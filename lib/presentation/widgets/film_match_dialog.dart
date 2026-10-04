import 'package:flutter/material.dart';

import '../../core/utils/file_sort.dart';
import '../../data/models/film_catalog_item.dart';
import '../../domain/services/film_catalog_matcher.dart';
import '../controllers/film_catalog_controller.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../theme/app_theme.dart';
import 'film_artwork.dart';
import 'glass_dialog.dart';
import 'sp_dialog.dart';

Future<bool?> showFilmMatchDialog(
  BuildContext context,
  FilmCatalogController catalog,
  FilmResource resource, {
  List<FilmResource>? initialResources,
}) => showGlassDialog<bool>(
  context: context,
  builder: (_) => FilmMatchDialog(
    catalog: catalog,
    resource: resource,
    initialResources: initialResources,
  ),
);

class FilmMatchDialog extends StatefulWidget {
  const FilmMatchDialog({
    super.key,
    required this.catalog,
    required this.resource,
    this.initialResources,
  });
  final FilmCatalogController catalog;
  final FilmResource resource;
  final List<FilmResource>? initialResources;
  @override
  State<FilmMatchDialog> createState() => _FilmMatchDialogState();
}

class _FilmMatchDialogState extends State<FilmMatchDialog> {
  final _query = TextEditingController();
  final _id = TextEditingController();
  late FilmMatchHint _hint;
  List<FilmWork> _results = [];
  List<FilmResource> _resources = [];
  final Set<int> _selectedFiles = {};
  FilmWork? _selected;
  bool _folder = false;
  late String _directory;
  bool _loading = false;
  String? _error;
  int _page = 1;
  bool _more = false;
  @override
  void initState() {
    super.initState();
    _hint = FilmCatalogMatcher.hint(widget.resource);
    _query.text = _hint.title;
    if (_hint.ids.length == 1) _id.text = _hint.ids.single.toString();
    _directory = widget.resource.parentPath;
    _resources = widget.initialResources ?? [widget.resource];
    _selectedFiles.addAll(_resources.map((r) => r.id));
  }

  @override
  void dispose() {
    _query.dispose();
    _id.dispose();
    super.dispose();
  }

  Future<bool> _run(Future<void> Function() action) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final ok = await widget.catalog.run(action);
    if (mounted) {
      setState(() {
        _loading = false;
        _error = widget.catalog.error;
      });
    }
    return ok;
  }

  Future<void> _search({bool more = false}) async {
    if (_query.text.trim().isEmpty) return;
    await _run(() async {
      final page = more ? _page + 1 : 1;
      final results = await widget.catalog.tmdb.search(
        widget.resource.type,
        _query.text.trim(),
        await widget.catalog.store.language(),
        year: _hint.year,
        page: page,
      );
      if (mounted) {
        setState(() {
          _results = more ? [..._results, ...results] : results;
          _page = page;
          _more = results.length == 20;
          if (!more) _selected = null;
        });
      }
    });
  }

  Future<void> _lookup() async {
    await _run(() async {
      final id = int.tryParse(_id.text.trim());
      if (id == null || id <= 0) {
        throw const FilmCatalogException('invalidMetadata');
      }
      final work = await widget.catalog.matcher.lookup(
        widget.resource.type,
        id,
      );
      if (mounted) {
        setState(() {
          _results = [work];
          _selected = work;
          _more = false;
        });
      }
    });
  }

  Future<void> _scope() async {
    await _run(() async {
      final resources = _folder
          ? (await widget.catalog.store.resources(
                  rootId: widget.resource.rootId,
                ))
                .where(
                  (r) => filmPathWithin(
                    filmPathKey(r.parentPath, r.sourceKind),
                    filmPathKey(_directory, r.sourceKind),
                  ),
                )
                .toList()
          : widget.initialResources ?? [widget.resource];
      if (mounted) {
        setState(() {
          _resources = resources;
          _selectedFiles.clear();
          _selectedFiles.addAll(
            resources
                .where(
                  (r) =>
                      r.bindingOrigin != 'manual' || r.id == widget.resource.id,
                )
                .map((r) => r.id),
          );
        });
      }
    });
  }

  Future<void> _save() async {
    final resources = _resources
        .where((r) => _selectedFiles.contains(r.id))
        .toList();
    final ok = await _run(
      () => widget.catalog.matcher.confirm(
        resources,
        widget.resource.type,
        _selected!.tmdbId,
        directoryPath: _folder ? _directory : null,
      ),
    );
    if (!ok || !mounted) return;
    await widget.catalog.run(
      () => widget.catalog.matcher.verifyEpisodes(
        resources.map((r) => r.id).toList(),
      ),
    );
    await widget.catalog.refresh();
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final ancestors = <String>[];
    var directory = widget.resource.parentPath;
    while (true) {
      ancestors.add(directory);
      if (directory == widget.resource.rootPath) break;
      final parts = directory.split('/')..removeLast();
      directory = parts.join('/');
    }
    return SPDialog(
      title: const AppText('匹配或更换作品'),
      content: SizedBox(
        width: 780,
        height: MediaQuery.sizeOf(context).height * 0.62,
        child: ListView(
          children: [
            SelectableText(widget.resource.path),
            if (_hint.conflicting) const AppText('文件与目录中的 TMDB ID 冲突，请人工确认'),
            const SizedBox(height: 12),
            TextField(
              controller: _query,
              onSubmitted: (_) => _loading ? null : _search(),
              decoration: const InputDecoration(label: AppText('搜索作品名称')),
            ),
            TextButton(
              onPressed: _loading ? null : _search,
              child: const AppText('搜索候选'),
            ),
            TextField(
              controller: _id,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(label: AppText('明确 TMDB ID')),
            ),
            TextButton(
              onPressed: _loading ? null : _lookup,
              child: const AppText('核验 ID'),
            ),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null) AppText(filmCatalogErrorText(_error!)),
            if (!_loading && _results.isEmpty)
              const AppText('搜索后选择正确作品，搜索排名不代表匹配结果'),
            for (final result in _results)
              ListTile(
                leading: FilmArtwork(
                  cache: widget.catalog.images,
                  path: result.posterPath,
                  width: 40,
                ),
                title: Text('${result.title} (${result.year ?? ''})'),
                subtitle: Text(
                  '${result.originalTitle} · TMDB ${result.tmdbId} · ${context.l10n.text(result.type == FilmMediaType.movie ? '电影' : '剧集')}',
                ),
                selected: _selected?.tmdbId == result.tmdbId,
                onTap: _loading
                    ? null
                    : () => setState(() => _selected = result),
              ),
            if (_more)
              TextButton(
                onPressed: _loading ? null : () => _search(more: true),
                child: const AppText('加载更多'),
              ),
            if (widget.resource.type == FilmMediaType.tv) ...[
              const Divider(),
              CheckboxListTile(
                value: _folder,
                title: const AppText('确认作品目录归属'),
                subtitle: const AppText('预览并选择本次关联文件；以后新增集数继承目录归属'),
                onChanged: _loading
                    ? null
                    : (value) {
                        setState(() => _folder = value!);
                        _scope();
                      },
              ),
              if (_folder)
                DropdownButtonFormField<String>(
                  dropdownColor: AppTheme.dropdownMenuColor(Theme.of(context)),
                  borderRadius: AppTheme.dropdownBorderRadius,
                  isExpanded: true,
                  key: ValueKey(_directory),
                  initialValue: _directory,
                  decoration: const InputDecoration(label: AppText('作品目录')),
                  items: [
                    for (final ancestor in ancestors)
                      DropdownMenuItem(
                        value: ancestor,
                        child: Text(
                          ancestor.isEmpty ? '/' : ancestor,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _loading
                      ? null
                      : (value) {
                          setState(() => _directory = value!);
                          _scope();
                        },
                ),
            ],
            const SizedBox(height: 12),
            const AppText('本次关联文件预览'),
            for (final resource in _resources)
              CheckboxListTile(
                value: _selectedFiles.contains(resource.id),
                title: Text(resource.name),
                subtitle: Text(
                  '${resource.path}${resource.bindingOrigin == 'manual' ? ' · ${context.l10n.text('已人工匹配')}' : ''}',
                ),
                onChanged: _loading
                    ? null
                    : (value) => setState(() {
                        if (value == true) {
                          _selectedFiles.add(resource.id);
                        } else {
                          _selectedFiles.remove(resource.id);
                        }
                      }),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.of(context).pop(),
          child: const AppText('取消'),
        ),
        FilledButton(
          onPressed: _loading || _selected == null || _selectedFiles.isEmpty
              ? null
              : _save,
          child: const AppText('确认匹配'),
        ),
      ],
    );
  }
}

Future<bool?> showFilmEpisodeMapping(
  BuildContext context,
  FilmCatalogController catalog,
  List<FilmResource> resources,
) => showGlassDialog<bool>(
  context: context,
  builder: (_) => _FilmEpisodeDialog(catalog: catalog, resources: resources),
);

class _FilmEpisodeDialog extends StatefulWidget {
  const _FilmEpisodeDialog({required this.catalog, required this.resources});
  final FilmCatalogController catalog;
  final List<FilmResource> resources;
  @override
  State<_FilmEpisodeDialog> createState() => _FilmEpisodeDialogState();
}

class _FilmEpisodeDialogState extends State<_FilmEpisodeDialog> {
  final _season = TextEditingController(text: '1');
  final _episode = TextEditingController(text: '1');
  late final List<FilmResource> _resources = List.of(widget.resources)
    ..sort((a, b) => naturalCompare(a.path, b.path));
  Map<FilmResource, (int, int)>? _preview;
  final Set<int> _accepted = {};
  bool _loading = false;
  String? _error;
  @override
  void dispose() {
    _season.dispose();
    _episode.dispose();
    super.dispose();
  }

  Future<void> _makePreview() async {
    setState(() {
      _loading = true;
      _error = null;
      _preview = null;
      _accepted.clear();
    });
    final ok = await widget.catalog.run(() async {
      final season = int.tryParse(_season.text);
      final first = int.tryParse(_episode.text);
      if (season == null || first == null) {
        throw const FilmCatalogException('invalidEpisode');
      }
      final preview = await widget.catalog.matcher.mappingPreview(
        _resources,
        season,
        first,
      );
      if (mounted) setState(() => _preview = preview);
    });
    if (mounted) {
      setState(() {
        _loading = false;
        if (!ok) _error = widget.catalog.error;
      });
    }
  }

  Future<void> _save() async {
    setState(() => _loading = true);
    final mappings = {
      for (final entry in _preview!.entries)
        if (_accepted.contains(entry.key.id)) entry.key: entry.value,
    };
    final ok = await widget.catalog.run(
      () => widget.catalog.store.mapEpisodes(mappings),
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _loading = false;
        _error = widget.catalog.error;
      });
    }
  }

  void _invalidate(String _) => setState(() {
    _preview = null;
    _accepted.clear();
  });
  @override
  Widget build(BuildContext context) => SPDialog(
    title: const AppText('季集映射预览'),
    content: SizedBox(
      width: 680,
      height: MediaQuery.sizeOf(context).height * 0.5,
      child: ListView(
        children: [
          TextField(
            controller: _season,
            onChanged: _invalidate,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(label: AppText('季号（0 为特别篇）')),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _episode,
            onChanged: _invalidate,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(label: AppText('首个集号')),
          ),
          TextButton(
            onPressed: _loading ? null : _makePreview,
            child: const AppText('生成映射预览'),
          ),
          const AppText('逐行确认真实文件与目标集；仅保存已勾选行'),
          const AppText('TMDB 未收录的集使用作品名称和图片'),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null) AppText(filmCatalogErrorText(_error!)),
          if (_preview != null)
            for (final entry in _preview!.entries)
              CheckboxListTile(
                value: _accepted.contains(entry.key.id),
                title: Text(entry.key.name),
                subtitle: Text(
                  '${entry.key.path}\nS${entry.value.$1}E${entry.value.$2}',
                ),
                onChanged: _loading
                    ? null
                    : (value) => setState(() {
                        if (value == true) {
                          _accepted.add(entry.key.id);
                        } else {
                          _accepted.remove(entry.key.id);
                        }
                      }),
              ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _loading ? null : () => Navigator.of(context).pop(),
        child: const AppText('取消'),
      ),
      FilledButton(
        onPressed: _loading || _preview == null || _accepted.isEmpty
            ? null
            : _save,
        child: const AppText('保存季集映射'),
      ),
    ],
  );
}
