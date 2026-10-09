import 'dart:io';
import 'dart:ui' show PointerDeviceKind, ImageByteFormat;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/appearance_config.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/main.dart';
import 'package:streampath/presentation/pages/browser_page.dart';
import 'package:streampath/presentation/pages/film_detail_page.dart';
import 'package:streampath/presentation/theme/appearance_controller.dart';
import 'package:streampath/presentation/widgets/directory_breadcrumbs.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';
import 'package:streampath/presentation/widgets/film_shelf.dart';
import 'package:streampath/presentation/widgets/file_tile.dart';
import 'package:streampath/presentation/widgets/window_title_bar.dart';

import 'helpers/shell_test_app_state.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    if (Platform.environment['STREAMPATH_STARTUP_VISUALS'] == '1') {
      for (final (family, name) in [
        ('Segoe UI', 'msyh.ttc'),
        ('Segoe Fluent Icons', 'SegoeIcons.ttf'),
      ]) {
        final font = File(p.join(r'C:\Windows\Fonts', name));
        final loader = FontLoader(family)
          ..addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          );
        await loader.load();
      }
    }
  });
  testWidgets('四项胶囊默认影视库、文件夹搜索与详情沉浸状态往返', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    const channel = MethodChannel('streampath/appearance');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async =>
          call.method == 'isMaximized' || call.method == 'isFullscreen'
          ? false
          : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final fixture = await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('film_dock_');
      final media = await Directory(p.join(temp.path, 'Media')).create();
      for (var i = 1; i <= 3; i++) {
        await File(p.join(media.path, 'Sample$i.mkv')).writeAsBytes([0]);
      }
      final config = StreamPathConfigStore.forPath(
        p.join(temp.path, 'config.json'),
      );
      await config.save(
        StreamPathConfig(
          localRoots: [
            LocalRootConfig(
              rootId: 'dock',
              displayName: 'Dock source',
              path: media.path,
            ),
          ],
          appearance: const AppearanceConfig(
            sidebarMode: SidebarDisplayMode.autoHide,
          ),
        ),
      );
      final progress = await PlaybackProgressService.open(
        inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      final app = ShellTestAppState(
        configStore: config,
        playbackHistoryStore: PlaybackHistoryStore.forPath(
          p.join(temp.path, 'history.json'),
        ),
        progressService: progress,
        mediaLibraryStore: MediaLibraryStore.forPath(
          p.join(temp.path, 'media_library.json'),
        ),
      );
      final c = await app.getFilmCatalog();
      await app.getGlobalSearchIndex();
      final rootId = await c.store.addRoot(
        sourceId: 'local:dock',
        kind: MediaSourceKind.local,
        path: '',
        type: FilmMediaType.movie,
        name: 'Dock source',
      );
      final root = (await c.store.root(rootId))!;
      final generation = await c.store.beginScan(rootId);
      await c.store.stage(root, generation, [
        for (var i = 1; i <= 3; i++)
          FilmScanEntry(
            path: 'Sample$i.mkv',
            parentPath: '',
            name: 'Sample$i.mkv',
            mediaKind: 'video',
          ),
      ]);
      await c.store.commitScan(rootId, generation, cancelled: () => false);
      await c.store.bind(
        await c.store.resources(),
        FilmWork(
          type: FilmMediaType.movie,
          tmdbId: 1,
          title: 'Dock movie',
          originalTitle: 'Original title',
          year: 2020,
          overview: 'An offline fixture synopsis. ' * 40,
          language: 'zh-CN',
          metadata: {
            'presentation_version': 3,
            'vote_average': 7.294,
            'vote_count': 2222,
            'runtime': 63,
            'genres': ['Drama'],
            'credits': {
              'cast': [
                for (var i = 0; i < 20; i++)
                  {'name': 'Actor $i', 'character': 'Role $i'},
              ],
            },
          },
        ),
      );
      await c.refresh();
      return (temp, app, progress, c);
    });
    final (temp, app, progress, catalog) = fixture!;
    final appearance = AppearanceController(
      initialConfig: app.configStore.current.appearance,
      driver: _GlassThemeDriver(),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.runAsync(() async {
        await app.closeTestStores();
        app.dispose();
        appearance.dispose();
        await progress.close();
        await temp.delete(recursive: true);
      });
    });
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull);
    }

    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('dock-test-frame'),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFFC7CFDC), Color(0xFF779DBA), Color(0xFF463B77)],
            ),
          ),
          child: StreamPathApp(
            appState: app,
            appearanceController: appearance,
            autoConnect: false,
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('startup-overlay')), findsOneWidget);
    Future<void> saveStartupFrame(String name) async {
      if (Platform.environment['STREAMPATH_STARTUP_VISUALS'] != '1') return;
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('dock-test-frame')),
        );
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ImageByteFormat.png);
        image.dispose();
        final output = await Directory(
          'build/startup_visuals',
        ).create(recursive: true);
        await File(
          p.join(output.path, '$name.png'),
        ).writeAsBytes(bytes!.buffer.asUint8List());
      });
    }

    await saveStartupFrame('loading');
    await settle();
    expect(find.byKey(const Key('startup-overlay')), findsNothing);
    await saveStartupFrame('ready');
    const sections = ['films', 'folders', 'library', 'settings'];
    expect(app.filmLibraryActive.value, isTrue);
    expect(
      tester.getRect(find.byKey(const Key('film-library-background'))),
      const Rect.fromLTWH(0, 0, 1280, 720),
    );
    expect(find.text('管理影视目录'), findsNothing);
    expect(
      tester
          .widget<Material>(find.byKey(WindowTitleBar.mainSurfaceKey))
          .color!
          .a,
      0,
    );
    final ys = [
      for (final section in sections)
        tester.getCenter(find.byKey(Key('sidebar-$section'))).dy,
    ];
    expect(ys, orderedEquals([...ys]..sort()));
    expect(find.byKey(const Key('sidebar-controls')), findsNothing);
    expect(find.byKey(const Key('sidebar-search')), findsNothing);
    expect(tester.getSize(find.byKey(const Key('sidebar-surface'))).width, 56);
    final dockCenter = tester.getCenter(
      find.byKey(const Key('sidebar-surface')),
    );
    expect(dockCenter.dy, 360);
    expect(find.byKey(const Key('folders-search')), findsNothing);
    final libraryHeader = tester.getRect(find.byType(AppBar));
    await tester.tap(find.text('待整理（0）'));
    await settle();
    expect(find.byType(FilmPendingPage), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const Key('film-library-background'))),
      const Rect.fromLTWH(0, 0, 1280, 720),
    );
    expect(tester.getRect(find.byType(AppBar)), libraryHeader);
    expect(find.byType(BackButton), findsNothing);
    expect(tester.getTopLeft(find.text('主页')).dx, greaterThanOrEqualTo(80));
    final pendingHomeY = tester.getCenter(find.text('主页')).dy;
    expect(pendingHomeY, libraryHeader.bottom + 40);
    await saveStartupFrame('pending');
    final customBackground = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 1280, 720),
        Paint()
          ..shader = const LinearGradient(
            colors: [Color(0xFF98C2DB), Color(0xFF755289)],
          ).createShader(const Rect.fromLTWH(0, 0, 1280, 720)),
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(1280, 720);
      final bytes = await image.toByteData(format: ImageByteFormat.png);
      picture.dispose();
      image.dispose();
      final file = File(p.join(temp.path, 'background.png'));
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      await catalog.store.setBackgroundPath(file.path);
      await catalog.refresh();
      return file;
    });
    await settle();
    final background = find.descendant(
      of: find.byKey(const Key('film-library-background')),
      matching: find.byType(Image),
    );
    expect(background, findsOneWidget);
    expect(
      (tester.widget<Image>(background).image as FileImage).file.path,
      customBackground!.path,
    );
    expect(tester.getRect(background), const Rect.fromLTWH(0, 0, 1280, 720));
    await saveStartupFrame('pending-background');
    await tester.tap(find.text('主页'));
    await settle();
    expect(find.byType(FilmPendingPage), findsNothing);
    expect(
      (tester
                  .widget<Image>(
                    find.descendant(
                      of: find.byKey(const Key('film-library-background')),
                      matching: find.byType(Image),
                    ),
                  )
                  .image
              as FileImage)
          .file
          .path,
      customBackground.path,
    );
    await tester.runAsync(() async {
      await catalog.store.setBackgroundPath(null);
      await catalog.refresh();
    });
    await settle();
    final poster = find.byType(FilmWorkCard).first;
    await tester.tap(poster);
    await settle();
    expect(find.byType(FilmDetailPage), findsOneWidget);
    expect(app.filmDetailChrome.value, 0);
    expect(tester.getRect(find.byType(FilmDetailPage)).left, 0);
    expect(tester.getRect(find.byType(FilmDetailPage)).top, 0);
    expect(tester.getRect(find.byKey(const Key('sidebar-rail'))).right, 0);
    expect(tester.getRect(find.byKey(const Key('film-detail-back'))).top, 34);
    expect(
      find.textContaining('7.3 TMDB   2020', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('2222'), findsNothing);
    final play = tester.widget<FilledButton>(
      find.byKey(const Key('film-detail-play')),
    );
    expect(play.style!.backgroundColor!.resolve({}), Colors.white);
    expect(
      tester
          .widget<Material>(find.byKey(WindowTitleBar.mainSurfaceKey))
          .color!
          .a,
      0,
    );
    final scrollable = find
        .descendant(
          of: find.byKey(const Key('film-detail-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    tester.state<ScrollableState>(scrollable).position.jumpTo(160);
    await tester.pump();
    expect(app.filmDetailChrome.value, 0);
    expect(find.byKey(const Key('film-detail-top-surface')), findsNothing);
    expect(
      tester
          .widget<Material>(find.byKey(WindowTitleBar.mainSurfaceKey))
          .color!
          .a,
      0,
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(400, 300));
    await mouse.moveTo(const Offset(3, 300));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(const Key('sidebar-rail'))).right, 64);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byTooltip('显示侧边栏'), findsNothing);
    expect(find.text('显示侧边栏'), findsNothing);
    await tester.tap(find.byKey(const Key('sidebar-folders')));
    await settle();
    expect(app.mediaSourcesVisible, isTrue);
    expect(app.filmDetailChrome.value, isNull);
    expect(find.text('本地文件夹'), findsOneWidget);
    expect(find.text('网络存储'), findsOneWidget);
    expect(find.text('媒体服务器'), findsOneWidget);
    expect(tester.getRect(find.byKey(WindowTitleBar.mainSurfaceKey)).left, 0);
    expect(
      tester.getCenter(find.byKey(const Key('sidebar-surface'))),
      dockCenter,
    );
    expect(find.byKey(const ValueKey('local-root-dock')), findsNothing);
    expect(find.text('添加服务器以浏览文件夹'), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('folders-network-tab'))).dx,
      84,
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('folders-network-tab'))).dx,
      lessThan(
        tester.getTopLeft(find.byKey(const Key('folders-local-tab'))).dx,
      ),
    );
    final header = tester.getRect(
      find.byKey(const Key('sidebar-header-extension')),
    );
    expect(header.bottom, tester.getRect(find.byType(AppBar)).bottom);
    Future<void> checkPagePixels() => tester.runAsync(() async {
      final frame = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('dock-test-frame')),
      );
      final image = await frame.toImage(pixelRatio: 1);
      final pixels = (await image.toByteData(
        format: ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List();
      for (final y in [16, 48, 100, 127, 170]) {
        final left = (y * image.width + 24) * 4;
        final right = (y * image.width + 500) * 4;
        expect(
          pixels.sublist(left, left + 4),
          pixels.sublist(right, right + 4),
          reason: 'Header, divider and body must span the sidebar at y=$y',
        );
      }
      image.dispose();
    });
    await checkPagePixels();
    await saveStartupFrame('folders');
    for (final brightness in [Brightness.light, Brightness.dark]) {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      for (final opacity in [.35, .7]) {
        await appearance.apply(
          AppearanceConfig(style: InterfaceStyle.glass, glassOpacity: opacity),
        );
        await settle();
        expect(appearance.glassActive, isTrue);
        await checkPagePixels();
        await saveStartupFrame('folders-$brightness-$opacity');
        expect(
          tester.getCenter(find.byKey(const Key('sidebar-surface'))),
          dockCenter,
        );
      }
    }
    await tester.tap(find.byKey(const Key('folders-local-tab')));
    await settle();
    expect(find.byKey(const ValueKey('local-root-dock')), findsOneWidget);
    expect(find.text('添加服务器以浏览文件夹'), findsNothing);
    await tester.tap(find.byKey(const Key('folders-search')));
    await settle();
    expect(
      tester.getRect(find.byKey(const Key('sidebar-header-extension'))).bottom,
      tester.getRect(find.byType(AppBar)).bottom,
    );
    await tester.enterText(
      find.byKey(const Key('global-search-field')),
      'Sample2',
    );
    await settle();
    for (
      var i = 0;
      i < 40 &&
          find
              .byKey(const ValueKey('search-local:dock-Sample2.mkv'))
              .evaluate()
              .isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      find.byKey(const ValueKey('search-local:dock-Sample2.mkv')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('search-local:dock-Sample2.mkv')),
    );
    await settle();
    for (var i = 0; i < 40 && find.byType(FileTile).evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(DirectoryBreadcrumbs), findsOneWidget);
    await checkPagePixels();
    expect(
      tester.getRect(find.byKey(const Key('sidebar-header-extension'))).bottom,
      tester.getRect(find.byType(AppBar)).bottom,
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is FileTile && w.file.name == 'Sample2.mkv',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byType(BackButton).first);
    await settle();
    expect(find.byKey(const Key('global-search-field')), findsOneWidget);
    await tester.tap(find.byType(BackButton).first);
    await settle();
    expect(find.byKey(const Key('folders-search')), findsOneWidget);
    expect(find.byKey(const ValueKey('local-root-dock')), findsOneWidget);
    expect(
      tester.getCenter(find.byKey(const Key('sidebar-surface'))),
      dockCenter,
    );
    expect(
      tester.getRect(find.byKey(const Key('sidebar-header-extension'))).bottom,
      tester.getRect(find.byType(AppBar)).bottom,
    );
    final foldersNavigator = Navigator.of(tester.element(find.byType(AppBar)));
    foldersNavigator.push(
      MaterialPageRoute<void>(
        builder: (_) => BrowserPage(localRoot: app.localRoots.single),
      ),
    );
    await settle();
    expect(
      tester.getRect(find.byKey(const Key('sidebar-header-extension'))).bottom,
      tester.getRect(find.byType(AppBar)).bottom,
    );
    await checkPagePixels();
    foldersNavigator.pop();
    await settle();
    await tester.tap(find.byKey(const Key('sidebar-films')));
    await settle();
    expect(find.byType(FilmDetailPage), findsOneWidget);
    expect(app.filmDetailChrome.value, 0);
    await tester.tap(find.byKey(const Key('film-detail-back')));
    await settle();
    expect(app.filmDetailChrome.value, isNull);
    await tester.runAsync(() => catalog.store.setFavorite(1, true));
    await tester.tap(find.byKey(const Key('sidebar-library')));
    await settle();
    expect(
      tester.getCenter(find.byKey(const Key('sidebar-surface'))),
      dockCenter,
    );
    expect(
      tester.getRect(find.byKey(const Key('sidebar-header-extension'))).bottom,
      tester.getRect(find.byType(AppBar)).bottom,
    );
    for (
      var i = 0;
      i < 40 && find.byType(FilmWorkCard).evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byType(FilmWorkCard).first);
    await settle();
    expect(app.filmDetailChrome.value, 0);
    expect(find.byKey(const Key('film-detail-play')), findsOneWidget);
    expect(find.byType(FilmArtwork), findsWidgets);
    await tester.tap(find.byKey(const Key('film-detail-back')));
    await settle();
    expect(app.filmDetailChrome.value, isNull);
    expect(
      app.configStore.current.appearance.sidebarMode,
      SidebarDisplayMode.autoHide,
    );
    await tester.tap(find.byKey(const Key('sidebar-settings')));
    await settle();
    expect(
      tester.getCenter(find.byKey(const Key('sidebar-surface'))),
      dockCenter,
    );
    expect(
      tester.getRect(find.byKey(const Key('sidebar-header-extension'))).bottom,
      tester.getRect(find.byType(AppBar)).bottom,
    );
    final navigation = tester.getRect(
      find.byKey(const Key('settings-navigation-bar')),
    );
    final extension = tester.getRect(
      find.byKey(const Key('sidebar-settings-navigation-extension')),
    );
    expect(extension.left, 0);
    expect(extension.top, navigation.top);
    expect(extension.bottom, navigation.bottom);
    expect(extension.right, navigation.left);
    await mouse.removePointer();
  });
}

class _GlassThemeDriver implements WindowAppearanceDriver {
  static const capabilities = WindowAppearanceCapabilities(
    isDetected: true,
    platformSupported: true,
    versionMajor: 10,
    versionMinor: 0,
    buildNumber: 26100,
    compositionEnabled: true,
    transparencyEnabled: true,
    highContrast: false,
    remoteSession: false,
    supportsLegacyAcrylic: true,
    supportsMica: true,
    supportsSystemBackdrop: true,
    systemBackdropType: WindowBackdropType.mica,
  );

  @override
  Future<WindowAppearanceCapabilities> queryCapabilities() async =>
      capabilities;

  @override
  Future<WindowAppearanceResult> apply(
    AppearanceConfig config,
    Brightness brightness,
  ) async => WindowAppearanceResult(
    requestedStyle: config.style,
    requestedMaterial: config.material,
    actualBackdrop: config.isGlass
        ? WindowBackdropType.mica
        : WindowBackdropType.none,
    capabilities: capabilities,
  );
}
