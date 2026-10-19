import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:streampath/core/utils/app_paths.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/data/models/playback_history.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/domain/services/external_player_service.dart';
import 'package:streampath/presentation/pages/browser_page.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'helpers/shell_test_app_state.dart';
import 'helpers/pump_until.dart';

class _BoundaryPlayer extends ExternalPlayerService {
  _BoundaryPlayer({required super.configStore});
  int closed = 0;
  @override
  ExternalPlayerService forFilmLibrary(
    PlaybackProgressService progress,
    Directory watchLater,
  ) => this;
  @override
  Future<bool> isPlayerRunning([String? sessionId]) async => false;
  @override
  Future<bool> closeForFilmBoundary(
    String sessionId, {
    int? expectedPid,
  }) async {
    closed++;
    return true;
  }
}

void main() {
  for (final scenario in [
    (name: 'manual-idle', status: '-1\n\n', prompts: 0),
    (name: 'stale-epoch', status: '-1\n0\nprevious-launch\n', prompts: 0),
    (name: 'owned-eof', status: '-1\n0\ncurrent-launch\n', prompts: 1),
  ]) {
    testWidgets('旧列表跨来源只接受本次自然结束标记 ${scenario.name}', (tester) async {
      late Directory dir;
      late File status;
      late ShellTestAppState app;
      late PlaybackProgressService progress;
      late LocalRootConfig root;
      late _BoundaryPlayer player;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('strict_boundary_');
        root = LocalRootConfig(
          rootId: 'boundary',
          displayName: 'Fixture',
          path: dir.path,
        );
        final config = StreamPathConfigStore.forPath('${dir.path}/config.json');
        await config.save(
          StreamPathConfig(
            localRoots: [root],
            autoSeasonTransitionEnabled: true,
          ),
        );
        player = _BoundaryPlayer(configStore: config);
        progress = await PlaybackProgressService.open(
          '${dir.path}/progress.db',
        );
        app = ShellTestAppState(
          configStore: config,
          playerService: player,
          progressService: progress,
          playbackHistoryStore: PlaybackHistoryStore.forPath(
            '${dir.path}/history.json',
          ),
          mediaLibraryStore: MediaLibraryStore.forPath(
            '${dir.path}/records.json',
          ),
        );
        await app.initializeFilmPlayback();
        final history = PlaybackHistory(
          sessionId: dir.path.split(Platform.pathSeparator).last,
          sourceId: root.sourceId,
          dirCrumbs: const [],
          fileName: 'episode.mkv',
          videoIndex: 0,
          playlistFileNames: const ['episode.mkv'],
          playlistRelativePaths: const ['episode.mkv'],
          updatedAt: DateTime.now().subtract(const Duration(seconds: 5)),
          playerPid: 99999999,
          ipcPipeName: 'fixture-boundary',
          launchEpoch: 'current-launch',
          filmNextItem: const MediaLibraryItem(
            sourceId: 'local:next',
            parentPath: '',
            name: 'next.mkv',
            kind: MediaLibraryKind.video,
          ),
        );
        await app.filmPlaybackHistoryStore.upsert(history);
        status = File(
          '${(await AppPaths.cacheDirectory()).path}/${ExternalPlayerService.sessionStatusFileName(history.sessionId, launchEpoch: history.launchEpoch)}',
        );
        await status.writeAsString(scenario.status);
      });
      var prompts = 0;
      final key = GlobalKey<BrowserPageState>();
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: app,
          child: MaterialApp(
            home: Scaffold(
              body: BrowserPage(
                key: key,
                localRoot: root,
                playbackOnly: true,
                onFilmSourceBoundary: (_) async {
                  prompts++;
                  return null;
                },
              ),
            ),
          ),
        ),
      );
      var refreshed = false;
      await tester.runAsync(() async {
        key.currentState!.refreshLibraryPlaybackStatuses().then(
          (_) => refreshed = true,
        );
      });
      await pumpUntil(
        tester,
        () => refreshed,
        reason: 'Restored boundary history is checked',
      );
      expect(prompts, scenario.prompts);
      expect(player.closed, scenario.prompts);
      if (scenario.prompts == 1) {
        final histories = await tester.runAsync(
          () => app.filmPlaybackHistoryStore.loadAll(),
        );
        expect(histories!.single.filmBoundaryReady, isTrue);
        expect(histories.single.filmBoundaryPrompted, isTrue);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        app.dispose();
        await app.closeTestStores();
        await progress.close();
        if (await status.exists()) await status.delete();
        await dir.delete(recursive: true);
      });
    });
  }
}
