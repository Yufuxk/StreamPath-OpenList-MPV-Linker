import 'package:streampath/presentation/widgets/film_watch_overlay.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';
import 'package:streampath/data/models/video_queue.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/pages/film_detail_page.dart';
import 'package:streampath/presentation/pages/film_library_page.dart';
import 'package:streampath/presentation/pages/film_media_center_page.dart';
import 'package:streampath/presentation/pages/media_library_page.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/theme/window_appearance_status.dart';
import 'package:streampath/presentation/widgets/film_artwork_picker.dart';
import 'package:streampath/presentation/widgets/film_continue_card.dart';
import 'package:streampath/presentation/widgets/film_shelf.dart';
import 'package:streampath/presentation/widgets/directory_wheel_scroll_region.dart';
import 'package:streampath/presentation/widgets/film_work_menu.dart';

import 'helpers/shell_test_app_state.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory temp;
  late ShellTestAppState app;
  late FilmCatalogController c;
  late PlaybackProgressService progress;
  late FilmCatalogRoot root;
  late List<FilmResource> resources;
  late File picture;
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Widget frame(
    Widget page, {
    ThemeData? theme,
    AppLanguage language = AppLanguage.simplifiedChinese,
    double scale = 1,
  }) => ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      locale: language.locale,
      supportedLocales: AppLanguage.values.map((l) => l.locale),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: RepaintBoundary(key: const Key('phase4-frame'), child: child!),
      ),
      theme: theme ?? AppTheme.dark(fontFamily: 'FilmTestFont'),
      home: page,
    ),
  );
  Future<void> render(WidgetTester tester, String name) async {
    if (Platform.environment['FILM_PHASE4_RENDER'] != '1') return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('phase4-frame')),
      );
      final image = await boundary.toImage(pixelRatio: 1);
      final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      image.dispose();
      final out = File(
        p.join(
          Directory.current.path,
          'build',
          'film_phase4_visuals',
          '$name.png',
        ),
      );
      await out.parent.create(recursive: true);
      await out.writeAsBytes(data.buffer.asUint8List());
    });
  }

  Future<void> prepare(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('film_phase4_ui_');
      final config = StreamPathConfigStore.forPath(
        p.join(temp.path, 'config.json'),
      );
      await config.save(
        StreamPathConfig(
          localRoots: [
            LocalRootConfig(
              rootId: 'fixture',
              displayName: 'Fixture',
              path: temp.path,
            ),
          ],
        ),
      );
      progress = await PlaybackProgressService.open(
        p.join(temp.path, 'streampath.db'),
      );
      app = ShellTestAppState(
        configStore: config,
        playbackHistoryStore: PlaybackHistoryStore.forPath(
          p.join(temp.path, 'history.json'),
        ),
        mediaLibraryStore: MediaLibraryStore.forPath(
          p.join(temp.path, 'records.json'),
        ),
        progressService: progress,
      );
      c = await app.getFilmCatalog();
      final id = await c.store.addRoot(
        sourceId: 'local:fixture',
        kind: MediaSourceKind.local,
        path: 'Movies',
        type: FilmMediaType.movie,
        name: 'Movies',
      );
      root = (await c.store.root(id))!;
      final generation = await c.store.beginScan(id);
      await c.store.stage(root, generation, [
        for (final name in ['a.mkv', 'b.mkv', 'c.mkv'])
          FilmScanEntry(
            path: 'Movies/$name',
            parentPath: 'Movies',
            name: name,
            mediaKind: 'video',
          ),
      ]);
      await c.store.commitScan(id, generation, cancelled: () => false);
      resources = await c.store.resources();
      await c.store.bind(
        resources.take(2).toList(),
        const FilmWork(
          type: FilmMediaType.movie,
          tmdbId: 1,
          title: 'A long film title that must remain on a single line',
          originalTitle: 'Long title',
          overview: 'Offline fixture',
          language: 'zh-CN',
          year: 2024,
          posterPath: '/poster.jpg',
          metadata: {
            'runtime': 100,
            'genres': ['动画'],
            'origin_country': ['JP'],
          },
        ),
      );
      await c.store.bind(
        [resources.last],
        const FilmWork(
          type: FilmMediaType.movie,
          tmdbId: 2,
          title: 'Second film',
          originalTitle: 'Second film',
          overview: '',
          language: 'zh-CN',
          year: 1998,
          posterPath: '/second.jpg',
          metadata: {
            'genres': ['科幻'],
            'origin_country': ['US'],
          },
        ),
      );
      resources = await c.store.resources();
      await c.store.saveProbe(resources.first.id, {
        'duration': 7200,
        'state': 'complete',
      });
      await c.store.saveProbe(resources[1].id, {
        'duration': 7500,
        'state': 'complete',
      });
      await c.store.setFavorite(resources.first.workId!, true);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 240, 360),
        Paint()..color = const Color(0xFF284D79),
      );
      canvas.drawCircle(
        const Offset(120, 145),
        72,
        Paint()..color = const Color(0xFF67B7D1),
      );
      final drawing = recorder.endRecording();
      final image = await drawing.toImage(240, 360);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      drawing.dispose();
      image.dispose();
      picture = File(p.join(temp.path, 'chosen.png'));
      await picture.writeAsBytes(bytes);
      await c.images.directory.create(recursive: true);
      await File(
        p.join(
          c.images.directory.path,
          '${FilmCatalogImageCache.cacheKey('/poster.jpg', 'w342')}.img',
        ),
      ).writeAsBytes(bytes);
      final font = File(r'C:\Windows\Fonts\msyh.ttc');
      if (await font.exists()) {
        final loader = FontLoader('FilmTestFont')
          ..addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          );
        await loader.load();
      }
      await app.initializeFilmPlayback();
      await c.refresh();
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        app.dispose();
        await app.closeTestStores();
        await progress.close();
        await temp.delete(recursive: true);
      });
    });
  }

  Future<void> seedContinue(WidgetTester tester) async {
    await tester.runAsync(() async {
      await app.filmMediaLibraryStore!.recordPlayback(
        resources.first.playbackItem,
        playbackSessionId: 'film',
      );
      await app.filmProgressService.saveProgress(
        url: p.join(temp.path, 'Movies', 'a.mkv'),
        profileId: root.sourceId,
        positionMs: 90000,
        durationMs: 7200000,
      );
    });
  }

  testWidgets('收藏封面与标题年份在窗口、放大及高 DPI 下保持同一左边界', (tester) async {
    await prepare(tester);
    for (final dimensions in [(1280.0, 1.0), (1920.0, 1.0), (2560.0, 1.5)]) {
      tester.view.physicalSize = Size(dimensions.$1, 1080);
      tester.view.devicePixelRatio = dimensions.$2;
      final works = await tester.runAsync(
        () => c.store.works(type: FilmMediaType.movie),
      );
      await tester.pumpWidget(
        frame(
          Scaffold(
            body: FilmPosterGrid(
              store: c.store,
              works: works!,
              cache: c.images,
              onOpen: (_) {},
              onMenu: (_, _) {},
            ),
          ),
          scale: dimensions.$2,
        ),
      );
      await settle(tester);
      final card = find.byType(FilmWorkCard).first;
      final artwork = find
          .descendant(of: card, matching: find.byType(FilmArtwork))
          .first;
      final title = find.descendant(
        of: card,
        matching: find.text(works.first.title),
      );
      final year = find.descendant(
        of: card,
        matching: find.text('${works.first.year}'),
      );
      expect(
        tester.getTopLeft(artwork).dx,
        closeTo(tester.getTopLeft(title).dx, .01),
      );
      expect(
        tester.getTopLeft(artwork).dx,
        closeTo(tester.getTopLeft(year).dx, .01),
      );
      expect(tester.takeException(), isNull);
      await render(
        tester,
        'implicit_favorites_${dimensions.$1}_${dimensions.$2}',
      );
    }
  });

  testWidgets('主页滚轮在内容和空白处只滚动一次，任务刷新保持控制器与位置', (tester) async {
    await prepare(tester);
    tester.view.physicalSize = const Size(1280, 640);
    await tester.pumpWidget(frame(FilmLibraryPage(onOpenItem: (_) async {})));
    await settle(tester);
    final region = find.byType(DirectoryWheelScrollRegion);
    final controller = tester
        .widget<DirectoryWheelScrollRegion>(region)
        .controller;
    expect(controller.positions, hasLength(1));
    final pointer = TestPointer(4, PointerDeviceKind.mouse);
    Future<void> wheel(Offset location) async {
      await tester.sendEventToBinding(pointer.hover(location));
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: location,
          scrollDelta: const Offset(0, 80),
        ),
      );
      await tester.pump();
    }

    final area = tester.getRect(region);
    await wheel(Offset(area.left + 60, area.top + 60));
    expect(controller.offset, 80);
    c.busy = true;
    c.scrapePaused = true;
    c.scrapeError = 'noToken';
    await tester.runAsync(() => c.refresh());
    await tester.pump();
    expect(
      tester.widget<DirectoryWheelScrollRegion>(region).controller,
      same(controller),
    );
    expect(controller.offset, 80);
    final refreshed = tester.getRect(region);
    await wheel(Offset(refreshed.right - 50, refreshed.top + 40));
    expect(controller.offset, 160);
    c.busy = false;
    c.scrapeError = null;
    await tester.runAsync(() => c.refresh());
    await tester.pump();
    expect(controller.offset, 160);
    expect(tester.takeException(), isNull);
  });

  testWidgets('封面未观看角标、观看中进度和已看清除使用独立状态', (tester) async {
    await prepare(tester);
    final item = resources.first;
    await tester.pumpWidget(
      frame(
        Center(
          child: SizedBox(
            width: 200,
            height: 300,
            child: FilmWatchOverlay(
              store: c.store,
              resource: item,
              child: const ColoredBox(color: Colors.blue),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    final overlay = find.byType(FilmWatchOverlay);
    expect(
      find.descendant(of: overlay, matching: find.byType(CustomPaint)),
      findsOneWidget,
    );
    await tester.runAsync(
      () => c.store.recordVideoProgress(
        VideoProgressUpdate(
          sourceId: item.sourceId,
          path: item.path,
          positionMs: 50,
          durationMs: 100,
          recordedAt: DateTime.now(),
        ),
      ),
    );
    await settle(tester);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      .5,
    );
    await tester.runAsync(() => c.store.markWatched([item], true));
    await settle(tester);
    expect(
      find.descendant(of: overlay, matching: find.byType(CustomPaint)),
      findsNothing,
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.runAsync(() => c.store.markWatched([item], false));
    await settle(tester);
    expect(
      find.descendant(of: overlay, matching: find.byType(CustomPaint)),
      findsOneWidget,
    );
  });

  testWidgets('外部与顶部作品菜单标记所有季，季菜单只标记当前季并包含手动光盘', (tester) async {
    await prepare(tester);
    final series = (await tester.runAsync(() async {
      final id = await c.store.addRoot(
        sourceId: root.sourceId,
        kind: root.sourceKind,
        path: 'TV',
        type: FilmMediaType.tv,
        name: 'TV',
      );
      final tvRoot = (await c.store.root(id))!;
      final generation = await c.store.beginScan(id);
      await c.store.stage(tvRoot, generation, [
        for (final (name, kind) in [
          ('e1.mkv', 'video'),
          ('e2.mkv', 'video'),
          ('disc.iso', 'iso'),
        ])
          FilmScanEntry(
            path: 'TV/$name',
            parentPath: 'TV',
            name: name,
            mediaKind: kind,
          ),
      ]);
      await c.store.commitScan(id, generation, cancelled: () => false);
      await c.store.bind(
        await c.store.resources(rootId: id),
        const FilmWork(
          type: FilmMediaType.tv,
          tmdbId: 77,
          title: 'Series',
          originalTitle: 'Series',
          overview: '',
          language: 'zh-CN',
          metadata: {'presentation_version': 3},
        ),
      );
      final rows = await c.store.resources(rootId: id);
      await c.store.mapEpisodes({
        for (final r in rows.where((r) => !r.isDisc))
          r: (r.name == 'e1.mkv' ? 1 : 2, 1),
      });
      return (await c.store.work(rows.first.workId!))!;
    }))!;
    await tester.pumpWidget(
      frame(
        Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: SizedBox(
                width: 174,
                height: 304,
                child: FilmWorkCard(
                  store: c.store,
                  work: series,
                  cache: c.images,
                  onTap: () {},
                  onMenu: (position) => showFilmWorkMenu(
                    context,
                    catalog: c,
                    work: series,
                    position: position,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.byType(FilmWorkCard), buttons: kSecondaryMouseButton);
    await settle(tester);
    expect(find.text('标记已看完'), findsOneWidget);
    await tester.tap(find.text('标记已看完'));
    await settle(tester);
    Future<List<FilmResource>> rows() => c.store.resources(workId: series.id);
    Future<List<bool>> marks() async => [
      for (final r in await rows())
        (await c.store.resourceWatchState(r))!.fraction == 1,
    ];
    expect(await tester.runAsync(marks), everyElement(true));
    await tester.pumpWidget(
      frame(
        FilmDetailPage(catalog: c, workId: series.id, onOpenItem: (_) async {}),
      ),
    );
    await settle(tester);
    await tester.tap(
      find.byKey(const Key('film-detail-poster')),
      buttons: kSecondaryMouseButton,
    );
    await settle(tester);
    await tester.tap(find.text('标记未观看'));
    await settle(tester);
    expect(await tester.runAsync(marks), everyElement(false));
    await tester.ensureVisible(find.byKey(const ValueKey('film-season-1')));
    await tester.tap(
      find.byKey(const ValueKey('film-season-1')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(find.byWidgetPredicate((w) => w is PopupMenuItem), findsNWidgets(2));
    await render(tester, 'minimal_season_watch_menu');
    await tester.tap(find.text('标记已看完'));
    await settle(tester);
    final states = await tester.runAsync(
      () async => {
        for (final r in await rows())
          r.name: (await c.store.resourceWatchState(r))!.fraction,
      },
    );
    expect(states, {'e1.mkv': 1.0, 'e2.mkv': 0.0, 'disc.iso': 0.0});
    expect(tester.takeException(), isNull);
  });

  for (final hasContinue in [true, false]) {
    testWidgets(
      'Home return preserves the first frame (continue: $hasContinue)',
      (tester) async {
        await prepare(tester);
        if (hasContinue) await seedContinue(tester);
        await tester.pumpWidget(
          frame(FilmLibraryPage(sidebarInset: 64, onOpenItem: (_) async {})),
        );
        await settle(tester);
        final state = tester.state(
          find.byType(MediaLibraryPage, skipOffstage: false),
        );
        final sourceTop = tester.getTopLeft(
          find.widgetWithText(Card, 'Movies').last,
        );
        for (var i = 0; i < 3; i++) {
          await tester.tap(find.widgetWithText(Card, 'Movies').last);
          await settle(tester);
          expect(find.byType(FilmContinueCard), findsNothing);
          await tester.tap(find.text('主页'));
          await tester.pump();
          expect(
            find.byType(FilmContinueCard),
            hasContinue ? findsOneWidget : findsNothing,
          );
          expect(
            tester.state(find.byType(MediaLibraryPage, skipOffstage: false)),
            same(state),
          );
          expect(
            tester.getTopLeft(find.widgetWithText(Card, 'Movies').last),
            sourceTop,
          );
          await settle(tester);
        }
        if (hasContinue) {
          await tester.tap(find.widgetWithText(Card, 'Movies').last);
          await settle(tester);
          await tester.runAsync(
            () => app.filmMediaLibraryStore!.removePlayback(
              resources.first.playbackItem,
            ),
          );
          await settle(tester);
          await tester.tap(find.text('主页'));
          await tester.pump();
          expect(find.byType(FilmContinueCard), findsNothing);
          expect(find.text('继续播放'), findsNothing);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Expanded continue shares the library background and sidebar inset',
    (tester) async {
      await prepare(tester);
      await seedContinue(tester);
      await tester.runAsync(() async {
        await c.store.setBackgroundPath(picture.path);
        await c.refresh();
      });
      var plays = 0;
      var menus = 0;
      await tester.pumpWidget(
        frame(
          FilmLibraryPage(
            sidebarInset: 64,
            onOpenItem: (_) async {},
            onContinueSelected: (_) => plays++,
            onContinueMenu: (_, _) => menus++,
          ),
        ),
      );
      await settle(tester);
      final homeHeader = tester.getRect(find.byType(AppBar));
      final homeTitle = tester.getTopLeft(find.text('影视库'));
      final continueShelf = find.byWidgetPredicate(
        (w) => w is FilmShelf && w.title == '继续播放',
      );
      await tester.tap(
        find.descendant(of: continueShelf, matching: find.text('查看全部')),
      );
      await settle(tester);
      expect(tester.getRect(find.byType(AppBar)), homeHeader);
      expect(tester.getTopLeft(find.text('继续播放')), homeTitle);
      expect(tester.getTopLeft(find.byType(FilmContinueCard)).dx, 84);
      expect(
        tester.widget<FilmContinueCard>(find.byType(FilmContinueCard)).poster,
        isFalse,
      );
      final background = find.byKey(const Key('film-library-background'));
      expect(background, findsOneWidget);
      expect(tester.getRect(background), const Rect.fromLTWH(0, 0, 1280, 900));
      final image = tester.widget<Image>(
        find.descendant(of: background, matching: find.byType(Image)),
      );
      expect((image.image as FileImage).file.path, picture.path);
      await render(tester, 'continue-expanded');
      await tester.tap(find.byType(FilmContinueCard));
      await tester.tap(
        find.byType(FilmContinueCard),
        buttons: kSecondaryMouseButton,
      );
      expect(plays, 1);
      expect(menus, 1);
      await tester.runAsync(() async {
        await c.store.setBackgroundPath(null);
        await c.refresh();
      });
      for (final theme in [
        AppTheme.dark(),
        AppTheme.dark(glass: true, windowBackdrop: WindowBackdropType.mica),
        AppTheme.light(
          glass: true,
          windowBackdrop: WindowBackdropType.systemAcrylic,
        ),
      ]) {
        await tester.pumpWidget(
          frame(
            FilmLibraryPage(sidebarInset: 64, onOpenItem: (_) async {}),
            theme: theme,
          ),
        );
        await settle(tester);
        expect(
          tester.widget<ColoredBox>(background).color,
          theme.scaffoldBackgroundColor,
        );
        expect(tester.getRect(find.byType(AppBar)), homeHeader);
      }
      await tester.tap(find.text('主页'));
      await tester.pump();
      await settle(tester);
      expect(find.byType(FilmContinueCard), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('默认背景随主题材质变化，筛选无布局进度条，封面单行并轻微放大', (tester) async {
    await prepare(tester);
    final page = FilmLibraryPage(onOpenItem: (_) async {});
    for (final theme in [
      AppTheme.dark(),
      AppTheme.dark(glass: true, windowBackdrop: WindowBackdropType.mica),
      AppTheme.light(
        glass: true,
        windowBackdrop: WindowBackdropType.systemAcrylic,
      ),
    ]) {
      await tester.pumpWidget(frame(page, theme: theme));
      await settle(tester);
      expect(
        tester
            .widget<ColoredBox>(
              find.byKey(const Key('film-library-background')),
            )
            .color,
        theme.scaffoldBackgroundColor,
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
    }
    await tester.pumpWidget(frame(page));
    await settle(tester);
    final card = find.byType(FilmWorkCard).first;
    final title = tester
        .widgetList<Text>(
          find.descendant(of: card, matching: find.byType(Text)),
        )
        .firstWhere((w) => w.data!.startsWith('A long film'));
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer();
    await pointer.moveTo(tester.getCenter(card));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester
          .widget<AnimatedScale>(
            find.descendant(of: card, matching: find.byType(AnimatedScale)),
          )
          .scale,
      1.04,
    );
    await pointer.removePointer();
    await render(tester, 'home');
    final source = find.widgetWithText(Card, 'Movies').last;
    final rightClick = await tester.createGesture(
      buttons: kSecondaryMouseButton,
    );
    await rightClick.down(tester.getCenter(source));
    await tester.pump(const Duration(milliseconds: 200));
    await rightClick.up();
    await settle(tester);
    expect(find.text('编辑影视目录'), findsOneWidget);
    expect(find.text('修改图片'), findsOneWidget);
    expect(find.text('设置影视库背景'), findsNothing);
    await tester.tap(find.text('编辑影视目录'));
    await settle(tester);
    final name = find.byWidgetPredicate(
      (w) => w is TextField && w.controller?.text == 'Movies',
    );
    await tester.enterText(name, 'Renamed source');
    await tester.tap(find.text('保存'));
    await settle(tester);
    expect(
      (await tester.runAsync(() => c.store.root(root.id)))!.displayName,
      'Renamed source',
    );
    expect(
      (await tester.runAsync(() => c.store.resources()))!.first.workId,
      resources.first.workId,
    );
    await tester.pumpWidget(
      frame(
        FilmDetailPage(
          catalog: c,
          workId: resources.first.workId!,
          onOpenItem: (_) async {},
        ),
      ),
    );
    await settle(tester);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('film-detail-metadata')))
          .textSpan!
          .toPlainText(),
      contains('影片时长：120 & 125 分钟'),
    );
    await tester.tap(
      find.byKey(const Key('film-detail-poster')),
      buttons: kSecondaryMouseButton,
    );
    await settle(tester);
    expect(find.text('纠正作品匹配'), findsOneWidget);
    await tester.tapAt(const Offset(1150, 850));
    await settle(tester);
    await render(tester, 'detail');
    expect(tester.takeException(), isNull);
  });

  testWidgets('本地与已缓存图片持久复制，自定义来源固定封面，默认恢复轮换', (tester) async {
    await prepare(tester);
    const channel = MethodChannel('streampath/folder_picker');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      expect(call.method, 'pickImage');
      return picture.path;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(
      frame(
        Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                TextButton(
                  onPressed: () =>
                      showFilmArtworkPicker(context, c, rootId: root.id),
                  child: const Text('Open'),
                ),
                TextButton(
                  onPressed: () => showFilmArtworkPicker(context, c),
                  child: const Text('Background'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await settle(tester);
    expect(find.byType(Image), findsOneWidget);
    await tester.runAsync(() async {
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '选择本地图片'))
          .onPressed!();
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await settle(tester);
    final custom = await tester.runAsync(
      () => c.store.customRootCover(root.id),
    );
    expect(
      custom,
      isNotNull,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data)
          .join('|'),
    );
    expect(custom, contains('film_custom_artwork'));
    await tester.tap(find.text('Background'));
    await settle(tester);
    final gallery = find
        .ancestor(of: find.byType(Image), matching: find.byType(InkWell))
        .first;
    await tester.runAsync(() async {
      tester.widget<InkWell>(gallery).onTap!();
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await settle(tester);
    expect(c.backgroundFile?.path, custom);
    await tester.runAsync(() async {
      await picture.delete();
      await c.images.clear();
      await c.refresh();
    });
    expect(c.rootCoverFiles[root.id]!.path, custom);
    expect(await tester.runAsync(() => File(custom!).exists()), isTrue);
    await tester.tap(find.text('Open'));
    await settle(tester);
    await tester.tap(find.text('默认'));
    await settle(tester);
    expect(
      await tester.runAsync(() => c.store.customRootCover(root.id)),
      isNull,
    );
    expect(c.rootCoverFiles[root.id], isNull);
    expect(await tester.runAsync(() => c.backgroundFile!.exists()), isTrue);
    await tester.tap(find.text('Background'));
    await settle(tester);
    await tester.tap(find.text('默认'));
    await settle(tester);
    expect(c.backgroundFile, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('媒体中心新增入口在四语言、窄宽窗口和大字号下可访问', (tester) async {
    await prepare(tester);
    final page = FilmMediaCenterPage(
      onOpenItem: (_) {},
      onContinueSelected: (_) {},
      onContinueMenu: (_, _) {},
      onOpenLegacyItem: (_) {},
    );
    for (final language in AppLanguage.values) {
      for (final width in [720.0, 900.0, 1280.0]) {
        for (final scale in [1.0, 2.0]) {
          tester.view.physicalSize = Size(width, 900);
          await tester.pumpWidget(
            frame(page, language: language, scale: scale),
          );
          await settle(tester);
          expect(
            find.text(AppLocalizations(language).text('旧媒体中心')),
            findsOneWidget,
          );
          expect(
            tester.takeException(),
            isNull,
            reason: '$language $width $scale',
          );
        }
      }
    }
  });

  testWidgets('新中心三页签、影视标题搜索、继续进度，旧中心保留布局与来源入口', (tester) async {
    await prepare(tester);
    await tester.runAsync(() async {
      await app.filmMediaLibraryStore!.recordPlayback(
        resources.first.playbackItem,
        playbackSessionId: 'film',
      );
      await app.filmProgressService.saveProgress(
        url: p.join(temp.path, 'Movies', 'a.mkv'),
        profileId: root.sourceId,
        positionMs: 90000,
        durationMs: 7200000,
      );
    });
    var plays = 0;
    await tester.pumpWidget(
      frame(
        FilmMediaCenterPage(
          onOpenItem: (_) => plays++,
          onContinueSelected: (_) => plays++,
          onContinueMenu: (_, _) {},
          onOpenLegacyItem: (_) {},
        ),
      ),
    );
    await settle(tester);
    expect(tester.widget<TabBar>(find.byType(TabBar)).tabs, hasLength(3));
    expect(find.text('目录'), findsNothing);
    expect(find.text('音频'), findsNothing);
    final header = tester.getRect(find.byType(AppBar));
    final title = tester.getRect(find.text('媒体中心'));
    final filter = tester.getRect(
      find.byKey(const Key('media-library-source-filter')),
    );
    await render(tester, 'center-favorites');
    await tester.tap(find.text('继续播放'));
    await settle(tester);
    expect(find.text('已播放 0:01:30'), findsOneWidget);
    expect(
      tester.widget<FilmContinueCard>(find.byType(FilmContinueCard)).poster,
      isTrue,
    );
    await render(tester, 'center-continue');
    await tester.tap(find.byType(FilmContinueCard));
    await settle(tester);
    expect(plays, 1);
    await tester.tap(find.text('最近播放'));
    await settle(tester);
    expect(
      find.text('A long film title that must remain on a single line'),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField), 'Second');
    await settle(tester);
    expect(find.byType(FilmContinueCard), findsNothing);
    await tester.enterText(find.byType(TextField), 'long film');
    await settle(tester);
    expect(find.byType(FilmContinueCard), findsOneWidget);
    await tester.tap(find.text('旧媒体中心'));
    await settle(tester);
    expect(tester.widget<TabBar>(find.byType(TabBar)).tabs, hasLength(4));
    expect(find.text('音频'), findsOneWidget);
    expect(tester.getRect(find.byType(AppBar)), header);
    expect(tester.getRect(find.text('媒体中心')).topLeft, title.topLeft);
    expect(tester.getRect(find.text('媒体中心')).height, title.height);
    expect(
      tester.getRect(find.byKey(const Key('media-library-source-filter'))),
      filter,
    );
    await render(tester, 'center-legacy');
    await tester.tap(find.text('返回新媒体中心'));
    await settle(tester);
    expect(tester.widget<TabBar>(find.byType(TabBar)).tabs, hasLength(3));
    expect(tester.takeException(), isNull);
  });
}
