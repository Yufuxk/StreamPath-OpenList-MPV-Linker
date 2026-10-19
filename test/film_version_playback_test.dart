import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/film_version.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_entry.dart';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/data/models/video_playlist_mode.dart';
import 'package:streampath/data/models/video_queue.dart';
import 'package:streampath/domain/services/external_player_service.dart';
import 'package:streampath/domain/services/film_version_resolver.dart';
import 'package:streampath/presentation/pages/browser_page.dart';
import 'package:streampath/presentation/pages/film_library_shell.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'helpers/shell_test_app_state.dart';
import 'helpers/pump_until.dart';

Future<void> settlePlayback(WidgetTester tester) async {
  for (var i = 0; i < 18; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

class _VersionPlayer extends ExternalPlayerService {
  _VersionPlayer({required super.configStore});
  final events = <String>[];
  final plans = <ImplicitVideoPlan?>[];
  final entries = <List<MediaEntry>>[];
  bool canClose = true;
  @override
  ExternalPlayerService forFilmLibrary(
    PlaybackProgressService progress,
    Directory watchLater,
  ) => this;
  @override
  Future<bool> closeForFilmBoundary(
    String sessionId, {
    int? expectedPid,
  }) async {
    events.add('close');
    return canClose;
  }

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
    events.add('launch:$sourceId');
    plans.add(implicitPlan);
    this.entries.add(entries);
    throw AppException.process('Fixture player launch captured');
  }
}

void main() {
  for (final mode in VideoPlaylistMode.values) {
    testWidgets('严格版本起播遵循快照且不混入其他版本 mode=$mode', (tester) async {
      late Directory dir;
      late ShellTestAppState app;
      late _VersionPlayer player;
      late PlaybackProgressService progress;
      late LocalRootConfig root;
      late MediaLibraryItem item;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('version_playback_');
        root = LocalRootConfig(
          rootId: 'one',
          displayName: 'One',
          path: dir.path,
        );
        final config = StreamPathConfigStore.forPath('${dir.path}/config.json');
        await config.save(
          StreamPathConfig(
            localRoots: [root],
            playerExecutable: 'fixture_mpv.exe',
            videoPlaylistMode: mode,
            subtitleInjectionEnabled: false,
            sharePlaylistFonts: false,
          ),
        );
        player = _VersionPlayer(configStore: config);
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
        final store = await app.getFilmCatalogStore();
        final id = await store.addRoot(
          sourceId: root.sourceId,
          kind: MediaSourceKind.local,
          path: 'TV',
          type: FilmMediaType.tv,
          name: 'One',
        );
        final catalogRoot = (await store.root(id))!;
        final generation = await store.beginScan(id);
        final paths = [
          'TV/A/S01/E1.mkv',
          'TV/A/S01/E3.mkv',
          'TV/B/S01/E1.mkv',
          'TV/B/S01/E2.mkv',
        ];
        for (final path in paths) {
          final file = File('${dir.path}/$path');
          await file.parent.create(recursive: true);
          await file.writeAsBytes([0]);
        }
        await store.stage(catalogRoot, generation, [
          for (final path in paths)
            FilmScanEntry(
              path: path,
              parentPath: path.substring(0, path.lastIndexOf('/')),
              name: path.split('/').last,
              mediaKind: 'video',
            ),
        ]);
        await store.commitScan(id, generation, cancelled: () => false);
        await store.bind(
          await store.resources(),
          const FilmWork(
            type: FilmMediaType.tv,
            tmdbId: 17,
            title: 'Show',
            originalTitle: 'Show',
            overview: '',
            language: 'en',
          ),
        );
        final rows = await store.resources();
        await store.mapEpisodes({
          for (final r in rows) r: (1, int.parse(r.name[1])),
        });
        final resources = await store.resources();
        final index = FilmVersionIndex(resources);
        final first = resources.firstWhere(
          (r) => r.path.contains('/A/') && r.episode == 1,
        );
        item = first.playbackItem.withFilmVersion(
          FilmPlaybackContext(
            workId: first.workId!,
            identity: 'tmdb:tv:17',
            selection: FilmVersionSelection(
              defaultKey: index.resourceKeys[first.id]!,
            ),
          ),
        );
      });
      await tester.runAsync(app.initializeFilmPlayback);
      final key = GlobalKey<BrowserPageState>();
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: app,
          child: MaterialApp(
            home: Scaffold(
              body: BrowserPage(key: key, localRoot: root, playbackOnly: true),
            ),
          ),
        ),
      );
      await settlePlayback(tester);
      var done = false;
      await tester.runAsync(() async {
        key.currentState!.playLibraryItem(item).then((_) => done = true);
      });
      await pumpUntil(
        tester,
        () => done,
        reason: 'Version queue launch completes',
      );
      expect(player.events, ['launch:local:one']);
      if (mode == VideoPlaylistMode.implicit) {
        expect(player.plans.single!.items.map((i) => i.episode), [1, 3]);
        expect(
          player.plans.single!.items
              .expand((i) => i.versions)
              .every((v) => v.path.contains('/A/')),
          isTrue,
        );
      } else {
        expect(
          player.entries.single.map(
            (e) => e.url.replaceAll('\\', '/').split('/').last,
          ),
          ['E1.mkv', 'E3.mkv'],
        );
        expect(
          player.entries.single.every(
            (e) => e.url.replaceAll('\\', '/').contains('/A/'),
          ),
          isTrue,
        );
      }
      final histories = await tester.runAsync(
        () => app.filmPlaybackHistoryStore.loadAll(),
      );
      expect(
        histories!.single.filmVersionContext!.signature,
        item.filmVersionContext!.signature,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        app.dispose();
        await app.closeTestStores();
        await progress.close();
        await dir.delete(recursive: true);
      });
    });
  }

  for (final canClose in [true, false]) {
    testWidgets('跨来源自然完成先退出再激活并提示，拒绝退出不提示 close=$canClose', (tester) async {
      late Directory dir;
      late ShellTestAppState app;
      late _VersionPlayer player;
      late PlaybackProgressService progress;
      late MediaLibraryItem first;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('version_boundary_');
        final roots = [
          for (final id in ['one', 'two'])
            LocalRootConfig(
              rootId: id,
              displayName: id,
              path: '${dir.path}/$id',
            ),
        ];
        final config = StreamPathConfigStore.forPath('${dir.path}/config.json');
        await config.save(
          StreamPathConfig(
            localRoots: roots,
            playerExecutable: 'fixture_mpv.exe',
            autoSeasonTransitionEnabled: true,
            videoPlaylistMode: VideoPlaylistMode.implicit,
            subtitleInjectionEnabled: false,
            sharePlaylistFonts: false,
          ),
        );
        player = _VersionPlayer(configStore: config)..canClose = canClose;
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
        final store = await app.getFilmCatalogStore();
        for (var i = 0; i < roots.length; i++) {
          final id = await store.addRoot(
            sourceId: roots[i].sourceId,
            kind: MediaSourceKind.local,
            path: 'TV',
            type: FilmMediaType.tv,
            name: roots[i].displayName,
          );
          final root = (await store.root(id))!;
          final path = 'TV/Show/S0${i + 1}/E1.mkv';
          final file = File('${roots[i].path}/$path');
          await file.parent.create(recursive: true);
          await file.writeAsBytes([0]);
          final generation = await store.beginScan(id);
          await store.stage(root, generation, [
            FilmScanEntry(
              path: path,
              parentPath: path.substring(0, path.lastIndexOf('/')),
              name: 'E1.mkv',
              mediaKind: 'video',
            ),
          ]);
          await store.commitScan(id, generation, cancelled: () => false);
        }
        await store.bind(
          await store.resources(),
          const FilmWork(
            type: FilmMediaType.tv,
            tmdbId: 18,
            title: 'Show',
            originalTitle: 'Show',
            overview: '',
            language: 'en',
          ),
        );
        var rows = await store.resources();
        await store.mapEpisodes({rows[0]: (1, 1), rows[1]: (2, 1)});
        rows = await store.resources();
        final index = FilmVersionIndex(rows);
        first = rows.first.playbackItem.withFilmVersion(
          FilmPlaybackContext(
            workId: rows.first.workId!,
            identity: 'tmdb:tv:18',
            selection: FilmVersionSelection(
              defaultKey: index.resourceKeys[rows.first.id]!,
              seasons: {2: index.resourceKeys[rows.last.id]!},
            ),
          ),
        );
      });
      const channel = MethodChannel('streampath/appearance');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'activate') {
          player.events.add('activate');
          return true;
        }
        return null;
      });
      final key = GlobalKey<FilmLibraryShellState>();
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: app,
          child: MaterialApp(home: FilmLibraryShell(key: key)),
        ),
      );
      await settlePlayback(tester);
      var started = false;
      await tester.runAsync(() async {
        key.currentState!.play(first).then((_) => started = true);
      });
      await pumpUntil(
        tester,
        () => started,
        reason: 'Initial source launch captured',
      );
      expect(player.plans.single!.completed, isNotNull);
      expect(player.events, ['launch:local:one']);
      var checked = false;
      await tester.runAsync(() async {
        key.currentState!.refreshPlaybackStatuses().then((_) => checked = true);
      });
      await pumpUntil(
        tester,
        () => checked,
        reason: 'Stopped playback does not prompt for the next source',
      );
      expect(player.events, ['launch:local:one']);
      await tester.runAsync(() => player.plans.single!.completed!());
      Future<void>? refresh;
      await tester.runAsync(() async {
        refresh = key.currentState!.refreshPlaybackStatuses();
      });
      if (canClose) {
        await pumpUntil(
          tester,
          () => find.text('稍后播放').evaluate().isNotEmpty,
          reason: 'Main app shows boundary decision',
        );
        expect(player.events, ['launch:local:one', 'close', 'activate']);
        await tester.tap(find.text('稍后播放'));
        await settlePlayback(tester);
        await tester.runAsync(() => refresh!);
        expect(player.plans, hasLength(1));
        var refreshed = false;
        await tester.runAsync(() async {
          key.currentState!.refreshPlaybackStatuses().then(
            (_) => refreshed = true,
          );
        });
        await pumpUntil(
          tester,
          () => refreshed,
          reason: 'Boundary is not prompted twice',
        );
        expect(find.text('稍后播放'), findsNothing);
        final histories = await tester.runAsync(
          () => app.filmPlaybackHistoryStore.loadAll(),
        );
        expect(histories!.single.filmBoundaryReady, isTrue);
        expect(histories.single.filmBoundaryPrompted, isTrue);
        var resumed = false;
        await tester.runAsync(() async {
          key.currentState!
              .continuePlaying(
                MediaLibraryRecord(
                  item: first,
                  updatedAt: DateTime.now(),
                  playbackSessionId: histories.single.sessionId,
                ),
              )
              .then((_) => resumed = true);
        });
        await pumpUntil(
          tester,
          () => find.text('稍后播放').evaluate().isNotEmpty,
          reason: 'Explicit continuation offers pending source',
        );
        await tester.tap(find.text('继续播放').last);
        await pumpUntil(
          tester,
          () => resumed,
          reason: 'Accepted handoff launches the next source',
        );
        expect(player.events.last, 'launch:local:two');
        expect(player.plans, hasLength(2));
      } else {
        await settlePlayback(tester);
        await tester.runAsync(() => refresh!);
        expect(player.events, ['launch:local:one', 'close']);
        expect(find.text('稍后播放'), findsNothing);
        expect(find.text('无法确认视频播放器已退出'), findsWidgets);
      }
      await tester.pumpWidget(const SizedBox());
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
      await tester.runAsync(() async {
        app.dispose();
        await app.closeTestStores();
        await progress.close();
        await dir.delete(recursive: true);
      });
    });
  }
}
