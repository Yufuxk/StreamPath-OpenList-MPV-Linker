import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/film_catalog_item.dart';
import '../models/film_directory_exclusions.dart';
import '../models/media_source.dart';
import '../models/film_home_section.dart';
import '../models/media_library_item.dart';
import '../models/film_watch_state.dart';
import '../models/video_queue.dart';
import '../models/film_collection.dart';
import '../models/media_connection.dart';
import '../models/film_image_reference.dart';
import '../models/film_playlist.dart';
import '../../domain/services/film_video_timeline.dart';

part 'film_catalog_phase5.dart';
part 'film_catalog_servers.dart';
part 'film_catalog_portability.dart';
part 'film_catalog_playlists.dart';

/// 永久影视目录；远端操作始终在写事务外完成。
class FilmCatalogStore extends ChangeNotifier {
  FilmCatalogStore._(this._db);
  final Database _db;
  int _notificationDepth = 0;
  bool _notificationPending = false;
  final _watchChanges = ChangeNotifier();
  Listenable get watchChanges => _watchChanges;
  bool _watchNotificationPending = false;
  Future<T> withBatchedChanges<T>(Future<T> Function() operation) async {
    _notificationDepth++;
    try {
      return await operation();
    } finally {
      _notificationDepth--;
      // 并行来源各自完成批次时发布已保存的变更。
      if (_notificationPending) {
        _notificationPending = false;
        super.notifyListeners();
      }
      if (_watchNotificationPending) {
        _watchNotificationPending = false;
        _watchChanges.notifyListeners();
      }
    }
  }

  @override
  void notifyListeners() => _notifyChange(watch: true);

  void _notifyChange({required bool watch}) {
    if (_notificationDepth > 0) {
      _notificationPending = true;
      _watchNotificationPending |= watch;
    } else {
      super.notifyListeners();
      if (watch) _watchChanges.notifyListeners();
    }
  }

  bool spoilerProtection = false;
  static const _watchSchema = '''CREATE TABLE film_watch_state (
    source_id TEXT NOT NULL, work_id INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
    season_number INTEGER NOT NULL, episode_number INTEGER NOT NULL,
    watched INTEGER NOT NULL DEFAULT 0, position_ms INTEGER NOT NULL DEFAULT 0,
    duration_ms INTEGER, observed_at INTEGER NOT NULL DEFAULT 0,
    manual_at INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(source_id, work_id, season_number, episode_number))''';
  static const _discWatchSchema = '''CREATE TABLE film_disc_watch_state (
    resource_id INTEGER NOT NULL REFERENCES resources(id) ON DELETE CASCADE,
    work_id INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
    watched INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(resource_id, work_id))''';

  (int, int) _watchNumbers(FilmResource r) =>
      r.type == FilmMediaType.movie ? (-1, -1) : (r.season!, r.episode!);

  FilmWatchState _watchState(Map<String, Object?> row) {
    if (row['watched'] == 1) return FilmWatchState.watched;
    final position = row['position_ms'] as int? ?? 0;
    final duration = row['duration_ms'] as int?;
    return position <= 0
        ? FilmWatchState.unwatched
        : FilmWatchState(
            status: FilmWatchStatus.inProgress,
            fraction: duration == null || duration <= 0
                ? 0
                : (position / duration).clamp(0.0, 1.0),
          );
  }

  Future<FilmWatchState?> resourceWatchState(FilmResource r) async {
    if (!r.canMarkWatched) return null;
    if (r.isDisc) {
      final rows = await _db.query(
        'film_disc_watch_state',
        where: 'resource_id=? AND work_id=?',
        whereArgs: [r.id, r.workId],
      );
      return rows.isEmpty ? FilmWatchState.unwatched : _watchState(rows.single);
    }
    final (s, e) = _watchNumbers(r);
    final rows = await _db.query(
      'film_watch_state',
      where:
          'source_id = ? AND work_id = ? AND season_number = ? AND episode_number = ?',
      whereArgs: [r.sourceId, r.workId, s, e],
    );
    return rows.isEmpty ? FilmWatchState.unwatched : _watchState(rows.single);
  }

  Future<DateTime?> manualWatchResetAt(String sourceId, String path) async {
    final resource = await resourceAt(sourceId, path);
    if (resource == null || !resource.canMarkWatched || resource.isDisc) {
      return null;
    }
    final (season, episode) = _watchNumbers(resource);
    final rows = await _db.query(
      'film_watch_state',
      columns: ['manual_at'],
      where:
          'source_id=? AND work_id=? AND season_number=? AND episode_number=?',
      whereArgs: [sourceId, resource.workId, season, episode],
    );
    final time = rows.isEmpty ? 0 : rows.single['manual_at'] as int;
    return time == 0 ? null : DateTime.fromMillisecondsSinceEpoch(time);
  }

  /// 一批作品统一读取，重复版本与来源不重复计入集数。
  Future<Map<int, FilmWatchState>> workWatchStates(
    List<int> workIds, {
    int? rootId,
    Set<String>? sourceIds,
  }) async {
    if (workIds.isEmpty) return {};
    final rows = await _watchRows(
      workIds,
      rootId: rootId,
      sourceIds: sourceIds,
    );
    return {
      for (final id in workIds)
        if (rows.any((r) => r['work_id'] == id))
          id: _aggregateWatch(
            rows.where((r) => r['work_id'] == id).toList(),
            regularOnly: true,
          ),
    };
  }

  Future<FilmWatchState?> seasonWatchState(
    int workId,
    int number, {
    String? sourceId,
    int? rootId,
  }) async {
    final rows = (await _watchRows(
      [workId],
      sourceId: sourceId,
      rootId: rootId,
    )).where((r) => r['season_number'] == number).toList();
    return rows.isEmpty ? null : _aggregateWatch(rows);
  }

  Future<List<Map<String, Object?>>> _watchRows(
    List<int> ids, {
    int? rootId,
    String? sourceId,
    Set<String>? sourceIds,
  }) => _db.rawQuery(
    '''
    SELECT r.work_id, r.season_number, r.episode_number, w.media_type,
      CASE WHEN r.media_kind IN ('iso','bdmv') THEN r.id END AS disc_id,
      CASE WHEN r.media_kind IN ('iso','bdmv') THEN d.watched ELSE v.watched END AS watched,
      CASE WHEN r.media_kind IN ('iso','bdmv') THEN 0 ELSE v.position_ms END AS position_ms,
      CASE WHEN r.media_kind IN ('iso','bdmv') THEN NULL ELSE v.duration_ms END AS duration_ms FROM resources r
    JOIN catalog_roots c ON c.id=r.root_id JOIN works w ON w.id=r.work_id
    LEFT JOIN film_watch_state v ON v.source_id=c.source_id AND v.work_id=r.work_id
      AND v.season_number=CASE WHEN w.media_type='movie' THEN -1 ELSE r.season_number END
      AND v.episode_number=CASE WHEN w.media_type='movie' THEN -1 ELSE r.episode_number END
    LEFT JOIN film_disc_watch_state d ON d.resource_id=r.id AND d.work_id=r.work_id
    WHERE r.work_id IN (${List.filled(ids.length, '?').join(',')})
      AND $_rootEnabledSql
      AND r.media_kind IN ('video','strm','iso','bdmv')
      AND (r.media_kind IN ('iso','bdmv') OR w.media_type='movie' OR r.season_number IS NOT NULL AND r.episode_number IS NOT NULL)
      ${rootId == null ? '' : 'AND r.root_id=?'} ${sourceId == null ? '' : 'AND c.source_id=?'}
      ${sourceIds == null
        ? ''
        : sourceIds.isEmpty
        ? 'AND 0'
        : 'AND c.source_id IN (${List.filled(sourceIds.length, '?').join(',')})'}''',
    [...ids, ?rootId, ?sourceId, ...?sourceIds],
  );

  FilmWatchState _aggregateWatch(
    List<Map<String, Object?>> rows, {
    bool regularOnly = false,
  }) {
    if (regularOnly && rows.any((r) => (r['season_number'] as int? ?? 0) > 0)) {
      rows = rows
          .where(
            (r) =>
                (r['season_number'] as int? ?? 0) > 0 ||
                r['disc_id'] != null && r['season_number'] == null,
          )
          .toList();
    }
    final episodes = <String, FilmWatchState>{};
    for (final row in rows) {
      final key = row['media_type'] == 'movie'
          ? 'movie'
          : row['disc_id'] != null
          ? 'disc:${row['disc_id']}'
          : '${row['season_number']}:${row['episode_number']}';
      final state = _watchState(row);
      final previous = episodes[key];
      if (previous == null ||
          state.fraction > previous.fraction ||
          previous.status == FilmWatchStatus.unwatched &&
              state.status == FilmWatchStatus.inProgress) {
        episodes[key] = state;
      }
    }
    if (episodes.isEmpty) return FilmWatchState.unwatched;
    final fraction =
        episodes.values.fold<double>(0, (sum, s) => sum + s.fraction) /
        episodes.length;
    if (fraction == 0 &&
        episodes.values.any((s) => s.status == FilmWatchStatus.inProgress)) {
      return const FilmWatchState(status: FilmWatchStatus.inProgress);
    }
    return FilmWatchState.fromFraction(fraction);
  }

  Future<void> recordVideoProgress(VideoProgressUpdate update) async {
    final r = await resourceAt(update.sourceId, update.path);
    if (r == null || !r.canMarkWatched || r.isDisc) return;
    final (s, e) = _watchNumbers(r);
    final time = update.recordedAt.millisecondsSinceEpoch;
    final watched =
        update.completed ||
        update.durationMs != null &&
            update.durationMs! > 0 &&
            update.positionMs / update.durationMs! >= 0.99;
    final previous = await resourceWatchState(r);
    await _db.rawInsert(
      '''INSERT INTO film_watch_state
      (source_id,work_id,season_number,episode_number,watched,position_ms,duration_ms,observed_at)
      VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(source_id,work_id,season_number,episode_number)
      DO UPDATE SET watched=MAX(film_watch_state.watched,excluded.watched),
        position_ms=excluded.position_ms,duration_ms=excluded.duration_ms,observed_at=excluded.observed_at
      WHERE excluded.observed_at>film_watch_state.manual_at
        AND (excluded.observed_at>=film_watch_state.observed_at OR excluded.watched=1)''',
      [
        r.sourceId,
        r.workId,
        s,
        e,
        watched ? 1 : 0,
        update.positionMs,
        update.durationMs,
        time,
      ],
    );
    final current = await resourceWatchState(r);
    if (previous?.status != current?.status ||
        ((previous?.fraction ?? 0) * 100).floor() !=
            ((current?.fraction ?? 0) * 100).floor()) {
      notifyListeners();
    }
  }

  /// 人工标记留存时间边界，拒绝旧日志与 watch_later 重新导入。
  Future<void> markWatched(
    List<FilmResource> resources,
    bool watched, {
    DateTime? observedAt,
  }) async {
    final now = (observedAt ?? DateTime.now()).millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      final keys = <(String, int, int, int)>{};
      for (final r in resources.where((r) => r.canMarkWatched)) {
        if (r.isDisc) {
          await txn.insert('film_disc_watch_state', {
            'resource_id': r.id,
            'work_id': r.workId,
            'watched': watched ? 1 : 0,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          continue;
        }
        final (s, e) = _watchNumbers(r);
        if (!keys.add((r.sourceId, r.workId!, s, e))) continue;
        await txn.rawInsert(
          '''INSERT INTO film_watch_state
          (source_id,work_id,season_number,episode_number,watched,manual_at,observed_at)
          VALUES (?,?,?,?,?,?,?) ON CONFLICT(source_id,work_id,season_number,episode_number)
          DO UPDATE SET watched=excluded.watched,position_ms=0,duration_ms=NULL,
            manual_at=excluded.manual_at,observed_at=excluded.observed_at''',
          [r.sourceId, r.workId, s, e, watched ? 1 : 0, now, now],
        );
      }
    });
    notifyListeners();
  }

  String get path => _db.path;

  static Future<FilmCatalogStore> open(String path) async {
    final db = await (Platform.isWindows ? databaseFactoryFfi : databaseFactory)
        .openDatabase(
          path,
          options: OpenDatabaseOptions(
            version: 8,
            onConfigure: (db) async {
              await db.execute('PRAGMA foreign_keys = ON');
              final version = await db.getVersion();
              if (version > 0 && version < 8 && path != inMemoryDatabasePath) {
                final backup =
                    '$path.before-v${version + 1}-${DateTime.now().microsecondsSinceEpoch}.bak';
                await db.execute(
                  "VACUUM INTO '${backup.replaceAll("'", "''")}'",
                );
              }
              if (version > 0 && version < 7) {
                await db.execute('PRAGMA foreign_keys = OFF');
              }
            },
            onCreate: (db, _) async {
              for (final statement in _schema) {
                await db.execute(statement);
              }
              await db.execute(_watchSchema);
              await db.execute(_discWatchSchema);
              for (final statement in _phase5Schema) {
                await db.execute(statement);
              }
              for (final statement in _playlistSchema) {
                await db.execute(statement);
              }
            },
            onUpgrade: (db, oldVersion, _) async {
              if (oldVersion < 5) await db.execute(_watchSchema);
              if (oldVersion == 1) {
                await db.execute(
                  'ALTER TABLE resources RENAME TO resources_v1',
                );
                await db.execute(
                  _schema.firstWhere(
                    (s) => s.startsWith('CREATE TABLE resources '),
                  ),
                );
                await db.execute(
                  'INSERT INTO resources SELECT * FROM resources_v1',
                );
                await db.execute('DROP TABLE resources_v1');
                for (final statement in _schema.where(
                  (s) => s.startsWith('CREATE INDEX resources_'),
                )) {
                  await db.execute(statement);
                }
              }
              if (oldVersion == 2) {
                await db.execute(
                  'ALTER TABLE resources RENAME TO resources_v2',
                );
                await db.execute(
                  _schema.firstWhere(
                    (s) => s.startsWith('CREATE TABLE resources '),
                  ),
                );
                await db.execute(
                  'INSERT INTO resources SELECT * FROM resources_v2',
                );
                await db.execute('DROP TABLE resources_v2');
                for (final statement in _schema.where(
                  (s) => s.startsWith('CREATE INDEX resources_'),
                )) {
                  await db.execute(statement);
                }
              }
              if (oldVersion < 3) {
                await db.execute('DROP TABLE scan_entries');
                await db.execute(
                  _schema.firstWhere(
                    (s) => s.startsWith('CREATE TABLE scan_entries '),
                  ),
                );
                for (final statement in _schema.where(
                  (s) =>
                      s.startsWith('CREATE TABLE work_favorites ') ||
                      s.startsWith('CREATE TABLE resource_probes ') ||
                      s.startsWith('CREATE TABLE root_covers '),
                )) {
                  await db.execute(statement);
                }
                await db.execute(
                  "ALTER TABLE catalog_settings ADD COLUMN probe_mode TEXT NOT NULL DEFAULT 'playback' CHECK(probe_mode IN ('playback','full'))",
                );
              }
              if (oldVersion < 4) {
                await db.execute(
                  'ALTER TABLE root_covers RENAME TO root_covers_v3',
                );
                await db.execute(
                  _schema.firstWhere(
                    (s) => s.startsWith('CREATE TABLE root_covers '),
                  ),
                );
                await db.execute(
                  'INSERT INTO root_covers (root_id, work_id) SELECT root_id, work_id FROM root_covers_v3',
                );
                await db.execute('DROP TABLE root_covers_v3');
                await db.execute(
                  _schema.firstWhere(
                    (s) => s.startsWith('CREATE TABLE catalog_preferences '),
                  ),
                );
              }
              if (oldVersion < 6) await db.execute(_discWatchSchema);
              if (oldVersion < 7) await _upgradePhase5(db);
              if (oldVersion < 8) {
                for (final statement in _playlistSchema) {
                  await db.execute(statement);
                }
              }
            },
            onOpen: (db) async {
              await db.execute('PRAGMA foreign_keys = ON');
              if ((await db.rawQuery('PRAGMA foreign_key_check')).isNotEmpty) {
                throw const FilmCatalogException('catalogStorageFailed');
              }
            },
          ),
        );
    await db.transaction((txn) async {
      await txn.update('catalog_roots', {
        'scan_status': 'failed',
        'last_error': 'interrupted',
      }, where: "scan_status = 'running'");
      await txn.delete('scan_entries');
    });
    final store = FilmCatalogStore._(db);
    store.spoilerProtection =
        await store.preference('spoiler_protection') == true;
    return store;
  }

  Future<void> close() async {
    await _db.close();
    _watchChanges.dispose();
    super.dispose();
  }

  static const _rootEnabledSql =
      '''NOT EXISTS (SELECT 1 FROM catalog_preferences p
    WHERE p.key='library_enabled:' || c.id AND p.value_json='false')''';
  static const _rootSelect =
      'SELECT c.*, ($_rootEnabledSql) AS enabled FROM catalog_roots c';

  Future<List<FilmCatalogRoot>> roots() async => (await _db.rawQuery(
    '$_rootSelect ORDER BY c.created_at, c.id',
  )).map(FilmCatalogRoot.fromRow).toList();

  Future<FilmCatalogRoot?> root(int id) async {
    final rows = await _db.rawQuery('$_rootSelect WHERE c.id = ?', [id]);
    return rows.isEmpty ? null : FilmCatalogRoot.fromRow(rows.single);
  }

  Future<void> setRootEnabled(int id, bool enabled) =>
      setPreference('library_enabled:$id', enabled);

  Future<bool> playbackVersionAvailable(
    String sourceId,
    VideoQueueVersion version,
  ) async {
    final resource = await resourceAt(sourceId, version.path);
    if (resource == null) return version.rootId == null;
    return resource.availability == 'present' &&
        (await root(resource.rootId))?.enabled == true;
  }

  Future<FilmDirectoryExclusions> directoryExclusions() async {
    final saved = await preference('directory_exclusions');
    return saved == null
        ? const FilmDirectoryExclusions()
        : FilmDirectoryExclusions.fromJson(
            (saved as Map).cast<String, dynamic>(),
          );
  }

  /// 仅移除目录库资源，作品资料和独立播放记录保留。
  Future<void> pruneExcludedDirectories(
    FilmCatalogRoot root,
    FilmDirectoryExclusions exclusions, {
    String? scopePath,
  }) async {
    if (exclusions.names.isEmpty || root.sourceKind.isMediaServer) return;
    final scope = scopePath == null
        ? null
        : filmPathKey(scopePath, root.sourceKind);
    final removed = await _db.transaction((txn) async {
      final rows = await txn.query(
        'resources',
        columns: [
          'id',
          'path_key',
          'relative_path',
          'parent_path',
          'media_kind',
        ],
        where: 'root_id=?',
        whereArgs: [root.id],
      );
      final ids = [
        for (final row in rows)
          if ((scope == null ||
                  filmPathWithin(row['path_key'] as String, scope)) &&
              exclusions.excludesPath(
                row[row['media_kind'] == 'bdmv'
                        ? 'relative_path'
                        : 'parent_path']
                    as String,
              ))
            row['id'] as int,
      ];
      for (var offset = 0; offset < ids.length; offset += 200) {
        final batch = ids.skip(offset).take(200).toList();
        await txn.delete(
          'resources',
          where: 'id IN (${List.filled(batch.length, '?').join(',')})',
          whereArgs: batch,
        );
      }
      return ids.isNotEmpty;
    });
    if (removed) {
      await reconcilePlaylists(sourceId: root.sourceId);
      notifyListeners();
    }
  }

  Future<int> addRoot({
    required String sourceId,
    required MediaSourceKind kind,
    required String path,
    required FilmMediaType type,
    required String name,
  }) async {
    validateFilmPath(path);
    final key = filmPathKey(path, kind);
    final id = await _db.transaction((txn) async {
      final existing = await txn.query(
        'catalog_roots',
        where: 'source_id = ?',
        whereArgs: [sourceId],
      );
      if (existing.any(
        (r) =>
            filmPathWithin(key, r['root_path_key'] as String) ||
            filmPathWithin(r['root_path_key'] as String, key),
      )) {
        throw const FilmCatalogException('overlappingRoot');
      }
      return txn.insert('catalog_roots', {
        'source_id': sourceId,
        'source_kind': kind.name,
        'root_path': path,
        'root_path_key': key,
        'media_type': type.name,
        'display_name': name,
        'created_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      });
    });
    notifyListeners();
    return id;
  }

  Future<void> removeRoot(int id) async {
    await _db.delete('catalog_roots', where: 'id = ?', whereArgs: [id]);
    notifyListeners();
  }

  Future<void> updateRoot(
    FilmCatalogRoot root, {
    required String sourceId,
    required MediaSourceKind kind,
    required String path,
    required FilmMediaType type,
    required String name,
  }) async {
    validateFilmPath(path);
    final key = filmPathKey(path, kind);
    final identityChanged =
        root.sourceId != sourceId ||
        root.sourceKind != kind ||
        filmPathKey(root.path, root.sourceKind) != key ||
        root.type != type;
    if (identityChanged && _db.path != inMemoryDatabasePath) {
      final backup =
          '${_db.path}.before-root${root.id}-${DateTime.now().microsecondsSinceEpoch}.bak';
      await _db.execute("VACUUM INTO '${backup.replaceAll("'", "''")}'");
    }
    await _db.transaction((txn) async {
      final current = await txn.query(
        'catalog_roots',
        where: 'id = ?',
        whereArgs: [root.id],
      );
      if (current.isEmpty ||
          current.single['scan_generation'] != root.generation) {
        throw const FilmCatalogException('staleScan');
      }
      if (current.single['scan_status'] == 'running') {
        throw const FilmCatalogException('scanBusy');
      }
      final others = await txn.query(
        'catalog_roots',
        where: 'source_id = ? AND id <> ?',
        whereArgs: [sourceId, root.id],
      );
      if (others.any(
        (r) =>
            filmPathWithin(key, r['root_path_key'] as String) ||
            filmPathWithin(r['root_path_key'] as String, key),
      )) {
        throw const FilmCatalogException('overlappingRoot');
      }
      if (identityChanged) {
        await txn.delete(
          'resources',
          where: 'root_id = ?',
          whereArgs: [root.id],
        );
        await txn.delete(
          'series_bindings',
          where: 'root_id = ?',
          whereArgs: [root.id],
        );
        await txn.delete(
          'scan_entries',
          where: 'root_id = ?',
          whereArgs: [root.id],
        );
      }
      await txn.update(
        'catalog_roots',
        {
          'source_id': sourceId,
          'source_kind': kind.name,
          'root_path': path,
          'root_path_key': key,
          'media_type': type.name,
          'display_name': name,
          if (identityChanged) ...{
            'scan_generation': root.generation + 1,
            'scan_status': 'idle',
            'last_success_at': null,
            'last_error': null,
          },
        },
        where: 'id = ?',
        whereArgs: [root.id],
      );
    });
    notifyListeners();
  }

  Future<int> beginScan(int id) async {
    final generation = await _db.transaction((txn) async {
      final rows = await txn.query(
        'catalog_roots',
        where: 'id = ?',
        whereArgs: [id],
      );
      if (rows.isEmpty) throw const FilmCatalogException('staleScan');
      final generation = (rows.single['scan_generation'] as int) + 1;
      await txn.delete('scan_entries', where: 'root_id = ?', whereArgs: [id]);
      await txn.update(
        'catalog_roots',
        {
          'scan_generation': generation,
          'scan_status': 'running',
          'last_error': null,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      return generation;
    });
    notifyListeners();
    return generation;
  }

  Future<void> _checkScan(DatabaseExecutor txn, int id, int generation) async {
    final rows = await txn.query(
      'catalog_roots',
      columns: ['id'],
      where: "id = ? AND scan_generation = ? AND scan_status = 'running'",
      whereArgs: [id, generation],
    );
    if (rows.isEmpty) throw const FilmCatalogException('staleScan');
  }

  Future<void> stage(
    FilmCatalogRoot root,
    int generation,
    List<FilmScanEntry> entries,
  ) async {
    await _db.transaction((txn) async {
      await _checkScan(txn, root.id, generation);
      final batch = txn.batch();
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      for (final entry in entries) {
        validateFilmPath(entry.path);
        if (!filmPathWithin(
          filmPathKey(entry.path, root.sourceKind),
          filmPathKey(root.path, root.sourceKind),
        )) {
          throw const FilmCatalogException('invalidPath');
        }
        batch.insert('scan_entries', {
          'root_id': root.id,
          'generation': generation,
          'relative_path': entry.path,
          'path_key': filmPathKey(entry.path, root.sourceKind),
          'parent_path': entry.parentPath,
          'name': entry.name,
          'media_kind': entry.mediaKind,
        });
        batch.rawInsert(
          '''INSERT INTO resources
        (root_id, relative_path, path_key, parent_path, name, media_kind,
         last_seen_generation, availability, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, 'present', ?)
        ON CONFLICT(root_id, path_key) DO UPDATE SET
          relative_path = excluded.relative_path, parent_path = excluded.parent_path,
          name = excluded.name, media_kind = excluded.media_kind,
          last_seen_generation = excluded.last_seen_generation, availability = 'present'
        ''',
          [
            root.id,
            entry.path,
            filmPathKey(entry.path, root.sourceKind),
            entry.parentPath,
            entry.name,
            entry.mediaKind,
            generation,
            now,
          ],
        );
      }
      await batch.commit(noResult: true);
    });
    if (entries.isNotEmpty) notifyListeners();
  }

  Future<void> commitScan(
    int id,
    int generation, {
    required bool Function() cancelled,
    bool incremental = false,
    String? scopePath,
  }) async {
    await _db.transaction((txn) async {
      await _checkScan(txn, id, generation);
      if (cancelled()) throw const FilmCatalogException('cancelled');
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      if (!incremental) {
        final roots = await txn.query(
          'catalog_roots',
          where: 'id=?',
          whereArgs: [id],
        );
        final root = FilmCatalogRoot.fromRow(roots.single);
        final scope = scopePath == null
            ? null
            : filmPathKey(scopePath, root.sourceKind);
        if (scope != null &&
            !filmPathWithin(scope, filmPathKey(root.path, root.sourceKind))) {
          throw const FilmCatalogException('invalidPath');
        }
        await txn.update(
          'resources',
          {'availability': 'missing'},
          where:
              'root_id = ? AND last_seen_generation <> ? ${scope == null || scope.isEmpty ? '' : "AND (path_key=? OR substr(path_key,1,?)=?)"}',
          whereArgs: [
            id,
            generation,
            if (scope != null && scope.isNotEmpty) ...[
              scope,
              scope.length + 1,
              '$scope/',
            ],
          ],
        );
      }
      if (cancelled()) throw const FilmCatalogException('cancelled');
      await txn.update(
        'catalog_roots',
        {
          'scan_status': 'completed',
          'last_success_at': now,
          'last_error': null,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      await txn.delete(
        'scan_entries',
        where: 'root_id = ? AND generation = ?',
        whereArgs: [id, generation],
      );
    });
    notifyListeners();
  }

  /// 刮削资料逐项关联已登记资源，保留请求期间的人工纠错。
  Future<void> applyMetadata(int id, Map<String, FilmScanMatch> matches) async {
    if (matches.isEmpty) return;
    final prepared = Map<String, FilmScanMatch>.of(matches);
    var changed = false;
    var watchChanged = false;
    await _db.transaction((txn) async {
      final roots = await txn.query(
        'catalog_roots',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [id],
      );
      if (roots.isEmpty) return;
      final workIds = <String, int>{};
      final savedSeasons = <(int, int)>{};
      for (final entry in prepared.entries) {
        final match = entry.value;
        final rows = await txn.query(
          'resources',
          where: 'root_id = ? AND path_key = ?',
          whereArgs: [id, entry.key],
        );
        final row = rows.firstOrNull;
        // 请求期间发生的人工纠错优先于本次扫描结果。
        if (row != null && row['binding_version'] != match.bindingVersion) {
          continue;
        }
        final workKey = match.work.identity;
        var workId = workIds[workKey];
        if (workId == null) {
          final cached = await txn.query(
            'works',
            where: 'identity_key = ?',
            whereArgs: [workKey],
          );
          final incoming = match.work.toRow();
          if (cached.isNotEmpty &&
              ((cached.single['metadata_fetched_at'] as int) >
                      match.work.fetchedAt ||
                  incoming.entries.every(
                    (entry) => cached.single[entry.key] == entry.value,
                  ))) {
            workId = cached.single['id'] as int;
          } else {
            workId = await _saveWork(txn, match.work, row: incoming);
            changed = true;
            // 文件作品取得统一身份时会同时合并资源与观看状态。
            watchChanged |= cached.isEmpty || match.work.id != workId;
          }
          workIds[workKey] = workId;
        }
        if (match.seasonMetadata != null &&
            (match.origin == 'nfo' ||
                savedSeasons.add((workId, match.seasonNumber!)))) {
          var metadata = match.seasonMetadata!;
          if (match.origin == 'nfo') {
            final previous = await txn.query(
              'season_metadata',
              where: 'work_id=? AND season_number=?',
              whereArgs: [workId, match.seasonNumber],
            );
            final old = previous.isEmpty
                ? <String, dynamic>{}
                : jsonDecode(previous.single['metadata_json'] as String)
                      as Map<String, dynamic>;
            final episodes = <Object?, Map>{
              for (final episode
                  in (old['episodes'] as List? ?? []).whereType<Map>())
                episode['episode_number']: episode,
              for (final episode
                  in (metadata['episodes'] as List? ?? []).whereType<Map>())
                episode['episode_number']: episode,
            };
            metadata = {
              ...old,
              ...metadata,
              'episodes': episodes.values.toList(),
            };
          }
          final previous = await txn.query(
            'season_metadata',
            columns: ['metadata_json', 'metadata_language'],
            where: 'work_id=? AND season_number=?',
            whereArgs: [workId, match.seasonNumber],
          );
          if (previous.isEmpty ||
              previous.single['metadata_language'] != match.work.language ||
              previous.single['metadata_json'] != jsonEncode(metadata)) {
            await _saveSeason(
              txn,
              workId,
              match.seasonNumber!,
              match.work.language,
              metadata,
            );
            changed = true;
          }
        }
        if (row == null) continue;
        var version = match.bindingVersion;
        if (row['work_id'] == null) {
          changed = watchChanged = true;
          await txn.update(
            'resources',
            {
              'work_id': workId,
              'binding_origin': match.origin,
              'binding_version': ++version,
            },
            where: 'id = ?',
            whereArgs: [row['id']],
          );
        }
        if (match.episode case final episode?) {
          if (row['episode_mapping_origin'] != 'manual' &&
              (row['season_number'] != episode.$1 ||
                  row['episode_number'] != episode.$2)) {
            changed = watchChanged = true;
            await txn.update(
              'resources',
              {
                'season_number': episode.$1,
                'episode_number': episode.$2,
                'episode_mapping_origin': match.origin == 'nfo'
                    ? 'nfo'
                    : 'filename',
                'binding_version': ++version,
              },
              where: 'id = ?',
              whereArgs: [row['id']],
            );
          }
        }
      }
    });
    if (changed) _notifyChange(watch: watchChanged);
  }

  Future<void> finishScan(
    int id,
    int generation,
    String status,
    String? error,
  ) async {
    await _db.transaction((txn) async {
      await txn.update(
        'catalog_roots',
        {'scan_status': status, 'last_error': error},
        where: 'id = ? AND scan_generation = ?',
        whereArgs: [id, generation],
      );
      await txn.delete(
        'scan_entries',
        where: 'root_id = ? AND generation = ?',
        whereArgs: [id, generation],
      );
    });
    notifyListeners();
  }

  static const _resourceSelect = '''SELECT r.*, c.source_id, c.source_kind,
      c.media_type, c.root_path, c.display_name FROM resources r
      JOIN catalog_roots c ON c.id = r.root_id''';

  Future<List<FilmResource>> resources({
    int? rootId,
    int? workId,
    String? sourceId,
    bool pending = false,
    bool enabledOnly = false,
    int? limit,
    int offset = 0,
  }) async {
    final clauses = <String>[];
    if (enabledOnly) clauses.add(_rootEnabledSql);
    final args = <Object?>[];
    if (rootId != null) {
      clauses.add('r.root_id = ?');
      args.add(rootId);
    }
    if (workId != null) {
      clauses.add('r.work_id = ?');
      args.add(workId);
    }
    if (sourceId != null) {
      clauses.add('c.source_id = ?');
      args.add(sourceId);
    }
    if (pending) {
      clauses.add(
        "(r.work_id IS NULL OR (c.media_type = 'tv' AND r.season_number IS NULL))",
      );
    }
    final rows = await _db.rawQuery(
      '$_resourceSelect ${clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}'} '
      'ORDER BY ${rootId != null || pending ? 'r.id' : 'r.season_number, r.episode_number, r.relative_path, r.id'} '
      '${limit == null ? '' : 'LIMIT ? OFFSET ?'}',
      [
        ...args,
        if (limit != null) ...[limit, offset],
      ],
    );
    return rows.map(FilmResource.fromRow).toList();
  }

  Future<FilmResource?> resource(int id) async {
    final rows = await _db.rawQuery('$_resourceSelect WHERE r.id = ?', [id]);
    return rows.isEmpty ? null : FilmResource.fromRow(rows.single);
  }

  Future<int> pendingCount({String? sourceId, int? rootId}) async =>
      (await _db.rawQuery(
            '''SELECT COUNT(*) AS count FROM resources r
      JOIN catalog_roots c ON c.id = r.root_id
      WHERE (r.work_id IS NULL OR (c.media_type = 'tv' AND r.season_number IS NULL))
      AND $_rootEnabledSql
      ${sourceId == null ? '' : 'AND c.source_id = ?'}
      ${rootId == null ? '' : 'AND c.id = ?'}''',
            [?sourceId, ?rootId],
          )).single['count']
          as int;

  Future<List<FilmWork>> works({
    required FilmMediaType? type,
    String query = '',
    String? sourceId,
    int? rootId,
    bool newest = false,
    int offset = 0,
    int limit = 60,
    bool favoritesOnly = false,
    String? collectionId,
    String? personId,
    Set<String>? sourceIds,
    String? sectionId,
  }) async {
    final daily = sectionId == 'daily' ? await dailySelection() : null;
    final rows = await _db.rawQuery(
      '''SELECT w.*, COUNT(r.id) AS resource_count,
      SUM(CASE WHEN r.availability = 'missing' THEN 1 ELSE 0 END) AS missing_count
      FROM works w JOIN resources r ON r.work_id = w.id
      JOIN catalog_roots c ON c.id = r.root_id
      WHERE (? IS NULL OR w.media_type = ?) AND (instr(lower(w.title), lower(?)) > 0
        OR instr(lower(w.original_title), lower(?)) > 0)
      AND $_rootEnabledSql
      ${sourceId == null ? '' : 'AND c.source_id = ?'}
      ${rootId == null ? '' : 'AND c.id = ?'}
      ${sectionId?.startsWith('genre:') == true ? "AND EXISTS (SELECT 1 FROM json_each(w.metadata_json, '\$.genres') WHERE value = ?)" : ''}
      ${sectionId?.startsWith('country:') == true ? "AND EXISTS (SELECT 1 FROM json_each(w.metadata_json, '\$.origin_country') WHERE value = ?)" : ''}
      ${sectionId?.startsWith('decade:') == true ? 'AND w.year >= ? AND w.year < ?' : ''}
      ${favoritesOnly ? 'AND EXISTS (SELECT 1 FROM work_favorites f WHERE f.work_id = w.id)' : ''}
      ${collectionId == null ? '' : 'AND EXISTS (SELECT 1 FROM collection_members m WHERE m.work_id=w.id AND m.collection_id=?)'}
      ${personId == null ? '' : 'AND EXISTS (SELECT 1 FROM work_people p WHERE p.work_id=w.id AND p.person_id=?)'}
      ${daily == null
          ? ''
          : daily.isEmpty
          ? 'AND 0'
          : 'AND w.id IN (${List.filled(daily.length, '?').join(',')})'}
      ${sourceIds == null
          ? ''
          : sourceIds.isEmpty
          ? 'AND 0'
          : 'AND c.source_id IN (${List.filled(sourceIds.length, '?').join(',')})'}
      GROUP BY w.id ORDER BY ${newest ? 'MAX(r.created_at) DESC' : 'w.title COLLATE NOCASE'}, w.id
      LIMIT ? OFFSET ?''',
      [
        type?.name,
        type?.name,
        query,
        query,
        ?sourceId,
        ?rootId,
        if (sectionId?.startsWith('genre:') == true ||
            sectionId?.startsWith('country:') == true)
          sectionId!.substring(sectionId.indexOf(':') + 1),
        if (sectionId?.startsWith('decade:') == true) ...[
          int.parse(sectionId!.substring(7)),
          int.parse(sectionId.substring(7)) + 10,
        ],
        ?collectionId,
        ?personId,
        ...?daily,
        ...?sourceIds,
        limit,
        offset,
      ],
    );
    final result = rows.map(FilmWork.fromRow).toList();
    if (daily != null) {
      result.sort((a, b) => daily.indexOf(a.id).compareTo(daily.indexOf(b.id)));
    }
    return result;
  }

  Future<FilmWork?> work(int id) async {
    final rows = await _db.query('works', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : FilmWork.fromRow(rows.single);
  }

  Future<bool> isFavorite(int workId) async => (await _db.query(
    'work_favorites',
    where: 'work_id = ?',
    whereArgs: [workId],
  )).isNotEmpty;

  Future<void> setFavorite(int workId, bool value) async {
    if (value) {
      await _db.insert('work_favorites', {
        'work_id': workId,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    } else {
      await _db.delete(
        'work_favorites',
        where: 'work_id = ?',
        whereArgs: [workId],
      );
    }
    notifyListeners();
  }

  Future<void> clearFavorites(String sourceId) async {
    await _db.rawDelete(
      'DELETE FROM work_favorites WHERE work_id IN (SELECT r.work_id FROM resources r JOIN catalog_roots c ON c.id = r.root_id WHERE c.source_id = ?)',
      [sourceId],
    );
    notifyListeners();
  }

  Future<FilmWork?> chooseRootCover(
    int rootId, {
    Future<bool> Function(FilmWork)? isCached,
  }) async {
    final previous = await _db.query(
      'root_covers',
      where: 'root_id = ?',
      whereArgs: [rootId],
    );
    final lastId = previous.firstOrNull?['work_id'];
    final rows = await _db.rawQuery(
      '''SELECT DISTINCT w.* FROM works w JOIN resources r ON r.work_id = w.id WHERE r.root_id = ? AND w.poster_path IS NOT NULL ORDER BY CASE WHEN w.id = ? THEN 1 ELSE 0 END, RANDOM()''',
      [rootId, lastId],
    );
    FilmWork? work;
    for (final row in rows) {
      final candidate = FilmWork.fromRow(row);
      if (isCached == null || await isCached(candidate)) {
        work = candidate;
        break;
      }
    }
    if (work == null) return null;
    await _db.insert('root_covers', {
      'root_id': rootId,
      'work_id': work.id,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return work;
  }

  Future<String?> customRootCover(int rootId) async =>
      (await _db.query(
            'root_covers',
            where: 'root_id = ?',
            whereArgs: [rootId],
          )).firstOrNull?['custom_path']
          as String?;

  Future<void> setCustomRootCover(int rootId, String? path) async {
    await _db.delete('root_covers', where: 'root_id = ?', whereArgs: [rootId]);
    if (path != null) {
      await _db.insert('root_covers', {'root_id': rootId, 'custom_path': path});
    }
    notifyListeners();
  }

  Future<String?> backgroundPath() async =>
      (await _db.query(
            'catalog_preferences',
            where: "key = 'background'",
          )).firstOrNull?['value_json']
          as String?;

  Future<void> setBackgroundPath(String? path) async {
    await _db.insert('catalog_preferences', {
      'key': 'background',
      'value_json': path ?? '',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    notifyListeners();
  }

  Future<List<FilmHomeSection>> homeSections() async {
    final rows = await _db.query(
      'catalog_preferences',
      where: "key = 'sections'",
    );
    final saved = rows.isEmpty
        ? FilmHomeSection.defaults
        : [
            for (final entry
                in jsonDecode(rows.single['value_json'] as String) as List)
              FilmHomeSection(
                entry['id'] as String,
                enabled: entry['enabled'] as bool,
              ),
          ];
    if (!saved.any((section) => section.id == 'daily')) {
      final index = saved.indexWhere((section) => section.id == 'continue');
      saved.insert(
        index < 0 ? 0 : index + 1,
        const FilmHomeSection('daily', enabled: true),
      );
    }
    final options = <String>{...FilmHomeSection.defaults.map((s) => s.id)};
    final works = await _db.rawQuery('''SELECT DISTINCT w.year,
        json_extract(w.metadata_json, '\$.genres') AS genres_json,
        json_extract(w.metadata_json, '\$.origin_country') AS countries_json
        FROM works w JOIN resources r ON r.work_id = w.id''');
    for (final row in works) {
      for (final genre
          in (jsonDecode(row['genres_json'] as String? ?? '[]') as List)
              .whereType<String>()) {
        options.add('genre:$genre');
      }
      for (final country
          in (jsonDecode(row['countries_json'] as String? ?? '[]') as List)
              .whereType<String>()) {
        options.add('country:$country');
      }
      if (row['year'] case final int year) {
        options.add('decade:${year ~/ 10 * 10}');
      }
    }
    return [
      ...saved,
      for (final id
          in options.difference(saved.map((s) => s.id).toSet()).toList()
            ..sort())
        FilmHomeSection(
          id,
          enabled: FilmHomeSection.defaults.any((s) => s.id == id),
        ),
    ];
  }

  Future<void> setHomeSections(List<FilmHomeSection> sections) async {
    await _db.insert('catalog_preferences', {
      'key': 'sections',
      'value_json': jsonEncode(sections.map((s) => s.toJson()).toList()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    notifyListeners();
  }

  Future<List<FilmWork>> artworkWorks() async => (await _db.query(
    'works',
    where: 'poster_path IS NOT NULL OR backdrop_path IS NOT NULL',
    orderBy: 'title',
  )).map(FilmWork.fromRow).toList();

  Future<Map<String, String>> playbackTitles(
    List<MediaLibraryRecord> records,
  ) async {
    final titles = <String, String>{};
    for (var start = 0; start < records.length; start += 200) {
      final batch = records.sublist(
        start,
        (start + 200).clamp(0, records.length),
      );
      final rows = await _db.rawQuery(
        'SELECT c.source_id, r.path_key, w.title FROM resources r JOIN catalog_roots c ON c.id = r.root_id JOIN works w ON w.id = r.work_id WHERE ${List.filled(batch.length, '(c.source_id = ? AND r.path_key = ?)').join(' OR ')}',
        [
          for (final record in batch) ...[
            record.item.sourceId,
            filmPathKey(
              record.item.discRootPath ?? record.item.targetPath,
              record.item.sourceKind,
            ),
          ],
        ],
      );
      final byPath = {
        for (final row in rows)
          '${row['source_id']}\u0000${row['path_key']}': row['title'] as String,
      };
      for (final record in batch) {
        titles[record.recordKey] =
            byPath['${record.item.sourceId}\u0000${filmPathKey(record.item.discRootPath ?? record.item.targetPath, record.item.sourceKind)}'] ??
            record.item.name;
      }
    }
    return titles;
  }

  Future<FilmResource?> resourceAt(String sourceId, String path) async {
    final rows = await _db.rawQuery(
      '$_resourceSelect WHERE c.source_id = ? AND r.path_key = ?',
      [sourceId, sourceId.startsWith('local:') ? path.toLowerCase() : path],
    );
    return rows.isEmpty ? null : FilmResource.fromRow(rows.first);
  }

  /// 按真实路径读取缓存标题，不发起 TMDB 或媒体请求。
  Future<Map<String, String>> videoPlaylistTitles(
    String sourceId,
    List<String> paths,
  ) async {
    final titles = <String, String>{};
    final kind = sourceId.startsWith('local:')
        ? MediaSourceKind.local
        : MediaSourceKind.webdav;
    for (var start = 0; start < paths.length; start += 200) {
      final batch = paths.sublist(start, (start + 200).clamp(0, paths.length));
      final rows = await _db.rawQuery(
        '''SELECT r.path_key, r.season_number, r.episode_number,
        w.title, w.year, w.media_type, s.metadata_json AS season_json
        FROM resources r JOIN catalog_roots c ON c.id = r.root_id
        JOIN works w ON w.id = r.work_id
        LEFT JOIN season_metadata s ON s.work_id = w.id
          AND s.season_number = r.season_number
          AND s.metadata_language = w.metadata_language
        WHERE c.source_id = ? AND r.path_key IN (${List.filled(batch.length, '?').join(',')})''',
        [sourceId, for (final path in batch) filmPathKey(path, kind)],
      );
      for (final row in rows) {
        final title = (row['title'] as String).trim();
        if (title.isEmpty) continue;
        final season = row['season_number'] as int?;
        final episode = row['episode_number'] as int?;
        final tv = row['media_type'] == 'tv';
        if (tv && (season == null || episode == null)) continue;
        String? episodeTitle;
        if (tv && row['season_json'] != null) {
          final metadata = jsonDecode(row['season_json'] as String) as Map;
          final episodes = metadata['episodes'] as List? ?? const [];
          episodeTitle =
              episodes
                      .where((entry) => entry['episode_number'] == episode)
                      .firstOrNull?['name']
                  as String?;
        }
        final name = episodeTitle?.trim() ?? '';
        final shortened = name.runes.length > 48
            ? '${String.fromCharCodes(name.runes.take(45))}...'
            : name;
        titles[row['path_key'] as String] = [
          title,
          if (row['year'] != null) '${row['year']}',
          if (tv)
            'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}',
          if (shortened.isNotEmpty) shortened,
        ].join('·');
      }
    }
    return {for (final path in paths) path: ?titles[filmPathKey(path, kind)]};
  }

  Future<Map<String, dynamic>?> probe(int resourceId) async {
    final rows = await _db.query(
      'resource_probes',
      where: 'resource_id = ?',
      whereArgs: [resourceId],
    );
    return rows.isEmpty
        ? null
        : Map<String, dynamic>.from(
            jsonDecode(rows.single['metadata_json'] as String),
          );
  }

  Future<List<FilmResource>> unprobedResources({int limit = 1}) async =>
      (await _db.rawQuery(
        '''$_resourceSelect LEFT JOIN resource_probes p ON p.resource_id = r.id
    WHERE r.availability = ? AND (p.resource_id IS NULL OR
      (r.media_kind <> 'strm' AND json_extract(p.metadata_json, '\$.state') = 'playback'
       AND COALESCE(json_extract(p.metadata_json, '\$.fullProbed'), 0) = 0))
    AND $_rootEnabledSql
    ORDER BY r.id LIMIT ?''',
        ['present', limit],
      )).map(FilmResource.fromRow).toList();

  Future<void> clearFailedProbes() async {
    await _db.delete(
      'resource_probes',
      where:
          "json_extract(metadata_json, '\$.state') IN ('failed', 'partial') OR "
          "json_extract(metadata_json, '\$.fullProbeState') IN ('failed', 'partial')",
    );
    notifyListeners();
  }

  Future<void> clearProbeMetadata() async {
    await _db.delete('resource_probes');
    notifyListeners();
  }

  Future<void> saveProbe(int resourceId, Map<String, dynamic> metadata) async {
    if (await resource(resourceId) == null) return;
    await _db.insert('resource_probes', {
      'resource_id': resourceId,
      'metadata_json': jsonEncode(metadata),
      'fetched_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    notifyListeners();
  }

  Future<String> probeMode() async =>
      (await _db.query('catalog_settings')).single['probe_mode'] as String;

  Future<void> setProbeMode(String mode) async {
    await _db.update('catalog_settings', {'probe_mode': mode});
    notifyListeners();
  }

  Future<FilmWork?> cachedWork(FilmMediaType type, int tmdbId) async {
    final rows = await _db.query(
      'works',
      where: 'media_type = ? AND tmdb_id = ?',
      whereArgs: [type.name, tmdbId],
    );
    return rows.isEmpty ? null : FilmWork.fromRow(rows.single);
  }

  Future<int> _saveWork(
    DatabaseExecutor txn,
    FilmWork work, {
    Map<String, Object?>? row,
  }) async {
    if (work.title.isEmpty || work.originalTitle.isEmpty) {
      throw const FilmCatalogException('invalidMetadata');
    }
    final rows = await txn.query(
      'works',
      columns: ['id'],
      where: 'identity_key = ?',
      whereArgs: [work.identity],
    );
    final previous = work.id == 0
        ? <Map<String, Object?>>[]
        : await txn.query('works', where: 'id=?', whereArgs: [work.id]);
    final localIdentity =
        previous.isNotEmpty && previous.single['tmdb_id'] == null;
    final id = rows.isNotEmpty
        ? rows.single['id'] as int
        : localIdentity
        ? work.id
        : await txn.insert('works', row ?? work.toRow());
    if (localIdentity && id != work.id) await _mergeWork(txn, work.id, id);
    if (rows.isNotEmpty || localIdentity) {
      await txn.update(
        'works',
        row ?? work.toRow(),
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    await _indexPhase5Work(txn, id, work);
    return id;
  }

  void _changed() => notifyListeners();

  Future<void> refreshWork(FilmWork work) async {
    await _db.transaction((txn) => _saveWork(txn, work));
    notifyListeners();
  }

  Future<void> _checkResource(
    DatabaseExecutor txn,
    FilmResource snapshot,
  ) async {
    final rows = await txn.query(
      'resources',
      columns: ['id'],
      where: 'id = ? AND root_id = ? AND path_key = ? AND binding_version = ?',
      whereArgs: [
        snapshot.id,
        snapshot.rootId,
        snapshot.pathKey,
        snapshot.bindingVersion,
      ],
    );
    if (rows.isEmpty) throw const FilmCatalogException('staleMatch');
  }

  Future<void> bind(
    List<FilmResource> snapshots,
    FilmWork work, {
    String origin = 'manual',
    String? directoryPath,
  }) async {
    if (snapshots.isEmpty) return;
    await _db.transaction((txn) async {
      for (final resource in snapshots) {
        await _checkResource(txn, resource);
        if (resource.type != work.type) {
          throw const FilmCatalogException('wrongMediaType');
        }
      }
      if (directoryPath != null) {
        validateFilmPath(directoryPath);
        final first = snapshots.first;
        if (work.type != FilmMediaType.tv ||
            snapshots.any(
              (r) =>
                  r.rootId != first.rootId ||
                  !filmPathWithin(
                    filmPathKey(r.parentPath, r.sourceKind),
                    filmPathKey(directoryPath, r.sourceKind),
                  ),
            ) ||
            !filmPathWithin(
              filmPathKey(directoryPath, first.sourceKind),
              filmPathKey(first.rootPath, first.sourceKind),
            )) {
          throw const FilmCatalogException('invalidPath');
        }
      }
      final workId = await _saveWork(txn, work);
      if (work.tmdbId > 0) {
        for (final oldId
            in snapshots.map((r) => r.workId).whereType<int>().toSet()) {
          if (oldId == workId) continue;
          final old = await txn.query(
            'works',
            where: 'id=?',
            whereArgs: [oldId],
          );
          if (old.isNotEmpty && old.single['tmdb_id'] == null) {
            await _mergeWork(txn, oldId, workId);
          }
        }
      }
      for (final resource in snapshots) {
        await txn.update(
          'resources',
          {
            'work_id': workId,
            'binding_origin': origin,
            'binding_version': resource.bindingVersion + 1,
            'season_number': null,
            'episode_number': null,
            'episode_mapping_origin': 'unset',
          },
          where: 'id = ?',
          whereArgs: [resource.id],
        );
      }
      if (directoryPath != null) {
        final first = snapshots.first;
        await txn.rawInsert(
          '''INSERT INTO series_bindings
          (root_id, directory_path, directory_path_key, work_id, confirmed_at)
          VALUES (?, ?, ?, ?, ?) ON CONFLICT(root_id, directory_path_key)
          DO UPDATE SET work_id = excluded.work_id, confirmed_at = excluded.confirmed_at''',
          [
            first.rootId,
            directoryPath,
            filmPathKey(directoryPath, first.sourceKind),
            workId,
            DateTime.now().toUtc().millisecondsSinceEpoch,
          ],
        );
      }
    });
    for (final source in snapshots.map((r) => r.sourceId).toSet()) {
      await reconcilePlaylists(sourceId: source);
    }
    notifyListeners();
  }

  Future<FilmWork?> directoryWork(FilmResource resource) => directoryWorkAt(
    resource.rootId,
    resource.parentPath,
    resource.sourceKind,
  );

  Future<FilmWork?> directoryWorkAt(
    int rootId,
    String parentPath,
    MediaSourceKind kind,
  ) async {
    final rows = await _db.rawQuery(
      '''SELECT w.*, b.directory_path_key FROM series_bindings b
      JOIN works w ON w.id = b.work_id WHERE b.root_id = ?
      ORDER BY length(b.directory_path_key) DESC''',
      [rootId],
    );
    final parent = filmPathKey(parentPath, kind);
    for (final row in rows) {
      if (filmPathWithin(parent, row['directory_path_key'] as String)) {
        return FilmWork.fromRow(row);
      }
    }
    return null;
  }

  Future<Map<String, dynamic>?> season(
    int workId,
    int number, {
    String? language,
  }) async {
    final rows = await _db.query(
      'season_metadata',
      where:
          'work_id = ? AND season_number = ? ${language == null ? '' : 'AND metadata_language = ?'}',
      whereArgs: [workId, number, ?language],
    );
    return rows.isEmpty
        ? null
        : Map<String, dynamic>.from(
            jsonDecode(rows.single['metadata_json'] as String),
          );
  }

  Future<void> saveSeason(
    int workId,
    int number,
    String language,
    Map<String, dynamic> metadata,
  ) async {
    final workValue = await work(workId);
    if (workValue?.type != FilmMediaType.tv || number < 0) {
      throw const FilmCatalogException('wrongMediaType');
    }
    await _saveSeason(_db, workId, number, language, metadata);
    notifyListeners();
  }

  Future<void> _saveSeason(
    DatabaseExecutor txn,
    int workId,
    int number,
    String language,
    Map<String, dynamic> metadata,
  ) async {
    await txn.rawInsert(
      '''INSERT INTO season_metadata
      (work_id, season_number, metadata_json, metadata_language, metadata_fetched_at)
      VALUES (?, ?, ?, ?, ?) ON CONFLICT(work_id, season_number) DO UPDATE SET
      metadata_json = excluded.metadata_json, metadata_language = excluded.metadata_language,
      metadata_fetched_at = excluded.metadata_fetched_at''',
      [
        workId,
        number,
        jsonEncode(metadata),
        language,
        DateTime.now().toUtc().millisecondsSinceEpoch,
      ],
    );
  }

  Future<void> mapEpisodes(
    Map<FilmResource, (int, int)> mappings, {
    String origin = 'manual',
  }) async {
    await _db.transaction((txn) async {
      for (final entry in mappings.entries) {
        final resource = entry.key;
        await _checkResource(txn, resource);
        if (resource.type != FilmMediaType.tv || resource.workId == null) {
          throw const FilmCatalogException('wrongMediaType');
        }
        if (entry.value.$1 < 0 || entry.value.$2 <= 0) {
          throw const FilmCatalogException('invalidEpisode');
        }
        await txn.update(
          'resources',
          {
            'season_number': entry.value.$1,
            'episode_number': entry.value.$2,
            'episode_mapping_origin': origin,
            'binding_version': resource.bindingVersion + 1,
          },
          where: 'id = ?',
          whereArgs: [resource.id],
        );
      }
    });
    for (final source in mappings.keys.map((r) => r.sourceId).toSet()) {
      await reconcilePlaylists(sourceId: source);
    }
    notifyListeners();
  }

  Future<String> language() async =>
      (await _db.query('catalog_settings')).single['metadata_language']
          as String;
  Future<void> setLanguage(String value) async {
    if (!['zh-CN', 'zh-TW', 'ja-JP', 'en-US'].contains(value)) {
      throw const FilmCatalogException('invalidMetadata');
    }
    await _db.update('catalog_settings', {
      'metadata_language': value,
    }, where: 'id = 1');
    notifyListeners();
  }

  static const _schema = <String>[
    '''CREATE TABLE catalog_roots (id INTEGER PRIMARY KEY AUTOINCREMENT,
      source_id TEXT NOT NULL, source_kind TEXT NOT NULL CHECK(source_kind IN ('local','webdav','smb','ftp','nfs','jellyfin','emby')),
      root_path TEXT NOT NULL, root_path_key TEXT NOT NULL,
      media_type TEXT NOT NULL CHECK(media_type IN ('movie','tv')), display_name TEXT NOT NULL,
      scan_generation INTEGER NOT NULL DEFAULT 0, scan_status TEXT NOT NULL DEFAULT 'idle'
      CHECK(scan_status IN ('idle','running','completed','failed','cancelled')),
      last_success_at INTEGER, last_error TEXT, created_at INTEGER NOT NULL,
      UNIQUE(source_id, root_path_key))''',
    '''CREATE TABLE works (id INTEGER PRIMARY KEY AUTOINCREMENT,
      media_type TEXT NOT NULL CHECK(media_type IN ('movie','tv')), tmdb_id INTEGER CHECK(tmdb_id > 0),
      identity_key TEXT NOT NULL UNIQUE, metadata_origin TEXT NOT NULL DEFAULT 'network',
      title TEXT NOT NULL, original_title TEXT NOT NULL, year INTEGER, overview TEXT NOT NULL,
      poster_path TEXT, backdrop_path TEXT, metadata_json TEXT NOT NULL,
      metadata_language TEXT NOT NULL, metadata_fetched_at INTEGER NOT NULL, UNIQUE(media_type, tmdb_id))''',
    '''CREATE TABLE resources (id INTEGER PRIMARY KEY AUTOINCREMENT,
      root_id INTEGER NOT NULL REFERENCES catalog_roots(id) ON DELETE CASCADE,
      relative_path TEXT NOT NULL, path_key TEXT NOT NULL, parent_path TEXT NOT NULL,
      name TEXT NOT NULL, media_kind TEXT NOT NULL CHECK(media_kind IN ('video','strm','iso','bdmv')),
      size_bytes INTEGER, modified_at INTEGER, last_seen_generation INTEGER NOT NULL,
      availability TEXT NOT NULL DEFAULT 'present' CHECK(availability IN ('present','missing')),
      work_id INTEGER REFERENCES works(id), binding_origin TEXT NOT NULL DEFAULT 'unset'
      CHECK(binding_origin IN ('unset','explicit','folder','search','manual','nfo','server')), binding_version INTEGER NOT NULL DEFAULT 0,
      season_number INTEGER CHECK(season_number >= 0), episode_number INTEGER CHECK(episode_number > 0),
      episode_mapping_origin TEXT NOT NULL DEFAULT 'unset' CHECK(episode_mapping_origin IN ('unset','filename','manual','nfo','server')),
      created_at INTEGER NOT NULL, UNIQUE(root_id,path_key),
      CHECK((season_number IS NULL AND episode_number IS NULL) OR (season_number IS NOT NULL AND episode_number IS NOT NULL)),
      CHECK((work_id IS NULL AND binding_origin = 'unset') OR (work_id IS NOT NULL AND binding_origin <> 'unset')),
      CHECK((episode_mapping_origin = 'unset' AND season_number IS NULL) OR (episode_mapping_origin <> 'unset' AND season_number IS NOT NULL)),
      CHECK(season_number IS NULL OR work_id IS NOT NULL))''',
    '''CREATE TABLE series_bindings (root_id INTEGER NOT NULL REFERENCES catalog_roots(id) ON DELETE CASCADE,
      directory_path TEXT NOT NULL, directory_path_key TEXT NOT NULL, work_id INTEGER NOT NULL REFERENCES works(id),
      confirmed_at INTEGER NOT NULL, PRIMARY KEY(root_id,directory_path_key))''',
    '''CREATE TABLE season_metadata (work_id INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
      season_number INTEGER NOT NULL CHECK(season_number >= 0), metadata_json TEXT NOT NULL,
      metadata_language TEXT NOT NULL, metadata_fetched_at INTEGER NOT NULL, PRIMARY KEY(work_id,season_number))''',
    '''CREATE TABLE scan_entries (root_id INTEGER NOT NULL REFERENCES catalog_roots(id) ON DELETE CASCADE,
      generation INTEGER NOT NULL, relative_path TEXT NOT NULL, path_key TEXT NOT NULL,
      parent_path TEXT NOT NULL, name TEXT NOT NULL, media_kind TEXT NOT NULL CHECK(media_kind IN ('video','strm','iso','bdmv')),
      size_bytes INTEGER, modified_at INTEGER, PRIMARY KEY(root_id,generation,path_key))''',
    "CREATE TABLE catalog_settings (id INTEGER PRIMARY KEY CHECK(id = 1), metadata_language TEXT NOT NULL, probe_mode TEXT NOT NULL DEFAULT 'playback' CHECK(probe_mode IN ('playback','full')))",
    "INSERT INTO catalog_settings (id, metadata_language) VALUES (1, 'zh-CN')",
    'CREATE TABLE work_favorites (work_id INTEGER PRIMARY KEY REFERENCES works(id) ON DELETE CASCADE, created_at INTEGER NOT NULL)',
    'CREATE TABLE resource_probes (resource_id INTEGER PRIMARY KEY REFERENCES resources(id) ON DELETE CASCADE, metadata_json TEXT NOT NULL, fetched_at INTEGER NOT NULL)',
    'CREATE TABLE root_covers (root_id INTEGER PRIMARY KEY REFERENCES catalog_roots(id) ON DELETE CASCADE, work_id INTEGER REFERENCES works(id) ON DELETE CASCADE, custom_path TEXT)',
    'CREATE TABLE catalog_preferences (key TEXT PRIMARY KEY, value_json TEXT NOT NULL)',
    'CREATE INDEX resources_work ON resources(work_id,availability)',
    'CREATE INDEX resources_root_state ON resources(root_id,availability)',
    'CREATE INDEX works_title ON works(title)',
  ];
}
