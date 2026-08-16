import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// 为桌面端滚动区域提供滚轮兜底路由。
///
/// 正常情况下，最深层的 [Scrollable] 会先通过
/// [GestureBinding.pointerSignalResolver] 接管滚轮；如果实际 Windows
/// 命中链被列表上层组件截断，本组件才作为外层候选，把滚轮交给同一个
/// [ScrollController]。使用统一解析器可避免列表与兜底逻辑重复滚动。
class DirectoryWheelScrollRegion extends StatelessWidget {
  const DirectoryWheelScrollRegion({
    super.key,
    required this.controller,
    required this.child,
  });

  final ScrollController controller;
  final Widget child;

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || controller.positions.length != 1) {
      return;
    }
    final position = controller.position;
    if (!position.physics.shouldAcceptUserOffset(position)) return;

    final delta = event.scrollDelta.dy != 0
        ? event.scrollDelta.dy
        : event.scrollDelta.dx;
    final target = math.min(
      math.max(position.pixels + delta, position.minScrollExtent),
      position.maxScrollExtent,
    );
    if (delta == 0 || target == position.pixels) return;

    GestureBinding.instance.pointerSignalResolver.register(event, (
      resolvedEvent,
    ) {
      if (resolvedEvent is! PointerScrollEvent ||
          controller.positions.length != 1) {
        return;
      }
      final current = controller.position;
      final resolvedDelta = resolvedEvent.scrollDelta.dy != 0
          ? resolvedEvent.scrollDelta.dy
          : resolvedEvent.scrollDelta.dx;
      final resolvedTarget = math.min(
        math.max(current.pixels + resolvedDelta, current.minScrollExtent),
        current.maxScrollExtent,
      );
      if (resolvedDelta == 0 || resolvedTarget == current.pixels) return;
      current.pointerScroll(resolvedDelta);
      resolvedEvent.respond(allowPlatformDefault: false);
    });
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.opaque,
    onPointerSignal: _handlePointerSignal,
    child: child,
  );
}
