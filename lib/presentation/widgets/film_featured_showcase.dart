import 'transition_content.dart';
import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import '../../data/models/film_catalog_item.dart';
import '../../data/models/film_collection.dart';
import '../controllers/film_catalog_controller.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../theme/app_theme.dart';
import 'directory_scroll_view.dart';
import 'adaptive_film_backdrop.dart';
import 'film_artwork.dart';
import 'film_detail_back_button.dart';
import 'film_detail_backdrop.dart';
import 'film_detail_buttons.dart';
import 'film_segmented_control.dart';
import 'film_shelf.dart';
import 'film_watch_overlay.dart';
import 'sp_icons.dart';
import 'sp_notice.dart';

class FilmFeaturedShowcase extends StatefulWidget {
  const FilmFeaturedShowcase({
    super.key,
    required this.catalog,
    required this.onOpenWork,
    required this.onPlayWork,
    required this.onOpenCollection,
    required this.onWorkMenu,
    this.onCollectionMenu,
    this.initialSection = 'daily',
    this.works,
  });
  final FilmCatalogController catalog;
  final String initialSection;
  final List<FilmWork>? works;
  final ValueChanged<FilmWork> onOpenWork, onPlayWork;
  final ValueChanged<FilmCollection> onOpenCollection;
  final void Function(FilmWork, Offset) onWorkMenu;
  final void Function(FilmCollection, Offset)? onCollectionMenu;

  @override
  State<FilmFeaturedShowcase> createState() => _FilmFeaturedShowcaseState();
}

class _FilmFeaturedShowcaseState extends State<FilmFeaturedShowcase>
    with StreamPathTransitionState {
  late String _section;
  int? _dailyId;
  String? _collectionId;
  final _scroll = ScrollController();
  final _railScroll = ScrollController();
  final _railFocus = FocusNode();
  bool _focused = false;
  (FilmCatalogController, String)? _backgroundSelection;
  ({int workId, String? path, String? poster})? _collectionBackdrop;
  ({int workId, String? path, String? poster})? _visibleBackdrop;
  bool _collectionBackdropLoading = false;
  int _backgroundGeneration = 0;
  bool _backdropReady = false;

  Color _foreground(BuildContext context) =>
      _backdropReady && _visibleBackdrop?.path != null
      ? Colors.white
      : Theme.of(context).colorScheme.onSurface;

  List<FilmWork> get _works =>
      widget.works ?? widget.catalog.sectionWorks['daily'] ?? [];
  List<FilmCollection> get _collections => widget.catalog.collections;
  List<String> get _sections =>
      widget.works != null ? ['daily'] : _homeSections;
  List<String> get _homeSections => widget.catalog.homeSections
      .where((s) => s.enabled && (s.id == 'daily' || s.id == 'collections'))
      .map((s) => s.id)
      .toList();
  bool get _daily => _section == 'daily';
  int get _count => _daily ? _works.length : _collections.length;
  int get _index {
    final index = _daily
        ? _works.indexWhere((w) => w.id == _dailyId)
        : _collections.indexWhere((c) => c.id == _collectionId);
    return math.max(0, index);
  }

  @override
  void initState() {
    super.initState();
    _section = widget.initialSection;
  }

  @override
  void dispose() {
    _scroll.dispose();
    _railScroll.dispose();
    _railFocus.dispose();
    super.dispose();
  }

  void _scheduleCollectionBackdrop(FilmCollection? collection) {
    final selection = collection == null
        ? null
        : (widget.catalog, collection.id);
    if (_backgroundSelection == selection) return;
    _backgroundSelection = selection;
    _collectionBackdrop = null;
    _collectionBackdropLoading = collection != null;
    final generation = ++_backgroundGeneration;
    if (collection != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && generation == _backgroundGeneration) {
          unawaited(
            _loadCollectionBackdrop(widget.catalog, collection.id, generation),
          );
        }
      });
    }
  }

  Future<void> _loadCollectionBackdrop(
    FilmCatalogController catalog,
    String collectionId,
    int generation,
  ) async {
    final ok = await catalog.run(() async {
      final backdrop = await catalog.collectionBackdrop(collectionId);
      if (mounted && generation == _backgroundGeneration) {
        setState(() {
          _collectionBackdrop = backdrop;
          _collectionBackdropLoading = false;
        });
      }
    }, clearError: false);
    if (!ok && mounted && generation == _backgroundGeneration) {
      ScaffoldMessenger.of(context).showSnackBar(
        SPNotice(content: AppText(filmCatalogErrorText(catalog.error!))),
      );
    }
  }

  void _select(int index, double itemWidth) {
    if (_count == 0) return;
    setState(() {
      if (_daily) {
        _dailyId = _works[index].id;
      } else {
        _collectionId = _collections[index].id;
      }
    });
    if (_railScroll.hasClients) {
      final position = _railScroll.position;
      final start = index * (itemWidth + 16);
      final end = start + itemWidth + 8;
      final target = start < position.pixels
          ? start
          : end > position.pixels + position.viewportDimension
          ? end - position.viewportDimension
          : position.pixels;
      _railScroll.animateTo(
        target.clamp(0.0, position.maxScrollExtent),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
  }

  KeyEventResult _key(KeyEvent event, double itemWidth) {
    if (event is KeyUpEvent || _count == 0) return KeyEventResult.ignored;
    final next = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowLeft => math.max(0, _index - 1),
      LogicalKeyboardKey.arrowRight => math.min(_count - 1, _index + 1),
      LogicalKeyboardKey.home => 0,
      LogicalKeyboardKey.end => _count - 1,
      _ => null,
    };
    if (next == null) return KeyEventResult.ignored;
    _select(next, itemWidth);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => StreamPathTransitionBuilder(
    listenable: widget.catalog,
    builder: (context) {
      final sections = _sections;
      final topInset = MediaQuery.paddingOf(context).top;
      final backButton = Positioned(
        top: topInset - 10,
        left: 4,
        child: FilmDetailBackButton(scrollController: _scroll),
      );
      if (sections.isEmpty) return Stack(children: [backButton]);
      if (!sections.contains(_section)) _section = sections.first;
      final work = _daily && _count > 0 ? _works[_index] : null;
      final collection = !_daily && _count > 0 ? _collections[_index] : null;
      _scheduleCollectionBackdrop(collection);
      if (_daily) {
        _visibleBackdrop = work == null
            ? null
            : (
                workId: work.id,
                path: work.backdropPath,
                poster: work.posterPath,
              );
      } else if (!_collectionBackdropLoading) {
        _visibleBackdrop = _collectionBackdrop;
      }
      return LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 640;
          final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
          final compact = constraints.maxHeight < 750;
          final railWidth = constraints.maxWidth - (narrow ? 32 : 48);
          final layout = FilmShelf.adaptiveLayout(
            railWidth - 8,
            widget.works == null
                ? _count
                : (widget.catalog.sectionWorks['daily'] ?? []).length,
          );
          final itemWidth = layout.width;
          final railPadding = math.max(
            4.0,
            (railWidth - (_count * itemWidth + math.max(0, _count - 1) * 16)) /
                2,
          );

          return Stack(
            children: [
              Positioned.fill(
                child: FilmDetailBackdrop(
                  key: const Key('featured-fullscreen-backdrop'),
                  artworkKey: const Key('featured-backdrop-artwork'),
                  catalog: widget.catalog,
                  workId: _visibleBackdrop?.workId,
                  path: _visibleBackdrop?.path,
                  style: FilmBackdropStyle.showcase,
                  onImageReady: () {
                    if (mounted && !_backdropReady) {
                      setState(() => _backdropReady = true);
                    }
                  },
                ),
              ),
              Positioned.fill(
                child: DirectoryScrollView(
                  controller: _scroll,
                  hideScrollbar: true,
                  builder: (controller) => CustomScrollView(
                    controller: controller,
                    slivers: [
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          narrow ? 16 : 24,
                          topInset +
                              (_homeSections.length > 1 ? 52 * scale + 12 : 40),
                          narrow ? 16 : 24,
                          0,
                        ),
                        sliver: SliverFillRemaining(
                          hasScrollBody: false,
                          child: _count == 0
                              ? Center(
                                  child: AppText(_daily ? '暂无每日精选' : '暂无合集'),
                                )
                              : Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Expanded(
                                      child: _hero(context, narrow, compact),
                                    ),
                                    const SizedBox(height: 12),
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 16,
                                      ),
                                      child: _rail(
                                        context,
                                        scale,
                                        layout,
                                        railPadding,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (sections.length > 1)
                Positioned(
                  top: topInset + 12,
                  right: narrow ? 16 : 24,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: math.max(0, constraints.maxWidth - 96),
                    ),
                    child: FilmSegmentedControl<String>(
                      segments: [
                        for (final section in sections)
                          ButtonSegment(
                            value: section,
                            label: AppText(section == 'daily' ? '每日精选' : '合集'),
                          ),
                      ],
                      selected: _section,
                      onSelectionChanged: (selection) {
                        setState(() => _section = selection);
                        if (_railScroll.hasClients) _railScroll.jumpTo(0);
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) _select(_index, itemWidth);
                        });
                      },
                    ),
                  ),
                ),
              backButton,
            ],
          );
        },
      );
    },
  );

  Widget _rail(
    BuildContext context,
    double scale,
    ({double width, double height, int visible}) layout,
    double railPadding,
  ) {
    final coverHeight = layout.width * 1.5;
    final topInset = math.max(
      16.0,
      (AppTheme.posterHoverLift +
              coverHeight * ((AppTheme.posterHoverScale - 1) / 2 + .018) +
              2)
          .ceilToDouble(),
    );
    return Column(
      key: const Key('featured-poster-rail'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Focus(
          focusNode: _railFocus,
          onFocusChange: (value) => setState(() => _focused = value),
          onKeyEvent: (_, event) => _key(event, layout.width),
          child: SizedBox(
            height: math.max(
              layout.height,
              coverHeight + 52 * scale + topInset + 8,
            ),
            child: DirectoryScrollView(
              controller: _railScroll,
              scrollDirection: Axis.horizontal,
              hideScrollbar: true,
              builder: (controller) => ListView.separated(
                key: ValueKey(_section),
                controller: controller,
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.fromLTRB(
                  railPadding,
                  topInset,
                  railPadding,
                  8,
                ),
                itemCount: _count,
                separatorBuilder: (_, _) => const SizedBox(width: 16),
                itemBuilder: (_, index) =>
                    _poster(context, index, layout.width),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _hero(BuildContext context, bool narrow, bool compact) {
    final work = _daily ? _works[_index] : null;
    final collection = _daily ? null : _collections[_index];
    final titleSize = narrow
        ? 30.0
        : compact
        ? 32.0
        : 40.0;
    final metadata = <String>[
      if (work?.year != null) '${work!.year}',
      if (work != null)
        context.l10n.text(work.type == FilmMediaType.movie ? '电影' : '剧集'),
      if (work?.metadata['genres'] is List)
        for (final genre in (work!.metadata['genres'] as List).take(3))
          if (genre is String && genre.isNotEmpty)
            genre
          else if (genre is Map &&
              genre['name'] is String &&
              (genre['name'] as String).isNotEmpty)
            genre['name'] as String,
      if ((work?.metadata['runtime'] as num? ?? 0) > 0)
        context.l10n.format('官方时长：{minutes} 分钟', {
          'minutes': work!.metadata['runtime'],
        }),
      if ((work?.metadata['vote_average'] as num? ?? 0) > 0)
        '★ ${(work!.metadata['vote_average'] as num).toStringAsFixed(1)}',
      if (collection != null)
        context.l10n.format('收录 {count} 部作品', {'count': collection.count}),
    ];
    final identity = work?.id ?? collection!.id;
    final title = Text(
      work?.title ?? collection!.name,
      key: ValueKey<Object>(('featured-title', identity)),
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: titleSize,
        height: 1.2,
        fontWeight: FontWeight.w700,
        color: _foreground(context),
      ),
    );
    final logo = work?.metadata['logo_path'] as String?;
    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: narrow ? 8 : 24,
            vertical: 12,
          ),
          child: Column(
            key: const Key('featured-information'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (logo != null && logo.isNotEmpty)
                Center(
                  child: FilmArtwork(
                    key: const Key('featured-logo'),
                    cache: widget.catalog.images,
                    path: logo,
                    target: 'original',
                    transparent: true,
                    logoGlyphSize: titleSize * 1.6,
                    width: 420,
                    height: 220,
                    placeholder: Center(child: title),
                  ),
                )
              else
                title,
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [
                  if (work != null)
                    FilmDetailPlayButton(
                      buttonKey: const ValueKey('featured-play'),
                      onPressed: work.resourceCount > work.missingCount
                          ? () => widget.onPlayWork(work)
                          : null,
                      label: const AppText('播放'),
                    ),
                  FilmDetailActionButton(
                    buttonKey: const ValueKey('featured-open'),
                    icon: const Icon(SPIcons.chevronRight),
                    onPressed: () => work != null
                        ? widget.onOpenWork(work)
                        : widget.onOpenCollection(collection!),
                    label: AppText(work == null ? '查看合集' : '查看详情'),
                  ),
                ],
              ),
              if (metadata.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  metadata.join(' · '),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, color: _foreground(context)),
                ),
              ],
              if (work != null && work.overview.isNotEmpty) ...[
                const SizedBox(height: 16),
                FilmSpoilerScope(
                  key: ValueKey<Object>(('featured-overview', identity)),
                  child: FilmWatchOverlay(
                    store: widget.catalog.store,
                    workId: work.id,
                    rootId: widget.catalog.rootId,
                    sourceIds: widget.catalog.sourceId == null
                        ? null
                        : {widget.catalog.sourceId!},
                    spoilerSensitive: true,
                    showStatus: false,
                    revealBelow: true,
                    child: Text(
                      work.overview,
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.6,
                        color: _foreground(context),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _poster(BuildContext context, int index, double width) {
    final scheme = Theme.of(context).colorScheme;
    final work = _daily ? _works[index] : null;
    final collection = _daily ? null : _collections[index];
    final title = work?.title ?? collection!.name;
    final selected = index == _index;
    return SizedBox(
      width: width,
      child: FilmPosterHover(
        child: Semantics(
          selected: selected,
          button: true,
          label: title,
          child: GestureDetector(
            onSecondaryTapUp: (details) => work != null
                ? widget.onWorkMenu(work, details.globalPosition)
                : collection!.readOnly
                ? null
                : widget.onCollectionMenu?.call(
                    collection,
                    details.globalPosition,
                  ),
            child: InkWell(
              hoverColor: Colors.transparent,
              key: ValueKey<Object>((
                'featured-poster',
                work?.id ?? collection!.id,
              )),
              borderRadius: BorderRadius.circular(9),
              onTap: () {
                _railFocus.requestFocus();
                _select(index, width);
              },
              child: RawGestureDetector(
                gestures: {
                  SerialTapGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        SerialTapGestureRecognizer
                      >(
                        () => SerialTapGestureRecognizer(
                          allowedButtonsFilter: (buttons) =>
                              buttons == kPrimaryMouseButton,
                        ),
                        (recognizer) => recognizer.onSerialTapUp = (details) {
                          _railFocus.requestFocus();
                          _select(index, width);
                          if (details.count == 2) {
                            if (work != null) {
                              widget.onOpenWork(work);
                            } else {
                              widget.onOpenCollection(collection!);
                            }
                          }
                        },
                      ),
                },
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AnimatedSlide(
                      offset: selected ? const Offset(0, -.018) : Offset.zero,
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                      child: FilmPosterHoverSurface(
                        borderRadius: BorderRadius.circular(9),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(9),
                            border: Border.all(
                              color: selected
                                  ? _focused
                                        ? scheme.onPrimaryContainer
                                        : scheme.primary
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: FilmArtwork(
                              cache: widget.catalog.images,
                              path:
                                  work?.posterPath ??
                                  widget.catalog.collectionCovers[collection
                                      ?.id],
                              height: width * 1.5 - 8,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: _foreground(context),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
