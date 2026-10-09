import 'dart:async';
import 'package:flutter/material.dart';
import '../../data/local/film_catalog_store.dart';
import '../../data/models/film_catalog_item.dart';
import '../../data/models/film_collection.dart';
import '../../data/models/media_library_item.dart';
import '../controllers/film_catalog_controller.dart';
import '../localization/app_text.dart';
import '../widgets/film_shelf.dart';
import '../widgets/film_work_menu.dart';
import 'package:provider/provider.dart';
import '../widgets/film_library_background.dart';
import '../widgets/window_title_bar.dart';
import '../widgets/directory_scroll_view.dart';
import 'film_detail_page.dart';

/// 关联页面只查询当前库内作品，保留上一页面的状态树和滚动位置。
class FilmRelatedPage extends StatefulWidget {
  const FilmRelatedPage({
    super.key,
    required this.catalog,
    required this.title,
    required this.onOpenItem,
    this.collection,
    this.personId,
    this.showCollections = false,
    this.onCollectionMenu,
    this.onContinueSelected,
    this.onContinueMenu,
    this.sidebarInset = WindowTitleBar.compactSidebarWidth,
  });
  final FilmCatalogController catalog;
  final String title;
  final FilmCollection? collection;
  final String? personId;
  final bool showCollections;
  final void Function(FilmCollection, Offset)? onCollectionMenu;
  final Future<void> Function(MediaLibraryItem) onOpenItem;
  final ValueChanged<MediaLibraryRecord>? onContinueSelected;
  final void Function(MediaLibraryRecord, Offset)? onContinueMenu;
  final double sidebarInset;
  @override
  State<FilmRelatedPage> createState() => _FilmRelatedPageState();
}

class _FilmRelatedPageState extends State<FilmRelatedPage> {
  final _scroll = ScrollController();
  List<FilmWork> _works = [];
  bool _loading = false, _more = true;
  int _generation = 0;
  Timer? _reloadTimer;
  bool _reloadPending = false;
  @override
  void initState() {
    super.initState();
    _scroll.addListener(_prefetch);
    widget.catalog.store.addListener(_changed);
    _load();
  }

  void _changed() {
    if (widget.showCollections || _reloadTimer?.isActive == true) return;
    _reloadTimer = Timer(const Duration(milliseconds: 150), () {
      if (_loading) {
        _reloadPending = true;
      } else {
        unawaited(_load());
      }
    });
  }

  void _prefetch() {
    if (_scroll.hasClients &&
        _scroll.position.extentAfter < 900 &&
        !_loading &&
        _more) {
      _load(more: true);
    }
  }

  Future<void> _load({bool more = false}) async {
    if (widget.showCollections) return;
    final generation = ++_generation;
    _loading = true;
    final rows = await widget.catalog.store.works(
      type: null,
      collectionId: widget.collection?.id,
      personId: widget.personId,
      sourceId: widget.catalog.sourceId,
      offset: more ? _works.length : 0,
      limit: more ? 60 : (_works.length < 60 ? 60 : _works.length),
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      _works = more ? [..._works, ...rows] : rows;
      _more = rows.length >= 60;
      _loading = false;
    });
    if (_reloadPending) {
      _reloadPending = false;
      _changed();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prefetch();
    });
  }

  @override
  void dispose() {
    _reloadTimer?.cancel();
    widget.catalog.store.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.catalog,
    builder: (context, _) => Stack(
      children: [
        Positioned.fill(
          child: ExcludeSemantics(
            child: IgnorePointer(
              child: FilmLibraryBackground(file: widget.catalog.backgroundFile),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.only(left: widget.sidebarInset),
          child: _page(context),
        ),
      ],
    ),
  );

  Widget _page(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    appBar: AppBar(
      toolbarHeight: 48,
      automaticallyImplyLeading: false,
      backgroundColor: Colors.transparent,
      shape: const Border(),
      title: widget.showCollections ? const AppText('合集') : Text(widget.title),
    ),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Align(
              alignment: Alignment.centerLeft,
              heightFactor: 1,
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const AppText('主页'),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: widget.showCollections
              ? DirectoryScrollView(
                  controller: _scroll,
                  builder: (controller) => GridView.builder(
                    controller: controller,
                    padding: const EdgeInsets.all(16),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 220,
                          mainAxisExtent: 350,
                          crossAxisSpacing: 16,
                          mainAxisSpacing: 16,
                        ),
                    itemCount: widget.catalog.collections.length,
                    itemBuilder: (_, index) {
                      final collection = widget.catalog.collections[index];
                      return FilmCollectionCard(
                        collection: collection,
                        cache: widget.catalog.images,
                        path: widget.catalog.collectionCovers[collection.id],
                        onMenu: collection.readOnly
                            ? null
                            : (position) => widget.onCollectionMenu?.call(
                                collection,
                                position,
                              ),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => FilmRelatedPage(
                              catalog: widget.catalog,
                              title: collection.name,
                              collection: collection,
                              sidebarInset: widget.sidebarInset,
                              onOpenItem: widget.onOpenItem,
                              onContinueSelected: widget.onContinueSelected,
                              onContinueMenu: widget.onContinueMenu,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                )
              : FilmPosterGrid(
                  controller: _scroll,
                  store: widget.catalog.store,
                  rootId: widget.catalog.rootId,
                  sourceIds: widget.catalog.sourceId == null
                      ? null
                      : {widget.catalog.sourceId!},
                  works: _works,
                  cache: widget.catalog.images,
                  onOpen: (work) async {
                    final chrome = context.read<ValueNotifier<double?>?>();
                    chrome?.value = 0;
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => FilmDetailPage(
                          catalog: widget.catalog,
                          workId: work.id,
                          initialWork: work,
                          onOpenItem: widget.onOpenItem,
                          onContinueSelected: widget.onContinueSelected,
                          onContinueMenu: widget.onContinueMenu,
                        ),
                      ),
                    );
                    if (mounted) chrome?.value = null;
                  },
                  onMenu: (work, position) async {
                    final collection = widget.collection;
                    await showFilmWorkMenu(
                      context,
                      catalog: widget.catalog,
                      work: work,
                      position: position,
                      onRemove: collection != null && !collection.readOnly
                          ? () => widget.catalog.store.removeCollectionMember(
                              collection.id,
                              work.id,
                            )
                          : null,
                    );
                  },
                ),
        ),
      ],
    ),
  );
}
