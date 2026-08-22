@TestOn('windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/domain/services/mpv_session_controller.dart';
import 'package:streampath/domain/services/mpv_scripts.dart';
import 'package:win32/win32.dart';

/// 真实 MPV 命令文件集成测试。
///
/// 验证软件内暂停/恢复按钮使用的会话命令文件能够控制对应 MPV，并由
/// 会话状态文件回报结果。依赖本机 MPV；未安装时跳过。
void main() {
  const mpvExe = r'D:\MPV_Player\mpv_config-2026.04.14\mpv.exe';

  test(
    'IPC 请求超时在 I/O isolate 内取消并使 controller 明确断连',
    () async {
      final pipeName =
          '${r'\\.\pipe\streampath-timeout-'}$pid-'
          '${DateTime.now().microsecondsSinceEpoch}';
      final ready = ReceivePort();
      final done = ReceivePort();
      final server = await Isolate.spawn(_silentPipeServer, [
        pipeName,
        ready.sendPort,
        done.sendPort,
      ]);
      final controller = MpvSessionController(pipeName: pipeName);
      try {
        expect(await ready.first.timeout(const Duration(seconds: 3)), true);
        expect(
          await controller.connect(timeout: const Duration(seconds: 3)),
          isTrue,
        );

        final elapsed = Stopwatch()..start();
        await expectLater(
          controller.getProperty('mpv-version'),
          throwsA(isA<TimeoutException>()),
        );
        elapsed.stop();
        expect(elapsed.elapsed, lessThan(const Duration(seconds: 5)));
        expect(controller.isConnected, isFalse);

        final rejected = Stopwatch()..start();
        await expectLater(
          controller.getProperty('pause'),
          throwsA(isA<StateError>()),
        );
        rejected.stop();
        expect(rejected.elapsed, lessThan(const Duration(milliseconds: 500)));
        expect(
          await done.first.timeout(const Duration(seconds: 3)),
          true,
          reason: '静默 pipe server 应在客户端取消并断开后正常释放 handle',
        );
      } finally {
        await controller.dispose();
        ready.close();
        done.close();
        server.kill(priority: Isolate.immediate);
      }
    },
    timeout: const Timeout(Duration(seconds: 12)),
  );

  test('真实 MPV：会话命令文件可暂停和恢复', () async {
    if (!File(mpvExe).existsSync()) {
      markTestSkipped('未检测到 MPV（D:\\MPV_Player）');
      return;
    }
    final dir = Directory.systemTemp.createTempSync('streampath_mpv_cmd_');
    final statusPath = p.join(dir.path, 'status.txt');
    final commandPath = p.join(dir.path, 'command.txt');
    final scriptPath = await MpvScripts.ensureCurrent(
      statusPath,
      commandPath,
      dir,
      sessionId: 'integration',
    );
    final process = await Process.start(mpvExe, [
      '--no-config',
      '--no-terminal',
      '--idle=yes',
      '--loop-file=inf',
      '--vo=null',
      '--ao=null',
      '--script=$scriptPath',
      'av://lavfi:testsrc=size=16x16:rate=1',
    ]);
    try {
      await _waitForPaused(statusPath, false);

      await File(commandPath).writeAsString('pause', flush: true);
      await _waitForPaused(statusPath, true, commandPath: commandPath);

      await File(commandPath).writeAsString('resume', flush: true);
      await _waitForPaused(statusPath, false, commandPath: commandPath);
    } finally {
      process.kill();
      await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () => -1,
      );
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}

void _silentPipeServer(List<Object?> arguments) {
  final pipeName = arguments[0]! as String;
  final ready = arguments[1]! as SendPort;
  final done = arguments[2]! as SendPort;
  final nativeName = pipeName.toNativeUtf16();
  final handle = CreateNamedPipe(
    nativeName,
    PIPE_ACCESS_DUPLEX,
    PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
    1,
    4096,
    4096,
    0,
    nullptr,
  );
  free(nativeName);
  if (handle == INVALID_HANDLE_VALUE) {
    ready.send(GetLastError());
    done.send(false);
    return;
  }
  ready.send(true);
  final buffer = calloc<Uint8>(4096);
  final read = calloc<Uint32>();
  try {
    final connected = ConnectNamedPipe(handle, nullptr);
    final connectError = connected == 0 ? GetLastError() : ERROR_SUCCESS;
    if (connected == 0 &&
        connectError != ERROR_PIPE_CONNECTED &&
        connectError != ERROR_SUCCESS) {
      done.send(false);
      return;
    }
    ReadFile(handle, buffer, 4096, read, nullptr);
    // 故意不回 JSON；客户端必须在自身 3 秒预算内取消 overlapped Read。
    Sleep(3500);
    done.send(true);
  } finally {
    free(buffer);
    free(read);
    DisconnectNamedPipe(handle);
    CloseHandle(handle);
  }
}

Future<void> _waitForPaused(
  String statusPath,
  bool expected, {
  String? commandPath,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  var lastStatus = '<不存在>';
  while (DateTime.now().isBefore(deadline)) {
    final file = File(statusPath);
    if (file.existsSync()) {
      try {
        lastStatus = await file.readAsString();
        final lines = const LineSplitter().convert(lastStatus);
        if (lines.length >= 3 && (lines[2].trim() == '1') == expected) return;
      } on FileSystemException {
        // MPV 正在替换状态文件时继续重试。
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  final commandFile = commandPath == null ? null : File(commandPath);
  final commandState = commandFile == null
      ? '<未提供>'
      : commandFile.existsSync()
      ? await commandFile.readAsString()
      : '<已被 MPV 删除>';
  throw TimeoutException(
    'MPV 未在限定时间内切换暂停状态：$expected；最后状态：$lastStatus；'
    '命令文件：$commandState',
  );
}
