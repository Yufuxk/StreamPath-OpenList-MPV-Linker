import 'package:flutter/material.dart';

/// 透明细圆环与圆角实心三角，柔和投影保持亮色封面上的辨识度。
class FilmPlayIcon extends StatelessWidget {
  const FilmPlayIcon({super.key, this.opacity});

  final Animation<double>? opacity;
  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size.square(48), painter: _PlayPainter(opacity));
}

class _PlayPainter extends CustomPainter {
  const _PlayPainter(this.opacity) : super(repaint: opacity);

  final Animation<double>? opacity;

  @override
  void paint(Canvas canvas, Size size) {
    final alpha = opacity?.value ?? 1;
    if (alpha == 0) return;
    // 在当前变换内合成整体透明度，保留阴影且避免独立 OpacityLayer 取整。
    if (alpha < 1) {
      canvas.saveLayer(
        (Offset.zero & size).inflate(16),
        Paint()..color = Colors.white.withValues(alpha: alpha),
      );
    }
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addOval(const Rect.fromLTRB(1, 1, 47, 47))
      ..addOval(const Rect.fromLTRB(3.5, 3.5, 44.5, 44.5))
      ..moveTo(21, 14.4)
      ..lineTo(33.1, 22)
      ..quadraticBezierTo(35.5, 24, 33.1, 26)
      ..lineTo(21, 33.6)
      ..quadraticBezierTo(18.3, 35.3, 18.3, 32.2)
      ..lineTo(18.3, 15.8)
      ..quadraticBezierTo(18.3, 12.7, 21, 14.4)
      ..close();
    final paint = Paint()..isAntiAlias = true;
    canvas.drawPath(
      path.shift(const Offset(0, 3)),
      paint
        ..color = const Color(0x29000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.drawPath(
      path.shift(const Offset(0, 1.5)),
      paint
        ..color = const Color(0x3D000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
    canvas.drawPath(
      path,
      paint
        ..color = Colors.white
        ..maskFilter = null,
    );
    if (alpha < 1) canvas.restore();
  }

  @override
  bool shouldRepaint(_PlayPainter oldDelegate) =>
      opacity != oldDelegate.opacity;
}
