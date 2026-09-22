import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/local/iso_subtitle_store.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/domain/services/local_media_source.dart';
import 'package:streampath/domain/services/iso_subtitle_service.dart';

void main() {
  final mpv = Platform.environment['STREAMPATH_PATH_MPV'];
  for (final autoSelect in [true, false]) {
    test('真实 MPV 自动评分及自动选择开关：$autoSelect', () async {
      final root = await Directory.systemTemp.createTemp('iso-score-mpv-');
      addTearDown(() => root.delete(recursive: true));
      final video = p.join(root.path, 'sample.avi');
      final generated = await Process.run('ffmpeg', [
        '-v',
        'error',
        '-f',
        'lavfi',
        '-i',
        'color=c=black:s=64x64:r=10',
        '-t',
        '4',
        '-c:v',
        'mpeg4',
        video,
      ]);
      expect(generated.exitCode, 0, reason: '${generated.stderr}');
      await File('${root.path}/Movie.iso').writeAsBytes([1]);
      await File(
        '${root.path}/wrong.chs.srt',
      ).writeAsString('1\n00:00:00,000 --> 00:00:30,000\nWRONG');
      await File(
        '${root.path}/right.en.srt',
      ).writeAsString('1\n00:00:00,000 --> 00:00:03,900\nSCORED');
      final source = LocalMediaSource(
        await LocalRootConfig.fromDirectory(
          path: root.path,
          displayName: 'test',
          rootId: 'score-mpv',
        ),
      );
      final context = IsoSubtitleContext(
        source: source,
        iso: (await source.fetchDirectory('')).firstWhere((e) => e.isIso),
        isoPath: 'Movie.iso',
        store: IsoSubtitleStore(Directory('${root.path}/maps')),
      );
      await context.discover();
      context.titleCatalog = [
        {'id': '00007', 'duration': 4},
      ];
      final session = await context.prepare(
        Directory('${root.path}/session'),
        sessionId: 'score',
        pipeName: 'unused',
        menu: false,
        autoSelect: autoSelect,
        playlist: [
          {'id': '00007', 'duration': '4', 'path': video},
        ],
      );
      final output = File('${root.path}/result.json');
      final probe = File('${root.path}/probe.lua');
      await probe.writeAsString('''
local mp=require 'mp'
local utils=require 'mp.utils'
mp.register_event('file-loaded',function()
  mp.add_timeout(0.7,function()
    local f=assert(io.open(${jsonEncode(output.path)},'wb'))
    f:write(utils.format_json({state=mp.get_property_native('user-data/streampath/iso-subtitles'),
      tracks=mp.get_property_native('track-list'),sid=mp.get_property_native('sid'),text=mp.get_property('sub-text')}))
    f:close(); mp.commandv('quit')
  end)
end)
''');
      final process = await Process.start(mpv!, [
        '--no-config',
        '--vo=null',
        '--ao=null',
        '--sid=no',
        '--sub-auto=no',
        '--script=${session.scriptPath}',
        '--script=${probe.path}',
        video,
      ]);
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.transform(utf8.decoder).join();
      try {
        expect(await process.exitCode.timeout(const Duration(seconds: 15)), 0);
        final result = jsonDecode(await output.readAsString()) as Map;
        final logDirectory = Directory('build/iso-auto-score-mpv')
          ..createSync(recursive: true);
        await File(
          '${logDirectory.path}/$autoSelect.json',
        ).writeAsString(jsonEncode(result));
        await File(
          '${logDirectory.path}/$autoSelect.log',
        ).writeAsString('${await stdout}\n${await stderr}');
        expect(result['state']['status'], 'loaded');
        final subs = (result['tracks'] as List)
            .where((t) => t['type'] == 'sub')
            .toList();
        expect(subs, hasLength(1));
        expect(subs.single['external-filename'], endsWith('right.en.srt'));
        if (autoSelect) {
          expect(result['text'], contains('SCORED'));
        } else {
          expect(result['sid'], isFalse);
        }
      } finally {
        process.kill();
        await process.exitCode;
      }
    }, skip: mpv == null || !File(mpv).existsSync());
  }
}
