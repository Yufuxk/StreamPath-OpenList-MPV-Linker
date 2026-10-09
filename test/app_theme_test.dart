import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/theme/glass_tokens.dart';
import 'package:streampath/presentation/theme/page_transitions.dart';
import 'package:streampath/presentation/theme/window_appearance_status.dart';

void main() {
  test('亮暗主题保持桌面视觉与低渲染成本约束', () {
    final light = AppTheme.light();
    final dark = AppTheme.dark();

    expect(light.brightness, Brightness.light);
    expect(dark.brightness, Brightness.dark);
    expect(light.cardTheme.elevation, 0);
    expect(dark.cardTheme.elevation, 0);
    expect(light.cardTheme.shadowColor, Colors.transparent);
    expect(dark.cardTheme.shadowColor, Colors.transparent);
    expect(light.scaffoldBackgroundColor, isNot(light.colorScheme.surface));
    expect(dark.scaffoldBackgroundColor, isNot(dark.colorScheme.surface));
    expect(dark.colorScheme.surface, const Color(0xFF121922));
    expect(dark.colorScheme.primary, const Color(0xFF6EA8FE));
    expect(dark.colorScheme.secondary, const Color(0xFF59C3BB));
    expect(dark.colorScheme.tertiary, const Color(0xFFE0B06C));
    final segmentedStyle = dark.segmentedButtonTheme.style!;
    expect(
      segmentedStyle.backgroundColor!.resolve({WidgetState.selected}),
      dark.colorScheme.primaryContainer,
    );
    expect(
      segmentedStyle.foregroundColor!.resolve({WidgetState.selected}),
      dark.colorScheme.onPrimaryContainer,
    );
    expect(dark.hoverColor.a, greaterThan(0));
    expect(
      dark.pageTransitionsTheme.builders[TargetPlatform.windows],
      isA<StreamPathPageTransitionsBuilder>(),
    );
  });

  test('系统强调色不改变旧版按钮与图标主配色', () {
    const accent = Color(0xFFAA5500);
    final light = AppTheme.light(systemAccent: accent).colorScheme;
    final dark = AppTheme.dark(systemAccent: accent).colorScheme;

    expect(light.primary, const Color(0xFF2F67D8));
    expect(light.onPrimary, Colors.white);
    expect(light.primaryContainer, const Color(0xFFDFE9FF));
    expect(dark.primary, const Color(0xFF6EA8FE));
    expect(dark.onPrimary, const Color(0xFF071B34));
    expect(dark.primaryContainer, const Color(0xFF17365F));
    expect(dark.onPrimaryContainer, const Color(0xFFD8E7FF));
    expect(dark.onSurfaceVariant, const Color(0xFFAEB9C7));
  });

  test('磨砂主题保持主背景控制并建立可区分的表面层级', () {
    final defaultDark = AppTheme.dark();
    final clearerGlass = AppTheme.dark(glass: true, glassOpacity: 0.60);
    final denserGlass = AppTheme.dark(glass: true, glassOpacity: 0.95);

    expect(defaultDark.scaffoldBackgroundColor.a, 1);
    expect(clearerGlass.scaffoldBackgroundColor.a, closeTo(0.22, 0.01));
    expect(
      clearerGlass.scaffoldBackgroundColor.toARGB32() & 0x00FFFFFF,
      0x000D131D,
    );
    expect(denserGlass.scaffoldBackgroundColor.a, closeTo(0.72, 0.01));
    expect(
      denserGlass.scaffoldBackgroundColor.a -
          clearerGlass.scaffoldBackgroundColor.a,
      greaterThanOrEqualTo(0.49),
    );
    expect(clearerGlass.colorScheme.onSurface.a, 1);
    expect(clearerGlass.cardTheme.elevation, greaterThan(0));
    expect(clearerGlass.cardTheme.shadowColor, isNot(Colors.transparent));
    final clearerTokens = clearerGlass.extension<GlassTokens>()!;
    final base = clearerTokens.baseSurface;
    final content = Color.alphaBlend(clearerTokens.contentSurface, base);
    final raised = Color.alphaBlend(clearerTokens.raisedSurface, base);
    final floating = Color.alphaBlend(clearerTokens.floatingSurface, base);
    expect(content.a, greaterThan(base.a));
    expect(raised.a, greaterThan(content.a));
    expect(floating.a, greaterThan(raised.a));
    expect(
      clearerGlass.appBarTheme.backgroundColor,
      clearerTokens.chromeSurface,
    );
    expect(clearerTokens.borderColor.a, greaterThan(0.12));
    expect(
      (clearerGlass.inputDecorationTheme.enabledBorder! as OutlineInputBorder)
          .borderSide
          .color,
      clearerTokens.borderColor,
    );
    expect(clearerGlass.colorScheme.primaryContainer, const Color(0xFF1E4D84));
    expect(clearerGlass.snackBarTheme.backgroundColor!.a, greaterThan(0.9));
    expect(AppTheme.dropdownMenuColor(clearerGlass), clearerTokens.modalSurface);
    expect(
      (clearerGlass.snackBarTheme.shape! as RoundedRectangleBorder)
          .side
          .color
          .a,
      greaterThan(0.2),
    );
  });

  test('Acrylic 与 Mica 使用独立的模态层材质', () {
    final acrylic = AppTheme.dark(
      glass: true,
      windowBackdrop: WindowBackdropType.systemAcrylic,
    );
    final mica = AppTheme.dark(
      glass: true,
      windowBackdrop: WindowBackdropType.mica,
    );
    final acrylicTokens = acrylic.extension<GlassTokens>()!;
    final micaTokens = mica.extension<GlassTokens>()!;

    expect(acrylicTokens.material, GlassMaterial.acrylic);
    expect(micaTokens.material, GlassMaterial.mica);
    expect(
      acrylicTokens.modalBlurSigma,
      greaterThan(micaTokens.modalBlurSigma),
    );
    expect(acrylicTokens.modalSurface.a, lessThan(micaTokens.modalSurface.a));
    expect(
      acrylicTokens.modalElevation,
      greaterThan(micaTokens.modalElevation),
    );
    expect(
      acrylicTokens.modalShadowColor.a,
      greaterThan(micaTokens.modalShadowColor.a),
    );
    expect(acrylicTokens.modalBorderColor.a, lessThan(0.10));
    expect(micaTokens.modalBorderColor.a, lessThan(0.07));
    expect(acrylic.dialogTheme.backgroundColor, acrylicTokens.modalSurface);
    expect(mica.dialogTheme.backgroundColor, micaTokens.modalSurface);
    expect(acrylic.dialogTheme.elevation, acrylicTokens.modalElevation);
    expect(mica.dialogTheme.elevation, micaTokens.modalElevation);
  });
}
