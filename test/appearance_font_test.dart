import 'package:streampath/presentation/widgets/sp_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/appearance_config.dart';
import 'package:streampath/presentation/theme/appearance_controller.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/film_certification_badge.dart';
import 'package:streampath/presentation/widgets/film_information_pill.dart';
import 'package:streampath/presentation/widgets/sp_font_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('界面字体随外观配置往返，旧配置沿用系统默认字体', () {
    const selected = AppearanceConfig(fontFamily: 'Microsoft YaHei UI');
    expect(
      AppearanceConfig.fromJson(selected.toJson()).fontFamily,
      'Microsoft YaHei UI',
    );
    expect(AppearanceConfig.fromJson({'style': 'classic'}).fontFamily, isNull);
    expect(AppTheme.light().textTheme.bodyMedium!.fontFamily, 'Segoe UI');
    expect(
      AppTheme.light(
        fontFamily: selected.fontFamily,
      ).textTheme.bodyMedium!.fontFamily,
      selected.fontFamily,
    );
  });

  testWidgets('只改界面字体不会重设窗口材质', (tester) async {
    final controller = AppearanceController(
      initialConfig: AppearanceConfig.defaults(),
      driver: _UnusedDriver(),
    );
    addTearDown(controller.dispose);

    expect(
      await controller.apply(
        const AppearanceConfig(fontFamily: 'Microsoft YaHei UI'),
      ),
      isTrue,
    );
    expect(controller.config.fontFamily, 'Microsoft YaHei UI');
  });

  testWidgets('启动时恢复旧 GDI 字样对应的 DirectWrite 字体族', (tester) async {
    const channel = MethodChannel('streampath/appearance');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'resolveFontFamily');
      expect(call.arguments, '苹方 常规');
      return 'PingFang SC';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final controller = AppearanceController(
      initialConfig: const AppearanceConfig(fontFamily: '苹方 常规'),
      driver: _UnusedDriver(),
    );
    addTearDown(controller.dispose);

    expect(await controller.restoreForStartup(), isTrue);
    expect(controller.config.fontFamily, 'PingFang SC');
  });

  testWidgets('公共字体切换覆盖正文、提示和影视胶囊，分级徽标字体保持独立', (tester) async {
    Widget app(ThemeData theme) => MaterialApp(
      theme: theme,
      home: const Scaffold(
        body: Column(
          children: [
            Text('公共正文'),
            FilmInformationPill(foreground: Colors.white, child: Text('剧情')),
            FilmCertificationBadge(rating: 'TV-14'),
          ],
        ),
      ),
    );
    TextStyle renderedStyle(String text) =>
        tester.renderObject<RenderParagraph>(find.text(text)).text.style!;

    for (final brightness in Brightness.values) {
      final theme = brightness == Brightness.dark
          ? AppTheme.dark
          : AppTheme.light;
      await tester.pumpWidget(app(theme()));
      await tester.pumpAndSettle();
      final pill = renderedStyle('剧情');
      final badge = renderedStyle('TV-14');
      expect(renderedStyle('公共正文').fontFamily, 'Segoe UI');
      expect(pill.fontFamily, 'Segoe UI');

      final custom = theme(fontFamily: 'PingFang SC');
      await tester.pumpWidget(app(custom));
      await tester.pumpAndSettle();
      expect(renderedStyle('公共正文').fontFamily, 'PingFang SC');
      expect(custom.snackBarTheme.contentTextStyle!.fontFamily, 'PingFang SC');
      expect(renderedStyle('剧情'), pill.copyWith(fontFamily: 'PingFang SC'));
      expect(renderedStyle('TV-14'), badge);
    }
  });

  testWidgets('展开字体选择栏可选系统已安装字体', (tester) async {
    const channel = MethodChannel('streampath/appearance');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getInstalledFonts');
      return ['Segoe UI', 'Microsoft YaHei UI'];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    String? chosen;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SPFontPicker(
            selectedFamily: null,
            onChanged: (value) => chosen = value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('interface-font-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Microsoft YaHei UI').last);
    await tester.pumpAndSettle();
    expect(chosen, 'Microsoft YaHei UI');
    final selector = tester.widget<SPDropdownButtonFormField<String>>(
      find.byKey(const Key('interface-font-selector')),
    );
    expect(selector.focusNode!.hasFocus, isFalse);

    await tester.tap(find.byKey(const Key('interface-font-selector')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(700, 500));
    await tester.pumpAndSettle();
    expect(
      tester.widget<InputDecorator>(find.byType(InputDecorator)).isFocused,
      isFalse,
    );
  });
}

class _UnusedDriver implements WindowAppearanceDriver {
  @override
  Future<WindowAppearanceResult> apply(
    AppearanceConfig config,
    Brightness brightness,
  ) => throw StateError('字体变更不应调用窗口接口');

  @override
  Future<WindowAppearanceCapabilities> queryCapabilities() =>
      throw StateError('字体变更不应查询窗口能力');
}
