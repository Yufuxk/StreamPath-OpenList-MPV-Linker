import 'package:flutter/material.dart';
import '../widgets/transition_content.dart';

/// 水平短距离过渡，退出与进入内容分段显示。
class StreamPathPageTransitionsBuilder extends PageTransitionsBuilder {
  const StreamPathPageTransitionsBuilder();

  @visibleForTesting
  static const incomingSlideKey = Key('streampath-page-incoming-slide');

  @override
  Duration get transitionDuration => const Duration(milliseconds: 220);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 180);

  @override
  DelegatedTransitionBuilder get delegatedTransition =>
      (
        BuildContext context,
        Animation<double> animation,
        Animation<double> secondaryAnimation,
        bool allowSnapshotting,
        Widget? child,
      ) => _slideOut(secondaryAnimation, child);

  static Widget _slideOut(Animation<double> animation, Widget? child) =>
      _PageSlide(
        animation: animation,
        begin: Offset.zero,
        end: const Offset(-30, 0),
        incoming: false,
        child: child,
      );

  @override
  Widget buildTransitions<T>(
    PageRoute<T>? route,
    BuildContext? context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return _slideOut(
      secondaryAnimation,
      _PageSlide(
        animation: animation,
        begin: const Offset(30, 0),
        end: Offset.zero,
        incoming: true,
        slideKey: incomingSlideKey,
        child: _RouteTransitionScope(
          route: route,
          animation: animation,
          secondaryAnimation: secondaryAnimation,
          child: child,
        ),
      ),
    );
  }
}

class _RouteTransitionScope extends StatefulWidget {
  const _RouteTransitionScope({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
    required this.route,
  });
  final Animation<double> animation, secondaryAnimation;
  final Widget child;
  final PageRoute<dynamic>? route;

  @override
  State<_RouteTransitionScope> createState() => _RouteTransitionScopeState();
}

class _RouteTransitionScopeState extends State<_RouteTransitionScope> {
  bool get _moving =>
      widget.route?.offstage == true ||
      widget.animation.status != AnimationStatus.completed ||
      widget.secondaryAnimation.status == AnimationStatus.forward ||
      widget.secondaryAnimation.status == AnimationStatus.reverse;

  void _changed(AnimationStatus _) => setState(() {});

  void _bind(bool add, _RouteTransitionScope source) {
    for (final animation in [source.animation, source.secondaryAnimation]) {
      if (add) {
        animation.addStatusListener(_changed);
      } else {
        animation.removeStatusListener(_changed);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _bind(true, widget);
  }

  @override
  void didUpdateWidget(_RouteTransitionScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation ||
        oldWidget.secondaryAnimation != widget.secondaryAnimation) {
      _bind(false, oldWidget);
      _bind(true, widget);
    }
  }

  @override
  void dispose() {
    _bind(false, widget);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      StreamPathTransitionScope(isTransitioning: _moving, child: widget.child);
}

class _PageSlide extends StatefulWidget {
  const _PageSlide({
    required this.animation,
    required this.begin,
    required this.end,
    required this.incoming,
    this.slideKey,
    this.child,
  });

  final Animation<double> animation;
  final Offset begin, end;
  final bool incoming;
  final Key? slideKey;
  final Widget? child;

  @override
  State<_PageSlide> createState() => _PageSlideState();
}

class _PageSlideState extends State<_PageSlide> {
  late CurvedAnimation _progress;

  void _bindAnimation() {
    _progress = CurvedAnimation(
      parent: widget.animation,
      curve: widget.incoming
          ? const Interval(.3, 1, curve: Curves.easeOutCubic)
          : const Interval(0, .3, curve: Curves.easeInCubic),
      reverseCurve: widget.incoming
          ? const Interval(.7, 1, curve: Curves.easeInCubic)
          : const Interval(0, .7, curve: Curves.easeOutCubic),
    );
  }

  @override
  void initState() {
    super.initState();
    _bindAnimation();
  }

  @override
  void didUpdateWidget(_PageSlide oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation ||
        oldWidget.incoming != widget.incoming) {
      _progress.dispose();
      _bindAnimation();
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRect(
    child: AnimatedBuilder(
      animation: _progress,
      child: widget.child,
      builder: (context, child) {
        final value = _progress.value;
        final opacity = widget.incoming ? value : 1 - value;
        final surface = Theme.of(context).scaffoldBackgroundColor;
        // 补足淡出层的底色透明度，半透明窗口也保持稳定底色。
        final fillAlpha =
            opacity == 1 || StreamPathTransitionBackdropScope.of(context)
            ? 0.0
            : surface.a * (1 - opacity) / (1 - surface.a * opacity);
        final offset = Offset.lerp(widget.begin, widget.end, value)!;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (opacity > 0 && fillAlpha > 0)
              ColoredBox(color: surface.withValues(alpha: fillAlpha)),
            Transform.translate(
              key: widget.slideKey,
              offset: offset,
              child: Opacity(opacity: opacity, child: child),
            ),
          ],
        );
      },
    ),
  );
}
