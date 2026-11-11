import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../data/local/film_catalog_store.dart';
import '../../data/models/film_catalog_item.dart';
import '../../data/models/film_extra.dart';
import '../../domain/services/film_extra_classifier.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import 'directory_scroll_view.dart';
import 'glass_dialog.dart';
import 'sp_dialog.dart';
import 'sp_controls.dart';
import 'sp_icons.dart';
import 'sp_menu.dart';
import 'sp_notice.dart';

String filmExtraLabel(
  BuildContext context,
  FilmCatalogStore store,
  String kind,
) {
  if (kind == '@none') return context.l10n.text('非特典');
  if (kind == '@unknown') return context.l10n.text('尚未分类');
  final type = store.extraRules.type(kind);
  final builtin = FilmExtraRules.defaults
      .where((t) => t.id == kind)
      .firstOrNull;
  return !type.custom && builtin?.label == type.label
      ? context.l10n.text(type.label)
      : type.label;
}

String filmExtraFilterKey(FilmResource resource) =>
    resource.extraKind ??
    (resource.extraStatus == 'non_extra' ? '@none' : '@unknown');

class FilmExtraFilter extends StatelessWidget {
  const FilmExtraFilter({
    super.key,
    required this.store,
    required this.resources,
    required this.selected,
    required this.onChanged,
  });
  final FilmCatalogStore store;
  final List<FilmResource> resources;
  final String? selected;
  final ValueChanged<String?> onChanged;
  @override
  Widget build(BuildContext context) {
    final counts = <String, int>{};
    for (final r in resources) {
      final key = filmExtraFilterKey(r);
      counts.update(key, (v) => v + 1, ifAbsent: () => 1);
    }
    return SizedBox(
      width: 220,
      child: SPDropdownButtonFormField<String>(
        key: ValueKey('film-extra-filter-${selected ?? 'all'}'),
        initialValue: selected != null && counts.containsKey(selected)
            ? selected
            : '',
        isExpanded: true,
        menuIcon: SPIcons.settings,
        decoration: InputDecoration(labelText: context.l10n.text('特典分类')),
        items: [
          DropdownMenuItem(
            value: '',
            child: Text('${context.l10n.text('全部特典')} (${resources.length})'),
          ),
          for (final type in store.extraRules.types.where(
            (t) => counts.containsKey(t.id),
          ))
            DropdownMenuItem(
              value: type.id,
              child: Text(
                '${filmExtraLabel(context, store, type.id)} (${counts[type.id]})',
              ),
            ),
          for (final key in ['@none', '@unknown'].where(counts.containsKey))
            DropdownMenuItem(
              value: key,
              child: Text(
                '${filmExtraLabel(context, store, key)} (${counts[key]})',
              ),
            ),
        ],
        onChanged: (value) => onChanged(value == '' ? null : value),
      ),
    );
  }
}

Future<void> showFilmExtraPicker(
  BuildContext context,
  FilmCatalogStore store,
  FilmResource resource,
) async {
  final value = await showGlassDialog<String>(
    context: context,
    builder: (dialogContext) => SPDialog(
      title: const AppText('修改特典类型'),
      content: SizedBox(
        width: 420,
        height: 420,
        child: DirectoryScrollView(
          builder: (controller) => ListView(
            controller: controller,
            children: [
              for (final id in [
                '@auto',
                '@none',
                ...store.extraRules.types.map((t) => t.id),
              ])
                SPTile(
                  selected: id == '@auto'
                      ? resource.extraOrigin != 'manual'
                      : id == '@none'
                      ? resource.extraOrigin == 'manual' && !resource.isExtra
                      : resource.extraOrigin == 'manual' &&
                            resource.extraKind == id,
                  onTap: () => Navigator.of(dialogContext).pop(id),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      id == '@auto'
                          ? context.l10n.text('自动识别')
                          : id == '@none'
                          ? context.l10n.text('非特典')
                          : filmExtraLabel(context, store, id),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const AppText('取消'),
        ),
      ],
    ),
  );
  if (value == null) return;
  await store.setExtraType(
    resource,
    value.startsWith('@') ? null : value,
    automatic: value == '@auto',
  );
}

Future<void> showFilmExtraSettings(
  BuildContext context,
  FilmCatalogStore store,
) => showGlassDialog<void>(
  context: context,
  builder: (_) => _ExtraSettings(store: store),
);

class _ExtraSettings extends StatefulWidget {
  const _ExtraSettings({required this.store});
  final FilmCatalogStore store;
  @override
  State<_ExtraSettings> createState() => _ExtraSettingsState();
}

class _ExtraSettingsState extends State<_ExtraSettings> {
  late final List<FilmExtraType> _types = List.of(
    widget.store.extraRules.types,
  );
  bool _saving = false;
  Future<void> _edit([FilmExtraType? type]) async {
    final result = await showGlassDialog<FilmExtraType>(
      context: context,
      builder: (_) => _ExtraTypeEditor(type: type, types: _types),
    );
    if (result == null || !mounted) return;
    setState(() {
      if (type == null) {
        _types.add(result);
      } else {
        _types[_types.indexOf(type)] = result;
      }
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.store.saveExtraRules(List.of(_types));
      if (mounted) Navigator.of(context).pop();
    } on FormatException catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SPNotice(
            content: Text(context.l10n.text(_extraError(error.message))),
          ),
        );
      }
    } on DatabaseException {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SPNotice(content: Text(context.l10n.text('特典分类保存失败'))));
      }
    }
  }

  @override
  Widget build(BuildContext context) => SPDialog(
    title: const AppText('特典分类管理'),
    content: SizedBox(
      width: 640,
      height: 480,
      child: DirectoryScrollView(
        builder: (controller) => ListView(
          controller: controller,
          children: [
            const AppText('修改显示名称与识别别名，保存后自动更新已有分类；人工分类保持不变'),
            const SizedBox(height: 12),
            for (final type in _types)
              SPTile(
                onTap: _saving ? null : () => _edit(type),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              type.custom ||
                                      FilmExtraRules.defaults
                                              .firstWhere(
                                                (t) => t.id == type.id,
                                              )
                                              .label !=
                                          type.label
                                  ? type.label
                                  : context.l10n.text(type.label),
                            ),
                            Text(
                              type.aliases.join(' · '),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const Icon(SPIcons.edit, size: 18),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => _edit(),
        child: const AppText('新增分类'),
      ),
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).pop(),
        child: const AppText('取消'),
      ),
      FilledButton(
        onPressed: _saving ? null : _save,
        child: const AppText('保存'),
      ),
    ],
  );
}

String _extraError(String code) => switch (code) {
  'duplicateExtraAlias' => '识别别名重复或占用了通用特典名称',
  'emptyExtraAlias' => '请填写至少一个识别别名',
  _ => '请填写有效的分类名称',
};

class _ExtraTypeEditor extends StatefulWidget {
  const _ExtraTypeEditor({this.type, required this.types});
  final FilmExtraType? type;
  final List<FilmExtraType> types;
  @override
  State<_ExtraTypeEditor> createState() => _ExtraTypeEditorState();
}

class _ExtraTypeEditorState extends State<_ExtraTypeEditor> {
  late final _name = TextEditingController(text: widget.type?.label);
  late final _aliases = TextEditingController(
    text: widget.type?.aliases.join('\n'),
  );
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _aliases.dispose();
    super.dispose();
  }

  void _save() {
    final value = FilmExtraType(
      widget.type?.id ?? 'custom:${DateTime.now().microsecondsSinceEpoch}',
      _name.text.trim(),
      _aliases.text
          .split(RegExp(r'[,，\n]'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList(),
      custom: widget.type?.custom ?? true,
    );
    try {
      FilmExtraClassifier.validateRules([
        for (final t in widget.types)
          if (t.id != value.id) t,
        value,
      ]);
      Navigator.of(context).pop(value);
    } on FormatException catch (error) {
      setState(() => _error = _extraError(error.message));
    }
  }

  @override
  Widget build(BuildContext context) => SPDialog(
    title: AppText(widget.type == null ? '新增分类' : '编辑特典分类'),
    content: SizedBox(
      width: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('film-extra-type-name'),
            controller: _name,
            decoration: InputDecoration(labelText: context.l10n.text('分类名称')),
          ),
          const SizedBox(height: 16),
          if (widget.type?.id != 'mixed')
            TextField(
              key: const Key('film-extra-type-aliases'),
              controller: _aliases,
              minLines: 3,
              maxLines: 7,
              decoration: InputDecoration(
                labelText: context.l10n.text('识别别名'),
                helperText: context.l10n.text('每行一个别名，也可用逗号分隔；按字面词元匹配'),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                context.l10n.text(_error!),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const AppText('取消'),
      ),
      FilledButton(onPressed: _save, child: const AppText('保存')),
    ],
  );
}
