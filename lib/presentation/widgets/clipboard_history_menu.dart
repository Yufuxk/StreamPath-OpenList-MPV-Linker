import 'package:flutter/material.dart';

import '../../core/utils/clipboard_history_fix.dart';
import '../../core/utils/clipboard_history_store.dart';
import '../../core/utils/clipboard_service.dart';

/// 输入框右键菜单构建器：在系统默认菜单之前插入「剪贴板历史」区，
/// 点击历史条目即可粘贴（不依赖系统 Win+V 注入，任何输入框可直接使用）：
///
/// ```dart
/// TextFormField(
///   contextMenuBuilder: buildClipboardHistoryMenu,
///   ...
/// )
/// ```
Widget buildClipboardHistoryMenu(
  BuildContext context,
  EditableTextState editableTextState,
) {
  final store = ClipboardHistoryStore.instance;
  return AdaptiveTextSelectionToolbar.buttonItems(
    anchors: editableTextState.contextMenuAnchors,
    buttonItems: [
      ...clipboardHistoryMenuItems(
        store,
        onPick: (text) {
          Navigator.pop(context);
          ClipboardHistoryFix.injectPaste(text);
        },
        onPickCurrentClipboard: () {
          _pasteCurrentClipboard(context);
        },
        onClearHistory: () {
          Navigator.pop(context);
          store.clear();
        },
      ),
      // 系统默认按钮（复制/粘贴/全选…）。
      ...editableTextState.contextMenuButtonItems,
    ],
  );
}

/// 读取系统剪贴板并粘贴到聚焦输入框（「粘贴当前剪贴板」兜底入口）。
Future<void> _pasteCurrentClipboard(BuildContext context) async {
  final text = await ClipboardService.instance.readPlainText();
  if (!context.mounted) return;
  Navigator.pop(context);
  if (text != null && text.isNotEmpty) {
    ClipboardHistoryStore.instance.add(text);
    ClipboardHistoryFix.injectPaste(text);
  }
}

/// 构建「剪贴板历史」菜单项（含「粘贴当前剪贴板」与「清空历史」）。
///
/// 抽成纯函数便于单元测试；[onPick] 在点击历史条目时回调，
/// [onPickCurrentClipboard] 在点击「粘贴当前剪贴板」时回调，
/// [onClearHistory] 在点击「清空剪贴板历史」时回调。
@visibleForTesting
List<ContextMenuButtonItem> clipboardHistoryMenuItems(
  ClipboardHistoryStore store, {
  required void Function(String text) onPick,
  required VoidCallback onPickCurrentClipboard,
  required VoidCallback onClearHistory,
}) {
  const maxLabelLength = 24;
  String labelOf(String text) => text.length > maxLabelLength
      ? '${text.substring(0, maxLabelLength)}…'
      : text;

  return [
    if (store.items.isEmpty)
      const ContextMenuButtonItem(label: '剪贴板历史为空', onPressed: null)
    else
      for (final item in store.items.take(5))
        ContextMenuButtonItem(
          label: labelOf(item),
          onPressed: () => onPick(item),
        ),
    ContextMenuButtonItem(
      label: '粘贴当前剪贴板',
      onPressed: onPickCurrentClipboard,
    ),
    if (store.items.isNotEmpty)
      ContextMenuButtonItem(
        label: '清空剪贴板历史',
        onPressed: onClearHistory,
      ),
  ];
}
