@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/core/utils/url_utils.dart';
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/data/models/external_audio_track.dart';
import 'package:streampath/data/models/media_entry.dart';
import 'package:streampath/domain/services/mpv_scripts.dart';
import 'package:streampath/domain/services/mpv_session_controller.dart';

void main() {
  final root = Platform.environment['STREAMPATH_MPV_TEST_ROOT'];
  final enabled = root != null && root.isNotEmpty;
  final builds = enabled
      ? (jsonDecode(
                  File(
                    'test/mpv_compatibility_manifest.json',
                  ).readAsStringSync(),
                )['builds']
                as List)
            .map(
              (build) => (
                id: build['id'] as String,
                path: p.join(root, build['relativePath'] as String),
              ),
            )
            .toList()
      : <({String id, String path})>[];
  final userMpv = Platform.environment['STREAMPATH_PATH_MPV'];
  if (enabled && userMpv != null) {
    builds.add((id: 'user-mpv', path: userMpv));
  }

  test(
    '实体 MPV 大音轨按需读取、选择、Seek、切集和换季',
    () async {
      final fixture = await _Fixture.create();
      try {
        for (final build in builds) {
          fixture.resetRequests();
          final first = fixture.entry('01', ['slow.wav', 'extra.wav']);
          final second = fixture.entry('02', ['next.wav']);
          final player = await fixture.start(
            build.path,
            [first, second],
            startSeconds: 6,
            nextSeason: [
              fixture.entry('01', ['initial-next.wav']),
              fixture.entry('02', []),
            ],
          );
          try {
            await _until(
              () async => fixture.requests.any((r) => r.path == '/slow.wav'),
            );
            final started = (await player.ipc.getProperty('time-pos') as num)
                .toDouble();
            await Future<void>.delayed(const Duration(milliseconds: 400));
            expect(
              (await player.ipc.getProperty('time-pos') as num).toDouble(),
              greaterThan(started + 0.15),
              reason: build.id,
            );
            expect(await player.ipc.getProperty('aid'), 1);
            expect(fixture.requests.any((r) => r.path == '/next.wav'), isFalse);
            expect(
              fixture.requests.any((r) => r.path == '/initial-next.wav'),
              isFalse,
            );
            await _until(
              () async =>
                  (await player.tracks())
                      .where((t) => t['external'] == true)
                      .length ==
                  2,
            );
            expect(await player.ipc.getProperty('aid'), 1, reason: build.id);
            final track = (await player.tracks()).singleWhere(
              (t) => t['title'] == 'slow.wav',
            );
            final bytes = fixture.audioBytes;
            expect(bytes, lessThan(_Fixture.audioLength ~/ 10));
            final videoRequest = fixture.requests.firstWhere(
              (r) => r.path == '/01.mkv',
            );
            final audioRequest = fixture.requests.firstWhere(
              (r) => r.path == '/slow.wav',
            );
            expect(audioRequest.elapsedMs, greaterThan(videoRequest.elapsedMs));
            await player.ipc.setProperty('aid', track['id'] as num);
            await player.ipc.command(['seek', 12, 'absolute+exact']);
            await _until(
              () async =>
                  (await player.ipc.getProperty('time-pos') as num) >= 11,
            );
            await _until(
              () async => fixture.requests.any(
                (r) =>
                    r.path == '/slow.wav' &&
                    r.range != null &&
                    !r.range!.startsWith('bytes=0-'),
              ),
            );
            expect(
              (await player.tracks()).where((t) => t['external'] == true),
              hasLength(2),
            );
            expect(
              fixture.requests.any(
                (r) =>
                    r.path == '/slow.wav' &&
                    r.range != null &&
                    !r.range!.startsWith('bytes=0-'),
              ),
              isTrue,
            );
            await player.ipc.command(['playlist-next', 'force']);
            await _until(
              () async => fixture.requests.any((r) => r.path == '/next.wav'),
            );
            await _until(
              () async =>
                  (await player.tracks()).any((t) => t['title'] == 'next.wav'),
            );
            expect(
              (await player.tracks()).any((t) => t['title'] == 'slow.wav'),
              isFalse,
            );

            final nextSeason = fixture.entry('S02E01', ['season.wav']);
            final playlist = await MpvScripts.ensurePlaylistM3u(
              [nextSeason],
              fixture.auth,
              fixture.dir,
              sessionId: 'next_${build.id}',
            );
            final script = await MpvScripts.ensureExternalAudioTracks(
              [nextSeason],
              fixture.auth,
              fixture.dir,
              playlistPath: playlist,
              deferUntilPlaylistChange: true,
              initialPlaylistIds: [
                for (final item
                    in await player.ipc.getProperty('playlist') as List)
                  (item as Map)['id'] as int,
              ],
              language: AppLanguage.english,
              sessionId: 'next_${build.id}',
            );
            await player.ipc.command(['load-script', script]);
            expect(
              fixture.requests.any((r) => r.path == '/season.wav'),
              isFalse,
            );
            await player.ipc.command(['loadlist', playlist, 'replace']);
            await _until(
              () async => (await player.tracks()).any(
                (t) => t['title'] == 'season.wav',
              ),
            );
            expect(
              (await player.tracks()).where((t) => t['external'] == true),
              hasLength(1),
            );
            expect(
              fixture.requests.where((r) => r.path == '/season.wav'),
              isNotEmpty,
            );
            expect(
              fixture.requests.any((r) => r.path == '/initial-next.wav'),
              isFalse,
            );
            expect(
              fixture.requests
                  .where((r) => r.auth != null)
                  .every((r) => r.auth == fixture.authorization),
              isTrue,
            );
            // ignore: avoid_print
            print(
              'EXTERNAL_AUDIO_STREAM id=${build.id} bytesAtLoad=$bytes total=${_Fixture.audioLength} videoRequestMs=${videoRequest.elapsedMs} audioRequestMs=${audioRequest.elapsedMs} playbackAdvanced=true seekRange=true season=true',
            );
          } finally {
            await player.close();
          }
        }
      } finally {
        await fixture.close();
      }
    },
    skip: enabled
        ? false
        : 'Set STREAMPATH_MPV_TEST_ROOT for real MPV audio tests',
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    '实体 MPV 音轨失败、超时、快速切集及关闭取消',
    () async {
      final fixture = await _Fixture.create();
      try {
        for (final build in builds) {
          fixture.resetRequests();
          final player = await fixture.start(build.path, [
            fixture.entry('01', [
              'redirect.wav',
              'unauthorized.wav',
              'missing.wav',
              'timeout.wav',
              'no-range.wav',
            ]),
            fixture.entry('02', []),
          ]);
          try {
            await _until(
              () async => fixture.requests.any((r) => r.path == '/timeout.wav'),
            );
            await player.ipc.setProperty('pause', true);
            await player.ipc.setProperty('aid', 'no');
            await _until(
              () async => (await player.tracks()).any(
                (t) => t['title'] == 'no-range.wav',
              ),
              timeout: const Duration(seconds: 16),
            );
            expect(await player.ipc.getProperty('aid'), anyOf('no', false));
            expect(fixture.redirectAuth, isNotEmpty);
            expect(fixture.redirectAuth.every((auth) => auth == null), isTrue);
            expect(
              (await player.ipc.getProperty('time-pos') as num),
              greaterThan(0),
            );
            expect(
              (await player.tracks()).any((t) => t['title'] == 'timeout.wav'),
              isFalse,
            );
            final before = (await player.ipc.getProperty('time-pos') as num)
                .toDouble();
            await player.ipc.setProperty('aid', 1);
            await player.ipc.setProperty('pause', false);
            final slowEntry = fixture.entry('01', ['timeout.wav', 'never.wav']);
            final list = await MpvScripts.ensurePlaylistM3u(
              [slowEntry, fixture.entry('02', [])],
              fixture.auth,
              fixture.dir,
              sessionId: 'cancel_${build.id}',
            );
            final script = await MpvScripts.ensureExternalAudioTracks(
              [slowEntry, fixture.entry('02', [])],
              fixture.auth,
              fixture.dir,
              playlistPath: list,
              deferUntilPlaylistChange: true,
              initialPlaylistIds: [
                for (final item
                    in await player.ipc.getProperty('playlist') as List)
                  (item as Map)['id'] as int,
              ],
              language: AppLanguage.english,
              sessionId: 'cancel_${build.id}',
            );
            await player.ipc.command(['load-script', script]);
            final requestsBefore = fixture.requests
                .where((r) => r.path == '/timeout.wav')
                .length;
            await player.ipc.command(['loadlist', list, 'replace']);
            await _until(
              () async =>
                  fixture.requests
                      .where((r) => r.path == '/timeout.wav')
                      .length >
                  requestsBefore,
            );
            await player.ipc.command(['playlist-next', 'force']);
            await _until(
              () async => await player.ipc.getProperty('playlist-pos') == 1,
            );
            await Future<void>.delayed(const Duration(milliseconds: 600));
            expect(
              (await player.tracks()).any((t) => t['external'] == true),
              isFalse,
            );
            expect(
              fixture.requests.any((r) => r.path == '/never.wav'),
              isFalse,
            );
            await player.ipc.command(['playlist-prev', 'force']);
            await _until(
              () async =>
                  fixture.requests
                      .where((r) => r.path == '/timeout.wav')
                      .length >
                  requestsBefore + 1,
            );
            final closing = Stopwatch()..start();
            await player.close();
            expect(closing.elapsed, lessThan(const Duration(seconds: 4)));
            expect(
              fixture.requests.any((r) => r.path == '/never.wav'),
              isFalse,
            );
            // ignore: avoid_print
            print(
              'EXTERNAL_AUDIO_FAILURE id=${build.id} timeAfterTimeout=$before unauthorized=true missing=true noRange=true cancel=true',
            );
          } catch (_) {
            // ignore: avoid_print
            print(
              'EXTERNAL_AUDIO_DIAGNOSTIC log=${player.output} requests=${fixture.requests.map((r) => r.path).toList()}',
            );
            rethrow;
          } finally {
            await player.close();
          }
        }
      } finally {
        await fixture.close();
      }
    },
    skip: enabled
        ? false
        : 'Set STREAMPATH_MPV_TEST_ROOT for real MPV audio tests',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<void> _until(
  Future<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final source = StackTrace.current;
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('MPV audio condition timed out: $source');
}

class _Player {
  _Player(this.process, this.ipc);
  final Process process;
  final MpvSessionController ipc;
  bool closed = false;
  final output = StringBuffer();
  Future<List<Map>> tracks() async =>
      (await ipc.getProperty('track-list') as List)
          .whereType<Map>()
          .where((t) => t['type'] == 'audio')
          .toList();
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await ipc.command(['quit']);
    await process.exitCode.timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    await ipc.dispose();
  }
}

class _Fixture {
  _Fixture(this.dir, this.server, this.destination, this.video);
  final Directory dir;
  final HttpServer server;
  final HttpServer destination;
  final redirectAuth = <String?>[];
  final Uint8List video;
  static const audioLength = 512 * 1024 * 1024 + 44;
  final requests =
      <({String path, String? range, String? auth, int elapsedMs})>[];
  final requestClock = Stopwatch();
  int audioBytes = 0;
  int requestGeneration = 0;
  bool stopped = false;
  String get origin => 'http://127.0.0.1:${server.port}';
  String get authorization => 'Basic ${base64Encode(utf8.encode('viewer:'))}';
  String auth(String url) => embedCredentials(url, 'viewer', '');
  void resetRequests() {
    requestGeneration++;
    requests.clear();
    audioBytes = 0;
    redirectAuth.clear();
    requestClock.reset();
    requestClock.start();
  }

  MediaEntry entry(String name, List<String> tracks) => MediaEntry(
    url: '$origin/$name.mkv',
    externalAudioTracks: [
      for (final track in tracks)
        ExternalAudioTrack(name: track, url: '$origin/$track'),
    ],
  );

  static Future<_Fixture> create() async {
    final dir = await Directory.systemTemp.createTemp('sp_external_audio_');
    final path = p.join(dir.path, 'video.mkv');
    final generated = await Process.run('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-f',
      'lavfi',
      '-i',
      'color=c=black:s=64x36:r=5',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:sample_rate=44100',
      '-t',
      '30',
      '-c:v',
      'libx264',
      '-c:a',
      'pcm_s16le',
      path,
    ]);
    if (generated.exitCode != 0) {
      throw StateError(
        'Audio test video generation failed: ${generated.stderr}',
      );
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final destination = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _Fixture(
      dir,
      server,
      destination,
      await File(path).readAsBytes(),
    );
    server.listen(fixture.serve);
    destination.listen((request) {
      fixture.redirectAuth.add(request.headers.value('authorization'));
      fixture.serve(request, requireAuthorization: false);
    });
    return fixture;
  }

  Future<_Player> start(
    String executable,
    List<MediaEntry> entries, {
    int startSeconds = 0,
    List<MediaEntry>? nextSeason,
  }) async {
    final id = '${DateTime.now().microsecondsSinceEpoch}';
    final playlist = await MpvScripts.ensurePlaylistM3u(
      entries,
      auth,
      dir,
      sessionId: id,
    );
    String? nextScript;
    if (nextSeason != null) {
      final nextPlaylist = await MpvScripts.ensurePlaylistM3u(
        nextSeason,
        auth,
        dir,
        sessionId: '${id}_next',
      );
      nextScript = await MpvScripts.ensureExternalAudioTracks(
        nextSeason,
        auth,
        dir,
        playlistPath: nextPlaylist,
        deferUntilPlaylistChange: true,
        language: AppLanguage.english,
        sessionId: '${id}_next',
      );
    }
    final script = await MpvScripts.ensureExternalAudioTracks(
      entries,
      auth,
      dir,
      playlistPath: playlist,
      language: AppLanguage.english,
      sessionId: id,
    );
    final pipe = '${r'\\.\pipe\sp_external_audio_'}$id';
    final process = await Process.start(executable, [
      '--no-config',
      '--terminal=yes',
      '--msg-level=all=warn',
      '--vo=null',
      '--ao=null',
      '--idle=yes',
      '--keep-open=no',
      '--cache=yes',
      '--demuxer-max-bytes=131072',
      '--cache-secs=1',
      '--start=$startSeconds',
      '--script=$script',
      if (nextScript != null) '--script=$nextScript',
      '--input-ipc-server=$pipe',
      '--playlist=$playlist',
    ]);
    final ipc = MpvSessionController(pipeName: pipe);
    final player = _Player(process, ipc);
    process.stdout.transform(utf8.decoder).listen(player.output.write);
    process.stderr.transform(utf8.decoder).listen(player.output.write);
    if (!await ipc.connect()) {
      process.kill();
      throw StateError('MPV audio IPC unavailable');
    }
    return player;
  }

  Future<void> serve(
    HttpRequest request, {
    bool requireAuthorization = true,
  }) async {
    final epoch = requestGeneration;
    final path = request.uri.path;
    final range = request.headers.value('range');
    requests.add((
      path: path,
      range: range,
      auth: request.headers.value('authorization'),
      elapsedMs: requestClock.elapsedMilliseconds,
    ));
    if (path == '/unauthorized.wav' ||
        (requireAuthorization &&
            request.headers.value('authorization') != authorization)) {
      request.response.statusCode = 401;
      request.response.headers.set(
        'www-authenticate',
        'Basic realm="StreamPath audio test"',
      );
      await request.response.close();
      return;
    }
    if (path == '/redirect.wav') {
      request.response.statusCode = 302;
      request.response.headers.set(
        'location',
        'http://127.0.0.1:${destination.port}/redirected.wav',
      );
      await request.response.close();
      return;
    }
    if (path == '/missing.wav') {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    if (path == '/timeout.wav') {
      await Future<void>.delayed(const Duration(seconds: 13));
    }
    if (path == '/slow.wav') {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }
    if (stopped || epoch != requestGeneration) return;
    final isVideo = path.endsWith('.mkv');
    final noRange = path == '/no-range.wav';
    final length = isVideo
        ? video.length
        : noRange
        ? 44100 * 2 * 30 + 44
        : audioLength;
    var offset = 0;
    var end = length - 1;
    final matched = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range ?? '');
    if (matched != null && !noRange) {
      offset = int.parse(matched[1]!);
      end = matched[2]!.isEmpty ? end : math.min(end, int.parse(matched[2]!));
      request.response.statusCode = 206;
      request.response.headers.set(
        'content-range',
        'bytes $offset-$end/$length',
      );
    }
    request.response.contentLength = end - offset + 1;
    request.response.headers.set(
      'content-type',
      isVideo ? 'video/x-matroska' : 'audio/wav',
    );
    if (!noRange) request.response.headers.set('accept-ranges', 'bytes');
    final header = Uint8List(44);
    header.setRange(0, 4, ascii.encode('RIFF'));
    header.setRange(8, 16, ascii.encode('WAVEfmt '));
    header.setRange(36, 40, ascii.encode('data'));
    final data = ByteData.sublistView(header);
    data.setUint32(4, length - 8, Endian.little);
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, 44100, Endian.little);
    data.setUint32(28, 88200, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    data.setUint32(40, length - 44, Endian.little);
    try {
      while (!stopped && epoch == requestGeneration && offset <= end) {
        final size = math.min(16384, end - offset + 1);
        final chunk = isVideo
            ? video.sublist(offset, offset + size)
            : Uint8List(size);
        if (!isVideo && offset < 44) {
          chunk.setRange(
            0,
            math.min(size, 44 - offset),
            header.sublist(offset, math.min(44, offset + size)),
          );
        }
        request.response.add(chunk);
        await request.response.flush();
        if (!isVideo && epoch == requestGeneration) audioBytes += size;
        offset += size;
        if (!isVideo) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }
      await request.response.close();
    } on HttpException {
      // MPV 取消请求或跳转到新的 Range。
    } on SocketException {
      // MPV 关闭后停止发送。
    }
  }

  Future<void> close() async {
    stopped = true;
    await server.close(force: true);
    await destination.close(force: true);
    await dir.delete(recursive: true);
  }
}
