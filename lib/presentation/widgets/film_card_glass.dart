import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/glass_tokens.dart';
import 'glass_surface.dart';

/// 连续玻璃底板承接封面圆角与悬停上浮，前景保持独立绘制。
class FilmCardGlass extends StatelessWidget {
  const FilmCardGlass({super.key, required this.child, this.enabled = true});

  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) => !enabled
      ? child
      : Stack(
          fit: StackFit.passthrough,
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: GlassSurface(
                  level: GlassSurfaceLevel.raised,
                  borderRadius: AppTheme.panelRadius,
                  automaticBorder: false,
                  showShadow: false,
                  blur: true,
                  blurSigma: GlassTokens.panelBlurSigma,
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerLow.withValues(alpha: .68),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            child,
          ],
        );
}
