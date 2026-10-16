import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/data/remote/webdav_client.dart';
import 'package:streampath/domain/services/webdav_service.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';
import 'package:streampath/domain/services/webdav_media_source_adapter.dart';
import 'package:streampath/features/video_cache/video_cache_models.dart';
import 'package:streampath/features/video_cache/video_cache_service.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/theme/glass_tokens.dart';
import 'package:streampath/presentation/widgets/glass_surface.dart';
import 'package:streampath/presentation/widgets/video_cache_widgets.dart';
import 'package:streampath/presentation/widgets/film_detail_buttons.dart';
import 'package:streampath/presentation/widgets/film_detail_back_button.dart';
import 'package:streampath/presentation/widgets/sp_icons.dart';
import 'package:streampath/presentation/theme/window_appearance_status.dart';

class _Directories extends WebDAVService {
  _Directories()
    : super(
        client: WebDavClient(baseUrl: 'https://fixture.invalid/'),
        profileId: 'fixture',
      );
  @override
  Future<List<WebDavFile>> fetchDirectory(
    String path, {
    bool forceRefresh = false,
  }) async => const [
    WebDavFile(
      name: 'Show',
      href: 'https://fixture.invalid/Show/',
      isDirectory: true,
      isSelfEntry: true,
    ),
    WebDavFile(
      name: 'Episode.mkv',
      href: 'Show/Episode.mkv',
      isDirectory: false,
      size: 1024,
    ),
  ];
}

class _CacheAppState extends AppState {
  _CacheAppState({
    required super.configStore,
    required super.playbackHistoryStore,
    required super.progressService,
    required super.videoCacheService,
    required this.catalog,
  });
  final FilmCatalogController Function() catalog;

  @override
  Future<FilmCatalogController> getFilmCatalog() async => catalog();
}

Map<String, dynamic> _available(String _) => {
  'available': 1024 * 1024 * 1024,
  'volume': 'fixture',
  'fat32': false,
};

class _CacheBackdropPattern extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    for (var x = 0; x < size.width; x += 8) {
      canvas.drawRect(
        Rect.fromLTWH(x.toDouble(), 0, 8, size.height),
        Paint()..color = x % 16 == 0 ? Colors.white : Colors.black,
      );
    }
  }

  @override
  bool shouldRepaint(_CacheBackdropPattern oldDelegate) => false;
}

void main() {
  testWidgets('缓存弹窗与浮窗覆盖四语言、明暗材质、窄窗及双倍文字', (tester) async {
    final root = await tester.runAsync(
      () => Directory.systemTemp.createTemp('sp_cache_widgets_'),
    );
    late VideoCacheService cache;
    late AppState app;
    late PlaybackProgressService progress;
    late FilmCatalogStore store;
    late FilmResource resource;
    late FilmCatalogController catalog;
    late HttpServer server;
    await tester.runAsync(() async {
      final font = File(r'C:\Windows\Fonts\msyh.ttc');
      if (await font.exists()) {
        final loader = FontLoader('CacheTestFont')
          ..addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          );
        await loader.load();
      }
      for (final entry in {
        'Segoe Fluent Icons': r'C:\Windows\Fonts\SegoeIcons.ttf',
        'Segoe UI': r'C:\Windows\Fonts\segoeui.ttf',
        'Microsoft YaHei UI': r'C:\Windows\Fonts\msyh.ttc',
      }.entries) {
        final file = File(entry.value);
        if (await file.exists()) {
          await (FontLoader(entry.key)..addFont(
                Future.value(ByteData.sublistView(await file.readAsBytes())),
              ))
              .load();
        }
      }
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.statusCode = 206;
        request.response.headers.set('content-range', 'bytes 0-0/1024');
        request.response.headers.set('etag', '"fixture"');
        request.response.contentLength = 1;
        request.response.add([1]);
        await request.response.close();
      });
      cache = await VideoCacheService.open(
        dataDirectory: root,
        diskSpaceProvider: _available,
        resolveTransfer: (source, path, strm) async => {
          'kind': 'http',
          'url': 'http://127.0.0.1:${server.port}/$path',
          'origin': 'http://127.0.0.1:${server.port}',
          'headers': <String, String>{},
          'identity': 'fixture',
          'progress': 'https://fixture.invalid/$path',
        },
      );
      final config = StreamPathConfigStore.forPath(
        '${root!.path}/settings.json',
      );
      progress = await PlaybackProgressService.open('${root.path}/progress.db');
      app = _CacheAppState(
        catalog: () => catalog,
        configStore: config,
        playbackHistoryStore: PlaybackHistoryStore.forPath(
          '${root.path}/history.json',
        ),
        progressService: progress,
        videoCacheService: cache,
      );
      store = await FilmCatalogStore.open('${root.path}/catalog.db');
      final id = await store.addRoot(
        sourceId: 'fixture',
        kind: MediaSourceKind.webdav,
        path: 'Show',
        type: FilmMediaType.tv,
        name: 'Fixture',
      );
      final catalogRoot = (await store.root(id))!;
      final generation = await store.beginScan(id);
      await store.stage(catalogRoot, generation, [
        const FilmScanEntry(
          path: 'Show/Episode.mkv',
          parentPath: 'Show',
          name: 'Episode.mkv',
          mediaKind: 'video',
        ),
      ]);
      await store.commitScan(id, generation, cancelled: () => false);
      resource = (await store.resources(rootId: id)).single;
      await store.bind(
        [resource],
        const FilmWork(
          type: FilmMediaType.tv,
          tmdbId: 1,
          title: 'Fixture',
          originalTitle: 'Fixture',
          overview: '',
          language: 'zh-CN',
          posterPath: '/fixture.png',
        ),
      );
      final tmdb = TmdbMetadataService();
      final images = FilmCatalogImageCache(
        Directory('${root.path}/images'),
        tmdb,
      );
      await images.directory.create();
      await File(
        '${images.directory.path}/${FilmCatalogImageCache.cacheKey('/fixture.png', 'w92')}.img',
      ).writeAsBytes(await File('assets/tmdb_logo.png').readAsBytes());
      await images.cached('/fixture.png', 'w92');
      catalog = FilmCatalogController(
        store: store,
        tmdb: tmdb,
        images: images,
        sourceFor: (_) => WebDavMediaSourceAdapter(_Directories()),
        ownsResources: false,
      );
    });
    final boundary = GlobalKey();
    final referenceScroll = ScrollController();
    addTearDown(referenceScroll.dispose);
    try {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.runAsync(
        () => precacheImage(
          filmArtworkProvider(
            catalog.images.knownFile('/fixture.png', 'w92')!,
            target: 'w92',
          ),
          tester.element(find.byType(MaterialApp)),
        ),
      );
      for (final locale in [
        const Locale('zh', 'CN'),
        const Locale('zh', 'TW'),
        const Locale('ja'),
        const Locale('en'),
      ]) {
        for (final dark in [true, false]) {
          for (final glass in [true, false]) {
            for (final width in [1280.0, 720.0]) {
              for (final scale in [1.0, 2.0]) {
                tester.view.physicalSize = Size(width, 900);
                tester.view.devicePixelRatio = 1;
                await tester.pumpWidget(
                  ChangeNotifierProvider<AppState>.value(
                    value: app,
                    child: MaterialApp(
                      locale: locale,
                      supportedLocales: const [
                        Locale('zh', 'CN'),
                        Locale('zh', 'TW'),
                        Locale('ja'),
                        Locale('en'),
                      ],
                      localizationsDelegates: const [
                        AppLocalizations.delegate,
                        GlobalMaterialLocalizations.delegate,
                        GlobalWidgetsLocalizations.delegate,
                        GlobalCupertinoLocalizations.delegate,
                      ],
                      theme: dark
                          ? AppTheme.dark(
                              glass: glass,
                              fontFamily: 'CacheTestFont',
                            )
                          : AppTheme.light(
                              glass: glass,
                              fontFamily: 'CacheTestFont',
                            ),
                      builder: (context, child) => MediaQuery(
                        data: MediaQuery.of(
                          context,
                        ).copyWith(textScaler: TextScaler.linear(scale)),
                        child: child!,
                      ),
                      home: RepaintBoundary(
                        key: boundary,
                        child: Scaffold(
                          body: Center(
                            child: VideoCacheDownloadDialog(
                              key: ValueKey(
                                '$locale-$dark-$glass-$width-$scale',
                              ),
                              cache: cache,
                              source: WebDavMediaSourceAdapter(_Directories()),
                              groups: [
                                [resource],
                              ],
                              title: 'Fixture series / S01',
                              disc: true,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
                for (var i = 0; i < 5; i++) {
                  await tester.runAsync(
                    () =>
                        Future<void>.delayed(const Duration(milliseconds: 20)),
                  );
                  await tester.pump();
                }
                expect(
                  tester.takeException(),
                  isNull,
                  reason: '$locale $dark $glass $width $scale',
                );
                expect(
                  find.byKey(const Key('confirm-video-cache')),
                  findsOneWidget,
                );
                if (locale == const Locale('en') &&
                    glass &&
                    !dark &&
                    width == 720 &&
                    scale == 2) {
                  await tester.runAsync(() async {
                    final image =
                        await (boundary.currentContext!.findRenderObject()
                                as RenderRepaintBoundary)
                            .toImage();
                    final bytes = await image.toByteData(
                      format: ui.ImageByteFormat.png,
                    );
                    image.dispose();
                    final file = File(
                      'build/video-cache-ui/dialog-en-light-narrow-2x.png',
                    );
                    await file.parent.create(recursive: true);
                    await file.writeAsBytes(bytes!.buffer.asUint8List());
                  });
                }
              }
            }
          }
        }
      }
      final info = await tester.runAsync(
        () => cache.probe('fixture', 'Show/Episode.mkv'),
      );
      await tester.runAsync(
        () => cache.enqueue([
          VideoCachePlan(
            bundle: {
              'id': 'ui',
              'source': 'fixture',
              'identity': 'fixture',
              'path': 'Show/Episode.mkv',
              'name': 'Episode.mkv',
              'files': ['ui-file'],
              'main': 'ui-file',
              'root': cache.targetDirectory,
              'kind': 'video',
              'progress': 'https://fixture.invalid/Show/Episode.mkv',
              'audio': [],
              'fonts': [],
              'directories': {},
              'subtitle': null,
            },
            files: [
              VideoCacheFile({
                'id': 'ui-file',
                'source': 'fixture',
                'path': 'Show/Episode.mkv',
                'root': cache.targetDirectory,
                'destination':
                    '${cache.targetDirectory}/StreamPathCache/Episode.mkv',
                'identity': 'fixture',
                ...info!,
              }),
            ],
          ),
        ]),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: app,
          child: MaterialApp(
            theme: AppTheme.dark(glass: true),
            home: RepaintBoundary(
              key: boundary,
              child: Scaffold(
                body: Stack(
                  children: [
                    Positioned.fill(
                      child: VideoCacheOverlay(
                        child: CustomPaint(
                          painter: _CacheBackdropPattern(),
                          child: const SizedBox.expand(
                            child: Text('Current page'),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      top: 0,
                      child: FilmDetailBackButton(
                        scrollController: referenceScroll,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const Key('video-cache-floating-button')),
        findsOneWidget,
      );
      final floating = tester.widget<IconButton>(
        find.byKey(const Key('video-cache-floating-button')),
      );
      expect(floating.style!.shape!.resolve({}), isA<CircleBorder>());
      expect(
        find.ancestor(
          of: find.byKey(const Key('video-cache-floating-button')),
          matching: find.byType(FilmDetailActionSurface),
        ),
        findsOneWidget,
      );
      final floatingContext = tester.element(
        find.byKey(const Key('video-cache-floating-button')),
      );
      final referenceStyle = FilmDetailActionButton.styleOf(floatingContext);
      expect(
        floating.style!.backgroundColor!.resolve({}),
        referenceStyle.backgroundColor!.resolve({}),
      );
      expect(
        floating.style!.side!.resolve({}),
        referenceStyle.side!.resolve({}),
      );
      await tester.tap(find.byKey(const Key('video-cache-floating-button')));
      await tester.pump();
      final panel = find.byKey(const Key('video-cache-panel'));
      final reveal = find.byKey(const Key('video-cache-panel-reveal'));
      Rect visibleRect() => tester
          .widget<ClipRect>(reveal)
          .clipper!
          .getClip(tester.getSize(reveal));
      Future<void> capture(String name, {bool checkBlur = true}) async {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final rgba = (await image.toByteData())!.buffer.asUint8List();
          if (checkBlur) {
            final rect = tester.getRect(panel);
            final y = rect.bottom.round() - 50;
            final samples = [
              for (
                var x = rect.right.round() - 110;
                x < rect.right.round() - 50;
                x++
              )
                rgba[(y * image.width + x) * 4],
            ];
            expect(
              samples.reduce((a, b) => a > b ? a : b) -
                  samples.reduce((a, b) => a < b ? a : b),
              lessThan(6),
              reason: name,
            );
          }
          final output = File('build/cache-panel-animation/$name.png');
          await output.parent.create(recursive: true);
          if (name == 'widget-open-50') {
            await File('build/cache-panel-animation/layers.txt').writeAsString(
              (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .debugLayer!
                  .toStringDeep(),
            );
          }
          await output.writeAsBytes(
            (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!.buffer.asUint8List(),
          );
          image.dispose();
        });
      }

      expect(panel, findsOneWidget);
      final initialPanelRect = tester.getRect(panel);
      final collapse = find.byKey(const Key('video-cache-collapse'));
      final collapseButton = tester.widget<IconButton>(collapse);
      expect(
        tester.getSize(collapse),
        tester.getSize(find.byKey(const Key('film-detail-back'))),
      );
      expect((collapseButton.icon as Icon).icon, SPIcons.chevronDown);
      expect(collapseButton.style!.shape!.resolve({}), isA<CircleBorder>());
      for (final states in [
        <WidgetState>{},
        {WidgetState.hovered},
        {WidgetState.focused},
        {WidgetState.pressed},
      ]) {
        expect(
          collapseButton.style!.backgroundColor!.resolve(states),
          Colors.transparent,
        );
        expect(
          collapseButton.style!.overlayColor!.resolve(states),
          Colors.transparent,
        );
        expect(collapseButton.style!.side!.resolve(states), BorderSide.none);
      }
      expect(
        find.ancestor(
          of: collapse,
          matching: find.byType(FilmDetailActionSurface),
        ),
        findsNothing,
      );
      final panelElement = tester.element(panel);
      expect(visibleRect().size, Size.zero);
      await capture('widget-open-0', checkBlur: false);
      expect(
        find.descendant(
          of: find.byType(VideoCacheOverlay),
          matching: find.byType(FadeTransition),
        ),
        findsNothing,
      );
      var lastWidth = 0.0;
      for (var frame = 1; frame <= 4; frame++) {
        await tester.pump(const Duration(milliseconds: 60));
        expect(tester.getRect(panel), initialPanelRect);
        expect(visibleRect().width, greaterThan(lastWidth));
        lastWidth = visibleRect().width;
        expect(tester.element(panel), same(panelElement));
        await capture('widget-open-${frame * 25}');
      }
      final fullyVisible = visibleRect();
      await tester.tap(find.byKey(const Key('video-cache-floating-button')));
      await tester.pump();
      expect(panel, findsOneWidget);
      expect(visibleRect(), fullyVisible);
      await tester.pump(const Duration(milliseconds: 50));
      expect(visibleRect().width, lessThan(fullyVisible.width));
      final taskToggle = find.byKey(const Key('video-cache-toggle-ui'));
      expect(
        tester
            .hitTestOnBinding(tester.getCenter(taskToggle))
            .path
            .any((entry) => entry.target == tester.renderObject(taskToggle)),
        isFalse,
      );
      final reversing = visibleRect();
      await tester.tap(find.byKey(const Key('video-cache-floating-button')));
      await tester.pump();
      expect(visibleRect(), reversing);
      expect(tester.element(panel), same(panelElement));
      cache.changes.value++;
      await tester.pump();
      expect(visibleRect(), reversing);
      await tester.pumpAndSettle();
      for (var i = 0; i < 20; i++) {
        await tester.tap(find.byKey(const Key('video-cache-floating-button')));
        await tester.pump(const Duration(milliseconds: 20));
        await tester.tap(find.byKey(const Key('video-cache-floating-button')));
        await tester.pump(const Duration(milliseconds: 20));
        expect(tester.element(panel), same(panelElement));
      }
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('video-cache-floating-button')));
      await tester.pump();
      await capture('widget-close-0');
      for (var frame = 1; frame <= 3; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
        await capture('widget-close-${frame * 25}');
      }
      await tester.pump(const Duration(milliseconds: 50));
      expect(visibleRect().size, Size.zero);
      await tester.pump(const Duration(milliseconds: 1));
      expect(panel, findsNothing);
      await capture('widget-close-100', checkBlur: false);
      await tester.tap(find.byKey(const Key('video-cache-floating-button')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      await tester.tap(find.byKey(const Key('video-cache-floating-button')));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      await tester.tap(find.byKey(const Key('video-cache-floating-button')));
      await tester.pumpAndSettle();
      for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = Size(560 * dpr, 720 * dpr);
        await tester.pump();
        final resized = tester.getRect(panel);
        expect(resized.left, greaterThanOrEqualTo(24));
        expect(resized.top, greaterThanOrEqualTo(0));
        expect(resized.right, lessThanOrEqualTo(560));
        expect(resized.bottom, lessThanOrEqualTo(720));
        expect(tester.takeException(), isNull);
      }
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      await tester.pump();
      expect(panel, findsOneWidget);
      expect(find.text('Episode.mkv'), findsOneWidget);
      expect(find.text('Current page'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('video-cache-toggle-ui')));
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
      expect(cache.bundles['ui']!['state'], 'paused');
      await tester.tap(find.byKey(const Key('video-cache-toggle-ui')));
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
      expect(cache.bundles['ui']!['state'], 'queued');
      expect(find.byKey(const Key('video-cache-cancel-ui')), findsNothing);
      await tester.tap(find.byKey(const Key('video-cache-delete-ui')));
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pumpAndSettle();
      expect(find.text('删除视频缓存？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(cache.bundles['ui']!['state'], 'queued');
      await tester.pumpWidget(const SizedBox.shrink());
      final longSourcePath =
          '网盘/STRM/电影资源/${List.filled(20, '长路径与文件名').join('/')}/Episode.strm';
      final longRootPath = 'D:\\${List.filled(20, '视频缓存目录').join('\\')}';
      cache.files['ui-file']!.data['path'] = longSourcePath;
      cache.bundles['ui']!['root'] = longRootPath;
      cache.files['shared'] = VideoCacheFile({
        'id': 'shared',
        'path': 'Show/Subtitle.srt',
        'size': 1024,
        'received': 1024,
        'state': 'completed',
      });
      cache.files['finished'] = VideoCacheFile({
        'id': 'finished',
        'path': 'Show/Finished.mkv',
        'size': 1024,
        'received': 1024,
        'state': 'completed',
      });
      cache.bundles['ui']!['files'] = ['ui-file', 'shared'];
      cache.bundles['finished'] = {
        ...cache.bundles['ui']!,
        'id': 'finished',
        'name': 'Finished episode',
        'path': 'Show/Unknown.mkv',
        'files': ['finished', 'shared'],
      };
      for (final locale in [
        const Locale('zh', 'CN'),
        const Locale('zh', 'TW'),
        const Locale('ja'),
        const Locale('en'),
      ]) {
        for (final dark in [true, false]) {
          for (final material in ['solid', 'acrylic', 'mica']) {
            for (final width in [1280.0, 560.0]) {
              for (final scale in [1.0, 2.0]) {
                tester.view.physicalSize = Size(width, 720);
                final theme = dark
                    ? AppTheme.dark(
                        glass: material != 'solid',
                        windowBackdrop: material == 'mica'
                            ? WindowBackdropType.mica
                            : WindowBackdropType.systemAcrylic,
                        fontFamily: 'CacheTestFont',
                      )
                    : AppTheme.light(
                        glass: material != 'solid',
                        windowBackdrop: material == 'mica'
                            ? WindowBackdropType.mica
                            : WindowBackdropType.systemAcrylic,
                        fontFamily: 'CacheTestFont',
                      );
                await tester.pumpWidget(
                  ChangeNotifierProvider<AppState>.value(
                    value: app,
                    child: MaterialApp(
                      key: ValueKey('$locale-$dark-$material-$width-$scale'),
                      locale: locale,
                      supportedLocales: const [
                        Locale('zh', 'CN'),
                        Locale('zh', 'TW'),
                        Locale('ja'),
                        Locale('en'),
                      ],
                      localizationsDelegates: const [
                        AppLocalizations.delegate,
                        GlobalMaterialLocalizations.delegate,
                        GlobalWidgetsLocalizations.delegate,
                        GlobalCupertinoLocalizations.delegate,
                      ],
                      theme: theme,
                      builder: (context, child) => MediaQuery(
                        data: MediaQuery.of(
                          context,
                        ).copyWith(textScaler: TextScaler.linear(scale)),
                        child: child!,
                      ),
                      home: RepaintBoundary(
                        key: boundary,
                        child: const Scaffold(
                          body: VideoCacheOverlay(
                            child: Center(child: VideoCacheSettingsCard()),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
                await tester.pump();
                await tester.tap(
                  find.byKey(const Key('video-cache-floating-button')),
                );
                await tester.pump();
                await tester.runAsync(
                  () async =>
                      Future<void>.delayed(const Duration(milliseconds: 30)),
                );
                await tester.pumpAndSettle();
                final summary = tester.widget<LinearProgressIndicator>(
                  find.byKey(const Key('video-cache-total-progress')),
                );
                expect(summary.value, closeTo(1 / 2, .001));
                expect(
                  find.byKey(const Key('video-cache-task-finished')),
                  findsNothing,
                );
                final task = find.byKey(const Key('video-cache-task-ui'));
                final floatingPoster = tester.widget<FilmArtwork>(
                  find.descendant(of: task, matching: find.byType(FilmArtwork)),
                );
                expect(floatingPoster.path, '/fixture.png');
                expect(floatingPoster.target, 'w92');
                expect(
                  tester.getSize(find.byType(FilmArtwork).first),
                  const Size(44, 66),
                );
                expect(
                  find.descendant(of: task, matching: find.byType(IconButton)),
                  findsNWidgets(2),
                );
                expect(
                  find.byKey(const Key('video-cache-cancel-ui')),
                  findsNothing,
                );
                final pathText = tester.widget<Text>(find.text(longSourcePath));
                expect(pathText.maxLines, 1);
                expect(pathText.softWrap, isFalse);
                expect(pathText.overflow, TextOverflow.ellipsis);
                expect(
                  tester
                      .renderObject<RenderParagraph>(find.text(longSourcePath))
                      .didExceedMaxLines,
                  isTrue,
                );
                final panel = tester.widget<GlassSurface>(
                  find.byKey(const Key('video-cache-panel')),
                );
                expect(panel.blurSigma, 20);
                if (dark && material != 'solid') {
                  expect(
                    Theme.of(
                      tester.element(
                        find.byKey(const Key('video-cache-panel')),
                      ),
                    ).glass.raisedSurface.a,
                    closeTo(.65, .001),
                  );
                }
                expect(
                  tester
                      .widget<CircularProgressIndicator>(
                        find.byType(CircularProgressIndicator),
                      )
                      .value,
                  summary.value,
                );
                expect(
                  tester.takeException(),
                  isNull,
                  reason: '$locale $dark $material $width $scale overlay',
                );
                if (locale == const Locale('zh', 'CN') &&
                    dark &&
                    material == 'acrylic' &&
                    width == 1280 &&
                    scale == 1) {
                  await tester.runAsync(() async {
                    final image =
                        await (boundary.currentContext!.findRenderObject()
                                as RenderRepaintBoundary)
                            .toImage();
                    final bytes = await image.toByteData(
                      format: ui.ImageByteFormat.png,
                    );
                    image.dispose();
                    await File(
                      'build/video-cache-ui/style-overlay-dark.png',
                    ).writeAsBytes(bytes!.buffer.asUint8List());
                  });
                }
                await tester.tap(
                  find.byTooltip(
                    AppLocalizations.of(
                      tester.element(find.byType(VideoCacheOverlay)),
                    ).text('收起缓存浮窗'),
                  ),
                );
                await tester.pumpAndSettle();
                await tester.tap(
                  find.text(
                    AppLocalizations.of(
                      tester.element(find.byType(VideoCacheOverlay)),
                    ).text('管理视频缓存'),
                  ),
                );
                await tester.runAsync(
                  () async =>
                      Future<void>.delayed(const Duration(milliseconds: 20)),
                );
                await tester.pumpAndSettle();
                await tester.runAsync(() async {
                  await precacheImage(
                    filmArtworkProvider(
                      catalog.images.knownFile('/fixture.png', 'w92')!,
                      target: 'w92',
                    ),
                    tester.element(find.byType(VideoCacheOverlay)),
                  );
                  await Future<void>.delayed(const Duration(milliseconds: 30));
                });
                await tester.pumpAndSettle();
                expect(
                  find.byKey(const Key('video-cache-total-progress')),
                  findsOneWidget,
                );
                expect(
                  tester
                      .widget<LinearProgressIndicator>(
                        find.byKey(const Key('video-cache-total-progress')),
                      )
                      .value,
                  closeTo(2 / 3, .001),
                );
                final poster = tester.widget<FilmArtwork>(
                  find.byType(FilmArtwork).first,
                );
                expect(poster.path, '/fixture.png');
                expect(poster.target, 'w92');
                expect(
                  tester.getSize(find.byType(FilmArtwork).first),
                  const Size(44, 66),
                );
                expect(
                  find.byKey(const Key('video-cache-cancel-ui')),
                  findsNothing,
                );
                expect(
                  find.descendant(
                    of: find.byKey(const Key('video-cache-task-ui')),
                    matching: find.byType(IconButton),
                  ),
                  findsNWidgets(2),
                );
                final destinationText = tester.widget<Text>(
                  find.descendant(
                    of: find.byKey(const Key('video-cache-task-ui')),
                    matching: find.text(longRootPath),
                  ),
                );
                expect(destinationText.maxLines, 1);
                expect(destinationText.softWrap, isFalse);
                expect(destinationText.overflow, TextOverflow.ellipsis);
                if (dark && material != 'solid') {
                  expect(
                    Theme.of(
                      tester.element(find.byType(AlertDialog)),
                    ).dialogTheme.backgroundColor!.a,
                    closeTo(.65, .001),
                  );
                }
                expect(
                  tester.takeException(),
                  isNull,
                  reason: '$locale $dark $material $width $scale management',
                );
                final list = find.descendant(
                  of: find.byType(AlertDialog),
                  matching: find.byType(ListView),
                );
                await tester.drag(list, const Offset(0, -380));
                await tester.pumpAndSettle();
                expect(
                  find.byKey(const Key('video-cache-task-finished')),
                  findsOneWidget,
                );
                expect(tester.takeException(), isNull);
                if (locale == const Locale('en') &&
                    !dark &&
                    material == 'mica' &&
                    width == 560 &&
                    scale == 2) {
                  await tester.runAsync(() async {
                    final image =
                        await (tester.firstRenderObject<RenderRepaintBoundary>(
                          find.ancestor(
                            of: find.byType(AlertDialog),
                            matching: find.byType(RepaintBoundary),
                          ),
                        )).toImage();
                    final bytes = await image.toByteData(
                      format: ui.ImageByteFormat.png,
                    );
                    image.dispose();
                    await File(
                      'build/video-cache-ui/style-management-en-light-narrow-2x.png',
                    ).writeAsBytes(bytes!.buffer.asUint8List());
                  });
                }
                await tester.pumpWidget(const SizedBox.shrink());
              }
            }
          }
        }
      }
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: app,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: const Scaffold(
              body: VideoCacheOverlay(child: SizedBox.expand()),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('video-cache-floating-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('video-cache-delete-ui')));
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pumpAndSettle();
      expect(cache.bundles, isEmpty);
      expect(
        find.byKey(const Key('video-cache-floating-button')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await tester.runAsync(() async {
        await app.prepareForClose();
        app.dispose();
        catalog.dispose();
        catalog.images.close();
        catalog.tmdb.close();
        await store.close();
        await progress.close();
        await server.close(force: true);
        await root!.delete(recursive: true);
      });
    }
  });
}
