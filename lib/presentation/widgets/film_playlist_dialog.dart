import 'package:flutter/material.dart';
import '../../data/local/film_catalog_store.dart';
import '../../data/models/film_catalog_item.dart';
import '../../data/models/film_playlist.dart';
import '../controllers/film_catalog_controller.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import 'directory_scroll_view.dart';
import 'film_watch_menu.dart';
import 'glass_dialog.dart';
import 'sp_dialog.dart';
import 'sp_notice.dart';
import 'sp_menu.dart';

Future<void> showFilmPlaylistDialog(
  BuildContext context,
  FilmCatalogController catalog,
  FilmPlaylistScope scope, {
  required bool create,
  String? title,
  String? sourceId,
}) async {
  if (scope.playlist case final list?) {
    await showGlassDialog<void>(
      context: context,
      builder: (_) => _PlaylistDialog(
        catalog: catalog,
        scope: scope,
        source: null,
        create: create,
        initialName: title ?? list.name,
        omitted: 0,
      ),
    );
    return;
  }
  List<FilmResource> resources = [];
  final ok = await catalog.run(() async {
    resources = scope.resource == null
        ? await catalog.store.resources(
            workId: scope.workId,
            sourceId: sourceId ?? catalog.sourceId,
          )
        : [scope.resource!];
  });
  if (!context.mounted) return;
  if (!ok) {
    ScaffoldMessenger.of(context).showSnackBar(
      SPNotice(content: AppText(filmCatalogErrorText(catalog.error!))),
    );
    return;
  }
  resources = resources
      .where(
        (r) =>
            (r.mediaKind == 'video' || r.mediaKind == 'strm') &&
            r.availability == 'present' &&
            (scope.season == null || r.season == scope.season),
      )
      .toList();
  if (resources.isEmpty) return;
  final selected = await selectFilmActionSource(context, resources);
  if (!context.mounted || selected == null) return;
  final resource = resources.firstWhere((r) => r.sourceId == selected);
  final omitted = scope.follows
      ? resources
            .where(
              (r) =>
                  r.sourceId == selected &&
                  r.type == FilmMediaType.tv &&
                  (r.season == null || r.episode == null),
            )
            .length
      : 0;
  await showGlassDialog<void>(
    context: context,
    builder: (_) => _PlaylistDialog(
      catalog: catalog,
      scope: scope,
      source: resource,
      create: create,
      initialName: title ?? resource.name,
      omitted: omitted,
    ),
  );
}

class _PlaylistDialog extends StatefulWidget {
  const _PlaylistDialog({
    required this.catalog,
    required this.scope,
    required this.source,
    required this.create,
    required this.initialName,
    required this.omitted,
  });
  final FilmCatalogController catalog;
  final FilmPlaylistScope scope;
  final FilmResource? source;
  final bool create;
  final String initialName;
  final int omitted;
  @override
  State<_PlaylistDialog> createState() => _PlaylistDialogState();
}

class _PlaylistDialogState extends State<_PlaylistDialog> {
  String get _sourceId =>
      widget.scope.playlist?.sourceId ?? widget.source!.sourceId;
  String get _sourceName =>
      widget.scope.playlist?.sourceName ?? widget.source!.rootName;
  late final _name = TextEditingController(text: widget.initialName);
  List<FilmPlaylist> _lists = [];
  int _count = 0;
  bool _busy = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final ok = await widget.catalog.run(() async {
      _count = await widget.catalog.store.playlistScopeCount(
        _sourceId,
        widget.scope,
      );
      final identity = widget.scope.playlist != null
          ? widget.scope.playlist!.serverIdentity
          : await widget.catalog.store.preference('server_identity:$_sourceId');
      _lists =
          (await widget.catalog.store.playlists(
                sourceId: _sourceId,
                editableOnly: true,
              ))
              .where(
                (p) =>
                    p.serverIdentity == identity &&
                    p.id != widget.scope.playlist?.id,
              )
              .toList();
    });
    if (mounted) {
      setState(() {
        _busy = false;
        _error = ok ? null : widget.catalog.error;
      });
    }
  }

  Future<void> _save(String? id) async {
    setState(() => _busy = true);
    final ok = await widget.catalog.run(() async {
      if (id == null) {
        await widget.catalog.store.createPlaylist(
          _name.text,
          _sourceId,
          widget.scope.playlist?.sourceKind ?? widget.source!.sourceKind,
          _sourceName,
          widget.scope,
        );
      } else {
        await widget.catalog.store.addPlaylistScope(
          id,
          _sourceId,
          widget.scope,
        );
      }
    });
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _error = widget.catalog.error;
      });
    }
  }

  @override
  Widget build(BuildContext context) => SPDialog(
    title: AppText(widget.create ? '创建播放列表' : '加入播放列表…'),
    content: SizedBox(
      width: 480,
      height: 360,
      child: DirectoryScrollView(
        builder: (controller) => ListView(
          controller: controller,
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (_error != null) AppText(filmCatalogErrorText(_error!)),
            Text(_sourceName, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(context.l10n.format('成员数量：{count}', {'count': _count})),
            AppText(
              widget.scope.playlist != null
                  ? '保留所选条目及版本设定，不自动追加'
                  : widget.scope.follows
                  ? widget.scope.season == null
                        ? '自动追加范围：本作品'
                        : '自动追加范围：本季'
                  : '固定所选版本，不自动追加',
            ),
            if (widget.omitted > 0)
              Text(
                context.l10n.format('未映射资源未纳入：{count}', {
                  'count': widget.omitted,
                }),
              ),
            if (!widget.create) ...[
              for (final list in _lists)
                ListTile(
                  title: Text(list.name),
                  onTap: _busy || _count == 0 ? null : () => _save(list.id),
                ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              enabled: !_busy,
              contextMenuBuilder: buildSPTextSelectionMenu,
              decoration: InputDecoration(
                labelText: context.l10n.text('播放列表名称'),
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.of(context).pop(),
        child: const AppText('取消'),
      ),
      FilledButton(
        onPressed: _busy || _count == 0 ? null : () => _save(null),
        child: const AppText('创建播放列表'),
      ),
    ],
  );
}
