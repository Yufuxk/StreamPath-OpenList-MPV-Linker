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
///  - 每个请求在后台 isolate 内按顺序完成 overlapped WriteFile/ReadFile，
///    主 isolate 不执行阻塞 I/O；
///  - 解析响应前夹带的 `property-change` 并经广播流分发；当前生产代码
///    不使用持续观察，事件流不承诺在没有后续请求时主动排空；
///  - 断开（mpv 退出/崩溃）检测与资源释放。
///
/// 线程模型：写入在主 isolate（消息小、低频）；读取在独立 isolate
/// （`ReadFile` 阻塞循环，句柄以 int 传递，不跨 isolate 共享指针）。
class MpvSessionController {
  MpvSessionController({this.pipeName = r'\\.\pipe\mpvsocket'});

  /// named pipe 路径（与 mpv `--input-ipc-server` 参数一致）。
  final String pipeName;

  final _propertyEvents = StreamController<MpvPropertyEvent>.broadcast();

  /// 属性变化事件流；事件在后续请求读取响应时一并分发。
  Stream<MpvPropertyEvent> get propertyEvents => _propertyEvents.stream;

  int _nextRequestId = 1;
  int _handle = INVALID_HANDLE_VALUE;
  bool _disposed = false;
  bool _eventsClosed = false;
  Future<void> _requestTail = Future<void>.value();
  Uint8List _readRemainder = Uint8List(0);

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
        return true;
      }
      await Future<void>.delayed(retryInterval);
    }
    return false;
  }

  /// 断开连接并释放资源（不终止 mpv）。
  Future<void> disconnect() async {
    try {
      await _requestTail;
    } catch (_) {
      // 请求失败后仍需释放连接。
    }
    if (_handle != INVALID_HANDLE_VALUE) {
      CloseHandle(_handle);
      _handle = INVALID_HANDLE_VALUE;
    }
    _readRemainder = Uint8List(0);
  }

  /// 查询属性值（如 `time-pos`、`duration`、`pause`）。
  Future<Object?> getProperty(String name) => _request({
    'command': ['get_property', name],
  });

  /// 设置属性值（如 `pause`）。
  Future<Object?> setProperty(String name, Object value) => _request({
    'command': ['set_property', name, value],
  });

  /// 注册属性观察：后续请求读取到变化时经 [propertyEvents] 推送。
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
    msg['request_id'] = id;
    final operation = _requestTail.then(
      (_) => _exchangeRequest(msg, id, timeout),
    );
    _requestTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
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
      FILE_FLAG_OVERLAPPED,
      0,
    );
    free(name);
    return h;
  }

  Future<Object?> _exchangeRequest(
    Map<String, Object?> message,
    int requestId,
    Duration timeout,
  ) async {
    final handle = _handle;
    if (_disposed || handle == INVALID_HANDLE_VALUE) {
      throw StateError('IPC 未连接');
    }
    final bytes = Uint8List.fromList(utf8.encode('${jsonEncode(message)}\n'));
    final remainder = _readRemainder;
    final exchanged = await Isolate.run(
      () => MpvSessionController._exchangePipe(
        handle: handle,
        request: bytes,
        requestId: requestId,
        initialRemainder: remainder,
        timeoutMilliseconds: timeout.inMilliseconds,
      ),
    );
    if (exchanged['timedOut'] == true) {
      if (_handle == handle) {
        CloseHandle(_handle);
        _handle = INVALID_HANDLE_VALUE;
      }
      throw TimeoutException('mpv IPC 请求超时: ${message['command']}');
    }
    if (_handle != handle) throw StateError('IPC 已断开');
    final nativeError = exchanged['nativeError'];
    if (nativeError is int) {
      CloseHandle(_handle);
      _handle = INVALID_HANDLE_VALUE;
      throw StateError(
        'mpv IPC ${exchanged['phase'] ?? 'exchange'} 失败: '
        'Windows error $nativeError',
      );
    }
    _readRemainder = exchanged['remainder']! as Uint8List;

    var responseSeen = false;
    Object? response;
    Object? responseError;
    for (final line in exchanged['lines']! as List<String>) {
      Object? decoded;
      try {
        decoded = jsonDecode(line);
      } catch (_) {
        continue;
      }
      if (decoded is! Map) continue;
      if (decoded['request_id'] == requestId) {
        responseSeen = true;
        response = decoded['data'];
        responseError = decoded['error'];
      } else if (decoded['event'] == 'property-change' && !_eventsClosed) {
        final name = decoded['name'];
        if (name is String) {
          _propertyEvents.add(
            MpvPropertyEvent(name: name, value: decoded['data']),
          );
        }
      }
    }
    if (!responseSeen) throw StateError('mpv IPC 响应缺少 request_id=$requestId');
    if (responseError != null && responseError != 'success') {
      throw StateError('mpv 错误: $responseError');
    }
    return response;
  }

  /// 同一个 pipe handle 上按顺序写请求再读响应；overlapped I/O 的等待、
  /// 超时取消与 OVERLAPPED 生命周期全部留在本 isolate 内。
  static Map<String, Object?> _exchangePipe({
    required int handle,
    required Uint8List request,
    required int requestId,
    required Uint8List initialRemainder,
    required int timeoutMilliseconds,
  }) {
    final writeBuffer = calloc<Uint8>(request.length);
    final written = calloc<Uint32>();
    final writeOverlapped = calloc<OVERLAPPED>();
    final readBuffer = calloc<Uint8>(4096);
    final read = calloc<Uint32>();
    final readOverlapped = calloc<OVERLAPPED>();
    final writeEvent = CreateEvent(nullptr, TRUE, FALSE, nullptr);
    final readEvent = CreateEvent(nullptr, TRUE, FALSE, nullptr);
    final deadline = DateTime.now().add(
      Duration(
        milliseconds: timeoutMilliseconds <= 0 ? 1 : timeoutMilliseconds,
      ),
    );
    try {
      if (writeEvent == 0 || readEvent == 0) {
        return <String, Object?>{
          'nativeError': GetLastError(),
          'phase': 'create-event',
          'lines': <String>[],
          'remainder': initialRemainder,
        };
      }
      writeOverlapped.ref.hEvent = writeEvent;
      readOverlapped.ref.hEvent = readEvent;
      writeBuffer.asTypedList(request.length).setAll(0, request);
      if (WriteFile(
            handle,
            writeBuffer,
            request.length,
            written,
            writeOverlapped,
          ) ==
          0) {
        final pendingError = GetLastError();
        // win32 FFI 的 GetLastError 在部分环境不会保留 Read/WriteFile
        // 返回前的 997；overlapped 调用返回 0 且 last-error=0 时仍由
        // GetOverlappedResultEx 判定最终结果。
        if (pendingError != ERROR_IO_PENDING && pendingError != 0) {
          return <String, Object?>{
            'nativeError': pendingError,
            'phase': 'write-start',
            'lines': <String>[],
            'remainder': initialRemainder,
          };
        }
        final completionError = _completeOverlapped(
          handle: handle,
          overlapped: writeOverlapped,
          transferred: written,
          deadline: deadline,
        );
        if (completionError != null) {
          return <String, Object?>{
            if (completionError == WAIT_TIMEOUT) 'timedOut': true,
            if (completionError != WAIT_TIMEOUT) 'nativeError': completionError,
            'phase': 'write-complete',
            'lines': <String>[],
            'remainder': initialRemainder,
          };
        }
      }

      var pending = initialRemainder.toList(growable: true);
      final lines = <String>[];
      while (true) {
        readOverlapped.ref
          ..Internal = 0
          ..InternalHigh = 0
          ..Offset = 0
          ..OffsetHigh = 0
          ..hEvent = readEvent;
        ResetEvent(readEvent);
        if (ReadFile(handle, readBuffer, 4096, read, readOverlapped) == 0) {
          final pendingError = GetLastError();
          if (pendingError != ERROR_IO_PENDING && pendingError != 0) {
            return <String, Object?>{
              'nativeError': pendingError,
              'phase': 'read-start',
              'lines': lines,
              'remainder': Uint8List.fromList(pending),
            };
          }
          final completionError = _completeOverlapped(
            handle: handle,
            overlapped: readOverlapped,
            transferred: read,
            deadline: deadline,
          );
          if (completionError != null) {
            return <String, Object?>{
              if (completionError == WAIT_TIMEOUT) 'timedOut': true,
              if (completionError != WAIT_TIMEOUT)
                'nativeError': completionError,
              'phase': 'read-complete',
              'lines': lines,
              'remainder': Uint8List.fromList(pending),
            };
          }
        }
        final count = read.value;
        if (count == 0) {
          return <String, Object?>{
            'nativeError': ERROR_BROKEN_PIPE,
            'phase': 'read-empty',
            'lines': lines,
            'remainder': Uint8List.fromList(pending),
          };
        }
        pending.addAll(readBuffer.asTypedList(count));
        var consumed = 0;
        var responseSeen = false;
        for (var index = 0; index < pending.length; index++) {
          if (pending[index] != 10) continue;
          final line = utf8
              .decode(pending.sublist(consumed, index), allowMalformed: true)
              .replaceFirst(RegExp(r'\r$'), '');
          lines.add(line);
          consumed = index + 1;
          try {
            final decoded = jsonDecode(line);
            if (decoded is Map && decoded['request_id'] == requestId) {
              responseSeen = true;
            }
          } catch (_) {
            // 非 JSON 行不影响后续完整响应。
          }
        }
        if (consumed > 0) pending = pending.sublist(consumed);
        if (responseSeen) {
          return <String, Object?>{
            'lines': lines,
            'remainder': Uint8List.fromList(pending),
          };
        }
      }
    } finally {
      if (writeEvent != 0) CloseHandle(writeEvent);
      if (readEvent != 0) CloseHandle(readEvent);
      free(writeBuffer);
      free(written);
      free(writeOverlapped);
      free(readBuffer);
      free(read);
      free(readOverlapped);
    }
  }

  static int? _completeOverlapped({
    required int handle,
    required Pointer<OVERLAPPED> overlapped,
    required Pointer<Uint32> transferred,
    required DateTime deadline,
  }) {
    final remaining = deadline.difference(DateTime.now()).inMilliseconds;
    if (remaining <= 0 ||
        GetOverlappedResultEx(
              handle,
              overlapped,
              transferred,
              remaining,
              FALSE,
            ) ==
            0) {
      final error = remaining <= 0 ? WAIT_TIMEOUT : GetLastError();
      if (error == WAIT_TIMEOUT) {
        CancelIoEx(handle, overlapped);
        // 等待本 isolate 发起的 I/O 完成取消，之后调用方才会释放
        // OVERLAPPED、event 与 pipe handle。
        GetOverlappedResult(handle, overlapped, transferred, TRUE);
      }
      return error;
    }
    return null;
  }

  /// 释放资源（不再使用后调用；幂等，可重复调用）。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await disconnect();
    if (!_eventsClosed) {
      _eventsClosed = true;
      await _propertyEvents.close();
    }
  }
}
