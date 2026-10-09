import 'sp_menu.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/errors/app_exception.dart';
import '../../data/models/film_catalog_item.dart';
import '../../data/local/film_catalog_store.dart';
import '../../domain/services/film_library_transfer.dart';
import '../../domain/services/windows_folder_picker.dart';
import '../controllers/film_catalog_controller.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import 'directory_scroll_view.dart';
import 'glass_dialog.dart';
import 'sp_dialog.dart';

Future<void> showFilmTransferDialog(
  BuildContext context, {
  bool importing = false,
}) => showGlassDialog<void>(
  context: context,
  builder: (_) => _FilmTransferDialog(importing: importing),
);

class _FilmTransferDialog extends StatefulWidget {
  const _FilmTransferDialog({required this.importing});
  final bool importing;
  @override
  State<_FilmTransferDialog> createState() => _FilmTransferDialogState();
}

class _FilmTransferDialogState extends State<_FilmTransferDialog> {
  bool _busy = false, _collections = false, _playing = false;
  String? _error, _result;
  Map<String, int>? _matches;
  FilmTransferPreview? _preview;
  final _categories = <String>{'metadata', 'playback', 'favorites', 'artwork'};
  final _mapping = <String, String>{};
  static const _labels = {
    'metadata': '作品与季集元数据',
    'playback': '续播、历史与观看状态',
    'favorites': '收藏',
    'artwork': '背景与封面偏好',
    'collections': '自定义合集结构',
  };
  @override
  void dispose() {
    _preview?.close();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() operation) async {
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      await operation();
    } on FilmCatalogException catch (error) {
      _error = filmCatalogErrorText(error.code);
    } on FileSystemException {
      _error = '导入导出文件操作失败';
    } on AppException {
      _error = '导入导出文件操作失败';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _choose() => _run(() async {
    final app = context.read<AppState>();
    final title = context.l10n.text('选择导入 ZIP');
    final file = await WindowsFolderPicker.pickArchive(title: title);
    if (file == null) return;
    final preview = await FilmLibraryTransfer.preflight(File(file));
    if (!mounted) {
      await preview.close();
      return;
    }
    await _preview?.close();
    _preview = preview;
    await app.getMediaConnections();
    final ids = {
      ...app.localRoots.map((r) => r.sourceId),
      ...app.configStore.current.profiles.map((r) => r.profileId),
      ...app.mediaConnections.map((r) => r.id),
    };
    for (final source in preview.sources) {
      _mapping[source] = ids.contains(source) ? source : '';
    }
    _playing = await app.anyPlaybackActive();
    if (_playing) _categories.remove('playback');
    await _updateMatches();
  });
  Future<void> _updateMatches() async {
    final preview = _preview;
    if (preview == null) return;
    final generation = Map<String, String>.of(_mapping);
    final result = await (await context.read<AppState>().getFilmCatalogStore())
        .previewPortable(
          Map<String, dynamic>.from(preview.data['catalog'] as Map),
          {
            for (final entry in generation.entries)
              if (entry.value.isNotEmpty) entry.key: entry.value,
          },
        );
    if (mounted &&
        generation.entries.every(
          (entry) => _mapping[entry.key] == entry.value,
        )) {
      setState(() => _matches = result);
    }
  }

  Future<void> _export() => _run(() async {
    final app = context.read<AppState>();
    await (await app.filmTransfer()).export(collections: _collections);
    _result = '导出完成';
  });
  Future<void> _import() => _run(() async {
    final result = await context
        .read<AppState>()
        .importFilmTransfer(_preview!, _categories, {
          for (final entry in _mapping.entries)
            if (entry.value.isNotEmpty) entry.key: entry.value,
        });
    if (!mounted) return;
    _result = context.l10n.format(
      '导入完成：匹配 {matched}，跳过 {skipped}，合集 {collections}',
      result,
    );
  });
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final sources = <String, String>{
      for (final root in app.localRoots) root.sourceId: root.displayName,
      for (final profile in app.configStore.current.profiles)
        profile.profileId: profile.name,
      for (final config in app.mediaConnections) config.id: config.name,
    };
    return PopScope(
      canPop: !_busy,
      child: SPDialog(
        title: AppText(widget.importing ? '导入影视库' : '导出影视库'),
        content: SizedBox(
          width: 600,
          height: widget.importing ? 520 : 180,
          child: DirectoryScrollView(
            builder: (controller) => ListView(
              controller: controller,
              children: [
                const AppText('合并缺失内容并保留本机冲突；凭据和运行中会话不参与迁移'),
                if (!widget.importing) ...[
                  const AppText('导出文件固定保存在 stream_path_data 目录'),
                  CheckboxListTile(
                    value: _collections,
                    title: const AppText('同时导出自定义合集'),
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _collections = value!),
                  ),
                ],
                if (widget.importing) ...[
                  TextButton(
                    onPressed: _busy ? null : _choose,
                    child: const AppText('选择导入 ZIP'),
                  ),
                  if (_preview != null) ...[
                    for (final category in _labels.entries)
                      CheckboxListTile(
                        title: Text(
                          '${context.l10n.text(category.value)} (${_preview!.counts[category.key] ?? 0})',
                        ),
                        value: _categories.contains(category.key),
                        onChanged:
                            _busy ||
                                category.key == 'playback' && _playing ||
                                category.key == 'collections' &&
                                    _preview!.counts['collections'] == 0
                            ? null
                            : (value) => setState(() {
                                if (value!) {
                                  _categories.add(category.key);
                                } else {
                                  _categories.remove(category.key);
                                }
                              }),
                      ),
                    if (_playing) const AppText('播放器运行期间不能导入播放状态'),
                    const AppText('来源映射'),
                    if (_matches != null)
                      Text(
                        context.l10n.format(
                          '预检结果：匹配 {matched}，跳过 {skipped}',
                          _matches!,
                        ),
                      ),
                    for (final source in _preview!.sources)
                      SPDropdownButtonFormField<String>(
                        dropdownColor: AppTheme.dropdownMenuColor(
                          Theme.of(context),
                        ),
                        borderRadius: AppTheme.dropdownBorderRadius,
                        initialValue: _mapping[source],
                        isExpanded: true,
                        decoration: InputDecoration(labelText: source),
                        items: [
                          const DropdownMenuItem(
                            value: '',
                            child: AppText('跳过未匹配来源'),
                          ),
                          for (final row in sources.entries)
                            DropdownMenuItem(
                              value: row.key,
                              child: Text(row.value),
                            ),
                        ],
                        onChanged: _busy
                            ? null
                            : (value) {
                                setState(() {
                                  _mapping[source] = value!;
                                  _matches = null;
                                });
                                _updateMatches();
                              },
                      ),
                  ],
                ],
                if (_busy) const LinearProgressIndicator(),
                if (_error != null)
                  AppText(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (_result != null) AppText(_result!),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const AppText('关闭'),
          ),
          FilledButton(
            onPressed:
                _busy ||
                    widget.importing &&
                        (_preview == null || _categories.isEmpty)
                ? null
                : widget.importing
                ? _import
                : _export,
            child: AppText(widget.importing ? '开始导入' : '导出'),
          ),
        ],
      ),
    );
  }
}
