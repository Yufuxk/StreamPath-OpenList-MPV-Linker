import 'directory_scroll_view.dart';
import '../localization/app_localizations.dart';
import '../../data/local/film_catalog_store.dart';
import 'film_watch_overlay.dart';
import 'dart:ui';
import 'dart:math' as math;
import 'dart:io';
import '../../data/models/film_collection.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../data/models/film_catalog_item.dart';
import '../../data/models/film_home_section.dart';
import '../../domain/services/film_catalog_image_cache.dart';
import '../localization/app_text.dart';
import '../theme/app_theme.dart';
import 'film_artwork.dart';

/// 主页支持鼠标拖动，默认最多 15 项；分类入口和演职人员可展示全部。
class FilmShelf extends StatefulWidget {
  const FilmShelf({
    super.key,
    required this.title,
    required this.count,
    required this.builder,
    this.height = defaultHeight,
    this.itemWidth = defaultItemWidth,
    this.onShowAll,
    this.horizontal = false,
    this.maxItems = 15,
  });
  static const double defaultHeight = 304;
  static const double defaultItemWidth = 174;
  static ({double width, double height, int visible}) adaptiveLayout(
    double availableWidth,
    int count, {
    double itemWidth = defaultItemWidth,
    double height = defaultHeight,
  }) {
    const spacing = 16.0;
    final capacity = math.max(
      1,
      ((availableWidth + spacing) / (itemWidth + spacing)).round(),
    );
    final visible = math.min(capacity, count);
    final width = count >= capacity
        ? (availableWidth - (capacity - 1) * spacing) / capacity
        : itemWidth;
    return (
      width: width,
      height: height * math.max(1.0, width / itemWidth),
      visible: visible,
    );
  }

  final String title;
  final int count;
  final double height, itemWidth;
  final IndexedWidgetBuilder builder;
  final VoidCallback? onShowAll;
  final bool horizontal;
  final int? maxItems;
  @override
  State<FilmShelf> createState() => _FilmShelfState();
}

class _FilmShelfState extends State<FilmShelf>
    with AutomaticKeepAliveClientMixin {
  final _scroll = ScrollController();
  @override
  bool get wantKeepAlive => !widget.horizontal;
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (widget.count == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: AppText(
                  widget.title,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontSize: 22),
                ),
              ),
              if (widget.onShowAll != null)
                TextButton(
                  onPressed: widget.onShowAll,
                  child: const AppText('查看全部'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          widget.horizontal
              ? SizedBox(
                  height: widget.height,
                  child: ScrollConfiguration(
                    behavior: const MaterialScrollBehavior().copyWith(
                      dragDevices: {
                        PointerDeviceKind.mouse,
                        PointerDeviceKind.touch,
                        PointerDeviceKind.trackpad,
                      },
                    ),
                    child: DirectoryScrollView(
                      scrollDirection: Axis.horizontal,
                      controller: _scroll,
                      hideScrollbar: true,
                      builder: (scrollController) => ListView.separated(
                        controller: scrollController,
                        scrollDirection: Axis.horizontal,
                        itemCount: widget.count,
                        separatorBuilder: (_, _) => const SizedBox(width: 16),
                        itemBuilder: (context, i) => SizedBox(
                          width: widget.itemWidth,
                          child: widget.builder(context, i),
                        ),
                      ),
                    ),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final count = widget.maxItems == null
                        ? widget.count
                        : math.min(widget.count, widget.maxItems!);
                    final layout = FilmShelf.adaptiveLayout(
                      constraints.maxWidth,
                      count,
                      itemWidth: widget.itemWidth,
                      height: widget.height,
                    );
                    final hoverInset =
                        (layout.width * (AppTheme.posterHoverScale - 1) / 2)
                            .ceilToDouble() +
                        2;
                    return SizedBox(
                      height: layout.height + 28,
                      // 扩展裁剪视口并补等量内边距，卡片原位置与宽度保持。
                      child: OverflowBox(
                        alignment: Alignment.topCenter,
                        minHeight: layout.height + 52,
                        maxHeight: layout.height + 52,
                        minWidth: constraints.maxWidth + hoverInset * 2,
                        maxWidth: constraints.maxWidth + hoverInset * 2,
                        child: GestureDetector(
                          supportedDevices: const {PointerDeviceKind.mouse},
                          onHorizontalDragUpdate: (details) => _scroll.jumpTo(
                            (_scroll.offset - details.delta.dx).clamp(
                              _scroll.position.minScrollExtent,
                              _scroll.position.maxScrollExtent,
                            ),
                          ),
                          child: DirectoryScrollView(
                            scrollDirection: Axis.horizontal,
                            controller: _scroll,
                            hideScrollbar: true,
                            builder: (scrollController) => ListView.separated(
                              controller: scrollController,
                              scrollDirection: Axis.horizontal,
                              physics: const NeverScrollableScrollPhysics(),
                              padding: EdgeInsets.fromLTRB(
                                hoverInset,
                                16,
                                hoverInset,
                                36,
                              ),
                              scrollCacheExtent: const ScrollCacheExtent.pixels(
                                0,
                              ),
                              itemCount: count,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(width: 16),
                              itemBuilder: (context, i) => SizedBox(
                                width: layout.width,
                                child: widget.builder(context, i),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ],
      ),
    );
  }
}

class FilmCategoryCard extends StatelessWidget {
  const FilmCategoryCard({
    super.key,
    required this.category,
    required this.cache,
    required this.onTap,
  });
  final FilmCategory category;
  final FilmCatalogImageCache cache;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => FilmPosterHover(
    borderRadius: BorderRadius.circular(12),
    child: Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.none,
      child: InkWell(
        hoverColor: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            FilmPosterHoverSurface(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  FilmArtwork(
                    cache: cache,
                    path: category.coverPath,
                    target: 'w780',
                    width: double.infinity,
                    height: double.infinity,
                    borderRadius: 0,
                  ),
                  const IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0x66000000),
                            Color(0x99000000),
                            Color(0xB3000000),
                          ],
                          stops: [0, .5, 1],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                child: Text(
                  category.section.categoryGroup == 'years'
                      ? context.l10n.format('{value} 年代', {
                          'value': category.section.value,
                        })
                      : context.l10n.text(category.section.value),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            Positioned(
              right: 12,
              bottom: 10,
              child: Text(
                '${category.count}',
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class FilmCollectionCard extends StatelessWidget {
  const FilmCollectionCard({
    super.key,
    required this.collection,
    required this.cache,
    required this.path,
    required this.onTap,
    this.onMenu,
  });
  final FilmCollection collection;
  final FilmCatalogImageCache cache;
  final String? path;
  final VoidCallback onTap;
  final ValueChanged<Offset>? onMenu;
  @override
  Widget build(BuildContext context) => FilmPosterHover(
    child: InkWell(
      hoverColor: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      onSecondaryTapUp: onMenu == null
          ? null
          : (details) => onMenu!(details.globalPosition),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: FilmPosterHoverSurface(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: collection.customPath == null
                    ? FilmArtwork(
                        cache: cache,
                        path: path,
                        showCachedImmediately: true,
                      )
                    : Image.file(
                        File(collection.customPath!),
                        fit: BoxFit.cover,
                        width: double.infinity,
                        cacheWidth: 342,
                        frameBuilder: filmPosterFrameBuilder,
                      ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            collection.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ],
      ),
    ),
  );
}

class FilmWorkCard extends StatefulWidget {
  const FilmWorkCard({
    super.key,
    this.store,
    this.rootId,
    this.sourceIds,
    required this.work,
    required this.cache,
    required this.onTap,
    required this.onMenu,
  });
  final FilmCatalogStore? store;
  final int? rootId;
  final Set<String>? sourceIds;
  final FilmWork work;
  final FilmCatalogImageCache cache;
  final VoidCallback onTap;
  final ValueChanged<Offset> onMenu;
  @override
  State<FilmWorkCard> createState() => _FilmWorkCardState();
}

class _FilmWorkCardState extends State<FilmWorkCard> {
  @override
  Widget build(BuildContext context) => GestureDetector(
    onSecondaryTapDown: (details) => widget.onMenu(details.globalPosition),
    child: FilmPosterHover(
      child: Card(
        margin: EdgeInsets.zero,
        color: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        clipBehavior: Clip.none,
        child: InkWell(
          hoverColor: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final defaults = DefaultTextStyle.of(context).style;
                double textHeight(String text, TextStyle style) {
                  final painter = TextPainter(
                    text: TextSpan(text: text, style: style),
                    textDirection: Directionality.of(context),
                    textScaler: MediaQuery.textScalerOf(context),
                    maxLines: 1,
                  )..layout(maxWidth: constraints.maxWidth);
                  final height = painter.height;
                  painter.dispose();
                  return height;
                }

                final textSpace =
                    8 +
                    textHeight(
                      widget.work.title,
                      defaults.merge(Theme.of(context).textTheme.titleSmall),
                    ) +
                    (widget.work.year == null
                        ? 0
                        : textHeight('${widget.work.year}', defaults)) +
                    (widget.work.missingCount > 0
                        ? textHeight(context.l10n.text('包含缺失位置'), defaults)
                        : 0);
                final posterWidth = math.min(
                  constraints.maxWidth,
                  math.max(0.0, (constraints.maxHeight - textSpace) * 2 / 3),
                );
                return Center(
                  child: SizedBox(
                    width: posterWidth,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Center(
                            child: FilmPosterHoverSurface(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: FilmWatchOverlay(
                                  store: widget.store,
                                  workId: widget.work.id,
                                  rootId: widget.rootId,
                                  sourceIds: widget.sourceIds,
                                  child: FilmArtwork(
                                    cache: widget.cache,
                                    path: widget.work.posterPath,
                                    borderRadius: 0,
                                    showCachedImmediately: true,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          widget.work.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        if (widget.work.year != null)
                          Text('${widget.work.year}'),
                        if (widget.work.missingCount > 0)
                          const AppText('包含缺失位置'),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
}

class FilmPosterGrid extends StatelessWidget {
  const FilmPosterGrid({
    super.key,
    this.store,
    this.rootId,
    this.sourceIds,
    required this.works,
    required this.cache,
    required this.onOpen,
    required this.onMenu,
    this.controller,
  });
  final FilmCatalogStore? store;
  final int? rootId;
  final Set<String>? sourceIds;
  final List<FilmWork> works;
  final FilmCatalogImageCache cache;
  final ValueChanged<FilmWork> onOpen;
  final void Function(FilmWork, Offset) onMenu;
  final ScrollController? controller;
  @override
  Widget build(BuildContext context) => DirectoryScrollView(
    controller: controller,
    builder: (scrollController) => GridView.builder(
      controller: scrollController,
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisExtent: 350,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: works.length,
      itemBuilder: (_, i) => FilmWorkCard(
        store: store,
        rootId: rootId,
        sourceIds: sourceIds,
        work: works[i],
        cache: cache,
        onTap: () => onOpen(works[i]),
        onMenu: (position) => onMenu(works[i], position),
      ),
    ),
  );
}
