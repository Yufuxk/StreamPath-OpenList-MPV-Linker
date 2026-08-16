import 'package:flutter/material.dart';

/// 玻璃表面的视觉层级。
enum GlassSurfaceLevel { base, chrome, content, raised, floating }

/// 玻璃界面的表现层参数，不承载窗口或业务状态。
@immutable
class GlassTokens extends ThemeExtension<GlassTokens> {
  const GlassTokens({
    required this.enabled,
    required this.baseSurface,
    required this.chromeSurface,
    required this.contentSurface,
    required this.raisedSurface,
    required this.floatingSurface,
    required this.borderColor,
    required this.dividerColor,
    required this.innerHighlight,
    required this.shadowColor,
    required this.modalBlurSigma,
  });

  factory GlassTokens.fromScheme(
    ColorScheme scheme, {
    required bool enabled,
    required double opacityProgress,
  }) {
    if (!enabled) {
      return GlassTokens(
        enabled: false,
        baseSurface: scheme.surfaceContainerLowest,
        chromeSurface: scheme.surface,
        contentSurface: scheme.surfaceContainerLow,
        raisedSurface: scheme.surface,
        floatingSurface: scheme.surface,
        borderColor: scheme.outlineVariant,
        dividerColor: scheme.outlineVariant,
        innerHighlight: Colors.transparent,
        shadowColor: Colors.transparent,
        modalBlurSigma: 0,
      );
    }

    final isDark = scheme.brightness == Brightness.dark;
    final progress = opacityProgress.clamp(0.0, 1.0).toDouble();
    final baseTarget = _mix(0.22, 0.72, progress);
    final contentTarget = (baseTarget + 0.10).clamp(0.0, 0.78);
    final chromeTarget = (baseTarget + 0.16).clamp(0.0, 0.84);
    final raisedTarget = (baseTarget + 0.24).clamp(0.0, 0.88);
    final floatingTarget = (baseTarget + 0.38).clamp(0.0, 0.94);

    return GlassTokens(
      enabled: true,
      baseSurface: scheme.surfaceContainerLowest.withValues(alpha: baseTarget),
      chromeSurface: scheme.surface.withValues(
        alpha: _overlayAlpha(baseTarget, chromeTarget),
      ),
      contentSurface: scheme.surfaceContainerLow.withValues(
        alpha: _overlayAlpha(baseTarget, contentTarget),
      ),
      raisedSurface: scheme.surface.withValues(
        alpha: _overlayAlpha(baseTarget, raisedTarget),
      ),
      floatingSurface: scheme.surface.withValues(
        alpha: _overlayAlpha(baseTarget, floatingTarget),
      ),
      borderColor: isDark
          ? Colors.white.withValues(alpha: 0.12)
          : const Color(0xFF506078).withValues(alpha: 0.18),
      dividerColor: isDark
          ? Colors.white.withValues(alpha: 0.09)
          : const Color(0xFF506078).withValues(alpha: 0.14),
      innerHighlight: Colors.white.withValues(alpha: isDark ? 0.05 : 0.18),
      shadowColor: Colors.black.withValues(alpha: isDark ? 0.12 : 0.06),
      modalBlurSigma: 12,
    );
  }

  final bool enabled;
  final Color baseSurface;
  final Color chromeSurface;
  final Color contentSurface;
  final Color raisedSurface;
  final Color floatingSurface;
  final Color borderColor;
  final Color dividerColor;
  final Color innerHighlight;
  final Color shadowColor;
  final double modalBlurSigma;

  Color surfaceFor(GlassSurfaceLevel level) => switch (level) {
    GlassSurfaceLevel.base => baseSurface,
    GlassSurfaceLevel.chrome => chromeSurface,
    GlassSurfaceLevel.content => contentSurface,
    GlassSurfaceLevel.raised => raisedSurface,
    GlassSurfaceLevel.floating => floatingSurface,
  };

  List<BoxShadow> shadowsFor(GlassSurfaceLevel level) {
    if (!enabled) return const [];
    return switch (level) {
      GlassSurfaceLevel.raised => [
        BoxShadow(
          color: shadowColor,
          blurRadius: 16,
          spreadRadius: -6,
          offset: const Offset(0, 4),
        ),
      ],
      GlassSurfaceLevel.floating => [
        BoxShadow(
          color: shadowColor,
          blurRadius: 28,
          spreadRadius: -8,
          offset: const Offset(0, 8),
        ),
      ],
      _ => const [],
    };
  }

  @override
  GlassTokens copyWith({
    bool? enabled,
    Color? baseSurface,
    Color? chromeSurface,
    Color? contentSurface,
    Color? raisedSurface,
    Color? floatingSurface,
    Color? borderColor,
    Color? dividerColor,
    Color? innerHighlight,
    Color? shadowColor,
    double? modalBlurSigma,
  }) => GlassTokens(
    enabled: enabled ?? this.enabled,
    baseSurface: baseSurface ?? this.baseSurface,
    chromeSurface: chromeSurface ?? this.chromeSurface,
    contentSurface: contentSurface ?? this.contentSurface,
    raisedSurface: raisedSurface ?? this.raisedSurface,
    floatingSurface: floatingSurface ?? this.floatingSurface,
    borderColor: borderColor ?? this.borderColor,
    dividerColor: dividerColor ?? this.dividerColor,
    innerHighlight: innerHighlight ?? this.innerHighlight,
    shadowColor: shadowColor ?? this.shadowColor,
    modalBlurSigma: modalBlurSigma ?? this.modalBlurSigma,
  );

  @override
  GlassTokens lerp(covariant GlassTokens? other, double t) {
    if (other == null) return this;
    return GlassTokens(
      enabled: t < 0.5 ? enabled : other.enabled,
      baseSurface: Color.lerp(baseSurface, other.baseSurface, t)!,
      chromeSurface: Color.lerp(chromeSurface, other.chromeSurface, t)!,
      contentSurface: Color.lerp(contentSurface, other.contentSurface, t)!,
      raisedSurface: Color.lerp(raisedSurface, other.raisedSurface, t)!,
      floatingSurface: Color.lerp(floatingSurface, other.floatingSurface, t)!,
      borderColor: Color.lerp(borderColor, other.borderColor, t)!,
      dividerColor: Color.lerp(dividerColor, other.dividerColor, t)!,
      innerHighlight: Color.lerp(innerHighlight, other.innerHighlight, t)!,
      shadowColor: Color.lerp(shadowColor, other.shadowColor, t)!,
      modalBlurSigma: _mix(modalBlurSigma, other.modalBlurSigma, t),
    );
  }

  static double _mix(double start, double end, double t) =>
      start + (end - start) * t;

  static double _overlayAlpha(double background, double target) {
    if (background >= 1) return 1;
    return ((target - background) / (1 - background)).clamp(0.0, 1.0);
  }
}

/// 获取当前主题的玻璃层级参数。
extension GlassThemeData on ThemeData {
  GlassTokens get glass =>
      extension<GlassTokens>() ??
      GlassTokens.fromScheme(colorScheme, enabled: false, opacityProgress: 1);
}
