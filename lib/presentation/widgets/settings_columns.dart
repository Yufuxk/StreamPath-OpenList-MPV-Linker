import 'package:flutter/material.dart';

/// 设置分组按可用宽度并排，保持跨断点的控件树与编辑状态。
class SettingsColumns extends StatelessWidget {
  const SettingsColumns({
    super.key,
    required this.children,
    this.firstFraction = 0.5,
  });

  final List<Widget> children;
  final double firstFraction;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final wide = constraints.maxWidth >= 1080 * scale;
      return Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          for (var i = 0; i < children.length; i++)
            SizedBox(
              width: wide
                  ? (constraints.maxWidth - 16) *
                        (i.isEven ? firstFraction : 1 - firstFraction)
                  : constraints.maxWidth,
              child: children[i],
            ),
        ],
      );
    },
  );
}
