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
      // 蓝色预设统一使用深邃宝蓝：暗色主色仍满足白字与深色表面的可读性。
      return base.copyWith(
        primary: isDark ? const Color(0xFF2563EB) : const Color(0xFF1142B2),
        onPrimary: Colors.white,
        primaryContainer: isDark
            ? glass
                  ? const Color(0xFF1A4A8C)
                  : const Color(0xFF143A78)
            : const Color(0xFFDCE7FF),
        onPrimaryContainer: isDark
            ? const Color(0xFFD6E5FF)
            : const Color(0xFF0A2350),
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
