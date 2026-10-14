import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../localization/app_text.dart';
import '../theme/app_theme.dart';
import 'sp_icons.dart';

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
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        scale: _hovered && widget.onPressed != null ? 1.025 : 1,
        duration: AppTheme.hoverDuration,
        curve: Curves.easeOutCubic,
        child: AnimatedContainer(
          duration: AppTheme.hoverDuration,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            boxShadow: widget.onPressed == null
                ? const []
                : AppTheme.accentGlow(scheme.primary),
          ),
          child: FilledButton.icon(
            key: widget.buttonKey,
            style: FilledButton.styleFrom(
              backgroundColor: scheme.primary,
              foregroundColor: scheme.onPrimary,
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: 20),
            ),
            onPressed: widget.onPressed,
            icon: Icon(
              SPIcons.play,
              color: widget.onPressed == null
                  ? scheme.onSurface.withValues(alpha: .38)
                  : scheme.onPrimary,
            ),
            label: widget.label,
          ),
        ),
      ),
    );
  }
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
