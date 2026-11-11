// ignore_for_file: depend_on_referenced_packages, experimental_member_use
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/film_watch_state.dart';
import 'package:streampath/data/models/video_queue.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/pages/film_detail_page.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/film_watch_overlay.dart';
import 'package:streampath/presentation/widgets/film_segmented_control.dart';
import 'helpers/shell_test_app_state.dart';

class _App extends ShellTestAppState {
  _App({
    required super.configStore,
    required super.playbackHistoryStore,
    required super.progressService,
    required this.catalog,
  });
  final FilmCatalogController catalog;
  @override
  Future<FilmCatalogController> getFilmCatalog() async => catalog;
  @override
  Future<FilmCatalogStore> getFilmCatalogStore() async => catalog.store;
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> quiet(WidgetTester tester, List<String> sql) async {
  var previous = -1;
  var stable = 0;
  for (var i = 0; i < 400 && stable < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    stable = previous == sql.length ? stable + 1 : 0;
    previous = sql.length;
  }
  expect(stable, 8, reason: 'Database work did not settle');
}

void main() {
  setUpAll(sqfliteFfiInit);
  for (final count in [24, 100, 300, 1000]) {
    testWidgets('detail workload $count', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final sql = <String>[];
      late Directory dir;
      late FilmCatalogStore store;
      late FilmCatalogController catalog;
      late PlaybackProgressService progress;
      late _App app;
      late List<FilmResource> resources;
      late FilmWork work;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('detail_perf_');
        store = await FilmCatalogStore.open(
          '${dir.path}/catalog.db',
          factory: SqfliteDatabaseFactoryLogger(
            databaseFactoryFfi,
            options: SqfliteLoggerOptions(
              log: (event) {
                if (event is SqfliteLoggerSqlEvent &&
                    event.type == SqliteSqlCommandType.query) {
                  sql.add(event.sql);
                }
              },
            ),
          ),
        );
        await store.waitForExtraBackfill();
        final tmdb = TmdbMetadataService();
        catalog = FilmCatalogController(
          store: store,
          tmdb: tmdb,
          images: FilmCatalogImageCache(Directory('${dir.path}/images'), tmdb),
          sourceFor: (_) =>
              throw const FilmCatalogException('sourceUnavailable'),
        );
        progress = await PlaybackProgressService.open(
          '${dir.path}/progress.db',
        );
        app = _App(
          configStore: StreamPathConfigStore.forPath('${dir.path}/config.json'),
          playbackHistoryStore: PlaybackHistoryStore.forPath(
            '${dir.path}/history.json',
          ),
          progressService: progress,
          catalog: catalog,
        );
        final rootId = await store.addRoot(
          sourceId: 'local:fixture',
          kind: MediaSourceKind.local,
          path: 'TV',
          type: FilmMediaType.tv,
          name: 'Fixture',
        );
        final root = (await store.root(rootId))!;
        final generation = await store.beginScan(rootId);
        await store.stage(root, generation, [
          for (var i = 1; i <= count; i++)
            FilmScanEntry(
              path: 'TV/E$i.mkv',
              parentPath: 'TV',
              name: 'E$i.mkv',
              mediaKind: 'video',
            ),
        ]);
        await store.commitScan(rootId, generation, cancelled: () => false);
        await store.bind(
          await store.resources(),
          const FilmWork(
            type: FilmMediaType.tv,
            tmdbId: 1,
            title: 'Performance fixture',
            originalTitle: 'Performance fixture',
            overview: '',
            language: 'zh-CN',
            metadata: {'presentation_version': 5, 'certification_version': 1},
          ),
        );
        resources = await store.resources();
        await store.mapEpisodes({
          for (var i = 0; i < resources.length; i++) resources[i]: (1, i + 1),
        });
        resources = await store.resources();
        work = (await store.work(resources.first.workId!))!;
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await settle(tester);
        await tester.runAsync(() async {
          await catalog.close();
          await app.closeTestStores();
          app.dispose();
          await progress.close();
          await dir.delete(recursive: true);
        });
      });
      sql.clear();
      var cardBuilds = 0;
      var pageBuilds = 0;
      final overlayBuilds = <int, int>{};
      final oldBuild = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        if (element.widget is FilmEpisodeCard) cardBuilds++;
        if (element.widget is Scaffold) pageBuilds++;
        final widget = element.widget;
        if (widget is FilmWatchOverlay && widget.resource != null) {
          overlayBuilds.update(
            widget.resource!.id,
            (n) => n + 1,
            ifAbsent: () => 1,
          );
        }
      };
      addTearDown(() => debugOnRebuildDirtyWidget = oldBuild);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: app,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: FilmDetailPage(
              catalog: catalog,
              workId: work.id,
              initialWork: work,
              onOpenItem: (_) async {},
            ),
          ),
        ),
      );
      await settle(tester);
      await quiet(tester, sql);
      final initialProbes = sql
          .where((s) => s.contains('resource_probes'))
          .length;
      final scroll = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byKey(const Key('film-detail-scroll')),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      scroll.jumpTo(450);
      await settle(tester);
      final live = find
          .byType(FilmEpisodeCard, skipOffstage: false)
          .evaluate()
          .length;
      var renderObjects = 0;
      void visit(RenderObject object) {
        renderObjects++;
        object.visitChildren(visit);
      }

      visit(tester.binding.renderViews.first);
      if (!const bool.fromEnvironment('DETAIL_BASELINE')) {
        cardBuilds = 0;
        scroll.jumpTo(451);
        await tester.pump(const Duration(milliseconds: 40));
        expect(
          cardBuilds,
          0,
          reason: 'Scrolling within cached rows must retain their widgets',
        );
        scroll.jumpTo(450);
        await settle(tester);
      }
      sql.clear();
      cardBuilds = 0;
      pageBuilds = 0;
      overlayBuilds.clear();
      await tester.runAsync(() => store.markWatched([resources.first], true));
      await settle(tester);
      await quiet(tester, sql);
      final watchReads = sql
          .where((s) => s.contains('film_watch_state'))
          .length;
      final probeReads = sql.where((s) => s.contains('resource_probes')).length;
      final detailLoads = sql
          .where((s) => s.contains('FROM works WHERE id = ?'))
          .length;
      // ignore: avoid_print
      print(
        'DETAIL_PERF count=$count live=$live renderObjects=$renderObjects initialProbes=$initialProbes markWatchReads=$watchReads markProbes=$probeReads markCardBuilds=$cardBuilds pageBuilds=$pageBuilds detailLoads=$detailLoads totalSelects=${sql.length}',
      );
      if (!const bool.fromEnvironment('DETAIL_BASELINE')) {
        expect(live, lessThanOrEqualTo(24));
        expect(initialProbes, (count / 400).ceil());
        expect(watchReads, lessThanOrEqualTo(4));
        expect(probeReads, 0);
        expect(cardBuilds, 0);
        expect(pageBuilds, 0);
        expect(detailLoads, 0);
        expect(
          overlayBuilds.keys.where((id) => id != resources.first.id),
          isEmpty,
        );
        sql.clear();
        await tester.runAsync(() => store.markWatched(resources, false));
        await settle(tester);
        expect(
          sql.where((s) => s.contains('film_watch_state')).length,
          lessThanOrEqualTo(4),
        );
        expect(sql.where((s) => s.contains('resource_probes')), isEmpty);
        if (count == 300) {
          sql.clear();
          cardBuilds = 0;
          await tester.tap(
            find.byType(FilmEpisodeCard).first,
            buttons: kSecondaryMouseButton,
          );
          await tester.pumpAndSettle();
          scroll.jumpTo(scroll.maxScrollExtent);
          await tester.pump();
          cardBuilds = 0;
          await tester.tap(find.text('标记已看完'));
          await settle(tester);
          await quiet(tester, sql);
          expect(sql.where((s) => s.contains('resource_probes')), isEmpty);
          expect(cardBuilds, 0);
        }
        if (count == 24) {
          await tester.runAsync(() async {
            await store.mapEpisodes({
              resources[1]: (1, resources.first.episode!),
            });
            resources = await store.resources();
            final same = resources.where((r) => r.episode == 1).toList();
            await store.markWatched([same.first], true);
            final states = await store.resourceWatchStates(same);
            expect(
              states.values.every((s) => s?.status == FilmWatchStatus.watched),
              isTrue,
            );
            await store.recordVideoProgress(
              VideoProgressUpdate(
                sourceId: same.first.sourceId,
                path: same.first.path,
                positionMs: 200,
                durationMs: 1000,
                recordedAt: DateTime.now().add(const Duration(seconds: 1)),
              ),
            );
            expect(
              (await store.resourceWatchState(same.first))!.status,
              FilmWatchStatus.watched,
            );
            await store.markWatched(same, false);
            await store.recordVideoProgress(
              VideoProgressUpdate(
                sourceId: same.first.sourceId,
                path: same.first.path,
                positionMs: 200,
                durationMs: 1000,
                recordedAt: DateTime.now().add(const Duration(seconds: 2)),
              ),
            );
            expect((await store.resourceWatchState(same.last))!.fraction, .2);
            final oldBinding = same.first;
            await store.markWatched([oldBinding], true);
            await store.mapEpisodes({oldBinding: (1, 3)});
            final currentBinding = (await store.resource(oldBinding.id))!;
            final snapshots = await Future.wait([
              store.resourceWatchState(oldBinding),
              store.resourceWatchState(currentBinding),
            ]);
            expect(snapshots.first!.status, FilmWatchStatus.watched);
            expect(snapshots.last!.status, FilmWatchStatus.unwatched);
          });
          await settle(tester);
        }
        if (count == 1000) {
          await tester.tap(find.text('1. Performance fixture'));
          await tester.pumpAndSettle();
          scroll.jumpTo(scroll.maxScrollExtent);
          await tester.pump();
          expect(
            find.byType(FilmEpisodeCard, skipOffstage: false).evaluate().length,
            lessThanOrEqualTo(28),
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          for (var i = 0; i < 20; i++) {
            scroll.jumpTo(i.isEven ? scroll.maxScrollExtent : 450);
            await tester.pump(const Duration(milliseconds: 50));
            expect(
              find
                  .byType(FilmEpisodeCard, skipOffstage: false)
                  .evaluate()
                  .length,
              lessThanOrEqualTo(24),
            );
          }
          await settle(tester);
          await tester.runAsync(() async {
            final db = await databaseFactoryFfi.openDatabase(store.path);
            await db.insert('resource_probes', {
              'resource_id': resources.first.id,
              'metadata_json': '{"duration":1440,"nested":{"video":"HEVC"}}',
              'fetched_at': 1,
            });
            final probes = await store.probes([
              ...resources.map((r) => r.id),
              -1,
            ]);
            expect(probes.length, 1001);
            expect(probes[resources.first.id]?['nested'], {'video': 'HEVC'});
            expect(probes[resources.last.id], isNull);
            expect(probes[-1], isNull);
            final metadata = jsonEncode({
              'duration': 1440,
              'nested': {'video': 'HEVC'},
              'streams': [
                for (var i = 0; i < 8; i++)
                  {'index': i, 'codec': 'hevc', 'width': 1920, 'height': 1080},
              ],
            });
            final batch = db.batch();
            for (final resource in resources) {
              batch.rawInsert(
                'INSERT OR REPLACE INTO resource_probes(resource_id,metadata_json,fetched_at) VALUES(?,?,?)',
                [resource.id, metadata, 1],
              );
            }
            await batch.commit(noResult: true);
            for (var repeat = 0; repeat < 3; repeat++) {
              sql.clear();
              final timer = Stopwatch()..start();
              final serial = <int, Map<String, dynamic>?>{};
              for (final resource in resources) {
                serial[resource.id] = await store.probe(resource.id);
              }
              final serialUs = timer.elapsedMicroseconds;
              final serialQueries = sql
                  .where((s) => s.contains('resource_probes'))
                  .length;
              sql.clear();
              timer.reset();
              final batched = await store.probes(resources.map((r) => r.id));
              final batchUs = timer.elapsedMicroseconds;
              final batchQueries = sql
                  .where((s) => s.contains('resource_probes'))
                  .length;
              expect(batched, serial);
              expect(serialQueries, 1000);
              expect(batchQueries, 3);
              // ignore: avoid_print
              print(
                'PROBE_BENCH count=1000 repeat=$repeat serialUs=$serialUs batchUs=$batchUs queries=$serialQueries/$batchQueries bytesPerRow=${utf8.encode(metadata).length}',
              );
            }
          });
          store.notifyListeners();
          await settle(tester);
          expect(
            tester
                .widgetList<FilmEpisodeCard>(find.byType(FilmEpisodeCard))
                .firstWhere((c) => c.resource.id == resources.first.id)
                .probe?['duration'],
            1440,
          );
          await tester.runAsync(
            () => store.mapEpisodes({
              for (var i = 0; i < resources.length; i++)
                resources[i]: i < 24 ? (1, i + 1) : (2, i - 23),
            }),
          );
          await settle(tester);
          scroll.jumpTo(0);
          await settle(tester);
          final seasons = find.byType(FilmSegmentedControl<int?>);
          expect(
            tester
                .widgetList<FilmEpisodeCard>(find.byType(FilmEpisodeCard))
                .every((card) => card.resource.season == 1),
            isTrue,
          );
          tester
              .widget<FilmSegmentedControl<int?>>(seasons)
              .onSelectionChanged(2);
          await settle(tester);
          expect(find.byType(FilmEpisodeCard), findsWidgets);
          expect(
            tester
                .widgetList<FilmEpisodeCard>(find.byType(FilmEpisodeCard))
                .every((card) => card.resource.season == 2),
            isTrue,
          );
          expect(
            find.byType(FilmEpisodeCard).evaluate().length,
            lessThanOrEqualTo(24),
          );
          tester
              .widget<FilmSegmentedControl<int?>>(seasons)
              .onSelectionChanged(1);
          await settle(tester);
          expect(find.byType(FilmEpisodeCard), findsWidgets);
          expect(
            tester
                .widgetList<FilmEpisodeCard>(find.byType(FilmEpisodeCard))
                .every((card) => card.resource.season == 1),
            isTrue,
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await settle(tester);
        // ignore: invalid_use_of_protected_member
        expect((store.watchChanges as ChangeNotifier).hasListeners, isFalse);
      }
    });
  }
}
