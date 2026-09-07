import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

const int _maximumMessageBytes = 1024 * 1024;

typedef _GetNamedPipeServerProcessIdNative =
    Int32 Function(IntPtr pipe, Pointer<Uint32> serverProcessId);
typedef _GetNamedPipeServerProcessIdDart =
    int Function(int pipe, Pointer<Uint32> serverProcessId);

final _getNamedPipeServerProcessId = DynamicLibrary.open('kernel32.dll')
    .lookupFunction<
      _GetNamedPipeServerProcessIdNative,
      _GetNamedPipeServerProcessIdDart
    >('GetNamedPipeServerProcessId');

class IsoBridgeProtocolException implements Exception {
  const IsoBridgeProtocolException(this.message);

  final String message;

  @override
  String toString() => 'IsoBridgeProtocolException: $message';
}

/// StreamPath 与 ISO Bridge 之间的 protocol v1 named-pipe 客户端。
///
/// 消息使用四字节小端长度与 UTF-8 JSON。阻塞的 Windows I/O 始终在独立
/// isolate 内执行，避免卡住 Flutter UI isolate。
class IsoBridgeClient {
  IsoBridgeClient._(this.pipeName, this.helperPid, this._handle);

  final String pipeName;
  final int helperPid;
  int _handle;
  Future<void> _tail = Future<void>.value();

  bool get isConnected => _handle != INVALID_HANDLE_VALUE;

  static Future<IsoBridgeClient> connect({
    required String pipeName,
    required int helperPid,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!pipeName.startsWith(r'\\.\pipe\') || helperPid <= 0) {
      throw const IsoBridgeProtocolException('ISO Bridge pipe 参数无效');
    }
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final nativeName = pipeName.toNativeUtf16();
      final handle = CreateFile(
        nativeName,
        GENERIC_READ | GENERIC_WRITE,
        0,
        nullptr,
        OPEN_EXISTING,
        0,
        0,
      );
      free(nativeName);
      if (handle != INVALID_HANDLE_VALUE) {
        final serverPid = calloc<Uint32>();
        try {
          if (_getNamedPipeServerProcessId(handle, serverPid) == 0 ||
              serverPid.value != helperPid) {
            CloseHandle(handle);
            throw const IsoBridgeProtocolException(
              'ISO Bridge named pipe 服务端身份不匹配',
            );
          }
        } finally {
          free(serverPid);
        }
        return IsoBridgeClient._(pipeName, helperPid, handle);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw TimeoutException('等待 ISO Bridge named pipe 超时');
  }

  Future<void> send(Map<String, Object?> message) => _serialize(() async {
    final handle = _requireHandle();
    final body = Uint8List.fromList(utf8.encode(jsonEncode(message)));
    if (body.isEmpty || body.length > _maximumMessageBytes) {
      throw const IsoBridgeProtocolException('ISO Bridge IPC 消息长度无效');
    }
    final result = await _writeFrameInWorker(handle, body);
    if (result != 0) {
      await close();
      throw IsoBridgeProtocolException(
        '写入 ISO Bridge IPC 失败：Windows error $result',
      );
    }
  });

  Future<Map<String, dynamic>> receive({
    Duration timeout = const Duration(seconds: 120),
  }) =>
      _serialize(() async {
        final handle = _requireHandle();
        final result = await _readFrameInWorker(handle);
        final nativeError = result['nativeError'];
        if (nativeError is int) {
          await close();
          throw IsoBridgeProtocolException(
            '读取 ISO Bridge IPC 失败：Windows error $nativeError',
          );
        }
        final bytes = result['body'];
        if (bytes is! Uint8List) {
          throw const IsoBridgeProtocolException('ISO Bridge IPC 响应为空');
        }
        try {
          final value = jsonDecode(utf8.decode(bytes));
          if (value is! Map<String, dynamic>) {
            throw const FormatException('root is not an object');
          }
          return value;
        } on FormatException catch (error) {
          throw IsoBridgeProtocolException('ISO Bridge IPC JSON 无效：$error');
        }
      }).timeout(
        timeout,
        onTimeout: () {
          unawaited(close());
          throw TimeoutException('等待 ISO Bridge 响应超时');
        },
      );

  Future<void> close() async {
    final handle = _handle;
    if (handle == INVALID_HANDLE_VALUE) return;
    _handle = INVALID_HANDLE_VALUE;
    CloseHandle(handle);
  }

  int _requireHandle() {
    if (_handle == INVALID_HANDLE_VALUE) {
      throw const IsoBridgeProtocolException('ISO Bridge IPC 已断开');
    }
    return _handle;
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  static Future<int> _writeFrameInWorker(int handle, Uint8List body) =>
      Isolate.run(() => _writeFrame(handle: handle, body: body));

  static Future<Map<String, Object?>> _readFrameInWorker(int handle) =>
      Isolate.run(() => _readFrame(handle));

  static int _writeFrame({required int handle, required Uint8List body}) {
    final frame = calloc<Uint8>(body.length + 4);
    final written = calloc<Uint32>();
    try {
      final bytes = frame.asTypedList(body.length + 4);
      final length = body.length;
      bytes[0] = length & 0xff;
      bytes[1] = (length >> 8) & 0xff;
      bytes[2] = (length >> 16) & 0xff;
      bytes[3] = (length >> 24) & 0xff;
      bytes.setRange(4, bytes.length, body);
      var offset = 0;
      while (offset < bytes.length) {
        if (WriteFile(
              handle,
              frame + offset,
              bytes.length - offset,
              written,
              nullptr,
            ) ==
            0) {
          return GetLastError();
        }
        if (written.value == 0) return ERROR_BROKEN_PIPE;
        offset += written.value;
      }
      return 0;
    } finally {
      free(frame);
      free(written);
    }
  }

  static Map<String, Object?> _readFrame(int handle) {
    final prefix = calloc<Uint8>(4);
    try {
      final prefixError = _readExact(handle, prefix, 4);
      if (prefixError != 0) return {'nativeError': prefixError};
      final bytes = prefix.asTypedList(4);
      final length =
          bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24);
      if (length <= 0 || length > _maximumMessageBytes) {
        return {'nativeError': ERROR_INVALID_DATA};
      }
      final body = calloc<Uint8>(length);
      try {
        final bodyError = _readExact(handle, body, length);
        if (bodyError != 0) return {'nativeError': bodyError};
        return {'body': Uint8List.fromList(body.asTypedList(length))};
      } finally {
        free(body);
      }
    } finally {
      free(prefix);
    }
  }

  static int _readExact(int handle, Pointer<Uint8> destination, int length) {
    final received = calloc<Uint32>();
    try {
      var offset = 0;
      while (offset < length) {
        if (ReadFile(
              handle,
              destination + offset,
              length - offset,
              received,
              nullptr,
            ) ==
            0) {
          return GetLastError();
        }
        if (received.value == 0) return ERROR_BROKEN_PIPE;
        offset += received.value;
      }
      return 0;
    } finally {
      free(received);
    }
  }
}
