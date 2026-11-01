import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../localization/app_text.dart';
import '../theme/app_theme.dart';

const _playRadius = BorderRadius.all(Radius.circular(8));

class FilmDetailPlayButton extends StatefulWidget {
  const FilmDetailPlayButton({
    super.key,
    required this.onPressed,
    this.buttonKey = const Key('film-detail-play'),
    this.label = const AppText('播放此文件'),
  });
  final VoidCallback? onPressed;
  final Key buttonKey;
  final Widget label;

  @override
  State<FilmDetailPlayButton> createState() => _FilmDetailPlayButtonState();
}

class _FilmDetailPlayButtonState extends State<FilmDetailPlayButton> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = widget.onPressed != null;
    final foreground = scheme.onPrimary;
    final glyphColor = enabled
        ? foreground
        : scheme.onSurface.withValues(alpha: .38);
    final labelStyle = Theme.of(context).textTheme.labelLarge?.copyWith(
      fontWeight: FontWeight.w500,
      letterSpacing: .1,
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        scale: _hovered && enabled ? 1.025 : 1,
        duration: AppTheme.hoverDuration,
        curve: Curves.easeOutCubic,
        child: FilledButton.icon(
          key: widget.buttonKey,
          style:
              FilledButton.styleFrom(
                elevation: 0,
                shadowColor: Colors.transparent,
                surfaceTintColor: Colors.transparent,
                backgroundColor: scheme.primary,
                disabledBackgroundColor: scheme.surfaceContainerHighest
                    .withValues(alpha: .85),
                foregroundColor: foreground,
                disabledForegroundColor: glyphColor,
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                shape: const RoundedRectangleBorder(borderRadius: _playRadius),
                textStyle: labelStyle,
              ).copyWith(
                // 仅保留 1px 极淡的白色高光描边，禁用态更淡。
                side: WidgetStateProperty.resolveWith(
                  (states) => BorderSide(
                    color: Colors.white.withValues(
                      alpha: states.contains(WidgetState.disabled) ? .06 : .12,
                    ),
                  ),
                ),
              ),
          onPressed: widget.onPressed,
          icon: _SolidPlayGlyph(color: glyphColor),
          label: widget.label,
        ),
      ),
    );
  }
}

/// 实心播放三角：三个角用细圆角收边，替代原有空心字形。
class _SolidPlayGlyph extends StatelessWidget {
  const _SolidPlayGlyph({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 16,
    child: CustomPaint(painter: _SolidPlayGlyphPainter(color)),
  );
}

class _SolidPlayGlyphPainter extends CustomPainter {
  const _SolidPlayGlyphPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width * .22, size.height * .14)
      ..lineTo(size.width * .88, size.height * .5)
      ..lineTo(size.width * .22, size.height * .86)
      ..close();
    // 先填充再以同色圆角描边扩大轮廓，三个角自然圆润。
    canvas.drawPath(path, Paint()..color = color);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * .16
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_SolidPlayGlyphPainter oldDelegate) =>
      oldDelegate.color != color;
}

class FilmDetailActionButton extends StatelessWidget {
  const FilmDetailActionButton({
    super.key,
    required this.onPressed,
    required this.label,
    required this.icon,
    this.buttonKey,
  });
  final VoidCallback? onPressed;
  final Widget label, icon;
  final Key? buttonKey;

  static ButtonStyle styleOf(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return OutlinedButton.styleFrom(
      minimumSize: const Size(0, 44),
      foregroundColor: scheme.onSurface,
      backgroundColor: scheme.onSurface.withValues(alpha: .08),
      side: BorderSide(color: scheme.onSurface.withValues(alpha: .16)),
    );
  }

  @override
  Widget build(BuildContext context) => FilmDetailActionSurface(
    child: OutlinedButton.icon(
      key: buttonKey,
      style: styleOf(context),
      onPressed: onPressed,
      icon: icon,
      label: label,
    ),
  );
}

class FilmDetailActionSurface extends StatelessWidget {
  const FilmDetailActionSurface({
    super.key,
    required this.child,
    this.radius = 8,
  });
  final Widget child;
  final double radius;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      boxShadow: const [
        BoxShadow(
          color: Color(0x33000000),
          blurRadius: 6,
          offset: Offset(0, 2),
        ),
      ],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: ColoredBox(
          color: Theme.of(
            context,
          ).scaffoldBackgroundColor.withValues(alpha: .74),
          child: child,
        ),
      ),
    ),
  );
}
