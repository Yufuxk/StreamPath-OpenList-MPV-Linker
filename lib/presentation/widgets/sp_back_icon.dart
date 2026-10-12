import 'package:flutter/widgets.dart';

/// 返回按钮共用的圆角矢量折线，按实际尺寸与设备像素比例绘制。
class SPBackIcon extends StatelessWidget {
  const SPBackIcon({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final size = theme.size ?? 24;
    final color = theme.color ?? DefaultTextStyle.of(context).style.color!;
    return CustomPaint(
      size: Size.square(size),
      painter: _BackIconPainter(
        color.withValues(alpha: color.a * (theme.opacity ?? 1)),
      ),
    );
  }
}

class _BackIconPainter extends CustomPainter {
  const _BackIconPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width * 2 / 3, size.height / 8)
      ..lineTo(size.width / 3, size.height / 2)
      ..lineTo(size.width * 2 / 3, size.height * 7 / 8);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.shortestSide * 0.12
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_BackIconPainter oldDelegate) =>
      color != oldDelegate.color;
}
