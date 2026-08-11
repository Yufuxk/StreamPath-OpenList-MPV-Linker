import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/domain/services/mpv_scripts.dart';

void main() {
  final testRoot = Platform.environment['STREAMPATH_MPV_TEST_ROOT'];

  test(
    '实际 MPV 版本可加载状态脚本、命令通道、IPC 与进度日志',
    () async {
      final root = Directory(testRoot!);
      final executables =
          root
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .where((file) => p.basename(file.path).toLowerCase() == 'mpv.exe')
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      expect(executables, hasLength(4));

      final workspace = Directory.systemTemp.createTempSync('sp_mpv_compat_');
      try {
        final media = File(p.join(workspace.path, 'silence.wav'));
        await media.writeAsBytes(_silentWave(seconds: 1), flush: true);

        for (var index = 0; index < executables.length; index++) {
          final executable = executables[index];
          final version = await Process.run(executable.path, ['--version']);
          expect(version.exitCode, 0, reason: '${executable.path} 无法输出版本信息');

          final caseDir = Directory(p.join(workspace.path, 'case_$index'))
            ..createSync();
          final status = p.join(caseDir.path, 'current.txt');
          final command = p.join(caseDir.path, 'command.txt');
          final progress = p.join(caseDir.path, 'progress.jsonl');
          final script = await MpvScripts.ensureCurrent(
            status,
            command,
            caseDir,
            sessionId: 'compat_$index',
            progressFile: progress,
          );
          final pipe =
              r'\\.\pipe\streampath-compat-'
              '$pid-${DateTime.now().microsecondsSinceEpoch}-$index';
          final process = await Process.start(executable.path, [
            '--no-config',
            '--terminal=no',
            '--vo=null',
            '--ao=null',
            '--pause=yes',
            '--idle=no',
            '--keep-open=no',
            '--input-ipc-server=$pipe',
            '--script=$script',
            media.path,
          ]);
          final stderr = StringBuffer();
          process.stderr.transform(utf8.decoder).listen(stderr.write);
          process.stdout.drain<void>();

          await _waitUntil(() => File(status).existsSync());
          await File(command).writeAsString('resume', flush: true);
          final exitCode = await process.exitCode.timeout(
            const Duration(seconds: 20),
            onTimeout: () {
              process.kill();
              return -1;
            },
          );
          expect(exitCode, 0, reason: '${executable.path} 兼容测试失败：$stderr');

          final lines = (await File(status).readAsString()).split('\n');
          expect(
            lines.length,
            greaterThanOrEqualTo(14),
            reason: '${executable.path} 未写出十四行状态',
          );
          final records = await File(progress).readAsLines();
          expect(records, isNotEmpty);
          final last = jsonDecode(records.last) as Map<String, dynamic>;
          expect(last['outcome'], 'completed');
          expect(last['reason'], 'eof');
        }
      } finally {
        try {
          workspace.deleteSync(recursive: true);
        } on FileSystemException {
          // 测试进程退出后仍被杀毒软件短暂占用时交由系统临时目录回收。
        }
      }
    },
    skip: testRoot == null || testRoot.trim().isEmpty
        ? '设置 STREAMPATH_MPV_TEST_ROOT 后运行真实版本兼容测试'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'URL 凭据可完成 Basic 认证且不会随跨来源重定向发送',
    () async {
      final root = Directory(testRoot!);
      final executables =
          root
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .where((file) => p.basename(file.path).toLowerCase() == 'mpv.exe')
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      expect(executables, hasLength(4));
      final media = _silentWave(seconds: 1);
      final expectedAuth = 'Basic ${base64Encode(utf8.encode('viewer:'))}';

      for (final executable in executables) {
        var originAuthenticated = false;
        String? destinationAuth;
        final destination = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        destination.listen((request) async {
          destinationAuth = request.headers.value(
            HttpHeaders.authorizationHeader,
          );
          await request.drain<void>();
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType('audio', 'wav')
            ..headers.contentLength = media.length
            ..add(media);
          await request.response.close();
        });

        final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        origin.listen((request) async {
          await request.drain<void>();
          if (request.headers.value(HttpHeaders.authorizationHeader) !=
              expectedAuth) {
            request.response
              ..statusCode = HttpStatus.unauthorized
              ..headers.set(
                HttpHeaders.wwwAuthenticateHeader,
                'Basic realm="StreamPath test"',
              );
          } else {
            originAuthenticated = true;
            request.response
              ..statusCode = HttpStatus.found
              ..headers.set(
                HttpHeaders.locationHeader,
                'http://${destination.address.address}:'
                '${destination.port}/media.wav',
              );
          }
          await request.response.close();
        });

        try {
          final mediaUrl = Uri(
            scheme: 'http',
            userInfo: 'viewer:',
            host: origin.address.address,
            port: origin.port,
            path: '/media.wav',
          );
          final process = await Process.start(executable.path, [
            '--no-config',
            '--terminal=no',
            '--vo=null',
            '--ao=null',
            '--idle=no',
            '--keep-open=no',
            mediaUrl.toString(),
          ]);
          process.stdout.drain<void>();
          final stderr = await process.stderr.transform(utf8.decoder).join();
          final exitCode = await process.exitCode.timeout(
            const Duration(seconds: 20),
            onTimeout: () {
              process.kill();
              return -1;
            },
          );
          expect(exitCode, 0, reason: '${executable.path}：$stderr');
          expect(originAuthenticated, isTrue, reason: executable.path);
          expect(destinationAuth, isNull, reason: executable.path);
        } finally {
          await origin.close(force: true);
          await destination.close(force: true);
        }
      }
    },
    skip: testRoot == null || testRoot.trim().isEmpty
        ? '设置 STREAMPATH_MPV_TEST_ROOT 后运行真实版本兼容测试'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw TimeoutException('等待 MPV 状态文件超时');
}

Uint8List _silentWave({required int seconds}) {
  const sampleRate = 8000;
  const channels = 1;
  const bitsPerSample = 16;
  final dataLength = sampleRate * seconds * channels * (bitsPerSample ~/ 8);
  final bytes = ByteData(44 + dataLength);

  void ascii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  bytes.setUint32(4, 36 + dataLength, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, channels, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * channels * 2, Endian.little);
  bytes.setUint16(32, channels * 2, Endian.little);
  bytes.setUint16(34, bitsPerSample, Endian.little);
  ascii(36, 'data');
  bytes.setUint32(40, dataLength, Endian.little);
  return bytes.buffer.asUint8List();
}
