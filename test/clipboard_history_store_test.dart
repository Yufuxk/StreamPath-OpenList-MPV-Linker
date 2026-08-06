import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/core/utils/clipboard_history_store.dart';

void main() {
  group('ClipboardHistoryStore 剪贴板历史', () {
    test('按新→旧顺序记录并去重', () {
      final store = ClipboardHistoryStore();
      store.add('第一条');
      store.add('第二条');
      store.add('第一条'); // 重复 → 移到最前
      expect(store.items, ['第一条', '第二条']);
    });

    test('空白内容忽略', () {
      final store = ClipboardHistoryStore();
      store.add('   ');
      store.add('');
      expect(store.items, isEmpty);
    });

    test('超过上限丢弃最旧', () {
      final store = ClipboardHistoryStore();
      for (var i = 0; i < ClipboardHistoryStore.maxEntries + 5; i++) {
        store.add('条目$i');
      }
      expect(store.items.length, ClipboardHistoryStore.maxEntries);
      expect(store.items.first, '条目${ClipboardHistoryStore.maxEntries + 4}');
      expect(store.items.contains('条目0'), isFalse);
    });

    test('clear 清空', () {
      final store = ClipboardHistoryStore();
      store.add('x');
      store.clear();
      expect(store.items, isEmpty);
    });
  });
}
