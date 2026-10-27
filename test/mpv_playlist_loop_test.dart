import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/media_entry.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/data/models/video_queue.dart';
import 'package:streampath/domain/services/external_player_service.dart';
import 'package:streampath/domain/services/mpv_session_controller.dart';

void main() {
  test(
    'implicit queue loops to the first item',
    () async {
      final dir = await Directory.systemTemp.createTemp('loop_verify_');
      final media = File(p.join(dir.path, 'a.wav'));
      await media.writeAsBytes(_silentWave(seconds: 1));
      final config = StreamPathConfigStore.forPath(
        p.join(dir.path, 'config.json'),
      );
      await config.save(
        StreamPathConfig(
          playerExecutable: Platform.environment['STREAMPATH_PATH_MPV']!,
          playerArgs: [
            '--no-config',
            '--vo=null',
            '--ao=null',
            '--pause=yes',
            '--log-file=${p.join(dir.path, 'mpv.log')}',
            '{url}',
          ],
          subtitleInjectionEnabled: false,
          externalAudioInjectionEnabled: false,
          autoSeasonTransitionEnabled: false,
        ),
      );
      final active = <int>[];
      MediaEntry entry(int index) => MediaEntry(
        url: media.path,
        catalogPath: 'list/$index.wav',
        title: 'Item $index',
      );
      // 播放器清理可能在用例结束后才回报失败，只记录测试期内的错误。
      var finished = false;
      final plan = ImplicitVideoPlan(
        index: 0,
        loop: true,
        items: [
          for (var i = 0; i < 2; i++)
            VideoQueueItem(
              versions: [
                VideoQueueVersion(path: 'list/$i.wav', name: '$i.wav'),
              ],
            ),
        ],
        prepare: (v) async =>
            PreparedVideoItem(entry: entry(int.parse(v.name[0]))),
        activated: (i, _) async => active.add(i),
        failed: (message) {
          if (!finished) fail(message);
        },
      );
      final service = ExternalPlayerService(
        configStore: config,
        watchLaterDir: Directory(p.join(dir.path, 'watch')),
      );
      PlayerLaunchResult? launched;
      MpvSessionController? controller;
      Future<void> waitFor(Future<bool> Function() check) async {
        for (var i = 0; i < 150; i++) {
          if (await check()) return;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        fail(await File(p.join(dir.path, 'mpv.log')).readAsString());
      }

      try {
        launched = await service.launchLocal(
          entries: [entry(0)],
          sourceId: 'local:loop',
          sessionId: 'loop-session',
          implicitPlan: plan,
        );
        controller = MpvSessionController(pipeName: launched.ipcPipeName!);
        expect(await controller.connect(), true);
        await waitFor(() async => active.contains(0));
        await controller.setProperty('pause', false);
        await waitFor(() async => active.contains(1));
        await waitFor(() async => active.where((i) => i == 0).length >= 2);
        expect(active, [0, 1, 0]);
        expect(await service.isPlayerRunning('loop-session'), true);
      } finally {
        finished = true;
        await controller?.dispose();
        if (launched != null) await service.terminateSession('loop-session');
        await dir.delete(recursive: true);
      }
    },
    skip: Platform.environment['STREAMPATH_PATH_MPV'] == null
        ? 'Set STREAMPATH_PATH_MPV'
        : false,
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'local implicit playback preloads next without autoload siblings',
    _expectLocalImplicitIsolation,
    skip: Platform.environment['STREAMPATH_PATH_MPV'] == null
        ? 'Set STREAMPATH_PATH_MPV'
        : false,
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'implicit queue keeps the configured window size',
    _expectImplicitWindowSize,
    skip: Platform.environment['STREAMPATH_PATH_MPV'] == null
        ? 'Set STREAMPATH_PATH_MPV'
        : false,
    timeout: const Timeout(Duration(minutes: 1)),
  );
}

Future<void> _expectLocalImplicitIsolation() async {
  final dir = await Directory.systemTemp.createTemp(
    'local_implicit_isolation_',
  );
  final media = <String, File>{};
  for (final name in ['a.wav', 'b.wav', 'c.wav']) {
    final file = File(p.join(dir.path, name));
    await file.writeAsBytes(_silentWave(seconds: 1));
    media[name] = file;
  }
  final autoload = File(p.join(dir.path, 'autoload.lua'));
  await autoload.writeAsString(r'''
local options = require 'mp.options'
local utils = require 'mp.utils'
local appended = false
mp.register_event('file-loaded', function()
  if appended then return end
  appended = true
  local o = { disabled = false }
  options.read_options(o, 'autoload')
  if o.disabled then return end
  local path = mp.get_property('path', '')
  local dir = path:match('^(.*)[/\\]') or ''
  local entries = utils.readdir(dir, 'files') or {}
  for _, name in ipairs(entries) do
    if name:match('%.wav$') then
      local file = utils.join_path(dir, name)
      if file ~= path then
        mp.commandv('loadfile', file, 'append')
      end
    end
  end
end)
''');
  final config = StreamPathConfigStore.forPath(p.join(dir.path, 'config.json'));
  await config.save(
    StreamPathConfig(
      playerExecutable: Platform.environment['STREAMPATH_PATH_MPV']!,
      playerArgs: [
        '--no-config',
        '--vo=null',
        '--ao=null',
        '--pause=yes',
        '--log-file=${p.join(dir.path, 'mpv.log')}',
        '--script-opts-append=autoload-disabled=no',
        '--script=${autoload.path}',
        '{url}',
      ],
      subtitleInjectionEnabled: false,
      externalAudioInjectionEnabled: false,
      autoSeasonTransitionEnabled: false,
    ),
  );
  MediaEntry entry(String name) => MediaEntry(
    url: media[name]!.path,
    catalogPath: 'isolation/$name',
    title: name,
  );
  final plan = ImplicitVideoPlan(
    index: 0,
    items: [
      VideoQueueItem(
        versions: [VideoQueueVersion(path: 'isolation/a.wav', name: 'a.wav')],
      ),
      VideoQueueItem(
        versions: [VideoQueueVersion(path: 'isolation/c.wav', name: 'c.wav')],
      ),
    ],
    prepare: (v) async => PreparedVideoItem(entry: entry(v.name)),
    isCached: (_) async => false,
    activated: (_, _) async {},
    failed: fail,
  );
  final service = ExternalPlayerService(
    configStore: config,
    watchLaterDir: Directory(p.join(dir.path, 'watch')),
  );
  PlayerLaunchResult? launched;
  MpvSessionController? controller;
  Future<void> waitFor(Future<bool> Function() check) async {
    for (var i = 0; i < 150; i++) {
      if (await check()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail(await File(p.join(dir.path, 'mpv.log')).readAsString());
  }

  try {
    launched = await service.launchLocal(
      entries: [entry('a.wav')],
      sourceId: 'local:isolation',
      sessionId: 'isolation',
      implicitPlan: plan,
    );
    controller = MpvSessionController(pipeName: launched.ipcPipeName!);
    expect(await controller.connect(), true);
    await waitFor(() async {
      final list = await controller!.getProperty('playlist') as List;
      return list.any(
        (e) => p.basename((e as Map)['filename'] as String? ?? '') == 'c.wav',
      );
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final list = await controller.getProperty('playlist') as List;
    final names = [
      for (final e in list) p.basename((e as Map)['filename'] as String? ?? ''),
    ];
    expect(names, containsAll(['a.wav', 'c.wav']));
    expect(names, isNot(contains('b.wav')));
    expect(
      names.where((name) => ['a.wav', 'b.wav', 'c.wav'].contains(name)),
      hasLength(2),
    );
  } finally {
    await controller?.dispose();
    if (launched != null) await service.terminateSession('isolation');
    await dir.delete(recursive: true);
  }
}

Future<void> _expectImplicitWindowSize() async {
  final dir = await Directory.systemTemp.createTemp('implicit_window_');
  final order = ['a.wav', 'b.wav', 'c.wav', 'd.wav', 'e.wav'];
  final media = <String, File>{};
  for (final name in order) {
    final file = File(p.join(dir.path, name));
    await file.writeAsBytes(_silentWave(seconds: 6));
    media[name] = file;
  }
  final config = StreamPathConfigStore.forPath(p.join(dir.path, 'config.json'));
  await config.save(
    StreamPathConfig(
      implicitPlaylistWindowSize: 3,
      playerExecutable: Platform.environment['STREAMPATH_PATH_MPV']!,
      playerArgs: [
        '--no-config',
        '--vo=null',
        '--ao=null',
        '--pause=yes',
        '--log-file=${p.join(dir.path, 'mpv.log')}',
        '{url}',
      ],
      subtitleInjectionEnabled: false,
      externalAudioInjectionEnabled: false,
      autoSeasonTransitionEnabled: false,
    ),
  );
  MediaEntry entry(String name) => MediaEntry(
    url: media[name]!.path,
    catalogPath: 'window/$name',
    title: name,
  );
  final active = <int>[];
  // 播放器清理可能在用例结束后才回报失败，只记录测试期内的错误。
  var finished = false;
  final plan = ImplicitVideoPlan(
    index: 0,
    items: [
      for (final name in order)
        VideoQueueItem(
          versions: [VideoQueueVersion(path: 'window/$name', name: name)],
        ),
    ],
    prepare: (v) async => PreparedVideoItem(entry: entry(v.name)),
    activated: (i, _) async => active.add(i),
    failed: (message) {
      if (!finished) fail(message);
    },
  );
  final service = ExternalPlayerService(
    configStore: config,
    watchLaterDir: Directory(p.join(dir.path, 'watch')),
  );
  PlayerLaunchResult? launched;
  MpvSessionController? controller;
  Future<void> waitFor(Future<bool> Function() check) async {
    for (var i = 0; i < 200; i++) {
      if (await check()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail(await File(p.join(dir.path, 'mpv.log')).readAsString());
  }

  Future<List<String>> window() async {
    final list = await controller!.getProperty('playlist') as List;
    return [
      for (final e in list) p.basename((e as Map)['filename'] as String? ?? ''),
    ];
  }

  try {
    launched = await service.launchLocal(
      entries: [entry('a.wav')],
      sourceId: 'local:window',
      sessionId: 'window',
      implicitPlan: plan,
    );
    controller = MpvSessionController(pipeName: launched.ipcPipeName!);
    expect(await controller.connect(), true);
    await waitFor(() async => (await window()).length == 3);
    expect(await window(), ['a.wav', 'b.wav', 'c.wav']);
    await controller.setProperty('pause', false);
    await waitFor(() async => active.contains(1));
    await controller.setProperty('pause', true);
    await waitFor(
      () async =>
          (await window()).length == 3 && (await window()).first == 'b.wav',
    );
    expect(await window(), ['b.wav', 'c.wav', 'd.wav']);
  } finally {
    finished = true;
    await controller?.dispose();
    if (launched != null) await service.terminateSession('window');
    await dir.delete(recursive: true);
  }
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
