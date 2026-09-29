import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/appearance_config.dart';
import 'package:streampath/presentation/theme/appearance_controller.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
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
    final selector = tester.widget<DropdownButton<String>>(
      find.byKey(const Key('interface-font-selector')),
    );
    expect(selector.focusColor, Colors.transparent);
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
