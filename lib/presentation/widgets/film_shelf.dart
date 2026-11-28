import 'directory_scroll_view.dart';
import '../localization/app_localizations.dart';
import '../../data/local/film_catalog_store.dart';
import 'film_watch_overlay.dart';
import 'dart:ui';
import 'dart:math' as math;
import 'dart:io';
import 'film_connected_transition.dart';
import '../../data/models/film_collection.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../data/models/film_catalog_item.dart';
import '../../data/models/film_home_section.dart';
import '../../domain/services/film_catalog_image_cache.dart';
import '../localization/app_text.dart';
import '../theme/app_theme.dart';
import 'film_artwork.dart';
import 'film_navigation_button.dart';
import 'film_poster_wall.dart';
import 'skeleton_scope.dart';

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
    this.titleWidget,
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
  final Widget? titleWidget;
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
                child:
                    widget.titleWidget ??
                    AppText(
                      widget.title,
                      style: Theme.of(
                        context,
                      ).textTheme.titleLarge?.copyWith(fontSize: 22),
                    ),
              ),
              if (widget.onShowAll != null)
                FilmShowAllButton(onPressed: widget.onShowAll!),
            ],
          ),
          const SizedBox(height: 12),
          widget.horizontal
              ? LayoutBuilder(
                  builder: (context, constraints) {
                    // 与海报栏一致：扩出悬停放大与上浮的绘制空间，内容原位置保持。
                    final hoverInset =
                        AppTheme.posterHoverLift +
                        (widget.itemWidth * (AppTheme.posterHoverScale - 1) / 2)
                            .ceilToDouble() +
                        2;
                    return SizedBox(
                      height: widget.height,
                      child: OverflowBox(
                        alignment: Alignment.center,
                        minHeight: widget.height + hoverInset * 2,
                        maxHeight: widget.height + hoverInset * 2,
                        minWidth: constraints.maxWidth + hoverInset * 2,
                        maxWidth: constraints.maxWidth + hoverInset * 2,
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
                              padding: EdgeInsets.symmetric(
                                horizontal: hoverInset,
                                vertical: hoverInset,
                              ),
                              separatorBuilder: (_, _) =>
                                  const SizedBox(width: 16),
                              itemBuilder: (context, i) => SizedBox(
                                width: widget.itemWidth,
                                child: widget.builder(context, i),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
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
              showBorder: false,
              clipBehavior: Clip.antiAliasWithSaveLayer,
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
                    child: CustomPaint(painter: _FilmCategoryGradient()),
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
                    fontWeight: AppTheme.fontWeight(context, FontWeight.w600),
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

class _FilmCategoryGradient extends CustomPainter {
  const _FilmCategoryGradient();

  @override
  void paint(Canvas canvas, Size size) {
    // 先合成图片与渐变，再由外层圆角统一裁剪。
    canvas.drawPaint(
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x66000000), Color(0x99000000), Color(0xB3000000)],
          stops: [0, .5, 1],
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(_FilmCategoryGradient oldDelegate) => false;
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
              child: SkeletonRegion(
                borderRadius: const BorderRadius.all(Radius.circular(8)),
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
          ),
          const SizedBox(height: 8),
          FilmPosterLabel(
            child: Text(
              collection.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall,
            ),
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
    this.onOpenPoster,
  });
  final FilmCatalogStore? store;
  final int? rootId;
  final Set<String>? sourceIds;
  final FilmWork work;
  final FilmCatalogImageCache cache;
  final VoidCallback onTap;
  final ValueChanged<Offset> onMenu;
  final ValueChanged<FilmPosterAnchor?>? onOpenPoster;
  @override
  State<FilmWorkCard> createState() => _FilmWorkCardState();
}

class _FilmWorkCardState extends State<FilmWorkCard> {
  FilmPosterAnchor _poster = FilmPosterAnchor();

  @override
  void didUpdateWidget(FilmWorkCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.work.id != widget.work.id ||
        oldWidget.work.posterPath != widget.work.posterPath) {
      _poster = FilmPosterAnchor();
    }
  }

  void _open() {
    final open = widget.onOpenPoster;
    if (open == null) {
      widget.onTap();
      return;
    }
    final provider = _poster.sourceProvider;
    ImageCacheStatus? status;
    provider?.obtainKey(ImageConfiguration.empty).then((key) {
      status = PaintingBinding.instance.imageCache.statusForKey(key);
    });
    if (_poster.visible &&
        _poster.ready &&
        status != null &&
        !status!.pending &&
        (status!.live || status!.keepAlive)) {
      _poster.provider = provider;
      _poster.beginFlight(Navigator.of(context));
      _poster.prepareReturn();
      open(_poster);
    } else {
      open(null);
    }
  }

  Widget _artwork() {
    final artwork = FilmWatchOverlay(
      store: widget.store,
      workId: widget.work.id,
      rootId: widget.rootId,
      sourceIds: widget.sourceIds,
      onStatusDecoration: widget.onOpenPoster == null
          ? null
          : (decorate) => _poster.decorate = decorate,
      child: FilmArtwork(
        cache: widget.cache,
        path: widget.work.posterPath,
        borderRadius: 0,
        showCachedImmediately: true,
      ),
    );
    return widget.onOpenPoster == null
        ? artwork
        : AspectRatio(
            aspectRatio: 2 / 3,
            child: FilmSharedPoster(
              anchor: _poster,
              source: true,
              child: artwork,
            ),
          );
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    return store == null
        ? _buildCard(context)
        : ListenableBuilder(
            listenable: store,
            builder: (context, _) => _buildCard(context),
          );
  }

  Widget _buildCard(BuildContext context) => GestureDetector(
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
          onTap: _open,
          child: _FilmWorkCardLayout(
            title: widget.work.title,
            subtitle: [
              if (widget.work.year != null) '${widget.work.year}',
              if (widget.store?.showPosterContentCount == true)
                context.l10n.format(
                  widget.work.type == FilmMediaType.tv
                      ? '{count}季'
                      : '{count}项内容',
                  {
                    'count': widget.work.type == FilmMediaType.tv
                        ? widget.work.seasonCount
                        : widget.work.resourceCount,
                  },
                ),
            ].join(' · '),
            artwork: _artwork(),
          ),
        ),
      ),
    ),
  );
}

class _FilmWorkCardLayout extends StatelessWidget {
  const _FilmWorkCardLayout({
    required this.title,
    required this.subtitle,
    required this.artwork,
  });

  final String title, subtitle;
  final Widget artwork;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final defaults = DefaultTextStyle.of(context).style;
        final theme = Theme.of(context);
        final titleStyle = defaults
            .merge(theme.textTheme.titleSmall)
            .copyWith(
              fontWeight: AppTheme.fontWeight(context, FontWeight.w500),
            );
        final captionStyle = defaults.merge(theme.textTheme.bodySmall);
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
            textHeight(title, titleStyle) +
            (subtitle.isEmpty ? 0 : textHeight(subtitle, captionStyle));
        final posterWidth = math.min(
          constraints.maxWidth,
          math.max(0.0, (constraints.maxHeight - textSpace) * 2 / 3),
        );
        const radius = BorderRadius.all(Radius.circular(8));
        final poster = SkeletonRegion(
          borderRadius: radius,
          child: ClipRRect(borderRadius: radius, child: artwork),
        );
        return Center(
          child: SizedBox(
            width: posterWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Center(child: FilmPosterHoverSurface(child: poster)),
                ),
                const SizedBox(height: 8),
                FilmPosterLabel(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  ),
                ),
                if (subtitle.isNotEmpty)
                  FilmPosterLabel(
                    child: Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: captionStyle,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
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
    this.onOpenPoster,
    this.loading = false,
    this.emptyBuilder,
  });
  final FilmCatalogStore? store;
  final int? rootId;
  final Set<String>? sourceIds;
  final List<FilmWork> works;
  final FilmCatalogImageCache cache;
  final ValueChanged<FilmWork> onOpen;
  final void Function(FilmWork, Offset) onMenu;
  final ScrollController? controller;
  final void Function(FilmWork, FilmPosterAnchor?)? onOpenPoster;
  final bool loading;
  final Widget Function(ScrollController)? emptyBuilder;

  @override
  Widget build(BuildContext context) {
    if (loading && works.isEmpty) return const SizedBox.expand();
    return FilmPosterWall(
      controller: controller,
      emptyBuilder: emptyBuilder,
      itemCount: works.length,
      itemBuilder: (_, i) => FilmWorkCard(
        key: ValueKey(works[i].id),
        store: store,
        rootId: rootId,
        sourceIds: sourceIds,
        work: works[i],
        cache: cache,
        onTap: () => onOpen(works[i]),
        onOpenPoster: onOpenPoster == null
            ? null
            : (poster) => onOpenPoster!(works[i], poster),
        onMenu: (position) => onMenu(works[i], position),
      ),
    );
  }
}
