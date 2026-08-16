import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/local/audio_playback_history_store.dart';
import 'package:streampath/data/models/audio_playback_history.dart';
import 'package:streampath/features/cache_expiration/models/cache_expiration_config.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('audio_history_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('音频会话保存、更新和删除均独立工作', () async {
    final store = AudioPlaybackHistoryStore.forPath(
      '${tempDir.path}${Platform.pathSeparator}audio.json',
    );
    final createdAt = DateTime(2026);
    final history = AudioPlaybackHistory(
      sessionId: 'audio-1',
      dirCrumbs: const ['音乐', '专辑'],
      fileName: '01.flac',
      trackIndex: 0,
      updatedAt: createdAt,
      createdAt: createdAt,
      playlistFileNames: const ['01.flac', '02.flac'],
    );

    expect(await store.upsert(history), isTrue);
    expect((await store.loadAll()).single.fileName, '01.flac');

    await store.upsert(history.copyWith(fileName: '02.flac', trackIndex: 1));
    final updated = (await store.loadAll()).single;
    expect(updated.fileName, '02.flac');
    expect(updated.trackIndex, 1);

    await store.remove('audio-1');
    expect(await store.loadAll(), isEmpty);
  });

  test('损坏的音频历史只返回空列表', () async {
    final path = '${tempDir.path}${Platform.pathSeparator}broken.json';
    await File(path).writeAsString('{bad json');

    expect(await AudioPlaybackHistoryStore.forPath(path).loadAll(), isEmpty);
  });

  test('过期音频会话自动移除，仍带进程身份的会话不误删', () async {
    final path = '${tempDir.path}${Platform.pathSeparator}expiration.json';
    var now = DateTime.utc(2026, 1, 1);
    const policy = CacheExpirationConfig(playbackRetentionDays: 1);
    final writer = AudioPlaybackHistoryStore.forPath(
      path,
      now: () => now,
      policyProvider: () => policy,
    );
    for (final entry in [
      AudioPlaybackHistory(
        sessionId: 'inactive',
        dirCrumbs: const [],
        fileName: 'inactive.flac',
        trackIndex: 0,
        updatedAt: now,
      ),
      AudioPlaybackHistory(
        sessionId: 'active',
        dirCrumbs: const [],
        fileName: 'active.flac',
        trackIndex: 0,
        updatedAt: now,
        playerPid: 456,
        ipcPipeName: r'\\.\pipe\mpv-audio-active',
      ),
    ]) {
      expect(await writer.upsert(entry), isTrue);
    }

    now = now.add(const Duration(days: 2));
    final reloaded = AudioPlaybackHistoryStore.forPath(
      path,
      now: () => now,
      policyProvider: () => policy,
    );
    final sessions = await reloaded.loadAll();

    expect(sessions.map((item) => item.sessionId), ['active']);
    expect(sessions.single.playerPid, 456);
  });

  test('运行中缩短保留期后，下次读取立即应用新策略', () async {
    final path = '${tempDir.path}${Platform.pathSeparator}dynamic.json';
    var now = DateTime.utc(2026, 1, 1);
    var policy = const CacheExpirationConfig(playbackRetentionDays: 30);
    final store = AudioPlaybackHistoryStore.forPath(
      path,
      now: () => now,
      policyProvider: () => policy,
    );
    await store.upsert(
      AudioPlaybackHistory(
        sessionId: 'dynamic',
        dirCrumbs: const [],
        fileName: 'dynamic.flac',
        trackIndex: 0,
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
