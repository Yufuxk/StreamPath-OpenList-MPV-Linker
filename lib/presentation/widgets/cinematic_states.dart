import 'package:flutter/material.dart';

import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../theme/app_theme.dart';
import '../theme/glass_tokens.dart';
import 'directory_scroll_view.dart';
import 'glass_surface.dart';

/// 固定占位上的微光呼吸，不改变加载期间的布局。
class CinematicSkeleton extends StatefulWidget {
  const CinematicSkeleton({super.key, this.showLines = true});
  final bool showLines;

  @override
  State<CinematicSkeleton> createState() => _CinematicSkeletonState();
}

class _CinematicSkeletonState extends State<CinematicSkeleton>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulse.stop();
      _pulse.value = .5;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glow = theme.colorScheme.onSurface;
    final surface = AppTheme.cinematicSurface(theme);
    return ExcludeSemantics(
      child: IgnorePointer(
        child: ClipRRect(
          borderRadius: AppTheme.panelRadius,
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (_, child) => DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: AppTheme.panelRadius,
                border: Border.all(color: glow.withValues(alpha: .10)),
                gradient: LinearGradient(
                  colors: [
                    surface,
                    Color.alphaBlend(
                      glow.withValues(
                        alpha:
                            .02 +
                            .04 * Curves.easeInOutSine.transform(_pulse.value),
                      ),
                      surface,
                    ),
                    surface,
                  ],
                ),
              ),
              child: child,
            ),
            child: widget.showLines
                ? Align(
                    alignment: Alignment.bottomLeft,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final width in [.9, .6]) ...[
                            FractionallySizedBox(
                              widthFactor: width,
                              child: Container(
                                height: 14,
                                decoration: BoxDecoration(
                                  color: glow.withValues(alpha: .08),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ),
                            if (width == .9) const SizedBox(height: 8),
                          ],
                        ],
                      ),
                    ),
                  )
                : const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

/// 加载占位复用原有滚动控制器，支持海报和列表两种现有布局。
class CinematicLoadingView extends StatelessWidget {
  const CinematicLoadingView({super.key, this.rows = false, this.controller});
  final bool rows;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) => Semantics(
    label: context.l10n.text('正在加载'),
    child: DirectoryScrollView(
      controller: controller,
      builder: (scrollController) => rows
          ? ListView.separated(
              controller: scrollController,
              padding: AppTheme.pagePadding,
              itemCount: 6,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (_, _) =>
                  const SizedBox(height: 88, child: CinematicSkeleton()),
            )
          : GridView.builder(
              controller: scrollController,
              padding: AppTheme.pagePadding,
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                mainAxisExtent: 304,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
              ),
              itemCount: 8,
              itemBuilder: (_, _) => const CinematicSkeleton(),
            ),
    ),
  );
}

class ImmersiveEmptyState extends StatelessWidget {
  const ImmersiveEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
  });
  final IconData icon;
  final String title, description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: AppTheme.pagePadding,
      child: GlassSurface(
        level: GlassSurfaceLevel.raised,
        color: theme.brightness == Brightness.dark
            ? AppTheme.cinematicSurface(theme).withValues(alpha: .25)
            : null,
        borderRadius: AppTheme.panelRadius,
        border: Border.all(
          color: theme.colorScheme.onSurface.withValues(alpha: .10),
        ),
        blur: true,
        showShadow: false,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
        child: SizedBox(
          width: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 48,
                color: theme.colorScheme.onSurface.withValues(alpha: .6),
              ),
              const SizedBox(height: 16),
              AppText(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: AppText(
                  description,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
