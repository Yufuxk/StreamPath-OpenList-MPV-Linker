import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/core/utils/clipboard_history_store.dart';
import 'package:streampath/presentation/widgets/clipboard_history_menu.dart';

void main() {
  group('clipboardHistoryMenuItems 右键菜单项', () {
    test('历史为空时仅提示与「粘贴当前剪贴板」', () {
      final store = ClipboardHistoryStore();
      final items = clipboardHistoryMenuItems(
        store,
        onPick: (_) {},
        onPickCurrentClipboard: () {},
        onClearHistory: () {},
      );
      expect(items.map((e) => e.label), ['剪贴板历史为空', '粘贴当前剪贴板']);
      expect(items.first.onPressed, isNull, reason: '提示项不可点击');
    });

    test('有历史时最多 5 条且长文本截断', () {
      final store = ClipboardHistoryStore();
      for (var i = 0; i < 7; i++) {
        store.add('历史$i');
      }
      store.add('这是一条非常长的剪贴板历史文本内容,远远超过二十四个字符的限制长度');
      final items = clipboardHistoryMenuItems(
        store,
        onPick: (_) {},
        onPickCurrentClipboard: () {},
        onClearHistory: () {},
      );
      expect(items.length, 7, reason: '5 条历史 + 粘贴当前剪贴板 + 清空历史');
      expect(items.first.label, endsWith('…'));
      expect(
        items.map((e) => e.label),
        isNot(contains('历史2')),
        reason: '只保留最新 5 条（历史3 之后的不再显示）',
      );
      expect(items.last.label, '清空剪贴板历史');
    });

    test('点击历史条目回调对应文本', () {
      final store = ClipboardHistoryStore();
      store.add('第一条');
      store.add('第二条');
      final picked = <String>[];
      final items = clipboardHistoryMenuItems(
        store,
        onPick: picked.add,
        onPickCurrentClipboard: () {},
        onClearHistory: () {},
      );
      final target = items.firstWhere((e) => e.label == '第一条');
      target.onPressed!();
      expect(picked, ['第一条']);
    });

    test('点击「粘贴当前剪贴板」与「清空剪贴板历史」触发对应回调', () {
      final store = ClipboardHistoryStore();
      store.add('x');
      var pasteTapped = false;
      var clearTapped = false;
      final items = clipboardHistoryMenuItems(
        store,
        onPick: (_) {},
        onPickCurrentClipboard: () => pasteTapped = true,
        onClearHistory: () => clearTapped = true,
      );
      items.firstWhere((e) => e.label == '粘贴当前剪贴板').onPressed!();
      expect(pasteTapped, isTrue);
      items.firstWhere((e) => e.label == '清空剪贴板历史').onPressed!();
      expect(clearTapped, isTrue);
    });
  });
}
