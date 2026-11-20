import 'package:flutter/material.dart';

/// 影视背景上的共享文字样式。
abstract final class FilmTextStyles {
  static TextStyle metadata(ThemeData theme, TextStyle style) =>
      theme.brightness == Brightness.dark
      ? style.copyWith(
          fontFamily: 'Sarasa UI SC',
          fontFamilyFallback: [?style.fontFamily, ...?style.fontFamilyFallback],
          fontWeight: FontWeight.w400,
          fontFeatures: const [FontFeature.tabularFigures()],
        )
      : style;

  // 沿自适应黑白过渡淡化白字，保留纯黑前景的对比度。
  static Color adaptiveTone(ThemeData theme, Color foreground, Color tone) =>
      theme.brightness == Brightness.dark
      ? foreground.withValues(alpha: 1 - foreground.r * (1 - tone.a))
      : foreground;

  static const shadows = [
    Shadow(color: Color(0xCC000000), offset: Offset(0, 1), blurRadius: 3),
    Shadow(color: Color(0x80000000), offset: Offset(0, 2), blurRadius: 8),
  ];

  static const overviewMaxWidth = 620.0;
  static final overview = TextStyle(
    fontSize: 15,
    height: 1.75,
    color: Colors.white.withValues(alpha: .82),
    shadows: shadows,
  );
}
