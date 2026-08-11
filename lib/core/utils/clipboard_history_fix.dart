import 'dart:async';
import 'dart:io';
import 'dart:ui'
    show KeyData, KeyEventDeviceType, KeyEventType, PlatformDispatcher;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart'
    show
        LogicalKeyboardKey,
        MethodChannel,
        PhysicalKeyboardKey,
        SelectionChangedCause,
        TextEditingValue,
        TextRange,
        TextSelection;
import 'package:flutter/widgets.dart'
    show
        AppLifecycleListener,
        AppLifecycleState,
        EditableTextState,
        FocusManager;
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_paths.dart';
import 'clipboard_history_store.dart';
import 'clipboard_service.dart';

/// Windows 11 剪贴板历史（Win+V）粘贴支持。
///
/// 机制：Win11 剪贴板历史点击条目后，系统注入的合成键序列缺少 V 键，
/// 本模块识别该序列的特征并改写为完整的 Ctrl+V 组合键后转发给框架：
///  1. 合成 Ctrl up（synthesized 标志）且与 down 时间戳接近；
///  2. Ctrl down → up 后跟「空键事件」(physical==0)。
/// 确认后改写为 ControlLeft down → V down → V up → ControlLeft up。
///
/// 误判防护：单独的「单击 Ctrl」经短暂延迟后原样冲刷；真实组合键
/// （down 后紧跟其他键）直接透传。
class ClipboardHistoryFix {
  ClipboardHistoryFix();

  /// 单击 Ctrl 后冲刷缓存的延迟（毫秒）；期间若无注入特征则视为真实按键。
  static const int flushDelayMs = 150;

  /// synthesized up 与 down 的时间戳间隔上限（毫秒），超过则不算注入。
  static const int maxSynthesizedGapMs = 100;

  /// 诊断日志文件名（写入数据目录，另在用户主目录与应用支持目录各留一份）。
  static const String logFileName = 'clipboard_history_fix.log';

  /// 原生侧（windows runner）剪贴板变化通知通道。
  static const MethodChannel _clipboardChannel = MethodChannel(
    'streampath/clipboard',
  );

  static List<File> _logFiles = const [];

  /// 最近一次窗口激活（resumed）时间；null 表示从未激活。
  static DateTime? _lastResumedAt;

  /// 最近一次按键状态机确认「剪贴板历史注入序列」的时间。
  /// 作为自动注入的**第二证据**：仅凭窗口激活时序不足以判定
  /// （可能误注入用户自己复制的内容），必须同时观察到系统注入的
  /// 异常键序列（合成 Ctrl 或空键事件）。
  static DateTime? _lastInjectedSequenceAt;

  /// 剪贴板变化发生在窗口重新激活后 [autoPasteWindow] 内时自动注入
  /// （这是剪贴板历史点击的时序特征：历史窗口关闭 → 聚焦恢复 →
  /// 系统把所选内容写回剪贴板）。
  static const Duration autoPasteWindow = Duration(seconds: 1);

  /// Windows 剪贴板历史注入事件的物理键码标记。
  ///
  /// 系统注入的按键事件 physical 统一为
  /// 0x1600000000（真实键盘不会产生该键码），logical 键码保持正确
  /// （controlLeft=0x200000100、V=0x76）；且注入序列是「单击式」的
  /// （Ctrl↓ Ctrl↑ V↓ V↑ Ctrl↓ Ctrl↑），V 按下时 Ctrl 已抬起，
  /// 不构成 Flutter 认可的 Ctrl+V。因此按该标记整组识别注入序列，
  /// 整组丢弃并替换为一次合法 Ctrl+V。
  static const int injectedPhysicalKey = 0x1600000000;

  /// 注入缓冲超时（毫秒）：超时未确认则原样冲刷（防止事件泄漏）。
  static const int injectedFlushDelayMs = 500;

  /// 注入序列缓冲（physical == [injectedPhysicalKey] 的事件）。
  final List<KeyData> _injectedBuffer = [];
  Timer? _injectedBufferTimer;

  /// 完整 Win+V 序列在 V↑ 后通常还残留一组注入 Ctrl↓/Ctrl↑。若把
  /// 这组事件延迟到用户下一次输入时再交给 Flutter，会污染 IME 状态，
  /// 造成新字符覆盖粘贴内容或拼音字符成倍出现。
  bool _discardInjectedTail = false;
  bool _discardTailSawCtrlDown = false;
  Timer? _discardTailTimer;

  /// 缓存的待确认 Ctrl KeyDown。
  KeyData? _pendingDown;

  /// 缓存的待确认 Ctrl KeyUp（等待注入特征确认）。
  KeyData? _pendingUp;

  Timer? _flushTimer;

  /// Timer 到期冲刷的事件（下次 [transform] 时返回）。
  final List<KeyData> _deferred = [];

  /// 安装修复（初始化日志 + 注册剪贴板通道 + 后台安装按键修复）。
  /// 仅 Windows 生效。
  static Future<void> install() async {
    if (!Platform.isWindows) return;
    await _initLogFiles();
    _log('=== install ===');

    // 跟踪窗口激活：剪贴板历史点击时窗口先失焦再恢复聚焦。
    AppLifecycleListener(
      onStateChange: (state) {
        if (state == AppLifecycleState.resumed) {
          _lastResumedAt = DateTime.now();
          _log('窗口激活（resumed）');
        }
      },
    );

    // 剪贴板通道：原生层在剪贴板变化（WM_CLIPBOARDUPDATE）时发信号，
    // 文本由 super_clipboard 读取（更稳健，支持更多格式）。
    // 1) 全部记入应用内剪贴板历史（输入框右键菜单可点击粘贴）；
    // 2) 兜底自动注入：仅当同时满足「窗口刚恢复激活」与「按键状态机
    //    观察到系统注入的异常键序列」两个证据（剪贴板历史点击特征）
    //    时，延迟注入一次；若系统粘贴已生效（文本已变化）则跳过，
    //    避免重复粘贴。
    _clipboardChannel.setMethodCallHandler((call) async {
      if (call.method == 'clipboardChanged') {
        final text = await ClipboardService.instance.readPlainText();
        if (text != null && text.isNotEmpty) {
          _log('原生剪贴板通知（${text.length} 字符）→ 记入历史');
          ClipboardHistoryStore.instance.add(text);
          final now = DateTime.now();
          final lastResumed = _lastResumedAt;
          final lastSequence = _lastInjectedSequenceAt;
          final isHistoryPick =
              lastResumed != null &&
              now.difference(lastResumed) < autoPasteWindow &&
              lastSequence != null &&
              now.difference(lastSequence) < autoPasteWindow;
          if (isHistoryPick) {
            _log('剪贴板历史点击证据齐全（激活 + 注入序列）→ 兜底注入');
            unawaited(_scheduleFallbackPaste(text));
          }
        }
      }
      return null;
    });
    _log('剪贴板通道已注册');

    // 按键修复：框架在 runApp 之后才注册 onKeyData，因此后台轮询
    // 等待注册完成后包装，不阻塞 main()。
    unawaited(_installKeyFixWhenReady());
  }

  /// 轮询等待框架注册 [PlatformDispatcher.onKeyData] 后安装按键修复。
  static Future<void> _installKeyFixWhenReady() async {
    final dispatcher = PlatformDispatcher.instance;
    for (var i = 0; i < 100; i++) {
      final original = dispatcher.onKeyData;
      if (original != null) {
        // 预热框架的 _transitMode：Windows 上每个按键会同时走 KeyData
        // 与 flutter/keyevent 双通道，KeyEventManager 只按「第一个到达」
        // 的事件推断一次模式。若首个到达的是 keyevent 通道
        // （handleRawKeyMessage），_transitMode 会被推断为 rawKeyData，
        // 此后任何 KeyData 都会触发框架断言（'Should never encounter
        // KeyData when transitMode is rawKeyData'）。空键事件
        // （physical==0 && logical==0）会被框架直接忽略，仅触发
        // _transitMode ??= keyDataThenRawKeyData，无任何副作用。
        original(
          KeyData(
            timeStamp: Duration.zero,
            type: KeyEventType.up,
            physical: 0,
            logical: 0,
            character: null,
            synthesized: false,
            deviceType: KeyEventDeviceType.keyboard,
          ),
        );
        final fix = ClipboardHistoryFix();
        dispatcher.onKeyData = (KeyData data) {
          final events = fix.transform(data);
          if (events.isEmpty) {
            // 注入序列事件（physical == injectedPhysicalKey）必须吞掉：
            // 若转发给框架，4 事件紧凑序列（Ctrl↓ V↓ V↑ Ctrl↑）会被
            // KeyEventManager 识别为真实 Ctrl+V 自行粘贴一次，与下方
            // 合成的 Ctrl+V 叠加，导致重复粘贴两遍。
            if (data.physical == injectedPhysicalKey) {
              return true;
            }
            // 真实按键缓存（单击 Ctrl）或空键事件：转发给框架，保证
            // _transitMode 由 KeyData 路径推断（断言已由上方预热消除，
            // 此处转发同时保证真实按键不被吞）；空键事件框架会忽略。
            return original(data);
          }
          var handled = false;
          for (final e in events) {
            handled = original(e);
          }
          return handled;
        };
        _log('按键修复回调已安装（onKeyData 已注册，等待 ${i * 100}ms）');
        return;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    _log('等待 onKeyData 注册超时（10s），按键修复未安装');
  }

  /// 把 [text] 注入当前聚焦的文本输入框（等价于在光标处粘贴）。
  ///
  /// 通过 [FocusManager] 找到聚焦的 [EditableTextState] 并更新其值；
  /// 无聚焦输入框时忽略。
  static void injectPaste(String text) {
    final editable = _focusedEditableState();
    if (editable == null) {
      _log('注入失败：无聚焦的文本输入框');
      return;
    }
    final value = editable.textEditingValue;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final newText = value.text.replaceRange(start, end, text);
    // 使用用户编辑入口同步 EditableText 与平台 TextInputClient，并显式
    // 清空 Win+V 前后可能残留的 composing 区间。直接 updateEditingValue
    // 只更新框架侧时，下一次中文 IME 增量可能基于旧 composing 重放。
    editable.userUpdateTextEditingValue(
      TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: start + text.length),
        composing: TextRange.empty,
      ),
      SelectionChangedCause.keyboard,
    );
  }

  /// 兜底注入：剪贴板历史点击后延迟 300ms 检查输入框文本——
  /// 若系统注入的按键已被 Flutter 正常处理（文本已变化）则跳过，
  /// 否则手动注入（防止重复粘贴）。延迟后还会校验焦点仍在原输入框，
  /// 避免把内容注入到切换后的其他输入框。
  static Future<void> _scheduleFallbackPaste(String text) async {
    final editable = _focusedEditableState();
    if (editable == null) {
      _log('兜底注入跳过：无聚焦的文本输入框');
      return;
    }
    final before = editable.textEditingValue.text;
    await Future.delayed(const Duration(milliseconds: 300));
    final current = _focusedEditableState();
    if (current == null || !identical(current, editable)) {
      _log('兜底注入跳过：焦点已切换');
      return;
    }
    if (current.textEditingValue.text != before) {
      _log('系统粘贴已生效，跳过兜底注入');
      return;
    }
    _log('兜底注入文本（${text.length} 字符）');
    injectPaste(text);
  }

  /// 确认注入序列后从剪贴板读取文本并延迟兜底注入。
  static Future<void> _scheduleFallbackPasteFromClipboard() async {
    String? text;
    try {
      text = await ClipboardService.instance.readPlainText();
    } catch (e) {
      _log('注入兜底：读取剪贴板失败（$e）');
      return;
    }
    if (text == null || text.isEmpty) {
      _log('注入兜底：剪贴板无文本，跳过');
      return;
    }
    _log('注入兜底：剪贴板读取成功（${text.length} 字符），延迟防重注入');
    await _scheduleFallbackPaste(text);
  }

  /// 诊断：确认注入后 500ms 检查焦点与输入框文本是否变化
  /// （用于定位「合成 Ctrl+V 未触发粘贴」的根因）。
  static Future<void> _logPasteResultDiagnostics() async {
    final focus = FocusManager.instance.primaryFocus;
    final editable = _focusedEditableState();
    final before = editable?.textEditingValue.text;
    _log(
      '粘贴诊断：焦点=${focus?.debugLabel ?? 'null'} '
      'EditableText=${editable != null} 文本长度=${before?.length ?? -1}',
    );
    await Future.delayed(const Duration(milliseconds: 500));
    final editableNow = _focusedEditableState();
    final after = editableNow?.textEditingValue.text;
    _log(
      '粘贴诊断：500ms 后 EditableText=${editableNow != null} '
      '文本长度=${after?.length ?? -1} 变化=${before != after}',
    );
  }

  /// 测试辅助：清空注入缓冲与定时器（避免测试间状态泄漏）。
  @visibleForTesting
  void resetForTest() {
    _injectedBufferTimer?.cancel();
    _injectedBufferTimer = null;
    _injectedBuffer.clear();
    _discardTailTimer?.cancel();
    _discardTailTimer = null;
    _discardInjectedTail = false;
    _discardTailSawCtrlDown = false;
    _pendingDown = null;
    _pendingUp = null;
    _cancelTimer();
    _deferred.clear();
  }

  /// 从焦点元素向上查找 [EditableTextState]。
  ///
  /// TextField 的焦点挂在 EditableText 内部的 Focus widget 上，
  /// 因此从焦点 context 向上即可找到 EditableTextState。
  static EditableTextState? _focusedEditableState() => FocusManager
      .instance
      .primaryFocus
      ?.context
      ?.findAncestorStateOfType<EditableTextState>();

  /// 处理单个输入事件，返回需要转发的 [KeyData] 列表。
  ///
  /// 输出可为空（事件被缓存/丢弃）、单个或多个（原样转发）、
  /// 或四个（合成的 Ctrl+V 序列）。
  @visibleForTesting
  List<KeyData> transform(KeyData data) {
    final out = <KeyData>[..._deferred];
    _deferred.clear();

    // 已确认序列的尾部 Ctrl 事件属于同一次系统注入，必须直接吞掉，
    // 不能积压到下一次真实字符到来时再冲刷给框架/中文 IME。
    if (data.physical == injectedPhysicalKey && _discardInjectedTail) {
      if (_isCtrlLogical(data)) {
        if (data.type == KeyEventType.down) {
          _discardTailSawCtrlDown = true;
        } else if (data.type == KeyEventType.up && _discardTailSawCtrlDown) {
          _discardInjectedTail = false;
          _discardTailSawCtrlDown = false;
          _discardTailTimer?.cancel();
          _discardTailTimer = null;
        }
        _logEvent(data, '丢弃已确认 Win+V 序列的尾部 Ctrl 事件');
        return out;
      }
      // 非 Ctrl 标记事件说明这是新的注入序列，不误吞。
      _discardInjectedTail = false;
      _discardTailSawCtrlDown = false;
      _discardTailTimer?.cancel();
      _discardTailTimer = null;
    }

    // ── 注入序列整组识别（physical == injectedPhysicalKey）────────
    // 剪贴板历史注入的事件带统一物理标记，且序列为「单击式」Ctrl+V
    // （Ctrl↓ Ctrl↑ V↓ V↑ Ctrl↓ Ctrl↑），需整组收集后替换为一次
    // 合法 Ctrl+V，否则 Flutter 不识别为组合键。
    if (data.physical == injectedPhysicalKey) {
      _injectedBuffer.add(data);
      _injectedBufferTimer?.cancel();
      _injectedBufferTimer = Timer(
        const Duration(milliseconds: injectedFlushDelayMs),
        () {
          _log('注入缓冲超时未确认，原样冲刷（${_injectedBuffer.length} 事件）');
          _deferred.addAll(_injectedBuffer);
          _injectedBuffer.clear();
        },
      );
      final hasCtrlDown = _injectedBuffer.any(
        (e) => e.type == KeyEventType.down && _isCtrlLogical(e),
      );
      final hasCtrlUp = _injectedBuffer.any(
        (e) => e.type == KeyEventType.up && _isCtrlLogical(e),
      );
      final hasVDown = _injectedBuffer.any(
        (e) => e.type == KeyEventType.down && _isVLogical(e),
      );
      final hasVUp = _injectedBuffer.any(
        (e) => e.type == KeyEventType.up && _isVLogical(e),
      );
      if (hasCtrlDown && hasCtrlUp && hasVDown && hasVUp) {
        _injectedBufferTimer?.cancel();
        _injectedBufferTimer = null;
        final count = _injectedBuffer.length;
        _injectedBuffer.clear();
        _lastInjectedSequenceAt = DateTime.now();
        _discardInjectedTail = true;
        _discardTailSawCtrlDown = false;
        _discardTailTimer?.cancel();
        _discardTailTimer = Timer(const Duration(milliseconds: 250), () {
          _discardInjectedTail = false;
          _discardTailSawCtrlDown = false;
        });
        _log('识别完整剪贴板历史注入序列（$count 事件）→ 整组替换为一次 Ctrl+V');
        out.addAll(_ctrlVSequence(data));
        // 不依赖框架快捷键链路（焦点/TextInput 连接在剪贴板历史窗口
        // 切换后可能未恢复，合成 Ctrl+V 未触发粘贴）：
        // 直接读剪贴板并延迟兜底注入（防重：文本已变化则跳过）。
        unawaited(_scheduleFallbackPasteFromClipboard());
        unawaited(_logPasteResultDiagnostics());
        return out;
      }
      _logEvent(data, '注入序列缓冲（${_injectedBuffer.length} 事件）');
      return out;
    }

    // 非注入事件打断缓冲：原样冲刷缓冲内容（不丢事件）。
    if (_injectedBuffer.isNotEmpty) {
      _injectedBufferTimer?.cancel();
      _injectedBufferTimer = null;
      out.addAll(_injectedBuffer);
      _log('注入缓冲被普通事件打断，原样冲刷（${_injectedBuffer.length} 事件）');
      _injectedBuffer.clear();
    }

    if (_isCtrlDown(data)) {
      _cancelTimer();
      // 冲刷此前缓存的 up（双击 Ctrl 场景），再缓存新 down。
      if (_pendingUp != null) {
        out.addAll([_pendingDown!, _pendingUp!]);
        _pendingUp = null;
      }
      _pendingDown = data;
      _logEvent(data, '缓存 Ctrl down');
      return out;
    }

    if (_isCtrlUp(data)) {
      if (_pendingDown != null) {
        _cancelTimer();
        // 注入特征 1：合成 up 且与 down 时间戳接近 → 立即确认。
        final gap = data.timeStamp - _pendingDown!.timeStamp;
        if (data.synthesized &&
            gap <= const Duration(milliseconds: maxSynthesizedGapMs)) {
          _pendingDown = null;
          out.addAll(_ctrlVSequence(data));
          _lastInjectedSequenceAt = DateTime.now();
          _logEvent(
            data,
            '注入确认（syn up, gap=${gap.inMilliseconds}ms）→ 合成 Ctrl+V',
          );
          return out;
        }
        _pendingUp = data;
        _flushTimer = Timer(const Duration(milliseconds: flushDelayMs), () {
          _deferred.addAll([_pendingDown!, _pendingUp!]);
          _pendingDown = null;
          _pendingUp = null;
          _log('Ctrl 单击确认（超时），原样冲刷');
        });
        _logEvent(data, '缓存 Ctrl up（等待注入特征/超时）');
        return out;
      }
      // 孤立 Ctrl 抬起（注入序列开头等）：原样转发（无害）。
      out.add(data);
      _logEvent(data, '孤立 Ctrl up，转发');
      return out;
    }

    if (data.physical == 0) {
      // 注入特征 2：空键事件——真实键盘不会产生。若此前缓存了
      // Ctrl down→up，确认是剪贴板历史注入 → 合成完整 Ctrl+V。
      if (_pendingUp != null) {
        _cancelTimer();
        _pendingDown = null;
        _pendingUp = null;
        out.addAll(_ctrlVSequence(data));
        _lastInjectedSequenceAt = DateTime.now();
        _logEvent(data, '注入确认（空键事件）→ 合成 Ctrl+V');
        return out;
      }
      _logEvent(data, '丢弃空键事件（无待确认 Ctrl 序列）');
      return out;
    }

    // 其他按键：冲刷缓存后原样转发（真实 Ctrl+C/V 等组合键走这里）。
    _cancelTimer();
    if (_pendingUp != null) {
      out.addAll([_pendingDown!, _pendingUp!]);
      _pendingUp = null;
      _pendingDown = null;
    } else if (_pendingDown != null) {
      out.add(_pendingDown!);
      _pendingDown = null;
    }
    _logEvent(data, '转发');
    out.add(data);
    return out;
  }

  void _cancelTimer() {
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  bool _isCtrlDown(KeyData d) =>
      d.type == KeyEventType.down &&
      d.physical == PhysicalKeyboardKey.controlLeft.usbHidUsage;

  bool _isCtrlUp(KeyData d) =>
      d.type == KeyEventType.up &&
      d.physical == PhysicalKeyboardKey.controlLeft.usbHidUsage;

  /// 按 logical 判断是否为 Ctrl 左键（注入事件 physical 是统一标记，
  /// 无法按物理键码判断，logical 保持正确）。
  bool _isCtrlLogical(KeyData d) =>
      d.logical == LogicalKeyboardKey.controlLeft.keyId;

  /// 按 logical 判断是否为 V 键。
  bool _isVLogical(KeyData d) => d.logical == LogicalKeyboardKey.keyV.keyId;

  /// 构造完整 Ctrl+V 键序列（非 synthesized，等同真实按键）。
  static List<KeyData> _ctrlVSequence(KeyData seed) => [
    _make(
      seed,
      physical: PhysicalKeyboardKey.controlLeft.usbHidUsage,
      logical: LogicalKeyboardKey.controlLeft.keyId,
      type: KeyEventType.down,
    ),
    _make(
      seed,
      physical: PhysicalKeyboardKey.keyV.usbHidUsage,
      logical: LogicalKeyboardKey.keyV.keyId,
      type: KeyEventType.down,
    ),
    _make(
      seed,
      physical: PhysicalKeyboardKey.keyV.usbHidUsage,
      logical: LogicalKeyboardKey.keyV.keyId,
      type: KeyEventType.up,
    ),
    _make(
      seed,
      physical: PhysicalKeyboardKey.controlLeft.usbHidUsage,
      logical: LogicalKeyboardKey.controlLeft.keyId,
      type: KeyEventType.up,
    ),
  ];

  static KeyData _make(
    KeyData seed, {
    required int physical,
    required int logical,
    required KeyEventType type,
  }) => KeyData(
    timeStamp: seed.timeStamp,
    type: type,
    physical: physical,
    logical: logical,
    character: null,
    synthesized: false,
    deviceType: seed.deviceType,
  );

  // ── 诊断日志（写文件，GUI stdout 不可见） ──────────────────────

  /// 初始化日志文件：集中写入数据目录（`stream_path_data/`），
  /// 启动时清空旧日志。仅 debug 构建落盘（release 不产生非预期文件）。
  static Future<void> _initLogFiles() async {
    if (!kDebugMode) return;
    Directory? dataDir;
    try {
      dataDir = await AppPaths.cacheDirectory(); // 诊断日志
    } catch (_) {}
    final files = <File>[
      if (dataDir != null) File(p.join(dataDir.path, logFileName)),
    ];
    final home = Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty) {
      files.add(File(p.join(home, logFileName)));
    }
    try {
      final dir = await getApplicationSupportDirectory();
      files.add(File(p.join(dir.path, logFileName)));
    } catch (_) {
      // 忽略：项目根目录日志已足够。
    }
    for (final f in files) {
      try {
        f.parent.createSync(recursive: true);
        f.deleteSync();
      } catch (_) {}
    }
    _logFiles = files;
  }

  void _logEvent(KeyData d, String decision) {
    _log(
      'event type=${d.type.name} physical=0x${d.physical.toRadixString(16)}'
      ' logical=0x${d.logical.toRadixString(16)} syn=${d.synthesized}'
      ' ts=${d.timeStamp.inMilliseconds}ms -> $decision',
    );
  }

  static void _log(String line) {
    for (final f in _logFiles) {
      try {
        f.writeAsStringSync(
          '${DateTime.now().toIso8601String()} $line\n',
          mode: FileMode.append,
        );
      } catch (_) {
        // 写入失败不影响功能。
      }
    }
  }
}
