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
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/playback_history.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/presentation/pages/film_detail_page.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/widgets/film_continue_card.dart';

import 'helpers/shell_test_app_state.dart';

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
        expect(find.text('继续播放'), findsOneWidget);
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
}
