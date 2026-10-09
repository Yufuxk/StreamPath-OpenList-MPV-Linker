import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:streampath/data/local/directory_cache.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/playback_history.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/pages/media_library_page.dart';
import 'package:streampath/presentation/widgets/film_continue_card.dart';
import 'helpers/shell_test_app_state.dart';
import 'helpers/pump_until.dart';

void main() {
  testWidgets(
    'marking an episode finished keeps the next unstarted episode visible in the same continue card',
    (tester) async {
      late Directory dir;
      late ShellTestAppState app;
      late FilmCatalogController catalog;
      late PlaybackProgressService progress;
      late MediaLibraryStore records;
      late List<FilmResource> resources;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('sp_continue_advance_');
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
        progress = await PlaybackProgressService.open(
          '${dir.path}/progress.db',
        );
        records = MediaLibraryStore.forPath('${dir.path}/records.json');
        app = ShellTestAppState(
          configStore: config,
          playbackHistoryStore: PlaybackHistoryStore.forPath(
            '${dir.path}/history.json',
          ),
          progressService: progress,
          mediaLibraryStore: records,
        );
        catalog = await app.getFilmCatalog();
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
          ),
        );
        resources = await catalog.store.resources();
        await catalog.store.mapEpisodes({
          resources[0]: (1, 1),
          resources[1]: (1, 2),
        });
        resources = await catalog.store.resources();
        await records.recordPlayback(
          resources.first.playbackItem,
          playbackSessionId: 'series',
          playlistIndex: 0,
          playlistCount: 2,
        );
        await app.playbackHistoryStore.upsert(
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
        await progress.saveProgress(
          url: app.resolveMediaLibraryTarget(resources.first.playbackItem)!,
          profileId: 'local:fixture',
          positionMs: 20000,
          durationMs: 600000,
        );
      });
      Future<void> settle() async {
        for (var i = 0; i < 15; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            home: MediaLibraryPage(
              sourceId: 'local:fixture',
              store: records,
              directoryCache: DirectoryCache(),
              videoProgressService: progress,
              audioProgressService: null,
              resolveUrl: (url) => url,
              resolveDirectTarget: (item) =>
                  app.resolveMediaLibraryTarget(item),
              filmCatalog: catalog,
              filmContinueAll: true,
            ),
          ),
        );
        await settle();
        expect(find.byType(FilmContinueCard), findsOneWidget);
        final original = tester
            .widget<FilmContinueCard>(find.byType(FilmContinueCard))
            .record;
        final originalState = tester.state(find.byType(FilmContinueCard));
        late Future<void> marking;
        var marked = false;
        await tester.runAsync(() async {
          marking = app
              .markFilmWatched([resources.first], true)
              .then((_) => marked = true);
        });
        await pumpUntil(
          tester,
          () => marked,
          reason: 'Watch marking must commit before checking the continue card',
        );
        await tester.runAsync(() => marking);
        await pumpUntil(
          tester,
          () =>
              find.byType(FilmContinueCard).evaluate().length == 1 &&
              tester
                      .widget<FilmContinueCard>(find.byType(FilmContinueCard))
                      .record
                      .item
                      .name ==
                  'E2.mkv',
          reason: 'The committed next episode must reach the continue card',
        );
        expect(find.byType(FilmContinueCard), findsOneWidget);
        final next = tester.widget<FilmContinueCard>(
          find.byType(FilmContinueCard),
        );
        expect(next.record.item.name, 'E2.mkv');
        expect(next.positionMs, 0);
        expect(next.record.recordKey, original.recordKey);
        expect(next.record.updatedAt, original.updatedAt);
        expect(
          tester.state(find.byType(FilmContinueCard)),
          same(originalState),
        );
        await settle();
        expect(
          tester
              .widget<FilmContinueCard>(find.byType(FilmContinueCard))
              .positionMs,
          0,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          app.dispose();
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await app.closeTestStores();
          await progress.close();
          await dir.delete(recursive: true);
        });
      }
    },
  );
}
