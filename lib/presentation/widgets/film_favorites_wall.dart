import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/film_catalog_item.dart';
import '../../data/models/media_library_item.dart';
import '../controllers/film_catalog_controller.dart';
import '../localization/app_text.dart';
import '../pages/film_detail_page.dart';
import 'film_shelf.dart';
import 'film_work_menu.dart';

class FilmFavoritesWall extends StatefulWidget {
  const FilmFavoritesWall({
    super.key,
    required this.onOpenItem,
    required this.loadCatalog,
    this.sourceIds,
    this.query = '',
  });
  final Future<void> Function(MediaLibraryItem) onOpenItem;
  final Future<FilmCatalogController> Function() loadCatalog;
  final Set<String>? sourceIds;
  final String query;
  @override
  State<FilmFavoritesWall> createState() => _FilmFavoritesWallState();
}

class _FilmFavoritesWallState extends State<FilmFavoritesWall> {
  FilmCatalogController? _catalog;
  List<FilmWork> _works = [];
  final _scroll = ScrollController();
  bool _loading = true, _more = false;
  int _generation = 0, _limit = 60;
  String? _error;
  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_more && !_loading && _scroll.position.extentAfter < 700) {
        _limit += 60;
        _load();
      }
    });
    widget.loadCatalog().then(
      (catalog) {
        if (!mounted) return;
        _catalog = catalog;
        catalog.store.addListener(_load);
        _load();
      },
      onError: (Object _, StackTrace _) {
        if (mounted) {
          setState(() {
            _error = '影视目录库操作失败';
            _loading = false;
          });
        }
      },
    );
  }

  @override
  void didUpdateWidget(FilmFavoritesWall oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!setEquals(widget.sourceIds, oldWidget.sourceIds) ||
        widget.query != oldWidget.query) {
      _limit = 60;
      _works = [];
      _load();
    }
  }

  @override
  void dispose() {
    _generation++;
    _catalog?.store.removeListener(_load);
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final c = _catalog;
    if (c == null) return;
    final generation = ++_generation;
    _loading = true;
    List<FilmWork> works = [];
    final ok = await c.run(() async {
      works = await c.store.works(
        type: null,
        favoritesOnly: true,
        sourceIds: widget.sourceIds,
        query: widget.query,
        limit: _limit,
      );
    });
    if (!mounted || generation != _generation) return;
    setState(() {
      _loading = false;
      _error = ok ? null : '影视目录库操作失败';
      if (ok) {
        _works = works;
        _more = works.length == _limit;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: AppText(_error!));
    if (_loading && _catalog == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_works.isEmpty) return const Center(child: AppText('还没有收藏媒体'));
    return FilmPosterGrid(
      store: _catalog!.store,
      sourceIds: widget.sourceIds,
      works: _works,
      cache: _catalog!.images,
      controller: _scroll,
      onMenu: (work, position) => showFilmWorkMenu(
        context,
        catalog: _catalog!,
        work: work,
        position: position,
      ),
      onOpen: (work) async {
        final chrome = context.read<ValueNotifier<double?>?>();
        chrome?.value = 0;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => FilmDetailPage(
              catalog: _catalog!,
              workId: work.id,
              initialWork: work,
              onOpenItem: widget.onOpenItem,
            ),
          ),
        );
        if (mounted) chrome?.value = null;
      },
    );
  }
}
