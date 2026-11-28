import 'dart:math' as math;

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
    this.itemBuilder,
    this.loadingPlaceholder,
    this.emptyBuilder,
    this.controller,
    this.padding = 16,
    this.itemHeight = 350,
  }) : assert(itemCount == 0 || itemBuilder != null);

  final int itemCount;
  final IndexedWidgetBuilder? itemBuilder;
  final Widget? loadingPlaceholder;
  final Widget Function(ScrollController)? emptyBuilder;
  final ScrollController? controller;
  final double padding, itemHeight;

  @override
  Widget build(BuildContext context) {
    final placeholder = loadingPlaceholder;
    final waiting = placeholder != null && itemCount == 0;
    final grid = SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 220,
      mainAxisExtent: itemHeight,
      crossAxisSpacing: 16,
      mainAxisSpacing: 16,
    );
    return SkeletonScope(
      ready: !waiting,
      enabled: !StreamPathTransitionScope.of(context),
      waitForArtwork: false,
      minimumDuration: const Duration(milliseconds: 120),
      child: DirectoryScrollView(
        controller: controller,
        hideScrollbar: waiting,
        builder: (scrollController) {
          if (!waiting && itemCount == 0 && emptyBuilder != null) {
            return emptyBuilder!(scrollController);
          }
          return LayoutBuilder(
            builder: (_, constraints) {
              final count = waiting
                  ? (constraints.maxHeight /
                                (itemHeight + grid.mainAxisSpacing))
                            .ceil() *
                        math.max<int>(
                          1,
                          ((constraints.maxWidth - 2 * padding) /
                                  (grid.maxCrossAxisExtent +
                                      grid.crossAxisSpacing))
                              .ceil(),
                        )
                  : itemCount;
              return SkeletonInteractionBoundary(
                child: GridView.builder(
                  controller: scrollController,
                  padding: EdgeInsets.all(padding),
                  gridDelegate: grid,
                  physics: waiting
                      ? const NeverScrollableScrollPhysics()
                      : null,
                  itemCount: count,
                  itemBuilder: (context, index) =>
                      waiting ? placeholder : itemBuilder!(context, index),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// 保留原文字行框及宽度，在线框中间绘制短条。
class FilmPosterLabel extends StatelessWidget {
  const FilmPosterLabel({
    super.key,
    required this.child,
    this.placeholderOnly = false,
  });

  final Widget child;
  final bool placeholderOnly;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SkeletonRegion(
      placeholderOnly: placeholderOnly,
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
