import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/domain/services/cache_cleanup_service.dart';
import 'package:streampath/domain/services/iso_playback_service.dart';
import 'package:streampath/presentation/state/app_state.dart';

class _RecordingCacheCleaner implements CacheCleaner {
  bool called = false;

  @override
  Future<CacheCleanupResult> clear() async {
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
}
