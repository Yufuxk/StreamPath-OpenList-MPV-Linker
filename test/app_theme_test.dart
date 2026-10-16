import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/theme/glass_tokens.dart';
import 'package:streampath/presentation/theme/page_transitions.dart';
import 'package:streampath/presentation/theme/window_appearance_status.dart';

void main() {
  test('缓存面板暗色玻璃使用65%底色和20px模糊，其他主题保持原值', () {
    for (final backdrop in [
      WindowBackdropType.systemAcrylic,
      WindowBackdropType.mica,
    ]) {
      final original = AppTheme.dark(glass: true, windowBackdrop: backdrop);
      final originalSurface = original.glass.modalSurface;
      final scoped = AppTheme.videoCachePanelTheme(original);
      expect(scoped.glass.raisedSurface.a, closeTo(.65, .001));
      expect(scoped.glass.modalSurface.a, closeTo(.65, .001));
      expect(scoped.dialogTheme.backgroundColor, scoped.glass.modalSurface);
      expect(scoped.glass.modalBlurSigma, 20);
      expect(scoped.glass.borderColor, original.glass.borderColor);
      expect(original.glass.modalSurface, originalSurface);
    }
    for (final original in [
      AppTheme.dark(),
      AppTheme.light(),
      AppTheme.light(glass: true),
    ]) {
      expect(AppTheme.videoCachePanelTheme(original), same(original));
    }
  });

  test('无背景 Acrylic 控制栏使用旧版灰色及10到20%，自定义背景保持原参数', () {
    for (final opacity in [0.60, 0.95]) {
      final theme = AppTheme.dark(glass: true, glassOpacity: opacity);
      final plain = AppTheme.controlBarTheme(theme).glass.chromeSurface;
      expect(plain.withValues(alpha: 1), GlassTokens.controlBarAcrylic);
      expect(plain.a, closeTo(opacity == 0.60 ? .10 : .20, .001));
      final custom = theme.copyWith(
        extensions: [theme.glass.copyWith(hasCustomBackground: true)],
      );
      final surface = AppTheme.controlBarTheme(custom).glass.chromeSurface;
      expect(surface.withValues(alpha: 1), GlassTokens.controlBarDark);
      expect(surface.a, closeTo(opacity == 0.60 ? .25 : .35, .001));
      final mica = AppTheme.dark(
        glass: true,
        glassOpacity: opacity,
        windowBackdrop: WindowBackdropType.mica,
      );
      expect(AppTheme.controlBarTheme(mica).glass.chromeSurface, surface);
    }
  });

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
      dark.colorScheme.primary,
    );
    expect(
      segmentedStyle.foregroundColor!.resolve({WidgetState.selected}),
      dark.colorScheme.onPrimary,
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
    expect(dark.onSurfaceVariant, Colors.white.withValues(alpha: 0.55));
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
    expect(clearerTokens.borderColor.a, closeTo(0.10, 0.001));
    expect(
      (clearerGlass.inputDecorationTheme.enabledBorder! as OutlineInputBorder)
          .borderSide
          .color,
      clearerTokens.borderColor,
    );
    expect(clearerGlass.colorScheme.primaryContainer, const Color(0xFF1E4D84));
    expect(clearerGlass.snackBarTheme.backgroundColor!.a, greaterThan(0.9));
    expect(
      AppTheme.dropdownMenuColor(clearerGlass),
      clearerTokens.modalSurface,
    );
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
