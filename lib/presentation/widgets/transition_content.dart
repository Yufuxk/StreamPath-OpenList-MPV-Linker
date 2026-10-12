import 'package:flutter/material.dart';

/// 仅约束展示工作；数据保存、扫描与播放仍由原控制器执行。
class StreamPathTransitionScope extends InheritedWidget {
  const StreamPathTransitionScope({
    super.key,
    required this.isTransitioning,
    required super.child,
  });

  final bool isTransitioning;

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<StreamPathTransitionScope>()
          ?.isTransitioning ??
      false;

  static bool read(BuildContext context) =>
      context
          .getInheritedWidgetOfExactType<StreamPathTransitionScope>()
          ?.isTransitioning ??
      false;

  @override
  bool updateShouldNotify(StreamPathTransitionScope oldWidget) =>
      isTransitioning != oldWidget.isTransitioning;
}

/// 冷页面只挂载轻壳，运动结束后才调用正文构建器。
class StreamPathTransitionContent extends StatefulWidget {
  const StreamPathTransitionContent({
    super.key,
    required this.shellBuilder,
    required this.contentBuilder,
    this.isTransitioning = false,
    this.deferUntilNextFrame = true,
  });

  final WidgetBuilder shellBuilder, contentBuilder;
  final bool isTransitioning;
  final bool deferUntilNextFrame;

  @override
  State<StreamPathTransitionContent> createState() =>
      _StreamPathTransitionContentState();
}

class _StreamPathTransitionContentState
    extends State<StreamPathTransitionContent> {
  Widget? _content;
  bool _moving = false, _releasePending = false;

  @override
  Widget build(BuildContext context) {
    final moving =
        widget.isTransitioning || StreamPathTransitionScope.of(context);
    if (!widget.deferUntilNextFrame) _releasePending = false;
    if (_moving && !moving && !_releasePending && widget.deferUntilNextFrame) {
      _releasePending = true;
      // 先提交静止的最后一帧，再在下一帧挂载正文。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            !widget.isTransitioning &&
            !StreamPathTransitionScope.read(context)) {
          setState(() => _releasePending = false);
        } else {
          _releasePending = false;
        }
      });
    }
    _moving = moving;
    final gated = moving || _releasePending;
    if (!gated) _content = widget.contentBuilder(context);
    return StreamPathTransitionScope(
      isTransitioning: gated,
      child: _content ?? widget.shellBuilder(context),
    );
  }
}

/// 控制器通知在运动期间合并，结束时提交最新展示内容。
class StreamPathTransitionBuilder extends StatefulWidget {
  const StreamPathTransitionBuilder({
    super.key,
    required this.listenable,
    required this.builder,
  });

  final Listenable listenable;
  final WidgetBuilder builder;

  @override
  State<StreamPathTransitionBuilder> createState() =>
      _StreamPathTransitionBuilderState();
}

class _StreamPathTransitionBuilderState
    extends State<StreamPathTransitionBuilder> {
  Widget? _content;
  bool _moving = false;

  void _changed() {
    if (!_moving) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(StreamPathTransitionBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listenable != widget.listenable) {
      oldWidget.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _moving = StreamPathTransitionScope.of(context);
    if (!_moving || _content == null) _content = widget.builder(context);
    return _content!;
  }
}

/// 异步结果继续更新页面数据，运动期间合并 State 的展示刷新。
mixin StreamPathTransitionState<T extends StatefulWidget> on State<T> {
  bool _transitioning = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _transitioning = StreamPathTransitionScope.of(context);
  }

  @override
  void setState(VoidCallback fn) {
    if (_transitioning && mounted) {
      fn();
    } else {
      super.setState(fn);
    }
  }
}

/// 常驻背景由导航宿主持有，路由过渡不再补画主题底色。
class StreamPathTransitionBackdropScope extends InheritedWidget {
  const StreamPathTransitionBackdropScope({
    super.key,
    required this.hasBackdrop,
    required super.child,
  });

  final bool hasBackdrop;

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<
            StreamPathTransitionBackdropScope
          >()
          ?.hasBackdrop ??
      false;

  @override
  bool updateShouldNotify(StreamPathTransitionBackdropScope oldWidget) =>
      hasBackdrop != oldWidget.hasBackdrop;
}

class StreamPathPageShell extends StatelessWidget {
  const StreamPathPageShell({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    key: const Key('film-entry-shell'),
    backgroundColor: StreamPathTransitionBackdropScope.of(context)
        ? Colors.transparent
        : null,
  );
}
