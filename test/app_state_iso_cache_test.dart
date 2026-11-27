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
import 'package:streampath/data/models/media_source.dart';
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

  test('从未打开影视库时也检查影视光盘会话身份', () async {
    final config = StreamPathConfigStore.forPath(
      p.join(tempDirectory.path, 'config.json'),
    );
    final root = Directory(p.join(tempDirectory.path, 'iso_temp'));
    final session = await Directory(
      p.join(tempDirectory.path, 'film_iso_temp', 'iso_unknown'),
    ).create(recursive: true);
    await File(p.join(session.path, 'disc.iso')).writeAsBytes([1]);
    await File(
      p.join(session.path, IsoPlaybackService.manifestFileName),
    ).writeAsString(jsonEncode({'version': 1, 'state': 'identity-unknown'}));
    final iso = IsoPlaybackService(
      configStore: config,
      tempRootProvider: () async => root,
    );
    await iso.initialize();
    final cleaner = _RecordingCacheCleaner();
    appState = AppState(
      configStore: config,
      playbackHistoryStore: PlaybackHistoryStore.forPath(
        p.join(tempDirectory.path, 'history.json'),
      ),
      progressService: progressService,
      isoPlaybackService: iso,
      cacheCleaner: cleaner,
    );

    await expectLater(
      appState.clearCache(scope: CacheCleanupScope.playback),
      throwsA(isA<CacheCleanupBlockedException>()),
    );
    expect(cleaner.called, isFalse);
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

  for (final scope in [CacheCleanupScope.playback, CacheCleanupScope.all]) {
    test('$scope 清除两套光盘续播进度，保留选集与媒体中心记录', () async {
      final data = Directory(p.join(tempDirectory.path, 'stream_path_data'));
      final cache = await Directory(
        p.join(data.path, 'cache'),
      ).create(recursive: true);
      final config = StreamPathConfigStore.forPath(
        p.join(data.path, 'config.json'),
      );
      final store = MediaLibraryStore.forPath(
        p.join(data.path, 'library', 'media_library.json'),
      );
      final localDisc = const MediaLibraryItem(
        sourceId: 'local:test',
        sourceKind: MediaSourceKind.local,
        parentPath: '',
        name: 'Local.iso',
        kind: MediaLibraryKind.iso,
        playbackMode: PlaybackMode.localHdmvMenu,
      );
      final localTarget = p.join(data.path, localDisc.name);
      final normal = IsoPlaybackService(
        configStore: config,
        tempRootProvider: () async => Directory(p.join(cache.path, 'iso_temp')),
      );
      appState = AppState(
        configStore: config,
        playbackHistoryStore: PlaybackHistoryStore.forPath(
          p.join(cache.path, 'playback_history.json'),
        ),
        progressService: progressService,
        mediaLibraryStore: store,
        isoPlaybackService: normal,
        cacheCleaner: CacheCleanupService(
          dataDirectoryProvider: () async => data,
          storeClearers: const [],
          preservedCacheNames: const {
            'iso_catalog.json',
            'film_iso_catalog.json',
            'film_iso_progress_migrated',
          },
        ),
      );
      final film = IsoPlaybackService(
        configStore: config,
        progressPrefix: 'film_',
        tempRootProvider: () async =>
            Directory(p.join(cache.path, 'film_iso_temp')),
      );
      addTearDown(film.dispose);
      final marker = File(p.join(cache.path, 'film_iso_progress_migrated'));
      await marker.writeAsString('1');
      final samples = [
        (
          'https://fixture.test/disc.iso',
          PlaybackMode.legacyTitle,
          ['00002', '00001'],
        ),
        ('https://fixture.test/BDMV/', PlaybackMode.webdavHdmvMenu, <String>[]),
        (
          'https://fixture.test/dvd.iso',
          PlaybackMode.legacyTitle,
          ['dvd-title-02', 'dvd-title-01'],
        ),
      ];
      for (final iso in [normal, film]) {
        final files = <String, String>{};
        for (final (url, mode, programmes) in samples) {
          final menu = mode == PlaybackMode.webdavHdmvMenu;
          await iso.planPortableState(
            {
              'selection': {
                'order': programmes,
                'selected': programmes,
                if (!menu) 'lastProgrammeId': programmes.last,
              },
              'titles': {
                if (!menu) programmes.last: {'position': 80, 'duration': 120},
              },
              if (menu)
                'menu': {
                  'position': 80,
                  'duration': 120,
                  'edition': 0,
                  'editions': 1,
                  'completed': false,
                },
            },
            profileId: 'fixture',
            resolvedUrl: url,
            playbackMode: mode,
            files: files,
          );
        }
        for (final entry in files.entries) {
          final file = File(entry.key);
          await file.parent.create(recursive: true);
          await file.writeAsString(entry.value);
        }
      }
      final filmRecords = appState.filmMediaLibraryStore!;
      for (final records in [store, filmRecords]) {
        await records.toggleFavorite(localDisc);
        await records.recordPlayback(
          localDisc,
          playbackSessionId: 'local-disc',
          localDiscSession: LocalDiscSessionSnapshot(
            rootId: 'test',
            relativePath: localDisc.name,
            size: 42,
            modified: DateTime(2026),
            fingerprint: List.filled(64, 'a').join(),
            currentEdition: 1,
            editionCount: 2,
          ),
        );
        await records.importPortable(
          {
            'isoHistory': [
              MediaLibraryRecord(
                item: const MediaLibraryItem(
                  sourceId: 'local:test',
                  sourceKind: MediaSourceKind.local,
                  parentPath: '',
                  name: 'Imported.iso',
                  kind: MediaLibraryKind.iso,
                ),
                updatedAt: DateTime(2026),
                discResumeEdition: 2,
              ).toJson(),
            ],
          },
          {'playback'},
        );
      }
      final filmProgress = await progressService.forFilmLibrary({});
      try {
        for (final db in [progressService, filmProgress]) {
          await db.saveProgress(
            url: localTarget,
            profileId: localDisc.sourceId,
            positionMs: 8000,
          );
          await db.saveTemporaryProgress(
            url: localTarget,
            profileId: localDisc.sourceId,
            positionMs: 9000,
          );
        }
      } finally {
        await filmProgress.close();
      }

      await appState.clearCache(scope: CacheCleanupScope.temporary);
      for (final iso in [normal, film]) {
        for (final (url, mode, _) in samples) {
          expect(
            await iso.getLibraryProgress(
              profileId: 'fixture',
              resolvedUrl: url,
              playbackMode: mode,
            ),
            isNotNull,
          );
        }
      }
      await appState.clearCache(scope: scope);
      for (final iso in [normal, film]) {
        for (final (url, mode, programmes) in samples) {
          final state = await iso.portableState(
            profileId: 'fixture',
            resolvedUrl: url,
            playbackMode: mode,
          );
          expect(state['titles'], isEmpty);
          expect(state['menu'], isNull);
          final selection = state['selection'] as Map;
          expect(selection['order'], programmes);
          expect(selection['selected'], programmes);
          expect(selection.containsKey('lastProgrammeId'), isFalse);
          expect(selection.containsKey('lastMplsId'), isFalse);
        }
      }
      expect(await marker.exists(), isTrue);
      for (final records in [store, filmRecords]) {
        expect(await records.favorites(localDisc.sourceId), hasLength(1));
        final history = await records.playbackHistory(
          localDisc.sourceId,
          audio: false,
          iso: true,
        );
        expect(history, hasLength(2));
        expect(
          history.every((record) => record.discResumeEdition == null),
          isTrue,
        );
        final record = history.singleWhere(
          (record) => record.item.name == localDisc.name,
        );
        expect(record.playbackSessionId, 'local-disc');
        expect(record.localDiscSession?.relativePath, localDisc.name);
        expect(record.localDiscSession?.currentEdition, isNull);
      }
      for (final db in [progressService, appState.filmProgressService]) {
        expect(
          await db.getResumeProgress(
            localTarget,
            profileId: localDisc.sourceId,
          ),
          isNull,
        );
      }
    });
  }
}
