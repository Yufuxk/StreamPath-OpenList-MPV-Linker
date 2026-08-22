import 'package:flutter/material.dart';

/// 玻璃表面的视觉层级。
enum GlassSurfaceLevel { base, chrome, content, raised, floating }

/// 当前玻璃主题实际采用的窗口材质。
enum GlassMaterial { acrylic, mica }

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
    required this.material,
    required this.modalSurface,
    required this.modalBorderColor,
    required this.modalShadowColor,
    required this.modalBarrierColor,
    required this.modalBlurSigma,
    required this.modalElevation,
    required this.modalScaleBegin,
    required this.modalSlideOffset,
  });

  factory GlassTokens.fromScheme(
    ColorScheme scheme, {
    required bool enabled,
    required double opacityProgress,
    GlassMaterial material = GlassMaterial.acrylic,
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
        material: material,
        modalSurface: scheme.surface,
        modalBorderColor: scheme.outlineVariant,
        modalShadowColor: Colors.black.withValues(alpha: 0.24),
        modalBarrierColor: Colors.black.withValues(alpha: 0.32),
        modalBlurSigma: 0,
        modalElevation: 6,
        modalScaleBegin: 0.985,
        modalSlideOffset: 6,
      );
    }

    final isDark = scheme.brightness == Brightness.dark;
    final progress = opacityProgress.clamp(0.0, 1.0).toDouble();
    final baseTarget = _mix(0.22, 0.72, progress);
    final contentTarget = (baseTarget + 0.10).clamp(0.0, 0.78);
    final chromeTarget = (baseTarget + 0.16).clamp(0.0, 0.84);
    final raisedTarget = (baseTarget + 0.24).clamp(0.0, 0.88);
    final floatingTarget = (baseTarget + 0.38).clamp(0.0, 0.94);
    final isMica = material == GlassMaterial.mica;
    final modalTarget = isMica
        ? (baseTarget + 0.62).clamp(0.0, 0.97)
        : (baseTarget + 0.5).clamp(0.0, 0.90);
    final modalSurfaceBase = isMica
        ? scheme.surface
        : scheme.surfaceContainerLow;

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
      material: material,
      modalSurface: modalSurfaceBase.withValues(
        alpha: _overlayAlpha(baseTarget, modalTarget),
      ),
      modalBorderColor: isDark
          ? Colors.white.withValues(alpha: isMica ? 0.06 : 0.09)
          : const Color(0xFF506078).withValues(alpha: isMica ? 0.11 : 0.15),
      modalShadowColor: Colors.black.withValues(
        alpha: isDark ? (isMica ? 0.13 : 0.27) : (isMica ? 0.06 : 0.08),
      ),
      modalBarrierColor:
          (isDark ? const Color(0xFF080B10) : const Color(0xFF18202A))
              .withValues(alpha: isMica ? 0.26 : 0.55),
      modalBlurSigma: isMica ? 3.5 : 8.0,
      modalElevation: isMica ? 2 : 4,
      modalScaleBegin: isMica ? 0.992 : 0.985,
      modalSlideOffset: isMica ? 4 : 7,
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
  final GlassMaterial material;
  final Color modalSurface;
  final Color modalBorderColor;
  final Color modalShadowColor;
  final Color modalBarrierColor;
  final double modalBlurSigma;
  final double modalElevation;
  final double modalScaleBegin;
  final double modalSlideOffset;

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
    GlassMaterial? material,
    Color? modalSurface,
    Color? modalBorderColor,
    Color? modalShadowColor,
    Color? modalBarrierColor,
    double? modalBlurSigma,
    double? modalElevation,
    double? modalScaleBegin,
    double? modalSlideOffset,
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
    material: material ?? this.material,
    modalSurface: modalSurface ?? this.modalSurface,
    modalBorderColor: modalBorderColor ?? this.modalBorderColor,
    modalShadowColor: modalShadowColor ?? this.modalShadowColor,
    modalBarrierColor: modalBarrierColor ?? this.modalBarrierColor,
    modalBlurSigma: modalBlurSigma ?? this.modalBlurSigma,
    modalElevation: modalElevation ?? this.modalElevation,
    modalScaleBegin: modalScaleBegin ?? this.modalScaleBegin,
    modalSlideOffset: modalSlideOffset ?? this.modalSlideOffset,
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
      material: t < 0.5 ? material : other.material,
      modalSurface: Color.lerp(modalSurface, other.modalSurface, t)!,
      modalBorderColor: Color.lerp(
        modalBorderColor,
        other.modalBorderColor,
        t,
      )!,
      modalShadowColor: Color.lerp(
        modalShadowColor,
        other.modalShadowColor,
        t,
      )!,
      modalBarrierColor: Color.lerp(
        modalBarrierColor,
        other.modalBarrierColor,
        t,
      )!,
      modalBlurSigma: _mix(modalBlurSigma, other.modalBlurSigma, t),
      modalElevation: _mix(modalElevation, other.modalElevation, t),
      modalScaleBegin: _mix(modalScaleBegin, other.modalScaleBegin, t),
      modalSlideOffset: _mix(modalSlideOffset, other.modalSlideOffset, t),
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
