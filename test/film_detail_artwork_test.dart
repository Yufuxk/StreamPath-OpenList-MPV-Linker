import 'package:streampath/presentation/widgets/transition_content.dart';
import 'package:streampath/presentation/widgets/film_connected_transition.dart';
import 'package:streampath/presentation/widgets/skeleton_scope.dart';
import 'package:streampath/presentation/widgets/cinematic_states.dart';
import 'package:streampath/presentation/widgets/adaptive_film_backdrop.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
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
import 'package:streampath/data/models/video_queue.dart';
import 'package:streampath/data/models/media_connection.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/pages/film_detail_page.dart';
import 'package:streampath/presentation/pages/film_library_page.dart';
import 'package:streampath/presentation/pages/film_library_shell.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/theme/window_appearance_status.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';
import 'package:streampath/presentation/widgets/film_shelf.dart';
import 'package:streampath/presentation/widgets/film_library_background.dart';
import 'package:streampath/presentation/widgets/directory_scroll_view.dart';
import 'package:streampath/presentation/pages/film_related_page.dart';
import 'package:streampath/data/models/film_home_section.dart';
import 'package:streampath/presentation/pages/film_featured_page.dart';
import 'package:streampath/presentation/widgets/film_featured_showcase.dart';
import 'package:streampath/presentation/widgets/film_segmented_control.dart';
import 'package:streampath/presentation/widgets/film_detail_backdrop.dart';
import 'package:streampath/presentation/widgets/film_detail_back_button.dart';
import 'package:streampath/presentation/widgets/film_watch_overlay.dart';
import 'package:streampath/presentation/widgets/film_continue_card.dart';
import 'package:streampath/presentation/widgets/film_certification_badge.dart';
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

  Future<void> prepare(WidgetTester tester, {int count = 3}) async {
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
        for (var i = 0; i < count; i++)
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
      for (var i = 0; i < count; i++) {
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
          if (target == 'original') {
            await catalog.images.backdropBlurs.get(
              File(
                p.join(
                  catalog.images.directory.path,
                  '${FilmCatalogImageCache.cacheKey(path, target)}.img',
                ),
              ),
            );
          }
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

  testWidgets('电影资源卡片显示片名、真实文件名、上映日期与时长且点击播放', (tester) async {
    await prepare(tester, count: 1);
    final resource = (await tester.runAsync(
      () => catalog.store.resources(),
    ))!.single;
    var plays = 0;
    final cjkFont = File(r'C:\Windows\Fonts\msyh.ttc');
    if (cjkFont.existsSync()) {
      await tester.runAsync(() async {
        final loader = FontLoader('MovieCardPreview')
          ..addFont(
            Future.value(ByteData.sublistView(await cjkFont.readAsBytes())),
          );
        await loader.load();
      });
    }
    final previewTheme = AppTheme.dark();
    final cardBoundary = GlobalKey();
    await tester.pumpWidget(
      frame(
        Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: cardBoundary,
              child: Theme(
                data: previewTheme.copyWith(
                  textTheme: previewTheme.textTheme.apply(
                    fontFamily: cjkFont.existsSync()
                        ? 'MovieCardPreview'
                        : null,
                  ),
                ),
                child: SizedBox(
                  width: 320,
                  child: FilmEpisodeCard(
                    catalog: catalog,
                    resource: resource,
                    state: '可用',
                    displayTitle: '流浪地球 2',
                    releaseDate: '2023-01-22',
                    probe: const {'duration': 10380},
                    onOpenItem: (_) async => plays++,
                    onChanged: () async {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('流浪地球 2'), findsOneWidget);
    expect(find.text('0.mkv'), findsOneWidget);
    expect(find.text('2023-01-22'), findsOneWidget);
    expect(find.text('173 分钟'), findsOneWidget);
    expect(find.text('播放此文件'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final boundary =
          cardBoundary.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final output = Directory('build/movie-card-detail')
        ..createSync(recursive: true);
      await File(
        p.join(output.path, 'movie-card.png'),
      ).writeAsBytes(png!.buffer.asUint8List());
      image.dispose();
    });
    await tester.tap(find.text('0.mkv'));
    await tester.pump();
    expect(plays, 1);
  });

  testWidgets('电影详情关联资源显示片名、真实文件名与上映日期', (tester) async {
    await prepare(tester, count: 1);
    final original = works.single;
    await tester.runAsync(() async {
      await catalog.store.setPreference('spoiler_protection', false);
      await catalog.store.refreshWork(
        FilmWork(
          id: original.id,
          type: original.type,
          tmdbId: original.tmdbId,
          title: '流浪地球 2',
          originalTitle: original.originalTitle,
          overview: '',
          language: original.language,
          posterPath: original.posterPath,
          backdropPath: original.backdropPath,
          metadata: const {
            'presentation_version': 4,
            'release_date': '2023-01-22',
          },
        ),
      );
    });
    MediaLibraryItem? opened;
    await tester.pumpWidget(
      frame(
        FilmDetailPage(
          catalog: catalog,
          workId: original.id,
          onOpenItem: (item) async => opened = item,
        ),
      ),
    );
    await settle(tester);
    final file = find.text('0.mkv');
    await tester.scrollUntilVisible(
      file,
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('2023-01-22'), findsOneWidget);
    await tester.tap(file);
    await tester.pump();
    expect(opened?.targetPath, '0.mkv');
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情简介仅在溢出时渐隐并可展开收起，缺图演职员显示姓名缩写', (tester) async {
    await prepare(tester, count: 1);
    final original = works.single;
    Future<void> updateOverview(String overview) async {
      await tester.runAsync(() async {
        await catalog.store.setPreference('spoiler_protection', false);
        await catalog.store.refreshWork(
          FilmWork(
            id: original.id,
            type: original.type,
            tmdbId: original.tmdbId,
            title: original.title,
            originalTitle: original.originalTitle,
            overview: overview,
            language: original.language,
            posterPath: original.posterPath,
            backdropPath: original.backdropPath,
            metadata: {
              ...original.metadata,
              'vote_average': 8.6,
              'genres': ['Animation', 'Drama'],
              'credits': {
                'crew': [
                  {'name': 'Andy Smith', 'job': 'Director'},
                  {'name': '丸户史明', 'job': 'Original Story'},
                  {'name': '𠮷田', 'job': 'Writer'},
                ],
              },
            },
          ),
        );
      });
    }

    final long =
        'A long synopsis with enough words to exceed four lines. ' * 24;
    await updateOverview(long);
    await tester.pumpWidget(
      frame(
        FilmDetailPage(
          catalog: catalog,
          workId: original.id,
          onOpenItem: (_) async {},
        ),
      ),
    );
    await settle(tester);
    expect(
      find.ancestor(of: find.text(long), matching: find.byType(ShaderMask)),
      findsOneWidget,
    );
    expect(find.text('AS'), findsOneWidget);
    expect(find.text('丸'), findsOneWidget);
    expect(find.text('𠮷'), findsOneWidget);
    final expand = find.widgetWithText(TextButton, '展开简介');
    await tester.ensureVisible(expand);
    await tester.tap(expand);
    await settle(tester);
    expect(tester.widget<Text>(find.text(long)).maxLines, isNull);
    expect(
      find.ancestor(of: find.text(long), matching: find.byType(ShaderMask)),
      findsNothing,
    );
    final collapse = find.widgetWithText(TextButton, '收起简介');
    await tester.ensureVisible(collapse);
    await tester.tap(collapse);
    await settle(tester);
    expect(tester.widget<Text>(find.text(long)).maxLines, 4);
    expect(
      find.ancestor(of: find.text(long), matching: find.byType(ShaderMask)),
      findsOneWidget,
    );
    await updateOverview('Short synopsis.');
    await settle(tester);
    expect(find.text('Short synopsis.'), findsOneWidget);
    expect(find.text('展开简介'), findsNothing);
    expect(find.text('收起简介'), findsNothing);
    expect(
      find.ancestor(
        of: find.text('Short synopsis.'),
        matching: find.byType(ShaderMask),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('演职人员头像复用封面悬停放大，文字不动且命中区不随缩放扩大', (tester) async {
    await prepare(tester, count: 1);
    final original = works.single;
    await tester.runAsync(() async {
      await catalog.store.refreshWork(
        FilmWork(
          id: original.id,
          type: original.type,
          tmdbId: original.tmdbId,
          title: original.title,
          originalTitle: original.originalTitle,
          overview: 'Synopsis.',
          language: original.language,
          posterPath: original.posterPath,
          backdropPath: original.backdropPath,
          metadata: {
            ...original.metadata,
            'credits': {
              'cast': [
                {'id': 1, 'name': 'Andy Smith', 'character': 'Hero'},
                {'id': 2, 'name': 'Jane Doe', 'character': 'Pilot'},
              ],
            },
          },
        ),
      );
    });
    await tester.pumpWidget(
      frame(
        FilmDetailPage(
          catalog: catalog,
          workId: original.id,
          onOpenItem: (_) async {},
        ),
      ),
    );
    await settle(tester);
    final title = find.text('演职人员');
    await tester.ensureVisible(title);
    await settle(tester);
    final shelf = find.ancestor(of: title, matching: find.byType(FilmShelf));
    final surfaces = find.descendant(
      of: shelf,
      matching: find.byType(FilmPosterHoverSurface),
    );
    expect(surfaces, findsNWidgets(2));
    final avatar = find.descendant(
      of: surfaces.first,
      matching: find.byType(FilmArtwork),
    );
    expect(avatar, findsOneWidget);
    expect(
      find.ancestor(of: avatar, matching: find.byType(AnimatedScale)),
      findsNothing,
    );
    // 悬停变换不得进入合成层，否则缩放在整数像素取整后表现为抖动。
    final transform = find
        .ancestor(
          of: avatar,
          matching: find.byWidgetPredicate(
            (widget) => widget is Transform && !widget.transformHitTests,
          ),
        )
        .first;
    expect(
      tester.renderObject<RenderTransform>(transform).needsCompositing,
      isFalse,
    );
    final before = tester.getRect(avatar);
    final name = find.text('Andy Smith');
    final nameBefore = tester.getRect(name);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(before.center));
    await settle(tester);
    final hovered = tester.getRect(avatar);
    expect(
      hovered.width,
      closeTo(before.width * AppTheme.posterHoverScale, .5),
    );
    expect(hovered.top, lessThan(before.top - AppTheme.posterHoverLift + 1));
    expect(tester.getRect(name), nameBefore);
    // 命中区不随放大变化：移到原 68px 边界外即收回。
    await tester.sendEventToBinding(
      pointer.hover(before.center + Offset(before.width / 2 + .8, 0)),
    );
    await settle(tester);
    expect(tester.getRect(avatar).width, closeTo(before.width, .5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情骨架覆盖原布局，缓存命中也不会闪现，替换保留正文 State', (tester) async {
    await prepare(tester, count: 1);
    final original = works.single;
    await tester.runAsync(() async {
      await catalog.store.refreshWork(
        FilmWork(
          id: original.id,
          type: original.type,
          tmdbId: original.tmdbId,
          title: original.title,
          originalTitle: 'Original film title',
          overview: 'A synopsis that fills the existing overview area. ' * 20,
          language: original.language,
          posterPath: original.posterPath,
          backdropPath: original.backdropPath,
          year: 2026,
          metadata: {
            ...original.metadata,
            'vote_average': 8.5,
            'runtime': 90,
            'genres': ['Animation', 'Adventure'],
            'credits': {
              'cast': [
                for (var i = 0; i < 12; i++)
                  {
                    'id': i + 1,
                    'name': 'Actor $i',
                    'character': 'Character $i',
                  },
              ],
            },
          },
        ),
      );
      works = await catalog.store.works(type: null);
    });
    final imageKey = GlobalKey();
    await tester.pumpWidget(
      frame(
        RepaintBoundary(
          key: imageKey,
          child: FilmDetailPage(
            catalog: catalog,
            workId: original.id,
            initialWork: works.single,
            onOpenItem: (_) async {},
          ),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    final detailRoute = ModalRoute.of(
      tester.element(find.byType(FilmDetailPage)),
    )!;
    final avatar = find
        .byWidgetPredicate(
          (w) =>
              w is SkeletonRegion &&
              w.borderRadius == BorderRadius.circular(999),
        )
        .first;
    await tester.tap(avatar, warnIfMissed: false);
    await tester.pump();
    expect(
      detailRoute.isCurrent,
      isTrue,
      reason: 'Skeleton avatars must not open a related page',
    );
    final regions = <String, Rect>{};
    for (final name in [
      'logo',
      'original-title',
      'metadata',
      'genres',
      'actions',
      'overview',
    ]) {
      final region = find.byKey(Key('film-skeleton-$name'));
      final block = find.descendant(
        of: region,
        matching: find.byType(CinematicSkeleton),
      );
      expect(block, findsOneWidget);
      regions[name] = tester.getRect(region);
      expect(tester.getRect(block), regions[name]);
      expect(
        tester.widget<CinematicSkeleton>(block).borderRadius,
        AppTheme.controlRadius,
      );
    }
    final logo = find.byWidgetPredicate(
      (w) => w is FilmArtwork && w.transparent,
    );
    final logoState = tester.state(logo);
    Future<void> capture(String name) async {
      await tester.runAsync(() async {
        final boundary =
            imageKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory('build/detail-skeleton')
          ..createSync(recursive: true);
        await File(
          p.join(directory.path, '$name.png'),
        ).writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      });
    }

    await capture('widget-skeleton');
    await tester.pump(const Duration(milliseconds: 450));
    expect(
      find.descendant(
        of: find.byKey(const Key('film-skeleton-logo')),
        matching: find.byType(CinematicSkeleton),
      ),
      findsOneWidget,
    );
    await settle(tester);
    expect(find.byType(CinematicSkeleton), findsNothing);
    expect(tester.state(logo), same(logoState));
    for (final entry in regions.entries) {
      expect(
        tester.getRect(find.byKey(Key('film-skeleton-${entry.key}'))),
        entry.value,
      );
    }
    await capture('widget-content');
    expect(find.byType(SkeletonScope), findsOneWidget);
    await tester.tap(avatar);
    await settle(tester);
    expect(find.byType(FilmRelatedPage), findsOneWidget);
    Navigator.of(tester.element(find.byType(FilmRelatedPage))).pop();
    await settle(tester);
    expect(find.byType(CinematicSkeleton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情骨架适配四语言、明暗与材质主题、窄窗及双倍字号', (tester) async {
    await prepare(tester, count: 1);
    final original = works.single;
    await tester.runAsync(
      () => catalog.store.refreshWork(
        FilmWork(
          id: original.id,
          type: original.type,
          tmdbId: original.tmdbId,
          title: original.title,
          originalTitle: 'Original title for the detail page',
          overview: 'A long synopsis for narrow windows and larger text. ' * 20,
          language: original.language,
          posterPath: original.posterPath,
          backdropPath: original.backdropPath,
          year: 2026,
          metadata: {
            ...original.metadata,
            'vote_average': 8.6,
            'runtime': 124,
            'genres': ['Animation', 'Drama', 'Science Fiction'],
            'credits': {
              'crew': [
                {'name': 'Andy Smith', 'job': 'Original Story'},
              ],
            },
          },
        ),
      ),
    );
    works = (await tester.runAsync(() => catalog.store.works(type: null)))!;
    const locales = [
      Locale('zh', 'CN'),
      Locale('zh', 'TW'),
      Locale('ja'),
      Locale('en'),
    ];
    for (var i = 0; i < 8; i++) {
      final light = i.isOdd;
      final theme = (light ? AppTheme.light : AppTheme.dark)(
        glass: i % 3 != 0,
        windowBackdrop: i % 3 == 1
            ? WindowBackdropType.systemAcrylic
            : WindowBackdropType.mica,
      );
      tester.view.physicalSize = i < 4
          ? const Size(1280, 900)
          : const Size(760, 1100);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: app,
          child: MaterialApp(
            key: ValueKey(i),
            theme: theme,
            locale: locales[i % 4],
            supportedLocales: locales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(i < 4 ? 1 : 2)),
              child: child!,
            ),
            home: FilmDetailPage(
              catalog: catalog,
              workId: works.single.id,
              initialWork: works.single,
              onOpenItem: (_) async {},
            ),
          ),
        ),
      );
      expect(find.byType(CinematicSkeleton), findsWidgets);
      expect(tester.takeException(), isNull, reason: 'Skeleton case $i');
      await settle(tester);
      expect(find.byType(CinematicSkeleton), findsNothing);
      expect(tester.takeException(), isNull, reason: 'Content case $i');
    }
  });

  testWidgets('详情季切换复用滑动选择框，含特别篇和未映射资源，并保持剧集等高', (tester) async {
    await prepare(tester, count: 1);
    final synopsis = 'Detailed episode overview with full context. ' * 120;
    var playCalls = 0;
    final workId = (await tester.runAsync(() async {
      final rootId = await catalog.store.addRoot(
        sourceId: 'local:season-clip',
        kind: MediaSourceKind.local,
        path: 'TV',
        type: FilmMediaType.tv,
        name: 'Season switch',
      );
      final root = (await catalog.store.root(rootId))!;
      final generation = await catalog.store.beginScan(rootId);
      await catalog.store.stage(root, generation, [
        for (var i = 0; i < 12; i++)
          FilmScanEntry(
            path: 'TV/E$i.mkv',
            parentPath: 'TV',
            name: 'E$i.mkv',
            mediaKind: 'video',
          ),
      ]);
      await catalog.store.commitScan(
        rootId,
        generation,
        cancelled: () => false,
      );
      await catalog.store.bind(
        await catalog.store.resources(rootId: rootId),
        FilmWork(
          type: FilmMediaType.tv,
          tmdbId: 888,
          title: 'Season switch fixture',
          originalTitle: 'Season switch fixture',
          overview: '',
          language: 'zh-CN',
          posterPath: works.first.posterPath,
          metadata: const {'presentation_version': 3},
        ),
      );
      final resources = await catalog.store.resources(rootId: rootId);
      await catalog.store.mapEpisodes({
        for (var i = 0; i < 11; i++)
          resources[i]: i < 2
              ? (1, i + 1)
              : i == 2
              ? (0, 1)
              : (i, 1),
      });
      final workId = resources.first.workId!;
      await catalog.store.saveSeason(workId, 1, 'zh-CN', {
        'episodes': [
          {
            'episode_number': 1,
            'name': 'Short',
            'overview': synopsis,
            'air_date': '2026-10-18',
            'runtime': 24,
          },
          {
            'episode_number': 2,
            'name': 'A long title that should occupy one line only',
            'overview': '',
          },
        ],
      });
      await catalog.store.saveProbe(resources.first.id, {
        'duration': 1470,
        'width': 1920,
        'height': 1080,
      });
      await catalog.store.setPreference('spoiler_protection', true);
      return workId;
    }))!;
    for (final scale in [1.0, 2.0]) {
      playCalls = 0;
      tester.view.physicalSize = const Size(760, 1100);
      await tester.pumpWidget(
        frame(
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: FilmDetailPage(
                key: ValueKey(scale),
                catalog: catalog,
                workId: workId,
                onOpenItem: (_) async {
                  playCalls++;
                },
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      final selector = find.byKey(const Key('film-season-selector'));
      await tester.ensureVisible(selector);
      await settle(tester);
      final control = find.byType(FilmSegmentedControl<int?>);
      expect(control, findsOneWidget);
      expect(tester.widget<FilmSegmentedControl<int?>>(control).selected, 1);
      expect(find.text('第 1 季 (2)'), findsOneWidget);
      final cards = find.byType(FilmEpisodeCard);
      expect(cards, findsNWidgets(2));
      Size cardSize(int index) => tester.getSize(
        find.descendant(of: cards.at(index), matching: find.byType(Card)).first,
      );
      expect(cardSize(0), cardSize(1));
      final before = cardSize(0);
      await tester.ensureVisible(find.text('1. Short'));
      await tester.tap(find.text('1. Short'));
      await settle(tester);
      expect(playCalls, 0);
      expect(
        find.ancestor(
          of: find.text(synopsis),
          matching: find.byType(ImageFiltered),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('1. Short'));
      await settle(tester);
      final reveal = find.descendant(
        of: cards.first,
        matching: find.text('展示封面'),
      );
      await tester.ensureVisible(reveal);
      await tester.tap(reveal);
      await settle(tester);
      expect(cardSize(0), before);
      expect(cardSize(1), before);
      final firstCard = find
          .descendant(of: cards.first, matching: find.byType(Card))
          .first;
      final artwork = find
          .descendant(of: firstCard, matching: find.byType(FilmArtwork))
          .first;
      final artworkState = tester.state(artwork);
      await tester.ensureVisible(find.text('1. Short'));
      final sourceRect = tester.getRect(cards.first);
      final neighborRect = tester.getRect(cards.at(1));
      await tester.tap(find.text('1. Short'));
      await tester.pump();
      await tester.pump();
      final openingHeights = <double>[tester.getSize(firstCard).height];
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        openingHeights.add(tester.getSize(firstCard).height);
      }
      expect(openingHeights.first, closeTo(before.height, .01));
      expect(openingHeights[1], greaterThan(openingHeights.first));
      expect(openingHeights[1], lessThan(openingHeights.last));
      for (var i = 1; i < openingHeights.length; i++) {
        expect(openingHeights[i], greaterThanOrEqualTo(openingHeights[i - 1]));
      }
      await settle(tester);
      expect(playCalls, 0);
      expect(tester.widget<Text>(find.text(synopsis)).maxLines, isNull);
      expect(tester.getRect(cards.first), sourceRect);
      expect(tester.getRect(cards.at(1)), neighborRect);
      expect(tester.state(artwork), same(artworkState));
      final synopsisScroll = find.descendant(
        of: firstCard,
        matching: find.byType(SingleChildScrollView),
      );
      await tester.drag(synopsisScroll, const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SingleChildScrollView>(synopsisScroll).controller!.offset,
        greaterThan(0),
      );
      await tester.tap(find.text('1. Short'));
      await tester.pump();
      final closingStart = tester.getSize(firstCard).height;
      await tester.pump(const Duration(milliseconds: 80));
      final closingMiddle = tester.getSize(firstCard).height;
      expect(closingMiddle, lessThan(closingStart));
      expect(closingMiddle, greaterThan(before.height));
      await settle(tester);
      expect(tester.widget<Text>(find.text(synopsis)).maxLines, 1);
      expect(find.byTooltip('收起简介'), findsNothing);
      await tester.tap(find.text('1. Short'));
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(tester.widget<Text>(find.text(synopsis)).maxLines, 1);
      expect(tester.getRect(cards.first), sourceRect);
      await tester.tap(find.text('1. Short'));
      await settle(tester);
      await tester.tapAt(const Offset(730, 20));
      await settle(tester);
      expect(tester.widget<Text>(find.text(synopsis)).maxLines, 1);
      await tester.tap(find.text('1. Short'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final interruptedHeight = tester.getSize(firstCard).height;
      await tester.tap(find.text('1. Short'));
      await tester.pump();
      expect(tester.getSize(firstCard).height, closeTo(interruptedHeight, .01));
      await settle(tester);
      expect(tester.widget<Text>(find.text(synopsis)).maxLines, 1);
      expect(tester.getRect(cards.first), sourceRect);
      await tester.ensureVisible(artwork);
      await tester.tap(artwork);
      await tester.pump();
      expect(playCalls, 1);
      await tester.ensureVisible(find.text('1. Short'));
      await tester.tap(find.text('1. Short'));
      await settle(tester);
      await tester.tap(artwork);
      await settle(tester);
      expect(playCalls, 2);
      expect(tester.widget<Text>(find.text(synopsis)).maxLines, 1);
      await tester.ensureVisible(find.text('特别篇 (1)'));
      await tester.tap(find.text('特别篇 (1)'));
      await settle(tester);
      expect(
        tester
            .widget<FilmEpisodeCard>(find.byType(FilmEpisodeCard))
            .resource
            .season,
        0,
      );
      await tester.tap(find.text('特别篇 (1)'), buttons: kSecondaryMouseButton);
      await settle(tester);
      expect(find.text('标记已看完'), findsOneWidget);
      await tester.tapAt(const Offset(700, 20));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('集号待确认 (1)'));
      await tester.tap(find.text('集号待确认 (1)'));
      await settle(tester);
      expect(
        tester
            .widget<FilmEpisodeCard>(find.byType(FilmEpisodeCard))
            .resource
            .season,
        isNull,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('剧集与续播玻璃连接连续，悬停限于封面且角标保持尺寸', (tester) async {
    await prepare(tester, count: 1);
    final resource = (await tester.runAsync(() async {
      final rootId = await catalog.store.addRoot(
        sourceId: 'local:glass-fixture',
        kind: MediaSourceKind.local,
        path: 'TV',
        type: FilmMediaType.tv,
        name: 'Glass fixture',
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
      await catalog.store.bind(
        await catalog.store.resources(rootId: rootId),
        FilmWork(
          type: FilmMediaType.tv,
          tmdbId: 777,
          title: 'Glass fixture',
          originalTitle: 'Glass fixture',
          overview: '',
          language: 'en',
          posterPath: works.first.posterPath,
          backdropPath: works.first.backdropPath,
        ),
      );
      final resource = (await catalog.store.resources(rootId: rootId)).single;
      await catalog.store.mapEpisodes({resource: (1, 1)});
      await catalog.store.setPreference('spoiler_protection', false);
      final original = (await catalog.images.cached(
        works.first.backdropPath!,
        'original',
      ))!;
      for (final target in ['w780', 'w342']) {
        await original.copy(
          p.join(
            catalog.images.directory.path,
            '${FilmCatalogImageCache.cacheKey(works.first.backdropPath!, target)}.img',
          ),
        );
      }
      return (await catalog.store.resources(rootId: rootId)).single;
    }))!;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(900, 700));
    for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = Size(1000 * dpr, 800 * dpr);
      for (final light in [false, true]) {
        for (final kind in ['episode', 'continue', 'poster']) {
          await mouse.moveTo(const Offset(900, 700));
          final boundary = GlobalKey();
          var plays = 0;
          var cardWidth = 300.0;
          late StateSetter resizeCard;
          await tester.pumpWidget(
            frame(
              Theme(
                data: light ? AppTheme.light() : AppTheme.dark(),
                child: Scaffold(
                  body: RepaintBoundary(
                    key: boundary,
                    child: ColoredBox(
                      color: light ? Colors.black : Colors.white,
                      child: Padding(
                        padding: const EdgeInsets.all(40),
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: StatefulBuilder(
                            builder: (context, setSize) {
                              resizeCard = setSize;
                              return SizedBox(
                                width: cardWidth,
                                height: kind == 'episode'
                                    ? null
                                    : kind == 'poster'
                                    ? 400
                                    : 220,
                                child: kind == 'episode'
                                    ? FilmEpisodeCard(
                                        resource: resource,
                                        catalog: catalog,
                                        state: '可用',
                                        artworkPath: works.first.backdropPath,
                                        probe: const {
                                          'video': [
                                            {'width': 1920, 'height': 1080},
                                          ],
                                        },
                                        episode: const {
                                          'name': 'Glass episode',
                                          'overview': 'Short overview',
                                        },
                                        onOpenItem: (_) async {
                                          plays++;
                                        },
                                        onChanged: () async {},
                                      )
                                    : FilmContinueCard(
                                        catalog: catalog,
                                        poster: kind == 'poster',
                                        record: MediaLibraryRecord(
                                          item: resource.playbackItem,
                                          updatedAt: DateTime.now(),
                                        ),
                                        onTap: () {
                                          plays++;
                                        },
                                      ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await settle(tester);
          if (kind == 'episode' && dpr == 1 && !light) {
            final imageState = tester.state(find.byType(FilmArtwork));
            resizeCard(() => cardWidth = 240);
            await tester.pumpAndSettle();
            resizeCard(() => cardWidth = 300);
            await tester.pump();
            for (final ms in [0, 16, 32, 72, 80]) {
              await tester.pump(Duration(milliseconds: ms));
              final cardRect = tester.getRect(find.byType(Card));
              for (final label in ['1. Glass episode', 'Short overview']) {
                expect(
                  tester.getTopLeft(find.text(label)).dx,
                  closeTo(cardRect.left + 12, .01),
                  reason:
                      'Restored episode text moves horizontally: $label at ${ms}ms',
                );
              }
            }
            expect(tester.state(find.byType(FilmArtwork)), same(imageState));
            await tester.pumpAndSettle();
          }
          final artwork = find.byType(FilmArtwork);
          final resting = tester.getRect(artwork);
          final card = tester.getRect(find.byType(Card));
          final badge = find.text('1920 × 1080');
          final badgeRest = kind == 'episode' ? tester.getRect(badge) : null;
          double playOpacity() => tester
              .widget<FilmPlayIcon>(
                find.descendant(
                  of: find.byType(FilmPosterHoverPlayIcon),
                  matching: find.byType(FilmPlayIcon),
                ),
              )
              .opacity!
              .value;
          if (kind == 'episode') expect(playOpacity(), 0);
          final body = Offset(card.left + 50, resting.bottom + 20);
          final origin = tester.getTopLeft(find.byKey(boundary));
          Future<void> checkJunction(String phase) async {
            final image = (await tester.runAsync(
              () =>
                  (boundary.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary)
                      .toImage(pixelRatio: dpr),
            ))!;
            final bytes = (await tester.runAsync(
              () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
            ))!;
            for (final x in [
              resting.left + 3,
              resting.right - 3,
              resting.center.dx,
            ]) {
              final y = resting.bottom - 1;
              final offset =
                  (((y - origin.dy) * dpr).floor() * image.width +
                      ((x - origin.dx) * dpr).floor()) *
                  4;
              // 连接处必须由连续底板或封面覆盖，不能漏出对比背景或落成黑线。
              final green = bytes.getUint8(offset + 1);
              expect(
                green,
                inInclusiveRange(light ? 60 : 35, light ? 255 : 175),
                reason:
                    '$kind dpr=$dpr light=$light phase=$phase x=$x green=$green',
              );
            }
            image.dispose();
          }

          await checkJunction('rest');
          await mouse.moveTo(body);
          await tester.pumpAndSettle();
          expect(tester.getRect(artwork), resting, reason: 'Body hover: $kind');
          if (kind == 'episode') expect(playOpacity(), 0);

          await mouse.moveTo(resting.center);
          await tester.pump();
          for (final ms in [40, 60, 100]) {
            await tester.pump(Duration(milliseconds: ms));
            await checkJunction('enter-$ms');
          }
          final hovered = tester.getRect(artwork);
          if (kind == 'episode') expect(playOpacity(), 1);
          expect(hovered.width, closeTo(resting.width * 1.05, .01));
          if (badgeRest != null) {
            final moved = tester.getRect(badge);
            expect(moved.size.width, closeTo(badgeRest.width, .01));
            expect(moved.size.height, closeTo(badgeRest.height, .01));
            expect(moved.top, lessThan(badgeRest.top));
            expect(moved.left, lessThan(badgeRest.left));
          }
          await mouse.moveTo(body);
          await tester.pump();
          for (final ms in [40, 60, 100]) {
            await tester.pump(Duration(milliseconds: ms));
            await checkJunction('exit-$ms');
          }
          expect(tester.getRect(artwork), resting);
          if (kind == 'episode') expect(playOpacity(), 0);
          await tester.tapAt(resting.center);
          await tester.pump();
          expect(plays, 1);
          expect(tester.takeException(), isNull);
        }
      }
    }
    await mouse.removePointer();
  });

  testWidgets('episode hover does not paint the fixed border over artwork', (
    tester,
  ) async {
    await prepare(tester);
    final resource = (await tester.runAsync(
      () => catalog.store.resources(),
    ))!.first;
    await tester.runAsync(() async {
      final original = (await catalog.images.cached(
        works.first.backdropPath!,
        'original',
      ))!;
      await original.copy(
        p.join(
          catalog.images.directory.path,
          '${FilmCatalogImageCache.cacheKey(works.first.backdropPath!, 'w780')}.img',
        ),
      );
    });
    final boundary = GlobalKey();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1000, 800));
    for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
      tester.view.devicePixelRatio = dpr;
      for (final selected in [false, true]) {
        await mouse.moveTo(const Offset(1000, 800));
        await tester.pumpWidget(
          frame(
            Scaffold(
              body: RepaintBoundary(
                key: boundary,
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: 320,
                      child: FilmEpisodeCard(
                        catalog: catalog,
                        resource: resource,
                        state: '可用',
                        artworkPath: works.first.backdropPath,
                        selected: selected,
                        onOpenItem: (_) async {},
                        onChanged: () async {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await settle(tester);
        final card = tester.getRect(
          find
              .descendant(
                of: find.byKey(ValueKey('film-resource-${resource.id}')),
                matching: find.byType(InkWell),
              )
              .first,
        );
        final imageRect = tester.getRect(find.byType(FilmArtwork));
        await mouse.moveTo(imageRect.center);
        await tester.pumpAndSettle();
        final origin = tester.getTopLeft(find.byKey(boundary));
        final image = (await tester.runAsync(
          () =>
              (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: dpr),
        ))!;
        final bytes = (await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
        ))!;
        final y = ((imageRect.bottom - 12 - origin.dy) * dpr).floor();
        final edgeX = ((card.left - origin.dx) * dpr).ceil();
        final centerX = ((card.left + 12 - origin.dx) * dpr).floor();
        for (var c = 0; c < 3; c++) {
          expect(
            bytes.getUint8((y * image.width + edgeX) * 4 + c),
            closeTo(bytes.getUint8((y * image.width + centerX) * 4 + c), 2),
            reason: 'border crosses artwork at dpr=$dpr selected=$selected',
          );
        }
        image.dispose();
      }
    }
    await mouse.removePointer();
  });

  Finder backdropImages() => find.descendant(
    of: find.byKey(const Key('film-detail-backdrop')),
    matching: find.byKey(const Key('adaptive-backdrop-sharp')),
  );

  testWidgets('详情提亮后极亮极暗背景仍可阅读真实信息区', (tester) async {
    await prepare(tester);
    final old = works.first;
    const overview =
        'Readable detail overview with a long paragraph. '
        'The scene remains visible while the title and description stay clear. '
        'A second sentence fills the available reading width. '
        'The final sentence checks the right edge of the information column.';
    await tester.runAsync(() async {
      await catalog.store.bind(
        [
          (await catalog.store.resources()).firstWhere(
            (r) => r.workId == old.id,
          ),
        ],
        FilmWork(
          type: old.type,
          tmdbId: old.tmdbId,
          title: old.title,
          originalTitle: 'Original detail title with a long readable name',
          overview: overview,
          language: old.language,
          year: 2020,
          posterPath: old.posterPath,
          backdropPath: old.backdropPath,
          metadata: const {
            'genres': ['Drama', 'Science Fiction'],
            'runtime': 140,
            'presentation_version': 3,
          },
        ),
      );
      await catalog.store.setPreference('spoiler_protection', false);
    });
    final evidence = <Map<String, Object>>[];
    for (final size in [const Size(1920, 1350), const Size(640, 450)]) {
      for (final color in [Colors.white, Colors.black]) {
        await tester.pumpWidget(const SizedBox.shrink());
        PaintingBinding.instance.imageCache.clear();
        final file = (await tester.runAsync(
          () => catalog.images.cached(old.backdropPath!, 'original'),
        ))!;
        await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawRect(Offset.zero & size, Paint()..color = color);
          final picture = recorder.endRecording();
          final image = await picture.toImage(
            size.width.toInt(),
            size.height.toInt(),
          );
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
          picture.dispose();
        });
        var ready = false;
        Object? failure;
        unawaited(
          catalog.images.backdropBlurs
              .get(file)
              .then(
                (_) => ready = true,
                onError: (Object error) {
                  failure = error;
                  ready = true;
                },
              ),
        );
        for (var wait = 0; !ready && wait < 600; wait++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(failure, isNull);
        expect(ready, isTrue);
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          frame(
            RepaintBoundary(
              key: boundaryKey,
              child: FilmDetailPage(
                catalog: catalog,
                workId: old.id,
                onOpenItem: (_) async {},
              ),
            ),
          ),
        );
        await settle(tester);
        final textRows = <(String, Rect, Color, double)>[];
        for (final label in [
          old.title,
          'Original detail title with a long readable name',
          'Drama · Science Fiction',
          overview,
        ]) {
          final finder = find.text(label).first;
          final element = tester.element(finder);
          final text = element.widget as Text;
          final style = DefaultTextStyle.of(element).style.merge(text.style);
          final rect = tester.getRect(finder);
          final painter = TextPainter(
            text: TextSpan(text: label, style: style),
            textDirection: TextDirection.ltr,
            maxLines: text.maxLines,
            ellipsis: text.overflow == TextOverflow.ellipsis ? '…' : null,
          )..layout(maxWidth: rect.width);
          for (final line in painter.computeLineMetrics()) {
            textRows.add((
              label,
              Rect.fromLTWH(
                rect.left + line.left,
                rect.top + line.baseline - line.ascent,
                line.width,
                line.height,
              ),
              style.color!,
              style.fontSize!,
            ));
          }
          painter.dispose();
        }
        final colors = {for (final row in textRows) row.$3};
        expect(colors, hasLength(1));
        expect([Colors.black, Colors.white], contains(colors.single));
        final backgroundKey = tester
            .widget<AdaptiveFilmBackdrop>(find.byType(AdaptiveFilmBackdrop))
            .textColors!
            .backgroundKey;
        final data = (await tester.runAsync(() async {
          final image =
              await (backgroundKey.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          return bytes;
        }))!;
        for (final (label, bounds, foreground, fontSize) in textRows) {
          final rect = bounds.intersect(const Rect.fromLTWH(0, 0, 1280, 900));
          if (rect.isEmpty) continue;
          var minimum = double.infinity;
          for (var y = rect.top + 2; y < rect.bottom - 2; y += 4) {
            for (var x = rect.left + 2; x < rect.right - 2; x += 4) {
              final offset = (y.floor() * 1280 + x.floor()) * 4;
              final background = Color.fromARGB(
                255,
                data.getUint8(offset),
                data.getUint8(offset + 1),
                data.getUint8(offset + 2),
              );
              final a = Color.alphaBlend(
                    foreground,
                    background,
                  ).computeLuminance(),
                  b = background.computeLuminance();
              final contrast = a > b
                  ? (a + .05) / (b + .05)
                  : (b + .05) / (a + .05);
              if (contrast < minimum) minimum = contrast;
            }
          }
          evidence.add({
            'size': size.toString(),
            'color': color.toString(),
            'label': label,
            'contrast': minimum,
          });
          expect(
            minimum,
            greaterThanOrEqualTo(fontSize >= 24 ? 3 : 4.5),
            reason: 'Detail: $size, $color, $label',
          );
        }
      }
    }
    await tester.runAsync(() async {
      final file = File(
        'build/adaptive-background/brightness-followup/detail-contrast.json',
      );
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(evidence));
    });
  });

  testWidgets('portrait progress leaves unplayed poster visible', (
    tester,
  ) async {
    await prepare(tester);
    final pair = works.take(2).toList();
    await tester.runAsync(() async {
      final resources = await catalog.store.resources();
      for (final work in pair) {
        final resource = resources.singleWhere((r) => r.workId == work.id);
        await catalog.store.recordVideoProgress(
          VideoProgressUpdate(
            sourceId: resource.sourceId,
            path: resource.path,
            positionMs: 50,
            durationMs: 100,
            recordedAt: DateTime.now(),
          ),
        );
      }
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.white, BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(342, 513);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await (await catalog.images.cached(
        pair.last.posterPath!,
        'w342',
      ))!.writeAsBytes(bytes.buffer.asUint8List());
      image.dispose();
      picture.dispose();
    });
    final keys = [GlobalKey(), GlobalKey()];
    for (final dpr in [1.0, 1.25, 1.5]) {
      tester.view.devicePixelRatio = dpr;
      for (final width in [174.5, 181.0, 210.5]) {
        await tester.pumpWidget(
          frame(
            Scaffold(
              body: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < pair.length; i++)
                    RepaintBoundary(
                      key: keys[i],
                      child: SizedBox(
                        width: width,
                        height: 350,
                        child: FilmWorkCard(
                          store: catalog.store,
                          work: pair[i],
                          cache: catalog.images,
                          onTap: () {},
                          onMenu: (_) {},
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
        await settle(tester);
        final progressRect = tester.getRect(
          find.byType(LinearProgressIndicator).first,
        );
        final pixels = <ByteData>[];
        var imageWidth = 0;
        for (final key in keys) {
          final image = await tester.runAsync(
            () =>
                (key.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: dpr),
          );
          imageWidth = image!.width;
          pixels.add(
            (await tester.runAsync(
              () async =>
                  (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!,
            ))!,
          );
          image.dispose();
        }
        final row = (progressRect.center.dy * dpr).floor();
        for (
          var x = (30 * dpr).ceil();
          x < ((width / 2 - 4) * dpr).floor();
          x++
        ) {
          for (var channel = 0; channel < 3; channel++) {
            final offset = (row * imageWidth + x) * 4 + channel;
            expect(
              pixels[0].getUint8(offset),
              closeTo(pixels[1].getUint8(offset), 1),
              reason: 'progress differs at dpr=$dpr width=$width x=$x row=$row',
            );
          }
        }
        for (
          var x = ((width / 2 + 4) * dpr).ceil();
          x < ((width - 30) * dpr).floor();
          x++
        ) {
          final offset = (row * imageWidth + x) * 4;
          expect(
            (pixels[0].getUint8(offset) - pixels[1].getUint8(offset)).abs(),
            greaterThan(20),
            reason: 'track hides poster at dpr=$dpr width=$width x=$x',
          );
        }
      }
    }
  });

  testWidgets(
    'spoiler mode retains main artwork and uses one overview reveal action',
    (tester) async {
      await prepare(tester);
      final overview = 'Secret overview with a long paragraph. ' * 30;
      await tester.runAsync(() async {
        await catalog.store.bind(
          [(await catalog.store.resources()).first],
          FilmWork(
            type: FilmMediaType.movie,
            tmdbId: works.first.tmdbId,
            title: works.first.title,
            originalTitle: works.first.originalTitle,
            overview: overview,
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
          of: find.text(overview),
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
          of: find.text(overview),
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
    'collections show all opens the immersive showcase with selected artwork',
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
      await tester.scrollUntilVisible(
        all,
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(all);
      await settle(tester);
      expect(find.byType(AppBar), findsNothing);
      expect(find.byType(FilmFeaturedPage), findsOneWidget);
      expect(find.byType(FilmFeaturedShowcase), findsOneWidget);
      expect(find.byType(FilmDetailBackButton), findsOneWidget);
      final selectedBackdrop = tester
          .widget<FilmDetailBackdrop>(find.byType(FilmDetailBackdrop))
          .path;
      expect(selectedBackdrop, works.first.backdropPath);
      expect(
        find.descendant(
          of: find.byType(FilmFeaturedShowcase),
          matching: find.byType(FilmPosterHover),
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
      expect(find.byType(FilmLibraryBackground), findsNothing);
      expect(
        tester.widget<FilmDetailBackdrop>(find.byType(FilmDetailBackdrop)).path,
        selectedBackdrop,
      );
      await tester.tap(find.text('查看合集'));
      await settle(tester);
      expect(find.byType(FilmPosterGrid), findsNothing);
      expect(find.byType(FilmFeaturedShowcase), findsOneWidget);
      expect(find.byType(FilmSegmentedControl<String>), findsNothing);
      expect(find.byType(FilmLibraryBackground), findsNothing);
      expect(
        tester
            .widget<FilmFeaturedShowcase>(find.byType(FilmFeaturedShowcase))
            .works!
            .single
            .id,
        works.first.id,
      );
      await tester.tap(find.byKey(const ValueKey('featured-open')));
      await settle(tester);
      expect(find.byType(FilmDetailPage), findsOneWidget);
      Navigator.of(tester.element(find.byType(FilmDetailPage))).pop();
      await settle(tester);
      expect(find.byType(FilmFeaturedShowcase), findsOneWidget);
      expect(find.byType(FilmSegmentedControl<String>), findsNothing);
      Navigator.of(tester.element(find.byType(FilmFeaturedShowcase))).pop();
      await settle(tester);
      expect(find.text('查看合集'), findsOneWidget);
      Navigator.of(tester.element(find.byType(FilmFeaturedShowcase))).pop();
      await settle(tester);
      expect(find.byType(FilmLibraryPage), findsOneWidget);
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
        matching: find.byKey(const Key('adaptive-backdrop-sharp')),
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
      final pending = tester.element(
        find.byKey(const ValueKey('film-pending-button')),
      );
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
      expect(
        tester.element(find.byKey(const ValueKey('film-pending-button'))),
        pending,
      );
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
      expect(
        tester.element(find.byKey(const ValueKey('film-pending-button'))),
        pending,
      );
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
        expect(
          tester.element(find.byKey(const ValueKey('film-pending-button'))),
          pending,
        );
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
      await tester.scrollUntilVisible(
        find.text(title),
        400,
        scrollable: find.byType(Scrollable).first,
      );
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

  testWidgets('资源替换后详情移除旧版本，主页不显示缺失位置标记', (tester) async {
    await prepare(tester, count: 1);
    final work = works.single;
    final original = (await tester.runAsync(
      () => catalog.store.resources(workId: work.id),
    ))!.single;
    late FilmResource current;
    await tester.runAsync(() async {
      final root = (await catalog.store.root(original.rootId))!;
      final generation = await catalog.store.beginScan(root.id);
      await catalog.store.stage(root, generation, const [
        FilmScanEntry(
          path: 'replacement.mkv',
          parentPath: '',
          name: 'replacement.mkv',
          mediaKind: 'video',
        ),
      ]);
      await catalog.store.commitScan(
        root.id,
        generation,
        cancelled: () => false,
      );
      current = (await catalog.store.resources(rootId: root.id)).single;
      await catalog.store.bind([current], work);
      await catalog.refresh();
      works = await catalog.store.works(type: null);
    });
    await tester.pumpWidget(
      frame(
        FilmDetailPage(
          catalog: catalog,
          workId: work.id,
          initialWork: works.single,
          onOpenItem: (_) async {},
        ),
      ),
    );
    await settle(tester);
    expect(find.byKey(ValueKey('film-resource-${original.id}')), findsNothing);
    expect(find.byKey(ValueKey('film-resource-${current.id}')), findsOneWidget);
    expect(find.text('位置缺失'), findsNothing);
    await tester.pumpWidget(
      frame(
        FilmLibraryPage(
          onOpenItem: (_) async {},
          continueShelf: const SizedBox.shrink(),
        ),
      ),
    );
    await settle(tester);
    expect(find.text('包含缺失位置'), findsNothing);
    expect(catalog.movies.single.resourceCount, 1);
    expect(catalog.movies.single.missingCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('影片分级在详情与主页显示并复用海报墙筛选', (tester) async {
    await prepare(tester, count: 1);
    final work = works.single;
    await tester.runAsync(() async {
      await catalog.store.refreshWork(
        FilmWork.fromRow({
          ...work.toRow(),
          'id': work.id,
          'metadata_json': jsonEncode({
            ...work.metadata,
            'certification': 'TV-PG',
          }),
        }),
      );
      await catalog.store.setHomeSections([
        for (final section in FilmHomeSection.defaults)
          section.withEnabled(section.id == 'ratings'),
      ]);
      await catalog.refresh();
      works = await catalog.store.works(type: null);
    });
    await tester.pumpWidget(
      frame(
        FilmDetailPage(
          catalog: catalog,
          workId: work.id,
          initialWork: works.single,
          onOpenItem: (_) async {},
        ),
      ),
    );
    await settle(tester);
    expect(
      tester
          .widget<FilmCertificationBadge>(find.byType(FilmCertificationBadge))
          .rating,
      'TV-PG',
    );
    await tester.pumpWidget(
      frame(
        FilmLibraryPage(
          onOpenItem: (_) async {},
          continueShelf: const SizedBox.shrink(),
        ),
      ),
    );
    await settle(tester);
    final shelf = find.byWidgetPredicate(
      (w) => w is FilmShelf && w.title == '影片分级',
    );
    expect(shelf, findsOneWidget);
    expect(
      find.descendant(of: shelf, matching: find.text('TV-PG')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: shelf, matching: find.byType(FilmCertificationBadge)),
      findsNothing,
    );
    expect(
      find.descendant(of: shelf, matching: find.text('查看全部')),
      findsNothing,
    );
    final card = find.descendant(
      of: shelf,
      matching: find.byType(FilmCategoryCard),
    );
    await tester.ensureVisible(card);
    await tester.tap(card);
    await settle(tester);
    expect(catalog.sectionId, 'rating:TV-PG');
    expect(catalog.works.map((w) => w.id), [work.id]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('分类栏无查看全部，鼠标拖动可访问全部分类并复用海报墙筛选', (tester) async {
    await prepare(tester);
    final work = works.first;
    await tester.runAsync(() async {
      await catalog.store.refreshWork(
        FilmWork(
          id: work.id,
          type: work.type,
          tmdbId: work.tmdbId,
          title: work.title,
          originalTitle: work.originalTitle,
          overview: work.overview,
          language: work.language,
          year: 2024,
          posterPath: work.posterPath,
          backdropPath: work.backdropPath,
          metadata: {
            'genres': [
              for (var i = 0; i < 18; i++)
                'Genre ${i.toString().padLeft(2, '0')}',
            ],
            'origin_country': ['JP'],
          },
        ),
      );
      await catalog.store.setHomeSections(const [
        FilmHomeSection('genres', enabled: true),
        FilmHomeSection('countries', enabled: true),
        FilmHomeSection('years', enabled: true),
        FilmHomeSection('continue'),
        FilmHomeSection('daily'),
        FilmHomeSection('collections'),
        FilmHomeSection('sources'),
        FilmHomeSection('recent'),
        FilmHomeSection('movies'),
        FilmHomeSection('series'),
      ]);
      final original = File(
        p.join(
          catalog.images.directory.path,
          '${FilmCatalogImageCache.cacheKey(work.backdropPath!, 'original')}.img',
        ),
      );
      await original.copy(
        p.join(
          catalog.images.directory.path,
          '${FilmCatalogImageCache.cacheKey(work.backdropPath!, 'w780')}.img',
        ),
      );
      await catalog.refresh();
    });
    await tester.pumpWidget(
      frame(
        FilmLibraryPage(
          onOpenItem: (_) async {},
          continueShelf: const SizedBox.shrink(),
        ),
      ),
    );
    await settle(tester);
    final shelf = find.byWidgetPredicate(
      (w) => w is FilmShelf && w.title == '类型',
    );
    await tester.ensureVisible(shelf);
    await tester.pumpAndSettle();
    final list = tester.widget<ListView>(
      find.descendant(of: shelf, matching: find.byType(ListView)),
    );
    expect(list.semanticChildCount, 18);
    for (final title in ['类型', '地区', '年份']) {
      final categoryShelf = find.byWidgetPredicate(
        (w) => w is FilmShelf && w.title == title,
      );
      expect(
        find.descendant(of: categoryShelf, matching: find.text('查看全部')),
        findsNothing,
      );
    }
    final cover = tester
        .widget<FilmCategoryCard>(
          find
              .descendant(of: shelf, matching: find.byType(FilmCategoryCard))
              .first,
        )
        .category
        .coverPath;
    final shared = tester.widget<DirectoryScrollView>(
      find.descendant(of: shelf, matching: find.byType(DirectoryScrollView)),
    );
    expect(shared.hideScrollbar, isTrue);
    await tester.drag(
      shelf,
      const Offset(-10000, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(
      shared.controller!.offset,
      shared.controller!.position.maxScrollExtent,
    );
    expect(find.text('Genre 17'), findsOneWidget);
    await tester.tap(find.text('Genre 17'));
    await settle(tester);
    expect(catalog.sectionId, 'genre:Genre 17');
    expect(catalog.works.map((w) => w.id), [work.id]);
    await tester.tap(find.text('主页'));
    await settle(tester);
    await tester.drag(
      shelf,
      const Offset(10000, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilmCategoryCard>(
            find
                .descendant(of: shelf, matching: find.byType(FilmCategoryCard))
                .first,
          )
          .category
          .coverPath,
      cover,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'continue artwork and watch overlay fill the card cover without inset gaps',
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
                  width: poster ? 212 : FilmContinueCard.landscapeWidth,
                  height: poster ? 400 : FilmContinueCard.landscapeHeight,
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
        final card = tester.getRect(find.byType(FilmContinueCard));
        expect(artwork.left, closeTo(card.left, 1e-9));
        expect(artwork.top, closeTo(card.top, 1e-9));
        expect(artwork.width, closeTo(card.width, 1e-9));
        expect(artwork, tester.getRect(find.byType(FilmWatchOverlay)));
        final info = tester.getRect(
          find
              .descendant(
                of: find.byType(FilmContinueCard),
                matching: find.byType(Padding),
              )
              .last,
        );
        expect(artwork.bottom, closeTo(info.top, 1e-9));
        expect(tester.widget<Card>(find.byType(Card)).clipBehavior, Clip.none);
        final surface = find.byType(FilmPosterHoverSurface);
        expect(
          find.descendant(of: surface, matching: find.byType(ClipRRect)),
          findsWidgets,
        );
      }
    },
  );

  testWidgets('episode artwork and overview share one compact reveal action', (
    tester,
  ) async {
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
      final cardKey = GlobalKey();
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
                      child: RepaintBoundary(
                        key: cardKey,
                        child: FilmEpisodeCard(
                          resource: resource,
                          catalog: catalog,
                          state: '可用',
                          onOpenItem: (_) async {},
                          onChanged: () async {},
                          probe: overview.isEmpty ? null : {'duration': 1470},
                          episode: {
                            'name': 'Episode',
                            'still_path': '/still.png',
                            'overview': overview,
                            'air_date': '2026-10-18',
                            'runtime': 24,
                          },
                        ),
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
      await tester.runAsync(() async {
        final boundary =
            cardKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(
          pixelRatio: tester.view.devicePixelRatio,
        );
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = Directory('build/spoiler-edges')
          ..createSync(recursive: true);
        await File(
          p.join(
            output.path,
            overview.isEmpty ? 'empty-card.png' : 'synopsis-card.png',
          ),
        ).writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      });
      expect(find.text('${overview.isEmpty ? 24 : 25} 分钟'), findsOneWidget);
      expect(find.text('展示封面'), findsOneWidget);
      expect(find.text('展示剧透'), findsNothing);
      expect(find.byType(ImageFiltered), findsNWidgets(3));
      final caption = find.byWidgetPredicate(
        (widget) => widget is FilmWatchOverlay && widget.softEdges,
      );
      expect(caption, findsOneWidget);
      final captionSize = tester.getSize(caption);
      for (final element in find.byType(ImageFiltered).evaluate()) {
        final filter = find.byWidget(element.widget);
        final isCaption = find
            .ancestor(of: filter, matching: caption)
            .evaluate()
            .isNotEmpty;
        final clip = find
            .ancestor(
              of: filter,
              matching: find.byType(isCaption ? ClipRRect : ClipRect),
            )
            .first;
        expect(tester.getRect(clip), tester.getRect(filter));
        if (isCaption) {
          expect(
            tester.widget<ClipRRect>(clip).borderRadius,
            AppTheme.controlRadius,
          );
        }
      }
      expect(
        find.ancestor(
          of: find.text('展示封面'),
          matching: find.byType(ImageFiltered),
        ),
        findsNothing,
      );
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
      expect(tester.getSize(caption), captionSize);
    }
  });

  testWidgets(
    'synopsis spoiler edges feather into transparent rounded bounds',
    (tester) async {
      await prepare(tester);
      await tester.runAsync(
        () => catalog.store.setPreference('spoiler_protection', true),
      );
      for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
        tester.view.devicePixelRatio = dpr;
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          frame(
            Scaffold(
              body: Center(
                child: RepaintBoundary(
                  key: boundaryKey,
                  child: FilmWatchOverlay(
                    key: ValueKey(dpr),
                    store: catalog.store,
                    workId: works.first.id,
                    spoilerSensitive: true,
                    showStatus: false,
                    softEdges: true,
                    revealLabel: '展示封面',
                    child: const SizedBox(
                      width: 280,
                      height: 40,
                      child: ColoredBox(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await settle(tester);
        final size = tester.getSize(find.byKey(boundaryKey));
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: dpr);
          final rgba = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List();
          int alpha(double x, double y) =>
              rgba[((y * dpr).floor() * image.width + (x * dpr).floor()) * 4 +
                  3];
          // 实心输入用于检查边缘透明度，不依赖字体和文本分布。
          expect(alpha(0, 20), lessThan(15));
          expect(alpha(3, 20), lessThan(alpha(7, 20)));
          expect(alpha(7, 20), lessThan(alpha(16, 20)));
          expect(alpha(40, 0), lessThan(15));
          expect(alpha(40, 3), lessThan(alpha(40, 7)));
          expect(alpha(40, 7), lessThan(alpha(40, 15)));
          expect(alpha(1, 1), lessThan(5));
          expect(alpha(279, 39), lessThan(5));
          expect(alpha(40, 20), inInclusiveRange(160, 185));
          final output = Directory('build/spoiler-edges')
            ..createSync(recursive: true);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            p.join(output.path, 'feather-$dpr.png'),
          ).writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
        });
        await tester.tap(find.text('展示封面'));
        await tester.pump();
        expect(find.byType(ImageFiltered), findsNothing);
        expect(tester.getSize(find.byKey(boundaryKey)), size);
      }
    },
  );

  testWidgets('首页背景淘汰后返回保留首帧，候选加载失败保留已显示图', (tester) async {
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
            return FilmLibraryBackground(cache: catalog.images, file: file);
          },
        ),
      ),
    );
    await settle(tester);
    final original = tester
        .widget<RawImage>(find.byKey(const Key('adaptive-backdrop-sharp')))
        .image;
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
      expect(
        tester
            .widget<RawImage>(find.byKey(const Key('adaptive-backdrop-sharp')))
            .image,
        isNotNull,
      );
      await settle(tester);
    }
    await tester.pumpWidget(
      frame(
        Builder(
          builder: (_) => FilmLibraryBackground(
            cache: catalog.images,
            file: File(p.join(temp.path, 'missing-background.png')),
          ),
        ),
      ),
    );
    expect(
      tester
          .widget<RawImage>(find.byKey(const Key('adaptive-backdrop-sharp')))
          .image,
      same(original),
    );
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('影片详情复用目录滚动条，滚轮在条边和正文只滚动一次', (tester) async {
    await prepare(tester);
    tester.view.physicalSize = const Size(1280, 560);
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
          AdaptiveFilmBackdrop(
            cache: catalog.images,
            path: works.first.backdropPath,
          ),
        ),
      );
      final images = tester
          .widgetList<RawImage>(
            find.byKey(const Key('adaptive-backdrop-sharp')),
          )
          .toList();
      expect(images, hasLength(1));
      expect(images.every((image) => image.image != null), isTrue);
      expect(images.single.image!.width, 960);
      expect(images.single.scale, dpr);
      expect(PaintingBinding.instance.imageCache.currentSizeBytes, before);
    });
  }

  testWidgets('共享封面背景交叉过渡保留主页帧，不绘制切页占位块', (tester) async {
    await prepare(tester);
    await tester.runAsync(() async {
      final background = await catalog.images.cached(
        works.first.backdropPath!,
        'original',
      );
      await catalog.store.setBackgroundPath(background!.path);
      await catalog.refresh();
    });
    const frameKey = Key('library-transition-frame');
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          theme: AppTheme.dark().copyWith(platform: TargetPlatform.windows),
          builder: (_, child) => RepaintBoundary(key: frameKey, child: child!),
          home: const FilmLibraryShell(sidebarInset: 64),
        ),
      ),
    );
    await settle(tester);
    final background = find.byType(FilmLibraryBackground);
    expect(background, findsOneWidget);
    final element = tester.element(background);
    final sharp = find.descendant(
      of: background,
      matching: find.byKey(const Key('adaptive-backdrop-sharp')),
    );
    final decoded = tester.widget<RawImage>(sharp).image;
    expect(decoded, isNotNull);
    Future<List<int>> pixel() async => (await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(frameKey),
      );
      final image = await boundary.toImage();
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List();
      final offset = (450 * image.width + 5) * 4;
      final result = data.sublist(offset, offset + 4);
      image.dispose();
      return result;
    }))!;
    var previousPixel = await pixel();
    PaintingBinding.instance.imageCache.clear();
    Future<void> checkFrames(int count) async {
      for (var frame = 0; frame < count; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.element(background), same(element));
        expect(tester.widget<RawImage>(sharp).image, same(decoded));
        final current = await pixel();
        for (var channel = 0; channel < 4; channel++) {
          expect(
            (current[channel] - previousPixel[channel]).abs(),
            lessThanOrEqualTo(48),
          );
        }
        previousPixel = current;
      }
    }

    await tester.tap(find.byType(FilmWorkCard).first);
    await tester.pump();
    await checkFrames(12);
    expect(find.byType(StreamPathPageShell), findsNothing);
    expect(find.byType(FilmDetailPage), findsOneWidget);
    expect(find.byKey(const Key('film-connected-flight')), findsOneWidget);
    await settle(tester);
    Navigator.of(tester.element(find.byType(FilmDetailPage))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 64));
    await checkFrames(8);
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('共享封面立即导航，飞行后加载原图并渐显首张背景', (tester) async {
    await prepare(tester);
    await tester.pumpWidget(frame(FilmLibraryPage(onOpenItem: (_) async {})));
    await settle(tester);
    final card = find.byType(FilmWorkCard).first;
    final work = tester.widget<FilmWorkCard>(card).work;
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
    // 已解码封面先进入共享路由，大图和资源在飞行后准备。
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          theme: AppTheme.dark().copyWith(platform: TargetPlatform.windows),
          home: FilmLibraryPage(onOpenItem: (_) async {}),
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.byType(FilmWorkCard).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(StreamPathPageShell), findsNothing);
    expect(find.byType(FilmDetailPage), findsOneWidget);
    expect(find.byKey(const Key('film-connected-flight')), findsOneWidget);
    expect(backdropImages(), findsNothing);
    await settle(tester);
    final images = tester.widgetList<RawImage>(backdropImages()).toList();
    expect(images, hasLength(1));
    expect(images.single.image!.width, 960);
    final transitions = tester
        .widgetList<AnimatedBuilder>(
          find.descendant(
            of: find.byKey(const Key('film-detail-backdrop')),
            matching: find.byType(AnimatedBuilder),
          ),
        )
        .map((w) => w.animation)
        .whereType<AnimationController>();
    expect(transitions.every((animation) => animation.value == 1), isTrue);
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
    testWidgets('${focus ? '键盘焦点' : '鼠标悬停'}不预解码下一页背景，切页完成后才加载', (tester) async {
      await prepare(tester);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: app,
          child: MaterialApp(
            theme: AppTheme.dark().copyWith(platform: TargetPlatform.windows),
            home: FilmLibraryPage(onOpenItem: (_) async {}),
          ),
        ),
      );
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
      final file = File(
        p.join(
          catalog.images.directory.path,
          '${FilmCatalogImageCache.cacheKey(work.backdropPath!, 'original')}.img',
        ),
      );
      final provider = filmArtworkProvider(
        file,
        target: 'original',
        backdrop: true,
      );
      expect(
        PaintingBinding.instance.imageCache.statusForKey(provider).untracked,
        isTrue,
      );
      await tester.tap(card);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(StreamPathPageShell), findsNothing);
      expect(find.byType(FilmDetailPage), findsOneWidget);
      expect(find.byKey(const Key('film-connected-flight')), findsOneWidget);
      expect(
        PaintingBinding.instance.imageCache.statusForKey(provider).untracked,
        isTrue,
      );
      await settle(tester);
      final route = ModalRoute.of(tester.element(find.byType(FilmDetailPage)))!;
      expect(route, isA<MaterialPageRoute<void>>());
      expect(route.transitionDuration, const Duration(milliseconds: 360));
      expect(
        PaintingBinding.instance.imageCache.statusForKey(provider).keepAlive,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });
  }

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
    await tester.runAsync(
      () => catalog.images.cached(works.first.backdropPath!, 'original'),
    );
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

  testWidgets('共享详情在骨架最短停留期间返回，不在反向运动中揭示正文', (tester) async {
    await prepare(tester, count: 1);
    await tester.runAsync(() async {
      await catalog.store.setPreference('daily_selection', {
        'date': DateTime.now().toIso8601String().substring(0, 10),
        'ids': [works.single.id],
      });
      await catalog.refresh();
    });
    await tester.pumpWidget(frame(FilmLibraryPage(onOpenItem: (_) async {})));
    await settle(tester);
    await tester.tap(
      find
          .byWidgetPredicate(
            (w) => w is FilmWorkCard && w.work.id == works.single.id,
          )
          .first,
    );
    await tester.pump();
    await tester.pump();
    final route = ModalRoute.of(tester.element(find.byType(FilmDetailPage)))!;
    expect(route, isA<FilmConnectedDetailRoute>());
    await tester.pump(const Duration(milliseconds: 420));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(
      tester.widget<SkeletonScope>(find.byType(SkeletonScope)).ready,
      isTrue,
    );
    await tester.pump(const Duration(milliseconds: 120));
    Navigator.of(tester.element(find.byType(FilmDetailPage))).pop();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(route.animation!.status, AnimationStatus.reverse);
    final region = find.byKey(const Key('film-skeleton-logo'));
    final opacity = tester
        .widget<Opacity>(
          find.descendant(of: region, matching: find.byType(Opacity)).first,
        )
        .opacity;
    expect(
      opacity,
      0,
      reason: 'Pending content must stay concealed while returning',
    );
    expect(
      find.descendant(of: region, matching: find.byType(CinematicSkeleton)),
      findsOneWidget,
    );
    await settle(tester);
    expect(find.byType(FilmDetailPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final dpr in [1.0, 1.5, 2.0]) {
    testWidgets('共享封面：每日精选最右侧进入与返回 DPR=$dpr', (tester) async {
      await prepare(tester, count: 20);
      await tester.runAsync(() async {
        await catalog.store.setPreference('daily_selection', {
          'date': DateTime.now().toIso8601String().substring(0, 10),
          'ids': works.take(10).map((w) => w.id).toList(),
        });
        await catalog.refresh();
      });
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = Size(1280 * dpr, 900 * dpr);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: app,
          child: MaterialApp(
            theme: AppTheme.dark().copyWith(platform: TargetPlatform.windows),
            builder: (_, child) => RepaintBoundary(
              key: const Key('connected-frame'),
              child: child!,
            ),
            home: const FilmLibraryShell(sidebarInset: 64),
          ),
        ),
      );
      await settle(tester);
      final shelf = find.byWidgetPredicate(
        (w) => w is FilmShelf && w.title == '每日精选',
      );
      final cards = find.descendant(
        of: shelf,
        matching: find.byType(FilmWorkCard),
      );
      final visible = cards.evaluate().where((e) {
        final rect = tester.getRect(find.byWidget(e.widget));
        return rect.left >= 64 && rect.right <= 1280 && rect.bottom <= 900;
      }).toList();
      expect(visible.length, greaterThan(3));
      final card = find.byWidget(visible.last.widget);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(card));
      await settle(tester);
      final sourceHero = find.descendant(of: card, matching: find.byType(Hero));
      final sourceTag = tester.widget<Hero>(sourceHero).tag;
      final sourceArtwork = find.descendant(
        of: card,
        matching: find.byType(FilmArtwork),
      );
      final sourceState = tester.state(sourceArtwork);
      final start = tester.getRect(sourceHero);
      final points = [
        Offset(start.right - 8, start.top + 8),
        Offset(start.right - 8, start.top + 100),
        start.center,
      ];
      Future<List<int>> sampleCover([List<Offset>? locations]) async =>
          (await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const Key('connected-frame')),
            );
            final image = await boundary.toImage();
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            final result = <int>[];
            for (final point in locations ?? points) {
              final offset =
                  (point.dy.floor() * image.width + point.dx.floor()) * 4;
              result.addAll(bytes.sublist(offset, offset + 4));
            }
            image.dispose();
            return result;
          }))!;
      final sourcePixels = await sampleCover();
      final work = tester.widget<FilmWorkCard>(card).work;
      expect(start.right, greaterThan(1200));
      await tester.tap(card);
      await tester.pump();
      await tester.pump();
      final flight = find.byKey(const Key('film-connected-flight'));
      expect(flight, findsOneWidget);
      final first = tester.getRect(flight);
      expect(
        StreamPathTransitionScope.read(
          tester.element(find.byType(FilmLibraryPage, skipOffstage: false)),
        ),
        isTrue,
      );
      final flightPixels = await sampleCover();
      for (var channel = 0; channel < sourcePixels.length; channel++) {
        expect(
          flightPixels[channel],
          closeTo(sourcePixels[channel], 6),
          reason:
              'Poster, watch marker and rail edge must hand over in the same frame',
        );
      }
      expect(first.left, closeTo(start.left, .5));
      expect(first.top, closeTo(start.top, .5));
      expect(first.width, closeTo(start.width, .5));
      expect(
        find.ancestor(of: flight, matching: find.byType(Scrollable)),
        findsNothing,
      );
      final route = ModalRoute.of(tester.element(find.byType(FilmDetailPage)))!;
      expect(route, isA<FilmConnectedDetailRoute>());
      expect(route.transitionDuration.inMilliseconds, 360);
      expect(route.reverseTransitionDuration.inMilliseconds, 360);
      expect(backdropImages(), findsNothing);
      await tester.pump(const Duration(milliseconds: 180));
      final middle = tester.getRect(flight);
      expect(middle.left, lessThan(start.left));
      expect(middle.left, greaterThan(24));
      await tester.pump(const Duration(milliseconds: 180));
      await tester.pump(const Duration(milliseconds: 1));
      expect(route.animation!.status, AnimationStatus.completed);
      await tester.pump();
      for (var frame = 0; frame < 4; frame++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        final center = tester.getCenter(
          find.byKey(const Key('film-detail-poster')),
        );
        final pixels = await sampleCover([center]);
        for (var channel = 0; channel < 4; channel++) {
          expect(
            pixels[channel],
            closeTo(sourcePixels[8 + channel], 6),
            reason:
                'The cached fallback must remain fully visible while upgrading the detail poster',
          );
        }
      }
      await settle(tester);
      expect(flight, findsNothing);
      final destination = tester.getRect(
        find.byKey(const Key('film-detail-poster')),
      );
      expect(
        StreamPathTransitionScope.read(
          tester.element(find.byType(FilmLibraryPage, skipOffstage: false)),
        ),
        isFalse,
      );
      expect(destination, const Rect.fromLTWH(24, 68, 180, 270));
      final nav = Navigator.of(tester.element(find.byType(FilmDetailPage)));
      await mouse.moveTo(Offset.zero);
      nav.pop();
      await tester.pump();
      await tester.pump();
      expect(flight, findsOneWidget);
      expect(tester.getRect(flight).left, closeTo(destination.left, .5));
      await tester.pump(const Duration(milliseconds: 210));
      expect(tester.getRect(flight).left, greaterThan(24));
      await settle(tester);
      expect(find.byType(FilmDetailPage), findsNothing);
      expect(flight, findsNothing);
      final returnedHero = find.byWidgetPredicate(
        (w) => w is Hero && w.tag == sourceTag,
      );
      expect(
        tester.state(
          find.descendant(of: returnedHero, matching: find.byType(FilmArtwork)),
        ),
        same(sourceState),
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is FilmWorkCard && w.work.id == work.id,
        ),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
      await mouse.removePointer();
    });
  }

  testWidgets('共享封面：横纵滚动、重复点击、窗口变化、中途返回与源卡片消失', (tester) async {
    await prepare(tester, count: 20);
    await tester.runAsync(() async {
      await catalog.store.setPreference('daily_selection', {
        'date': DateTime.now().toIso8601String().substring(0, 10),
        'ids': works.take(10).map((w) => w.id).toList(),
      });
      await catalog.refresh();
    });
    await tester.pumpWidget(frame(FilmLibraryPage(onOpenItem: (_) async {})));
    await settle(tester);
    final shelf = find.byWidgetPredicate(
      (w) => w is FilmShelf && w.title == '每日精选',
    );
    final rail = tester
        .widget<ListView>(
          find.descendant(of: shelf, matching: find.byType(ListView)),
        )
        .controller!;
    rail.jumpTo(rail.position.maxScrollExtent);
    await settle(tester);
    final scrolledOffset = rail.offset;
    Finder visibleCard() => find.byWidget(
      find
          .descendant(of: shelf, matching: find.byType(FilmWorkCard))
          .evaluate()
          .firstWhere((e) {
            final rect = tester.getRect(find.byWidget(e.widget));
            return rect.left >= 24 && rect.right <= 1280;
          })
          .widget,
    );
    final card = visibleCard();
    final sourceTag = tester
        .widget<Hero>(find.descendant(of: card, matching: find.byType(Hero)))
        .tag;
    final ink = tester.widget<InkWell>(
      find.descendant(of: card, matching: find.byType(InkWell)).first,
    );
    ink.onTap!();
    ink.onTap!();
    await tester.pump();
    await tester.pump();
    expect(find.byType(FilmDetailPage), findsOneWidget);
    final flight = find.byKey(const Key('film-connected-flight'));
    expect(flight, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 120));
    tester.view.physicalSize = const Size(1440, 900);
    await tester.pump();
    await settle(tester);
    expect(
      tester.getRect(find.byKey(const Key('film-detail-poster'))),
      const Rect.fromLTWH(24, 68, 180, 270),
    );
    Navigator.of(tester.element(find.byType(FilmDetailPage))).pop();
    await tester.pump();
    await tester.pump();
    expect(flight, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 210));
    tester.view.physicalSize = const Size(1360, 900);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 194));
    final landing = tester.getRect(flight);
    final homeHero = find.descendant(
      of: find.byType(FilmLibraryPage, skipOffstage: false),
      matching: find.byWidgetPredicate(
        (w) => w is Hero && w.tag == sourceTag,
        skipOffstage: false,
      ),
    );
    final latestTarget = tester.getRect(homeHero);
    expect(landing.width, closeTo(latestTarget.width, 1));
    expect(landing.left, closeTo(latestTarget.left, 1));
    ink.onTap!();
    await settle(tester);
    expect(find.byType(FilmDetailPage), findsNothing);
    expect(flight, findsNothing);
    expect(rail.offset, scrolledOffset.clamp(0, rail.position.maxScrollExtent));

    // 相同入口在飞行中返回，不创建第二个详情或残留 Overlay。
    await tester.tap(visibleCard());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    Navigator.of(tester.element(find.byType(FilmDetailPage))).pop();
    await settle(tester);
    expect(flight, findsNothing);
    expect(find.byType(FilmDetailPage), findsNothing);

    // 源页面在详情期间滚动到其他栏目，返回不能飞向已裁掉的卡片。
    await tester.tap(visibleCard());
    await settle(tester);
    final home = tester
        .widget<CustomScrollView>(
          find.byKey(const Key('film-home-scroll'), skipOffstage: false),
        )
        .controller!;
    home.jumpTo(home.position.maxScrollExtent);
    await tester.pump();
    Navigator.of(tester.element(find.byType(FilmDetailPage))).pop();
    await tester.pump();
    await tester.pump();
    expect(flight, findsNothing);
    await settle(tester);
    home.jumpTo(0);
    await settle(tester);

    // 过滤/栏目变更真正卸载原卡片后使用同一退化路径。
    await tester.tap(visibleCard());
    await settle(tester);
    await tester.runAsync(() async {
      await catalog.store.setHomeSections([
        const FilmHomeSection('sources', enabled: true),
        const FilmHomeSection('daily', enabled: false),
      ]);
      await catalog.refresh();
    });
    await tester.pump();
    Navigator.of(tester.element(find.byType(FilmDetailPage))).pop();
    await tester.pump();
    await tester.pump();
    expect(flight, findsNothing);
    await settle(tester);
    expect(find.byType(FilmDetailPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('共享封面：文件位置缓存淘汰后仍复用已显示封面飞行', (tester) async {
    await prepare(tester);
    await tester.pumpWidget(frame(FilmLibraryPage(onOpenItem: (_) async {})));
    await settle(tester);
    final card = find.byType(FilmWorkCard).first;
    final work = tester.widget<FilmWorkCard>(card).work;
    final source = find.descendant(
      of: card,
      matching: find.byType(FilmSharedPoster),
    );
    final anchor = tester.widget<FilmSharedPoster>(source).anchor;
    final file = catalog.images.knownFile(work.posterPath, 'w342')!;
    final artwork = find.descendant(
      of: card,
      matching: find.byType(FilmArtwork),
    );
    final sourceState = tester.state(artwork);
    final provider = tester
        .widget<Image>(
          find.descendant(of: artwork, matching: find.byType(Image)),
        )
        .image;
    final imageKey = await tester.runAsync(
      () => provider.obtainKey(ImageConfiguration.empty),
    );
    expect(
      PaintingBinding.instance.imageCache.statusForKey(imageKey!).live,
      isTrue,
    );
    await tester.runAsync(() async {
      for (var i = 0; i < 129; i++) {
        final path = '/eviction$i.png';
        await file.copy(
          p.join(
            catalog.images.directory.path,
            '${FilmCatalogImageCache.cacheKey(path, 'w342')}.img',
          ),
        );
        await catalog.images.cached(path, 'w342');
      }
    });
    expect(anchor.visible, isTrue);
    expect(anchor.ready, isTrue);
    expect(catalog.images.knownFile(work.posterPath, 'w342'), isNull);
    expect(
      PaintingBinding.instance.imageCache.statusForKey(imageKey).live,
      isTrue,
    );
    expect(tester.state(artwork), same(sourceState));
    await tester.tap(card);
    await tester.pump();
    await tester.pump();
    final route = ModalRoute.of(tester.element(find.byType(FilmDetailPage)));
    expect(route, isA<FilmConnectedDetailRoute>());
    final flight = find.byKey(const Key('film-connected-flight'));
    expect(flight, findsOneWidget);
    expect(tester.widget<Image>(flight).image, same(provider));
    await settle(tester);
    Navigator.of(tester.element(find.byType(FilmDetailPage))).pop();
    await settle(tester);
    expect(tester.state(artwork), same(sourceState));
    expect(tester.takeException(), isNull);
  });

  testWidgets('共享封面：左侧卡片不同悬停阶段、切换页面与后台恢复后二十次往返', (tester) async {
    await prepare(tester, count: 20);
    await tester.runAsync(() async {
      await catalog.store.setPreference('daily_selection', {
        'date': DateTime.now().toIso8601String().substring(0, 10),
        'ids': works.take(10).map((w) => w.id).toList(),
      });
      await catalog.refresh();
    });
    final selected = ValueNotifier(0);
    addTearDown(selected.dispose);
    const library = FilmLibraryShell(sidebarInset: 64);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          theme: AppTheme.dark().copyWith(platform: TargetPlatform.windows),
          home: ValueListenableBuilder<int>(
            valueListenable: selected,
            builder: (_, value, _) => IndexedStack(
              index: value,
              children: const [library, SizedBox.expand()],
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    final shelf = find.byWidgetPredicate(
      (w) => w is FilmShelf && w.title == '每日精选',
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1270, 890));
    for (var round = 0; round < 20; round++) {
      final index = round % 3;
      final card = find
          .descendant(of: shelf, matching: find.byType(FilmWorkCard))
          .at(index);
      final source = find.descendant(
        of: card,
        matching: find.byType(FilmSharedPoster),
      );
      final anchor = tester.widget<FilmSharedPoster>(source).anchor;
      if (round == 6) {
        selected.value = 1;
        await tester.pump();
        expect(anchor.visible, isFalse);
        selected.value = 0;
        await settle(tester);
      }
      if (round == 12) {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await settle(tester);
      }
      if (round == 18) {
        await tester.tap(find.text('播放列表'));
        await settle(tester);
        final context = tester.element(find.text('暂无播放列表'));
        Navigator.of(context).pop();
        await settle(tester);
      }
      await mouse.moveTo(tester.getCenter(card));
      await tester.pump(Duration(milliseconds: [0, 50, 250][round % 3]));
      expect(anchor.visible, isTrue);
      expect(anchor.ready, isTrue);
      await tester.tap(card);
      await tester.pump();
      await tester.pump();
      expect(
        ModalRoute.of(tester.element(find.byType(FilmDetailPage))),
        isA<FilmConnectedDetailRoute>(),
      );
      expect(find.byKey(const Key('film-connected-flight')), findsOneWidget);
      if (round % 4 == 0) {
        await tester.pump(const Duration(milliseconds: 90));
      } else {
        await settle(tester);
      }
      Navigator.of(tester.element(find.byType(FilmDetailPage))).pop();
      await settle(tester);
      await mouse.moveTo(const Offset(1270, 890));
      await tester.pump(const Duration(milliseconds: 250));
    }
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });

  testWidgets('共享封面：源重新可见后恢复飞行，连续打开不同作品', (tester) async {
    await prepare(tester, count: 20);
    await tester.runAsync(() async {
      await catalog.store.setPreference('daily_selection', {
        'date': DateTime.now().toIso8601String().substring(0, 10),
        'ids': works.take(10).map((w) => w.id).toList(),
      });
      await catalog.refresh();
    });
    await tester.pumpWidget(frame(FilmLibraryPage(onOpenItem: (_) async {})));
    await settle(tester);
    final shelf = find.byWidgetPredicate(
      (w) => w is FilmShelf && w.title == '每日精选',
    );
    final card = find
        .descendant(of: shelf, matching: find.byType(FilmWorkCard))
        .first;
    final source = find.descendant(
      of: card,
      matching: find.byType(FilmSharedPoster),
    );
    final anchor = tester.widget<FilmSharedPoster>(source).anchor;
    final home = tester
        .widget<CustomScrollView>(find.byKey(const Key('film-home-scroll')))
        .controller!;
    final offset = tester.getRect(source).top + 10;
    home.jumpTo(offset);
    await tester.pump();
    expect(anchor.visible, isFalse);
    anchor.prepareReturn();
    await tester.pump();
    home.jumpTo(0);
    await settle(tester);
    expect(tester.widget<FilmSharedPoster>(source).anchor, same(anchor));
    expect(anchor.visible, isTrue);
    await tester.tap(card);
    await tester.pump();
    await tester.pump();
    final flight = find.byKey(const Key('film-connected-flight'));
    expect(flight, findsOneWidget);
    await settle(tester);
    final firstId = tester
        .widget<FilmDetailPage>(find.byType(FilmDetailPage))
        .workId;
    Navigator.of(tester.element(find.byType(FilmDetailPage))).pop();
    await settle(tester);
    final other = find
        .descendant(
          of: shelf,
          matching: find.byWidgetPredicate(
            (w) => w is FilmWorkCard && w.work.id != firstId,
          ),
        )
        .first;
    await tester.tap(other);
    await tester.pump();
    await tester.pump();
    expect(flight, findsOneWidget);
    expect(
      tester.widget<FilmDetailPage>(find.byType(FilmDetailPage)).workId,
      isNot(firstId),
    );
    await settle(tester);
    Navigator.of(tester.element(find.byType(FilmDetailPage))).pop();
    await settle(tester);
    expect(flight, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('共享封面：未解码封面沿用轻壳，不启动空白飞行', (tester) async {
    await prepare(tester);
    final work = works.first;
    await tester.runAsync(() async {
      await catalog.store.refreshWork(
        FilmWork(
          id: work.id,
          type: work.type,
          tmdbId: work.tmdbId,
          title: work.title,
          originalTitle: work.originalTitle,
          overview: work.overview,
          language: work.language,
          posterPath: '/uncached-poster.png',
          backdropPath: work.backdropPath,
          metadata: work.metadata,
        ),
      );
      await catalog.refresh();
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          theme: AppTheme.dark().copyWith(platform: TargetPlatform.windows),
          home: FilmLibraryPage(onOpenItem: (_) async {}),
        ),
      ),
    );
    await settle(tester);
    final card = find
        .byWidgetPredicate((w) => w is FilmWorkCard && w.work.id == work.id)
        .first;
    await tester.tap(
      find.descendant(of: card, matching: find.text(work.title)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('film-connected-flight')), findsNothing);
    expect(find.byType(StreamPathPageShell), findsOneWidget);
    expect(find.byType(FilmDetailPage), findsNothing);
    await settle(tester);
    expect(find.byType(FilmDetailPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('共享封面：返回保留已加载标题徽标', (tester) async {
    await prepare(tester);
    final work = works.first;
    const logoPath = '/return-title-logo.png';
    await tester.runAsync(() async {
      final poster = (await catalog.images.cached(work.posterPath!, 'w342'))!;
      await poster.copy(
        p.join(
          catalog.images.directory.path,
          '${FilmCatalogImageCache.cacheKey(logoPath, 'original')}.img',
        ),
      );
      await catalog.store.refreshWork(
        FilmWork(
          id: work.id,
          type: work.type,
          tmdbId: work.tmdbId,
          title: work.title,
          originalTitle: work.originalTitle,
          overview: work.overview,
          language: work.language,
          posterPath: work.posterPath,
          backdropPath: work.backdropPath,
          metadata: {...work.metadata, 'logo_path': logoPath},
        ),
      );
      await catalog.store.setPreference('daily_selection', {
        'date': DateTime.now().toIso8601String().substring(0, 10),
        'ids': [work.id],
      });
      await catalog.refresh();
    });
    await tester.pumpWidget(frame(FilmLibraryPage(onOpenItem: (_) async {})));
    await settle(tester);
    await tester.tap(
      find
          .byWidgetPredicate((w) => w is FilmWorkCard && w.work.id == work.id)
          .first,
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('film-connected-flight')), findsOneWidget);
    await settle(tester);
    final logo = find.byWidgetPredicate(
      (w) => w is FilmArtwork && w.transparent,
    );
    final state = tester.state(logo);
    final image = tester
        .widget<RawImage>(
          find.descendant(of: logo, matching: find.byType(RawImage)).first,
        )
        .image!;
    expect(tester.widget<FilmArtwork>(logo).path, logoPath);
    Navigator.of(tester.element(find.byType(FilmDetailPage))).pop();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(find.byKey(const Key('film-connected-flight')), findsOneWidget);
    expect(
      StreamPathTransitionScope.of(tester.element(find.byType(FilmDetailPage))),
      isTrue,
    );
    expect(tester.widget<FilmArtwork>(logo).path, logoPath);
    expect(tester.state(logo), same(state));
    expect(
      tester
          .widget<RawImage>(
            find.descendant(of: logo, matching: find.byType(RawImage)).first,
          )
          .image!
          .isCloneOf(image),
      isTrue,
    );
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情徽标按墨色叠加描边，并保留左上角背景暗区', (tester) async {
    await prepare(tester, count: 1);
    final work = works.first;
    final font = File(r'C:\Windows\Fonts\msyh.ttc');
    if (font.existsSync()) {
      await tester.runAsync(() async {
        final loader = FontLoader('DetailLogoPreview')
          ..addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          );
        await loader.load();
      });
    }
    Future<void> writeLogo(String path, Color ink) async {
      final paragraph =
          (ui.ParagraphBuilder(
                  ui.ParagraphStyle(
                    fontFamily: 'DetailLogoPreview',
                    fontSize: 110,
                    textAlign: TextAlign.left,
                  ),
                )
                ..pushStyle(
                  ui.TextStyle(
                    color: ink,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 3,
                  ),
                )
                ..addText('Charlotte'))
              .build()
            ..layout(const ui.ParagraphConstraints(width: 900));
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawParagraph(paragraph, const Offset(15, 25));
      final picture = recorder.endRecording();
      final image = await picture.toImage(930, 200);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      await File(
        p.join(
          catalog.images.directory.path,
          '${FilmCatalogImageCache.cacheKey(path, 'original')}.img',
        ),
      ).writeAsBytes(bytes!.buffer.asUint8List());
    }

    const blackLogo = '/detail-black-logo.png';
    const whiteLogo = '/detail-white-logo.png';
    await tester.runAsync(() async {
      await catalog.images.directory.create(recursive: true);
      await writeLogo(blackLogo, Colors.black);
      await writeLogo(whiteLogo, Colors.white);
    });

    Future<void> capture(
      String path,
      ThemeData theme,
      String name, {
      String? backdrop,
    }) async {
      await tester.runAsync(
        () => catalog.store.refreshWork(
          FilmWork(
            id: work.id,
            type: work.type,
            tmdbId: work.tmdbId,
            title: work.title,
            originalTitle: work.originalTitle,
            overview: work.overview,
            language: work.language,
            posterPath: work.posterPath,
            backdropPath: backdrop ?? work.backdropPath,
            metadata: {...work.metadata, 'logo_path': path},
          ),
        ),
      );
      final boundary = GlobalKey();
      final preview = font.existsSync()
          ? theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: 'DetailLogoPreview'),
            )
          : theme;
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: app,
          child: MaterialApp(
            theme: preview,
            home: RepaintBoundary(
              key: boundary,
              child: FilmDetailPage(
                catalog: catalog,
                workId: work.id,
                onOpenItem: (_) async {},
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      final logo = find.byWidgetPredicate(
        (w) => w is FilmArtwork && w.transparent,
      );
      final artwork = tester.widget<FilmArtwork>(logo);
      expect(artwork.logoInkOutline, isTrue);
      expect(artwork.logoPadding, 3);
      expect(artwork.borderRadius, 0);
      final rim = find.descendant(
        of: logo,
        matching: find.byType(ImageFiltered),
      );
      for (var i = 0; i < 100 && rim.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(rim, findsOneWidget);
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory('build/detail-shadow-logo')
          ..createSync(recursive: true);
        await File(
          p.join(directory.path, '$name.png'),
        ).writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      });
    }

    await capture(blackLogo, AppTheme.dark(), 'detail-dark-black-logo');
    await capture(whiteLogo, AppTheme.light(), 'detail-light-white-logo');

    const brightBackdrop = '/detail-bright-backdrop.png';
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      const bounds = Rect.fromLTWH(0, 0, 1920, 1080);
      canvas.drawRect(
        bounds,
        Paint()
          ..shader = ui.Gradient.linear(
            const Offset(0, 0),
            const Offset(0, 1080),
            const [Color(0xFF4A3540), Color(0xFF120C10)],
          ),
      );
      canvas.drawRect(
        bounds,
        Paint()
          ..shader = ui.Gradient.radial(const Offset(1740, 60), 1150, const [
            Color(0xFFFFFFFF),
            Color(0x00FFF3F7),
          ]),
      );
      canvas.drawRect(
        bounds,
        Paint()
          ..shader = ui.Gradient.radial(const Offset(300, 820), 760, const [
            Color(0x55101A28),
            Color(0x00101A28),
          ]),
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(1920, 1080);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      await File(
        p.join(
          catalog.images.directory.path,
          '${FilmCatalogImageCache.cacheKey(brightBackdrop, 'original')}.img',
        ),
      ).writeAsBytes(bytes!.buffer.asUint8List());
    });
    await capture(
      blackLogo,
      AppTheme.dark(),
      'detail-dark-bright-corner',
      backdrop: brightBackdrop,
    );
    expect(tester.takeException(), isNull);
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
      AdaptiveFilmBackdrop(cache: catalog.images, path: work.backdropPath),
    );
    await tester.pumpWidget(artwork(works.first));
    await tester.pumpWidget(artwork(works[1]));
    final file = catalog.images.knownFile(works[1].backdropPath, 'original')!;
    await settle(tester);
    expect(
      tester
          .widget<AdaptiveFilmBackdrop>(find.byType(AdaptiveFilmBackdrop))
          .path,
      works[1].backdropPath,
    );
    expect(
      tester
          .widget<RawImage>(find.byKey(const Key('adaptive-backdrop-sharp')))
          .image!
          .width,
      960,
    );
    expect(
      file.path,
      catalog.images.knownFile(works[1].backdropPath, 'original')!.path,
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
