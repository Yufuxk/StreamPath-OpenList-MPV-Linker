import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/data/local/iso_subtitle_store.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/data/models/webdav_bdmv.dart';
import 'package:streampath/data/remote/webdav_client.dart';
import 'package:streampath/domain/services/bd_java_runtime.dart';
import 'package:streampath/domain/services/iso_access_provider.dart';
import 'package:streampath/domain/services/iso_playback_service.dart';
import 'package:streampath/domain/services/iso_subtitle_service.dart';
import 'package:streampath/domain/services/local_media_source.dart';
import 'package:streampath/domain/services/mpv_session_controller.dart';
import 'package:streampath/domain/services/remote_menu_playback_service.dart';
import 'package:streampath/domain/services/webdav_service.dart';

Future<Object?> readProperty(MpvSessionController ipc, String name) async {
  try {
    return await ipc.getProperty(name);
  } on StateError catch (error) {
    if (error.message.toString().contains('property unavailable')) return null;
    rethrow;
  }
}

void main() {
  final fixturePath = Platform.environment['STREAMPATH_BLURAY_FIXTURE'];
  final player = Platform.environment['STREAMPATH_BLURAY_MPV'];
  final helper = Platform.environment['STREAMPATH_BLURAY_HELPER'];
  final javaRoot = Platform.environment['STREAMPATH_BLURAY_JAVA'];
  if (fixturePath == null ||
      player == null ||
      helper == null ||
      javaRoot == null) {
    test('真实 BDMV 双模式验证需要显式回环夹具及 MPV', () {}, skip: true);
    return;
  }
  for (final menu in [false, true]) {
    test(
      '真实生产服务 ${menu ? "菜单" : "MPLS"} 起播、字幕、章节和退出',
      () async {
        final fixture =
            jsonDecode(await File(fixturePath).readAsString()) as Map;
        final root = await Directory.systemTemp.createTemp('bluray-service-');
        final source = WebDAVService(
          client: WebDavClient(baseUrl: fixture['baseUrl'] as String),
          profileId: 'bluray-acceptance',
        );
        final disc = WebDavBdmv(
          name: 'Disc',
          href: '/',
          rootPath: '',
          files: [
            for (final item in fixture['files'] as List)
              Map<String, Object>.from(item as Map),
          ],
        );
        final config = PlayerConfig(
          name: 'MPV',
          executable: player,
          menuProgressSharingEnabled: true,
          args: ['--no-config', '--vo=null', '--ao=null', '--hwdec=auto-copy'],
        );
        final service = IsoPlaybackService(
          configStore: StreamPathConfigStore.forPath(
            p.join(root.path, 'config.json'),
          ),
          accessProvider: IsoBridgeAccessProvider(
            helperPathResolver: () async => helper,
          ),
          remoteMenuAccessProvider: IsoBridgeAccessProvider(
            helperPathResolver: () async => helper,
            remoteMenu: true,
          ),
          remoteMenuService: RemoteMenuPlaybackService(
            configLoader: () async => config,
            helperExecutable: helper,
            javaRuntime: BdJavaRuntime(root: javaRoot),
          ),
          configLoader: () async => config,
          tempRootProvider: () async =>
              Directory(p.join(root.path, 'iso_temp')),
          processStarter:
              (executable, args, {Map<String, String>? environment}) async {
                final process = await Process.start(executable, [
                  '--log-file=${p.join(root.path, "mpv.log")}',
                  ...args,
                ], environment: environment);
                process.stdout.drain<void>();
                process.stderr.drain<void>();
                return process.pid;
              },
        );
        IsoPlaybackLaunchResult? result;
        MpvSessionController? ipc;
        addTearDown(() async {
          await ipc?.dispose();
          if (result != null) {
            await service.terminateSession(result.sessionDirectoryPath);
          }
          service.dispose();
          // 只清理测试创建的数据；证据复制到 build 后保留。
          if (await root.exists()) await root.delete(recursive: true);
        });
        final resourceRoot = await Directory(
          p.join(root.path, 'resources'),
        ).create();
        await File(
          p.join(resourceRoot.path, 'Disc.iso'),
        ).writeAsBytes([1, 2, 3]);
        await File(
          p.join(resourceRoot.path, 'Disc.MPLS00222.ass'),
        ).writeAsString("""[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,36,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,1:57:00.00,Default,,0,0,0,,BLURAY TEST
""");
        final local = LocalMediaSource(
          LocalRootConfig(
            rootId: 'subs',
            displayName: 'Subtitles',
            path: resourceRoot.path,
          ),
        );
        final entries = await local.fetchDirectory('');
        final subtitles = IsoSubtitleContext(
          source: local,
          iso: entries.firstWhere((f) => f.name == 'Disc.iso'),
          isoPath: 'Disc.iso',
          store: IsoSubtitleStore(Directory(p.join(root.path, 'bindings'))),
        );
        await subtitles.discover();
        Future<IsoTitleSelection?> select(
          IsoTitleSelectionRequest request,
        ) async {
          final title = request.titles.firstWhere(
            (t) => t.programmeId == '00222',
          );
          expect(title.chapters, hasLength(19));
          return IsoTitleSelection(
            orderedTitles: request.titles,
            selectedProgrammeIds: {'00222'},
          );
        }

        final started = Stopwatch()..start();
        result = menu
            ? await service.startRemoteMenu(
                webDavService: source,
                file: disc,
                subtitles: subtitles,
              )
            : await service.start(
                webDavService: source,
                file: disc,
                subtitles: subtitles,
                selectTitles: select,
              );
        expect(result, isNotNull);
        final launch = result!;
        final pipe = launch.args
            .firstWhere((a) => a.startsWith('--input-ipc-server='))
            .substring('--input-ipc-server='.length);
        ipc = MpvSessionController(pipeName: pipe);
        expect(await ipc.connect(), isTrue);
        if (menu) {
          var observedMenu = false, observedFeature = false;
          final actions = <int>{};
          while (started.elapsed < const Duration(seconds: 120)) {
            final seconds = started.elapsed.inSeconds;
            for (final at in [5, 45, 80]) {
              if (seconds >= at && actions.add(at)) {
                await ipc.command(['discnav', at == 5 ? 'menu' : 'select']);
              }
            }
            observedMenu |= await readProperty(ipc, 'disc-menu-active') == true;
            final duration = await readProperty(ipc, 'duration') as num?;
            final position = await readProperty(ipc, 'time-pos') as num?;
            final chapters = await readProperty(ipc, 'chapter-list') as List?;
            observedFeature |=
                (duration ?? 0) > 6000 &&
                (position ?? 0) > 3 &&
                chapters?.length == 19 &&
                await readProperty(ipc, 'disc-menu-active') == false;
            if (observedFeature) break;
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
          expect(observedMenu, isTrue);
          expect(observedFeature, isTrue);
        } else {
          for (var i = 0; i < 150; i++) {
            final duration = await readProperty(ipc, 'duration') as num?;
            if ((duration ?? 0) > 6000 &&
                await readProperty(ipc, 'time-pos') != null) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
        num? position;
        for (final target in [600.0, 1200.0, 600.0]) {
          await ipc.command(['seek', target, 'absolute+exact']);
          for (var i = 0; i < 100; i++) {
            position = await readProperty(ipc, 'time-pos') as num?;
            if (position != null && (position - target).abs() < 2) break;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(position, closeTo(target, 2));
        }
        expect(await readProperty(ipc, 'chapter-list'), hasLength(19));
        List tracks = [];
        for (var i = 0; i < 100; i++) {
          tracks = await readProperty(ipc, 'track-list') as List? ?? [];
          if (tracks.any((t) => t['type'] == 'sub' && t['external'] == true)) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(
          tracks.any((t) => t['type'] == 'sub' && t['external'] == true),
          isTrue,
        );
        await Future<void>.delayed(const Duration(seconds: 2));
        if (menu) {
          await ipc.command(['discnav', 'popup']);
          await Future<void>.delayed(const Duration(seconds: 1));
          await ipc.command(['discnav', 'popup']);
        }
        final properties = <String, Object?>{};
        for (final name in [
          'time-pos',
          'duration',
          'chapter-list',
          'track-list',
          'disc-menu-active',
          'hwdec-current',
        ]) {
          properties[name] = await readProperty(ipc, name);
        }
        await ipc.command(['quit']);
        await ipc.dispose();
        ipc = null;
        for (var i = 0; i < 150 && service.isBusy; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(service.isBusy, isFalse);
        if (menu) {
          final eventsFile = File(
            p.join(
              root.path,
              'iso_benchmarks',
              p.basename(launch.sessionDirectoryPath),
              'iso-menu-events.jsonl',
            ),
          );
          final text = await eventsFile.readAsString();
          final events = text
              .split('\n')
              .where((line) => line.isNotEmpty)
              .map((line) => jsonDecode(line) as Map)
              .toList();
          expect(
            events.any((event) => event['event'] == 'playback-restart'),
            isTrue,
          );
          expect(events.every((event) => event['time'] is num), isTrue);
          expect(text, isNot(contains(fixture['baseUrl'] as String)));
        }
        final state = await service.portableState(
          profileId: source.sourceId,
          resolvedUrl: source.persistentUrl(disc.href),
          playbackMode: launch.playbackMode,
        );
        if (menu) {
          final cancelledSelection = await service.start(
            webDavService: source,
            file: disc,
            selectTitles: (request) async {
              expect(
                request.resumeByProgrammeId['00222']?.position.inSeconds,
                greaterThan(599),
              );
              return null;
            },
          );
          expect(cancelledSelection, isNull);
        }
        if (!menu) {
          expect((state['titles'] as Map).containsKey('00222'), isTrue);
          final savedPosition = state['titles']['00222']['position'] as num;
          result = await service.start(
            webDavService: source,
            file: disc,
            subtitles: subtitles,
            selectTitles: (request) async {
              expect(
                request.resumeByProgrammeId['00222']!.position.inSeconds,
                greaterThanOrEqualTo(599),
              );
              return select(request);
            },
          );
          final resumed = result!;
          final resumePipe = resumed.args
              .firstWhere((a) => a.startsWith('--input-ipc-server='))
              .substring('--input-ipc-server='.length);
          ipc = MpvSessionController(pipeName: resumePipe);
          expect(await ipc.connect(), isTrue);
          num? restored;
          for (var i = 0; i < 150; i++) {
            restored = await readProperty(ipc, 'time-pos') as num?;
            if (restored != null && (restored - savedPosition).abs() < 2) break;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(restored, closeTo(savedPosition, 3));
          properties['restoredPosition'] = restored;
          await ipc.command(['quit']);
          await ipc.dispose();
          ipc = null;
          for (var i = 0; i < 150 && service.isBusy; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(service.isBusy, isFalse);
        }
        final evidence = await Directory(
          Platform.environment['STREAMPATH_BLURAY_EVIDENCE'] ??
              'build/bluray-upgrade/service-evidence',
        ).create(recursive: true);
        await File(
          p.join(evidence.path, menu ? 'menu.json' : 'title.json'),
        ).writeAsString(
          jsonEncode({
            'properties': properties,
            'portableState': state,
            'startupAndProbeMs': started.elapsedMilliseconds,
          }),
        );
        await File(
          p.join(root.path, 'mpv.log'),
        ).copy(p.join(evidence.path, menu ? 'menu.log' : 'title.log'));
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
