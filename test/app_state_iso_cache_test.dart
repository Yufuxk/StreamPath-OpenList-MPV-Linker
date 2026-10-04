import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/core/utils/url_utils.dart';
import 'package:streampath/domain/services/cache_cleanup_service.dart';
import 'package:streampath/domain/services/iso_playback_service.dart';
import 'package:streampath/presentation/state/app_state.dart';

class _RecordingCacheCleaner implements CacheCleaner {
  bool called = false;

  @override
  Future<CacheCleanupResult> clear({
    CacheCleanupScope scope = CacheCleanupScope.all,
  }) async {
    called = true;
    return const CacheCleanupResult(
      cacheDirectory: 'test-cache',
      deletedEntries: 0,
      clearedStores: 0,
    );
  }
}

void main() {
  late Directory tempDirectory;
  late PlaybackProgressService progressService;
  late AppState appState;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'streampath_app_state_iso_',
    );
    progressService = await PlaybackProgressService.open(
      p.join(tempDirectory.path, 'progress.db'),
      factory: databaseFactoryFfi,
    );
  });

  tearDown(() async {
    appState.dispose();
    await progressService.close();
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('普通缓存清理受 ISO 状态保护，学习数据清理保持解耦', () async {
    final configStore = StreamPathConfigStore.forPath(
      p.join(tempDirectory.path, 'config.json'),
    );
    final isoRoot = Directory(p.join(tempDirectory.path, 'iso_temp'));
    final session = Directory(p.join(isoRoot.path, 'iso_unknown'));
    await session.create(recursive: true);
    await File(p.join(session.path, 'disc.iso')).writeAsBytes(const [1]);
    await File(
      p.join(session.path, IsoPlaybackService.manifestFileName),
    ).writeAsString(jsonEncode({'version': 1, 'state': 'identity-unknown'}));
    final isoService = IsoPlaybackService(
      configStore: configStore,
      tempRootProvider: () async => isoRoot,
    );
    await isoService.initialize();
    final cacheCleaner = _RecordingCacheCleaner();
    final learningCleaner = _RecordingCacheCleaner();
    appState = AppState(
      configStore: configStore,
      playbackHistoryStore: PlaybackHistoryStore.forPath(
        p.join(tempDirectory.path, 'history.json'),
      ),
      progressService: progressService,
      cacheCleaner: cacheCleaner,
      learningDataCleaner: learningCleaner,
      isoPlaybackService: isoService,
    );

    await expectLater(
      appState.clearCache(),
      throwsA(
        isA<CacheCleanupBlockedException>().having(
          (error) => error.message,
          'message',
          contains('ISO 播放器'),
        ),
      ),
    );
    expect(cacheCleaner.called, isFalse);

    await appState.clearLearningData();
    expect(learningCleaner.called, isTrue);
  });

  test('全部清理保留媒体中心引用的正式及临时进度与 STRM 记录', () async {
    final config = StreamPathConfigStore.forPath(
      p.join(tempDirectory.path, 'config.json'),
    );
    await config.save(
      const StreamPathConfig(
        serverUrl: 'http://fixture.test/dav',
        username: 'test',
      ),
    );
    final store = MediaLibraryStore.forPath(
      p.join(tempDirectory.path, 'media_library.json'),
    );
    final item = MediaLibraryItem(
      sourceId: config.current.profileId,
      parentPath: 'Movies',
      name: 'kept.mkv',
      kind: MediaLibraryKind.video,
    );
    final strm = MediaLibraryItem(
      sourceId: item.sourceId,
      parentPath: 'Movies',
      name: 'kept.strm',
      kind: MediaLibraryKind.strm,
    );
    for (final records in [store, store.forFilmLibrary()]) {
      await records.recordPlayback(item);
      await records.toggleFavorite(item);
      await records.recordPlayback(
        strm,
        playbackSessionId: 'strm-session',
        playlistIndex: 0,
      );
      await records.updateStrmProgress(
        sourceId: item.sourceId,
        playbackSessionId: 'strm-session',
        fileName: strm.name,
        playlistIndex: 0,
        positionMs: 12000,
        durationMs: 90000,
      );
    }
    final url = joinUrl(config.current.serverUrl, item.targetPath);
    final orphan = joinUrl(config.current.serverUrl, 'Movies/orphan.mkv');
    await progressService.saveProgress(
      url: url,
      profileId: item.sourceId,
      positionMs: 8000,
    );
    await progressService.saveTemporaryProgress(
      url: url,
      profileId: item.sourceId,
      positionMs: 10000,
    );
    await progressService.saveProgress(
      url: orphan,
      profileId: item.sourceId,
      positionMs: 8000,
    );
    await progressService.saveTemporaryProgress(
      url: orphan,
      profileId: item.sourceId,
      positionMs: 10000,
    );
    appState = AppState(
      configStore: config,
      playbackHistoryStore: PlaybackHistoryStore.forPath(
        p.join(tempDirectory.path, 'history.json'),
      ),
      progressService: progressService,
      mediaLibraryStore: store,
      cacheCleaner: _RecordingCacheCleaner(),
    );
    for (final scope in [
      CacheCleanupScope.directory,
      CacheCleanupScope.metadata,
      CacheCleanupScope.temporary,
    ]) {
      await appState.clearCache(scope: scope);
      expect(
        await progressService.getProgress(orphan, profileId: item.sourceId),
        isNotNull,
      );
    }
    await appState.clearCache();
    expect(
      (await progressService.getProgress(
        url,
        profileId: item.sourceId,
      ))!.positionMs,
      8000,
    );
    expect(
      (await progressService.getTemporaryProgress(
        url,
        profileId: item.sourceId,
      ))!.positionMs,
      10000,
    );
    expect(
      await progressService.getProgress(orphan, profileId: item.sourceId),
      isNull,
    );
    expect(
      await progressService.getTemporaryProgress(
        orphan,
        profileId: item.sourceId,
      ),
      isNull,
    );
    for (final records in [store, appState.filmMediaLibraryStore!]) {
      expect(await records.favorites(item.sourceId), hasLength(1));
      final history = await records.playbackHistory(
        item.sourceId,
        audio: false,
      );
      expect(history, hasLength(2));
      expect(
        history
            .firstWhere((r) => r.item.kind == MediaLibraryKind.strm)
            .strmPositionMs,
        12000,
      );
    }
  });
}
