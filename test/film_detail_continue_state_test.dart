import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_entry.dart';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/playback_history.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/domain/services/mpv_playback_progress_sync.dart';
import 'package:streampath/presentation/pages/film_detail_page.dart';
import 'package:streampath/presentation/pages/global_media_library_page.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/widgets/film_continue_card.dart';

import 'helpers/shell_test_app_state.dart';
import 'helpers/pump_until.dart';

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  for (final film in [false, true]) {
    testWidgets('detail follows advance and final dismissal from film=$film', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final prepared = await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('detail_continue_');
        final config = StreamPathConfigStore.forPath('${dir.path}/config.json');
        await config.save(
          StreamPathConfig(
            localRoots: [
              LocalRootConfig(
                rootId: 'fixture',
                displayName: 'Fixture',
                path: dir.path,
              ),
            ],
          ),
        );
        final progress = await PlaybackProgressService.open(
          '${dir.path}/progress.db',
        );
        final app = ShellTestAppState(
          configStore: config,
          playbackHistoryStore: PlaybackHistoryStore.forPath(
            '${dir.path}/history.json',
          ),
          progressService: progress,
          mediaLibraryStore: MediaLibraryStore.forPath(
            '${dir.path}/records.json',
          ),
        );
        final catalog = await app.getFilmCatalog();
        await app.initializeFilmPlayback();
        final rootId = await catalog.store.addRoot(
          sourceId: 'local:fixture',
          kind: MediaSourceKind.local,
          path: 'TV',
          type: FilmMediaType.tv,
          name: 'TV',
        );
        final root = (await catalog.store.root(rootId))!;
        final generation = await catalog.store.beginScan(rootId);
        await catalog.store.stage(root, generation, [
          for (final name in ['E1.mkv', 'E2.mkv'])
            FilmScanEntry(
              path: 'TV/$name',
              parentPath: 'TV',
              name: name,
              mediaKind: 'video',
            ),
        ]);
        await catalog.store.commitScan(
          rootId,
          generation,
          cancelled: () => false,
        );
        await catalog.store.bind(
          await catalog.store.resources(),
          const FilmWork(
            type: FilmMediaType.tv,
            tmdbId: 1,
            title: 'Series',
            originalTitle: 'Series',
            overview: '',
            language: 'en',
            metadata: {'presentation_version': 3},
          ),
        );
        final rows = await catalog.store.resources();
        await catalog.store.mapEpisodes({rows[0]: (1, 1), rows[1]: (1, 2)});
        final resources = await catalog.store.resources();
        final records = film
            ? app.filmMediaLibraryStore!
            : app.mediaLibraryStore!;
        final histories = film
            ? app.filmPlaybackHistoryStore
            : app.playbackHistoryStore;
        await records.recordPlayback(
          resources.first.playbackItem,
          playbackSessionId: 'series',
          playlistIndex: 0,
          playlistCount: 2,
        );
        await histories.upsert(
          PlaybackHistory(
            dirCrumbs: const ['TV'],
            fileName: 'E1.mkv',
            videoIndex: 0,
            updatedAt: DateTime.now(),
            sessionId: 'series',
            sourceId: 'local:fixture',
            playlistFileNames: const ['E1.mkv', 'E2.mkv'],
            playlistRelativePaths: const ['TV/E1.mkv', 'TV/E2.mkv'],
          ),
        );
        await (film ? app.filmProgressService : progress).saveProgress(
          url: app.resolveMediaLibraryTarget(resources.first.playbackItem)!,
          positionMs: 30000,
          durationMs: 120000,
          profileId: 'local:fixture',
        );
        return (dir, app, catalog, progress, records, resources);
      });
      final (dir, app, catalog, progress, records, resources) = prepared!;
      MediaLibraryRecord? selected;
      MediaLibraryItem? started;
      try {
        await tester.pumpWidget(
          ChangeNotifierProvider<AppState>.value(
            value: app,
            child: MaterialApp(
              home: FilmDetailPage(
                catalog: catalog,
                workId: resources.first.workId!,
                onContinueSelected: (record) => selected = record,
                onOpenItem: (item) async => started = item,
              ),
            ),
          ),
        );
        await settle(tester);
        if (!film) {
          expect(find.text('开始播放'), findsOneWidget);
          expect(find.text('继续播放'), findsNothing);
          return;
        }
        expect(find.text('继续播放'), findsOneWidget);
        final continueProgress = find.descendant(
          of: find.byType(FilmContinueCard),
          matching: find.byType(LinearProgressIndicator),
        );
        expect(continueProgress, findsOneWidget);
        expect(
          tester.widget<LinearProgressIndicator>(continueProgress).value,
          .25,
        );
        await tester.runAsync(
          () => (film ? app.filmProgressService : progress).saveProgress(
            url: app.resolveMediaLibraryTarget(resources.first.playbackItem)!,
            positionMs: 60000,
            durationMs: 120000,
            profileId: 'local:fixture',
          ),
        );
        await settle(tester);
        expect(
          tester.widget<LinearProgressIndicator>(continueProgress).value,
          .5,
        );
        expect(
          tester
              .widget<FilmContinueCard>(find.byType(FilmContinueCard))
              .record
              .item
              .name,
          'E1.mkv',
        );
        late Future<void> marking;
        await tester.runAsync(() async {
          marking = app.markFilmWatched([resources.first], true);
        });
        await settle(tester);
        await tester.runAsync(
          () => marking.timeout(const Duration(seconds: 5)),
        );
        await settle(tester);
        final advanced = tester.widget<FilmContinueCard>(
          find.byType(FilmContinueCard),
        );
        expect(advanced.record.item.name, 'E2.mkv');
        expect(continueProgress, findsNothing);
        advanced.onTap();
        expect(selected!.item.name, 'E2.mkv');
        expect(selected!.playbackSessionId, 'series');
        await tester.runAsync(
          () => records.dismissVideoContinueSession('local:fixture', 'series'),
        );
        await settle(tester);
        expect(find.text('继续播放'), findsNothing);
        expect(find.text('开始播放'), findsOneWidget);
        final start = tester.widget<FilmContinueCard>(
          find.byType(FilmContinueCard),
        );
        start.onTap();
        expect(started!.name, 'E1.mkv');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await settle(tester);
        await tester.runAsync(() async {
          app.dispose();
          await app.closeTestStores();
          await progress.close();
          await dir.delete(recursive: true);
        });
      }
    });
  }

  for (final scenario in [
    'strm',
    'eof',
    'older-session',
    'browser-store',
    'bulk-clear',
  ]) {
    final isStrm = scenario == 'strm';
    final name = isStrm ? 'Movie.strm' : 'Movie.mkv';
    testWidgets('mounted movie and home agree after $scenario', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final prepared = await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('movie_continue_');
        final config = StreamPathConfigStore.forPath('${dir.path}/config.json');
        await config.save(
          StreamPathConfig(
            localRoots: [
              LocalRootConfig(
                rootId: 'fixture',
                displayName: 'Fixture',
                path: dir.path,
              ),
            ],
          ),
        );
        final progress = await PlaybackProgressService.open(
          '${dir.path}/progress.db',
        );
        final app = ShellTestAppState(
          configStore: config,
          playbackHistoryStore: PlaybackHistoryStore.forPath(
            '${dir.path}/history.json',
          ),
          progressService: progress,
          mediaLibraryStore: MediaLibraryStore.forPath(
            '${dir.path}/records.json',
          ),
        );
        final catalog = await app.getFilmCatalog();
        await app.initializeFilmPlayback();
        final rootId = await catalog.store.addRoot(
          sourceId: 'local:fixture',
          kind: MediaSourceKind.local,
          path: 'Movies',
          type: FilmMediaType.movie,
          name: 'Movies',
        );
        final root = (await catalog.store.root(rootId))!;
        final generation = await catalog.store.beginScan(rootId);
        await catalog.store.stage(root, generation, [
          FilmScanEntry(
            path: 'Movies/$name',
            parentPath: 'Movies',
            name: name,
            mediaKind: isStrm ? 'strm' : 'video',
          ),
        ]);
        await catalog.store.commitScan(
          rootId,
          generation,
          cancelled: () => false,
        );
        await catalog.store.bind(
          await catalog.store.resources(),
          const FilmWork(
            type: FilmMediaType.movie,
            tmdbId: 2,
            title: 'Movie',
            originalTitle: 'Movie',
            overview: '',
            language: 'en',
            metadata: {'presentation_version': 3},
          ),
        );
        final resource = (await catalog.store.resources()).single;
        final records = app.filmMediaLibraryStore!;
        if (scenario == 'older-session' || scenario == 'browser-store') {
          final oldStore = scenario == 'older-session'
              ? records
              : app.mediaLibraryStore!;
          await oldStore.recordPlayback(
            resource.playbackItem,
            playbackSessionId: 'older',
          );
        }
        await records.recordPlayback(
          resource.playbackItem,
          playbackSessionId: 'movie',
          playlistIndex: 0,
          playlistCount: 1,
        );
        if (isStrm) {
          await records.updateStrmProgress(
            sourceId: 'local:fixture',
            playbackSessionId: 'movie',
            fileName: name,
            playlistIndex: 0,
            positionMs: 5057806,
            durationMs: 5064062,
          );
        } else {
          final url = app.resolveMediaLibraryTarget(resource.playbackItem)!;
          await app.filmProgressService.saveProgress(
            url: url,
            profileId: 'local:fixture',
            positionMs: 30000,
            durationMs: 120000,
          );
          if (scenario == 'browser-store') {
            await progress.saveProgress(
              url: app.resolveMediaLibraryTarget(resource.playbackItem)!,
              profileId: 'local:fixture',
              positionMs: 30000,
              durationMs: 120000,
            );
          }
        }
        return (dir, app, catalog, progress, records, resource);
      });
      final (dir, app, catalog, progress, records, resource) = prepared!;
      try {
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          ChangeNotifierProvider<AppState>.value(
            value: app,
            child: MaterialApp(
              navigatorKey: navigator,
              home: GlobalMediaLibraryPage(
                filmCatalog: catalog,
                onOpenItem: (_) async {},
              ),
            ),
          ),
        );
        await settle(tester);
        final homeCards = find.descendant(
          of: find.byType(GlobalMediaLibraryPage, skipOffstage: false),
          matching: find.byType(FilmContinueCard, skipOffstage: false),
          skipOffstage: false,
        );
        if (!isStrm) expect(homeCards, findsOneWidget);
        Future<void> mutate(Future<void> Function() action) async {
          var done = false;
          late Future<void> operation;
          await tester.runAsync(() async {
            operation = action().whenComplete(() => done = true);
          });
          await pumpUntil(
            tester,
            () => done,
            reason: 'Playback write finishes',
          );
          await tester.runAsync(() => operation);
          await settle(tester);
        }

        MediaLibraryRecord? selected;
        navigator.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) => FilmDetailPage(
              catalog: catalog,
              workId: resource.workId!,
              onContinueSelected: (record) => selected = record,
              onOpenItem: (_) async {},
            ),
          ),
        );
        await settle(tester);
        final detailCards = find.descendant(
          of: find.byType(FilmDetailPage),
          matching: find.byType(FilmContinueCard),
        );
        Finder detailText(String text) => find.descendant(
          of: find.byType(FilmDetailPage),
          matching: find.text(text),
        );
        if (!isStrm) {
          final url = app.resolveMediaLibraryTarget(resource.playbackItem)!;
          expect(detailText('继续播放'), findsOneWidget);
          tester.widget<FilmContinueCard>(detailCards).onTap();
          expect(selected?.playbackSessionId, 'movie');
          if (scenario == 'bulk-clear') {
            await mutate(records.clearContinuePlayback);
            await tester.runAsync(() async {
              expect(
                (await app.filmProgressService.getResumeProgress(
                  url,
                  profileId: 'local:fixture',
                ))?.positionMs,
                30000,
              );
            });
          } else {
            await mutate(() async {
              final journal = await File('${dir.path}/progress.jsonl')
                  .writeAsString(
                    '${jsonEncode({'epoch': 'launch', 'outcome': 'completed', 'reason': 'eof', 'playlist_pos': 0, 'path': url, 'position': 97, 'duration': 120})}\n',
                  );
              await const MpvPlaybackProgressSynchronizer().sync(
                progressService: app.filmProgressService,
                profileId: 'local:fixture',
                entries: [MediaEntry(url: url)],
                watchLaterDirectory: dir,
                journalFile: journal,
                expectedEpoch: 'launch',
              );
              expect(
                await app.filmProgressService.getResumeProgress(
                  url,
                  profileId: 'local:fixture',
                ),
                isNull,
              );
              if (scenario != 'eof') {
                await records.dismissVideoContinueSession(
                  'local:fixture',
                  'movie',
                );
              }
            });
          }
          await settle(tester);
        }
        expect(detailText('继续播放'), findsNothing);
        expect(detailText('开始播放'), findsOneWidget);
        expect(homeCards, findsNothing);
        expect(
          tester.widget<FilmContinueCard>(detailCards).record.playbackSessionId,
          isNull,
        );
        expect(
          find.descendant(
            of: find.byType(FilmContinueCard),
            matching: find.byType(LinearProgressIndicator),
          ),
          findsNothing,
        );
        if (scenario == 'eof') {
          await mutate(
            () => records.dismissVideoContinueSession('local:fixture', 'movie'),
          );
        }
        if (!isStrm) {
          final history = records.playbackHistorySnapshot(
            'local:fixture',
            audio: false,
          );
          expect(history.first.playbackSessionId, 'movie');
          expect(history.first.continueDismissed, isTrue);
          expect(history.first.continueCompleted, scenario != 'bulk-clear');
          expect(history, hasLength(scenario == 'older-session' ? 2 : 1));
        }
        await mutate(() async {
          if (isStrm) {
            await records.updateStrmProgress(
              sourceId: 'local:fixture',
              playbackSessionId: 'movie',
              fileName: name,
              playlistIndex: 0,
              positionMs: 2532031,
              durationMs: 5064062,
            );
          } else {
            // 底层 URL 重新有进度时，由最新会话决定历史记录是否可续播。
            await app.filmProgressService.saveProgress(
              url: app.resolveMediaLibraryTarget(resource.playbackItem)!,
              profileId: 'local:fixture',
              positionMs: 60000,
              durationMs: 120000,
            );
          }
        });
        if (!isStrm) {
          await settle(tester);
          expect(detailText('开始播放'), findsOneWidget);
        }
        if (!isStrm) {
          await mutate(() async {
            await records.recordPlayback(
              resource.playbackItem,
              playbackSessionId: 'replay',
              playlistIndex: 0,
              playlistCount: 1,
            );
            await records.dismissVideoContinueSession('local:fixture', 'movie');
            await records.recordPlayback(
              resource.playbackItem,
              playbackSessionId: 'movie',
            );
            if (scenario == 'older-session') {
              await records.recordPlayback(
                resource.playbackItem,
                playbackSessionId: 'older',
              );
            }
          });
        }
        await settle(tester);
        expect(detailText('继续播放'), findsOneWidget);
        final progressBar = find.descendant(
          of: find.byType(FilmContinueCard),
          matching: find.byType(LinearProgressIndicator),
        );
        expect(progressBar, findsOneWidget);
        expect(
          tester.widget<LinearProgressIndicator>(progressBar).value,
          closeTo(.5, .01),
        );
        if (!isStrm) {
          tester.widget<FilmContinueCard>(detailCards).onTap();
          expect(selected?.playbackSessionId, 'replay');
          navigator.currentState!.pop();
          await settle(tester);
          expect(homeCards, findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await settle(tester);
        await tester.runAsync(() async {
          app.dispose();
          await app.closeTestStores();
          await progress.close();
          await dir.delete(recursive: true);
        });
      }
    });
  }
}
