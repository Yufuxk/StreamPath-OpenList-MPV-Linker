@TestOn('windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/audio_media_entry.dart';
import 'package:streampath/data/models/connection_config.dart';
import 'package:streampath/data/models/media_entry.dart';
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/data/models/subtitle_item.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/data/remote/webdav_client.dart';
import 'package:streampath/domain/services/audio_lyrics_localizer.dart';
import 'package:streampath/domain/services/audio_mpv_scripts.dart';
import 'package:streampath/domain/services/external_player_service.dart';
import 'package:streampath/domain/services/iso_playback_service.dart';
import 'package:streampath/domain/services/mpv_session_controller.dart';
import 'package:streampath/domain/services/mpv_scripts.dart';
import 'package:streampath/domain/services/mpv_watch_later_sync.dart';

final List<({int pid, Future<int> exitCode})> _ownedMpvProcesses = [];

void main() {
  final testRoot = Platform.environment['STREAMPATH_MPV_TEST_ROOT'];

  test(
    '实际 MPV 版本可加载状态脚本、命令通道、IPC 与进度日志',
    () async {
      final manifestBuilds = _manifestBuilds(testRoot!);
      expect(manifestBuilds, hasLength(4));
      expect(
        manifestBuilds.any(
          (build) => build.version.major == 0 && build.version.minor == 34,
        ),
        isTrue,
        reason: 'manifest 必须包含 MPV 0.34',
      );
      expect(
        manifestBuilds.any(
          (build) => build.version.major > 0 || build.version.minor >= 41,
        ),
        isTrue,
        reason: 'manifest 必须包含 MPV 0.41+',
      );
      final builds = _fiveBuilds(testRoot);
      expect(builds, hasLength(5));

      final workspace = Directory.systemTemp.createTempSync('sp_mpv_compat_');
      try {
        final media = File(p.join(workspace.path, 'silence.wav'));
        await media.writeAsBytes(_silentWave(seconds: 1), flush: true);

        for (var index = 0; index < builds.length; index++) {
          final build = builds[index];
          final executable = build.executable;

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
            launchEpoch: build.id,
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
          final exitCodeFuture = _trackOwnedMpv(process);
          final controller = MpvSessionController(pipeName: pipe);

          try {
            expect(
              await controller.connect(timeout: const Duration(seconds: 10)),
              isTrue,
              reason: '${build.id} 未建立真实 named pipe',
            );
            expect(await controller.getProperty('mpv-version'), isNotNull);
            await controller.setProperty('cache', 'yes');
            await controller.setProperty('demuxer-seekable-cache', 'yes');
            await controller.setProperty('demuxer-max-bytes', 16777216);
            await controller.setProperty('cache-secs', 30.0);
            _expectYes(await controller.getProperty('cache'), build.id);
            _expectYes(
              await controller.getProperty('demuxer-seekable-cache'),
              build.id,
            );
            expect(
              (await controller.getProperty('demuxer-max-bytes') as num)
                  .toInt(),
              16777216,
              reason: build.id,
            );
            expect(
              (await controller.getProperty('cache-secs') as num).toDouble(),
              30.0,
              reason: build.id,
            );
            await _waitUntil(() => File(status).existsSync());
            await File(command).writeAsString('resume', flush: true);
            final exitCode = await exitCodeFuture.timeout(
              const Duration(seconds: 20),
            );
            expect(exitCode, 0, reason: '${build.id} 兼容测试失败：$stderr');
          } finally {
            await controller.dispose();
            if (!await _hasExited(exitCodeFuture)) {
              process.kill();
              await exitCodeFuture.timeout(
                const Duration(seconds: 5),
                onTimeout: () => -1,
              );
            }
          }

          final lines = (await File(status).readAsString()).split('\n');
          expect(
            lines.length,
            greaterThanOrEqualTo(18),
            reason: '${executable.path} 未写出十八行状态',
          );
          final records = await File(progress).readAsLines();
          expect(records, isNotEmpty);
          final last = jsonDecode(records.last) as Map<String, dynamic>;
          expect(last['epoch'], build.id);
          expect(last['outcome'], 'completed');
          expect(last['reason'], 'eof');
          // ignore: avoid_print
          print(
            'MPV_MATRIX pipe-properties id=${build.id} path=${executable.path} '
            'version=${build.versionHead} cache=yes seekable=yes '
            'maxBytes=16777216 cacheSecs=30',
          );
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
      final executables = _manifestBuilds(
        testRoot!,
      ).map((build) => build.executable).toList(growable: false);
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
          final stderrFuture = process.stderr.transform(utf8.decoder).join();
          final exitCodeFuture = _trackOwnedMpv(process);
          int exitCode;
          try {
            exitCode = await exitCodeFuture.timeout(
              const Duration(seconds: 20),
              onTimeout: () {
                process.kill();
                return -1;
              },
            );
          } finally {
            await _cleanupOwnedProcess(process, exitCodeFuture);
          }
          final stderr = await stderrFuture;
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

  test(
    'ISO 参数保持自然退出且所有 MPV 版本阻断加载失败后的播放列表连跳',
    () async {
      final executables = _fiveExecutables(testRoot!);
      expect(executables, hasLength(5));
      final workspace = Directory.systemTemp.createTempSync('sp_iso_mpv_exit_');
      try {
        final media = File(p.join(workspace.path, 'silence.wav'));
        await media.writeAsBytes(_silentWave(seconds: 1), flush: true);
        final playlist = File(p.join(workspace.path, 'iso-playlist.m3u8'));
        await playlist.writeAsString(
          '#EXTM3U\n${media.path}\n${media.path}\n',
          flush: true,
        );
        final failurePlaylist = File(
          p.join(workspace.path, 'iso-failure-playlist.m3u8'),
        );
        await failurePlaylist.writeAsString(
          '#EXTM3U\n${p.join(workspace.path, 'missing-1.m2ts')}\n'
          '${p.join(workspace.path, 'missing-2.m2ts')}\n'
          '${p.join(workspace.path, 'missing-3.m2ts')}\n',
          flush: true,
        );
        final failureEvents = File(
          p.join(workspace.path, 'iso-failure-events.jsonl'),
        );
        final script = File(p.join(workspace.path, 'iso-progress.lua'));
        await script.writeAsString('''
local utils = require "mp.utils"
local LOG = ${jsonEncode(failureEvents.path)}
mp.register_event("end-file", function(event)
    local reason = event and event["reason"] or "unknown"
    if reason ~= "error" then return end
    mp.commandv("stop")
    local ok, line = pcall(utils.format_json, {reason = reason})
    if not ok or line == nil then return end
    local file = io.open(LOG, "a")
    if not file then return end
    file:write(line .. "\\n")
    file:flush()
    file:close()
end)
''', flush: true);
        final configDirectory = Directory(p.join(workspace.path, 'mpv-home'))
          ..createSync();
        await File(
          p.join(configDirectory.path, 'mpv.conf'),
        ).writeAsString('idle=yes\nkeep-open=yes\n', flush: true);

        for (final executable in executables) {
          final args = IsoPlaybackService.buildMpvArgs(
            config: PlayerConfig(
              name: 'MPV',
              executable: executable.path,
              args: const [
                '--terminal=no',
                '--vo=null',
                '--ao=null',
                '--idle=yes',
                '--keep-open=yes',
              ],
            ),
            title: 'ISO exit compatibility',
            playlistPath: playlist.path,
            playlistStart: 0,
            progressScriptPath: script.path,
          );
          final process = await Process.start(
            executable.path,
            args,
            environment: {'MPV_HOME': configDirectory.path},
          );
          process.stdout.drain<void>();
          final stderrFuture = process.stderr.transform(utf8.decoder).join();
          final exitCodeFuture = _trackOwnedMpv(process);
          int exitCode;
          try {
            exitCode = await exitCodeFuture.timeout(
              const Duration(seconds: 20),
              onTimeout: () {
                process.kill();
                return -1;
              },
            );
          } finally {
            await _cleanupOwnedProcess(process, exitCodeFuture);
          }
          expect(
            exitCode,
            0,
            reason: '${executable.path}：${await stderrFuture}',
          );

          if (await failureEvents.exists()) await failureEvents.delete();
          final failureArgs = IsoPlaybackService.buildMpvArgs(
            config: PlayerConfig(
              name: 'MPV',
              executable: executable.path,
              args: const ['--terminal=no', '--vo=null', '--ao=null'],
            ),
            title: 'ISO failure cascade compatibility',
            playlistPath: failurePlaylist.path,
            playlistStart: 0,
            progressScriptPath: script.path,
          );
          final failureProcess = await Process.start(
            executable.path,
            failureArgs,
            environment: {'MPV_HOME': configDirectory.path},
          );
          failureProcess.stdout.drain<void>();
          final failureStderr = failureProcess.stderr
              .transform(utf8.decoder)
              .join();
          final failureExitFuture = _trackOwnedMpv(failureProcess);
          int failureExitCode;
          try {
            failureExitCode = await failureExitFuture.timeout(
              const Duration(seconds: 20),
              onTimeout: () {
                failureProcess.kill();
                return -1;
              },
            );
          } finally {
            await _cleanupOwnedProcess(failureProcess, failureExitFuture);
          }
          final records = await failureEvents.readAsLines();
          expect(
            failureExitCode,
            greaterThanOrEqualTo(0),
            reason: '${executable.path}：${await failureStderr}',
          );
          expect(
            records,
            hasLength(1),
            reason: '${executable.path} 仍在一次加载失败后继续跳过播放列表',
          );
        }
      } finally {
        await workspace.delete(recursive: true);
      }
    },
    skip: testRoot == null || testRoot.trim().isEmpty
        ? '设置 STREAMPATH_MPV_TEST_ROOT 后运行真实版本兼容测试'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    '五个 MPV 实体覆盖音频列表、TS、字幕、watch_later、file_error 与 idle',
    () async {
      final executables = _fiveExecutables(testRoot!);
      expect(executables, hasLength(5));
      final versionHeads = executables.map(_mpvVersionHead).toSet();
      expect(versionHeads, hasLength(5), reason: '五个测试程序必须来自不同 MPV 构建');
      final workspace = Directory.systemTemp.createTempSync(
        'sp_audio_mpv_compat_',
      );
      final audio = _silentWave(seconds: 1);
      final cover = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final name = request.uri.pathSegments.last;
        final List<int> bytes;
        final ContentType contentType;
        if (name.endsWith('.wav')) {
          bytes = audio;
          contentType = ContentType('audio', 'wav');
        } else if (name.endsWith('.lrc')) {
          bytes = utf8.encode('[00:00.00]StreamPath 跨版本歌词\n');
          contentType = ContentType.text;
        } else {
          bytes = cover;
          contentType = ContentType('image', 'png');
        }
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = contentType
          ..headers.contentLength = bytes.length
          ..add(bytes);
        await request.response.close();
      });

      try {
        final origin = 'http://${server.address.address}:${server.port}';
        final client = WebDavClient(baseUrl: origin);
        for (var index = 0; index < executables.length; index++) {
          final executable = executables[index];
          final caseDir = Directory(p.join(workspace.path, 'case_$index'))
            ..createSync();
          final entries = List.generate(
            2,
            (track) => AudioMediaEntry(
              url: '$origin/song$track.wav',
              title: '曲目 ${track + 1}',
              lyrics: AudioCompanionFile(
                name: 'song$track.lrc',
                url: '$origin/song$track.lrc',
              ),
              coverArt: AudioCompanionFile(
                name: 'song$track.png',
                url: '$origin/song$track.png',
              ),
            ),
          );
          final localized = await const AudioLyricsLocalizer().localize(
            entries: entries,
            base: caseDir,
            sessionId: 'audio_compat_$index',
            loader: (url, {required maxBytes, required timeout}) =>
                client.getFileBytes(url, maxBytes: maxBytes, timeout: timeout),
          );
          expect(localized.sessionFiles, hasLength(2));

          final playlist = await AudioMpvScripts.ensurePlaylistM3u8(
            entries,
            (value) => value,
            caseDir,
            sessionId: 'audio_compat_$index',
          );
          final companions = await AudioMpvScripts.ensureCompanions(
            localized.entries,
            (value) => value,
            caseDir,
            sessionId: 'audio_compat_$index',
            lyricsInjectionEnabled: true,
            lyricsAutoSelectEnabled: true,
          );
          final companionText = await File(companions).readAsString();
          expect(companionText, isNot(contains('$origin/song0.lrc')));
          expect(companionText, contains('$origin/song0.png'));

          final status = p.join(caseDir.path, 'current.txt');
          final command = p.join(caseDir.path, 'command.txt');
          final progress = p.join(caseDir.path, 'progress.jsonl');
          final current = await AudioMpvScripts.ensureCurrent(
            status,
            command,
            progress,
            caseDir,
            sessionId: 'audio_compat_$index',
            launchEpoch: 'audio_compat_$index',
          );
          final process = await Process.start(executable.path, [
            '--no-config',
            '--terminal=no',
            '--vo=null',
            '--ao=null',
            '--idle=no',
            '--keep-open=no',
            '--audio-display=embedded-first',
            '--cover-art-auto=no',
            '--sub-auto=no',
            '--script=$companions',
            '--script=$current',
            '--playlist=$playlist',
          ]);
          process.stdout.drain<void>();
          final stderrFuture = process.stderr.transform(utf8.decoder).join();
          final exitCodeFuture = _trackOwnedMpv(process);
          int exitCode;
          try {
            exitCode = await exitCodeFuture.timeout(
              const Duration(seconds: 25),
              onTimeout: () {
                process.kill();
                return -1;
              },
            );
          } finally {
            await _cleanupOwnedProcess(process, exitCodeFuture);
          }
          final stderr = await stderrFuture;
          expect(exitCode, 0, reason: '${executable.path}：$stderr');
          final records = await File(progress).readAsLines();
          final completed = records
              .map((line) => jsonDecode(line) as Map<String, dynamic>)
              .where((record) => record['outcome'] == 'completed')
              .toList();
          expect(
            completed,
            hasLength(2),
            reason: '${executable.path} 未自然播放完整音频列表：$stderr',
          );
          expect(completed.last['playlist_pos'], 1);
          expect(completed.last['epoch'], 'audio_compat_$index');
          // ignore: avoid_print
          print(
            'MPV_MATRIX audio path=${executable.path} '
            'version=${_mpvVersionHead(executable)} completed=2 lrc=local cover=remote',
          );
        }
        await _verifyEntityMatrix(
          builds: _fiveBuilds(testRoot),
          workspace: Directory(p.join(workspace.path, 'entity_matrix'))
            ..createSync(),
        );
        await _assertNoOwnedMpvProcesses();
      } finally {
        await server.close(force: true);
        try {
          workspace.deleteSync(recursive: true);
        } on FileSystemException {
          // MPV 退出后仍被安全软件短暂占用时交由系统临时目录回收。
        }
      }
    },
    skip: testRoot == null || testRoot.trim().isEmpty
        ? '设置 STREAMPATH_MPV_TEST_ROOT 后运行真实版本兼容测试'
        : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

class _MpvVersion {
  const _MpvVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;
}

class _MpvBuild {
  const _MpvBuild({
    required this.id,
    required this.executable,
    required this.versionHead,
    required this.version,
  });

  final String id;
  final File executable;
  final String versionHead;
  final _MpvVersion version;
}

List<_MpvBuild> _manifestBuilds(String root) {
  final manifest = File(
    p.join(Directory.current.path, 'test', 'mpv_compatibility_manifest.json'),
  );
  expect(manifest.existsSync(), isTrue, reason: '缺少 MPV 兼容性 manifest');
  final decoded =
      jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
  final rows = decoded['builds'] as List<dynamic>?;
  expect(rows, isNotNull);
  final builds = <_MpvBuild>[];
  for (final raw in rows!) {
    final row = raw as Map<String, dynamic>;
    final id = row['id'] as String;
    final relativePath = row['relativePath'] as String;
    final executable = File(
      p.normalize(p.join(root, relativePath.replaceAll('/', p.separator))),
    );
    expect(
      executable.existsSync(),
      isTrue,
      reason: '$id 文件不存在：${executable.path}',
    );
    final versionHead = _mpvVersionHead(executable);
    final pattern = RegExp(row['versionPattern'] as String);
    expect(versionHead, matches(pattern), reason: '$id 版本漂移：$versionHead');
    builds.add(
      _MpvBuild(
        id: id,
        executable: executable,
        versionHead: versionHead,
        version: _parseMpvVersion(versionHead),
      ),
    );
  }
  return builds;
}

List<_MpvBuild> _fiveBuilds(String root) {
  final builds = _manifestBuilds(root);
  final configured = Platform.environment['STREAMPATH_PATH_MPV'];
  final pathMpv = configured != null && configured.trim().isNotEmpty
      ? configured.trim()
      : _findPathMpv();
  if (pathMpv != null && File(pathMpv).existsSync()) {
    final executable = File(pathMpv);
    final head = _mpvVersionHead(executable);
    builds.add(
      _MpvBuild(
        id: 'system-path-mpv',
        executable: executable,
        versionHead: head,
        version: _parseMpvVersion(head),
      ),
    );
  }
  final unique = <String, _MpvBuild>{};
  for (final build in builds) {
    unique[p.normalize(build.executable.absolute.path).toLowerCase()] = build;
  }
  return unique.values.toList(growable: false);
}

List<File> _fiveExecutables(String root) =>
    _fiveBuilds(root).map((build) => build.executable).toList(growable: false);

_MpvVersion _parseMpvVersion(String head) {
  final match = RegExp(r'^mpv v?(\d+)\.(\d+)\.(\d+)').firstMatch(head);
  if (match == null) throw FormatException('无法解析 MPV 版本：$head');
  return _MpvVersion(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  );
}

Future<void> _verifyEntityMatrix({
  required List<_MpvBuild> builds,
  required Directory workspace,
}) async {
  expect(builds, hasLength(5));
  final wave = File(p.join(workspace.path, 'four-seconds.wav'));
  await wave.writeAsBytes(_silentWave(seconds: 4), flush: true);
  final shortWave = File(p.join(workspace.path, 'one-second.wav'));
  await shortWave.writeAsBytes(_silentWave(seconds: 1), flush: true);
  final transportStream = File(p.join(workspace.path, 'sample.ts'));
  await _generateTransportStream(transportStream);
  final subtitle = File(p.join(workspace.path, 'sample.srt'));
  await subtitle.writeAsString(
    '1\r\n00:00:00,000 --> 00:00:03,000\r\nStreamPath subtitle\r\n',
    flush: true,
  );

  for (var index = 0; index < builds.length; index++) {
    final build = builds[index];
    final caseDir = Directory(p.join(workspace.path, 'entity_$index'))
      ..createSync();
    await _verifyTransportStream(
      build: build,
      media: transportStream,
      caseDir: Directory(p.join(caseDir.path, 'ts'))..createSync(),
    );
    await _verifySubtitleInjection(
      build: build,
      media: transportStream,
      subtitle: subtitle,
      caseDir: Directory(p.join(caseDir.path, 'subtitle'))..createSync(),
    );
    await _verifyWatchLater(
      build: build,
      media: wave,
      caseDir: Directory(p.join(caseDir.path, 'watch_later'))..createSync(),
    );
    await _verifyFileError(
      build: build,
      caseDir: Directory(p.join(caseDir.path, 'file_error'))..createSync(),
    );
    await _verifyIdleLifecycle(
      build: build,
      media: shortWave,
      caseDir: Directory(p.join(caseDir.path, 'idle'))..createSync(),
    );
  }
  await _verifyServiceIdleLifecycle(build: builds.last, workspace: workspace);
}

/// 以应用服务而非裸 IPC 验证 idle=yes 的自然完成生命周期。
/// 最后一项只有 250ms，短于服务 tracker 的健康探活周期，必须依靠
/// 持久化 idle 标记和退出同步收敛，不能只等 UI 轮询恰好命中。
Future<void> _verifyServiceIdleLifecycle({
  required _MpvBuild build,
  required Directory workspace,
}) async {
  final caseDir = Directory(p.join(workspace.path, 'service_idle'))
    ..createSync();
  final first = File(p.join(caseDir.path, 'service-first.wav'))
    ..writeAsBytesSync(_silentWave(seconds: 2), flush: true);
  final last = File(p.join(caseDir.path, 'service-last.wav'))
    ..writeAsBytesSync(_silentWaveWithMilliseconds(250), flush: true);
  final configStore = StreamPathConfigStore.forPath(
    p.join(caseDir.path, 'config.json'),
  );
  await configStore.save(
    StreamPathConfig.fromParts(
      PlayerConfig(
        name: 'mpv',
        executable: build.executable.path,
        args: const [
          '--no-config',
          '--terminal=no',
          '--vo=null',
          '--ao=null',
          '--idle=yes',
          '--keep-open=no',
          '{url}',
        ],
        subtitleInjectionEnabled: false,
        subtitleAutoSelectEnabled: false,
        resumeEnabled: false,
      ),
      const ConnectionConfig(baseUrl: 'http://127.0.0.1/dav'),
    ),
  );
  final service = ExternalPlayerService(
    configStore: configStore,
    watchLaterDir: Directory(p.join(caseDir.path, 'watch-later')),
  );
  final sessionId = 'service-idle-${build.id}';
  try {
    final launch = await service.launch(
      sessionId: sessionId,
      entries: [
        MediaEntry(url: first.path, title: '服务第一项'),
        MediaEntry(url: last.path, title: '服务短末项'),
      ],
    );
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (DateTime.now().isBefore(deadline) &&
        await service.isPlayerRunning(sessionId)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(
      await service.isPlayerRunning(sessionId),
      isFalse,
      reason: '${build.id} 服务级 idle 生命周期未收敛',
    );
    await service.waitForExitSync(sessionId);
    await _waitForPidExit(launch.process.pid, '${build.id} service idle');

    final statusLines = File(launch.statusFilePath!).readAsLinesSync();
    expect(statusLines.first.trim(), '-1');
    final records = File(launch.progressFilePath!)
        .readAsLinesSync()
        .where((line) => line.trim().isNotEmpty)
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .where((record) => record['outcome'] == 'completed')
        .toList();
    expect(records, isNotEmpty, reason: '${build.id} 服务级 idle 未写完成日志');
    expect(records.last['playlist_pos'], 1);
    expect(records.last['epoch'], launch.launchEpoch);
    // ignore: avoid_print
    print(
      'MPV_MATRIX service-idle id=${build.id} '
      'lastPlaylistPos=${records.last['playlist_pos']} pidExited=true',
    );
  } finally {
    await service.terminateSession(sessionId);
  }
}

Future<void> _generateTransportStream(File output) async {
  final result = Process.runSync('where.exe', ['ffmpeg.exe']);
  expect(result.exitCode, 0, reason: '真实 TS 验收需要 ffmpeg.exe');
  final executable = result.stdout
      .toString()
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .firstWhere((line) => line.isNotEmpty);
  final generated = await Process.run(executable, [
    '-hide_banner',
    '-loglevel',
    'error',
    '-y',
    '-f',
    'lavfi',
    '-i',
    'testsrc=size=64x64:rate=10:duration=1',
    '-f',
    'lavfi',
    '-i',
    'sine=frequency=440:sample_rate=44100:duration=1',
    '-c:v',
    'mpeg2video',
    '-pix_fmt',
    'yuv420p',
    '-c:a',
    'mp2',
    '-shortest',
    '-f',
    'mpegts',
    output.path,
  ]);
  expect(generated.exitCode, 0, reason: 'ffmpeg 生成 TS 失败：${generated.stderr}');
  expect(output.lengthSync(), greaterThan(0));
}

Future<void> _verifyTransportStream({
  required _MpvBuild build,
  required File media,
  required Directory caseDir,
}) async {
  final epoch = 'ts-${build.id}';
  final status = p.join(caseDir.path, 'status.txt');
  final command = p.join(caseDir.path, 'command.txt');
  final progress = p.join(caseDir.path, 'progress.jsonl');
  final script = await MpvScripts.ensureCurrent(
    status,
    command,
    caseDir,
    sessionId: epoch,
    progressFile: progress,
    launchEpoch: epoch,
  );
  final pipe = _uniquePipe(build.id, 'ts');
  final process = await Process.start(build.executable.path, [
    '--no-config',
    '--terminal=no',
    '--vo=null',
    '--ao=null',
    '--pause=yes',
    '--idle=no',
    '--keep-open=no',
    '--rebase-start-time=yes',
    '--input-ipc-server=$pipe',
    '--script=$script',
    media.path,
  ]);
  process.stdout.drain<void>();
  final stderrFuture = process.stderr.transform(utf8.decoder).join();
  final exitFuture = _trackOwnedMpv(process);
  final controller = MpvSessionController(pipeName: pipe);
  var exitCode = -1;
  try {
    expect(
      await controller.connect(timeout: const Duration(seconds: 10)),
      isTrue,
      reason: '${build.id} TS named pipe 未建立',
    );
    final duration = await _waitForProperty(
      controller,
      'duration',
      (value) => value is num && value > 0,
    );
    expect(duration, isA<num>(), reason: build.id);
    expect(
      (await controller.getProperty('path')).toString().toLowerCase(),
      endsWith('.ts'),
      reason: build.id,
    );
    await controller.setProperty('pause', false);
    exitCode = await _awaitOwnedExit(process, exitFuture, '${build.id} TS');
  } finally {
    await controller.dispose();
    await _cleanupOwnedProcess(process, exitFuture);
  }
  final stderr = await stderrFuture;
  expect(exitCode, 0, reason: '${build.id} TS 播放失败：$stderr');
  final records = await File(progress).readAsLines();
  final completed = records
      .map((line) => jsonDecode(line) as Map<String, dynamic>)
      .where((record) => record['outcome'] == 'completed')
      .toList();
  expect(completed, hasLength(1), reason: '${build.id} TS 未记录完整 EOF');
  expect(completed.single['epoch'], epoch);
  // ignore: avoid_print
  print('MPV_MATRIX ts id=${build.id} result=eof rebase=yes');
}

Future<void> _verifySubtitleInjection({
  required _MpvBuild build,
  required File media,
  required File subtitle,
  required Directory caseDir,
}) async {
  final script = await MpvScripts.ensureSingleSubtitle(
    SubtitleItem(
      name: p.basename(subtitle.path),
      url: subtitle.path,
      language: SubtitleLanguage.exact,
    ),
    (value) => value,
    caseDir,
    autoSelect: true,
    sessionId: 'subtitle-${build.id}',
  );
  final pipe = _uniquePipe(build.id, 'subtitle');
  final process = await Process.start(build.executable.path, [
    '--no-config',
    '--terminal=no',
    '--vo=null',
    '--ao=null',
    '--pause=yes',
    '--idle=yes',
    '--keep-open=no',
    '--sub-auto=no',
    '--input-ipc-server=$pipe',
    '--script=$script',
    media.path,
  ]);
  process.stdout.drain<void>();
  final stderrFuture = process.stderr.transform(utf8.decoder).join();
  final exitFuture = _trackOwnedMpv(process);
  final controller = MpvSessionController(pipeName: pipe);
  try {
    expect(
      await controller.connect(timeout: const Duration(seconds: 10)),
      isTrue,
      reason: '${build.id} 字幕 named pipe 未建立',
    );
    final trackList = await _waitForProperty(
      controller,
      'track-list',
      (value) =>
          value is List &&
          value.any((track) => track is Map && track['type'] == 'sub'),
    );
    expect(
      (trackList as List).any(
        (track) => track is Map && track['type'] == 'sub',
      ),
      isTrue,
      reason: '${build.id} 未通过 Lua sub-add 注入外挂字幕',
    );
    await controller.command(['quit']);
    expect(
      await _awaitOwnedExit(process, exitFuture, '${build.id} 字幕'),
      0,
      reason: '${build.id} 字幕场景失败：${await stderrFuture}',
    );
    // ignore: avoid_print
    print('MPV_MATRIX subtitle id=${build.id} result=sub-add-track');
  } finally {
    await controller.dispose();
    await _cleanupOwnedProcess(process, exitFuture);
  }
}

Future<void> _verifyWatchLater({
  required _MpvBuild build,
  required File media,
  required Directory caseDir,
}) async {
  final recordsDir = Directory(p.join(caseDir.path, 'records'))..createSync();
  final pipe = _uniquePipe(build.id, 'watch-later');
  final process = await Process.start(build.executable.path, [
    '--no-config',
    '--terminal=no',
    '--vo=null',
    '--ao=null',
    '--pause=yes',
    '--idle=yes',
    '--keep-open=no',
    '--no-resume-playback',
    '--save-position-on-quit',
    '--watch-later-directory=${recordsDir.path}',
    '--input-ipc-server=$pipe',
    media.path,
  ]);
  process.stdout.drain<void>();
  final stderrFuture = process.stderr.transform(utf8.decoder).join();
  final exitFuture = _trackOwnedMpv(process);
  final controller = MpvSessionController(pipeName: pipe);
  try {
    expect(
      await controller.connect(timeout: const Duration(seconds: 10)),
      isTrue,
      reason: '${build.id} watch_later named pipe 未建立',
    );
    await _waitForProperty(
      controller,
      'duration',
      (value) => value is num && value >= 3,
    );
    await controller.setProperty('time-pos', 1.25);
    await _waitForProperty(
      controller,
      'time-pos',
      (value) => value is num && value >= 1,
    );
    await controller.command(['quit-watch-later']);
    expect(
      await _awaitOwnedExit(process, exitFuture, '${build.id} watch_later'),
      0,
      reason: '${build.id} watch_later 退出失败：${await stderrFuture}',
    );
  } finally {
    await controller.dispose();
    await _cleanupOwnedProcess(process, exitFuture);
  }
  final index = await const MpvWatchLaterSync().buildIndex(recordsDir, [
    media.path,
  ]);
  final record = index.recordFor(media.path);
  expect(record, isNotNull, reason: '${build.id} 未写出 watch_later 记录');
  expect(record!.startSeconds, greaterThanOrEqualTo(1));
  // ignore: avoid_print
  print(
    'MPV_MATRIX watch_later id=${build.id} '
    'start=${record.startSeconds} duration=${record.durationSeconds}',
  );
}

Future<void> _verifyFileError({
  required _MpvBuild build,
  required Directory caseDir,
}) async {
  final epoch = 'file-error-${build.id}';
  final progress = p.join(caseDir.path, 'progress.jsonl');
  final script = await MpvScripts.ensureCurrent(
    p.join(caseDir.path, 'status.txt'),
    p.join(caseDir.path, 'command.txt'),
    caseDir,
    sessionId: epoch,
    progressFile: progress,
    launchEpoch: epoch,
  );
  final pipe = _uniquePipe(build.id, 'file-error');
  final missing = p.join(caseDir.path, 'definitely-missing-media.mkv');
  final process = await Process.start(build.executable.path, [
    '--no-config',
    '--terminal=no',
    '--vo=null',
    '--ao=null',
    '--idle=yes',
    '--keep-open=no',
    '--input-ipc-server=$pipe',
    '--script=$script',
    missing,
  ]);
  process.stdout.drain<void>();
  final stderrFuture = process.stderr.transform(utf8.decoder).join();
  final exitFuture = _trackOwnedMpv(process);
  final controller = MpvSessionController(pipeName: pipe);
  final progressFile = File(progress);
  late final Map<String, dynamic> failure;
  try {
    expect(
      await controller.connect(timeout: const Duration(seconds: 10)),
      isTrue,
      reason: '${build.id} file_error named pipe 未建立',
    );
    await _waitUntil(() {
      if (!progressFile.existsSync()) return false;
      try {
        return progressFile.readAsStringSync().endsWith('\n');
      } on FileSystemException {
        return false;
      }
    });
    final records = (await progressFile.readAsLines())
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .where((record) => record['reason'] == 'error')
        .toList();
    expect(
      records,
      isNotEmpty,
      reason: '${build.id} 未记录 end-file reason=error',
    );
    failure = records.last;
    expect(failure['epoch'], epoch);
    expect(failure['file_error'], isA<String>());
    expect((failure['file_error'] as String).trim(), isNotEmpty);

    // 错误上报与加载失败后的自然退出是两个独立兼容性契约。
    await controller.command(['quit']);
    final exitCode = await _awaitOwnedExit(
      process,
      exitFuture,
      '${build.id} file_error',
    );
    expect(
      exitCode,
      0,
      reason: '${build.id} file_error 显式退出失败：${await stderrFuture}',
    );
  } finally {
    await controller.dispose();
    await _cleanupOwnedProcess(process, exitFuture);
  }
  // ignore: avoid_print
  print(
    'MPV_MATRIX file_error id=${build.id} reason=${failure['reason']} '
    'file_error=${failure['file_error']}',
  );
}

Future<void> _verifyIdleLifecycle({
  required _MpvBuild build,
  required File media,
  required Directory caseDir,
}) async {
  final epoch = 'idle-${build.id}';
  final status = p.join(caseDir.path, 'status.txt');
  final script = await MpvScripts.ensureCurrent(
    status,
    p.join(caseDir.path, 'command.txt'),
    caseDir,
    sessionId: epoch,
    progressFile: p.join(caseDir.path, 'progress.jsonl'),
    launchEpoch: epoch,
  );
  final pipe = _uniquePipe(build.id, 'idle');
  final process = await Process.start(build.executable.path, [
    '--no-config',
    '--terminal=no',
    '--vo=null',
    '--ao=null',
    '--idle=yes',
    '--keep-open=no',
    '--input-ipc-server=$pipe',
    '--script=$script',
    media.path,
  ]);
  process.stdout.drain<void>();
  final stderrFuture = process.stderr.transform(utf8.decoder).join();
  final exitFuture = _trackOwnedMpv(process);
  final controller = MpvSessionController(pipeName: pipe);
  try {
    expect(
      await controller.connect(timeout: const Duration(seconds: 10)),
      isTrue,
      reason: '${build.id} idle named pipe 未建立',
    );
    await _waitUntil(() => _statusIsIdle(status));
    expect(
      await _hasExited(exitFuture, wait: const Duration(milliseconds: 300)),
      isFalse,
      reason: '${build.id} idle=yes 应保持测试进程存活',
    );
    _expectYes(await controller.getProperty('idle-active'), build.id);
    await controller.command(['quit']);
    expect(
      await _awaitOwnedExit(process, exitFuture, '${build.id} idle'),
      0,
      reason: '${build.id} idle 精确退出失败：${await stderrFuture}',
    );
    // ignore: avoid_print
    print('MPV_MATRIX idle id=${build.id} observed=true exactQuit=true');
  } finally {
    await controller.dispose();
    await _cleanupOwnedProcess(process, exitFuture);
  }
}

Future<Object?> _waitForProperty(
  MpvSessionController controller,
  String name,
  bool Function(Object? value) predicate,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  Object? last;
  Object? lastError;
  while (DateTime.now().isBefore(deadline)) {
    try {
      last = await controller.getProperty(name);
      if (predicate(last)) return last;
    } catch (error) {
      lastError = error;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw TimeoutException('等待 MPV 属性 $name 超时；last=$last；error=$lastError');
}

String _uniquePipe(String buildId, String scenario) {
  final token = '$buildId-$scenario'.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '-');
  return '${r'\\.\pipe\streampath-entity-'}$token-$pid-'
      '${DateTime.now().microsecondsSinceEpoch}';
}

void _expectYes(Object? value, String buildId) {
  expect(
    value == true || value == 'yes',
    isTrue,
    reason: '$buildId 属性值不是 yes/true：$value',
  );
}

Future<int> _awaitOwnedExit(
  Process process,
  Future<int> exitFuture,
  String label,
) async {
  try {
    return await exitFuture.timeout(const Duration(seconds: 20));
  } on TimeoutException {
    process.kill();
    await exitFuture.timeout(const Duration(seconds: 5), onTimeout: () => -1);
    throw TimeoutException('$label 测试进程未在 20 秒内退出');
  }
}

Future<int> _trackOwnedMpv(Process process) {
  final exitCode = process.exitCode;
  _ownedMpvProcesses.add((pid: process.pid, exitCode: exitCode));
  return exitCode;
}

Future<void> _assertNoOwnedMpvProcesses() async {
  for (final owned in _ownedMpvProcesses) {
    expect(
      await _hasExited(owned.exitCode),
      isTrue,
      reason: '测试自行启动的 MPV PID ${owned.pid} 仍未退出',
    );
  }
}

Future<void> _cleanupOwnedProcess(
  Process process,
  Future<int> exitFuture,
) async {
  if (await _hasExited(exitFuture)) return;
  process.kill();
  await exitFuture.timeout(const Duration(seconds: 5), onTimeout: () => -1);
}

Future<bool> _hasExited(
  Future<int> exitFuture, {
  Duration wait = const Duration(milliseconds: 50),
}) => Future.any<bool>([
  exitFuture.then((_) => true),
  Future<void>.delayed(wait).then((_) => false),
]);

bool _statusIsIdle(String path) {
  try {
    final file = File(path);
    if (!file.existsSync()) return false;
    final lines = file.readAsLinesSync();
    return lines.isNotEmpty && lines.first.trim() == '-1';
  } on FileSystemException {
    return false;
  }
}

String? _findPathMpv() {
  final result = Process.runSync('where.exe', ['mpv.exe']);
  if (result.exitCode != 0) return null;
  return result.stdout
      .toString()
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .firstOrNull;
}

String _mpvVersionHead(File executable) {
  var probe = executable;
  var result = Process.runSync(probe.path, ['--version']);
  var output = '${result.stdout}${result.stderr}';
  if (output.trim().isEmpty) {
    final sibling = File(p.join(executable.parent.path, 'mpv.com'));
    if (sibling.existsSync()) {
      probe = sibling;
      result = Process.runSync(probe.path, ['--version']);
      output = '${result.stdout}${result.stderr}';
    }
  }
  expect(result.exitCode, 0, reason: '${probe.path} 无法输出版本信息');
  expect(output.trim(), isNotEmpty, reason: '${probe.path} 版本输出为空');
  return output
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .firstWhere((line) => line.isNotEmpty);
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw TimeoutException('等待 MPV 状态文件超时');
}

Future<void> _waitForPidExit(int pid, String label) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    final result = await Process.run('tasklist', [
      '/FI',
      'PID eq $pid',
      '/NH',
      '/FO',
      'CSV',
    ]);
    final found = result.stdout.toString().split(RegExp(r'\r?\n')).any((line) {
      final columns = line.split(',');
      return columns.length > 1 &&
          columns[1].replaceAll('"', '').trim() == '$pid';
    });
    if (!found) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('$label：PID $pid 未退出');
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

Uint8List _silentWaveWithMilliseconds(int milliseconds) {
  const sampleRate = 8000;
  const channels = 1;
  const bitsPerSample = 16;
  final dataLength =
      sampleRate * milliseconds ~/ 1000 * channels * (bitsPerSample ~/ 8);
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
