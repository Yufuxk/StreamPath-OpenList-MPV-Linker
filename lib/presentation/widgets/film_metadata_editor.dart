import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../core/errors/app_exception.dart';

import '../../data/models/film_catalog_item.dart';
import '../../data/local/film_catalog_store.dart';
import '../../data/models/film_metadata_edit.dart';
import '../../domain/services/film_metadata_artwork.dart';
import '../../domain/services/windows_folder_picker.dart';
import '../controllers/film_catalog_controller.dart';
import '../localization/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/glass_tokens.dart';
import 'directory_scroll_view.dart';
import 'film_artwork.dart';
import 'film_segmented_control.dart';
import 'glass_dialog.dart';
import 'sp_controls.dart';
import 'sp_dialog.dart';
import 'sp_menu.dart';

Future<void> showFilmMetadataEditor(
  BuildContext context,
  FilmCatalogController catalog,
  FilmMetadataTarget target, {
  String? image,
}) async {
  await showGlassDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        _MetadataEditor(catalog: catalog, target: target, image: image),
  );
}

const _labels = <String, String>{
  'title': '标题',
  'original_title': '原名',
  'sort_title': '排序名',
  'overview': '简介',
  'tagline': '标语',
  'year': '年份',
  'release_date': '上映/播出日期',
  'original_language': '原始语言',
  'genres': '类型',
  'origin_country': '国家/地区',
  'certification': '分级',
  'certification_country': '分级地区',
  'vote_average': '评分',
  'tags': '标签',
  'production_companies': '制作公司',
  'runtime': '展示时长（分钟）',
  'poster_path': '封面',
  'backdrop_path': '背景图',
  'logo_path': 'Logo',
};
const _lists = {'genres', 'origin_country', 'tags', 'production_companies'};
const _numbers = {'year', 'runtime', 'vote_average'};
const _basic = [
  'title',
  'original_title',
  'sort_title',
  'overview',
  'tagline',
  'year',
  'release_date',
  'original_language',
  'runtime',
  'vote_average',
];
const _classification = [
  'genres',
  'origin_country',
  'certification',
  'certification_country',
  'tags',
  'production_companies',
];

class _MetadataEditor extends StatefulWidget {
  const _MetadataEditor({
    required this.catalog,
    required this.target,
    this.image,
  });
  final FilmCatalogController catalog;
  final FilmMetadataTarget target;
  final String? image;
  @override
  State<_MetadataEditor> createState() => _MetadataEditorState();
}

class _MetadataEditorState extends State<_MetadataEditor> {
  FilmMetadataSnapshot? _snapshot;
  late FilmMetadataTarget _target = widget.target;
  late final _artwork = FilmMetadataArtwork(
    widget.catalog.images.managedArtworkDirectory,
    widget.catalog.images,
  );
  final _controllers = <String, TextEditingController>{};
  final _changes = <String, dynamic>{};
  final _restore = <String>{};
  final _candidates = <String, List<Map<String, dynamic>>>{};
  int _tab = 0;
  late String _image = widget.image ?? 'poster_path';
  String _language = '*';
  String? _error, _imageError;
  bool _busy = false,
      _loadingImages = false,
      _canPop = false,
      _importing = false;
  final _fieldErrors = <String, String>{};
  bool get _dirty => _changes.isNotEmpty || _restore.isNotEmpty;
  Map<String, dynamic> get _values => {
    ...?_snapshot?.values,
    for (final key in _restore) key: _snapshot!.source[key],
    ..._changes,
  };
  String tr(String value) => context.l10n.text(value);

  @override
  void initState() {
    super.initState();
    _tab = widget.image == null ? 0 : 2;
    unawaited(_load());
  }

  @override
  void dispose() {
    _artwork.cancel();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final snapshot = await widget.catalog.store.metadataSnapshot(_target);
      if (!mounted) return;
      for (final controller in _controllers.values) {
        controller.dispose();
      }
      _controllers.clear();
      _changes.clear();
      _restore.clear();
      _candidates.clear();
      _snapshot = snapshot;
      _artwork.track(
        snapshot.overrides.values.whereType<String>().where(
          (v) => v.startsWith('sp-image:'),
        ),
      );
      _fieldErrors.clear();
      for (final key in [..._basic, ..._classification]) {
        final value = snapshot.values[key];
        _controllers[key] = TextEditingController(
          text: _lists.contains(key)
              ? (value as List? ?? [])
                    .map((e) => e is Map ? e['name'] ?? '' : e)
                    .join(', ')
              : '${value ?? ''}',
        );
      }
      if (_tab == 2) unawaited(_loadImages());
    } on FilmCatalogException catch (e) {
      if (mounted) _error = filmCatalogErrorText(e.code);
    } on DatabaseException {
      if (mounted) _error = filmCatalogErrorText('catalogStorageFailed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _change(String key, dynamic value) {
    setState(() {
      _restore.remove(key);
      _fieldErrors.remove(key);
      if (filmMetadataEqual(value, _snapshot!.values[key])) {
        _changes.remove(key);
      } else {
        _changes[key] = value;
      }
    });
  }

  void _reset(String key) {
    setState(() {
      _changes.remove(key);
      if (_snapshot!.overrides.containsKey(key)) _restore.add(key);
      final value = _values[key];
      if (_controllers[key] case final TextEditingController c) {
        c.text = _lists.contains(key)
            ? (value as List? ?? [])
                  .map((e) => e is Map ? e['name'] ?? '' : e)
                  .join(', ')
            : '${value ?? ''}';
      }
    });
  }

  bool _supported(String key) => switch (_target.level) {
    FilmMetadataLevel.season => {
      'title',
      'sort_title',
      'overview',
      'year',
      'release_date',
    }.contains(key),
    FilmMetadataLevel.episode => !{
      'tagline',
      'original_language',
      ..._classification,
    }.contains(key),
    _ => true,
  };

  Widget _custom(String key) {
    final custom =
        _changes.containsKey(key) ||
        _snapshot!.overrides.containsKey(key) && !_restore.contains(key);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (custom)
          Text(tr('已自定义'), style: Theme.of(context).textTheme.labelSmall),
        TextButton(
          onPressed: custom ? () => _reset(key) : null,
          child: Text(tr('恢复来源值')),
        ),
      ],
    );
  }

  Widget _field(String key) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          children: [Text(tr(_labels[key]!)), _custom(key)],
        ),
        const SizedBox(height: 6),
        TextFormField(
          contextMenuBuilder: buildSPTextSelectionMenu,
          key: ValueKey('metadata:$key'),
          controller: _controllers[key],
          minLines: key == 'overview' ? 3 : 1,
          maxLines: key == 'overview' ? 6 : 1,
          decoration: InputDecoration(
            errorText: _fieldErrors[key] == null
                ? null
                : tr(_fieldErrors[key]!),
            helperText: _lists.contains(key)
                ? tr('多项以逗号分隔')
                : key == 'release_date'
                ? 'YYYY-MM-DD'
                : null,
          ),
          onChanged: (text) {
            dynamic value = text;
            if (_numbers.contains(key)) {
              value = text.trim().isEmpty
                  ? null
                  : key == 'vote_average'
                  ? num.tryParse(text) ?? text
                  : int.tryParse(text) ?? text;
            }
            if (_lists.contains(key)) {
              final names = text
                  .split(RegExp('[,，]'))
                  .map((s) => s.trim())
                  .where((s) => s.isNotEmpty)
                  .toList();
              value = key == 'production_companies'
                  ? [
                      for (final name in names)
                        (_snapshot!.values[key] as List? ?? [])
                                .whereType<Map>()
                                .where((e) => e['name'] == name)
                                .firstOrNull ??
                            {'name': name},
                    ]
                  : names;
            }
            _change(key, value);
          },
        ),
      ],
    ),
  );

  Future<bool> _save({bool close = true}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _fieldErrors.clear();
      final values = _values;
      if ((values['title'] as String? ?? '').trim().isEmpty) {
        _fieldErrors['title'] = '标题不能为空';
      }
      for (final key in _numbers) {
        final v = values[key];
        if (v != null &&
            (v is! num ||
                !v.isFinite ||
                v < 0 ||
                key == 'year' && (v < 1 || v > 9999 || v is! int) ||
                key == 'runtime' && v is! int ||
                key == 'vote_average' && v > 10)) {
          _fieldErrors[key] = '年份、评分或时长格式不正确';
        }
      }
      final date = values['release_date'] as String? ?? '';
      if (date.isNotEmpty) {
        final parsed = DateTime.tryParse(date);
        if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ||
            parsed == null ||
            parsed.toIso8601String().substring(0, 10) != date ||
            values['year'] != null && parsed.year != values['year']) {
          _fieldErrors['release_date'] = '日期格式不正确或与年份不一致';
        }
      }
      if (_fieldErrors.isNotEmpty) {
        _tab = 0;
        throw const FilmCatalogException('invalidMetadata');
      }
      validateFilmMetadata(values);
      await widget.catalog.store.saveMetadata(
        _snapshot!,
        _changes,
        restore: _restore,
      );
      await _artwork.cleanup(
        await widget.catalog.store.metadataArtworkReferences(),
      );
      if (!mounted) return false;
      _changes.clear();
      _restore.clear();
      if (close) {
        setState(() => _canPop = true);
        Navigator.pop(context);
      }
      return true;
    } on FilmCatalogException catch (e) {
      if (mounted) _error = filmCatalogErrorText(e.code);
    } on FileSystemException {
      if (mounted) _error = '无法保存元数据';
    } on DatabaseException {
      if (mounted) _error = filmCatalogErrorText('catalogStorageFailed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    return false;
  }

  Future<bool> _leave() async {
    if (!_dirty) return true;
    final choice = await showGlassDialog<String>(
      context: context,
      builder: (context) => SPDialog(
        title: Text(tr('保存修改？')),
        content: Text(tr('当前修改尚未保存。')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: Text(tr('继续编辑')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: Text(tr('放弃')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'save'),
            child: Text(tr('保存')),
          ),
        ],
      ),
    );
    if (choice == 'save') return _save(close: false);
    return choice == 'discard';
  }

  Future<void> _close() async {
    if (_busy || !await _leave() || !mounted) return;
    _artwork.cancel();
    await _artwork.cleanup(
      await widget.catalog.store.metadataArtworkReferences(),
    );
    if (!mounted) return;
    setState(() => _canPop = true);
    Navigator.pop(context);
  }

  Future<void> _switch(FilmMetadataTarget target) async {
    if (!await _leave() || !mounted) return;
    _target = target;
    _imageError = null;
    _language = '*';
    _loadingImages = false;
    await _load();
  }

  Future<void> _loadImages() async {
    if (_loadingImages || _snapshot == null) return;
    final target = _target;
    final snapshot = _snapshot!;
    setState(() {
      _loadingImages = true;
      _imageError = null;
    });
    for (final key in ['poster_path', 'backdrop_path', 'logo_path']) {
      final rows = _candidates.putIfAbsent(key, () => []);
      final saved =
          snapshot.values[key.replaceFirst('_path', '_candidates')] as List? ??
          [];
      for (final item in saved.whereType<Map>()) {
        final path = item['path'] ?? item['file_path'];
        if (path is String && !rows.any((e) => e['path'] == path)) {
          rows.add({
            ...Map<String, dynamic>.from(item),
            'path': path,
            'language': item['language'] ?? item['iso_639_1'],
          });
        }
      }
    }
    try {
      final work = snapshot.work;
      if (work != null && work.tmdbId > 0 && work.metadataOrigin == 'network') {
        final r = snapshot.resource;
        final season =
            target.season ?? (r?.type == FilmMediaType.tv ? r?.season : null);
        final episode =
            target.episode ?? (r?.type == FilmMediaType.tv ? r?.episode : null);
        final images = await widget.catalog.tmdb.imageCandidates(
          work.type,
          work.tmdbId,
          season: season,
          episode: episode,
        );
        if (!mounted || !identical(target, _target)) return;
        _candidates.addAll(images);
        await widget.catalog.store.saveMetadataCandidates(snapshot, images);
      }
    } on FilmCatalogException catch (e) {
      if (mounted && identical(target, _target)) {
        _imageError = filmCatalogErrorText(e.code);
      }
    } on DatabaseException {
      if (mounted && identical(target, _target)) {
        _imageError = filmCatalogErrorText('catalogStorageFailed');
      }
    } finally {
      if (mounted && identical(target, _target)) {
        setState(() => _loadingImages = false);
      }
    }
  }

  Future<void> _import(
    Future<String?> Function() action, {
    String? source,
  }) async {
    setState(() {
      _busy = true;
      _importing = true;
      _imageError = null;
    });
    try {
      final path = await action();
      if (mounted && path != null) {
        _change(_image, path);
        _change('image_sources', {
          ...?(_values['image_sources'] as Map?),
          _image: source,
        });
      }
    } on FilmCatalogException catch (e) {
      if (mounted) _imageError = filmCatalogErrorText(e.code);
    } on FileSystemException {
      if (mounted) _imageError = '无法读取图片';
    } on AppException catch (e) {
      if (mounted) _imageError = e.message;
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _importing = false;
        });
      }
    }
  }

  Future<String?> _url() async {
    final controller = TextEditingController();
    try {
      final value = await showGlassDialog<String>(
        context: context,
        builder: (context) => SPDialog(
          title: Text(tr('图片网址')),
          content: TextField(
            contextMenuBuilder: buildSPTextSelectionMenu,
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'https://…'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr('取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: Text(tr('导入')),
            ),
          ],
        ),
      );
      return value == null ? null : await _artwork.fromUrl(value);
    } finally {
      controller.dispose();
    }
  }

  Widget _images() {
    final rows = _candidates[_image] ?? [];
    final languages =
        rows.map((r) => r['language'] as String? ?? '').toSet().toList()
          ..sort();
    final visible = rows
        .where((r) => _language == '*' || (r['language'] ?? '') == _language)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilmSegmentedControl<String>(
            selected: _image,
            onSelectionChanged: (key) => setState(() {
              _image = key;
              _language = '*';
            }),
            segments: [
              for (final key in ['poster_path', 'backdrop_path', 'logo_path'])
                ButtonSegment(value: key, label: Text(tr(_labels[key]!))),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _preview(),
        const SizedBox(height: 8),
        _custom(_image),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: () => _import(() async {
                final file = await WindowsFolderPicker.pickImage(
                  title: tr('选择图片'),
                );
                return file == null ? null : _artwork.fromFile(File(file));
              }),
              child: Text(tr('本地图片')),
            ),
            OutlinedButton(
              onPressed: () => _import(_url),
              child: Text(tr('图片网址')),
            ),
            TextButton(
              onPressed: () => _change(_image, ''),
              child: Text(tr('不显示该图')),
            ),
            TextButton(
              onPressed: _loadingImages ? null : _loadImages,
              child: Text(tr('刷新图片候选')),
            ),
          ],
        ),
        if (_loadingImages) const LinearProgressIndicator(),
        if (_imageError != null)
          Text(
            tr(_imageError!),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const SizedBox(height: 16),
        SPDropdownButtonFormField<String>(
          key: ValueKey(_image),
          initialValue: languages.contains(_language) || _language == '*'
              ? _language
              : '*',
          items: [
            DropdownMenuItem(value: '*', child: Text(tr('全部语言'))),
            for (final language in languages)
              DropdownMenuItem(
                value: language,
                child: Text(language.isEmpty ? tr('无语言') : language),
              ),
          ],
          onChanged: (value) => setState(() => _language = value!),
        ),
        const SizedBox(height: 12),
        if (!_loadingImages && visible.isEmpty) Text(tr('暂无候选图片，可导入本地文件或网址')),
      ],
    );
  }

  /// 当前图片的预览区；图片按完整内容居中显示，边缘只由底板圆角裁切。
  Widget _preview() {
    final glass = Theme.of(context).glass;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 384, maxHeight: 216),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: glass.contentSurface,
              borderRadius: AppTheme.controlRadius,
              border: Border.all(color: glass.borderColor),
            ),
            child: FilmArtwork(
              cache: widget.catalog.images,
              path: _values[_image] as String?,
              transparent: true,
              alignment: Alignment.center,
              borderRadius: 0,
              aspectRatio: 16 / 9,
            ),
          ),
        ),
      ),
    );
  }

  List<Map<String, dynamic>> get _visibleCandidates =>
      (_candidates[_image] ?? [])
          .where((r) => _language == '*' || (r['language'] ?? '') == _language)
          .toList();

  bool _picked(Map<String, dynamic> row) =>
      _values[_image] == row['path'] ||
      _values[_image] != '' &&
          !_restore.contains(_image) &&
          (_values['image_sources'] as Map?)?[_image] == row['path'];

  /// 候选图按原始宽高比显示，圆角始终贴合图片自身边界。
  double _candidateAspect(Map<String, dynamic> row) {
    final width = row['width'], height = row['height'];
    return width is num && height is num && width > 0 && height > 0
        ? width / height
        : 2 / 3;
  }

  Widget _imageRow(int start) {
    final visible = _visibleCandidates;
    final color = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final row in visible.skip(start).take(3))
            Expanded(
              child: SPTile(
                onTap: () => _import(
                  () => _artwork.fromReference(row['path'] as String),
                  source: row['path'] as String,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    children: [
                      Visibility(
                        visible: _picked(row),
                        maintainSize: true,
                        maintainAnimation: true,
                        maintainState: true,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            tr('已选中'),
                            style: TextStyle(color: color),
                          ),
                        ),
                      ),
                      SizedBox(
                        height: 120,
                        child: Center(
                          child: FilmArtwork(
                            cache: widget.catalog.images,
                            path: row['path'] as String,
                            target: 'w300',
                            aspectRatio: _candidateAspect(row),
                            transparent: true,
                            borderRadius: 8,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${row['language'] ?? tr('无语言')} · ${row['width'] ?? '?'}×${row['height'] ?? '?'}',
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _editorBody(
    ScrollController controller,
    FilmWork? work,
    FilmResource? r,
  ) {
    if (_tab == 2) {
      return ListView.builder(
        controller: controller,
        // 弹窗正文不占用窗口标题栏留出的顶部内边距。
        padding: EdgeInsets.zero,
        itemCount: 1 + (_visibleCandidates.length + 2) ~/ 3,
        itemBuilder: (_, index) =>
            index == 0 ? _images() : _imageRow((index - 1) * 3),
      );
    }
    return ListView(
      controller: controller,
      padding: EdgeInsets.zero,
      children: _tab == 0
          ? [
              for (final key in _basic.where(_supported)) _field(key),
              SelectableText(
                '${work?.type.name ?? r?.type.name ?? ''} · TMDB ${work?.tmdbId ?? ''}${r == null ? '' : '\n${r.path}'}${_target.season == null ? '' : '\nS${_target.season} E${_target.episode ?? ''}'}',
                contextMenuBuilder: buildSPTextSelectionMenu,
              ),
            ]
          : [
              for (final key in _classification.where(_supported)) _field(key),
              if (_target.level != FilmMetadataLevel.season) _people(),
            ],
    );
  }

  Widget _people() {
    final credits = Map<String, dynamic>.from(_values['credits'] as Map? ?? {});
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(children: [Text(tr('演职员')), _custom('credits')]),
        for (final kind in ['cast', 'crew']) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(tr(kind == 'cast' ? '演员' : '导演/编剧及其他人员')),
          ),
          for (var i = 0; i < (credits[kind] as List? ?? []).length; i++)
            _person(credits, kind, i),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: () {
                final list = [...(credits[kind] as List? ?? [])];
                list.add({
                  'identity': 'local:${DateTime.now().microsecondsSinceEpoch}',
                  'name': '',
                  if (kind == 'cast') 'character': '',
                  if (kind == 'crew') 'job': '',
                });
                _change('credits', {...credits, kind: list});
              },
              child: Text(tr('添加人员')),
            ),
          ),
        ],
      ],
    );
  }

  Widget _person(Map<String, dynamic> credits, String kind, int index) {
    final list = List<dynamic>.from(credits[kind] as List);
    final person = Map<String, dynamic>.from(list[index] as Map);
    void update(String key, String text) {
      list[index] = {...person, key: text};
      _change('credits', {...credits, kind: list});
    }

    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 14),
      child: Column(
        children: [
          TextFormField(
            contextMenuBuilder: buildSPTextSelectionMenu,
            key: ValueKey('${person['identity'] ?? person['id']}:name:$kind'),
            initialValue: person['name'] as String? ?? '',
            decoration: InputDecoration(labelText: tr('姓名')),
            onChanged: (v) => update('name', v),
          ),
          const SizedBox(height: 8),
          TextFormField(
            contextMenuBuilder: buildSPTextSelectionMenu,
            key: ValueKey('${person['identity'] ?? person['id']}:role:$kind'),
            initialValue:
                person[kind == 'cast' ? 'character' : 'job'] as String? ?? '',
            decoration: InputDecoration(labelText: tr('角色/职务')),
            onChanged: (v) => update(kind == 'cast' ? 'character' : 'job', v),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              TextButton(
                onPressed: index == 0
                    ? null
                    : () {
                        final p = list.removeAt(index);
                        list.insert(index - 1, p);
                        _change('credits', {...credits, kind: list});
                      },
                child: Text(tr('上移')),
              ),
              TextButton(
                onPressed: index == list.length - 1
                    ? null
                    : () {
                        final p = list.removeAt(index);
                        list.insert(index + 1, p);
                        _change('credits', {...credits, kind: list});
                      },
                child: Text(tr('下移')),
              ),
              TextButton(
                onPressed: () {
                  list.removeAt(index);
                  _change('credits', {...credits, kind: list});
                },
                child: Text(tr('删除')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final r = snapshot?.resource;
    final work = snapshot?.work;
    final level = ['作品', '季', '单集', '当前资源'][_target.level.index];
    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: SPDialog(
        title: Text(tr('编辑元数据…')),
        content: SizedBox(
          width: 860,
          height: MediaQuery.sizeOf(context).height * .7,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (snapshot != null) ...[
                Text(
                  '${tr(level)} · ${snapshot.values['title'] ?? ''}',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  tr(
                    _target.level == FilmMetadataLevel.resource
                        ? '仅影响当前资源版本'
                        : _target.level == FilmMetadataLevel.episode
                        ? '影响本集所有资源版本'
                        : '影响此对象的所有显示位置',
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (r != null && work != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _switch(FilmMetadataTarget.work(work.id)),
                          child: Text(tr('编辑所属作品')),
                        ),
                        if (r.season != null)
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _switch(
                                    FilmMetadataTarget.season(
                                      work.id,
                                      r.season,
                                    ),
                                  ),
                            child: Text(tr('编辑所属季')),
                          ),
                        if (r.season != null && r.episode != null)
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _switch(
                                    FilmMetadataTarget.episode(
                                      work.id,
                                      r.season,
                                      r.episode,
                                    ),
                                  ),
                            child: Text(tr('编辑共享单集')),
                          ),
                      ],
                    ),
                  ),
                if (widget.target.resourceId != null &&
                    _target.level != FilmMetadataLevel.resource)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(
                        onPressed: _busy ? null : () => _switch(widget.target),
                        child: Text(tr('编辑当前资源')),
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FilmSegmentedControl<int>(
                    selected: _tab,
                    onSelectionChanged: (tab) {
                      setState(() => _tab = tab);
                      if (tab == 2 && _candidates.isEmpty) {
                        unawaited(_loadImages());
                      }
                    },
                    segments: [
                      for (var i = 0; i < 3; i++)
                        ButtonSegment(
                          value: i,
                          enabled: !_busy,
                          label: Text(tr(['基本资料', '分类与人员', '图片'][i])),
                        ),
                    ],
                  ),
                ),
              ],
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                Text(
                  tr(_error!),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const SizedBox(height: 12),
              Expanded(
                child: snapshot == null
                    ? const SizedBox.shrink()
                    : IgnorePointer(
                        ignoring: _busy,
                        child: DirectoryScrollView(
                          builder: (controller) =>
                              _editorBody(controller, work, r),
                        ),
                      ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy || snapshot == null
                ? null
                : () async {
                    final yes = await showGlassDialog<bool>(
                      context: context,
                      builder: (context) => SPDialog(
                        title: Text(tr('恢复全部自定义项？')),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: Text(tr('取消')),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: Text(tr('恢复')),
                          ),
                        ],
                      ),
                    );
                    if (yes == true && mounted) {
                      for (final key in {
                        ...snapshot.overrides.keys,
                        ..._changes.keys,
                      }) {
                        _reset(key);
                      }
                    }
                  },
            child: Text(tr('恢复全部')),
          ),
          TextButton(
            onPressed: _importing
                ? _artwork.cancelDownloads
                : _busy
                ? null
                : _close,
            child: Text(tr(_importing ? '取消下载' : '取消')),
          ),
          FilledButton(
            onPressed: _busy || snapshot == null || !_dirty
                ? null
                : () => _save(),
            child: Text(tr('保存')),
          ),
        ],
      ),
    );
  }
}
