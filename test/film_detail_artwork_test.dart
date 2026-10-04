import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/pages/film_detail_page.dart';
import 'package:streampath/presentation/pages/film_library_page.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';
import 'package:streampath/presentation/widgets/film_shelf.dart';

import 'helpers/shell_test_app_state.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory temp;
  late ShellTestAppState app;
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
