import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../core/errors/app_exception.dart';
import '../../core/utils/app_paths.dart';
import '../models/playback_progress.dart';

/// 播放进度 SQLite 存储（按视频 URL 记录播放位置，支持续播）。
///
/// 桌面平台（Windows/Linux）使用 `sqflite_common_ffi` 实现，
/// 数据库文件位于应用支持目录下的 `streampath.db`；
/// `sqlite3_flutter_libs` 会在构建时自动打包 sqlite3 动态库。
class PlaybackProgressService {
  PlaybackProgressService._(this._db);

  static const _dbFileName = 'streampath.db';
  static const _table = 'playback_progress';

  final Database _db;

  /// 初始化数据库（应用启动时调用一次）。
  ///
  ///  - 桌面平台切换 databaseFactory 为 FFI 实现；
  ///  - 建表（version 1）。
  static Future<PlaybackProgressService> create() async {
    // 桌面（Windows/Linux）无默认实现，必须使用 ffi。
    if (Platform.isWindows || Platform.isLinux) {
      databaseFactory = databaseFactoryFfi;
    }

    final dir = await AppPaths.dataDirectory();
    return open(p.join(dir.path, _dbFileName));
  }

  /// 以指定数据库路径打开（测试可传 `inMemoryDatabasePath` 使用内存库）。
  @visibleForTesting
  static Future<PlaybackProgressService> open(
    String dbPath, {
    DatabaseFactory? factory,
  }) async {
    final f = factory ??
        (Platform.isWindows || Platform.isLinux
            ? databaseFactoryFfi
            : databaseFactory);

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
                'CREATE INDEX idx_progress_updated ON $_table (updated_at)');
          },
        ),
      );
      return PlaybackProgressService._(db);
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
          updatedAt: DateTime.now(),
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
      final rows = await _db.query(
        _table,
        where: 'url = ?',
        whereArgs: [url],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return PlaybackProgress.fromRow(rows.first);
    } on DatabaseException catch (e) {
      throw AppException.storage('读取播放进度失败：$e', e);
    }
  }
}
