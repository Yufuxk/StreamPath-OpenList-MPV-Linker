import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/media_connection.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/pages/film_detail_page.dart';
import 'package:streampath/presentation/pages/film_library_page.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';
import 'package:streampath/presentation/widgets/film_shelf.dart';
import 'package:streampath/presentation/widgets/film_library_background.dart';
import 'package:streampath/presentation/widgets/directory_scroll_view.dart';
import 'package:streampath/presentation/pages/film_related_page.dart';
import 'package:streampath/presentation/widgets/film_watch_overlay.dart';
import 'package:streampath/presentation/widgets/film_continue_card.dart';
import 'package:streampath/presentation/widgets/film_play_icon.dart';
import 'package:streampath/presentation/widgets/sp_menu.dart';
import 'package:streampath/data/models/media_library_item.dart';

import 'helpers/shell_test_app_state.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory temp;
  late _ServerTestAppState app;
  late FilmCatalogController catalog;
  late PlaybackProgressService progress;
  late List<FilmWork> works;

  Future<void> prepare(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('film_detail_artwork_');
      final config = StreamPathConfigStore.forPath(
        p.join(temp.path, 'config.json'),
      );
      progress = await PlaybackProgressService.open(
        inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      app = _ServerTestAppState(
        configStore: config,
        playbackHistoryStore: PlaybackHistoryStore.forPath(
          p.join(temp.path, 'history.json'),
        ),
        mediaLibraryStore: MediaLibraryStore.forPath(
          p.join(temp.path, 'records.json'),
        ),
        progressService: progress,
      );
      catalog = await app.getFilmCatalog();
      final rootId = await catalog.store.addRoot(
        sourceId: 'local:fixture',
        kind: MediaSourceKind.local,
        path: '',
        type: FilmMediaType.movie,
        name: 'Fixture',
      );
      final root = (await catalog.store.root(rootId))!;
      final generation = await catalog.store.beginScan(rootId);
      await catalog.store.stage(root, generation, [
        for (var i = 0; i < 3; i++)
          FilmScanEntry(
            path: '$i.mkv',
            parentPath: '',
            name: '$i.mkv',
            mediaKind: 'video',
          ),
      ]);
      await catalog.store.commitScan(
        rootId,
        generation,
        cancelled: () => false,
      );
      final resources = await catalog.store.resources();
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 960, 540),
        Paint()..color = Colors.teal,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(960, 540);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      image.dispose();
      picture.dispose();
      await catalog.images.directory.create(recursive: true);
      for (var i = 0; i < 3; i++) {
        await catalog.store.bind(
          [resources[i]],
          FilmWork(
            type: FilmMediaType.movie,
            tmdbId: i + 1,
            title: 'Film $i',
            originalTitle: 'Film $i',
            overview: '',
            language: 'zh-CN',
            posterPath: '/poster$i.png',
            backdropPath: '/backdrop$i.png',
            metadata: const {'presentation_version': 3},
          ),
        );
        for (final (path, target) in [
          ('/poster$i.png', 'w342'),
          ('/poster$i.png', 'w500'),
          ('/backdrop$i.png', 'original'),
        ]) {
          await File(
            p.join(
              catalog.images.directory.path,
              '${FilmCatalogImageCache.cacheKey(path, target)}.img',
            ),
          ).writeAsBytes(bytes);
        }
      }
      await catalog.refresh();
      works = await catalog.store.works(type: null);
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await tester.runAsync(() async {
        await app.closeTestStores();
        app.dispose();
        await progress.close();
        await temp.delete(recursive: true);
      });
    });
  }

  Widget frame(Widget home) => ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(theme: AppTheme.dark(), home: home),
  );

  Finder backdropImages() => find.descendant(
    of: find.byKey(const Key('film-detail-backdrop')),
    matching: find.byType(RawImage),
  );

  testWidgets(
    'spoiler mode retains main artwork and uses one overview reveal action',
    (tester) async {
      await prepare(tester);
      await tester.runAsync(() async {
        await catalog.store.bind(
          [(await catalog.store.resources()).first],
          FilmWork(
            type: FilmMediaType.movie,
            tmdbId: works.first.tmdbId,
            title: works.first.title,
            originalTitle: works.first.originalTitle,
            overview: 'Secret overview',
            language: 'zh-CN',
            posterPath: works.first.posterPath,
            backdropPath: works.first.backdropPath,
          ),
        );
        await catalog.store.setPreference('spoiler_protection', true);
      });
      await tester.pumpWidget(
        frame(
          FilmDetailPage(
            catalog: catalog,
            workId: works.first.id,
            onOpenItem: (_) async {},
          ),
        ),
      );
      await settle(tester);
      expect(
        find.ancestor(
          of: find.text('Secret overview'),
          matching: find.byType(ImageFiltered),
        ),
        findsOneWidget,
      );
      expect(find.text('展示剧透'), findsOneWidget);
      expect(find.text('展开简介'), findsNothing);
      for (final key in ['film-detail-poster', 'film-detail-backdrop']) {
        expect(
          find.ancestor(
            of: find.byKey(Key(key)),
            matching: find.byType(ImageFiltered),
          ),
          findsNothing,
        );
      }
      await tester.tap(find.text('展示剧透'));
      await tester.pump();
      expect(
        find.ancestor(
          of: find.text('Secret overview'),
          matching: find.byType(ImageFiltered),
        ),
        findsNothing,
      );
      expect(find.text('展示剧透'), findsNothing);
      expect(find.text('展开简介'), findsOneWidget);
    },
  );

  testWidgets(
    'collection and person pages share library layout and background updates',
    (tester) async {
      await prepare(tester);
      final collectionId = (await tester.runAsync(() async {
        final id = await catalog.store.createCollection('Fixture collection');
        await catalog.store.addCollectionMember(id, works.first.id);
        return id;
      }))!;
      final collections = (await tester.runAsync(
        () => catalog.store.collections(customOnly: true),
      ))!;
      final files = (await tester.runAsync(
        () async => [
          (await catalog.images.cached(works[0].backdropPath!, 'original'))!,
          (await catalog.images.cached(works[1].backdropPath!, 'original'))!,
        ],
      ))!;
      for (final isCollection in [true, false]) {
        await tester.runAsync(() async {
          await catalog.store.setBackgroundPath(files.first.path);
          await catalog.refresh();
        });
        await tester.pumpWidget(
          frame(
            FilmRelatedPage(
              key: ValueKey(isCollection),
              catalog: catalog,
              title: 'Related',
              collection: isCollection
                  ? collections.singleWhere((c) => c.id == collectionId)
                  : null,
              personId: isCollection ? null : 'tmdb:999',
              sidebarInset: 72,
              onOpenItem: (_) async {},
            ),
          ),
        );
        await settle(tester);
        expect(tester.getTopLeft(find.byType(AppBar)).dx, 72);
        final bar = tester.widget<AppBar>(find.byType(AppBar));
        expect(bar.toolbarHeight, 48);
        expect(bar.backgroundColor, Colors.transparent);
        expect(bar.shape, const Border());
        expect((bar.title! as Text).data, 'Related');
        expect((bar.title! as Text).style, isNull);
        expect(find.text('Related'), findsOneWidget);
        expect(find.text('主页'), findsOneWidget);
        expect(find.text('重命名'), findsNothing);
        expect(find.text('修改图片'), findsNothing);
        expect(find.text('删除合集'), findsNothing);
        expect(find.byType(FilmPosterGrid), findsOneWidget);
        expect(
          tester
              .widget<FilmLibraryBackground>(find.byType(FilmLibraryBackground))
              .file!
              .path,
          files.first.path,
        );
        await tester.runAsync(() async {
          await catalog.store.setBackgroundPath(files.last.path);
          await catalog.refresh();
        });
        await settle(tester);
        expect(
          tester
              .widget<FilmLibraryBackground>(find.byType(FilmLibraryBackground))
              .file!
              .path,
          files.last.path,
        );
      }
    },
  );

  testWidgets(
    'collections show all uses the shared grid, hover and synchronized background',
    (tester) async {
      await prepare(tester);
      await tester.runAsync(() async {
        final id = await catalog.store.createCollection(
          'All collections fixture',
        );
        await catalog.store.addCollectionMember(id, works.first.id);
        await catalog.store.setBackgroundPath(
          (await catalog.images.cached(
            works[0].backdropPath!,
            'original',
          ))!.path,
        );
        await catalog.refresh();
      });
      await tester.pumpWidget(
        frame(FilmLibraryPage(sidebarInset: 72, onOpenItem: (_) async {})),
      );
      await settle(tester);
      final shelf = find.byWidgetPredicate(
        (w) => w is FilmShelf && w.title == '合集',
      );
      final all = find.descendant(of: shelf, matching: find.text('查看全部'));
      await tester.ensureVisible(all);
      await tester.tap(all);
      await settle(tester);
      expect(tester.getTopLeft(find.byType(AppBar)).dx, 72);
      expect(tester.widget<AppBar>(find.byType(AppBar)).toolbarHeight, 48);
      expect(find.text('主页'), findsOneWidget);
      final grid = tester.widget<GridView>(find.byType(GridView));
      final layout =
          grid.gridDelegate as SliverGridDelegateWithMaxCrossAxisExtent;
      expect(layout.maxCrossAxisExtent, 220);
      expect(layout.mainAxisExtent, 350);
      expect(layout.crossAxisSpacing, 16);
      expect(
        find.descendant(
          of: find.byType(FilmCollectionCard),
          matching: find.byType(FilmCoverZoom),
        ),
        findsOneWidget,
      );
      final newBackground = (await tester.runAsync(
        () => catalog.images.cached(works[1].backdropPath!, 'original'),
      ))!;
      await tester.runAsync(() async {
        await catalog.store.setBackgroundPath(newBackground.path);
        await catalog.refresh();
      });
      await settle(tester);
      expect(
        tester
            .widget<FilmLibraryBackground>(find.byType(FilmLibraryBackground))
            .file!
            .path,
        newBackground.path,
      );
      await tester.tap(find.text('All collections fixture'));
      await settle(tester);
      expect(find.byType(FilmPosterGrid), findsOneWidget);
      expect(find.text(works.first.title), findsOneWidget);
      expect(
        tester
            .widget<FilmLibraryBackground>(find.byType(FilmLibraryBackground))
            .file!
            .path,
        newBackground.path,
      );
    },
  );

  testWidgets(
    'source selection shows the cached server library before refresh and shares background',
    (tester) async {
      await prepare(tester);
      await tester.runAsync(() async {
        final config = MediaConnection(
          id: 'jellyfin:fixture',
          kind: MediaSourceKind.jellyfin,
          name: 'Fixture server',
          url: 'http://localhost:8096',
        );
        app.servers.add(config);
        final root = (await catalog.store.serverRoots(
          config,
        ))[FilmMediaType.movie]!;
        final generation = await catalog.store.beginScan(root.id);
        final item = <String, dynamic>{'Id': 'fixture', 'Name': 'Server movie'};
        final work = await catalog.store.saveServerWork(
          config,
          'fixture-server',
          item,
          FilmMediaType.movie,
        );
        await catalog.store.saveServerResources(
          config,
          root,
          generation,
          item,
          work,
        );
        await catalog.store.commitScan(
          root.id,
          generation,
          cancelled: () => false,
        );
        await catalog.store.setBackgroundPath(
          (await catalog.images.cached(
            works.first.backdropPath!,
            'original',
          ))!.path,
        );
        await catalog.refresh();
      });
      await tester.pumpWidget(frame(FilmLibraryPage(onOpenItem: (_) async {})));
      await settle(tester);
      expect(find.text('主影视库'), findsOneWidget);
      final background = tester.element(find.byType(FilmLibraryBackground));
      final backgroundImage = find.descendant(
        of: find.byType(FilmLibraryBackground),
        matching: find.byType(RawImage),
      );
      final decoded = tester.widget<RawImage>(backgroundImage).image;
      expect(decoded, isNotNull);
      final search = tester.state(find.byType(EditableText));
      final selector = tester.state(
        find.byType(SPDropdownButtonFormField<String>),
      );
      final rootFilter = tester.state(
        find.byType(SPDropdownButtonFormField<int>),
      );
      final sortFilter = tester.state(
        find.byType(SPDropdownButtonFormField<bool>),
      );
      final pending = tester.element(find.text('待整理（0）'));
      app.catalogGate = Completer<void>();
      await tester.tap(find.text('主影视库'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fixture server').last);
      await tester.pumpAndSettle();
      expect(tester.element(find.byType(FilmLibraryBackground)), background);
      expect(tester.widget<RawImage>(backgroundImage).image, same(decoded));
      expect(tester.state(find.byType(EditableText)), search);
      expect(
        tester.state(find.byType(SPDropdownButtonFormField<String>)),
        selector,
      );
      expect(
        tester.state(find.byType(SPDropdownButtonFormField<int>)),
        rootFilter,
      );
      expect(
        tester.state(find.byType(SPDropdownButtonFormField<bool>)),
        sortFilter,
      );
      expect(tester.element(find.text('待整理（0）')), pending);
      app.catalogGate!.complete();
      app.catalogGate = null;
      await settle(tester);
      expect(app.refreshes, 1);
      expect(app.serverRefresh.isCompleted, false);
      expect(
        find.byWidgetPredicate(
          (w) => w is FilmWorkCard && w.work.title == 'Server movie',
        ),
        findsWidgets,
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is FilmWorkCard && w.work.title.startsWith('Film '),
        ),
        findsNothing,
      );
      expect(
        tester
            .widget<FilmLibraryBackground>(find.byType(FilmLibraryBackground))
            .file!
            .path,
        catalog.backgroundFile!.path,
      );
      expect(tester.element(find.byType(FilmLibraryBackground)), background);
      expect(tester.widget<RawImage>(backgroundImage).image, same(decoded));
      expect(tester.state(find.byType(EditableText)), search);
      expect(
        tester.state(find.byType(SPDropdownButtonFormField<String>)),
        selector,
      );
      expect(
        tester.state(find.byType(SPDropdownButtonFormField<int>)),
        rootFilter,
      );
      expect(
        tester.state(find.byType(SPDropdownButtonFormField<bool>)),
        sortFilter,
      );
      expect(tester.element(find.text('待整理（0）')), pending);
      app.serverRefresh.complete();
      await settle(tester);
      await tester.tap(
        find
            .descendant(
              of: find.byType(AppBar),
              matching: find.text('Fixture server'),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('主影视库').last);
      await settle(tester);
      expect(
        find.byWidgetPredicate(
          (w) => w is FilmWorkCard && w.work.title.startsWith('Film '),
        ),
        findsWidgets,
      );
      void expectRetained() {
        expect(tester.element(find.byType(FilmLibraryBackground)), background);
        expect(tester.widget<RawImage>(backgroundImage).image, same(decoded));
        expect(tester.state(find.byType(EditableText)), search);
        expect(
          tester.state(find.byType(SPDropdownButtonFormField<String>)),
          selector,
        );
        expect(
          tester.state(find.byType(SPDropdownButtonFormField<int>)),
          rootFilter,
        );
        expect(
          tester.state(find.byType(SPDropdownButtonFormField<bool>)),
          sortFilter,
        );
        expect(tester.element(find.text('待整理（0）')), pending);
      }

      void select(String value) => tester
          .widget<SPDropdownButtonFormField<String>>(
            find.byType(SPDropdownButtonFormField<String>),
          )
          .onChanged!(value);
      for (var i = 0; i < 20; i++) {
        app.catalogGate = Completer<void>();
        select('jellyfin:fixture');
        await tester.pump();
        expectRetained();
        if (i.isEven) {
          select('');
          await tester.pump();
        }
        app.catalogGate!.complete();
        app.catalogGate = null;
        await settle(tester);
        expectRetained();
        expect(
          tester
              .widget<SPDropdownButtonFormField<String>>(
                find.byType(SPDropdownButtonFormField<String>),
              )
              .initialValue,
          i.isEven ? '' : 'jellyfin:fixture',
        );
        expect(
          find.byWidgetPredicate(
            (w) => w is FilmWorkCard && w.work.title.startsWith('Film '),
          ),
          i.isEven ? findsWidgets : findsNothing,
        );
        if (i.isOdd) {
          select('');
          await settle(tester);
        }
        expectRetained();
        expect(tester.takeException(), isNull);
      }
      app.catalogFailure = const FileSystemException('Fixture load failure');
      app.catalogGate = Completer<void>();
      select('jellyfin:fixture');
      await tester.pump();
      app.catalogGate!.complete();
      app.catalogGate = null;
      await settle(tester);
      expectRetained();
      expect(find.text('影视目录库操作失败'), findsOneWidget);
      app.catalogFailure = null;
      select('');
      await settle(tester);
      expectRetained();
      expect(find.text('影视目录库操作失败'), findsNothing);
    },
  );

  testWidgets('collection cover menu renames and deletes the collection', (
    tester,
  ) async {
    await prepare(tester);
    await tester.runAsync(() async {
      final id = await catalog.store.createCollection('Menu collection');
      await catalog.store.addCollectionMember(id, works.first.id);
      await catalog.refresh();
    });
    await tester.pumpWidget(frame(FilmLibraryPage(onOpenItem: (_) async {})));
    await settle(tester);
    Future<void> openMenu(String title) async {
      await tester.ensureVisible(find.text(title));
      await tester.pumpAndSettle();
      await tester.tap(find.text(title), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(find.text('重命名'), findsOneWidget);
      expect(find.text('修改图片'), findsOneWidget);
      expect(find.text('删除合集'), findsOneWidget);
    }

    await openMenu('Menu collection');
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Renamed collection');
    await tester.tap(find.text('保存'));
    await settle(tester);
    expect(find.text('Renamed collection'), findsOneWidget);
    await openMenu('Renamed collection');
    await tester.tap(find.text('删除合集'));
    await settle(tester);
    expect(find.text('Renamed collection'), findsNothing);
  });

  testWidgets(
    'continue artwork fills landscape cards and retains portrait aspect ratio',
    (tester) async {
      await prepare(tester);
      final resource = (await tester.runAsync(
        () => catalog.store.resources(),
      ))!.first;
      for (final poster in [false, true]) {
        await tester.pumpWidget(
          frame(
            Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: FilmContinueCard.landscapeWidth,
                  height: FilmContinueCard.landscapeHeight,
                  child: FilmContinueCard(
                    catalog: catalog,
                    record: MediaLibraryRecord(
                      item: resource.playbackItem,
                      updatedAt: DateTime.now(),
                    ),
                    onTap: () {},
                    poster: poster,
                  ),
                ),
              ),
            ),
          ),
        );
        await settle(tester);
        final artwork = tester.getRect(find.byType(FilmArtwork));
        if (poster) {
          expect(artwork.width / artwork.height, closeTo(2 / 3, .001));
        } else {
          expect(artwork.width, FilmContinueCard.landscapeWidth);
          expect(artwork, tester.getRect(find.byType(FilmWatchOverlay)));
        }
      }
    },
  );

  testWidgets(
    'episode artwork and overview share one reveal action below the overview',
    (tester) async {
      await prepare(tester);
      final resource = (await tester.runAsync(() async {
        final rootId = await catalog.store.addRoot(
          sourceId: 'local:tv-fixture',
          kind: MediaSourceKind.local,
          path: 'TV',
          type: FilmMediaType.tv,
          name: 'TV fixture',
        );
        final root = (await catalog.store.root(rootId))!;
        final generation = await catalog.store.beginScan(rootId);
        await catalog.store.stage(root, generation, [
          const FilmScanEntry(
            path: 'TV/E1.mkv',
            parentPath: 'TV',
            name: 'E1.mkv',
            mediaKind: 'video',
          ),
        ]);
        await catalog.store.commitScan(
          rootId,
          generation,
          cancelled: () => false,
        );
        final resource = (await catalog.store.resources(rootId: rootId)).single;
        await catalog.store.bind(
          [resource],
          FilmWork(
            type: FilmMediaType.tv,
            tmdbId: 777,
            title: 'TV fixture',
            originalTitle: 'TV fixture',
            overview: '',
            language: 'en',
            posterPath: works.first.posterPath,
          ),
        );
        final bound = (await catalog.store.resources()).firstWhere(
          (r) => r.id == resource.id,
        );
        await catalog.store.mapEpisodes({bound: (1, 1)});
        await catalog.store.setPreference('spoiler_protection', true);
        final original = (await catalog.images.cached(
          works.first.backdropPath!,
          'original',
        ))!;
        await original.copy(
          p.join(
            catalog.images.directory.path,
            '${FilmCatalogImageCache.cacheKey('/still.png', 'w300')}.img',
          ),
        );
        return (await catalog.store.resources()).firstWhere(
          (r) => r.id == resource.id,
        );
      }))!;
      for (final overview in ['', 'Secret episode overview']) {
        var menuCalls = 0;
        await tester.pumpWidget(
          frame(
            Scaffold(
              body: FilmSpoilerScope(
                key: ValueKey(overview),
                child: SizedBox(
                  width: 300,
                  child: Column(
                    children: [
                      Expanded(
                        child: FilmEpisodeCard(
                          resource: resource,
                          catalog: catalog,
                          state: '可用',
                          onOpenItem: (_) async {},
                          onChanged: () async {},
                          episode: {
                            'name': 'Episode',
                            'still_path': '/still.png',
                            'overview': overview,
                          },
                        ),
                      ),
                      SizedBox(
                        height: FilmContinueCard.landscapeHeight,
                        child: FilmContinueCard(
                          catalog: catalog,
                          record: MediaLibraryRecord(
                            item: resource.playbackItem,
                            updatedAt: DateTime.now(),
                          ),
                          onTap: () {},
                          onMenu: (_) => menuCalls++,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await settle(tester);
        expect(find.text('展示封面'), findsOneWidget);
        expect(find.text('展示剧透'), findsNothing);
        expect(find.byType(ImageFiltered), findsNWidgets(3));
        final continuationMenu = find.descendant(
          of: find.byType(FilmContinueCard),
          matching: find.byTooltip('更多操作'),
        );
        expect(
          find.ancestor(
            of: find.byType(FilmPlayIcon),
            matching: find.byType(ImageFiltered),
          ),
          findsNothing,
        );
        expect(
          find.ancestor(
            of: continuationMenu,
            matching: find.byType(ImageFiltered),
          ),
          findsNothing,
        );
        await tester.tap(continuationMenu);
        await tester.pump();
        expect(menuCalls, 1);
        await tester.tap(find.text('展示封面'));
        await tester.pump();
        expect(find.byType(ImageFiltered), findsNothing);
        expect(find.text('展示封面'), findsNothing);
      }
    },
  );

  testWidgets('首页背景缓存被淘汰后返回首帧仍保留原图，切换路径不残留旧图', (tester) async {
    await prepare(tester);
    final file = (await tester.runAsync(
      () => catalog.images.cached(works.first.backdropPath!, 'original'),
    ))!;
    late BuildContext homeContext;
    await tester.pumpWidget(
      frame(
        Builder(
          builder: (context) {
            homeContext = context;
            return FilmLibraryBackground(file: file);
          },
        ),
      ),
    );
    await settle(tester);
    final original = tester.widget<RawImage>(find.byType(RawImage)).image;
    expect(original, isNotNull);
    for (var i = 0; i < 20; i++) {
      Navigator.of(homeContext).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Child')),
        ),
      );
      await tester.pumpAndSettle();
      PaintingBinding.instance.imageCache.clear();
      Navigator.of(homeContext).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      await settle(tester);
    }
    await tester.pumpWidget(
      frame(
        FilmLibraryBackground(
          file: File(p.join(temp.path, 'missing-background.png')),
        ),
      ),
    );
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNull);
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('影片详情复用目录滚动条，滚轮在条边和正文只滚动一次', (tester) async {
    await prepare(tester);
    tester.view.physicalSize = const Size(1280, 640);
    await tester.pumpWidget(
      frame(
        FilmDetailPage(
          catalog: catalog,
          workId: works.first.id,
          initialWork: works.first,
          onOpenItem: (_) async {},
        ),
      ),
    );
    await settle(tester);
    final list = find.byKey(const Key('film-detail-scroll'));
    final shared = find.ancestor(
      of: list,
      matching: find.byType(DirectoryScrollView),
    );
    expect(shared, findsOneWidget);
    final controller = tester.widget<ListView>(list).controller!;
    final rect = tester.getRect(shared);
    for (final x in [rect.right - 2, rect.left + 400]) {
      final before = controller.offset;
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      final location = Offset(x, rect.top + 80);
      await tester.sendEventToBinding(pointer.hover(location));
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: location,
          scrollDelta: const Offset(0, 30),
        ),
      );
      await tester.pump();
      expect(controller.offset, before + 30);
    }
    expect(tester.takeException(), isNull);
  });

  for (final dpr in [1.0, 2.0]) {
    testWidgets('已解码背景在首帧复用同一缓存键 DPR=$dpr', (tester) async {
      await prepare(tester);
      tester.view.devicePixelRatio = dpr;
      final file = (await tester.runAsync(
        () => catalog.images.cached(works.first.backdropPath!, 'original'),
      ))!;
      final provider = filmArtworkProvider(
        file,
        target: 'original',
        backdrop: true,
        devicePixelRatio: dpr,
      );
      await decode(tester, provider);
      final before = PaintingBinding.instance.imageCache.currentSizeBytes;
      await tester.pumpWidget(
        frame(
          FilmArtwork(
            cache: catalog.images,
            path: works.first.backdropPath,
            target: 'original',
            backdrop: true,
            height: double.infinity,
            width: double.infinity,
          ),
        ),
      );
      final images = tester
          .widgetList<RawImage>(find.byType(RawImage))
          .toList();
      expect(images, hasLength(2));
      expect(images.every((image) => image.image != null), isTrue);
      expect(images.first.image!.isCloneOf(images.last.image!), isTrue);
      expect(
        tester
            .widgetList<Image>(find.byType(Image))
            .every((image) => image.image == provider),
        isTrue,
      );
      expect(PaintingBinding.instance.imageCache.currentSizeBytes, before);
    });
  }

  testWidgets('点击立即导航，首帧复用主界面海报并继续原详情加载', (tester) async {
    await prepare(tester);
    await tester.pumpWidget(frame(FilmLibraryPage(onOpenItem: (_) async {})));
    await settle(tester);
    final card = find.byType(FilmWorkCard).first;
    final work = tester.widget<FilmWorkCard>(card).work;
    final poster = tester
        .widgetList<RawImage>(
          find.descendant(of: card, matching: find.byType(RawImage)),
        )
        .first
        .image!;
    final background = File(
      p.join(
        catalog.images.directory.path,
        '${FilmCatalogImageCache.cacheKey(work.backdropPath!, 'original')}.img',
      ),
    );
    expect(
      PaintingBinding.instance.imageCache
          .statusForKey(
            filmArtworkProvider(background, target: 'original', backdrop: true),
          )
          .untracked,
      isTrue,
    );
    await tester.tap(card);
    await tester.pump();
    await tester.pump();
    expect(find.byType(FilmDetailPage), findsOneWidget);
    final images = tester.widgetList<RawImage>(backdropImages()).toList();
    expect(images, hasLength(2));
    expect(
      images.every(
        (image) =>
            image.image != null &&
            (image.image!.isCloneOf(poster) || image.image!.width == 960),
      ),
      isTrue,
    );
    await settle(tester);
    final actual = tester.widgetList<Image>(
      find.descendant(
        of: find.byKey(const Key('film-detail-backdrop')),
        matching: find.byType(Image),
      ),
    );
    expect(actual.every((image) => image.image is FileImage), isTrue);
    expect(find.byKey(const Key('film-detail-scroll')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final focus in [false, true]) {
    testWidgets('${focus ? '键盘焦点' : '鼠标悬停'}预热详情专用 Provider', (tester) async {
      await prepare(tester);
      await tester.pumpWidget(frame(FilmLibraryPage(onOpenItem: (_) async {})));
      await settle(tester);
      final card = find.byType(FilmWorkCard).first;
      final work = tester.widget<FilmWorkCard>(card).work;
      if (focus) {
        Focus.of(
          tester.element(
            find.descendant(of: card, matching: find.byType(FilmArtwork)).first,
          ),
        ).requestFocus();
        await tester.pump();
      } else {
        final mouse = await tester.createGesture(
          kind: ui.PointerDeviceKind.mouse,
        );
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(tester.getCenter(card));
        addTearDown(mouse.removePointer);
      }
      await settle(tester);
      final file = catalog.images.knownFile(work.backdropPath, 'original')!;
      final provider = filmArtworkProvider(
        file,
        target: 'original',
        backdrop: true,
      );
      expect(
        PaintingBinding.instance.imageCache.statusForKey(provider).keepAlive,
        isTrue,
      );
      await tester.tap(card);
      await tester.pump();
      await tester.pump();
      expect(
        tester
            .widgetList<RawImage>(backdropImages())
            .every((image) => image.image?.width == 960),
        isTrue,
      );
      expect(
        tester
            .widgetList<Image>(
              find.descendant(
                of: find.byKey(const Key('film-detail-backdrop')),
                matching: find.byType(Image),
              ),
            )
            .every((image) => image.image == provider),
        isTrue,
      );
      final route = ModalRoute.of(tester.element(find.byType(FilmDetailPage)))!;
      expect(route, isA<MaterialPageRoute<void>>());
      expect(route.transitionDuration, const Duration(milliseconds: 300));
      await settle(tester);
    });
  }

  testWidgets('快速候选切换只预热进行中与最新作品，不下载缺失图片', (tester) async {
    await prepare(tester);
    late BuildContext context;
    await tester.pumpWidget(
      frame(
        Builder(
          builder: (value) {
            context = value;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    for (final work in works) {
      precacheFilmDetailArtwork(context, catalog.images, work);
    }
    await settle(tester);
    expect(
      catalog.images.knownFile(works.first.backdropPath, 'original'),
      isNotNull,
    );
    final skipped = File(
      p.join(
        catalog.images.directory.path,
        '${FilmCatalogImageCache.cacheKey(works[1].backdropPath!, 'original')}.img',
      ),
    );
    expect(
      PaintingBinding.instance.imageCache
          .statusForKey(
            filmArtworkProvider(skipped, target: 'original', backdrop: true),
          )
          .untracked,
      isTrue,
    );
    expect(
      catalog.images.knownFile(works.last.backdropPath, 'original'),
      isNotNull,
    );
    precacheFilmDetailArtwork(
      context,
      catalog.images,
      const FilmWork(
        type: FilmMediaType.movie,
        tmdbId: 100,
        title: 'Missing',
        originalTitle: '',
        overview: '',
        language: 'zh-CN',
        backdropPath: '/missing.png',
        posterPath: '/missingposter.png',
      ),
    );
    await settle(tester);
    expect(catalog.images.knownFile('/missing.png', 'original'), isNull);
    expect(
      await tester.runAsync(() => catalog.images.directory.list().length),
      9,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('20次进入退出不重复解码背景，缓存有界且没有残留监听器', (tester) async {
    await prepare(tester);
    late BuildContext context;
    await tester.pumpWidget(
      frame(
        Builder(
          builder: (value) {
            context = value;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    precacheFilmDetailArtwork(context, catalog.images, works.first);
    await settle(tester);
    final cache = PaintingBinding.instance.imageCache;
    final file = catalog.images.knownFile(
      works.first.backdropPath,
      'original',
    )!;
    final provider = filmArtworkProvider(
      file,
      target: 'original',
      backdrop: true,
    );
    final original = await decode(tester, provider);
    final initialBytes = cache.currentSizeBytes;
    int? settledBytes;
    for (var i = 0; i < 20; i++) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => FilmDetailPage(
            catalog: catalog,
            workId: works.first.id,
            initialWork: works.first,
            onOpenItem: (_) async {},
          ),
        ),
      );
      await tester.pump();
      expect(
        tester
            .widgetList<RawImage>(backdropImages())
            .every((image) => image.image?.isCloneOf(original) ?? false),
        isTrue,
      );
      await settle(tester);
      settledBytes ??= cache.currentSizeBytes;
      expect(cache.currentSizeBytes, settledBytes);
      Navigator.of(context).pop();
      await settle(tester);
    }
    expect(cache.currentSizeBytes, lessThanOrEqualTo(settledBytes!));
    expect(cache.maximumSizeBytes, 100 * 1024 * 1024);
    expect(cache.liveImageCount, 0);
    expect(cache.pendingImageCount, 0);
    expect(find.byType(FilmDetailPage), findsNothing);
    expect(tester.takeException(), isNull);
    stdout.writeln(
      'IMAGE_CACHE_20_CYCLES initial_bytes=$initialBytes final_bytes=${cache.currentSizeBytes} live=${cache.liveImageCount} pending=${cache.pendingImageCount}',
    );
  });

  testWidgets('改变图片路径不保留上一部背景，清理缓存同步废弃文件位置', (tester) async {
    await prepare(tester);
    for (final work in works.take(2)) {
      final file = (await tester.runAsync(
        () => catalog.images.cached(work.backdropPath!, 'original'),
      ))!;
      await decode(
        tester,
        filmArtworkProvider(file, target: 'original', backdrop: true),
      );
    }
    Widget artwork(FilmWork work) => frame(
      FilmArtwork(
        cache: catalog.images,
        path: work.backdropPath,
        target: 'original',
        backdrop: true,
        height: double.infinity,
      ),
    );
    await tester.pumpWidget(artwork(works.first));
    await tester.pumpWidget(artwork(works[1]));
    final file = catalog.images.knownFile(works[1].backdropPath, 'original')!;
    expect(
      tester
          .widgetList<Image>(find.byType(Image))
          .every((image) => (image.image as FileImage).file.path == file.path),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => catalog.images.clear());
    expect(catalog.images.knownFile(works[1].backdropPath, 'original'), isNull);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<ui.Image> decode(
  WidgetTester tester,
  ImageProvider<Object> provider,
) async {
  final result = await tester.runAsync(() async {
    final stream = provider.resolve(ImageConfiguration.empty);
    ui.Image? image;
    final listener = ImageStreamListener(
      (info, _) => image = info.image.clone(),
    );
    stream.addListener(listener);
    while (image == null) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    stream.removeListener(listener);
    return image!;
  });
  addTearDown(result!.dispose);
  return result;
}

class _ServerTestAppState extends ShellTestAppState {
  _ServerTestAppState({
    required super.configStore,
    required super.playbackHistoryStore,
    required super.mediaLibraryStore,
    required super.progressService,
  });
  final servers = <MediaConnection>[];
  final serverRefresh = Completer<void>();
  Completer<void>? catalogGate;
  Object? catalogFailure;
  int refreshes = 0;
  @override
  List<MediaConnection> get mediaConnections => servers;
  @override
  Future<FilmCatalogController> getFilmCatalog() async {
    await catalogGate?.future;
    if (catalogFailure case final failure?) throw failure;
    return super.getFilmCatalog();
  }

  @override
  Future<void> refreshMediaServer(String id, {bool metadata = true}) async {
    refreshes++;
    await serverRefresh.future;
  }
}
