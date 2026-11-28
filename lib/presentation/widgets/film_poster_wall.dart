import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'directory_scroll_view.dart';
import 'skeleton_scope.dart';
import 'transition_content.dart';

/// 海报墙和占位使用同一网格，单张慢图继续使用自己的图片占位。
class FilmPosterWall extends StatelessWidget {
  const FilmPosterWall({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.emptyBuilder,
    this.controller,
    this.padding = 16,
    this.itemHeight = 350,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final Widget Function(ScrollController)? emptyBuilder;
  final ScrollController? controller;
  final double padding, itemHeight;

  @override
  Widget build(BuildContext context) {
    final scrollView = DirectoryScrollView(
      controller: controller,
      builder: (scrollController) {
        if (itemCount == 0 && emptyBuilder != null) {
          return emptyBuilder!(scrollController);
        }
        return SkeletonInteractionBoundary(
          child: GridView.builder(
            controller: scrollController,
            padding: EdgeInsets.all(padding),
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              mainAxisExtent: itemHeight,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
            ),
            itemCount: itemCount,
            itemBuilder: itemBuilder,
          ),
        );
      },
    );
    if (itemCount == 0) return scrollView;
    return SkeletonScope(
      ready: true,
      enabled: !StreamPathTransitionScope.of(context),
      waitForArtwork: false,
      minimumDuration: const Duration(milliseconds: 120),
      child: scrollView,
    );
  }
}

/// 保留原文字行框及宽度，在线框中间绘制短条。
class FilmPosterLabel extends StatelessWidget {
  const FilmPosterLabel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SkeletonRegion(
      placeholder: FractionallySizedBox(
        heightFactor: .6,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Color.alphaBlend(
              theme.colorScheme.onSurface.withValues(alpha: .12),
              AppTheme.cinematicSurface(theme),
            ),
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ),
      child: child,
    );
  }
}
