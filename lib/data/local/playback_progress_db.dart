import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../core/cache/cache_retention_policy.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/app_paths.dart';
import '../models/playback_progress.dart';

/// 单条播放进度或整个进度库的变更。
class PlaybackProgressChange {
  const PlaybackProgressChange.url(this.url, {this.profileId = ''});
  const PlaybackProgressChange.all({this.profileId = ''}) : url = null;

  final String? url;
  final String profileId;
  bool get affectsAll => url == null;
}

class DatabaseIntegrityReport {
  const DatabaseIntegrityReport({
    required this.ok,
    required this.messages,
    required this.checkedAt,
  });

  final bool ok;
  final List<String> messages;
  final DateTime checkedAt;
}

class DatabaseMaintenanceResult {
  const DatabaseMaintenanceResult({
    required this.backupPath,
    required this.integrity,
  });

  final String backupPath;
  final DatabaseIntegrityReport integrity;
}

/// 媒体中心读取继续播放进度所需的最小接口。
abstract interface class PlaybackProgressReader {
  void addListener(void Function(PlaybackProgressChange) listener);

  void removeListener(void Function(PlaybackProgressChange) listener);

  Future<PlaybackProgress?> getProgress(String url, {String? profileId});

  Future<PlaybackProgress?> getResumeProgress(String url, {String? profileId});
}

/// 播放进度 SQLite 存储（按视频 URL 记录播放位置，支持续播）。
///
/// Windows 使用 `sqflite_common_ffi`，数据库保存在便携 `cache/` 目录；
/// sqlite3 动态库由 `sqlite3` Native Assets 随构建产物打包。
class PlaybackProgressService implements PlaybackProgressReader {
  PlaybackProgressService._(
    this._db,
    this._dbPath,
    this._now,
    this._policyProvider,
    this._defaultProfileId,
  );

  static const _dbFileName = 'streampath.db';
  static const _audioDbFileName = 'audio_streampath.db';
  static const _table = 'playback_progress';
  static const _temporaryTable = 'temporary_playback_progress';

  final Database _db;
  final String _dbPath;
  final DateTime Function() _now;
  final CacheRetentionPolicyProvider _policyProvider;
  String _defaultProfileId;
  final Set<void Function(PlaybackProgressChange)> _listeners = {};

  /// 监听成功落库的播放进度变更。
  @override
  void addListener(void Function(PlaybackProgressChange) listener) =>
      _listeners.add(listener);

  @override
  void removeListener(void Function(PlaybackProgressChange) listener) =>
      _listeners.remove(listener);

  /// 初始化数据库（应用启动时调用一次）。
  ///
  ///  - 桌面平台切换 databaseFactory 为 FFI 实现；
  ///  - 建表（version 1）。
  static Future<PlaybackProgressService> create({
    CacheRetentionPolicyProvider? policyProvider,
    String legacyProfileId = '',
  }) async {
    // 桌面（Windows）无默认实现，必须使用 ffi。
    if (Platform.isWindows) {
      databaseFactory = databaseFactoryFfi;
    }

    final dir = await AppPaths.cacheDirectory(); // streampath.db
    return open(
      p.join(dir.path, _dbFileName),
      policyProvider: policyProvider,
      legacyProfileId: legacyProfileId,
    );
  }

  /// 初始化独立的音频进度数据库，避免音频与视频进度文件互相影响。
  static Future<PlaybackProgressService> createAudio({
    CacheRetentionPolicyProvider? policyProvider,
    String legacyProfileId = '',
  }) async {
    if (Platform.isWindows) {
      databaseFactory = databaseFactoryFfi;
    }
    final dir = await AppPaths.cacheDirectory();
    return open(
      p.join(dir.path, _audioDbFileName),
      policyProvider: policyProvider,
      legacyProfileId: legacyProfileId,
    );
  }

  /// 以指定数据库路径打开（测试可传 `inMemoryDatabasePath` 使用内存库）。
  @visibleForTesting
  static Future<PlaybackProgressService> open(
    String dbPath, {
    DatabaseFactory? factory,
    DateTime Function()? now,
    CacheRetentionPolicyProvider? policyProvider,
    String legacyProfileId = '',
  }) async {
    final f =
        factory ?? (Platform.isWindows ? databaseFactoryFfi : databaseFactory);

    try {
      final db = await f.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 3,
          onCreate: (db, version) async {
            await _createProgressTable(db);
            await _createTemporaryTable(db);
          },
          onUpgrade: (db, oldVersion, newVersion) async {
            if (oldVersion < 3) {
              await _upgradeToProfileIsolation(
                db,
                oldVersion: oldVersion,
                legacyProfileId: legacyProfileId,
              );
            }
          },
        ),
      );
      final service = PlaybackProgressService._(
        db,
        dbPath,
        now ?? DateTime.now,
        policyProvider ?? _defaultPolicyProvider,
        legacyProfileId,
      );
      try {
        await service.purgeExpired();
      } on AppException {
        // 自动过期失败只保留旧缓存，不阻止播放进度服务启动。
      }
      return service;
    } on DatabaseException catch (e) {
      throw AppException.storage('初始化播放进度数据库失败：$e', e);
    }
  }

  /// 保存/更新进度（upsert，按 URL 主键覆盖）。
  Future<void> saveProgress({
    required String url,
    required int positionMs,
    int? durationMs,
    String? profileId,
  }) async {
    final namespace = _profile(profileId);
    try {
      await _db.insert(_table, {
        'profile_id': namespace,
        ...PlaybackProgress(
          url: url,
          positionMs: positionMs,
          durationMs: durationMs,
          updatedAt: _now(),
        ).toRow(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      _notifyChanged(PlaybackProgressChange.url(url, profileId: namespace));
    } on DatabaseException catch (e) {
      throw AppException.storage('保存播放进度失败：$e', e);
    }
  }

  /// 查询某视频的进度；无记录返回 null。
  @override
  Future<PlaybackProgress?> getProgress(String url, {String? profileId}) async {
    final namespace = _profile(profileId);
    try {
      final cutoff = _expirationCutoffMs();
      final rows = await _db.query(
        _table,
        where: 'profile_id = ? AND url = ? AND updated_at >= ?',
        whereArgs: [namespace, url, cutoff],
        limit: 1,
      );
      if (rows.isEmpty) {
        await _db.delete(
          _table,
          where: 'profile_id = ? AND url = ? AND updated_at < ?',
          whereArgs: [namespace, url, cutoff],
        );
        return null;
      }
      return PlaybackProgress.fromRow(rows.first);
    } on DatabaseException catch (e) {
      throw AppException.storage('读取播放进度失败：$e', e);
    }
  }

  /// 保存缓冲异常时的临时播放点。
  ///
  /// 临时播放点使用独立表，不会被普通退出、watch_later 或 SQLite
  /// 正式进度写入覆盖。
  Future<void> saveTemporaryProgress({
    required String url,
    required int positionMs,
    int? durationMs,
    String? profileId,
  }) async {
    final namespace = _profile(profileId);
    try {
      await _db.insert(_temporaryTable, {
        'profile_id': namespace,
        ...PlaybackProgress(
          url: url,
          positionMs: positionMs,
          durationMs: durationMs,
          updatedAt: _now(),
        ).toRow(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      _notifyChanged(PlaybackProgressChange.url(url, profileId: namespace));
    } on DatabaseException catch (e) {
      throw AppException.storage('保存临时播放点失败：$e', e);
    }
  }

  /// 查询缓冲异常留下的临时播放点。
  Future<PlaybackProgress?> getTemporaryProgress(
    String url, {
    String? profileId,
  }) async {
    final namespace = _profile(profileId);
    try {
      final cutoff = _expirationCutoffMs();
      final rows = await _db.query(
        _temporaryTable,
        where: 'profile_id = ? AND url = ? AND updated_at >= ?',
        whereArgs: [namespace, url, cutoff],
        limit: 1,
      );
      if (rows.isEmpty) {
        await _db.delete(
          _temporaryTable,
          where: 'profile_id = ? AND url = ? AND updated_at < ?',
          whereArgs: [namespace, url, cutoff],
        );
        return null;
      }
      return PlaybackProgress.fromRow(rows.first);
    } on DatabaseException catch (e) {
      throw AppException.storage('读取临时播放点失败：$e', e);
    }
  }

  /// 查询实际续播点；缓冲异常检查点优先于正式播放进度。
  @override
  Future<PlaybackProgress?> getResumeProgress(
    String url, {
    String? profileId,
  }) async =>
      await getTemporaryProgress(url, profileId: profileId) ??
      await getProgress(url, profileId: profileId);

  /// 删除指定媒体的进度记录。
  ///
  /// 自然播放完成或用户明确回到 0 秒时调用，避免旧的正数进度在
  /// `watch_later` 没有生成新记录时继续被当作续播点。
  Future<void> deleteProgress(String url, {String? profileId}) async {
    final namespace = _profile(profileId);
    try {
      final removed = await _db.delete(
        _table,
        where: 'profile_id = ? AND url = ?',
        whereArgs: [namespace, url],
      );
      if (removed > 0) {
        _notifyChanged(PlaybackProgressChange.url(url, profileId: namespace));
      }
    } on DatabaseException catch (e) {
      throw AppException.storage('删除播放进度失败：$e', e);
    }
  }

  /// 删除指定媒体的缓冲临时播放点。
  Future<void> deleteTemporaryProgress(String url, {String? profileId}) async {
    final namespace = _profile(profileId);
    try {
      final removed = await _db.delete(
        _temporaryTable,
        where: 'profile_id = ? AND url = ?',
        whereArgs: [namespace, url],
      );
      if (removed > 0) {
        _notifyChanged(PlaybackProgressChange.url(url, profileId: namespace));
      }
    } on DatabaseException catch (e) {
      throw AppException.storage('删除临时播放点失败：$e', e);
    }
  }

  /// 清空全部播放进度，并保持数据库连接可继续使用。
  Future<void> clearAll() async {
    try {
      await _db.transaction((txn) async {
        await txn.delete(_table);
        await txn.delete(_temporaryTable);
      });
      _notifyChanged(const PlaybackProgressChange.all());
    } on DatabaseException catch (e) {
      throw AppException.storage('清空播放进度失败：$e', e);
    }
  }

  /// 删除超过保留期的播放进度，返回删除数量。
  Future<int> purgeExpired({DateTime? now}) async {
    final cutoff = (now ?? _now()).subtract(retention).millisecondsSinceEpoch;
    try {
      final removed = await _db.transaction((txn) async {
        final formal = await txn.delete(
          _table,
          where: 'updated_at < ?',
          whereArgs: [cutoff],
        );
        final temporary = await txn.delete(
          _temporaryTable,
          where: 'updated_at < ?',
          whereArgs: [cutoff],
        );
        return formal + temporary;
      });
      if (removed > 0) _notifyChanged(const PlaybackProgressChange.all());
      return removed;
    } on DatabaseException catch (e) {
      throw AppException.storage('清理过期播放进度失败：$e', e);
    }
  }

  Duration get retention => _policyProvider().playbackRetention;

  String get databasePath => _dbPath;

  String get defaultProfileId => _defaultProfileId;

  void useProfile(String profileId) {
    _defaultProfileId = profileId;
  }

  Future<DatabaseIntegrityReport> checkIntegrity() async {
    try {
      final rows = await _db.rawQuery('PRAGMA quick_check');
      final messages = rows
          .expand((row) => row.values)
          .whereType<Object>()
          .map((value) => value.toString())
          .toList(growable: false);
      return DatabaseIntegrityReport(
        ok: messages.length == 1 && messages.single.toLowerCase() == 'ok',
        messages: messages,
        checkedAt: _now(),
      );
    } on DatabaseException catch (error) {
      throw AppException.storage('SQLite 完整性检查失败：$error', error);
    }
  }

  /// 先生成 SQLite 一致性备份，再重建索引与统计信息；不删除进度记录。
  Future<DatabaseMaintenanceResult> repairNonDestructive() async {
    final before = await checkIntegrity();
    if (!before.ok) {
      throw AppException.storage('数据库已报告损坏，为避免扩大损失，已停止自动修复');
    }
    if (_dbPath == inMemoryDatabasePath || _dbPath.isEmpty) {
      throw AppException.storage('内存数据库不支持生成维护备份');
    }
    final stamp = _now()
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[^0-9]'), '')
        .substring(0, 14);
    var backupPath = '$_dbPath.maintenance-$stamp.bak';
    for (var suffix = 1; File(backupPath).existsSync(); suffix++) {
      backupPath = '$_dbPath.maintenance-$stamp-$suffix.bak';
    }
    try {
      final escaped = backupPath.replaceAll("'", "''");
      await _db.execute("VACUUM INTO '$escaped'");
      await _db.execute('REINDEX');
      await _db.execute('ANALYZE');
      return DatabaseMaintenanceResult(
        backupPath: backupPath,
        integrity: await checkIntegrity(),
      );
    } on DatabaseException catch (error) {
      throw AppException.storage('SQLite 非破坏性维护失败：$error', error);
    }
  }

  int _expirationCutoffMs() =>
      _now().subtract(retention).millisecondsSinceEpoch;

  String _profile(String? value) => value ?? _defaultProfileId;

  /// 关闭数据库连接。应用退出或测试释放临时数据库时调用。
  Future<void> close() async {
    _listeners.clear();
    await _db.close();
  }

  void _notifyChanged(PlaybackProgressChange change) {
    for (final listener in List<void Function(PlaybackProgressChange)>.of(
      _listeners,
    )) {
      try {
        listener(change);
      } catch (_) {
        // 界面监听异常不能影响进度落库和播放退出同步。
      }
    }
  }

  static CacheRetentionPolicy _defaultPolicyProvider() =>
      const DefaultCacheRetentionPolicy();

  static Future<void> _createTemporaryTable(Database db) async {
    await db.execute('''
      CREATE TABLE $_temporaryTable (
        profile_id TEXT NOT NULL,
        url TEXT NOT NULL,
        position_ms INTEGER NOT NULL,
        duration_ms INTEGER,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (profile_id, url)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_temporary_progress_updated '
      'ON $_temporaryTable (updated_at)',
    );
  }

  static Future<void> _createProgressTable(Database db) async {
    await db.execute('''
      CREATE TABLE $_table (
        profile_id TEXT NOT NULL,
        url TEXT NOT NULL,
        position_ms INTEGER NOT NULL,
        duration_ms INTEGER,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (profile_id, url)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_progress_updated ON $_table (updated_at)',
    );
  }

  static Future<void> _upgradeToProfileIsolation(
    Database db, {
    required int oldVersion,
    required String legacyProfileId,
  }) async {
    await db.execute('ALTER TABLE $_table RENAME TO ${_table}_legacy');
    await db.execute('DROP INDEX IF EXISTS idx_progress_updated');
    await _createProgressTable(db);
    await db.rawInsert(
      'INSERT INTO $_table '
      '(profile_id, url, position_ms, duration_ms, updated_at) '
      'SELECT ?, url, position_ms, duration_ms, updated_at '
      'FROM ${_table}_legacy',
      [legacyProfileId],
    );
    await db.execute('DROP TABLE ${_table}_legacy');

    if (oldVersion >= 2) {
      await db.execute(
        'ALTER TABLE $_temporaryTable RENAME TO ${_temporaryTable}_legacy',
      );
      await db.execute('DROP INDEX IF EXISTS idx_temporary_progress_updated');
      await _createTemporaryTable(db);
      await db.rawInsert(
        'INSERT INTO $_temporaryTable '
        '(profile_id, url, position_ms, duration_ms, updated_at) '
        'SELECT ?, url, position_ms, duration_ms, updated_at '
        'FROM ${_temporaryTable}_legacy',
        [legacyProfileId],
      );
      await db.execute('DROP TABLE ${_temporaryTable}_legacy');
    } else {
      await _createTemporaryTable(db);
    }
  }
}
