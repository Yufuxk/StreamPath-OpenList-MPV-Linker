import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/connection_config.dart';
import 'package:streampath/data/models/media_entry.dart';
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/domain/services/external_player_service.dart';
import 'package:streampath/domain/services/playback_startup_trace.dart';
import 'package:streampath/features/cache_control/cache_policy_service.dart';
import 'package:streampath/features/cache_control/store/cache_policy_config_store.dart';
import 'package:streampath/features/cache_control/models/cache_policy_config.dart';

void main() {
  final mpv = Platform.environment['STREAMPATH_TS_MPV'];
  final media = Platform.environment['STREAMPATH_TS_MEDIA'];
  final output = Platform.environment['STREAMPATH_TS_OUTPUT'];
  test(
    '真实 M2TS 经过生产启动服务，诊断默认不改变缓存参数',
    () async {
      final base = await Directory.systemTemp.createTemp('ts_real_launch_');
      final out = Directory(output!);
      await out.create(recursive: true);
      final config = StreamPathConfigStore.forPath('${base.path}/config.json');
      await config.save(
        StreamPathConfig.fromParts(
          PlayerConfig(
            name: 'mpv',
            executable: mpv!,
            args: const [
              '--no-config',
              '--load-scripts=no',
              '--vo=null',
              '--ao=null',
              '--hwdec=no',
              '--length=8',
              '{url}',
            ],
            subtitleInjectionEnabled: false,
            resumeEnabled: false,
          ),
          const ConnectionConfig(baseUrl: ''),
        ),
      );
      final remote = Platform.environment['STREAMPATH_TS_HTTP'] == '1';
      final logs = <String>[];
      final store = CachePolicyConfigStore.forPath('${base.path}/cache.json');
      await store.save(CachePolicyConfig.defaults());
      HttpServer? server;
      if (remote) {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          final file = File(media!);
          final size = await file.length();
          final match = RegExp(
            r'bytes=(\d+)-(\d*)',
          ).firstMatch(request.headers.value('range') ?? '');
          final start = match == null ? 0 : int.parse(match[1]!);
          final end = match == null || match[2]!.isEmpty
              ? size - 1
              : int.parse(match[2]!);
          request.response.statusCode = match == null ? 200 : 206;
          request.response.contentLength = end - start + 1;
          request.response.headers.set('accept-ranges', 'bytes');
          if (match != null) {
            request.response.headers.set(
              'content-range',
              'bytes $start-$end/$size',
            );
          }
          try {
            if (request.method != 'HEAD') {
              await request.response.addStream(file.openRead(start, end + 1));
            }
            await request.response.close();
          } on HttpException {
            // MPV 停止预读时会取消当前响应。
          } on SocketException {
            // 播放退出会关闭连接。
          }
        });
      }
      final service = ExternalPlayerService(
        configStore: config,
        watchLaterDir: base,
        cacheLogger: logs.add,
        cachePolicy: remote
            ? CachePolicyService(store: store, logger: logs.add)
            : null,
      );
      try {
        for (var i = 0; i < 3; i++) {
          late PlaybackStartupTrace trace;
          final result = await PlaybackStartupTrace.run(() async {
            trace = PlaybackStartupTrace.current!;
            trace.mark('playbackPreparationStart', {'scope': 'service-only'});
            if (server != null) {
              return service.launch(
                entries: [
                  MediaEntry(url: 'http://127.0.0.1:${server.port}/movie.m2ts'),
                ],
                sessionId: 'ts-diagnostic-$i',
              );
            }
            return service.launchLocal(
              entries: [MediaEntry(url: media!)],
              sourceId: 'local:ts-diagnostics',
              sessionId: 'ts-diagnostic-$i',
            );
          }, outputDirectory: out);
          await trace.flushed;
          expect(
            result.args.where((a) => a.startsWith('--cache=')),
            remote ? contains('--cache=no') : isEmpty,
          );
          await service.waitForExitSync(result.sessionId);
          final records = await File(trace.mpvOutput).readAsLines();
          final events = records.map((r) => jsonDecode(r) as Map).toList();
          expect(events.any((r) => r['event'] == 'mpvFileLoaded'), isTrue);
          expect(events.any((r) => r['event'] == 'mpvPlaybackRestart'), isTrue);
          await service.terminateSession(result.sessionId);
        }
        if (remote) {
          expect(
            logs.any((s) => s.contains('IPC cache update applied')),
            isTrue,
          );
        }
      } finally {
        await service.finishStoppedSessions();
        await server?.close(force: true);
        await base.delete(recursive: true);
      }
    },
    skip: mpv == null || media == null || output == null
        ? 'Set STREAMPATH_TS_MPV, STREAMPATH_TS_MEDIA and STREAMPATH_TS_OUTPUT for read-only real-media diagnostics'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
