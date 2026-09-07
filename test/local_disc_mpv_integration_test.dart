@TestOn('windows')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/domain/services/mpv_scripts.dart';

void main() {
  final executable = Platform.environment['STREAMPATH_LOCAL_DISC_MPV'];
  final devicePath = Platform.environment['STREAMPATH_LOCAL_DISC_TEST_ROOT'];

  test(
    '真实 MPV 可从本地 ISO/BDMV 根读取 edition 并写入菜单状态',
    () async {
      if (executable == null || devicePath == null) {
        markTestSkipped(
          '设置 STREAMPATH_LOCAL_DISC_MPV 与 '
          'STREAMPATH_LOCAL_DISC_TEST_ROOT 后运行真实本地蓝光测试',
        );
        return;
      }
      final directory = Directory.systemTemp.createTempSync(
        'streampath_local_disc_mpv_',
      );
      final statusPath = p.join(directory.path, 'status.txt');
      final commandPath = p.join(directory.path, 'command.txt');
      final progressPath = p.join(directory.path, 'progress.jsonl');
      Process? process;
      try {
        final scriptPath = await MpvScripts.ensureCurrent(
          statusPath,
          commandPath,
          directory,
          sessionId: 'real-local-disc',
          progressFile: progressPath,
          launchEpoch: 'real-local-disc',
          reportedPath: devicePath,
        );
        process = await Process.start(executable, [
          '--no-config',
          '--terminal=yes',
          '--msg-level=all=warn',
          '--vo=null',
          '--ao=null',
          '--pause=yes',
          '--idle=no',
          '--keep-open=yes',
          '--bluray-device=$devicePath',
          '--script=$scriptPath',
          'bd://longest',
        ]);
        final output = StringBuffer();
        process.stdout.transform(systemEncoding.decoder).listen(output.write);
        process.stderr.transform(systemEncoding.decoder).listen(output.write);
        List<String>? lines;
        final deadline = DateTime.now().add(const Duration(seconds: 25));
        while (DateTime.now().isBefore(deadline)) {
          final statusFile = File(statusPath);
          if (await statusFile.exists()) {
            final current = await statusFile.readAsLines();
            if (current.length >= 21 && int.tryParse(current[18]) == 0) {
              lines = current;
              break;
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(lines, isNotNull, reason: output.toString());
        expect(lines, hasLength(greaterThanOrEqualTo(21)));
        expect(lines![1], devicePath);
        expect(int.tryParse(lines[18]), 0);
        final currentEdition = int.tryParse(lines[19]);
        final editionCount = int.tryParse(lines[20]);
        expect(currentEdition, isNotNull);
        expect(currentEdition, greaterThanOrEqualTo(0));
        expect(editionCount, isNotNull);
        expect(editionCount, greaterThan(currentEdition!));
      } finally {
        if (process != null) {
          process.kill();
          try {
            await process.exitCode.timeout(const Duration(seconds: 5));
          } on TimeoutException {
            // 只终止本测试创建的 MPV 进程。
            process.kill(ProcessSignal.sigkill);
          }
        }
        try {
          directory.deleteSync(recursive: true);
        } on FileSystemException {
          // MPV 退出后的短暂文件占用交由系统临时目录回收。
        }
      }
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
