import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/theme/glass_tokens.dart';
import 'package:streampath/presentation/theme/page_transitions.dart';

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
    expect(dark.hoverColor.a, greaterThan(0));
    expect(
      dark.pageTransitionsTheme.builders[TargetPlatform.windows],
      isA<StreamPathPageTransitionsBuilder>(),
    );
  });

  test('磨砂主题保持主背景控制并建立可区分的表面层级', () {
    final defaultDark = AppTheme.dark();
    final clearerGlass = AppTheme.dark(glass: true, glassOpacity: 0.60);
    final denserGlass = AppTheme.dark(glass: true, glassOpacity: 0.95);

    expect(defaultDark.scaffoldBackgroundColor.a, 1);
    expect(clearerGlass.scaffoldBackgroundColor.a, closeTo(0.22, 0.01));
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
  });
}
