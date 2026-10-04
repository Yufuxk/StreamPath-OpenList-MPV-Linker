import 'package:flutter/material.dart';

/// 封面上的高对比播放标记。
class FilmPlayIcon extends StatelessWidget {
  const FilmPlayIcon({super.key});
  @override
  Widget build(BuildContext context) => Container(
    width: 48,
    height: 48,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: Colors.black.withValues(alpha: .48),
      border: Border.all(
        color: Colors.white.withValues(alpha: .85),
        width: 1.8,
      ),
      boxShadow: const [
        BoxShadow(
          color: Color(0x66000000),
          blurRadius: 8,
          offset: Offset(0, 2),
        ),
      ],
    ),
    child: const Center(
      child: Padding(
        padding: EdgeInsets.only(left: 2),
        child: CustomPaint(size: Size.square(26), painter: _PlayPainter()),
      ),
    ),
  );
}

class _PlayPainter extends CustomPainter {
  const _PlayPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(6, 3)
      ..lineTo(22, 13)
      ..lineTo(6, 23)
      ..close();
    final paint = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(
      path.shift(const Offset(0, 1)),
      paint
        ..color = Colors.black
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5),
    );
    canvas.drawPath(
      path,
      paint
        ..color = Colors.white
        ..maskFilter = null,
    );
  }

  @override
  bool shouldRepaint(_PlayPainter oldDelegate) => false;
}
