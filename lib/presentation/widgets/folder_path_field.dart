import 'package:flutter/material.dart';

import 'clipboard_history_menu.dart';
import 'sp_icons.dart';

/// 桌面文件夹路径输入与选择入口。
class FolderPathField extends StatelessWidget {
  const FolderPathField({
    super.key,
    required this.controller,
    required this.label,
    required this.pickerTooltip,
    required this.onPick,
    this.fieldKey,
    this.pickerKey,
    this.helperText,
    this.validator,
    this.selecting = false,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String label;
  final String pickerTooltip;
  final VoidCallback onPick;
  final Key? fieldKey;
  final Key? pickerKey;
  final String? helperText;
  final FormFieldValidator<String>? validator;
  final bool selecting;
  final bool enabled;

  @override
  Widget build(BuildContext context) => TextFormField(
    key: fieldKey,
    controller: controller,
    enabled: enabled,
    contextMenuBuilder: buildClipboardHistoryMenu,
    validator: validator,
    decoration: InputDecoration(
      labelText: label,
      helperText: helperText,
      prefixIcon: const Icon(SPIcons.folder),
      suffixIcon: IconButton(
        key: pickerKey,
        tooltip: pickerTooltip,
        onPressed: enabled && !selecting ? onPick : null,
        icon: selecting
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(SPIcons.folderOpen),
      ),
      border: const OutlineInputBorder(),
    ),
  );
}
