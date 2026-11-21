import 'package:flutter/material.dart';

import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../theme/app_theme.dart';
import 'film_detail_buttons.dart';
import 'sp_back_icon.dart';
import 'sp_controls.dart';

class FilmNavigationBackButton extends StatelessWidget {
  const FilmNavigationBackButton({
    super.key,
    required this.onPressed,
    this.tooltip = '返回',
  }) : _toolbarHeight = null;

  const FilmNavigationBackButton.toolbar({
    super.key,
    required this.onPressed,
    required double height,
  }) : tooltip = '主页',
       _toolbarHeight = height;

  final VoidCallback onPressed;
  final String tooltip;
  final double? _toolbarHeight;

  @override
  Widget build(BuildContext context) {
    final message = context.l10n.text(tooltip);
    if (_toolbarHeight case final height?) {
      return Tooltip(
        message: message,
        child: SizedBox.square(
          dimension: height,
          child: SPButton(
            onPressed: onPressed,
            padding: EdgeInsets.zero,
            minimumHeight: height,
            label: const SizedBox.square(dimension: 22, child: SPBackIcon()),
          ),
        ),
      );
    }
    final surfaceStyle = FilmDetailActionButton.styleOf(context);
    return SizedBox.square(
      dimension: AppTheme.controlHeight,
      child: FilmDetailActionSurface(
        radius: AppTheme.controlRadius.topLeft.x,
        child: IconButton(
          onPressed: onPressed,
          tooltip: message,
          iconSize: 22,
          style: ButtonStyle(
            backgroundColor: surfaceStyle.backgroundColor,
            foregroundColor: surfaceStyle.foregroundColor,
            side: surfaceStyle.side,
            shape: const WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: AppTheme.controlRadius),
            ),
          ),
          icon: const SPBackIcon(),
        ),
      ),
    );
  }
}

class FilmShowAllButton extends StatelessWidget {
  const FilmShowAllButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = WidgetStateProperty.resolveWith<Color>((states) {
      final active =
          states.contains(WidgetState.hovered) ||
          states.contains(WidgetState.pressed) ||
          states.contains(WidgetState.focused);
      return active ? scheme.onSurface : scheme.onSurfaceVariant;
    });
    return TextButton(
      onPressed: onPressed,
      style: ButtonStyle(foregroundColor: foreground, iconColor: foreground),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: AppText('查看全部')),
          SizedBox(width: 4),
          RotatedBox(
            quarterTurns: 2,
            child: SizedBox.square(dimension: 12, child: SPBackIcon()),
          ),
        ],
      ),
    );
  }
}
