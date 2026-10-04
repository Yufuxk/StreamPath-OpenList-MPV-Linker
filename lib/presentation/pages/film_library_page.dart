import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/film_catalog_item.dart';
import '../../data/models/film_home_section.dart';
import '../../data/models/media_library_item.dart';
import '../controllers/film_catalog_controller.dart';
import '../widgets/film_catalog_tasks.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/sp_icons.dart';
import 'film_detail_page.dart';
import '../widgets/film_shelf.dart';
import '../widgets/film_work_menu.dart';
import '../widgets/film_artwork_picker.dart';
import '../widgets/film_section_settings.dart';
import '../widgets/film_library_background.dart';
import '../widgets/directory_scroll_view.dart';
import 'film_library_manage_page.dart';
import 'global_media_library_page.dart';

class FilmLibraryPage extends StatefulWidget {
  const FilmLibraryPage({
    super.key,
    required this.onOpenItem,
    this.sidebarInset = 0,
    this.continueShelf,
    this.onContinueSelected,
    this.onContinueMenu,
  });
  final Future<void> Function(MediaLibraryItem) onOpenItem;
  final double sidebarInset;
  final Widget? continueShelf;
  final ValueChanged<MediaLibraryRecord>? onContinueSelected;
  final void Function(MediaLibraryRecord, Offset)? onContinueMenu;
  @override
  State<FilmLibraryPage> createState() => _FilmLibraryPageState();
}

class _FilmLibraryPageState extends State<FilmLibraryPage> {
  late Future<FilmCatalogController> _catalog;
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _homeScroll = ScrollController();
  FilmCatalogController? _controller;
  bool _prefetchScheduled = false;
  bool _browse = false;
  bool _startupFrameScheduled = false;
  @override
  void initState() {
    super.initState();
    _scroll.addListener(_loadMore);
    _catalog = context.read<AppState>().getFilmCatalog().then((c) async {
      await c.refresh();
      if (mounted) _controller = c;
      return c;
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    _homeScroll.dispose();
    super.dispose();
  }

  void _schedulePrefetch() {
    if (_prefetchScheduled) return;
    _prefetchScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _prefetchScheduled = false;
      _loadMore();
    });
  }

  void _loadMore() {
    final c = _controller;
    if (!mounted ||
        c == null ||
        c.loading ||
        !c.hasMore ||
        !_scroll.hasClients) {
      return;
    }
    final position = _scroll.position;
    final reserve = math.max(700.0, position.viewportDimension * 2);
    if (position.extentAfter <= reserve) {
      unawaited(c.refresh(more: true));
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<FilmCatalogController>(
    future: _catalog,
    builder: (context, state) {
      if (!_startupFrameScheduled &&
          state.connectionState == ConnectionState.done) {
        _startupFrameScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) context.read<AppState>().startupReady.value = true;
        });
      }
      if (!state.hasData) {
        return Padding(
          padding: EdgeInsets.only(left: widget.sidebarInset),
          child: Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              toolbarHeight: 48,
              backgroundColor: Colors.transparent,
              shape: const Border(),
              title: const AppText('影视库'),
            ),
            body: Center(
              child: state.hasError
                  ? const AppText('影视目录库操作失败')
                  : const SizedBox.shrink(),
            ),
          ),
        );
      }
      final c = state.data!;
      return AnimatedBuilder(
        animation: c,
        builder: (context, _) => GestureDetector(
          behavior: HitTestBehavior.translucent,
          onSecondaryTapUp: (details) =>
              _backgroundMenu(c, details.globalPosition),
          child: Stack(
            children: [
              Positioned.fill(
                child: ExcludeSemantics(
                  child: IgnorePointer(
                    child: FilmLibraryBackground(file: c.backgroundFile),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.only(left: widget.sidebarInset),
                child: Theme(
                  data: Theme.of(context).copyWith(
                    inputDecorationTheme: Theme.of(context).inputDecorationTheme
                        .copyWith(
                          fillColor: Theme.of(context).colorScheme.surface
                              .withValues(
                                alpha:
                                    Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? .28
                                    : .64,
                              ),
                        ),
                  ),
                  child: Scaffold(
                    backgroundColor: Colors.transparent,
                    appBar: AppBar(
                      toolbarHeight: 48,
                      backgroundColor: Colors.transparent,
                      shape: const Border(),
                      title: const AppText('影视库'),
                    ),
                    body: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (_browse)
                                TextButton(
                                  onPressed: () {
                                    setState(() => _browse = false);
                                    c.type = null;
                                    c.query = '';
                                    c.rootId = null;
                                    c.sectionId = null;
                                    _search.clear();
                                    c.refresh();
                                  },
                                  child: const AppText('主页'),
                                ),
                              SizedBox(
                                width: 250,
                                child: TextField(
                                  controller: _search,
                                  decoration: InputDecoration(
                                    label: const AppText('搜索库内作品'),
                                    suffixIcon: IconButton(
                                      icon: const Icon(SPIcons.search),
                                      onPressed: () {
                                        setState(() => _browse = true);
                                        c.query = _search.text;
                                        c.refresh();
                                      },
                                    ),
                                  ),
                                  onSubmitted: (value) {
                                    setState(() => _browse = true);
                                    c.query = value;
                                    c.refresh();
                                  },
                                ),
                              ),
                              SizedBox(
                                width: 220,
                                child: DropdownButtonFormField<int>(
                                  key: ValueKey(
                                    'film-root-filter-${c.rootId}-${c.roots.map((r) => r.id).join(',')}',
                                  ),
                                  dropdownColor: AppTheme.dropdownMenuColor(
                                    Theme.of(context),
                                  ),
                                  borderRadius: AppTheme.dropdownBorderRadius,
                                  isExpanded: true,
                                  initialValue: c.rootId ?? 0,
                                  decoration: const InputDecoration(
                                    label: AppText('来源'),
                                  ),
                                  items: [
                                    const DropdownMenuItem(
                                      value: 0,
                                      child: AppText(
                                        '全部来源',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    for (final root in c.roots)
                                      DropdownMenuItem(
                                        value: root.id,
                                        child: Text(
                                          root.displayName,
                                          overflow: TextOverflow.ellipsis,
                                          maxLines: 1,
                                        ),
                                      ),
                                  ],
                                  onChanged: (value) {
                                    setState(() => _browse = true);
                                    c.rootId = value == 0 ? null : value;
                                    c.sectionId = null;
                                    c.refresh();
                                  },
                                ),
                              ),
                              SizedBox(
                                width: 155,
                                child: DropdownButtonFormField<bool>(
                                  dropdownColor: AppTheme.dropdownMenuColor(
                                    Theme.of(context),
                                  ),
                                  borderRadius: AppTheme.dropdownBorderRadius,
                                  isExpanded: true,
                                  initialValue: c.newest,
                                  decoration: const InputDecoration(
                                    label: AppText('排序'),
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: false,
                                      child: AppText(
                                        '按标题',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    DropdownMenuItem(
                                      value: true,
                                      child: AppText(
                                        '按收录时间',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                  onChanged: (value) {
                                    c.newest = value!;
                                    c.refresh();
                                  },
                                ),
                              ),
                              TextButton(
                                onPressed: () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => FilmPendingPage(
                                      catalog: c,
                                      onOpenItem: widget.onOpenItem,
                                      sidebarInset: widget.sidebarInset,
                                    ),
                                  ),
                                ),
                                child: Text(
                                  context.l10n.format('待整理（{count}）', {
                                    'count': c.pendingCount,
                                  }),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: FilmCatalogTasks(catalog: c),
                        ),
                        if (c.error != null)
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: AppText(
                              filmCatalogErrorText(c.error!),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        Expanded(
                          child: IndexedStack(
                            index: _browse ? 1 : 0,
                            children: [
                              DirectoryScrollView(
                                controller: _homeScroll,
                                builder: (_) => ListView(
                                  controller: _homeScroll,
                                  padding: const EdgeInsets.all(20),
                                  children: [
                                    for (final section in c.homeSections.where(
                                      (s) => s.enabled,
                                    ))
                                      _homeSection(c, section),
                                    if (c.works.isEmpty && c.roots.isEmpty)
                                      const Padding(
                                        padding: EdgeInsets.all(24),
                                        child: AppText('暂无已匹配作品，请添加影视目录并整理文件'),
                                      ),
                                  ],
                                ),
                              ),
                              !_browse || (c.works.isEmpty && c.loading)
                                  ? const SizedBox.shrink()
                                  : c.works.isEmpty
                                  ? const Center(
                                      child: AppText('暂无已匹配作品，请添加影视目录并整理文件'),
                                    )
                                  : NotificationListener<
                                      ScrollMetricsNotification
                                    >(
                                      onNotification: (_) {
                                        _schedulePrefetch();
                                        return false;
                                      },
                                      child: FilmPosterGrid(
                                        store: c.store,
                                        rootId: c.rootId,
                                        works: c.works,
                                        cache: c.images,
                                        controller: _scroll,
                                        onOpen: (work) => _openWork(c, work),
                                        onMenu: (work, position) =>
                                            showFilmWorkMenu(
                                              context,
                                              catalog: c,
                                              work: work,
                                              position: position,
                                            ),
                                      ),
                                    ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
  Future<void> _openWork(FilmCatalogController c, FilmWork work) async {
    final chrome = context.read<ValueNotifier<double?>?>();
    chrome?.value = 0;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FilmDetailPage(
          catalog: c,
          workId: work.id,
          initialWork: work,
          onOpenItem: widget.onOpenItem,
        ),
      ),
    );
    if (mounted) chrome?.value = null;
  }

  Widget _workShelf(
    FilmCatalogController c,
    String title,
    List<FilmWork> works, {
    FilmMediaType? type,
    bool newest = false,
    String? sectionId,
  }) => FilmShelf(
    title: title,
    count: works.length,
    onShowAll: () {
      setState(() => _browse = true);
      c.type = type;
      c.newest = newest;
      c.sectionId = sectionId;
      c.rootId = null;
      c.query = '';
      _search.clear();
      c.refresh();
    },
    builder: (_, i) => FilmWorkCard(
      store: c.store,
      work: works[i],
      cache: c.images,
      onTap: () => _openWork(c, works[i]),
      onMenu: (position) => showFilmWorkMenu(
        context,
        catalog: c,
        work: works[i],
        position: position,
      ),
    ),
  );

  Widget _homeSection(FilmCatalogController c, FilmHomeSection section) =>
      switch (section.id) {
        'continue' =>
          widget.continueShelf ??
              GlobalMediaLibraryPage(
                filmCatalog: c,
                sidebarInset: widget.sidebarInset,
                onOpenItem: widget.onOpenItem,
                onContinueSelected: widget.onContinueSelected,
                onContinueMenu: widget.onContinueMenu,
              ),
        'sources' => _sourceShelf(c),
        'recent' => _workShelf(c, '最近添加', c.recentWorks, newest: true),
        'movies' => _workShelf(c, '电影', c.movies, type: FilmMediaType.movie),
        'series' => _workShelf(c, '剧集', c.series, type: FilmMediaType.tv),
        _ => _workShelf(
          c,
          filmSectionTitle(context, section),
          c.sectionWorks[section.id] ?? [],
          sectionId: section.id,
        ),
      };

  Widget _sourceShelf(FilmCatalogController c) => FilmShelf(
    title: '媒体来源',
    count: c.roots.length,
    height: 188,
    itemWidth: 280,
    builder: (_, i) {
      final root = c.roots[i];
      final cover = c.rootCoverFiles[root.id];
      return GestureDetector(
        onSecondaryTapUp: (details) =>
            _sourceMenu(c, root, details.globalPosition),
        child: Card(
          margin: EdgeInsets.zero,
          color: Colors.transparent,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () {
              setState(() => _browse = true);
              c.type = null;
              c.rootId = root.id;
              c.sectionId = null;
              c.query = '';
              _search.clear();
              c.refresh();
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (cover != null)
                        Image.file(
                          cover,
                          fit: BoxFit.cover,
                          cacheWidth: 560,
                          errorBuilder: (_, _, _) => const Center(
                            child: Icon(SPIcons.folderOpen, size: 40),
                          ),
                        )
                      else
                        const Center(child: Icon(SPIcons.folderOpen, size: 40)),
                      ColoredBox(color: Colors.black.withValues(alpha: .35)),
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            root.displayName,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(
                    root.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Future<String?> _menu(Offset position, List<PopupMenuEntry<String>> items) {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final local = overlay.globalToLocal(position);
    return showMenu<String>(
      context: context,
      color: AppTheme.dropdownMenuColor(Theme.of(context)),
      shape: RoundedRectangleBorder(
        borderRadius: AppTheme.dropdownBorderRadius,
      ),
      position: RelativeRect.fromRect(
        Rect.fromLTWH(local.dx, local.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: items,
    );
  }

  Future<void> _sourceMenu(
    FilmCatalogController c,
    FilmCatalogRoot root,
    Offset position,
  ) async {
    final action = await _menu(position, [
      PopupMenuItem(
        value: 'edit',
        enabled: !c.busy && !c.scraping,
        child: const AppText('编辑影视目录'),
      ),
      const PopupMenuItem(value: 'image', child: AppText('修改图片')),
    ]);
    if (!mounted) return;
    if (action == 'edit') {
      await showFilmRootEditor(context, c, root: root);
    } else if (action == 'image') {
      await showFilmArtworkPicker(context, c, rootId: root.id);
    }
  }

  Future<void> _backgroundMenu(FilmCatalogController c, Offset position) async {
    final action = await _menu(position, const [
      PopupMenuItem(value: 'background', child: AppText('设置影视库背景')),
    ]);
    if (mounted && action != null) await showFilmArtworkPicker(context, c);
  }
}
