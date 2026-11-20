import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 影视背景上的共享文字样式。
abstract final class FilmTextStyles {
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

  static ButtonStyle? overviewAction(BuildContext context) {
    if (Theme.of(context).brightness != Brightness.dark) return null;
    return ButtonStyle(
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return null;
        final active =
            states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.pressed) ||
            states.contains(WidgetState.focused);
        return active ? const Color(0xE6FFFFFF) : const Color(0x80FFFFFF);
      }),
      animationDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : AppTheme.hoverDuration,
    );
  }
}
