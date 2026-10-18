import 'package:flutter/material.dart';

import 'directory_wheel_scroll_region.dart';
import '../theme/app_theme.dart';

/// 共用目录滚动条与滚轮兜底；滚动内容始终使用同一个 controller。
class DirectoryScrollView extends StatefulWidget {
  const DirectoryScrollView({
    super.key,
    required this.builder,
    this.controller,
    this.scrollbarKey,
    this.thumbVisibility = false,
    this.hideScrollbar = false,
    this.scrollDirection = Axis.vertical,
  });

  final Widget Function(ScrollController) builder;
  final ScrollController? controller;
  final Key? scrollbarKey;
  final bool thumbVisibility;
  final bool hideScrollbar;
  final Axis scrollDirection;

  static ({Rect viewport, Offset strength})? edgeMaskOf(BuildContext context) {
    final state = context.findAncestorStateOfType<_DirectoryScrollViewState>();
    if (state == null || state.widget.scrollDirection != Axis.horizontal) {
      return null;
    }
    final box = state.context.findRenderObject()! as RenderBox;
    return (
      viewport: MatrixUtils.transformRect(
        box.getTransformTo(null),
        Offset.zero & box.size,
      ),
      strength: state._edgeStrength,
    );
  }

  static Shader edgeShader(Rect bounds, Offset strength, {double scale = 1}) {
    final fade = (96 * scale / bounds.width).clamp(0.0, 1 / 3);
    final colors = <Color>[];
    final stops = <double>[];
    for (var i = 0; i <= 12; i++) {
      final t = i / 12;
      stops.add(fade * t);
      colors.add(
        Colors.white.withValues(
          alpha: 1 - strength.dx * (1 - Curves.easeInOutSine.transform(t)),
        ),
      );
    }
    for (var i = 0; i <= 12; i++) {
      final t = i / 12;
      stops.add(1 - fade + fade * t);
      colors.add(
        Colors.white.withValues(
          alpha: 1 - strength.dy * Curves.easeInOutSine.transform(t),
        ),
      );
    }
    return LinearGradient(colors: colors, stops: stops).createShader(bounds);
  }

  @override
  State<DirectoryScrollView> createState() => _DirectoryScrollViewState();
}

class _DirectoryScrollViewState extends State<DirectoryScrollView> {
  ScrollController? _ownedController;
  bool _fadeLeft = false, _fadeRight = false;
  Offset _edgeStrength = Offset.zero;

  void _updateEdges(ScrollMetrics metrics) {
    final horizontal = metrics.axis == Axis.horizontal;
    final reversed = metrics.axisDirection == AxisDirection.left;
    final left =
        horizontal &&
        (reversed ? metrics.extentAfter : metrics.extentBefore) > .5;
    final right =
        horizontal &&
        (reversed ? metrics.extentBefore : metrics.extentAfter) > .5;
    if (_fadeLeft == left && _fadeRight == right) {
      return;
    }
    setState(() {
      _fadeLeft = left;
      _fadeRight = right;
    });
  }

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller =
        widget.controller ?? (_ownedController ??= ScrollController());
    final body = widget.builder(controller);
    final fadingBody = widget.scrollDirection == Axis.horizontal
        ? TweenAnimationBuilder<Offset>(
            tween: Tween(
              begin: Offset.zero,
              end: Offset(_fadeLeft ? 1 : 0, _fadeRight ? 1 : 0),
            ),
            duration: AppTheme.hoverDuration,
            child: body,
            builder: (_, strength, child) {
              _edgeStrength = strength;
              return ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (bounds) =>
                    DirectoryScrollView.edgeShader(bounds, strength),
                child: child,
              );
            },
          )
        : body;
    final scrollbar = Scrollbar(
      key: widget.scrollbarKey,
      controller: controller,
      thumbVisibility: widget.hideScrollbar ? false : widget.thumbVisibility,
      interactive: !widget.hideScrollbar,
      child: fadingBody,
    );
    final content = DirectoryWheelScrollRegion(
      controller: controller,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: widget.hideScrollbar
            ? ScrollbarTheme(
                data: Theme.of(context).scrollbarTheme.copyWith(
                  thickness: const WidgetStatePropertyAll(0),
                  thumbColor: const WidgetStatePropertyAll(Colors.transparent),
                  trackColor: const WidgetStatePropertyAll(Colors.transparent),
                  trackBorderColor: const WidgetStatePropertyAll(
                    Colors.transparent,
                  ),
                  trackVisibility: const WidgetStatePropertyAll(false),
                ),
                child: scrollbar,
              )
            : scrollbar,
      ),
    );
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (notification.depth == 0) _updateEdges(notification.metrics);
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.depth == 0) _updateEdges(notification.metrics);
          return false;
        },
        child: content,
      ),
    );
  }
}
