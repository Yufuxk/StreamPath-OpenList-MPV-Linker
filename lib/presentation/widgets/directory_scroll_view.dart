import 'package:flutter/material.dart';

import 'directory_wheel_scroll_region.dart';

/// 共用目录滚动条与滚轮兜底；滚动内容始终使用同一个 controller。
class DirectoryScrollView extends StatefulWidget {
  const DirectoryScrollView({
    super.key,
    required this.builder,
    this.controller,
    this.scrollbarKey,
    this.thumbVisibility = false,
  });

  final Widget Function(ScrollController) builder;
  final ScrollController? controller;
  final Key? scrollbarKey;
  final bool thumbVisibility;

  @override
  State<DirectoryScrollView> createState() => _DirectoryScrollViewState();
}

class _DirectoryScrollViewState extends State<DirectoryScrollView> {
  ScrollController? _ownedController;

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller =
        widget.controller ?? (_ownedController ??= ScrollController());
    return DirectoryWheelScrollRegion(
      controller: controller,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: Scrollbar(
          key: widget.scrollbarKey,
          controller: controller,
          thumbVisibility: widget.thumbVisibility,
          interactive: true,
          child: widget.builder(controller),
        ),
      ),
    );
  }
}
