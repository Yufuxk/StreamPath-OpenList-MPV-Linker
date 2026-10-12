import '../widgets/transition_content.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/film_catalog_item.dart';
import '../../data/models/film_collection.dart';
import '../../data/models/media_library_item.dart';
import '../controllers/film_catalog_controller.dart';
import '../localization/app_text.dart';
import '../state/app_state.dart';
import '../widgets/film_featured_showcase.dart';
import '../widgets/film_work_menu.dart';
import '../widgets/sp_notice.dart';
import 'film_detail_page.dart';

class FilmFeaturedPage extends StatefulWidget {
  const FilmFeaturedPage({
    super.key,
    required this.catalog,
    required this.initialSection,
    required this.onOpenItem,
    required this.onOpenWork,
    this.onCollectionMenu,
    this.onContinueSelected,
    this.onContinueMenu,
    this.sidebarInset = 0,
    this.collection,
    this.initialWorks = const [],
  });
  final FilmCatalogController catalog;
  final String initialSection;
  final Future<void> Function(MediaLibraryItem) onOpenItem;
  final ValueChanged<FilmWork> onOpenWork;
  final void Function(FilmCollection, Offset)? onCollectionMenu;
  final ValueChanged<MediaLibraryRecord>? onContinueSelected;
  final void Function(MediaLibraryRecord, Offset)? onContinueMenu;
  final double sidebarInset;
  final FilmCollection? collection;
  final List<FilmWork> initialWorks;

  @override
  State<FilmFeaturedPage> createState() => _FilmFeaturedPageState();
}

class _FilmFeaturedPageState extends State<FilmFeaturedPage>
    with StreamPathTransitionState {
  bool _playing = false;
  bool _loadingMembers = false;
  late List<FilmWork> _members;
  int _memberGeneration = 0;
  MaterialPageRoute<void>? _collectionRoute;

  @override
  void initState() {
    super.initState();
    _members = widget.initialWorks;
    if (widget.collection != null) {
      widget.catalog.store.addListener(_reloadMembers);
      if (widget.initialWorks.isEmpty) {
        _loadingMembers = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _reloadMembers();
        });
      }
    }
  }

  Future<void> _reloadMembers() async {
    final generation = ++_memberGeneration;
    final ok = await widget.catalog.run(() async {
      final members = await widget.catalog.store.works(
        type: null,
        collectionId: widget.collection!.id,
        sourceId: widget.catalog.sourceId,
        limit: -1,
      );
      if (mounted && generation == _memberGeneration) {
        setState(() {
          _members = members;
          _loadingMembers = false;
        });
      }
    });
    if (!ok && mounted && generation == _memberGeneration) {
      setState(() => _loadingMembers = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SPNotice(content: AppText(filmCatalogErrorText(widget.catalog.error!))),
      );
    }
  }

  @override
  void dispose() {
    if (widget.collection != null) {
      widget.catalog.store.removeListener(_reloadMembers);
    }
    super.dispose();
  }

  Future<void> _play(FilmWork work) async {
    if (_playing) return;
    _playing = true;
    try {
      final resources = await widget.catalog.store.resources(
        workId: work.id,
        sourceId: widget.catalog.sourceId,
        enabledOnly: true,
      );
      if (!mounted) return;
      final resource = recommendedFilmResource(
        context.read<AppState>(),
        work,
        resources,
      );
      if (resource == null) {
        throw const FilmCatalogException('sourceUnavailable');
      }
      await widget.onOpenItem(resource.playbackItem);
    } on FilmCatalogException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SPNotice(content: AppText(filmCatalogErrorText(error.code))),
        );
      }
    } finally {
      _playing = false;
    }
  }

  Future<void> _openCollection(FilmCollection collection) async {
    final chrome = context.read<ValueNotifier<double?>?>();
    chrome?.value = 0;
    final route = MaterialPageRoute<void>(
      builder: (_) => StreamPathTransitionContent(
        shellBuilder: (_) => const StreamPathPageShell(),
        contentBuilder: (_) => FilmFeaturedPage(
          catalog: widget.catalog,
          initialSection: 'daily',
          collection: collection,
          sidebarInset: widget.sidebarInset,
          onOpenItem: widget.onOpenItem,
          onOpenWork: widget.onOpenWork,
          onContinueSelected: widget.onContinueSelected,
          onContinueMenu: widget.onContinueMenu,
        ),
      ),
    );
    _collectionRoute = route;
    await Navigator.of(context).push(route);
    await route.completed;
    if (mounted &&
        _collectionRoute == route &&
        ModalRoute.of(context)?.isActive == true) {
      _collectionRoute = null;
      chrome?.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) => _loadingMembers
      ? const StreamPathPageShell()
      : Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          body: FilmFeaturedShowcase(
            catalog: widget.catalog,
            initialSection: widget.initialSection,
            works: widget.collection == null ? null : _members,
            onOpenWork: widget.onOpenWork,
            onPlayWork: _play,
            onOpenCollection: _openCollection,
            onWorkMenu: (work, position) => showFilmWorkMenu(
              context,
              catalog: widget.catalog,
              work: work,
              position: position,
            ),
            onCollectionMenu: widget.onCollectionMenu,
          ),
        );
}
