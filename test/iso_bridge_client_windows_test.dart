import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/domain/services/iso_bridge_client.dart';
import 'package:win32/win32.dart';

const int _maximumTestMessageBytes = 1024 * 1024;

void main() {
  test('真实 named pipe 可连续 receive、send、receive', () async {
    final suffix =
        'streampath_iso_client_test_${GetCurrentProcessId()}_'
        '${DateTime.now().microsecondsSinceEpoch}';
    final pipeName = '${r'\\.\pipe\'}$suffix';
    final events = ReceivePort();
    final iterator = StreamIterator<dynamic>(events);
    final serverIsolate = await Isolate.spawn(_pipeServerMain, [
      pipeName,
      events.sendPort,
    ]);
    addTearDown(() {
      serverIsolate.kill(priority: Isolate.immediate);
      events.close();
    });
    expect(
      await iterator.moveNext().timeout(const Duration(seconds: 5)),
      isTrue,
    );
    expect(iterator.current, {'type': 'listening'});

    final client = await IsoBridgeClient.connect(
      pipeName: pipeName,
      helperPid: GetCurrentProcessId(),
    );
    final hello = await client.receive(timeout: const Duration(seconds: 5));
    expect(hello, {
      'type': 'hello',
      'version': 1,
      'pid': GetCurrentProcessId(),
    });

    await client.send(const {'type': 'ping', 'version': 1});
    final response = await client.receive(timeout: const Duration(seconds: 5));
    expect(response, {'type': 'ready', 'version': 1, 'attached': true});
    await client.close();

    expect(
      await iterator.moveNext().timeout(const Duration(seconds: 5)),
      isTrue,
    );
    final serverResult = iterator.current as Map<dynamic, dynamic>;
    expect(serverResult['type'], 'completed');
    expect(serverResult['received'], {'type': 'ping', 'version': 1});
    await iterator.cancel();
  });
}

void _pipeServerMain(List<Object> arguments) {
  final pipeName = arguments[0] as String;
  final events = arguments[1] as SendPort;
  final nativeName = pipeName.toNativeUtf16();
  final handle = CreateNamedPipe(
    nativeName,
    PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
    PIPE_TYPE_BYTE |
        PIPE_READMODE_BYTE |
        PIPE_WAIT |
        PIPE_REJECT_REMOTE_CLIENTS,
    1,
    _maximumTestMessageBytes,
    _maximumTestMessageBytes,
    0,
    nullptr,
  );
  free(nativeName);
  if (handle == INVALID_HANDLE_VALUE) {
    events.send({'type': 'error', 'message': 'CreateNamedPipe failed'});
    return;
  }
  events.send({'type': 'listening'});
  try {
    if (ConnectNamedPipe(handle, nullptr) == 0 &&
        GetLastError() != ERROR_PIPE_CONNECTED) {
      throw StateError('ConnectNamedPipe failed: ${GetLastError()}');
    }
    _writeJsonFrame(handle, {
      'type': 'hello',
      'version': 1,
      'pid': GetCurrentProcessId(),
    });
    final received = _readJsonFrame(handle);
    _writeJsonFrame(handle, {'type': 'ready', 'version': 1, 'attached': true});
    events.send({'type': 'completed', 'received': received});
  } catch (error, stackTrace) {
    events.send({
      'type': 'error',
      'message': error.toString(),
      'stackTrace': stackTrace.toString(),
    });
  } finally {
    FlushFileBuffers(handle);
    DisconnectNamedPipe(handle);
    CloseHandle(handle);
  }
}

void _writeJsonFrame(int handle, Map<String, Object?> message) {
  final body = Uint8List.fromList(utf8.encode(jsonEncode(message)));
  final frame = calloc<Uint8>(body.length + 4);
  final written = calloc<Uint32>();
  try {
    final bytes = frame.asTypedList(body.length + 4);
    bytes[0] = body.length & 0xff;
    bytes[1] = (body.length >> 8) & 0xff;
    bytes[2] = (body.length >> 16) & 0xff;
    bytes[3] = (body.length >> 24) & 0xff;
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
        throw StateError('WriteFile failed: ${GetLastError()}');
      }
      if (written.value == 0) throw StateError('WriteFile returned zero');
      offset += written.value;
    }
  } finally {
    free(frame);
    free(written);
  }
}

Map<String, dynamic> _readJsonFrame(int handle) {
  final prefix = _readExact(handle, 4);
  final length =
      prefix[0] | (prefix[1] << 8) | (prefix[2] << 16) | (prefix[3] << 24);
  if (length <= 0 || length > _maximumTestMessageBytes) {
    throw StateError('invalid frame length');
  }
  final decoded = jsonDecode(utf8.decode(_readExact(handle, length)));
  if (decoded is! Map<String, dynamic>) throw StateError('invalid JSON frame');
  return decoded;
}

Uint8List _readExact(int handle, int length) {
  final buffer = calloc<Uint8>(length);
  final received = calloc<Uint32>();
  try {
    final output = Uint8List(length);
    var offset = 0;
    while (offset < length) {
      if (ReadFile(
            handle,
            buffer + offset,
            length - offset,
            received,
            nullptr,
          ) ==
          0) {
        throw StateError('ReadFile failed: ${GetLastError()}');
      }
      if (received.value == 0) throw StateError('ReadFile returned zero');
      output.setRange(
        offset,
        offset + received.value,
        buffer.asTypedList(length),
        offset,
      );
      offset += received.value;
    }
    return output;
  } finally {
    free(buffer);
    free(received);
  }
}
