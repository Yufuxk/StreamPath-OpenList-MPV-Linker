import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../core/cache/cache_retention_policy.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/app_paths.dart';
import '../models/playback_progress.dart';

/// 播放进度 SQLite 存储（按视频 URL 记录播放位置，支持续播）。
///
/// Windows 使用 `sqflite_common_ffi`，数据库保存在便携 `cache/` 目录；
/// sqlite3 动态库由 `sqlite3` Native Assets 随构建产物打包。
class PlaybackProgressService {
  PlaybackProgressService._(this._db, this._now, this._policyProvider);

  static const _dbFileName = 'streampath.db';
  static const _audioDbFileName = 'audio_streampath.db';
  static const _table = 'playback_progress';

  final Database _db;
  final DateTime Function() _now;
  final CacheRetentionPolicyProvider _policyProvider;

  /// 初始化数据库（应用启动时调用一次）。
  ///
  ///  - 桌面平台切换 databaseFactory 为 FFI 实现；
  ///  - 建表（version 1）。
  static Future<PlaybackProgressService> create({
    CacheRetentionPolicyProvider? policyProvider,
  }) async {
    // 桌面（Windows）无默认实现，必须使用 ffi。
    if (Platform.isWindows) {
      databaseFactory = databaseFactoryFfi;
    }

    final dir = await AppPaths.cacheDirectory(); // streampath.db
    return open(p.join(dir.path, _dbFileName), policyProvider: policyProvider);
  }

  /// 初始化独立的音频进度数据库，避免音频与视频进度文件互相影响。
  static Future<PlaybackProgressService> createAudio({
    CacheRetentionPolicyProvider? policyProvider,
  }) async {
    if (Platform.isWindows) {
      databaseFactory = databaseFactoryFfi;
    }
    final dir = await AppPaths.cacheDirectory();
    return open(
      p.join(dir.path, _audioDbFileName),
      policyProvider: policyProvider,
    );
  }

  /// 以指定数据库路径打开（测试可传 `inMemoryDatabasePath` 使用内存库）。
  @visibleForTesting
  static Future<PlaybackProgressService> open(
    String dbPath, {
    DatabaseFactory? factory,
    DateTime Function()? now,
    CacheRetentionPolicyProvider? policyProvider,
  }) async {
    final f =
        factory ?? (Platform.isWindows ? databaseFactoryFfi : databaseFactory);

    try {
      final db = await f.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) async {
            await db.execute('''
              CREATE TABLE $_table (
                url TEXT PRIMARY KEY,
                position_ms INTEGER NOT NULL,
                duration_ms INTEGER,
                updated_at INTEGER NOT NULL
              )
            ''');
            await db.execute(
              'CREATE INDEX idx_progress_updated ON $_table (updated_at)',
            );
          },
        ),
      );
      final service = PlaybackProgressService._(
        db,
        now ?? DateTime.now,
        policyProvider ?? _defaultPolicyProvider,
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
  }) async {
    try {
      await _db.insert(
        _table,
        PlaybackProgress(
          url: url,
          positionMs: positionMs,
          durationMs: durationMs,
          updatedAt: _now(),
        ).toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } on DatabaseException catch (e) {
      throw AppException.storage('保存播放进度失败：$e', e);
    }
  }

  /// 查询某视频的进度；无记录返回 null。
  Future<PlaybackProgress?> getProgress(String url) async {
    try {
      final cutoff = _expirationCutoffMs();
      final rows = await _db.query(
        _table,
        where: 'url = ? AND updated_at >= ?',
        whereArgs: [url, cutoff],
        limit: 1,
      );
      if (rows.isEmpty) {
        await _db.delete(
          _table,
          where: 'url = ? AND updated_at < ?',
          whereArgs: [url, cutoff],
        );
        return null;
      }
      return PlaybackProgress.fromRow(rows.first);
    } on DatabaseException catch (e) {
      throw AppException.storage('读取播放进度失败：$e', e);
    }
  }

  /// 删除指定媒体的进度记录。
  ///
  /// 自然播放完成或用户明确回到 0 秒时调用，避免旧的正数进度在
  /// `watch_later` 没有生成新记录时继续被当作续播点。
  Future<void> deleteProgress(String url) async {
    try {
      await _db.delete(_table, where: 'url = ?', whereArgs: [url]);
    } on DatabaseException catch (e) {
      throw AppException.storage('删除播放进度失败：$e', e);
    }
  }

  /// 清空全部播放进度，并保持数据库连接可继续使用。
  Future<void> clearAll() async {
    try {
      await _db.delete(_table);
    } on DatabaseException catch (e) {
      throw AppException.storage('清空播放进度失败：$e', e);
    }
  }

  /// 删除超过保留期的播放进度，返回删除数量。
  Future<int> purgeExpired({DateTime? now}) async {
    final cutoff = (now ?? _now()).subtract(retention).millisecondsSinceEpoch;
    try {
      return await _db.delete(
        _table,
        where: 'updated_at < ?',
        whereArgs: [cutoff],
      );
    } on DatabaseException catch (e) {
      throw AppException.storage('清理过期播放进度失败：$e', e);
    }
  }

  Duration get retention => _policyProvider().playbackRetention;

  int _expirationCutoffMs() =>
      _now().subtract(retention).millisecondsSinceEpoch;

  /// 关闭数据库连接。应用退出或测试释放临时数据库时调用。
  Future<void> close() => _db.close();

  static CacheRetentionPolicy _defaultPolicyProvider() =>
      const DefaultCacheRetentionPolicy();
}
