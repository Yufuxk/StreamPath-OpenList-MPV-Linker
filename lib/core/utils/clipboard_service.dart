import 'package:super_clipboard/super_clipboard.dart';

/// 剪贴板读取服务：基于 [super_clipboard]（Rust 原生实现，支持多种
/// 格式、处理 Windows 剪贴板事件更稳健），替代 flutter/services 的
/// `Clipboard.getData` 与原生 C++ 读取。
///
/// 使用 [instance] 单例；测试中可替换为 fake。
class ClipboardService {
  ClipboardService();

  /// 全局单例。
  static ClipboardService instance = ClipboardService();

  /// 读取剪贴板纯文本；剪贴板不可用或无文本时返回 null。
  Future<String?> readPlainText() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return null;
    final reader = await clipboard.read();
    if (!reader.canProvide(Formats.plainText)) return null;
    return await reader.readValue(Formats.plainText);
  }
}
