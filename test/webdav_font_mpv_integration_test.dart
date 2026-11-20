import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/media_entry.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/data/models/subtitle_item.dart';
import 'package:streampath/data/remote/webdav_client.dart';
import 'package:streampath/domain/services/external_player_service.dart';
import 'package:streampath/domain/services/mpv_session_controller.dart';
import 'package:streampath/domain/services/webdav_font_cache.dart';
import 'package:streampath/domain/services/webdav_font_matcher.dart';
import 'package:streampath/domain/services/webdav_service.dart';

void main() {
  final mpv = Platform.environment['STREAMPATH_PATH_MPV'];
  final systemFont = File(
    p.join(
      Platform.environment['WINDIR'] ?? 'C:/Windows',
      'Fonts',
      'arial.ttf',
    ),
  );
  test(
    'MPV selects external fonts on a late start, jump, back and offline replay',
    () async {
      final root = await Directory.systemTemp.createTemp('spfont_');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
        await root.delete(recursive: true);
      });
      final origin = 'http://127.0.0.1:${server.port}';
      final font = await systemFont.readAsBytes();
      final families = ['SpFxA', 'SpFxB', 'SpFxC'];
      final remote = {
        for (final family in families)
          '/$family/font.ttf': _renameArial(font, family),
      };
      final requests = <String>[];
      server.listen((request) async {
        final path = request.uri.path;
        requests.add(path);
        final body = remote[path]!;
        if (path.contains(families.last) && requests.length == 1) {
          await Future<void>.delayed(const Duration(milliseconds: 2200));
        }
        request.response.contentLength = body.length;
        request.response.add(body);
        await request.response.close();
      });
      final config = StreamPathConfigStore.forPath(
        p.join(root.path, 'config.json'),
      );
      final log = File(p.join(root.path, 'mpv.log'));
      final probe = await File(p.join(root.path, 'font-probe.lua'))
          .writeAsString('''
mp.enable_messages('debug')
mp.register_event('log-message', function(event)
    if not event.text:find('fontselect:', 1, true) then return end
    local file = assert(io.open(${jsonEncode(log.path)}, 'a'))
    file:write(event.text, '\\n')
    file:close()
end)
''');
      await config.save(
        StreamPathConfig(
          playerExecutable: mpv!,
          playerArgs: [
            '--no-config',
            '--vo=null',
            '--vf=sub',
            '--ao=null',
            '--pause=yes',
            '--script=${probe.path}',
            '{url}',
          ],
          subtitleInjectionEnabled: true,
          subtitleAutoSelectEnabled: true,
          autoSeasonTransitionEnabled: false,
          webDavFontCacheEnabled: true,
        ),
      );
      final cacheRoot = Directory(p.join(root.path, 'fonts'));
      final player = ExternalPlayerService(
        configStore: config,
        watchLaterDir: Directory(p.join(root.path, 'scripts')),
        fontCache: WebDavFontCache(directory: cacheRoot),
      );
      final dav = WebDAVService(client: WebDavClient(baseUrl: origin));
      final sample = File(p.absolute('test/fixtures/film_probe.mp4'));
      final entries = <MediaEntry>[];
      final fonts = <WebDavFontDirectory>[];
      for (final family in families) {
        final video = await sample.copy(p.join(root.path, '$family.mp4'));
        final ass = await File(
          p.join(root.path, '$family.ass'),
        ).writeAsString(_ass(family));
        entries.add(
          MediaEntry(
            url: video.path,
            catalogPath: '$family/video.mkv',
            progressTarget: '$origin/$family/video.mkv',
            subtitle: SubtitleItem(
              name: '$family.ass',
              url: ass.path,
              language: SubtitleLanguage.chinese,
            ),
          ),
        );
        final directory = '$origin/$family/';
        fonts.add(
          WebDavFontDirectory(
            name: 'Fonts',
            requestPath: family,
            entryKey: directory,
            files: [
              WebDavFontFile(
                name: 'font.ttf',
                url: '${directory}font.ttf',
                size: font.length,
                etag: 'v1',
              ),
            ],
          ),
        );
      }
      final indices = List<int>.filled(150, 0)
        ..[73] = 1
        ..[149] = 2;
      Future<void> exercise(
        String session, {
        bool offline = false,
        bool jump = false,
      }) async {
        if (await log.exists()) await log.delete();
        final result = await player.launch(
          entries: [for (final i in indices) entries[i]],
          playlistStart: 149,
          sessionId: session,
          webDavSourceId: 'fixture-fonts',
          webDavSourceUrl: origin,
          webDavFontsByEntry: [
            for (final i in indices)
              offline ? WebDavFontDirectory.unavailable(families[i]) : fonts[i],
          ],
          webDavFontLoader: dav.fetchFileBytes,
          webDavFontFileLoader: dav.downloadFile,
        );
        final ipc = MpvSessionController(pipeName: result.ipcPipeName!);
        try {
          expect(await ipc.connect(), isTrue);
          Future<void> verify(int pos) async {
            final index = indices[pos];
            final family = families[index];
            await _until(() async {
              final tracks = await ipc.getProperty('track-list');
              if (tracks is! List ||
                  !tracks.any(
                    (track) =>
                        (track['external-filename'] as String?)?.endsWith(
                          '$family.ass',
                        ) ==
                        true,
                  )) {
                return false;
              }
              final directory = await ipc.getProperty('sub-fonts-dir');
              if (directory is! String ||
                  !p.isWithin(cacheRoot.path, directory)) {
                return false;
              }
              final cached = Directory(
                directory,
              ).listSync().whereType<File>().single;
              return await cached.length() == font.length &&
                  (await cached.readAsBytes()).toString() ==
                      remote['/$family/font.ttf'].toString();
            });
            await ipc.command(['frame-step']);
            await _until(
              () async =>
                  await log.exists() &&
                  (await log.readAsString()).contains(
                    'fontselect: ($family, 400, 0) -> $family',
                  ),
            );
          }

          await verify(149);
          if (jump) {
            expect(requests, ['/SpFxC/font.ttf']);
            for (final pos in [0, 73, 149]) {
              await log.delete();
              await ipc.setProperty('playlist-pos', pos);
              await verify(pos);
            }
          }
        } catch (_) {
          if (!await log.exists()) {
            // ignore: avoid_print
            print('MPV font trace missing after launch with ${result.args}');
          } else {
            // ignore: avoid_print
            print(
              (await log.readAsLines())
                  .where(
                    (line) =>
                        line.contains('fontselect') ||
                        line.contains('font-directory') ||
                        line.contains('Error'),
                  )
                  .join('\n'),
            );
          }
          rethrow;
        } finally {
          await ipc.dispose();
          await player.terminateSession(session);
        }
      }

      await exercise('font-first', jump: true);
      expect(requests, [
        '/SpFxC/font.ttf',
        '/SpFxA/font.ttf',
        '/SpFxB/font.ttf',
      ]);
      await exercise('font-online');
      expect(requests, hasLength(3));
      await server.close(force: true);
      await exercise('font-offline', offline: true);
      expect(requests, hasLength(3));
    },
    skip: mpv == null || !systemFont.existsSync()
        ? 'Set STREAMPATH_PATH_MPV and provide Windows Arial'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<void> _until(Future<bool> Function() predicate) async {
  final timer = Stopwatch()..start();
  while (timer.elapsed < const Duration(seconds: 12)) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('MPV font condition was not observed');
}

// 保持字体表偏移不变，使用系统中不存在的测试字体族名。
Uint8List _renameArial(Uint8List original, String family) {
  final bytes = Uint8List.fromList(original);
  final source = ascii.encode('Arial');
  final target = ascii.encode(family);
  for (final wide in [false, true]) {
    final pattern = [
      for (final value in source) ...[if (wide) 0, value],
    ];
    final replacement = [
      for (final value in target) ...[if (wide) 0, value],
    ];
    for (var offset = 0; offset <= bytes.length - pattern.length; offset++) {
      if (pattern.indexed.every((item) => bytes[offset + item.$1] == item.$2)) {
        bytes.setRange(offset, offset + pattern.length, replacement);
      }
    }
  }
  return bytes;
}

String _ass(String family) =>
    '''
[Script Info]
ScriptType: v4.00+
PlayResX: 160
PlayResY: 90
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,$family,24,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,0,0,0,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:04.00,Default,,0,0,0,,External font sample
''';
