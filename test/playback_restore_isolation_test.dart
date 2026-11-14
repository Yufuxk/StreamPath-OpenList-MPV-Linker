import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/core/utils/app_paths.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_entry.dart';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/playback_history.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/data/models/video_queue.dart';
import 'package:streampath/domain/services/external_player_service.dart';
import 'package:streampath/domain/services/player_process_controller.dart';
import 'package:streampath/presentation/pages/browser_page.dart';
import 'package:streampath/presentation/state/app_state.dart';

import 'helpers/pump_until.dart';
import 'helpers/shell_test_app_state.dart';

class _CapturePlayer extends ExternalPlayerService {
  _CapturePlayer({
    required super.configStore,
    required super.processController,
  });
  int launches = 0;

  @override
  Future<PlayerLaunchResult> launchLocal({
    required List<MediaEntry> entries,
    required String sourceId,
    String? sessionId,
    int playlistStart = 0,
    int? resumeSeconds,
    List<String?>? localFontDirectories,
    ImplicitVideoPlan? implicitPlan,
    SeasonPlaybackEntries? nextSeason,
  }) async {
    launches++;
    throw AppException.process('Fixture launch captured');
  }
}

void main() {
  for (final hasPid in [false, true]) {
    testWidgets('坏会话工件不阻断页面播放和刷新，保留旧进度 pid=$hasPid', (tester) async {
      final fixture = (await tester.runAsync(() async {
        final temp = await Directory.systemTemp.createTemp(
          'restore_isolation_',
        );
        final root = LocalRootConfig(
          rootId: 'fixture',
          displayName: 'Fixture',
          path: temp.path,
        );
        final video = File(p.join(temp.path, 'Movies', 'one.mkv'));
        await video.parent.create(recursive: true);
        await video.writeAsBytes([0]);
        final config = StreamPathConfigStore.forPath(
          p.join(temp.path, 'config.json'),
        );
        await config.save(
          StreamPathConfig(
            localRoots: [root],
            playerExecutable: 'fixture_mpv.exe',
            subtitleInjectionEnabled: false,
            sharePlaylistFonts: false,
          ),
        );
        final histories = PlaybackHistoryStore.forPath(
          p.join(temp.path, 'history.json'),
        );
        final id = 'restore-isolation-${DateTime.now().microsecondsSinceEpoch}';
        final cache = await AppPaths.cacheDirectory();
        expect(
          p.equals(
            cache.path,
            p.join(Directory.current.path, 'stream_path_data', 'cache'),
          ),
          isFalse,
        );
        final artifact = File(
          p.join(cache.path, 'mpv-season-entries-$id.json'),
        );
        await artifact.writeAsString('{');
        await histories.upsert(
          PlaybackHistory(
            sessionId: id,
            sourceId: root.sourceId,
            dirCrumbs: const ['Movies'],
            fileName: 'one.mkv',
            videoIndex: 0,
            playlistFileNames: const ['one.mkv'],
            playlistRelativePaths: const ['Movies/one.mkv'],
            playerPid: hasPid ? 2147483640 : null,
            updatedAt: DateTime.now(),
          ),
        );
        final progress = await PlaybackProgressService.open(
          p.join(temp.path, 'progress.db'),
        );
        await progress.saveProgress(
          url: video.path,
          profileId: root.sourceId,
          positionMs: 12000,
          durationMs: 60000,
        );
        final player = _CapturePlayer(
          configStore: config,
          processController: PlayerProcessController(
            snapshotLoader: (_) async =>
                const PlayerProcessLookupResult.failed(),
          ),
        );
        final app = ShellTestAppState(
          configStore: config,
          playbackHistoryStore: histories,
          progressService: progress,
          playerService: player,
        );
        return (
          temp,
          root,
          video,
          histories,
          id,
          artifact,
          progress,
          player,
          app,
        );
      }))!;
      final (
        temp,
        root,
        video,
        histories,
        id,
        artifact,
        progress,
        player,
        app,
      ) = fixture;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          player.releaseSession(id);
          app.dispose();
          await app.closeTestStores();
          await progress.close();
          await artifact.delete();
          await temp.delete(recursive: true);
        });
      });
      final key = GlobalKey<BrowserPageState>();
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: app,
          child: MaterialApp(
            home: Scaffold(
              body: BrowserPage(
                key: key,
                localRoot: root,
                initialDirectoryPath: 'Movies',
              ),
            ),
          ),
        ),
      );
      await pumpUntil(
        tester,
        () => player.hasRestoreFailure(id),
        reason: 'Damaged history restoration finishes',
      );
      var played = false;
      await tester.runAsync(() async {
        key.currentState!
            .playLibraryItem(
              MediaLibraryItem(
                sourceId: root.sourceId,
                sourceKind: MediaSourceKind.local,
                parentPath: 'Movies',
                name: 'one.mkv',
                kind: MediaLibraryKind.video,
              ),
            )
            .then((_) => played = true);
      });
      await pumpUntil(
        tester,
        () => played,
        reason: 'Playback entry remains usable',
      );
      expect(player.launches, 1);
      var refreshed = false;
      await tester.runAsync(() async {
        key.currentState!.refreshLibraryPlaybackStatuses().then(
          (_) => refreshed = true,
        );
      });
      await pumpUntil(
        tester,
        () => refreshed,
        reason: 'Status refresh remains usable',
      );
      if (hasPid) expect(find.text('无法确认视频播放器已退出'), findsOneWidget);
      await tester.runAsync(() async {
        expect(
          (await histories.loadAll()).any((h) => h.sessionId == id),
          isTrue,
        );
        expect(
          (await progress.getProgress(
            video.path,
            profileId: root.sourceId,
          ))!.positionMs,
          12000,
        );
        expect(await artifact.readAsString(), '{');
      });
      expect(tester.takeException(), isNull);
    });
  }
}
