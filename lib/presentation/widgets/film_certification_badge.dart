import 'package:flutter/material.dart';

import '../localization/app_localizations.dart';
import '../theme/app_theme.dart';

/// 详情信息使用的文字轮廓徽标。
class FilmCertificationBadge extends StatelessWidget {
  const FilmCertificationBadge({super.key, required this.rating, this.color});

  final String rating;
  final Color? color;
  static const double _fontSize = 13;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final foreground = color ?? theme.colorScheme.onSurface;
    final outlineAlpha = dark ? foreground.a * .55 : .7;
    final label = rating == 'NR'
        ? context.l10n.text('未分级')
        : context.l10n.format('影片分级：{value}', {'value': rating});
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        excludeSemantics: true,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 240),
          padding: EdgeInsets.symmetric(
            horizontal: _fontSize * .5,
            vertical: _fontSize * .16,
          ),
          decoration: BoxDecoration(
            border: Border.all(
              color: foreground.withValues(alpha: outlineAlpha),
              width: 1.4,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            rating,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge!.copyWith(
              inherit: false,
              fontFamily: dark ? 'Sarasa UI SC' : AppTheme.defaultFontFamily,
              fontFamilyFallback: dark
                  ? const [AppTheme.defaultFontFamily]
                  : const [],
              color: foreground,
              fontSize: _fontSize,
              fontWeight: dark ? FontWeight.w400 : FontWeight.w700,
              fontFeatures: dark ? const [FontFeature.tabularFigures()] : null,
              letterSpacing: .6,
              height: 1.1,
            ),
          ),
        ),
      ),
    );
  }
}
