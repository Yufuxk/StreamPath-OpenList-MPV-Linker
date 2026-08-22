import 'package:flutter/material.dart';

import '../../data/models/appearance_config.dart';
import 'glass_tokens.dart';
import 'page_transitions.dart';
import 'window_appearance_status.dart';

/// StreamPath 的轻量桌面主题。
abstract final class AppTheme {
  static const Color _seedColor = Color(0xFF3B6FE8);

  static ThemeData light({
    bool glass = false,
    double glassOpacity = AppearanceConfig.defaultGlassOpacity,
    WindowBackdropType windowBackdrop = WindowBackdropType.systemAcrylic,
  }) => _build(
    Brightness.light,
    glass: glass,
    glassOpacity: glassOpacity,
    windowBackdrop: windowBackdrop,
  );

  static ThemeData dark({
    bool glass = false,
    double glassOpacity = AppearanceConfig.defaultGlassOpacity,
    WindowBackdropType windowBackdrop = WindowBackdropType.systemAcrylic,
  }) => _build(
    Brightness.dark,
    glass: glass,
    glassOpacity: glassOpacity,
    windowBackdrop: windowBackdrop,
  );

  static ThemeData _build(
    Brightness brightness, {
    required bool glass,
    required double glassOpacity,
    required WindowBackdropType windowBackdrop,
  }) {
    final isDark = brightness == Brightness.dark;
    final generated = ColorScheme.fromSeed(
      seedColor: _seedColor,
      brightness: brightness,
    );
    final opaqueScheme = generated.copyWith(
      primary: isDark ? const Color(0xFF6EA8FE) : const Color(0xFF2F67D8),
      onPrimary: isDark ? const Color(0xFF071B34) : const Color(0xFFFFFFFF),
      primaryContainer: isDark
          ? const Color(0xFF17365F)
          : const Color(0xFFDFE9FF),
      onPrimaryContainer: isDark
          ? const Color(0xFFD8E7FF)
          : const Color(0xFF10284D),
      secondary: isDark ? const Color(0xFF59C3BB) : const Color(0xFF237B75),
      onSecondary: isDark ? const Color(0xFF05201E) : const Color(0xFFFFFFFF),
      secondaryContainer: isDark
          ? const Color(0xFF123B38)
          : const Color(0xFFD0F1ED),
      onSecondaryContainer: isDark
          ? const Color(0xFFC6F0EC)
          : const Color(0xFF123733),
      tertiary: isDark ? const Color(0xFFE0B06C) : const Color(0xFF8C6326),
      onTertiary: isDark ? const Color(0xFF271704) : const Color(0xFFFFFFFF),
      tertiaryContainer: isDark
          ? const Color(0xFF453117)
          : const Color(0xFFF7E6C8),
      onTertiaryContainer: isDark
          ? const Color(0xFFFCE5BE)
          : const Color(0xFF3A290B),
      surface: isDark ? const Color(0xFF121922) : const Color(0xFFFFFFFF),
      onSurface: isDark ? const Color(0xFFE7EDF5) : const Color(0xFF17202C),
      onSurfaceVariant: isDark
          ? const Color(0xFFAEB9C7)
          : const Color(0xFF586576),
      surfaceContainerLowest: isDark
          ? const Color(0xFF0B1016)
          : const Color(0xFFF3F6FA),
      surfaceContainerLow: isDark
          ? const Color(0xFF161F29)
          : const Color(0xFFF7F9FC),
      surfaceContainer: isDark
          ? const Color(0xFF1A2530)
          : const Color(0xFFEEF2F7),
      surfaceContainerHigh: isDark
          ? const Color(0xFF202D3A)
          : const Color(0xFFE8EDF4),
      surfaceContainerHighest: isDark
          ? const Color(0xFF273544)
          : const Color(0xFFDFE6EF),
      outline: isDark ? const Color(0xFF708096) : const Color(0xFF738096),
      outlineVariant: isDark
          ? const Color(0xFF2B3949)
          : const Color(0xFFD8E0EA),
    );
    final opacity = glassOpacity
        .clamp(
          AppearanceConfig.minGlassOpacity,
          AppearanceConfig.maxGlassOpacity,
        )
        .toDouble();
    final opacityProgress =
        (opacity - AppearanceConfig.minGlassOpacity) /
        (AppearanceConfig.maxGlassOpacity - AppearanceConfig.minGlassOpacity);
    // 先定义最终视觉层级，再反推覆盖层透明度，避免嵌套半透明表面趋同。
    final glassTokens = GlassTokens.fromScheme(
      opaqueScheme,
      enabled: glass,
      opacityProgress: opacityProgress,
      material:
          windowBackdrop == WindowBackdropType.mica ||
              windowBackdrop == WindowBackdropType.tabbed
          ? GlassMaterial.mica
          : GlassMaterial.acrylic,
    );
    final scheme = glass
        ? opaqueScheme.copyWith(
            surface: glassTokens.raisedSurface,
            surfaceContainerLowest: glassTokens.baseSurface,
            surfaceContainerLow: glassTokens.contentSurface,
            surfaceContainer: glassTokens.contentSurface,
            surfaceContainerHigh: glassTokens.raisedSurface,
            surfaceContainerHighest: glassTokens.floatingSurface,
          )
        : opaqueScheme;
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      visualDensity: VisualDensity.standard,
      extensions: [glassTokens],
    );
    final controlBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: scheme.outlineVariant),
    );

    return base.copyWith(
      scaffoldBackgroundColor: glassTokens.baseSurface,
      canvasColor: scheme.surface,
      hoverColor: scheme.primary.withValues(alpha: isDark ? 0.12 : 0.08),
      focusColor: scheme.primary.withValues(alpha: isDark ? 0.14 : 0.10),
      highlightColor: scheme.primary.withValues(alpha: isDark ? 0.10 : 0.07),
      splashColor: scheme.primary.withValues(alpha: isDark ? 0.16 : 0.12),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {TargetPlatform.windows: StreamPathPageTransitionsBuilder()},
      ),
      appBarTheme: AppBarThemeData(
        backgroundColor: glassTokens.chromeSurface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: 64,
        titleSpacing: 20,
        shape: Border(bottom: BorderSide(color: glassTokens.dividerColor)),
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: glassTokens.raisedSurface,
        surfaceTintColor: Colors.transparent,
        shadowColor: glassTokens.shadowColor,
        elevation: glass ? 2 : 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: glassTokens.borderColor),
        ),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: glassTokens.contentSurface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 15,
        ),
        border: controlBorder,
        enabledBorder: controlBorder,
        focusedBorder: controlBorder.copyWith(
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        errorBorder: controlBorder.copyWith(
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: controlBorder.copyWith(
          borderSide: BorderSide(color: scheme.error, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          side: BorderSide(color: scheme.outlineVariant),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(40, 40),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: glassTokens.floatingSurface,
        surfaceTintColor: Colors.transparent,
        shadowColor: glassTokens.shadowColor,
        elevation: glass ? 6 : 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: glassTokens.borderColor),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: glassTokens.dividerColor,
        thickness: 1,
        space: 1,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: glassTokens.modalSurface,
        surfaceTintColor: Colors.transparent,
        shadowColor: glassTokens.modalShadowColor,
        elevation: glass ? glassTokens.modalElevation : 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: glassTokens.modalBorderColor),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(color: scheme.onInverseSurface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 450),
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: TextStyle(color: scheme.onInverseSurface, fontSize: 12),
      ),
    );
  }
}
