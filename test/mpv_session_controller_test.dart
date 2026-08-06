@TestOn('windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/domain/services/mpv_scripts.dart';

/// 真实 MPV 命令文件集成测试。
///
/// 验证软件内暂停/恢复按钮使用的会话命令文件能够控制对应 MPV，并由
/// 会话状态文件回报结果。依赖本机 MPV；未安装时跳过。
void main() {
  const mpvExe = r'D:\MPV_Player\mpv_config-2026.04.14\mpv.exe';

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
