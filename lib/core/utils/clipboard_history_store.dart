import 'package:flutter/foundation.dart';

/// 应用内剪贴板历史（输入框右键菜单「剪贴板历史」的数据源）。
///
/// 由原生层 `WM_CLIPBOARDUPDATE` 通知实时维护：任何应用复制的内容
/// 都会进入历史（与系统剪贴板历史语义一致），点击历史条目即可
/// 粘贴，不依赖系统 Win+V 的按键注入。
class ClipboardHistoryStore extends ChangeNotifier {
  ClipboardHistoryStore();

  /// 全局单例（由 [ClipboardHistoryFix.install] 与菜单共享）。
  static final ClipboardHistoryStore instance = ClipboardHistoryStore();

  /// 历史条数上限（超出后丢弃最旧的）。
  static const int maxEntries = 20;

  final List<String> _items = [];

  /// 历史条目（新→旧）。
  List<String> get items => List.unmodifiable(_items);

  /// 记录一条剪贴板内容（去重：重复内容移到最前）。
  void add(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _items.remove(trimmed);
    _items.insert(0, trimmed);
    if (_items.length > maxEntries) {
      _items.removeRange(maxEntries, _items.length);
    }
    notifyListeners();
  }

  /// 清空历史。
  void clear() {
    if (_items.isEmpty) return;
    _items.clear();
    notifyListeners();
  }
}
