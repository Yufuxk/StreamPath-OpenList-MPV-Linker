import 'directory_scroll_view.dart';
import '../localization/app_localizations.dart';
import '../../data/local/film_catalog_store.dart';
import 'film_watch_overlay.dart';
import 'dart:ui';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/models/film_catalog_item.dart';
import '../../domain/services/film_catalog_image_cache.dart';
import '../localization/app_text.dart';
import 'film_artwork.dart';

/// 主页展示一行可见卡片；演职人员可显式开启横向拖动。
class FilmShelf extends StatefulWidget {
  const FilmShelf({
    super.key,
    required this.title,
    required this.count,
    required this.builder,
    this.height = 304,
    this.itemWidth = 174,
    this.onShowAll,
    this.horizontal = false,
  });
  final String title;
  final int count;
  final double height, itemWidth;
  final IndexedWidgetBuilder builder;
  final VoidCallback? onShowAll;
  final bool horizontal;
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
                  style: Theme.of(context).textTheme.titleLarge,
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
                  child: ShaderMask(
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (bounds) => LinearGradient(
                      colors: const [
                        Colors.white,
                        Colors.white,
                        Colors.transparent,
                      ],
                      stops: [0, (1 - 32 / bounds.width).clamp(0.0, 1.0), 1],
                    ).createShader(bounds),
                    child: ScrollConfiguration(
                      behavior: const MaterialScrollBehavior().copyWith(
                        dragDevices: {
                          PointerDeviceKind.mouse,
                          PointerDeviceKind.touch,
                          PointerDeviceKind.trackpad,
                        },
                      ),
                      child: DirectoryScrollView(
                        controller: _scroll,
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
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    const spacing = 16.0;
                    final capacity = math.max(
                      1,
                      ((constraints.maxWidth + spacing) /
                              (widget.itemWidth + spacing))
                          .round(),
                    );
                    final visible = math.min(capacity, widget.count);
                    final fillsRow = widget.count >= capacity;
                    final width = fillsRow
                        ? (constraints.maxWidth - (capacity - 1) * spacing) /
                              capacity
                        : widget.itemWidth;
                    // 保留文字区高度；扩大卡片时同步增加封面空间。
                    final height =
                        widget.height * math.max(1.0, width / widget.itemWidth);
                    return SizedBox(
                      height: height,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < visible; i++) ...[
                            if (i > 0) const SizedBox(width: spacing),
                            SizedBox(
                              width: width,
                              child: widget.builder(context, i),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
        ],
      ),
    );
  }
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
  bool _hovered = false;
  @override
  Widget build(BuildContext context) => GestureDetector(
    onSecondaryTapDown: (details) => widget.onMenu(details.globalPosition),
    child: Card(
      margin: EdgeInsets.zero,
      color: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          precacheFilmDetailArtwork(context, widget.cache, widget.work);
          widget.onTap();
        },
        onHover: (value) {
          setState(() => _hovered = value);
          if (value) {
            precacheFilmDetailArtwork(context, widget.cache, widget.work);
          }
        },
        onFocusChange: (value) {
          if (value) {
            precacheFilmDetailArtwork(context, widget.cache, widget.work);
          }
        },
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
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: AnimatedScale(
                              scale: _hovered ? 1.04 : 1,
                              duration: const Duration(milliseconds: 160),
                              child: FilmWatchOverlay(
                                store: widget.store,
                                workId: widget.work.id,
                                rootId: widget.rootId,
                                sourceIds: widget.sourceIds,
                                child: FilmArtwork(
                                  cache: widget.cache,
                                  path: widget.work.posterPath,
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
                      if (widget.work.year != null) Text('${widget.work.year}'),
                      if (widget.work.missingCount > 0) const AppText('包含缺失位置'),
                    ],
                  ),
                ),
              );
            },
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
