import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:streampath/data/models/appearance_config.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/theme/appearance_controller.dart';
import 'package:streampath/presentation/widgets/window_title_bar.dart';

void main() {
  testWidgets('标题栏位于 Navigator 之上的 builder 中仍正常渲染且配色一致', (tester) async {
    final appearanceController = AppearanceController(
      initialConfig: const AppearanceConfig(),
      driver: _FakeDriver(),
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [ChangeNotifierProvider.value(value: appearanceController)],
        child: AnimatedBuilder(
          animation: appearanceController,
          builder: (context, child) {
            final appearance = appearanceController.config;
            final glass = appearanceController.glassActive;
            return MaterialApp(
              color: glass ? Colors.transparent : null,
              theme: AppTheme.dark(
                glass: glass,
                glassOpacity: appearance.glassOpacity,
              ),
              darkTheme: AppTheme.dark(
                glass: glass,
                glassOpacity: appearance.glassOpacity,
              ),
              builder: (context, navigator) => Overlay(
                initialEntries: [
                  OverlayEntry(
                    builder: (context) => Column(
                      children: [
                        const WindowTitleBar(),
                        Expanded(child: navigator ?? const SizedBox.shrink()),
                      ],
                    ),
                  ),
                ],
              ),
              home: child,
            );
          },
          child: Scaffold(
            appBar: AppBar(title: const Text('根目录')),
            body: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);

    final titleBarRect = tester.getRect(find.byType(WindowTitleBar));
    final appBarRect = tester.getRect(find.byType(AppBar));
    expect(titleBarRect.top, 0);
    expect(titleBarRect.height, WindowTitleBar.height);
    expect(appBarRect.top, WindowTitleBar.height);

    final titleBarMaterial = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(WindowTitleBar),
            matching: find.byType(Material),
          )
          .first,
    );
    final theme = Theme.of(tester.element(find.byType(WindowTitleBar)));
    expect(
      identical(theme, Theme.of(tester.element(find.byType(AppBar)))),
      isTrue,
    );
    expect(
      titleBarMaterial.color,
      Color.alphaBlend(
        theme.appBarTheme.backgroundColor!,
        theme.scaffoldBackgroundColor,
      ),
    );

    // 切换到磨砂玻璃：标题栏应等价合成 AppBar 与 Scaffold 的透明表面。
    await appearanceController.apply(
      const AppearanceConfig(style: InterfaceStyle.glass, glassOpacity: 0.6),
    );
    await tester.pumpAndSettle();

    final glassTitleBarMaterial = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(WindowTitleBar),
            matching: find.byType(Material),
          )
          .first,
    );
    final glassTheme = Theme.of(tester.element(find.byType(WindowTitleBar)));
    final glassAppBarMaterial = tester.widget<Material>(
      find
          .descendant(of: find.byType(AppBar), matching: find.byType(Material))
          .first,
    );
    expect(
      identical(glassTheme, Theme.of(tester.element(find.byType(AppBar)))),
      isTrue,
    );
    expect(
      glassTitleBarMaterial.color,
      Color.alphaBlend(
        glassAppBarMaterial.color!,
        glassTheme.scaffoldBackgroundColor,
      ),
    );
    expect(glassTitleBarMaterial.color!.a, lessThan(1));
  });
}

class _FakeDriver implements WindowAppearanceDriver {
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
  ) async => config.isGlass
      ? WindowAppearanceResult(
          requestedStyle: InterfaceStyle.glass,
          requestedMaterial: config.material,
          actualBackdrop: config.material == WindowMaterialPreference.acrylic
              ? WindowBackdropType.systemAcrylic
              : WindowBackdropType.mica,
          capabilities: capabilities,
        )
      : WindowAppearanceResult.classic(capabilities);
}
