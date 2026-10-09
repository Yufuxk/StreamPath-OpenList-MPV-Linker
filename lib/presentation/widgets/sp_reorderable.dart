import 'package:flutter/material.dart';
import 'sp_icons.dart';
import 'sp_menu.dart';

/// 排序浮层复用菜单的整块材质。
Widget spReorderProxy(Widget child, int index, Animation<double> animation) =>
    SPMenuSurface(child: child);

class SPReorderHandle extends StatelessWidget {
  const SPReorderHandle({
    super.key,
    required this.index,
    required this.tooltip,
    this.enabled = true,
  });
  final int index;
  final String tooltip;
  final bool enabled;

  @override
  Widget build(BuildContext context) => ReorderableDragStartListener(
    index: index,
    enabled: enabled,
    child: Tooltip(
      message: tooltip,
      child: const Padding(
        padding: EdgeInsets.all(8),
        child: Icon(SPIcons.swapVertical),
      ),
    ),
  );
}
