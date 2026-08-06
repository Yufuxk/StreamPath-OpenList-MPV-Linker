import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/playback_progress_db.dart';

/// 进度库测试：使用 sqlite3 3.5.0 的 native assets hook 自动解析
/// sqlite3 动态库（Dart 3.12+），无需手工加载 dll。
void main() {
  late PlaybackProgressService service;

  setUp(() async {
    service = await PlaybackProgressService.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
  });

  group('PlaybackProgressService 进度 CRUD', () {
    test('保存后按 URL 查询', () async {
      await service.saveProgress(
          url: 'http://host/dav/movie.mp4', positionMs: 90000, durationMs: 7200000);
      final p = await service.getProgress('http://host/dav/movie.mp4');
      expect(p, isNotNull);
      expect(p!.positionMs, 90000);
      expect(p.durationMs, 7200000);
      expect(p.resumeSeconds, 90); // 90000ms → 90s
    });

    test('重复保存同一 URL 为 upsert（覆盖不新增）', () async {
      await service.saveProgress(url: 'http://host/dav/a.mp4', positionMs: 1000);
      await service.saveProgress(url: 'http://host/dav/a.mp4', positionMs: 2000);
      final p = await service.getProgress('http://host/dav/a.mp4');
      expect(p!.positionMs, 2000);
    });

    test('不同 URL 互不干扰', () async {
      await service.saveProgress(url: 'http://host/dav/a.mp4', positionMs: 111);
      await service.saveProgress(url: 'http://host/dav/b.mp4', positionMs: 222);
      expect((await service.getProgress('http://host/dav/a.mp4'))!.positionMs, 111);
      expect((await service.getProgress('http://host/dav/b.mp4'))!.positionMs, 222);
    });

    test('无记录返回 null', () async {
      expect(await service.getProgress('http://host/dav/never.mp4'), isNull);
    });

    test('positionMs<=0 时 resumeSeconds 为 null', () async {
      await service.saveProgress(url: 'http://host/dav/z.mp4', positionMs: 0);
      expect((await service.getProgress('http://host/dav/z.mp4'))!.resumeSeconds, isNull);
    });
  });
}
