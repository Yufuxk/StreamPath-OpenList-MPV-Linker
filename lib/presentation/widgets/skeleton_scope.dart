import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'cinematic_states.dart';

/// 页面资料及已挂载图片就绪后，统一结束骨架并保留最短展示时间。
class SkeletonScope extends StatefulWidget {
  const SkeletonScope({
    super.key,
    required this.ready,
    required this.child,
    this.enabled = true,
    this.minimumDuration = const Duration(milliseconds: 700),
    this.revealDuration = const Duration(milliseconds: 240),
  });

  final bool ready, enabled;
  final Duration minimumDuration, revealDuration;
  final Widget child;

  @override
  State<SkeletonScope> createState() => _SkeletonScopeState();
}

class _SkeletonScopeState extends State<SkeletonScope>
    with SingleTickerProviderStateMixin {
  late final _reveal = AnimationController(vsync: this);
  late final _controller = _SkeletonController(_reveal, _scheduleCheck);
  Timer? _minimumTimer;
  bool _minimumElapsed = false, _checkScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _minimumTimer = Timer(widget.minimumDuration, () {
        _minimumElapsed = true;
        _scheduleCheck();
      });
    });
  }

  void _scheduleCheck() {
    if (!mounted || _checkScheduled || _controller.revealed) return;
    _checkScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      if (!mounted || _controller.revealed) return;
      if (widget.ready &&
          widget.enabled &&
          _minimumElapsed &&
          _controller.pending.isEmpty) {
        _controller.revealed = true;
        _reveal.duration = MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : widget.revealDuration;
        _reveal.forward();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _minimumTimer?.cancel();
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _scheduleCheck();
    return _SkeletonData(controller: _controller, child: widget.child);
  }
}

class _SkeletonController {
  _SkeletonController(this.reveal, this.changed);
  final Animation<double> reveal;
  final VoidCallback changed;
  final pending = <Object>{};
  bool revealed = false;

  VoidCallback? hold() {
    if (revealed) return null;
    final token = Object();
    pending.add(token);
    return () {
      if (pending.remove(token)) changed();
    };
  }
}

class _SkeletonData extends InheritedWidget {
  const _SkeletonData({required this.controller, required super.child});
  final _SkeletonController controller;

  static _SkeletonController? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SkeletonData>()?.controller;

  @override
  bool updateShouldNotify(_SkeletonData oldWidget) =>
      oldWidget.controller != controller;
}

/// 异步组件报告首帧、缺图或失败已就绪；仅影响最近的骨架页面。
class SkeletonLoadBoundary extends StatefulWidget {
  const SkeletonLoadBoundary({
    super.key,
    required this.ready,
    required this.child,
  });
  final bool ready;
  final Widget child;

  @override
  State<SkeletonLoadBoundary> createState() => _SkeletonLoadBoundaryState();
}

class _SkeletonLoadBoundaryState extends State<SkeletonLoadBoundary> {
  _SkeletonController? _controller;
  VoidCallback? _release;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = _SkeletonData.of(context);
    if (controller != _controller) {
      _release?.call();
      _release = null;
      _controller = controller;
    }
    _update();
  }

  @override
  void didUpdateWidget(SkeletonLoadBoundary oldWidget) {
    super.didUpdateWidget(oldWidget);
    _update();
  }

  void _update() {
    if (widget.ready) {
      _release?.call();
      _release = null;
    } else {
      _release ??= _controller?.hold();
    }
  }

  @override
  void dispose() {
    _release?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 隐藏内容仍参与布局和异步加载，占位与真实控件使用同一个矩形。
class SkeletonRegion extends StatelessWidget {
  const SkeletonRegion({
    super.key,
    required this.child,
    this.borderRadius = AppTheme.controlRadius,
  });
  final Widget child;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final controller = _SkeletonData.of(context);
    if (controller == null) return child;
    return AnimatedBuilder(
      animation: controller.reveal,
      child: child,
      builder: (_, child) {
        final progress = controller.reveal.value;
        final opacity = Curves.easeOutCubic.transform(progress);
        return Stack(
          fit: StackFit.passthrough,
          children: [
            ExcludeSemantics(
              excluding: progress != 1,
              child: IgnorePointer(
                ignoring: progress != 1,
                child: Opacity(opacity: opacity, child: child),
              ),
            ),
            if (progress != 1)
              Positioned.fill(
                child: Opacity(
                  opacity: 1 - opacity,
                  child: CinematicSkeleton(
                    showLines: false,
                    borderRadius: borderRadius,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
