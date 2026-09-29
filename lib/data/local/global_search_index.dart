import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/media_directory_entry.dart';

class GlobalSearchResult {
  const GlobalSearchResult({
    required this.sourceId,
    required this.parentPath,
    required this.name,
    required this.isDirectory,
  });

  final String sourceId;
  final String parentPath;
  final String name;
  final bool isDirectory;

  String get path => parentPath.isEmpty ? name : '$parentPath/$name';
}

class SearchIndexStatus {
  const SearchIndexStatus({required this.entryCount, required this.builtAt});
  final int entryCount;
  final DateTime builtAt;
}

/// 客户端全目录索引；完成整个来源后才替换旧版结果。
class GlobalSearchIndex {
  GlobalSearchIndex._(this._db);
  final Database _db;
  final Map<String, Future<void>> _inFlight = {};
  final Map<String, int> _sourceGeneration = {};

  static Future<GlobalSearchIndex> open(String path) async {
    final db = await (Platform.isWindows ? databaseFactoryFfi : databaseFactory)
        .openDatabase(
          path,
          options: OpenDatabaseOptions(
            version: 1,
            onCreate: (db, _) async {
              await db.execute(
                'CREATE TABLE entries ('
                'source_id TEXT NOT NULL, parent_path TEXT NOT NULL, '
                'name TEXT NOT NULL, lower_name TEXT NOT NULL, '
                'is_directory INTEGER NOT NULL, '
                'PRIMARY KEY(source_id, parent_path, name))',
              );
              await db.execute(
                'CREATE TABLE staging ('
                'source_id TEXT NOT NULL, parent_path TEXT NOT NULL, '
                'name TEXT NOT NULL, lower_name TEXT NOT NULL, '
                'is_directory INTEGER NOT NULL)',
              );
              await db.execute(
                'CREATE TABLE sources ('
                'source_id TEXT PRIMARY KEY, entry_count INTEGER NOT NULL, '
                'built_at INTEGER NOT NULL)',
              );
              await db.execute(
                'CREATE INDEX entries_name ON entries(lower_name)',
              );
            },
          ),
        );
    await db.delete('staging');
    return GlobalSearchIndex._(db);
  }

  Future<SearchIndexStatus?> status(String sourceId) async {
    final rows = await _db.query(
      'sources',
      where: 'source_id = ?',
      whereArgs: [sourceId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return SearchIndexStatus(
      entryCount: rows.first['entry_count'] as int,
      builtAt: DateTime.fromMillisecondsSinceEpoch(
        rows.first['built_at'] as int,
      ),
    );
  }

  Future<void> removeSource(String sourceId) {
    _sourceGeneration[sourceId] = (_sourceGeneration[sourceId] ?? 0) + 1;
    return _db.transaction((txn) async {
      await txn.delete(
        'entries',
        where: 'source_id = ?',
        whereArgs: [sourceId],
      );
      await txn.delete(
        'staging',
        where: 'source_id = ?',
        whereArgs: [sourceId],
      );
      await txn.delete(
        'sources',
        where: 'source_id = ?',
        whereArgs: [sourceId],
      );
    });
  }

  Future<void> retainSources(Set<String> ids) async {
    final rows = await _db.query('sources', columns: ['source_id']);
    for (final row in rows) {
      final id = row['source_id'] as String;
      if (!ids.contains(id)) {
        await removeSource(id);
      }
    }
  }

  Future<void> indexSource({
    required String sourceId,
    required Future<List<MediaDirectoryEntry>> Function(String path) list,
    Future<bool> Function(MediaDirectoryEntry entry)? shouldDescend,
    void Function(int directories, int entries)? onProgress,
  }) {
    final existing = _inFlight[sourceId];
    if (existing != null) return existing;
    final task = _indexSource(
      sourceId: sourceId,
      list: list,
      shouldDescend: shouldDescend,
      onProgress: onProgress,
    );
    _inFlight[sourceId] = task;
    task.then<void>(
      (_) {
        _inFlight.remove(sourceId);
      },
      onError: (Object _, StackTrace _) {
        _inFlight.remove(sourceId);
      },
    );
    return task;
  }

  Future<void> _indexSource({
    required String sourceId,
    required Future<List<MediaDirectoryEntry>> Function(String path) list,
    Future<bool> Function(MediaDirectoryEntry entry)? shouldDescend,
    void Function(int directories, int entries)? onProgress,
  }) async {
    final generation = _sourceGeneration[sourceId] ?? 0;
    await _db.delete('staging', where: 'source_id = ?', whereArgs: [sourceId]);
    final queue = <String>[''];
    final seen = <String>{};
    var cursor = 0;
    var entryCount = 0;
    try {
      while (cursor < queue.length) {
        final path = queue[cursor++];
        if (!seen.add(path)) continue;
        final files = await list(path);
        if ((_sourceGeneration[sourceId] ?? 0) != generation) {
          throw StateError('Search source was removed');
        }
        final batch = _db.batch();
        for (final entry in files) {
          if (entry.isSelfEntry) continue;
          final name = entry.name;
          if (name.isEmpty ||
              name == '.' ||
              name == '..' ||
              name.contains('/') ||
              name.contains('\\')) {
            continue;
          }
          batch.insert('staging', {
            'source_id': sourceId,
            'parent_path': path,
            'name': name,
            'lower_name': name.toLowerCase(),
            'is_directory': entry.isDirectory ? 1 : 0,
          });
          entryCount++;
          if (entry.isDirectory &&
              (shouldDescend == null || await shouldDescend(entry))) {
            queue.add(path.isEmpty ? name : '$path/$name');
          }
        }
        await batch.commit(noResult: true);
        onProgress?.call(cursor, entryCount);
      }
      if ((_sourceGeneration[sourceId] ?? 0) != generation) {
        throw StateError('Search source was removed');
      }
      await _db.transaction((txn) async {
        await txn.delete(
          'entries',
          where: 'source_id = ?',
          whereArgs: [sourceId],
        );
        await txn.execute(
          'INSERT INTO entries '
          '(source_id, parent_path, name, lower_name, is_directory) '
          'SELECT source_id, parent_path, name, lower_name, is_directory '
          'FROM staging WHERE source_id = ?',
          [sourceId],
        );
        await txn.delete(
          'staging',
          where: 'source_id = ?',
          whereArgs: [sourceId],
        );
        await txn.insert('sources', {
          'source_id': sourceId,
          'entry_count': entryCount,
          'built_at': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });
    } catch (_) {
      await _db.delete(
        'staging',
        where: 'source_id = ?',
        whereArgs: [sourceId],
      );
      rethrow;
    }
  }

  Future<List<GlobalSearchResult>> search(
    String query, {
    String? sourceId,
    int limit = 200,
  }) async {
    final needle = query
        .trim()
        .toLowerCase()
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
    if (needle.isEmpty) return const [];
    final rows = await _db.rawQuery(
      "SELECT source_id, parent_path, name, is_directory FROM entries "
      "WHERE lower_name LIKE ? ESCAPE '\\' "
      '${sourceId == null ? '' : 'AND source_id = ? '}'
      'ORDER BY CASE WHEN lower_name = ? THEN 0 '
      'WHEN lower_name LIKE ? THEN 1 ELSE 2 END, lower_name LIMIT ?',
      ['%$needle%', ?sourceId, needle, '$needle%', limit],
    );
    return rows
        .map(
          (row) => GlobalSearchResult(
            sourceId: row['source_id'] as String,
            parentPath: row['parent_path'] as String,
            name: row['name'] as String,
            isDirectory: row['is_directory'] == 1,
          ),
        )
        .toList(growable: false);
  }

  Future<void> close() => _db.close();
}
