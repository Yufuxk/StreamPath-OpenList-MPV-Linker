import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderIndexedStack, RenderImage, RenderOpacity;

import 'transition_content.dart';
import 'directory_scroll_view.dart';

/// 每个卡片实例拥有独立身份，同一作品在不同栏目不会共享 tag。
class FilmPosterAnchor {
  final _source = GlobalKey<_FilmSharedPosterState>();
  ImageProvider<Object>? provider;
  Widget Function(Widget)? decorate;
  late Size _flightViewport;
  Rect? _flightSource;
  ({Rect viewport, Offset strength})? _flightEdge;

  void beginFlight(NavigatorState navigator) {
    _source.currentState?._setEnabled(true);
    _flightViewport = (navigator.context.findRenderObject()! as RenderBox).size;
    _flightSource = _bounds;
    final context = _source.currentContext;
    _flightEdge = context == null
        ? null
        : DirectoryScrollView.edgeMaskOf(context);
  }

  bool get visible => _visible(_source.currentContext);

  /// 飞行复用当前挂载的图片，不依赖文件位置缓存是否仍有记录。
  ImageProvider<Object>? get sourceProvider {
    ImageProvider<Object>? result;
    void visit(Element element) {
      if (result != null) return;
      if (element.widget case Image(:final image)) {
        result = image;
      } else {
        element.visitChildElements(visit);
      }
    }

    _source.currentContext?.visitChildElements(visit);
    return result;
  }

  bool get ready {
    var hasImage = false, fading = false;
    void visit(RenderObject object) {
      if (object is RenderImage && object.image != null) hasImage = true;
      if (object is RenderOpacity && object.opacity < 1) fading = true;
      object.visitChildren(visit);
    }

    _source.currentContext?.findRenderObject()?.visitChildren(visit);
    return hasImage && !fading;
  }

  Rect? get _bounds => _globalBounds(_source.currentContext);

  void prepareReturn() => _source.currentState?._setEnabled(visible);

  static bool _visible(BuildContext? context) {
    final rect = _globalBounds(context);
    if (rect == null) return false;
    RenderObject child = context!.findRenderObject()!;
    for (
      RenderObject? parent = child.parent;
      parent != null;
      parent = child.parent
    ) {
      if (parent is RenderIndexedStack &&
          parent.index !=
              parent.getChildrenAsList().indexOf(child as RenderBox)) {
        return false;
      }
      final clip = parent.describeApproximatePaintClip(child);
      if (clip != null) {
        final bounds = MatrixUtils.transformRect(
          parent.getTransformTo(null),
          clip,
        ).inflate(.5);
        if (!bounds.contains(rect.topLeft) ||
            !bounds.contains(rect.bottomRight)) {
          return false;
        }
      }
      child = parent;
    }
    return true;
  }

  static Rect? _globalBounds(BuildContext? context) {
    final box = context?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    final rect = MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );
    return rect.isFinite && !rect.isEmpty ? rect : null;
  }
}

class FilmSharedPoster extends StatefulWidget {
  FilmSharedPoster({
    required this.anchor,
    required this.child,
    this.source = false,
  }) : super(key: source ? anchor._source : null);

  final FilmPosterAnchor anchor;
  final Widget child;
  final bool source;

  @override
  State<FilmSharedPoster> createState() => _FilmSharedPosterState();
}

class _FilmSharedPosterState extends State<FilmSharedPoster> {
  bool _enabled = true;
  final _contentKey = GlobalKey();

  void _setEnabled(bool enabled) {
    if (_enabled != enabled) setState(() => _enabled = enabled);
  }

  @override
  Widget build(BuildContext context) => HeroMode(
    enabled: _enabled,
    child: Hero(
      tag: widget.anchor,
      curve: Curves.easeInOutCubic,
      reverseCurve: Curves.easeInOutCubic,
      placeholderBuilder: (_, size, child) => SizedBox(
        width: size.width,
        height: size.height,
        child: Offstage(child: TickerMode(enabled: false, child: child)),
      ),
      createRectTween: (begin, end) => _PosterRectTween(
        begin: begin,
        end: end,
        poster: widget.anchor,
        landingOnSource: widget.source,
        navigator: Navigator.of(context),
      ),
      flightShuttleBuilder: (_, animation, direction, _, _) => _PosterShuttle(
        poster: widget.anchor,
        animation: animation,
        returning: direction == HeroFlightDirection.pop,
      ),
      child: KeyedSubtree(key: _contentKey, child: widget.child),
    ),
  );
}

class _PosterShuttle extends StatelessWidget {
  const _PosterShuttle({
    required this.poster,
    required this.animation,
    required this.returning,
  });
  final FilmPosterAnchor poster;
  final Animation<double> animation;
  final bool returning;

  @override
  Widget build(BuildContext context) {
    final image = Image(
      key: const Key('film-connected-flight'),
      image: poster.provider!,
      width: double.infinity,
      height: double.infinity,
      fit: BoxFit.cover,
      alignment: Alignment.center,
      filterQuality: FilterQuality.medium,
    );
    final child = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: poster.decorate?.call(image) ?? image,
    );
    if (poster._flightEdge == null) return child;
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (_, child) => ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) {
          final context = poster._source.currentContext;
          final landing =
              returning || animation.status == AnimationStatus.reverse;
          final edge = landing && context != null
              ? DirectoryScrollView.edgeMaskOf(context) ?? poster._flightEdge!
              : poster._flightEdge!;
          final source =
              (landing ? poster._bounds : null) ?? poster._flightSource!;
          final scale = bounds.width / source.width;
          final strength =
              1 -
              const Interval(
                0,
                .3,
                curve: Curves.easeOutCubic,
              ).transform(animation.value);
          return DirectoryScrollView.edgeShader(
            Rect.fromLTWH(
              (edge.viewport.left - source.left) * scale,
              0,
              edge.viewport.width * scale,
              bounds.height,
            ),
            edge.strength * strength,
            scale: scale,
          );
        },
        child: child,
      ),
    );
  }
}

class _PosterRectTween extends RectTween {
  _PosterRectTween({
    super.begin,
    super.end,
    required this.poster,
    required this.landingOnSource,
    required this.navigator,
  });
  final FilmPosterAnchor poster;
  final bool landingOnSource;
  final NavigatorState navigator;
  @override
  Rect? lerp(double t) {
    final bounds = landingOnSource ? poster._bounds : null;
    // Hero 跟随终点位置；响应式列表同时需要更新终点尺寸。
    if (bounds != null) end = end!.topLeft & bounds.size;
    final rect = super.lerp(t)!;
    final viewport = (navigator.context.findRenderObject()! as RenderBox).size;
    // Hero 的 RelativeRect 使用起飞时的视口，窗口变化需补偿右下边距。
    return Rect.fromLTRB(
      rect.left,
      rect.top,
      rect.right + poster._flightViewport.width - viewport.width,
      rect.bottom + poster._flightViewport.height - viewport.height,
    );
  }
}

/// 仅共享详情路由参与 Hero 预布局，普通页面保留原首帧时序。
class FilmConnectedHeroController extends HeroController {
  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    if ((previousTopRoute is FilmConnectedDetailRoute &&
            previousTopRoute.animation!.status == AnimationStatus.reverse) ||
        (topRoute is FilmConnectedDetailRoute &&
            topRoute.animation!.status == AnimationStatus.forward)) {
      super.didChangeTop(topRoute, previousTopRoute);
    }
  }

  @override
  void didStartUserGesture(
    Route<dynamic> route,
    Route<dynamic>? previousRoute,
  ) {
    if (route is FilmConnectedDetailRoute) {
      super.didStartUserGesture(route, previousRoute);
    }
  }
}

/// 沿用 Navigator 的 Hero 交接与中途反向，不创建额外动画控制器。
class FilmConnectedDetailRoute extends MaterialPageRoute<void> {
  FilmConnectedDetailRoute({required this.poster, required super.builder})
    : super(allowSnapshotting: false);

  final FilmPosterAnchor poster;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 420);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 420);

  @override
  bool didPop(Object? result) {
    if (animation!.status == AnimationStatus.completed) {
      poster.beginFlight(navigator!);
    }
    poster.prepareReturn();
    return super.didPop(null);
  }

  @override
  DelegatedTransitionBuilder get delegatedTransition =>
      (context, animation, secondaryAnimation, allowSnapshotting, child) =>
          _HomeScope(
            animation: secondaryAnimation,
            child: StreamPathTransitionScope(
              isTransitioning:
                  secondaryAnimation.status == AnimationStatus.forward ||
                  secondaryAnimation.status == AnimationStatus.reverse,
              child: child!,
            ),
          );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => _ConnectedScope(
    animation: animation,
    poster: poster,
    child: StreamPathTransitionScope(
      isTransitioning:
          offstage || animation.status != AnimationStatus.completed,
      child: IgnorePointer(
        ignoring: animation.status != AnimationStatus.completed,
        child: child,
      ),
    ),
  );
}

class _HomeScope extends InheritedWidget {
  const _HomeScope({required this.animation, required super.child});
  final Animation<double> animation;
  @override
  bool updateShouldNotify(_HomeScope oldWidget) =>
      animation != oldWidget.animation;
}

/// 只淡出主页前景，已显示的背景仍留在原绘制层。
class FilmConnectedHomeContent extends StatelessWidget {
  const FilmConnectedHomeContent({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_HomeScope>();
    return FadeTransition(
      opacity:
          scope?.animation.drive(
            Tween(begin: 1.0, end: 0.0).chain(
              CurveTween(
                curve: const Interval(0, 120 / 420, curve: Curves.easeOutCubic),
              ),
            ),
          ) ??
          const AlwaysStoppedAnimation(1.0),
      child: child,
    );
  }
}

enum FilmConnectedPart { background, poster, primary, secondary }

class _ConnectedScope extends InheritedWidget {
  const _ConnectedScope({
    required this.animation,
    required this.poster,
    required super.child,
  });
  final Animation<double> animation;
  final FilmPosterAnchor poster;

  @override
  bool updateShouldNotify(_ConnectedScope oldWidget) =>
      animation != oldWidget.animation || poster != oldWidget.poster;
}

FilmPosterAnchor? filmConnectedPoster(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<_ConnectedScope>()?.poster;

class FilmConnectedReveal extends StatelessWidget {
  const FilmConnectedReveal({
    super.key,
    required this.child,
    this.part = FilmConnectedPart.primary,
  });
  final Widget child;
  final FilmConnectedPart part;

  @override
  Widget build(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_ConnectedScope>();
    if (scope == null) return child;
    final stage = part;
    final (begin, end) = switch (stage) {
      FilmConnectedPart.background => (100 / 420, 320 / 420),
      FilmConnectedPart.poster => (0.0, 100 / 420),
      FilmConnectedPart.primary => (180 / 420, 380 / 420),
      FilmConnectedPart.secondary => (280 / 420, 1.0),
    };
    final progress = scope.animation.drive(
      CurveTween(curve: Interval(begin, end, curve: Curves.easeOutCubic)),
    );
    Widget content =
        stage == FilmConnectedPart.background ||
            stage == FilmConnectedPart.poster
        ? child
        : AnimatedBuilder(
            animation: progress,
            child: child,
            builder: (_, child) => Transform.translate(
              offset: Offset(0, 8 * (1 - progress.value)),
              child: child,
            ),
          );
    if (stage == FilmConnectedPart.secondary) {
      content = TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        child: content,
        builder: (_, opacity, child) => Opacity(opacity: opacity, child: child),
      );
    }
    return FadeTransition(opacity: progress, child: content);
  }
}
