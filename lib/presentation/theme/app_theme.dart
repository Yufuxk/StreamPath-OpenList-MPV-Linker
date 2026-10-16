import 'package:flutter/material.dart';

import '../../data/models/appearance_config.dart';
import '../../data/models/accent_color_preset.dart';
import '../widgets/sp_back_icon.dart';
import 'glass_tokens.dart';
import 'page_transitions.dart';
import 'window_appearance_status.dart';
import 'accent_color_controller.dart';

/// StreamPath 的轻量桌面主题。
abstract final class AppTheme {
  static const Color _seedColor = Color(0xFF3B6FE8);
  static const controlRadius = BorderRadius.all(Radius.circular(10));
  static const panelRadius = BorderRadius.all(Radius.circular(16));
  static const pillRadius = BorderRadius.all(Radius.circular(999));
  static const dropdownBorderRadius = controlRadius;
  static const double controlHeight = 40;
  static const double controlGap = 12;
  static const double pageInset = 24;
  static const double controlBarMaxWidth = 1248;
  static const double videoCacheBlurSigma = 20;
  static const pagePadding = EdgeInsets.all(pageInset);
  static const hoverDuration = Duration(milliseconds: 200);
  static const double posterHoverScale = 1.05;
  static const double posterHoverLift = 6;

  static Color cinematicSurface(ThemeData theme) =>
      theme.brightness == Brightness.dark
      ? GlassTokens.surfaceDark.withValues(alpha: .45)
      : theme.glass.raisedSurface;

  static Color scrollEdgeColor(ThemeData theme) =>
      theme.brightness == Brightness.dark
      ? const Color(0xFF0B0B0E)
      : theme.colorScheme.surface;

  static List<BoxShadow> accentGlow(Color accent) => [
    BoxShadow(
      color: accent.withValues(alpha: 0.25),
      blurRadius: 12,
      spreadRadius: -2,
    ),
  ];

  static double controlHeightFor(BuildContext context) =>
      (MediaQuery.textScalerOf(context).scale(14) * 20 / 14 + 20).clamp(
        controlHeight,
        double.infinity,
      );

  /// 各主页面共用影视库的紧凑控制栏材质。
  static ThemeData controlBarTheme(ThemeData theme) {
    final glass = theme.glass;
    final plainAcrylic =
        glass.material == GlassMaterial.acrylic && !glass.hasCustomBackground;
    return theme.copyWith(
      extensions: theme.extensions.values.map(
        (extension) => extension is GlassTokens
            ? extension.copyWith(
                chromeSurface:
                    extension.enabled && theme.brightness == Brightness.dark
                    ? (plainAcrylic
                              ? GlassTokens.controlBarAcrylic
                              : GlassTokens.controlBarDark)
                          .withValues(
                            alpha:
                                (plainAcrylic ? 0.10 : 0.25) +
                                ((extension.baseSurface.a - 0.22) / 0.5).clamp(
                                      0.0,
                                      1.0,
                                    ) *
                                    0.10,
                          )
                    : extension.raisedSurface,
              )
            : extension,
      ),
      textTheme: theme.textTheme.copyWith(
        bodySmall: theme.textTheme.bodySmall?.copyWith(
          fontSize: 13,
          height: 20 / 13,
        ),
      ),
      inputDecorationTheme: theme.inputDecorationTheme.copyWith(
        fillColor: theme.glass.enabled
            ? theme.glass.raisedSurface
            : theme.glass.contentSurface,
      ),
    );
  }

  static Color dropdownMenuColor(ThemeData theme) {
    final surface = theme.colorScheme.surfaceContainerLow;
    final glass = theme.glass;
    if (!glass.enabled) return surface.withValues(alpha: 1);
    return glass.modalSurface;
  }

  static ThemeData videoCachePanelTheme(ThemeData theme) {
    final glass = theme.glass;
    if (!glass.enabled || theme.brightness != Brightness.dark) return theme;
    final surface = glass.modalSurface.withValues(alpha: .65);
    return theme.copyWith(
      extensions: theme.extensions.values.map(
        (extension) => extension is GlassTokens
            ? extension.copyWith(
                raisedSurface: surface,
                modalSurface: surface,
                modalBlurSigma: videoCacheBlurSigma,
              )
            : extension,
      ),
      dialogTheme: theme.dialogTheme.copyWith(backgroundColor: surface),
    );
  }

  static ThemeData light({
    bool glass = false,
    double glassOpacity = AppearanceConfig.defaultGlassOpacity,
    WindowBackdropType windowBackdrop = WindowBackdropType.systemAcrylic,
    String? fontFamily,
    Color? systemAccent,
    int accentColor = defaultAccentColor,
  }) => _build(
    Brightness.light,
    glass: glass,
    glassOpacity: glassOpacity,
    windowBackdrop: windowBackdrop,
    fontFamily: fontFamily,
    systemAccent: systemAccent,
    accentColor: accentColor,
  );

  static ThemeData dark({
    bool glass = false,
    double glassOpacity = AppearanceConfig.defaultGlassOpacity,
    WindowBackdropType windowBackdrop = WindowBackdropType.systemAcrylic,
    String? fontFamily,
    Color? systemAccent,
    int accentColor = defaultAccentColor,
  }) => _build(
    Brightness.dark,
    glass: glass,
    glassOpacity: glassOpacity,
    windowBackdrop: windowBackdrop,
    fontFamily: fontFamily,
    systemAccent: systemAccent,
    accentColor: accentColor,
  );

  static ThemeData _build(
    Brightness brightness, {
    required bool glass,
    required double glassOpacity,
    required WindowBackdropType windowBackdrop,
    required String? fontFamily,
    required Color? systemAccent,
    required int accentColor,
  }) {
    final isDark = brightness == Brightness.dark;
    final generated = ColorScheme.fromSeed(
      seedColor: systemAccent ?? _seedColor,
      brightness: brightness,
    );
    final accentScheme = AccentColorController.apply(
      generated,
      argb: accentColor,
      glass: glass,
    );
    final opaqueScheme = accentScheme.copyWith(
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
          ? Colors.white.withValues(alpha: 0.55)
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
            surface: GlassTokens.surfaceDark,
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
    final titleColor = isDark ? Colors.white : scheme.onSurface;
    final bodyColor = isDark
        ? Colors.white.withValues(alpha: 0.85)
        : scheme.onSurface;
    final description = scheme.onSurfaceVariant;
    final desktopTextTheme = base.textTheme.copyWith(
      displayLarge: base.textTheme.displayLarge?.copyWith(color: titleColor),
      displayMedium: base.textTheme.displayMedium?.copyWith(color: titleColor),
      displaySmall: base.textTheme.displaySmall?.copyWith(color: titleColor),
      headlineLarge: base.textTheme.headlineLarge?.copyWith(
        color: titleColor,
        fontWeight: FontWeight.w600,
      ),
      headlineMedium: base.textTheme.headlineMedium?.copyWith(
        color: titleColor,
        fontWeight: FontWeight.w600,
      ),
      headlineSmall: base.textTheme.headlineSmall?.copyWith(
        color: titleColor,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(
        color: bodyColor,
        fontWeight: FontWeight.w500,
        fontSize: 14,
        height: 20 / 14,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        color: titleColor,
        fontSize: 24,
        height: 32 / 24,
        fontWeight: FontWeight.w600,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        color: titleColor,
        fontSize: 18,
        height: 24 / 18,
        fontWeight: FontWeight.w600,
      ),
      titleSmall: base.textTheme.titleSmall?.copyWith(
        color: titleColor,
        fontSize: 14,
        height: 20 / 14,
        fontWeight: FontWeight.w600,
      ),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(
        color: bodyColor,
        fontSize: 14,
        height: 20 / 14,
        fontWeight: FontWeight.w500,
      ),
      bodySmall: base.textTheme.bodySmall?.copyWith(
        color: description,
        fontSize: 12,
        height: 16 / 12,
        fontWeight: FontWeight.w400,
      ),
      labelLarge: base.textTheme.labelLarge?.copyWith(
        color: bodyColor,
        fontWeight: FontWeight.w500,
      ),
      labelMedium: base.textTheme.labelMedium?.copyWith(
        color: bodyColor,
        fontWeight: FontWeight.w500,
      ),
      labelSmall: base.textTheme.labelSmall?.copyWith(
        color: description,
        fontWeight: FontWeight.w400,
      ),
    );
    final controlBorder = OutlineInputBorder(
      borderRadius: controlRadius,
      borderSide: BorderSide(color: glassTokens.borderColor),
    );

    return base.copyWith(
      actionIconTheme: ActionIconThemeData(
        backButtonIconBuilder: (_) => const SPBackIcon(),
      ),
      textTheme: desktopTextTheme,
      scaffoldBackgroundColor: glassTokens.baseSurface,
      canvasColor: scheme.surface,
      hoverColor: (isDark ? Colors.white : scheme.onSurface).withValues(
        alpha: 0.04,
      ),
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
        titleSpacing: pageInset,
        shape: Border(bottom: BorderSide(color: glassTokens.dividerColor)),
        titleTextStyle: desktopTextTheme.titleLarge?.copyWith(
          color: titleColor,
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
          borderRadius: panelRadius,
          side: BorderSide(color: glassTokens.panelBorderColor),
        ),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        isDense: true,
        filled: true,
        fillColor: glass
            ? glassTokens.raisedSurface
            : glassTokens.contentSurface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        constraints: const BoxConstraints(minHeight: controlHeight),
        prefixIconConstraints: const BoxConstraints(
          minWidth: 40,
          minHeight: 40,
        ),
        suffixIconConstraints: const BoxConstraints(
          minWidth: 40,
          minHeight: 40,
        ),
        hintStyle: desktopTextTheme.bodyMedium?.copyWith(color: description),
        labelStyle: desktopTextTheme.bodyMedium,
        helperStyle: desktopTextTheme.bodySmall,
        border: controlBorder,
        enabledBorder: controlBorder,
        disabledBorder: controlBorder,
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
              selectedBackgroundColor: scheme.primary,
              selectedForegroundColor: scheme.onPrimary,
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
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.transparent
              : scheme.outlineVariant,
        ),
        trackOutlineWidth: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? 0 : 1,
        ),
      ),
      progressIndicatorTheme: accentColor == defaultAccentColor
          ? const ProgressIndicatorThemeData()
          : ProgressIndicatorThemeData(
              linearTrackColor: scheme.primaryContainer,
              circularTrackColor: scheme.primaryContainer,
            ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          elevation: 2,
          shadowColor: scheme.primary.withValues(alpha: 0.25),
          minimumSize: const Size(0, controlHeight),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          shape: const RoundedRectangleBorder(borderRadius: controlRadius),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, controlHeight),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          side: BorderSide(color: glassTokens.borderColor),
          shape: const RoundedRectangleBorder(borderRadius: controlRadius),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: const RoundedRectangleBorder(borderRadius: controlRadius),
          minimumSize: const Size(0, controlHeight),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style:
            IconButton.styleFrom(
              minimumSize: const Size(36, 36),
              shape: const RoundedRectangleBorder(borderRadius: controlRadius),
            ).copyWith(
              animationDuration: hoverDuration,
              foregroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.disabled)
                    ? scheme.onSurface.withValues(alpha: 0.38)
                    : scheme.onSurface.withValues(
                        alpha:
                            states.contains(WidgetState.hovered) ||
                                states.contains(WidgetState.focused)
                            ? 1
                            : 0.6,
                      ),
              ),
            ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: glass ? Colors.transparent : glassTokens.floatingSurface,
        surfaceTintColor: Colors.transparent,
        shadowColor: glassTokens.shadowColor,
        elevation: glass ? 6 : 4,
        shape: RoundedRectangleBorder(
          borderRadius: controlRadius,
          side: BorderSide(color: glassTokens.borderColor),
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        interactive: true,
        radius: const Radius.circular(999),
        thickness: const WidgetStatePropertyAll(6),
        trackColor: const WidgetStatePropertyAll(Colors.transparent),
        trackBorderColor: const WidgetStatePropertyAll(Colors.transparent),
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => scheme.onSurface.withValues(
            alpha:
                states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.dragged)
                ? 0.30
                : 0.15,
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
          borderRadius: panelRadius,
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
