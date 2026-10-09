import 'dart:async';
import 'package:flutter/material.dart';
import '../../data/local/film_catalog_store.dart';
import '../../data/models/film_catalog_item.dart';
import '../../data/models/film_playlist.dart';
import '../controllers/film_catalog_controller.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../theme/app_theme.dart';
import '../widgets/directory_scroll_view.dart';
import '../widgets/film_artwork.dart';
import '../widgets/film_library_background.dart';
import '../widgets/film_playlist_dialog.dart';
import '../widgets/film_watch_menu.dart';
import '../widgets/film_watch_overlay.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/sp_dialog.dart';
import '../widgets/sp_icons.dart';
import '../widgets/sp_menu.dart';
import '../widgets/sp_notice.dart';
import '../widgets/sp_reorderable.dart';

class FilmPlaylistPage extends StatefulWidget {
  const FilmPlaylistPage({
    super.key,
    required this.catalog,
    required this.onPlay,
    this.playlistId,
    this.sidebarInset = 0,
  });
  final FilmCatalogController catalog;
  final String? playlistId;
  final double sidebarInset;
  final Future<void> Function(FilmPlaylistSnapshot, int) onPlay;
  @override
  State<FilmPlaylistPage> createState() => _FilmPlaylistPageState();
}

class _FilmPlaylistPageState extends State<FilmPlaylistPage> {
  final _scroll = ScrollController();
  List<FilmPlaylist> _lists = [];
  FilmPlaylistSnapshot? _snapshot;
  String? _selected;
  bool _busy = false, _pending = false, _dragging = false;
  String? _error;
  Timer? _reload;
  @override
  void initState() {
    super.initState();
    widget.catalog.store.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  void _changed() {
    if (_busy || _dragging) {
      _pending = true;
      return;
    }
    _reload ??= Timer(const Duration(milliseconds: 150), () {
      _reload = null;
      _load();
    });
  }

  Future<void> _load() async {
    if (_busy || _dragging) {
      _pending = true;
      return;
    }
    _busy = true;
    final ok = await widget.catalog.run(() async {
      if (widget.playlistId == null) {
        _lists = await widget.catalog.store.playlists(
          sourceId: widget.catalog.sourceId,
        );
      } else {
        _snapshot = await widget.catalog.store.playlistSnapshot(
          widget.playlistId!,
        );
      }
    });
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = ok ? null : widget.catalog.error;
    });
    if (_pending) {
      _pending = false;
      _changed();
    }
  }

  @override
  void dispose() {
    _reload?.cancel();
    widget.catalog.store.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }

  Future<bool> _mutate(Future<void> Function() action) async {
    if (_busy) return false;
    setState(() => _busy = true);
    final ok = await widget.catalog.run(action);
    if (!mounted) return ok;
    setState(() => _busy = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SPNotice(content: AppText(filmCatalogErrorText(widget.catalog.error!))),
      );
    }
    return ok;
  }

  Future<void> _reorder(int from, int to) async {
    if (_busy) return;
    final snapshot = _snapshot!;
    final previous = List<FilmPlaylistEntry>.of(snapshot.entries);
    setState(
      () => snapshot.entries.insert(to, snapshot.entries.removeAt(from)),
    );
    final ok = await _mutate(
      () => widget.catalog.store.reorderPlaylist(
        snapshot.playlist.id,
        snapshot.entries.map((e) => e.id).toList(),
      ),
    );
    if (!mounted) return;
    if (!ok) {
      setState(() {
        snapshot.entries
          ..clear()
          ..addAll(previous);
      });
    }
    await _load();
  }

  Future<void> _play(int index) async {
    if (_busy) return;
    final id = _snapshot!.entries[index].id;
    FilmPlaylistSnapshot? fresh;
    final ok = await _mutate(() async {
      fresh = await widget.catalog.store.playlistSnapshot(widget.playlistId!);
    });
    if (!ok || !mounted) return;
    setState(() => _snapshot = fresh);
    final target = fresh!.entries.indexWhere((e) => e.id == id);
    if (target < 0 || !fresh!.entries[target].available) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SPNotice(content: AppText('播放列表条目不可用，请检查来源或资源')));
      return;
    }
    await _mutate(() => widget.onPlay(fresh!, target));
    if (mounted) await _load();
  }

  Future<void> _manage(FilmPlaylist list, String action) async {
    if (_busy) return;
    if (action == 'delete') {
      final yes = await showGlassDialog<bool>(
        context: context,
        builder: (ctx) => SPDialog(
          title: const AppText('删除播放列表'),
          content: Text(list.name),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const AppText('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const AppText('删除'),
            ),
          ],
        ),
      );
      if (yes != true || !mounted) return;
      final ok = await _mutate(
        () => widget.catalog.store.deletePlaylist(list.id),
      );
      if (!mounted) return;
      if (ok && widget.playlistId != null) {
        Navigator.of(context).pop();
        return;
      }
      await _load();
      return;
    }
    final name = await _playlistName(
      context,
      list.name,
      action == 'copy' ? '复制为自定义播放列表' : '重命名',
    );
    if (name == null || !mounted) return;
    String? copy;
    final ok = await _mutate(() async {
      if (action == 'copy') {
        copy = await widget.catalog.store.copyPlaylist(list.id, name);
      } else {
        await widget.catalog.store.renamePlaylist(list.id, name);
      }
    });
    if (!mounted) return;
    await _load();
    if (ok && copy != null && mounted) _open(copy!);
  }

  void _open(String id) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => FilmPlaylistPage(
        catalog: widget.catalog,
        onPlay: widget.onPlay,
        playlistId: id,
        sidebarInset: widget.sidebarInset,
      ),
    ),
  );

  Future<void> _coverMenu(
    FilmPlaylist list,
    Offset position, {
    String? entryId,
  }) async {
    if (_busy || _dragging) return;
    late FilmPlaylistSnapshot snapshot;
    final ok = await _mutate(() async {
      snapshot = await widget.catalog.store.playlistSnapshot(list.id);
    });
    if (!ok || !mounted) return;
    final entries = snapshot.entries
        .where((e) => entryId == null || e.id == entryId)
        .toList();
    final resources = entries
        .map((e) => e.resource)
        .whereType<FilmResource>()
        .toList();
    final workIds = entries.map((e) => e.workId).whereType<int>().toSet();
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final local = overlay.globalToLocal(position);
    setState(() => _busy = true);
    final action = await showSPMenu<String>(
      context: context,
      color: AppTheme.dropdownMenuColor(Theme.of(context)),
      shape: RoundedRectangleBorder(
        borderRadius: AppTheme.dropdownBorderRadius,
      ),
      position: RelativeRect.fromRect(
        Rect.fromLTWH(local.dx, local.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: 'refresh',
          enabled: workIds.isNotEmpty,
          child: const AppText('刷新元数据'),
        ),
        PopupMenuItem(
          value: 'watched',
          enabled: resources.any((r) => r.canMarkWatched),
          child: const AppText('标记已看完'),
        ),
        PopupMenuItem(
          value: 'unwatched',
          enabled: resources.any((r) => r.canMarkWatched),
          child: const AppText('标记未看完'),
        ),
        PopupMenuItem(
          value: 'addPlaylist',
          enabled: entries.isNotEmpty,
          child: const AppText('加入播放列表…'),
        ),
        PopupMenuItem(
          value: 'playlist',
          enabled: entries.isNotEmpty,
          child: AppText(entryId == null ? '以本列表创建播放列表' : '以本集创建播放列表'),
        ),
        if (entryId == null || !list.readOnly) const PopupMenuDivider(),
        if (entryId == null)
          ..._actions(list)
        else if (!list.readOnly)
          const PopupMenuItem(value: 'remove', child: AppText('移除成员')),
      ],
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (action == null) {
      await _load();
      return;
    }
    if (action == 'playlist' || action == 'addPlaylist') {
      await showFilmPlaylistDialog(
        context,
        widget.catalog,
        FilmPlaylistScope.playlist(snapshot.playlist, entryId: entryId),
        create: action == 'playlist',
        title: entryId == null ? list.name : entries.single.title,
      );
    } else if (action == 'watched' || action == 'unwatched') {
      await _mutate(
        () => markFilmWatch(context, resources, action == 'watched'),
      );
    } else if (action == 'refresh') {
      await _mutate(() async {
        for (final id in workIds) {
          final work = await widget.catalog.store.work(id);
          if (work != null) await widget.catalog.matcher.refresh(work);
        }
      });
    } else if (action == 'remove') {
      await _mutate(
        () => widget.catalog.store.removePlaylistEntry(list.id, entryId!),
      );
    } else {
      await _manage(list, action);
      return;
    }
    if (mounted) await _load();
  }

  List<PopupMenuEntry<String>> _actions(FilmPlaylist list) => list.readOnly
      ? [const PopupMenuItem(value: 'copy', child: AppText('复制为自定义播放列表'))]
      : [
          const PopupMenuItem(value: 'rename', child: AppText('重命名')),
          const PopupMenuItem(value: 'delete', child: AppText('删除播放列表')),
        ];
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
          child: FilmSpoilerScope(
            child: Scaffold(
              backgroundColor: Colors.transparent,
              appBar: AppBar(
                toolbarHeight: 48,
                automaticallyImplyLeading: false,
                backgroundColor: Colors.transparent,
                shape: const Border(),
                title: _snapshot == null
                    ? const AppText('播放列表')
                    : Text(_snapshot!.playlist.name),
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
                        TextButton.icon(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(SPIcons.back),
                          label: const AppText('返回'),
                        ),
                        if (_snapshot case final snapshot?) ...[
                          Text(snapshot.playlist.sourceName),
                          if (snapshot.playlist.readOnly) const AppText('只读镜像'),
                          if (snapshot.playlist.error != null)
                            AppText(
                              filmCatalogErrorText(snapshot.playlist.error!),
                            ),
                          SPPopupMenuButton<String>(
                            icon: const Icon(SPIcons.more),
                            itemBuilder: (_) => _actions(snapshot.playlist),
                            onSelected: (action) =>
                                _manage(snapshot.playlist, action),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: AppText(filmCatalogErrorText(_error!)),
                    ),
                  Expanded(
                    child: DirectoryScrollView(
                      controller: _scroll,
                      builder: (controller) {
                        if (widget.playlistId == null) {
                          return ListView.builder(
                            controller: controller,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: _lists.length,
                            itemBuilder: (_, i) {
                              final list = _lists[i];
                              return GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onSecondaryTapDown: (details) =>
                                    _coverMenu(list, details.globalPosition),
                                child: ListTile(
                                  key: ValueKey(list.id),
                                  leading: SizedBox(
                                    width: 96,
                                    height: 54,
                                    child: list.artwork == null
                                        ? const Icon(SPIcons.list)
                                        : ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            child: FilmWatchOverlay(
                                              store: widget.catalog.store,
                                              workId: list.artworkWorkId,
                                              sourceId: list.sourceId,
                                              path: list.artworkPath,
                                              spoilerSensitive:
                                                  list.artworkSensitive,
                                              canReveal: false,
                                              child: FilmArtwork(
                                                cache: widget.catalog.images,
                                                path: list.artwork,
                                                target: list.artworkTarget,
                                                width: 96,
                                                height: 54,
                                                aspectRatio: 16 / 9,
                                              ),
                                            ),
                                          ),
                                  ),
                                  title: Text(list.name),
                                  subtitle: Text(
                                    '${list.sourceName} · ${context.l10n.format('成员数量：{count}', {'count': list.count})}${list.readOnly ? ' · ${context.l10n.text('只读镜像')}' : ''}',
                                  ),
                                  onTap: () => _open(list.id),
                                  trailing: SPPopupMenuButton<String>(
                                    itemBuilder: (_) => _actions(list),
                                    onSelected: (action) =>
                                        _manage(list, action),
                                  ),
                                ),
                              );
                            },
                          );
                        }
                        final snapshot = _snapshot;
                        if (snapshot == null) {
                          return ListView(controller: controller);
                        }
                        if (snapshot.entries.isEmpty) {
                          return ListView(
                            controller: controller,
                            children: const [
                              ListTile(title: AppText('播放列表为空')),
                            ],
                          );
                        }
                        if (snapshot.playlist.readOnly) {
                          return ListView.builder(
                            controller: controller,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: snapshot.entries.length,
                            itemBuilder: (_, i) => _row(snapshot, i),
                          );
                        }
                        return ReorderableListView.builder(
                          scrollController: controller,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          buildDefaultDragHandles: false,
                          proxyDecorator: spReorderProxy,
                          onReorderItem: _reorder,
                          onReorderStart: (_) => _dragging = true,
                          onReorderEnd: (_) {
                            _dragging = false;
                            if (_pending) {
                              _pending = false;
                              _changed();
                            }
                          },
                          itemCount: snapshot.entries.length,
                          itemBuilder: (_, i) => _row(snapshot, i),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
  Widget _row(FilmPlaylistSnapshot snapshot, int index) {
    final entry = snapshot.entries[index];
    final versions = entry.currentVersions ?? entry.versions;
    final info = [
      if (entry.year != null) '${entry.year}',
      if (entry.season != null)
        'S${entry.season.toString().padLeft(2, '0')}${entry.episode == null ? '' : 'E${entry.episode.toString().padLeft(2, '0')}'}',
      if (entry.pinnedPath != null) versions.first.name,
      if (!entry.available) context.l10n.text('不可用'),
    ].join(' · ');
    final episode = entry.display['episodeTitle'] as String?;
    return Material(
      key: ValueKey(entry.id),
      color: entry.id == _selected
          ? Theme.of(context).colorScheme.primary.withValues(alpha: .12)
          : Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _selected = entry.id),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 72),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onDoubleTap: _busy ? null : () => _play(index),
                    onSecondaryTapDown: (details) => _coverMenu(
                      snapshot.playlist,
                      details.globalPosition,
                      entryId: entry.id,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 32,
                            child: Text(
                              '${index + 1}',
                              textAlign: TextAlign.center,
                            ),
                          ),
                          SizedBox(
                            width: 96,
                            height: 54,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: FilmWatchOverlay(
                                store: widget.catalog.store,
                                resource: entry.resource,
                                workId: entry.workId,
                                sourceId: snapshot.playlist.sourceId,
                                path: versions.first.path,
                                spoilerSensitive:
                                    entry.display['episodeArtwork'] == true,
                                canReveal: false,
                                child: FilmArtwork(
                                  cache: widget.catalog.images,
                                  path: entry.artwork,
                                  target:
                                      entry.display['artworkTarget']
                                          as String? ??
                                      'w342',
                                  width: 96,
                                  height: 54,
                                  aspectRatio: 16 / 9,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  episode == null || episode.isEmpty
                                      ? entry.title
                                      : '${entry.title} · $episode',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (info.isNotEmpty)
                                  Text(
                                    info,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: context.l10n.text('播放此文件'),
                  onPressed: _busy ? null : () => _play(index),
                  icon: const Icon(SPIcons.play),
                ),
                if (!snapshot.playlist.readOnly) ...[
                  SPPopupMenuButton<String>(
                    icon: const Icon(SPIcons.more),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'remove',
                        child: AppText('移除成员'),
                      ),
                    ],
                    onSelected: (_) async {
                      await _mutate(
                        () => widget.catalog.store.removePlaylistEntry(
                          snapshot.playlist.id,
                          entry.id,
                        ),
                      );
                      await _load();
                    },
                  ),
                  SPReorderHandle(
                    index: index,
                    enabled: !_busy,
                    tooltip: context.l10n.text('拖动排序'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<String?> _playlistName(
  BuildContext context,
  String initial,
  String title,
) async {
  final controller = TextEditingController(text: initial);
  final result = await showGlassDialog<String>(
    context: context,
    builder: (ctx) => SPDialog(
      title: AppText(title),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: controller,
          autofocus: true,
          contextMenuBuilder: buildSPTextSelectionMenu,
          decoration: InputDecoration(labelText: ctx.l10n.text('播放列表名称')),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const AppText('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(controller.text),
          child: const AppText('保存'),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}
