import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/accent_color_preset.dart';
import 'package:streampath/data/models/appearance_config.dart';
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/theme/appearance_controller.dart';
import 'package:streampath/presentation/widgets/film_segmented_control.dart';
import 'package:streampath/presentation/widgets/sp_controls.dart';

double contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return x > y ? (x + .05) / (y + .05) : (y + .05) / (x + .05);
}

void main() {
  test('旧配置、非法值与新增预设使用稳定的颜色值存储', () {
    expect(AppearanceConfig.fromJson({}).accentColor, defaultAccentColor);
    for (final value in [null, 'white', -1, 0xFFFFFFFFF, 0x003B6FE8]) {
      expect(
        AppearanceConfig.fromJson({'accentColor': value}).accentColor,
        defaultAccentColor,
      );
    }
    for (final argb in [
      ...AccentColorPreset.values.map((preset) => preset.argb),
      0xFF35AC76,
    ]) {
      final config = StreamPathConfig(
        appearance: AppearanceConfig(accentColor: argb),
      );
      final restored = StreamPathConfig.fromJson(config.toJson());
      expect(restored.appearance.accentColor, argb);
      expect(
        restored.appearance.copyWith(sidebarCompact: true).accentColor,
        argb,
      );
      expect(restored.copyWithParts().appearance.accentColor, argb);
    }
  });

  test('白色在明暗及各材质下保持中性、按钮前景与可读性', () {
    for (final dark in [false, true]) {
      for (final backdrop in [
        WindowBackdropType.none,
        WindowBackdropType.systemAcrylic,
        WindowBackdropType.mica,
      ]) {
        final theme = dark
            ? AppTheme.dark(
                accentColor: 0xFFFFFFFF,
                glass: backdrop != WindowBackdropType.none,
                windowBackdrop: backdrop,
                systemAccent: Colors.orange,
              )
            : AppTheme.light(
                accentColor: 0xFFFFFFFF,
                glass: backdrop != WindowBackdropType.none,
                windowBackdrop: backdrop,
                systemAccent: Colors.orange,
              );
        final scheme = theme.colorScheme;
        expect(scheme.primary.r, scheme.primary.g);
        expect(scheme.primary.g, scheme.primary.b);
        expect(scheme.primaryContainer.r, scheme.primaryContainer.g);
        expect(
          contrast(scheme.primary, scheme.onPrimary),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(
            scheme.primary,
            dark ? const Color(0xFF121922) : Colors.white,
          ),
          greaterThanOrEqualTo(4.5),
        );
        if (dark) {
          expect(scheme.primary, Colors.white);
          expect(scheme.onPrimary, Colors.black);
        }
        expect(
          theme.switchTheme.trackColor!.resolve({WidgetState.selected}),
          scheme.primary,
        );
        expect(
          theme.progressIndicatorTheme.linearTrackColor,
          scheme.primaryContainer,
        );
        expect(
          theme.segmentedButtonTheme.style!.foregroundColor!.resolve({
            WidgetState.selected,
          }),
          scheme.onPrimary,
        );
      }
    }
  });

  test('任意颜色复用强调色派生，表面与错误色保持', () {
    for (final argb in [
      ...AccentColorPreset.values
          .where((preset) => preset != AccentColorPreset.blue)
          .map((preset) => preset.argb),
      0xFF35AC76,
      0xFFAB236F,
      0xFF000000,
    ]) {
      final base = AppTheme.dark();
      final selected = AppTheme.dark(accentColor: argb);
      expect(selected.colorScheme.primary, isNot(base.colorScheme.primary));
      expect(selected.colorScheme.surface, base.colorScheme.surface);
      expect(selected.colorScheme.error, base.colorScheme.error);
      expect(
        contrast(selected.colorScheme.primary, selected.colorScheme.onPrimary),
        greaterThanOrEqualTo(4.5),
      );
    }
  });

  test('预设和相关设置文案覆盖四语言', () {
    for (final language in AppLanguage.values) {
      final l10n = AppLocalizations(language);
      for (final text in [
        '强调色',
        '自定义颜色',
        ...AccentColorPreset.values.map((p) => p.label),
      ]) {
        expect(l10n.text(text), isNotEmpty);
        if (language == AppLanguage.english ||
            language == AppLanguage.japanese) {
          expect(l10n.text(text), isNot(text));
        }
      }
    }
  });

  testWidgets('仅更改强调色通知主题且不调用原生材质接口', (tester) async {
    final driver = _Driver();
    final controller = AppearanceController(
      initialConfig: AppearanceConfig.defaults(),
      driver: driver,
    );
    addTearDown(controller.dispose);
    var notices = 0;
    controller.addListener(() => notices++);
    expect(
      await controller.apply(const AppearanceConfig(accentColor: 0xFFFFFFFF)),
      isTrue,
    );
    expect(controller.config.accentColor, 0xFFFFFFFF);
    expect(notices, 1);
    expect(driver.calls, 0);
    driver.fail = true;
    expect(
      await controller.apply(
        const AppearanceConfig(
          style: InterfaceStyle.glass,
          accentColor: 0xFF35AC76,
        ),
      ),
      isFalse,
    );
    expect(controller.config.accentColor, 0xFFFFFFFF);
  });

  testWidgets('材质恢复失败仍保留所选强调色', (tester) async {
    final controller = AppearanceController(
      initialConfig: const AppearanceConfig(
        style: InterfaceStyle.glass,
        accentColor: 0xFFFFFFFF,
      ),
      driver: _Driver()..fail = true,
    );
    addTearDown(controller.dispose);
    expect(await controller.restoreForStartup(), isFalse);
    expect(controller.config.style, InterfaceStyle.classic);
    expect(controller.config.accentColor, 0xFFFFFFFF);
  });

  testWidgets('主按钮、分段选择与开关共用所选强调色', (tester) async {
    if (Platform.environment['SP_ACCENT_RENDER'] == '1') {
      await tester.runAsync(() async {
        final loader = FontLoader('AccentPreviewFont')
          ..addFont(
            Future.value(
              ByteData.sublistView(
                await File(r'C:\Windows\Fonts\msyh.ttc').readAsBytes(),
              ),
            ),
          );
        await loader.load();
      });
    }
    tester.view.physicalSize = const Size(720, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final dark in [true, false]) {
      for (final preset in AccentColorPreset.values) {
        final theme = dark
            ? AppTheme.dark(
                accentColor: preset.argb,
                fontFamily: 'AccentPreviewFont',
              )
            : AppTheme.light(
                accentColor: preset.argb,
                fontFamily: 'AccentPreviewFont',
              );
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: RepaintBoundary(
              key: const Key('accent-preview'),
              child: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'StreamPath · ${preset.name}',
                        style: theme.textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 24),
                      SPButton(
                        label: const Text('开始播放'),
                        kind: SPButtonKind.primary,
                        onPressed: () {},
                      ),
                      const SizedBox(height: 24),
                      FilmSegmentedControl<int>(
                        selected: 0,
                        segments: const [
                          ButtonSegment(
                            value: 0,
                            label: Text(
                              '每日精选',
                              style: TextStyle(fontFamily: 'AccentPreviewFont'),
                            ),
                          ),
                          ButtonSegment(
                            value: 1,
                            label: Text(
                              '合集',
                              style: TextStyle(fontFamily: 'AccentPreviewFont'),
                            ),
                          ),
                        ],
                        onSelectionChanged: (_) {},
                      ),
                      const SizedBox(height: 24),
                      SwitchListTile(
                        title: const Text('播放设置'),
                        value: true,
                        onChanged: (_) {},
                      ),
                      LinearProgressIndicator(value: .6),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final button = tester.widget<FilledButton>(find.byType(FilledButton));
        expect(
          button.style!.backgroundColor!.resolve({}),
          theme.colorScheme.primary,
        );
        expect(
          button.style!.foregroundColor!.resolve({}),
          theme.colorScheme.onPrimary,
        );
        expect(tester.takeException(), isNull);
        if (Platform.environment['SP_ACCENT_RENDER'] == '1') {
          await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const Key('accent-preview')),
            );
            final picture = await boundary.toImage();
            final bytes = await picture.toByteData(
              format: ui.ImageByteFormat.png,
            );
            picture.dispose();
            final file = File(
              'build/accent-color/preview-${dark ? 'dark' : 'light'}-${preset.name}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
          });
        }
      }
    }
  });
}

class _Driver implements WindowAppearanceDriver {
  int calls = 0;
  bool fail = false;
  @override
  Future<WindowAppearanceResult> apply(
    AppearanceConfig config,
    Brightness brightness,
  ) async {
    calls++;
    if (fail) throw StateError('Synthetic material failure');
    return WindowAppearanceResult.classic(
      const WindowAppearanceCapabilities.unsupported(),
    );
  }

  @override
  Future<WindowAppearanceCapabilities> queryCapabilities() async =>
      const WindowAppearanceCapabilities.unsupported();
}
