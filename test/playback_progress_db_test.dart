import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/core/constants.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/features/cache_expiration/models/cache_expiration_config.dart';

/// 进度库测试：使用 sqlite3 3.5.0 的 native assets hook 自动解析
/// sqlite3 动态库（Dart 3.12+），无需手工加载 dll。
void main() {
  test('音频与视频可使用相互独立的进度数据库', () async {
    sqfliteFfiInit();
    final factory = databaseFactoryFfi;
    final dir = Directory.systemTemp.createTempSync('progress_isolation_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final video = await PlaybackProgressService.open(
      '${dir.path}${Platform.pathSeparator}video.db',
      factory: factory,
    );
    final audio = await PlaybackProgressService.open(
      '${dir.path}${Platform.pathSeparator}audio.db',
      factory: factory,
    );
    addTearDown(() async {
      await video.close();
      await audio.close();
    });

    await video.saveProgress(url: 'http://h/media.mp3', positionMs: 1000);
    expect(await audio.getProgress('http://h/media.mp3'), isNull);
  });

  late PlaybackProgressService service;
  late DateTime now;
  late CacheExpirationConfig policy;

  setUp(() async {
    now = DateTime.utc(2026, 1, 1);
    policy = CacheExpirationConfig.defaults();
    service = await PlaybackProgressService.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfi,
      now: () => now,
      policyProvider: () => policy,
    );
  });

  tearDown(() => service.close());

  group('PlaybackProgressService 进度 CRUD', () {
    test('保存后按 URL 查询', () async {
      await service.saveProgress(
        url: 'http://host/dav/movie.mp4',
        positionMs: 90000,
        durationMs: 7200000,
      );
      final p = await service.getProgress('http://host/dav/movie.mp4');
      expect(p, isNotNull);
      expect(p!.positionMs, 90000);
      expect(p.durationMs, 7200000);
      expect(p.resumeSeconds, 90); // 90000ms → 90s
    });

    test('重复保存同一 URL 为 upsert（覆盖不新增）', () async {
      await service.saveProgress(
        url: 'http://host/dav/a.mp4',
        positionMs: 1000,
      );
      await service.saveProgress(
        url: 'http://host/dav/a.mp4',
        positionMs: 2000,
      );
      final p = await service.getProgress('http://host/dav/a.mp4');
      expect(p!.positionMs, 2000);
    });

    test('不同 URL 互不干扰', () async {
      await service.saveProgress(url: 'http://host/dav/a.mp4', positionMs: 111);
      await service.saveProgress(url: 'http://host/dav/b.mp4', positionMs: 222);
      expect(
        (await service.getProgress('http://host/dav/a.mp4'))!.positionMs,
        111,
      );
      expect(
        (await service.getProgress('http://host/dav/b.mp4'))!.positionMs,
        222,
      );
    });

    test('无记录返回 null', () async {
      expect(await service.getProgress('http://host/dav/never.mp4'), isNull);
    });

    test('positionMs<=0 时 resumeSeconds 为 null', () async {
      await service.saveProgress(url: 'http://host/dav/z.mp4', positionMs: 0);
      expect(
        (await service.getProgress('http://host/dav/z.mp4'))!.resumeSeconds,
        isNull,
      );
    });

    test('删除完成记录后不再返回旧续播点', () async {
      const url = 'http://host/dav/done.mp4';
      await service.saveProgress(url: url, positionMs: 90000);
      await service.deleteProgress(url);
      expect(await service.getProgress(url), isNull);
    });

    test('超过持久化保留期后不再返回并在读取时清除', () async {
      const url = 'http://host/dav/expired.mp4';
      await service.saveProgress(url: url, positionMs: 90000);

      now = now
          .add(AppConstants.playbackCacheRetention)
          .add(const Duration(milliseconds: 1));
      expect(await service.getProgress(url), isNull);
      expect(await service.purgeExpired(), 0);
    });

    test('保留期边界仍可续播', () async {
      const url = 'http://host/dav/boundary.mp4';
      await service.saveProgress(url: url, positionMs: 30000);

      now = now.add(AppConstants.playbackCacheRetention);
      expect((await service.getProgress(url))?.positionMs, 30000);
    });

    test('设置变更后查询立即使用新的续播保留时间', () async {
      const url = 'http://host/dav/configurable.mp4';
      await service.saveProgress(url: url, positionMs: 45000);
      now = now.add(const Duration(days: 2));

      policy = const CacheExpirationConfig(playbackRetentionDays: 1);
      expect(await service.getProgress(url), isNull);
    });
  });
}
