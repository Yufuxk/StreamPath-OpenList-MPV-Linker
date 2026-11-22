import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/glass_tokens.dart';
import 'glass_surface.dart';

/// 作品信息胶囊；详情页与橱窗共用同一材质与内边距。
class FilmInformationPill extends StatelessWidget {
  const FilmInformationPill({
    super.key,
    required this.foreground,
    required this.child,
  });

  final Color foreground;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final label = theme.textTheme.labelMedium!.copyWith(
      color: foreground,
      fontWeight: dark ? AppTheme.fontWeight(context, FontWeight.w400) : null,
      fontFeatures: dark ? const [FontFeature.tabularFigures()] : null,
    );
    return GlassSurface(
      level: GlassSurfaceLevel.content,
      borderRadius: AppTheme.pillRadius,
      border: Border.all(color: foreground.withValues(alpha: .14)),
      color: theme.colorScheme.surface.withValues(alpha: .18),
      showShadow: false,
      blur: true,
      blurSigma: 10,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      child: DefaultTextStyle(style: label, child: child),
    );
  }
}
