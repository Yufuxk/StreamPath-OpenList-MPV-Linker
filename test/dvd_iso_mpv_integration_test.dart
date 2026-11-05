import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/data/local/iso_subtitle_store.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/domain/services/iso_access_provider.dart';
import 'package:streampath/domain/services/iso_playback_service.dart';
import 'package:streampath/domain/services/iso_subtitle_service.dart';
import 'package:streampath/domain/services/local_iso_service.dart';
import 'package:streampath/domain/services/local_media_source.dart';
import 'package:streampath/domain/services/mpv_session_controller.dart';

void main() {
  final image = Platform.environment['STREAMPATH_DVD_ISO'];
  final programme =
      Platform.environment['STREAMPATH_DVD_PROGRAMME'] ?? 'dvd-title-01';
  final chapters = int.parse(
    Platform.environment['STREAMPATH_DVD_CHAPTERS'] ?? '8',
  );
  final playerRoot = Platform.environment['STREAMPATH_MPV_TEST_ROOT'];
  final helper = Platform.environment['STREAMPATH_DVD_HELPER'];
  final players = playerRoot == null
      ? <File>[]
      : Directory(playerRoot)
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => p.basename(file.path).toLowerCase() == 'mpv.exe')
            .toList();
  if (players.isEmpty) {
    test('DVD 实体 MPV 验证需要显式样本及播放器目录', () {}, skip: true);
  }
  for (final player in players) {
    test(
      'DVD 实体起播、章节、Seek、外挂字体与独立续播 ${p.basename(player.parent.path)}',
      () async {
        final root = await Directory(
          p.absolute(
            'build',
            'dvd-support',
            'service-$programme-${p.basename(player.parent.path)}',
          ),
        ).create(recursive: true);
        final local = LocalMediaSource(
          LocalRootConfig(
            rootId: 'dvd-test',
            displayName: 'DVD test',
            path: p.dirname(image!),
          ),
        );
        final source = LocalIsoService(local);
        final stat = await File(image).stat();
        final iso = WebDavFile(
          name: p.basename(image),
          href: p.basename(image),
          isDirectory: false,
          size: stat.size,
          modified: stat.modified,
        );
        final resourceRoot = Directory(p.join(root.path, 'resources'))
          ..createSync();
        final subtitle = File(
          p.join(resourceRoot.path, 'Disc.TITLE${programme.substring(10)}.ass'),
        );
        await File(
          p.join(resourceRoot.path, 'Disc.iso'),
        ).writeAsBytes([1, 2, 3]);
        await subtitle.writeAsString('''[Script Info]
ScriptType: v4.00+
PlayResX: 720
PlayResY: 480
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,30,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:58:00.00,Default,,0,0,0,,DVD TEST
''');
        final fonts = Directory(p.join(resourceRoot.path, 'fonts'))
          ..createSync();
        await File(
          r'C:\Windows\Fonts\arial.ttf',
        ).copy(p.join(fonts.path, 'test.ttf'));
        final resources = LocalMediaSource(
          LocalRootConfig(
            rootId: 'dvd-subs',
            displayName: 'DVD subtitles',
            path: resourceRoot.path,
          ),
        );
        final entries = await resources.fetchDirectory('');
        final subtitles = IsoSubtitleContext(
          source: resources,
          iso: entries.firstWhere((file) => file.name == 'Disc.iso'),
          isoPath: 'Disc.iso',
          store: IsoSubtitleStore(Directory(p.join(root.path, 'bindings'))),
        );
        await subtitles.discover();
        expect(subtitles.fonts, hasLength(1));
        final service = IsoPlaybackService(
          configStore: StreamPathConfigStore.forPath(
            p.join(root.path, 'config.json'),
          ),
          accessProvider: IsoBridgeAccessProvider(
            helperPathResolver: () async => helper!,
          ),
          processStarter: (executable, args) async {
            final process = await Process.start(executable, [
              '--log-file=${p.join(root.path, 'mpv.log').replaceAll(r'\', '/')}',
              ...args,
            ]);
            process.stdout.drain<void>();
            process.stderr.drain<void>();
            return process.pid;
          },
          tempRootProvider: () async =>
              Directory(p.join(root.path, 'iso_temp')),
          configLoader: () async => PlayerConfig(
            name: 'MPV',
            executable: player.path,
            args: [
              '--no-config',
              '--vo=null',
              '--ao=null',
              '--pause=yes',
              '--log-file=${p.join(root.path, 'mpv.log').replaceAll(r'\', '/')}',
            ],
          ),
        );
        IsoPlaybackLaunchResult? result;
        MpvSessionController? ipc;
        addTearDown(() async {
          await ipc?.dispose();
          if (result != null) {
            await service.terminateSession(result.sessionDirectoryPath);
          }
          service.dispose();
          if (await root.exists()) await root.delete(recursive: true);
        });
        result = await service.start(
          webDavService: source,
          file: iso,
          subtitles: subtitles,
          selectTitles: (request) async {
            final title = request.titles.firstWhere(
              (title) => title.programmeId == programme,
            );
            expect(title.chapters, hasLength(chapters));
            return IsoTitleSelection(
              orderedTitles: request.titles,
              selectedProgrammeIds: {programme},
            );
          },
        );
        expect(result, isNotNull);
        expect(
          result!.args.any((arg) => arg.startsWith('--dvd-device')),
          isFalse,
        );
        final pipe = result.args
            .firstWhere((arg) => arg.startsWith('--input-ipc-server='))
            .substring('--input-ipc-server='.length);
        ipc = MpvSessionController(pipeName: pipe);
        expect(await ipc.connect(), isTrue);
        List<dynamic> tracks = [];
        for (var attempt = 0; attempt < 80; attempt++) {
          tracks =
              (await ipc.getProperty('track-list')) as List<dynamic>? ?? [];
          if (tracks.any(
            (track) => track['type'] == 'sub' && track['external'] == true,
          )) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(
          tracks.where(
            (track) => track['type'] == 'sub' && track['external'] == true,
          ),
          hasLength(1),
        );
        expect(tracks.any((track) => track['type'] == 'video'), isTrue);
        expect(tracks.any((track) => track['type'] == 'audio'), isTrue);
        final options = await Process.run(player.path, [
          '--no-config',
          '--list-options',
        ]);
        if ((options.stdout as String).contains('--sub-fonts-dir')) {
          expect(
            await ipc.getProperty('sub-fonts-dir'),
            contains(result.sessionDirectoryPath),
          );
        }
        expect(
          (await ipc.getProperty('chapter-list') as List).length,
          chapters,
        );
        await ipc.setProperty('pause', false);
        await Future<void>.delayed(const Duration(milliseconds: 350));
        num? position;
        for (final target in [671.934, 121.0, 671.934]) {
          await ipc.command(['seek', target, 'absolute+exact']);
          for (var attempt = 0; attempt < 60; attempt++) {
            position = await ipc.getProperty('time-pos') as num?;
            if (position != null && (position - target).abs() < 2) break;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(position, closeTo(target, 2));
        }
        expect(
          (await ipc.getProperty('track-list') as List).where(
            (track) => track['type'] == 'sub' && track['external'] == true,
          ),
          hasLength(1),
        );
        await Future<void>.delayed(const Duration(seconds: 1));
        await ipc.command(['quit']);
        await ipc.dispose();
        ipc = null;
        for (var attempt = 0; attempt < 80 && service.isBusy; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(service.isBusy, isFalse);
        final state = await service.portableState(
          profileId: source.sourceId,
          resolvedUrl: source.persistentUrl(iso.href),
          playbackMode: result.playbackMode,
        );
        expect((state['titles'] as Map).containsKey(programme), isTrue);
        expect(
          (state['titles'][programme]['position'] as num),
          greaterThan(670),
        );
        result = await service.start(
          webDavService: source,
          file: iso,
          selectTitles: (request) async {
            expect(
              request.resumeByProgrammeId[programme]!.position.inMilliseconds /
                  1000,
              greaterThan(670),
            );
            return IsoTitleSelection(
              orderedTitles: request.titles,
              selectedProgrammeIds: {programme},
            );
          },
        );
        final resumePipe = result!.args
            .firstWhere((arg) => arg.startsWith('--input-ipc-server='))
            .substring('--input-ipc-server='.length);
        ipc = MpvSessionController(pipeName: resumePipe);
        expect(await ipc.connect(), isTrue);
        num? restoredPosition;
        for (var attempt = 0; attempt < 80; attempt++) {
          restoredPosition = await ipc.getProperty('time-pos') as num?;
          if (restoredPosition != null && restoredPosition > 670) break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(restoredPosition, closeTo(position!, 3));
        await ipc.command(['quit']);
        await ipc.dispose();
        ipc = null;
        for (var attempt = 0; attempt < 80 && service.isBusy; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(service.isBusy, isFalse);
        final evidence = await Directory(
          p.absolute('build', 'dvd-support', 'service-evidence'),
        ).create(recursive: true);
        await File(
          p.join(
            evidence.path,
            '$programme-${p.basename(player.parent.path)}.json',
          ),
        ).writeAsString(
          jsonEncode({
            'chapters': chapters,
            'subtitleTracks': 1,
            'fontsDirectorySupported': (options.stdout as String).contains(
              '--sub-fonts-dir',
            ),
            'seekPosition': position,
            'restoredPosition': restoredPosition,
            'portableState': state,
          }),
        );
      },
      skip: image == null || helper == null,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
