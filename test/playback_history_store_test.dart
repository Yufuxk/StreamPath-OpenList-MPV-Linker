import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/core/constants.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/models/playback_history.dart';
import 'package:streampath/features/cache_expiration/models/cache_expiration_config.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ph_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('保存后读取一致（目录/文件名/索引/时间）', () async {
    final store = PlaybackHistoryStore.forPath(
      '${tempDir.path}${Platform.pathSeparator}history.json',
    );
    await store.upsert(
      PlaybackHistory(
        dirCrumbs: const ['动漫', '2024秋'],
        fileName: 'AIR S01E02.mkv',
        videoIndex: 1,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
        playerPid: 123,
        playerExecutablePath: r'C:\MPV\mpv.exe',
        playerCreationTime: 133700000000000000,
      ),
    );
    final loaded = await store.loadAll();
    expect(loaded, hasLength(1));
    expect(loaded.first.dirCrumbs, ['动漫', '2024秋']);
    expect(loaded.first.fileName, 'AIR S01E02.mkv');
    expect(loaded.first.videoIndex, 1);
    expect(loaded.first.playerPid, 123);
    expect(loaded.first.playerExecutablePath, r'C:\MPV\mpv.exe');
    expect(loaded.first.playerCreationTime, 133700000000000000);
    expect(
      loaded.first.updatedAt.isAfter(DateTime.fromMillisecondsSinceEpoch(0)),
      isTrue,
      reason: '保存时自动更新为当前时间',
    );
  });

  test('旧视频历史缺少完整进程身份时保持为空且不会伪造', () {
    final history = PlaybackHistory.fromJson(<String, dynamic>{
      'sessionId': 'legacy-process',
      'fileName': 'old.mkv',
      'playerPid': 456,
      'ipcPipeName': r'\\.\pipe\old-mpv',
    });

    expect(history.playerPid, 456);
    expect(history.playerExecutablePath, isNull);
    expect(history.playerCreationTime, isNull);
  });

  test('文件不存在时返回 null', () async {
    final store = PlaybackHistoryStore.forPath(
      '${tempDir.path}${Platform.pathSeparator}none.json',
    );
    expect(await store.loadAll(), isEmpty);
  });

  test('损坏文件返回空列表（不抛异常）', () async {
    final path = '${tempDir.path}${Platform.pathSeparator}broken.json';
    File(path).writeAsStringSync('{not valid');
    final store = PlaybackHistoryStore.forPath(path);
    expect(await store.loadAll(), isEmpty);
  });

  test('重复保存覆盖旧记录（内存缓存一致）', () async {
    final store = PlaybackHistoryStore.forPath(
      '${tempDir.path}${Platform.pathSeparator}update.json',
    );
    await store.upsert(
      PlaybackHistory(
        dirCrumbs: ['a'],
        fileName: '1.mkv',
        videoIndex: 0,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      ),
    );
    await store.upsert(
      PlaybackHistory(
        dirCrumbs: ['b'],
        fileName: '2.mkv',
        videoIndex: 2,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      ),
    );
    final loaded = await store.loadAll();
    expect(loaded.last.fileName, '2.mkv');
    expect(loaded.last.dirCrumbs, ['b']);
  });

  test('remove 删除文件并清空缓存（播完最后一个视频后调用）', () async {
    final path = '${tempDir.path}${Platform.pathSeparator}clear.json';
    final store = PlaybackHistoryStore.forPath(path);
    await store.upsert(
      PlaybackHistory(
        sessionId: 'only',
        dirCrumbs: const ['动漫', '2024秋'],
        fileName: 'S01E12.mkv',
        videoIndex: 11,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      ),
    );
    expect(await store.loadAll(), hasLength(1));

    await store.remove('only');

    expect(await store.loadAll(), isEmpty, reason: '缓存已清空');
    expect(File(path).existsSync(), isFalse, reason: '历史文件已删除');
    // 再次保存后仍可正常记录（功能可复用）。
    await store.upsert(
      PlaybackHistory(
        dirCrumbs: const ['新目录'],
        fileName: 'new.mkv',
        videoIndex: 0,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      ),
    );
    final reloaded = await store.loadAll();
    expect(reloaded.single.fileName, 'new.mkv');
  });

  test('两个播放会话按创建时间保存，更新其中一个不会覆盖另一个', () async {
    final path = '${tempDir.path}${Platform.pathSeparator}multi.json';
    final store = PlaybackHistoryStore.forPath(path);
    final later = DateTime(2026, 1, 2);
    final earlier = DateTime(2026, 1, 1);

    expect(
      await store.upsert(
        PlaybackHistory(
          sessionId: 'later',
          dirCrumbs: const ['剧集'],
          fileName: 'S01E02.mkv',
          videoIndex: 1,
          updatedAt: later,
          createdAt: later,
        ),
      ),
      isTrue,
    );
    expect(
      await store.upsert(
        PlaybackHistory(
          sessionId: 'earlier',
          dirCrumbs: const ['电影'],
          fileName: 'movie.mkv',
          videoIndex: 0,
          updatedAt: earlier,
          createdAt: earlier,
        ),
      ),
      isTrue,
    );

    expect((await store.loadAll()).map((e) => e.sessionId), [
      'earlier',
      'later',
    ]);

    await store.upsert(
      PlaybackHistory(
        sessionId: 'later',
        dirCrumbs: const ['剧集'],
        fileName: 'S01E03.mkv',
        videoIndex: 2,
        updatedAt: later,
        createdAt: later,
      ),
    );
    final all = await store.loadAll();
    expect(all, hasLength(2));
    expect(all.first.fileName, 'movie.mkv');
    expect(all.last.fileName, 'S01E03.mkv');

    final json = jsonDecode(await File(path).readAsString());
    expect(json['version'], 2);
    expect(json['sessions'], hasLength(2));
  });

  test('删除一个会话只清理目标记录', () async {
    final path = '${tempDir.path}${Platform.pathSeparator}remove.json';
    final store = PlaybackHistoryStore.forPath(path);
    for (final id in ['one', 'two']) {
      await store.upsert(
        PlaybackHistory(
          sessionId: id,
          dirCrumbs: const [],
          fileName: '$id.mkv',
          videoIndex: 0,
          updatedAt: DateTime(2026),
          createdAt: DateTime(2026),
        ),
      );
    }

    await store.remove('one');

    final all = await store.loadAll();
    expect(all, hasLength(1));
    expect(all.single.sessionId, 'two');
  });

  test('达到播放会话上限后拒绝第三个新会话', () async {
    final store = PlaybackHistoryStore.forPath(
      '${tempDir.path}${Platform.pathSeparator}limit.json',
    );
    for (var i = 0; i < AppConstants.maxPlaybackSessions; i++) {
      expect(
        await store.upsert(
          PlaybackHistory(
            sessionId: 'session-$i',
            dirCrumbs: const [],
            fileName: '$i.mkv',
            videoIndex: 0,
            updatedAt: DateTime(2026),
            createdAt: DateTime(2026, 1, i + 1),
          ),
        ),
        isTrue,
      );
    }

    expect(
      await store.upsert(
        PlaybackHistory(
          sessionId: 'overflow',
          dirCrumbs: const [],
          fileName: 'overflow.mkv',
          videoIndex: 0,
          updatedAt: DateTime(2026),
          createdAt: DateTime(2026, 2),
        ),
      ),
      isFalse,
    );
    expect(await store.loadAll(), hasLength(AppConstants.maxPlaybackSessions));
  });

  test('两个会话并发更新时不会互相覆盖', () async {
    final path = '${tempDir.path}${Platform.pathSeparator}concurrent.json';
    final store = PlaybackHistoryStore.forPath(path);
    final createdAt = DateTime(2026);
    for (final id in const ['one', 'two']) {
      await store.upsert(
        PlaybackHistory(
          sessionId: id,
          dirCrumbs: const [],
          fileName: '$id-old.mkv',
          videoIndex: 0,
          updatedAt: createdAt,
          createdAt: createdAt,
        ),
      );
    }

    await Future.wait([
      store.upsert(
        PlaybackHistory(
          sessionId: 'one',
          dirCrumbs: const [],
          fileName: 'one-new.mkv',
          videoIndex: 1,
          updatedAt: createdAt,
          createdAt: createdAt,
        ),
      ),
      store.upsert(
        PlaybackHistory(
          sessionId: 'two',
          dirCrumbs: const [],
          fileName: 'two-new.mkv',
          videoIndex: 2,
          updatedAt: createdAt,
          createdAt: createdAt,
        ),
      ),
    ]);

    final reloaded = PlaybackHistoryStore.forPath(path);
    final sessions = await reloaded.loadAll();
    expect(sessions, hasLength(2));
    expect(
      sessions.firstWhere((item) => item.sessionId == 'one').fileName,
      'one-new.mkv',
    );
    expect(
      sessions.firstWhere((item) => item.sessionId == 'two').fileName,
      'two-new.mkv',
    );
  });

  test('旧版单对象记录可作为 legacy 会话读取', () async {
    final path = '${tempDir.path}${Platform.pathSeparator}legacy.json';
    await File(path).writeAsString(
      jsonEncode({
        'dirCrumbs': ['旧目录'],
        'fileName': 'legacy.mkv',
        'videoIndex': 3,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      }),
    );

    final store = PlaybackHistoryStore.forPath(path);
    final all = await store.loadAll();

    expect(all, hasLength(1));
    expect(all.single.sessionId, 'legacy');
    expect(all.single.fileName, 'legacy.mkv');
  });

  test('过期的非活动会话自动移除，带进程身份的会话保留', () async {
    final path = '${tempDir.path}${Platform.pathSeparator}expiration.json';
    var now = DateTime.utc(2026, 1, 1);
    const policy = CacheExpirationConfig(playbackRetentionDays: 1);
    final writer = PlaybackHistoryStore.forPath(
      path,
      now: () => now,
      policyProvider: () => policy,
    );
    await writer.upsert(
      PlaybackHistory(
        sessionId: 'inactive',
        dirCrumbs: const [],
        fileName: 'inactive.mkv',
        videoIndex: 0,
        updatedAt: now,
      ),
    );
    await writer.upsert(
      PlaybackHistory(
        sessionId: 'active',
        dirCrumbs: const [],
        fileName: 'active.mkv',
        videoIndex: 0,
        updatedAt: now,
        playerPid: 123,
        ipcPipeName: r'\\.\pipe\mpv-active',
      ),
    );

    now = now.add(const Duration(days: 2));
    final reloaded = PlaybackHistoryStore.forPath(
      path,
      now: () => now,
      policyProvider: () => policy,
    );
    final sessions = await reloaded.loadAll();

    expect(sessions.map((item) => item.sessionId), ['active']);
    expect(sessions.single.playerPid, 123);
  });

  test('运行中缩短保留期后，下次读取立即应用新策略', () async {
    final path = '${tempDir.path}${Platform.pathSeparator}dynamic.json';
    var now = DateTime.utc(2026, 1, 1);
    var policy = const CacheExpirationConfig(playbackRetentionDays: 30);
    final store = PlaybackHistoryStore.forPath(
      path,
      now: () => now,
      policyProvider: () => policy,
    );
    await store.upsert(
      PlaybackHistory(
        sessionId: 'dynamic',
        dirCrumbs: const [],
        fileName: 'dynamic.mkv',
        videoIndex: 0,
        updatedAt: now,
      ),
    );

    now = now.add(const Duration(days: 2));
    expect(await store.loadAll(), hasLength(1));
    policy = const CacheExpirationConfig(playbackRetentionDays: 1);

    expect(await store.loadAll(), isEmpty);
    expect(File(path).existsSync(), isFalse);
  });
}
