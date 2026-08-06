import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// MPV 属性变化事件（`property-change`）。
class MpvPropertyEvent {
  const MpvPropertyEvent({required this.name, this.value});

  /// 属性名（如 `pause`、`time-pos`、`playlist-pos`）。
  final String name;

  /// 属性当前值（类型随属性而定：bool/num/String/List/Map/null）。
  final Object? value;
}

/// MPV JSON-RPC IPC 会话控制器（Windows named pipe）。
///
/// 负责：
///  - 连接 mpv 的 `--input-ipc-server` named pipe（含创建等待重试）；
///  - 发送 JSON-RPC 请求（get/set property、命令），按 `request_id`
///    匹配异步响应；
///  - 后台 isolate 阻塞读取管道并解析 JSON 行，`property-change`
///    事件经广播流分发；
///  - 断开（mpv 退出/崩溃）检测与资源释放。
///
/// 线程模型：写入在主 isolate（消息小、低频）；读取在独立 isolate
/// （`ReadFile` 阻塞循环，句柄以 int 传递，不跨 isolate 共享指针）。
class MpvSessionController {
  MpvSessionController({this.pipeName = r'\\.\pipe\mpvsocket'});

  /// named pipe 路径（与 mpv `--input-ipc-server` 参数一致）。
  final String pipeName;

  final _propertyEvents = StreamController<MpvPropertyEvent>.broadcast();

  /// 属性变化事件流（observe_property 注册后实时推送）。
  Stream<MpvPropertyEvent> get propertyEvents => _propertyEvents.stream;

  final _incoming = StreamController<String>();
  final _pending = <int, Completer<Object?>>{};

  int _nextRequestId = 1;
  int _handle = INVALID_HANDLE_VALUE;
  bool _disposed = false;

  /// 事件流是否已关闭（与 [_disposed] 分离：断连也会关闭事件流）。
  bool _eventsClosed = false;
  Isolate? _reader;
  ReceivePort? _readerPort;

  /// 写入 isolate：named pipe 写入在独立线程执行，
  /// 避免主 isolate 因管道缓冲满而同步阻塞（UI 卡死）。
  Isolate? _writer;
  SendPort? _writerPort;

  /// 是否已连接。
  bool get isConnected => _handle != INVALID_HANDLE_VALUE;

  /// 连接 mpv 的 named pipe；pipe 由 mpv 启动后异步创建，
  /// 因此按 [retryInterval] 轮询尝试，直到 [timeout] 或成功。
  Future<bool> connect({
    Duration timeout = const Duration(seconds: 10),
    Duration retryInterval = const Duration(milliseconds: 250),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final h = _tryOpenPipe();
      if (h != INVALID_HANDLE_VALUE) {
        _handle = h;
        _incoming.stream.listen(_handleLine);
        _startReader();
        await _startWriter();
        return true;
      }
      await Future<void>.delayed(retryInterval);
    }
    return false;
  }

  /// 断开连接并释放资源（不终止 mpv）。
  Future<void> disconnect() async {
    // 先终止后台读取/写入 isolate，避免 CloseHandle 与挂起的
    // ReadFile/WriteFile 竞态。
    if (_reader != null) {
      _reader!.kill(priority: Isolate.immediate);
      _reader = null;
    }
    if (_writer != null) {
      _writer!.kill(priority: Isolate.immediate);
      _writer = null;
    }
    _writerPort = null;
    _readerPort?.close();
    _readerPort = null;
    if (_handle != INVALID_HANDLE_VALUE) {
      CloseHandle(_handle);
      _handle = INVALID_HANDLE_VALUE;
    }
    for (final c in _pending.values) {
      c.completeError(StateError('IPC 已断开'));
    }
    _pending.clear();
  }

  /// 查询属性值（如 `time-pos`、`duration`、`pause`）。
  Future<Object?> getProperty(String name) => _request({
    'command': ['get_property', name],
  });

  /// 设置属性值（如 `pause`）。
  Future<Object?> setProperty(String name, Object value) => _request({
    'command': ['set_property', name, value],
  });

  /// 注册属性观察：属性变化时经 [propertyEvents] 推送事件。
  /// [observeId] 由调用方自定（1..N，用于区分同名属性多次观察）。
  Future<void> observe(String name, int observeId) => _request({
    'command': ['observe_property', observeId, name],
  }).then((_) {});

  /// 执行 mpv 命令（如 `seek`）。
  Future<Object?> command(List<Object?> command) =>
      _request({'command': command});

  /// 发送请求并等待响应；超时（[timeout]）未响应则移除挂起项并抛错。
  Future<Object?> _request(
    Map<String, Object?> msg, {
    Duration timeout = const Duration(seconds: 3),
  }) {
    final id = _nextRequestId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    msg['request_id'] = id;
    _send(msg);
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('mpv IPC 请求超时: ${msg['command']}');
      },
    );
  }

  // ── 内部 ───────────────────────────────────────────────────

  /// 尝试打开 named pipe（CreateFile，OPEN_EXISTING）。
  int _tryOpenPipe() {
    final name = pipeName.toNativeUtf16();
    final h = CreateFile(
      name,
      GENERIC_READ | GENERIC_WRITE,
      0,
      nullptr,
      OPEN_EXISTING,
      0,
      0,
    );
    free(name);
    return h;
  }

  /// 发送一条 JSON-RPC 消息（追加换行）。
  ///
  /// 经写入 isolate 队列发出：`WriteFile` 在独立线程执行，
  /// 管道缓冲满时不会阻塞主 isolate（UI 线程）。
  void _send(Map<String, Object?> msg) {
    final port = _writerPort;
    if (port == null) return;
    final data = Uint8List.fromList(utf8.encode('${jsonEncode(msg)}\n'));
    port.send(data);
  }

  /// 启动写入 isolate：持有句柄，循环处理写入队列。
  Future<void> _startWriter() async {
    final ready = ReceivePort();
    _writer = await Isolate.spawn(_writeLoop, [_handle, ready.sendPort]);
    // 等待写 isolate 回传其队列 SendPort（异步初始化完成）。
    _writerPort = await ready.first as SendPort;
    ready.close();
  }

  /// 写入循环（isolate 入口）：收到字节流后同步 WriteFile。
  static void _writeLoop(List<dynamic> args) {
    final handle = args[0] as int;
    final readyPort = args[1] as SendPort;
    final queue = ReceivePort();
    readyPort.send(queue.sendPort);
    queue.listen((msg) {
      if (msg is Uint8List && msg.isNotEmpty) {
        final buffer = calloc<Uint8>(msg.length);
        buffer.asTypedList(msg.length).setAll(0, msg);
        final written = calloc<Uint32>();
        WriteFile(handle, buffer, msg.length, written, nullptr);
        free(buffer);
        free(written);
      }
    });
  }

  /// 启动后台读取 isolate：阻塞 ReadFile 循环，按行回传。
  void _startReader() {
    final port = ReceivePort();
    _readerPort = port;
    port.listen((msg) {
      if (msg is String) {
        _incoming.add(msg);
      } else {
        // null = EOF（mpv 退出）
        _incoming.add('__eof__');
      }
    });
    unawaited(
      Isolate.spawn(_readLoop, [_handle, port.sendPort]).then((reader) {
        if (_disposed || !identical(_readerPort, port)) {
          reader.kill(priority: Isolate.immediate);
          return;
        }
        _reader = reader;
      }),
    );
  }

  /// 处理一行 JSON。
  void _handleLine(String line) {
    if (line == '__eof__') {
      _onDisconnected();
      return;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    if (decoded.containsKey('request_id')) {
      final id = decoded['request_id'];
      final completer = id is int ? _pending.remove(id) : null;
      if (completer != null) {
        final error = decoded['error'];
        if (error == null || error == 'success') {
          completer.complete(decoded['data']);
        } else {
          completer.completeError(StateError('mpv 错误: $error'));
        }
      }
    } else if (decoded['event'] == 'property-change') {
      final name = decoded['name'];
      if (name is String) {
        _propertyEvents.add(
          MpvPropertyEvent(name: name, value: decoded['data']),
        );
      }
    }
  }

  void _onDisconnected() {
    if (_handle != INVALID_HANDLE_VALUE) {
      CloseHandle(_handle);
      _handle = INVALID_HANDLE_VALUE;
    }
    for (final c in _pending.values) {
      c.completeError(StateError('mpv 已退出'));
    }
    _pending.clear();
    // 事件流只关闭一次（与 dispose 状态分离：mpv 正常退出也触发本方法）。
    if (!_eventsClosed) {
      _eventsClosed = true;
      unawaited(_propertyEvents.close());
    }
  }

  /// 后台读取循环（isolate 入口）：ReadFile 阻塞读，按 `\n` 切行回传。
  static void _readLoop(List<dynamic> args) {
    final handle = args[0] as int;
    final sendPort = args[1] as SendPort;

    final buffer = calloc<Uint8>(4096);
    final read = calloc<Uint32>();
    var pending = <int>[];

    while (true) {
      final ok = ReadFile(handle, buffer, 4096, read, nullptr);
      if (ok == 0) {
        sendPort.send(null);
        break;
      }
      final n = read.value;
      if (n == 0) {
        sendPort.send(null);
        break;
      }
      pending.addAll(buffer.asTypedList(n));
      // 按行切分（保留最后不完整段）
      var start = 0;
      for (var i = 0; i < pending.length; i++) {
        if (pending[i] == 10) {
          final line = utf8.decode(
            pending.sublist(start, i),
            allowMalformed: true,
          );
          sendPort.send(line);
          start = i + 1;
        }
      }
      if (start > 0) {
        pending = pending.sublist(start);
      }
    }
    free(buffer);
    free(read);
  }

  /// 释放资源（不再使用后调用；幂等，可重复调用）。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await disconnect();
    await _incoming.close();
  }
}
