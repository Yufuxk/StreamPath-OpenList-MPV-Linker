import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/appearance_config.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/main.dart';
import 'package:streampath/presentation/widgets/adaptive_film_backdrop.dart';
import 'package:streampath/presentation/widgets/app_background.dart';
import 'package:streampath/presentation/widgets/window_title_bar.dart';
import 'package:streampath/presentation/theme/appearance_controller.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/theme/glass_tokens.dart';

import 'helpers/shell_test_app_state.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  for (final brightness in Brightness.values) {
    for (final style in InterfaceStyle.values) {
      testWidgets('全局背景铺满窗口并跨页面保留解码帧 $brightness $style', (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        const channel = MethodChannel('streampath/appearance');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async => false,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );

        final fixture = await tester.runAsync(() async {
          final temp = await Directory.systemTemp.createTemp('app_background_');
          final config = StreamPathConfigStore.forPath(
            '${temp.path}/config.json',
          );
          await config.save(
            StreamPathConfig(appearance: AppearanceConfig(style: style)),
          );
          final progress = await PlaybackProgressService.open(
            inMemoryDatabasePath,
            factory: databaseFactoryFfi,
          );
          final app = ShellTestAppState(
            configStore: config,
            playbackHistoryStore: PlaybackHistoryStore.forPath(
              '${temp.path}/history.json',
            ),
            progressService: progress,
          );
          final catalog = await app.getFilmCatalog();
          await catalog.images.directory.create(recursive: true);
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawColor(const Color(0xFF637EA0), BlendMode.src);
          final picture = recorder.endRecording();
          final image = await picture.toImage(1280, 720);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('${temp.path}/background.png');
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
          picture.dispose();
          await catalog.store.setBackgroundPath(file.path);
          return (temp, app, progress, catalog);
        });
        final (temp, app, progress, catalog) = fixture!;
        final appearance = AppearanceController(
          initialConfig: app.configStore.current.appearance,
          driver: _Driver(),
        );
        await appearance.apply(app.configStore.current.appearance);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            await app.closeTestStores();
            app.dispose();
            appearance.dispose();
            await progress.close();
            await temp.delete(recursive: true);
          });
        });

        Future<void> settle() async {
          for (var i = 0; i < 12; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(tester.takeException(), isNull);
        }

        await tester.pumpWidget(
          StreamPathApp(
            appState: app,
            appearanceController: appearance,
            autoConnect: false,
          ),
        );
        await settle();
        final background = find.byType(AdaptiveFilmBackdrop);
        expect(background, findsOneWidget);
        expect(
          tester.getRect(background),
          const Rect.fromLTWH(0, 0, 1280, 720),
        );
        final element = tester.element(background);
        final sharp = find.byKey(const Key('adaptive-backdrop-sharp'));
        final image = tester.widget<RawImage>(sharp).image;
        expect(image, isNotNull);
        expect(app.startupReady.value, isTrue);
        if (style == InterfaceStyle.glass && brightness == Brightness.dark) {
          final theme = Theme.of(tester.element(find.byType(WindowTitleBar)));
          expect(
            AppTheme.controlBarTheme(theme).glass.chromeSurface,
            GlassTokens.controlBarDark.withValues(alpha: .25),
          );
        }

        for (final section in ['folders', 'library', 'settings', 'films']) {
          await tester.tap(find.byKey(Key('sidebar-$section')));
          await settle();
          expect(tester.element(background), same(element));
          expect(tester.widget<RawImage>(sharp).image, same(image));
          expect(
            tester.getRect(background),
            const Rect.fromLTWH(0, 0, 1280, 720),
          );
          final titleBar = tester.element(find.byType(WindowTitleBar));
          expect(
            Theme.of(titleBar).scaffoldBackgroundColor,
            Colors.transparent,
          );
          expect(
            tester
                .widget<Material>(find.byKey(WindowTitleBar.mainSurfaceKey))
                .color,
            Colors.transparent,
          );
        }

        await tester.tap(find.byKey(const Key('sidebar-settings')));
        await settle();
        final settings = tester.element(
          find.byKey(const Key('sidebar-settings')),
        );
        await tester.runAsync(() async {
          final replacement = await File(
            '${temp.path}/background.png',
          ).copy('${temp.path}/replacement.png');
          await catalog.store.setBackgroundPath(replacement.path);
          await catalog.refresh();
        });
        await settle();
        expect(tester.element(background), same(element));
        expect(tester.widget<RawImage>(sharp).image, isNot(same(image)));
        expect(
          tester.element(find.byKey(const Key('sidebar-settings'))),
          same(settings),
        );
        tester.view.physicalSize = const Size(1600, 1200);
        tester.view.devicePixelRatio = 2;
        await settle();
        expect(tester.getRect(background), const Rect.fromLTWH(0, 0, 800, 600));
        await tester.runAsync(() async {
          await catalog.store.setBackgroundPath(null);
          await catalog.refresh();
        });
        await settle();
        expect(sharp, findsNothing);
        final scope = tester.widget<AppBackgroundScope>(
          find.byType(AppBackgroundScope),
        );
        expect(scope.hasBackground, isFalse);
        final theme = Theme.of(tester.element(find.byType(WindowTitleBar)));
        final original = brightness == Brightness.dark
            ? AppTheme.dark(glass: appearance.glassActive)
            : AppTheme.light(glass: appearance.glassActive);
        expect(theme.scaffoldBackgroundColor, original.scaffoldBackgroundColor);
        if (style == InterfaceStyle.glass && brightness == Brightness.dark) {
          expect(
            AppTheme.controlBarTheme(theme).glass.chromeSurface,
            GlassTokens.controlBarAcrylic.withValues(alpha: .10),
          );
        }
      });
    }
  }
}

class _Driver implements WindowAppearanceDriver {
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
    systemBackdropType: WindowBackdropType.systemAcrylic,
  );

  @override
  Future<WindowAppearanceCapabilities> queryCapabilities() async =>
      capabilities;

  @override
  Future<WindowAppearanceResult> apply(
    AppearanceConfig config,
    Brightness brightness,
  ) async => config.style == InterfaceStyle.glass
      ? const WindowAppearanceResult(
          requestedStyle: InterfaceStyle.glass,
          requestedMaterial: WindowMaterialPreference.automatic,
          capabilities: capabilities,
          actualBackdrop: WindowBackdropType.systemAcrylic,
        )
      : WindowAppearanceResult.classic(capabilities);
}
