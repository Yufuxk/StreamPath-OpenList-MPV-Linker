import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/glass_tokens.dart';

/// 只负责绘制层级材质的通用表面。
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.level,
    required this.child,
    this.borderRadius = BorderRadius.zero,
    this.border,
    this.padding,
    this.clipBehavior = Clip.none,
    this.automaticBorder = true,
    this.showShadow = true,
    this.blur = false,
    this.blurSigma = GlassTokens.panelBlurSigma,
    this.color,
  });

  final GlassSurfaceLevel level;
  final Widget child;
  final BorderRadius borderRadius;
  final Border? border;
  final EdgeInsetsGeometry? padding;
  final Clip clipBehavior;
  final bool automaticBorder;
  final bool showShadow;
  final bool blur;
  final double blurSigma;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).glass;
    final drawsRaisedEdge =
        level == GlassSurfaceLevel.raised ||
        level == GlassSurfaceLevel.floating;
    final effectiveBorder =
        border ??
        (automaticBorder && drawsRaisedEdge
            ? Border.all(color: tokens.borderColor)
            : null);
    final highlight = tokens.enabled && drawsRaisedEdge && color == null
        ? LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [tokens.innerHighlight, Colors.transparent],
            stops: const [0, 0.38],
          )
        : null;

    final content = Material(
      type: MaterialType.transparency,
      child: padding == null ? child : Padding(padding: padding!, child: child),
    );

    final decoration = BoxDecoration(
      color: color ?? tokens.surfaceFor(level),
      gradient: highlight,
      border: effectiveBorder,
      borderRadius: borderRadius,
    );
    final shadows = showShadow ? tokens.shadowsFor(level) : const <BoxShadow>[];
    if (blur && (tokens.enabled || color != null)) {
      // 先模糊背后画面，再叠加底色与描边。
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          boxShadow: shadows,
        ),
        child: ClipRRect(
          borderRadius: borderRadius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
            child: Container(decoration: decoration, child: content),
          ),
        ),
      );
    }
    return Container(
      decoration: decoration.copyWith(boxShadow: shadows),
      clipBehavior: clipBehavior,
      child: content,
    );
  }
}
