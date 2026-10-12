import 'package:flutter/material.dart';

import 'transition_content.dart';

/// 局部分类使用同一路径管理运动、冷内容挂载和最近一次切换请求。
class StreamPathSectionSwitcher<T> extends StatefulWidget {
  const StreamPathSectionSwitcher({
    super.key,
    required this.selected,
    required this.order,
    required this.contentBuilder,
    required this.shellBuilder,
    this.retainContent = false,
    this.animate = true,
    this.onSettled,
  });

  final T selected;
  final List<T> order;
  final Widget Function(BuildContext, T) contentBuilder, shellBuilder;
  final bool retainContent, animate;
  final ValueChanged<T>? onSettled;

  @override
  State<StreamPathSectionSwitcher<T>> createState() =>
      _SectionSwitcherState<T>();
}

class _SectionSwitcherState<T> extends State<StreamPathSectionSwitcher<T>>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation;
  late T _current;
  T? _target, _queued;
  final Set<T> _visited = {};
  double _direction = 1;

  @override
  void initState() {
    super.initState();
    _current = widget.selected;
    _visited.add(_current);
    _animation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      value: 1,
    )..addStatusListener(_finished);
  }

  void _select(T next) {
    if (_animation.isAnimating) {
      _queued = next;
      return;
    }
    if (next == _current) return;
    _direction = widget.order.indexOf(next) > widget.order.indexOf(_current)
        ? 1
        : -1;
    _target = next;
    _visited.add(next);
    _animation.forward(from: 0);
  }

  void _finished(AnimationStatus status) {
    if (status != AnimationStatus.completed || _target == null) return;
    final next = _queued;
    setState(() {
      _current = _target as T;
      _target = _queued = null;
      if (!widget.retainContent) {
        _visited.retainWhere((item) => item == _current);
      }
      if (next != null && next != _current) _select(next);
    });
    // 连续点击时，略过中间目标的正文与初始化。
    if (_target == null) widget.onSettled?.call(_current);
  }

  @override
  void didUpdateWidget(StreamPathSectionSwitcher<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected != oldWidget.selected ||
        (!widget.animate && oldWidget.animate)) {
      if (!widget.animate || MediaQuery.disableAnimationsOf(context)) {
        _animation.stop();
        _current = widget.selected;
        _target = _queued = null;
        if (!widget.retainContent) _visited.clear();
        _visited.add(_current);
        widget.onSettled?.call(_current);
      } else {
        _select(widget.selected);
      }
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRect(
    child: Stack(
      fit: StackFit.expand,
      children: [
        for (final section in _visited)
          AnimatedBuilder(
            key: ValueKey(section),
            animation: _animation,
            child: StreamPathTransitionContent(
              deferUntilNextFrame: widget.animate,
              isTransitioning: _target != null || section != _current,
              shellBuilder: (context) => widget.shellBuilder(context, section),
              contentBuilder: (context) =>
                  widget.contentBuilder(context, section),
            ),
            builder: (context, child) {
              final value = _animation.value;
              final incoming = section == _target;
              final visible = _target == null
                  ? section == _current
                  : incoming
                  ? value >= .3
                  : section == _current && value < .3;
              final progress = incoming
                  ? ((value - .3) / .7).clamp(0.0, 1.0)
                  : (value / .3).clamp(0.0, 1.0);
              final opacity = _target == null
                  ? 1.0
                  : incoming
                  ? progress
                  : 1 - progress;
              final offset = _target == null
                  ? 0.0
                  : incoming
                  ? _direction *
                        30 *
                        (1 - Curves.easeOutCubic.transform(progress))
                  : -_direction * 30 * Curves.easeInCubic.transform(progress);
              return Offstage(
                offstage: !visible,
                child: TickerMode(
                  enabled: visible,
                  child: IgnorePointer(
                    ignoring: _target != null,
                    child: ExcludeFocus(
                      excluding: !visible || _target != null,
                      child: Transform.translate(
                        key: ValueKey(('section-slide', section)),
                        offset: Offset(offset, 0),
                        child: Opacity(opacity: opacity, child: child),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    ),
  );
}
