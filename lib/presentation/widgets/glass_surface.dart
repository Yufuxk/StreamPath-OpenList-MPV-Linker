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
  });

  final GlassSurfaceLevel level;
  final Widget child;
  final BorderRadius borderRadius;
  final Border? border;
  final EdgeInsetsGeometry? padding;
  final Clip clipBehavior;
  final bool automaticBorder;
  final bool showShadow;

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
    final highlight = tokens.enabled && drawsRaisedEdge
        ? LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [tokens.innerHighlight, Colors.transparent],
            stops: const [0, 0.38],
          )
        : null;

    Widget content = Material(
      type: MaterialType.transparency,
      child: padding == null ? child : Padding(padding: padding!, child: child),
    );

    return Container(
      decoration: BoxDecoration(
        color: tokens.surfaceFor(level),
        gradient: highlight,
        border: effectiveBorder,
        borderRadius: borderRadius,
        boxShadow: showShadow ? tokens.shadowsFor(level) : const [],
      ),
      clipBehavior: clipBehavior,
      child: content,
    );
  }
}
