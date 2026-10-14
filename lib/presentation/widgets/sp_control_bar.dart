import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/glass_tokens.dart';
import 'glass_surface.dart';

/// 主页面共用的紧凑玻璃控制栏。
class SPControlBar extends StatelessWidget {
  const SPControlBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Theme(
    data: AppTheme.controlBarTheme(Theme.of(context)),
    child: Builder(
      builder: (context) => ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: AppTheme.controlBarMaxWidth,
        ),
        child: GlassSurface(
          level: GlassSurfaceLevel.chrome,
          borderRadius: AppTheme.panelRadius,
          border: Border.all(color: Theme.of(context).glass.borderColor),
          padding: const EdgeInsets.all(AppTheme.controlGap),
          showShadow: false,
          blur: true,
          blurSigma: GlassTokens.controlBarBlurSigma,
          child: SizedBox(width: double.infinity, child: child),
        ),
      ),
    ),
  );
}
