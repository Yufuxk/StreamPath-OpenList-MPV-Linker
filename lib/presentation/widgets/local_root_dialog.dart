import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../data/models/local_root_config.dart';
import '../../domain/services/windows_folder_picker.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import 'clipboard_history_menu.dart';

class LocalRootDraft {
  const LocalRootDraft({
    required this.displayName,
    required this.path,
    required this.enabled,
  });

  final String displayName;
  final String path;
  final bool enabled;
}

Future<LocalRootDraft?> showLocalRootDialog(
  BuildContext context, {
  LocalRootConfig? initial,
}) => showDialog<LocalRootDraft>(
  context: context,
  builder: (context) => _LocalRootDialog(initial: initial),
);

class _LocalRootDialog extends StatefulWidget {
  const _LocalRootDialog({this.initial});

  final LocalRootConfig? initial;

  @override
  State<_LocalRootDialog> createState() => _LocalRootDialogState();
}

class _LocalRootDialogState extends State<_LocalRootDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _pathController;
  late bool _enabled;
  bool _selecting = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.initial?.displayName ?? '',
    );
    _pathController = TextEditingController(text: widget.initial?.path ?? '');
    _enabled = widget.initial?.enabled ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _pathController.dispose();
    super.dispose();
  }

  Future<void> _selectDirectory() async {
    setState(() => _selecting = true);
    try {
      final selected = await WindowsFolderPicker.pickDirectory(
        title: context.l10n.text('选择本地文件夹'),
      );
      if (!mounted || selected == null) return;
      _pathController.text = selected;
      if (_nameController.text.trim().isEmpty) {
        final name = p.basename(p.normalize(selected));
        _nameController.text = name.isEmpty ? selected : name;
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: AppText('无法打开 Windows 文件夹选择器')));
    } finally {
      if (mounted) setState(() => _selecting = false);
    }
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(
      LocalRootDraft(
        displayName: _nameController.text.trim(),
        path: _pathController.text.trim(),
        enabled: _enabled,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: AppText(widget.initial == null ? '添加本地文件夹' : '编辑本地文件夹'),
    content: SizedBox(
      width: 560,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              key: const Key('local-root-name-field'),
              controller: _nameController,
              contextMenuBuilder: buildClipboardHistoryMenu,
              decoration: InputDecoration(
                labelText: context.l10n.text('显示名称'),
                prefixIcon: const Icon(Icons.label_outline),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('local-root-path-field'),
              controller: _pathController,
              contextMenuBuilder: buildClipboardHistoryMenu,
              decoration: InputDecoration(
                labelText: context.l10n.text('本地目录'),
                helperText: context.l10n.text('可直接输入绝对路径，或使用 Windows 目录选择器。'),
                prefixIcon: const Icon(Icons.folder_outlined),
                suffixIcon: IconButton(
                  key: const Key('pick-local-root-button'),
                  tooltip: context.l10n.text('选择文件夹'),
                  onPressed: _selecting ? null : _selectDirectory,
                  icon: _selecting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.folder_open_outlined),
                ),
                border: const OutlineInputBorder(),
              ),
              validator: (value) {
                final path = value?.trim() ?? '';
                if (path.isEmpty) return context.l10n.text('请输入本地目录');
                if (!p.isAbsolute(path)) {
                  return context.l10n.text('本地目录必须是绝对路径');
                }
                return null;
              },
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const AppText('启用此本地文件夹'),
              value: _enabled,
              onChanged: (value) => setState(() => _enabled = value),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const AppText('取消'),
      ),
      FilledButton(onPressed: _submit, child: const AppText('确定')),
    ],
  );
}
