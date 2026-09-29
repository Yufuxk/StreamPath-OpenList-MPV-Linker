import 'package:flutter/material.dart';

import '../../data/models/appearance_config.dart';
import 'glass_tokens.dart';
import 'page_transitions.dart';
import 'window_appearance_status.dart';

/// StreamPath 的轻量桌面主题。
abstract final class AppTheme {
  static const Color _seedColor = Color(0xFF3B6FE8);
  static const dropdownBorderRadius = BorderRadius.all(Radius.circular(8));

  static Color dropdownMenuColor(ThemeData theme) {
    final surface = theme.colorScheme.surfaceContainerLow;
    final glass = theme.glass;
    if (!glass.enabled) return surface.withValues(alpha: 1);
    // 下拉菜单没有背景模糊，浮层底色需遮住后面的文字。
    return Color.alphaBlend(
      surface.withValues(alpha: 0.96),
      glass.floatingSurface,
    );
  }

  static ThemeData light({
    bool glass = false,
    double glassOpacity = AppearanceConfig.defaultGlassOpacity,
    WindowBackdropType windowBackdrop = WindowBackdropType.systemAcrylic,
    String? fontFamily,
    Color? systemAccent,
  }) => _build(
    Brightness.light,
    glass: glass,
    glassOpacity: glassOpacity,
    windowBackdrop: windowBackdrop,
    fontFamily: fontFamily,
    systemAccent: systemAccent,
  );

  static ThemeData dark({
    bool glass = false,
    double glassOpacity = AppearanceConfig.defaultGlassOpacity,
    WindowBackdropType windowBackdrop = WindowBackdropType.systemAcrylic,
    String? fontFamily,
    Color? systemAccent,
  }) => _build(
    Brightness.dark,
    glass: glass,
    glassOpacity: glassOpacity,
    windowBackdrop: windowBackdrop,
    fontFamily: fontFamily,
    systemAccent: systemAccent,
  );

  static ThemeData _build(
    Brightness brightness, {
    required bool glass,
    required double glassOpacity,
    required WindowBackdropType windowBackdrop,
    required String? fontFamily,
    required Color? systemAccent,
  }) {
    final isDark = brightness == Brightness.dark;
    final generated = ColorScheme.fromSeed(
      seedColor: systemAccent ?? _seedColor,
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
    final glassSurfaceScheme = glass && isDark
        ? opaqueScheme.copyWith(
            surface: const Color(0xFF171D27),
            surfaceContainerLowest: const Color(0xFF0D131D),
            surfaceContainerLow: const Color(0xFF1B2430),
            surfaceContainer: const Color(0xFF202B38),
            surfaceContainerHigh: const Color(0xFF293544),
            surfaceContainerHighest: const Color(0xFF304052),
          )
        : opaqueScheme;
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
      glassSurfaceScheme,
      enabled: glass,
      opacityProgress: opacityProgress,
      material:
          windowBackdrop == WindowBackdropType.mica ||
              windowBackdrop == WindowBackdropType.tabbed
          ? GlassMaterial.mica
          : GlassMaterial.acrylic,
    );
    final scheme = glass
        ? glassSurfaceScheme.copyWith(
            surface: glassTokens.raisedSurface,
            surfaceContainerLowest: glassTokens.baseSurface,
            surfaceContainerLow: glassTokens.contentSurface,
            surfaceContainer: glassTokens.contentSurface,
            surfaceContainerHigh: glassTokens.raisedSurface,
            surfaceContainerHighest: glassTokens.floatingSurface,
            primaryContainer: isDark
                ? const Color(0xFF1E4D84)
                : opaqueScheme.primaryContainer,
          )
        : opaqueScheme;
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: fontFamily ?? 'Segoe UI',
      visualDensity: VisualDensity.standard,
      splashFactory: NoSplash.splashFactory,
      extensions: [glassTokens],
    );
    final desktopTextTheme = base.textTheme.copyWith(
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontSize: 24,
        height: 32 / 24,
        fontWeight: FontWeight.w600,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontSize: 16,
        height: 22 / 16,
        fontWeight: FontWeight.w600,
      ),
      titleSmall: base.textTheme.titleSmall?.copyWith(
        fontSize: 14,
        height: 20 / 14,
        fontWeight: FontWeight.w600,
      ),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(
        fontSize: 14,
        height: 20 / 14,
        fontWeight: FontWeight.w400,
      ),
      bodySmall: base.textTheme.bodySmall?.copyWith(
        fontSize: 12,
        height: 16 / 12,
        fontWeight: FontWeight.w400,
      ),
    );
    final controlBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(
        color: glass ? glassTokens.borderColor : scheme.outlineVariant,
      ),
    );

    return base.copyWith(
      textTheme: desktopTextTheme,
      scaffoldBackgroundColor: glassTokens.baseSurface,
      canvasColor: scheme.surface,
      hoverColor: scheme.primary.withValues(alpha: isDark ? 0.12 : 0.08),
      focusColor: scheme.primary.withValues(alpha: isDark ? 0.14 : 0.10),
      highlightColor: scheme.primary.withValues(alpha: isDark ? 0.10 : 0.07),
      splashColor: Colors.transparent,
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
        titleTextStyle: desktopTextTheme.titleLarge?.copyWith(
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
        fillColor: glass
            ? glassTokens.raisedSurface
            : glassTokens.contentSurface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
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
      segmentedButtonTheme: SegmentedButtonThemeData(
        style:
            SegmentedButton.styleFrom(
              selectedBackgroundColor: scheme.primaryContainer,
              selectedForegroundColor: scheme.onPrimaryContainer,
            ).copyWith(
              side: WidgetStateProperty.resolveWith(
                (states) => BorderSide(
                  color: states.contains(WidgetState.selected) && glass
                      ? scheme.primary.withValues(alpha: 0.34)
                      : glassTokens.borderColor,
                ),
              ),
            ),
      ),
      switchTheme: SwitchThemeData(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        splashRadius: 0,
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.onPrimary
              : scheme.onSurfaceVariant,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.surfaceContainerHighest,
        ),
        trackOutlineColor: WidgetStatePropertyAll(scheme.outlineVariant),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          side: BorderSide(color: scheme.outlineVariant),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          minimumSize: const Size(0, 36),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(36, 36),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ).copyWith(animationDuration: const Duration(milliseconds: 120)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: glassTokens.floatingSurface,
        surfaceTintColor: Colors.transparent,
        shadowColor: glassTokens.shadowColor,
        elevation: glass ? 6 : 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: glassTokens.borderColor),
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        interactive: true,
        radius: const Radius.circular(4),
        thickness: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered) ? 8 : 6,
        ),
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => scheme.onSurface.withValues(
            alpha:
                states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.dragged)
                ? 0.55
                : 0.35,
          ),
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
        backgroundColor: glass
            ? opaqueScheme.surfaceContainerHigh.withValues(
                alpha: isDark ? 0.94 : 0.96,
              )
            : scheme.surfaceContainerHigh,
        contentTextStyle: TextStyle(color: scheme.onSurface),
        elevation: glass ? 8 : 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: glass
                ? glassTokens.borderColor.withValues(alpha: 0.26)
                : scheme.outlineVariant,
          ),
        ),
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
