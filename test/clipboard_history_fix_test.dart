import 'dart:ui' show KeyData, KeyEventType;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show LogicalKeyboardKey, PhysicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/core/utils/clipboard_history_fix.dart';

/// 剪贴板历史（Win+V）修复的状态机测试。
///
/// 场景对照 flutter/flutter#143997：
/// - Win11 注入序列（带 synthesized 标志）：Ctrl down → Ctrl up →
///   应改写为完整 Ctrl+V；
/// - 注入序列（不带 synthesized）：Ctrl down → Ctrl up → 空键事件
///   (physical==0) → 应改写为完整 Ctrl+V；
/// - 完整注入序列（含 V 键）：应原样透传，不重复粘贴；
/// - 真实键盘（单击 Ctrl / Ctrl+C / Ctrl+V / 双击 Ctrl）：不受影响。
void main() {
  final ctrlPhysical = PhysicalKeyboardKey.controlLeft.usbHidUsage;
  final vPhysical = PhysicalKeyboardKey.keyV.usbHidUsage;
  final ctrlLogical = LogicalKeyboardKey.controlLeft.keyId;
  final vLogical = LogicalKeyboardKey.keyV.keyId;

  KeyData key(int physical,
          {KeyEventType type = KeyEventType.down,
          bool synthesized = false,
          Duration timeStamp = Duration.zero}) =>
      KeyData(
        timeStamp: timeStamp,
        type: type,
        physical: physical,
        logical: physical == ctrlPhysical ? ctrlLogical : physical,
        character: null,
        synthesized: synthesized,
      );

  KeyData ctrlDown([bool syn = false, Duration ts = Duration.zero]) =>
      key(ctrlPhysical, synthesized: syn, timeStamp: ts);
  KeyData ctrlUp([bool syn = false, Duration ts = Duration.zero]) =>
      key(ctrlPhysical, type: KeyEventType.up, synthesized: syn, timeStamp: ts);
  KeyData vDown([bool syn = false]) => key(vPhysical, synthesized: syn);
  KeyData vUp([bool syn = false]) =>
      key(vPhysical, type: KeyEventType.up, synthesized: syn);
  KeyData empty([bool syn = false]) =>
      key(0, type: KeyEventType.up, synthesized: syn);

  /// 断言输出为完整 Ctrl+V 序列。
  void expectCtrlV(List<KeyData> out) {
    expect(out, hasLength(4));
    expect(out[0].physical, ctrlPhysical);
    expect(out[0].type, KeyEventType.down);
    expect(out[1].physical, vPhysical);
    expect(out[1].logical, vLogical);
    expect(out[1].type, KeyEventType.down);
    expect(out[2].physical, vPhysical);
    expect(out[2].type, KeyEventType.up);
    expect(out[3].physical, ctrlPhysical);
    expect(out[3].type, KeyEventType.up);
    expect(out.every((e) => !e.synthesized), isTrue,
        reason: '合成事件须等同真实按键才能触发快捷键');
  }

  group('Win11 剪贴板历史注入序列', () {
    test('带 synthesized 的空 Ctrl 序列立即改写为完整 Ctrl+V', () {
      final fix = ClipboardHistoryFix();
      expect(fix.transform(ctrlDown(true)), isEmpty);
      final out = fix.transform(ctrlUp(true)); // 合成 up + 时间戳接近
      expectCtrlV(out);
    });

    test('不带 synthesized 的空 Ctrl 序列由空键事件确认改写', () {
      final fix = ClipboardHistoryFix();
      expect(fix.transform(ctrlDown()), isEmpty);
      expect(fix.transform(ctrlUp()), isEmpty);
      final out = fix.transform(empty());
      expectCtrlV(out);
    });

    test('带 synthesized 但时间戳间隔大的 up 不立即注入（仍可被空键确认）', () {
      final fix = ClipboardHistoryFix();
      fix.transform(ctrlDown(true)); // ts=0
      expect(
        fix.transform(ctrlUp(true, const Duration(milliseconds: 500))),
        isEmpty,
        reason: 'gap 超过阈值，不作为注入特征',
      );
      expectCtrlV(fix.transform(empty()));
    });

    test('注入序列残留的多个空键事件被丢弃', () {
      final fix = ClipboardHistoryFix();
      fix.transform(ctrlDown());
      fix.transform(ctrlUp());
      expectCtrlV(fix.transform(empty()));
      expect(fix.transform(empty()), isEmpty, reason: '多余空键事件丢弃');
    });

    test('连续两次注入都改写为 Ctrl+V', () {
      final fix = ClipboardHistoryFix();
      fix.transform(ctrlDown());
      fix.transform(ctrlUp());
      expectCtrlV(fix.transform(empty()));
      // 第二次注入（无真实按键间隔）
      fix.transform(ctrlDown());
      fix.transform(ctrlUp());
      expectCtrlV(fix.transform(empty()));
    });

    test('孤立 Ctrl KeyUp 原样转发（状态清理）', () {
      final fix = ClipboardHistoryFix();
      expect(fix.transform(ctrlUp()), [isA<KeyData>()]);
    });
  });

  group('完整注入序列 / 真实按键', () {
    test('真实 Ctrl+V 完全不受影响', () {
      final fix = ClipboardHistoryFix();
      expect(fix.transform(ctrlDown()), isEmpty, reason: 'down 先缓存');
      final out = fix.transform(vDown());
      expect(out, hasLength(2), reason: '冲刷 down + 转发 V down');
      expect(out[0].physical, ctrlPhysical);
      expect(out[1].physical, vPhysical);
      expect(fix.transform(vUp()), hasLength(1));
      expect(fix.transform(ctrlUp()), hasLength(1));
    });

    test('合成序列（带 synthesized 标志）的完整 Ctrl+V 也透传', () {
      final fix = ClipboardHistoryFix();
      fix.transform(ctrlDown(true));
      final out = fix.transform(vDown(true));
      expect(out, hasLength(2));
      expect(out[1].physical, vPhysical);
      expect(fix.transform(vUp(true)), hasLength(1));
      expect(fix.transform(ctrlUp(true)), hasLength(1));
    });

    test('Ctrl+C 组合键透传', () {
      final fix = ClipboardHistoryFix();
      fix.transform(ctrlDown());
      final out = fix.transform(key(0x70006)); // 'C'
      expect(out, hasLength(2));
      expect(out[1].physical, 0x70006);
      expect(fix.transform(key(0x70006, type: KeyEventType.up)), hasLength(1));
      expect(fix.transform(ctrlUp()), hasLength(1));
    });
  });

  group('单击 / 双击 Ctrl 不误判', () {
    test('单击 Ctrl：超时后原样冲刷（不合成粘贴）', () {
      fakeAsync((async) {
        final fix = ClipboardHistoryFix();
        expect(fix.transform(ctrlDown()), isEmpty);
        expect(fix.transform(ctrlUp()), isEmpty);
        async.elapse(const Duration(milliseconds: 200));
        // 下一次事件到来时返回滞留的 down+up
        final out = fix.transform(key(0x70004)); // 'A'
        expect(out, hasLength(3));
        expect(out[0].physical, ctrlPhysical);
        expect(out[0].type, KeyEventType.down);
        expect(out[1].physical, ctrlPhysical);
        expect(out[1].type, KeyEventType.up);
        expect(out[2].physical, 0x70004);
      });
    });

    test('单击 Ctrl 后按 V：原样冲刷（不合成粘贴）', () {
      fakeAsync((async) {
        final fix = ClipboardHistoryFix();
        fix.transform(ctrlDown());
        fix.transform(ctrlUp());
        async.elapse(const Duration(milliseconds: 200));
        final out = fix.transform(vDown());
        expect(out, hasLength(3));
        expect(out[1].type, KeyEventType.up);
        expect(out[2].physical, vPhysical);
      });
    });

    test('双击 Ctrl：全部原样透传', () {
      fakeAsync((async) {
        final fix = ClipboardHistoryFix();
        fix.transform(ctrlDown());
        fix.transform(ctrlUp());
        // 第二次按下：冲刷第一次的 down+up
        final out = fix.transform(ctrlDown());
        expect(out, hasLength(2));
        fix.transform(ctrlUp());
        async.elapse(const Duration(milliseconds: 200));
        final out2 = fix.transform(key(0x70004));
        expect(out2, hasLength(3));
        expect(out2[0].physical, ctrlPhysical);
        expect(out2[1].type, KeyEventType.up);
      });
    });

    test('无待确认序列时空键事件直接丢弃', () {
      final fix = ClipboardHistoryFix();
      expect(fix.transform(empty()), isEmpty);
      expect(fix.transform(empty(true)), isEmpty);
    });
  });

  group('注入序列整组识别（physical=0x1600000000 实测标记）', () {
    KeyData injected(int logical,
            {KeyEventType type = KeyEventType.down}) =>
        KeyData(
          timeStamp: Duration.zero,
          type: type,
          physical: ClipboardHistoryFix.injectedPhysicalKey,
          logical: logical,
          character: null,
          synthesized: false,
        );
    KeyData injCtrlDown() => injected(ctrlLogical);
    KeyData injCtrlUp() => injected(ctrlLogical, type: KeyEventType.up);
    KeyData injVDown() => injected(vLogical);
    KeyData injVUp() => injected(vLogical, type: KeyEventType.up);

    test('日志实测「单击式」6 事件序列整组替换为一次 Ctrl+V', () {
      final fix = ClipboardHistoryFix();
      // Ctrl↓ Ctrl↑ V↓ V↑ Ctrl↓ Ctrl↑（V 按下时 Ctrl 已抬起）
      expect(fix.transform(injCtrlDown()), isEmpty);
      expect(fix.transform(injCtrlUp()), isEmpty);
      expect(fix.transform(injVDown()), isEmpty);
      // V↑ 时 Ctrl down/up + V down/up 证据已齐 → 立即合成一次 Ctrl+V。
      expectCtrlV(fix.transform(injVUp()));
      // 注入序列尾部残留（Ctrl↓ Ctrl↑）进入缓冲，不转发（超时后冲刷）。
      expect(fix.transform(injCtrlDown()), isEmpty);
      expect(fix.transform(injCtrlUp()), isEmpty);
    });

    test('4 事件紧凑序列（Ctrl↓ V↓ V↑ Ctrl↑）也识别', () {
      final fix = ClipboardHistoryFix();
      fix.transform(injCtrlDown());
      fix.transform(injVDown());
      fix.transform(injVUp());
      expectCtrlV(fix.transform(injCtrlUp()));
    });

    test('缓冲被真实按键打断时原样冲刷（不丢事件）', () {
      final fix = ClipboardHistoryFix();
      fix.transform(injCtrlDown());
      fix.transform(injCtrlUp());
      final out = fix.transform(
          key(vPhysical, type: KeyEventType.down));
      expect(out, hasLength(3), reason: '冲刷 2 个注入事件 + 转发真实 V');
      expect(out[0].physical, ClipboardHistoryFix.injectedPhysicalKey);
      expect(out[2].physical, vPhysical);
    });

    test('缓冲超时未确认则冲刷（不泄漏）', () {
      fakeAsync((async) {
        final fix = ClipboardHistoryFix();
        fix.transform(injCtrlDown());
        fix.transform(injCtrlUp());
        async.elapse(const Duration(milliseconds: 600));
        final out = fix.transform(
            key(vPhysical, type: KeyEventType.down));
        expect(out, hasLength(3));
        expect(out[0].physical, ClipboardHistoryFix.injectedPhysicalKey);
      });
    });

    test('真实 Ctrl+V（标准物理键码）不受影响', () {
      final fix = ClipboardHistoryFix();
      fix.transform(ctrlDown());
      final out = fix.transform(vDown());
      expect(out, hasLength(2));
      expect(out[1].physical, vPhysical);
    });
  });

  group('injectPaste 聚焦输入框注入（原生剪贴板兜底）', () {
    testWidgets('文本注入聚焦的 TextField（等价粘贴）', (tester) async {
      final controller = TextEditingController(text: '前缀');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TextField(controller: controller),
        ),
      ));
      await tester.tap(find.byType(TextField));
      await tester.pump();

      ClipboardHistoryFix.injectPaste('粘贴内容');

      await tester.pump();
      expect(controller.text, '前缀粘贴内容');
      // 光标位于粘贴内容之后。
      expect(controller.selection.baseOffset, '前缀粘贴内容'.length);
    });

    testWidgets('光标处替换选区注入（等价粘贴）', (tester) async {
      final controller = TextEditingController(text: 'abcdef');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TextField(controller: controller),
        ),
      ));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      // 选中 'cde'。
      controller.selection = const TextSelection(
        baseOffset: 2,
        extentOffset: 5,
      );

      ClipboardHistoryFix.injectPaste('XY');

      await tester.pump();
      expect(controller.text, 'abXYf');
    });
  });
}
