import 'package:flutter/material.dart';

import '../../data/models/accent_color_preset.dart';

/// 统一派生强调色；保存和通知沿用 AppearanceController。
abstract final class AccentColorController {
  static ColorScheme apply(
    ColorScheme base, {
    required int argb,
    required bool glass,
  }) {
    final isDark = base.brightness == Brightness.dark;
    final color = Color(argb);
    final generated = ColorScheme.fromSeed(
      seedColor: color,
      brightness: base.brightness,
      dynamicSchemeVariant: argb == AccentColorPreset.white.argb
          ? DynamicSchemeVariant.monochrome
          : DynamicSchemeVariant.tonalSpot,
    );
    if (argb == AccentColorPreset.blue.argb) {
      return base.copyWith(
        primary: isDark ? const Color(0xFF6EA8FE) : const Color(0xFF2F67D8),
        onPrimary: isDark ? const Color(0xFF071B34) : Colors.white,
        primaryContainer: isDark
            ? glass
                  ? const Color(0xFF1E4D84)
                  : const Color(0xFF17365F)
            : const Color(0xFFDFE9FF),
        onPrimaryContainer: isDark
            ? const Color(0xFFD8E7FF)
            : const Color(0xFF10284D),
        inversePrimary: generated.inversePrimary,
        primaryFixed: generated.primaryFixed,
        primaryFixedDim: generated.primaryFixedDim,
        onPrimaryFixed: generated.onPrimaryFixed,
        onPrimaryFixedVariant: generated.onPrimaryFixedVariant,
      );
    }
    // 浅色背景上的白色及深色背景上的暗色使用可辨识的派生色。
    final surface = isDark ? const Color(0xFF121922) : Colors.white;
    final primary = _contrast(color, surface) >= 4.5
        ? color
        : generated.primary;
    final onPrimary =
        _contrast(primary, Colors.black) >= _contrast(primary, Colors.white)
        ? Colors.black
        : Colors.white;
    return base.copyWith(
      primary: primary,
      onPrimary: onPrimary,
      primaryContainer: generated.primaryContainer,
      onPrimaryContainer: generated.onPrimaryContainer,
      inversePrimary: generated.inversePrimary,
      primaryFixed: generated.primaryFixed,
      primaryFixedDim: generated.primaryFixedDim,
      onPrimaryFixed: generated.onPrimaryFixed,
      onPrimaryFixedVariant: generated.onPrimaryFixedVariant,
    );
  }

  static double _contrast(Color first, Color second) {
    final a = first.computeLuminance();
    final b = second.computeLuminance();
    return a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
  }
}
