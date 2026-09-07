import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/data/models/playback_history.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/domain/services/iso_access_provider.dart';
import 'package:streampath/domain/services/remote_menu_playback_service.dart';

void main() {
  test('实体 MPV 忽略旧续播参数并保留菜单导航和共享进度', () async {
    final directory = await Directory.systemTemp.createTemp('menu-resume-');
    addTearDown(() => directory.delete(recursive: true));
    final script = await RemoteMenuPlaybackService.writeProgressScript(directory);
    final resultFile = File('${directory.path}/result.json');
    final probe = File('${directory.path}/probe.lua');
    await probe.writeAsString('''
local mp = require 'mp'
local utils = require 'mp.utils'
local result = {}
mp.add_timeout(3, function()
    result.edition = mp.get_property_number('current-edition', -1)
    result.position = mp.get_property_number('time-pos', -1)
    result.cacheSeconds = mp.get_property_number('demuxer-cache-duration', -1)
end)
mp.add_timeout(27, function() mp.commandv('discnav', 'menu') end)
mp.add_timeout(40, function()
    result.menu = mp.get_property_native('disc-menu-active')
    mp.set_property_number('edition', 1)
end)
mp.add_timeout(42, function() mp.commandv('seek', 123.5, 'absolute+exact') end)
mp.add_timeout(45, function()
    local file = assert(io.open(${jsonEncode(resultFile.path)}, 'wb'))
    file:write(utils.format_json(result))
    file:close()
    mp.commandv('quit')
end)
''');
    final player = await Process.start(
      Platform.environment['STREAMPATH_MENU_MPV']!,
      [
        '--no-config', '--vo=null', '--ao=null', '--idle=no', '--keep-open=no',
        '--script=$script', '--script=${probe.path}',
        '--script-opts-append=streampath-menu-edition=1',
        '--script-opts-append=streampath-menu-position=123.5',
        '--bluray-device=${Platform.environment['STREAMPATH_MENU_BDMV']!}',
        'bd://menu',
      ],
    );
    final stdout = player.stdout.transform(utf8.decoder).join();
    final stderr = player.stderr.transform(utf8.decoder).join();
    try {
      expect(await player.exitCode.timeout(const Duration(seconds: 55)), 0);
      final result = jsonDecode(await resultFile.readAsString()) as Map;
      // ignore: avoid_print
      print('Menu resume probe: ${jsonEncode(result)}');
      expect(result['edition'], 0);
      expect(result['position'], lessThan(10));
      expect(result['menu'], isTrue);
      final lines = await File('${directory.path}/menu-progress.jsonl').readAsLines();
      final last = jsonDecode(lines.last) as Map;
      expect(last['edition'], 1);
      expect(last['mplsId'], '00001');
      expect(last['position'], inInclusiveRange(123.5, 132));
      expect(last['completed'], isFalse);
    } finally {
      player.kill();
      await player.exitCode;
      // 保留诊断输出供实体测试失败时定位。
      // ignore: avoid_print
      print('${await stdout}\n${await stderr}');
    }
  }, timeout: const Timeout(Duration(seconds: 60)),
      skip: Platform.environment['STREAMPATH_MENU_MPV'] == null ||
      Platform.environment['STREAMPATH_MENU_BDMV'] == null);

  test('菜单进度 Lua 保留退出位置并隔离菜单、切集和完成', () async {
    final directory = await Directory.systemTemp.createTemp('menu-progress-');
    addTearDown(() => directory.delete(recursive: true));
    final script = await RemoteMenuPlaybackService.writeProgressScript(directory);
    for (final mode in ['normal', 'resume']) {
      final result = await Process.run(
        Platform.environment['STREAMPATH_MENU_LUA']!,
        ['tools/winfsp_poc/verify_menu_progress.lua', script, mode],
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    }
  }, skip: Platform.environment['STREAMPATH_MENU_LUA'] == null);

  test(
    '实体 WinFsp helper 与用户 MPV 通过应用能力检查',
    () async {
      final config = PlayerConfig(
        name: 'MPV',
        executable: Platform.environment['STREAMPATH_MENU_MPV']!,
      );
      final service = RemoteMenuPlaybackService(
        configLoader: () async => config,
        helperExecutable: File(
          'build/windows/x64/iso_bridge/Release/streampath_iso_bridge.exe',
        ).absolute.path,
      );
      expect(await service.unavailableReason(), isNull);
      expect(
        await service.requireCapability(config: config),
        config.executable,
      );
    },
    skip:
        !Platform.isWindows ||
        Platform.environment['STREAMPATH_MENU_MPV'] == null,
  );
  test('WinFsp 菜单使用会话内本地文件且不注入专用 MPV 参数', () {
    final args = RemoteMenuPlaybackService.buildArgs(
      const PlayerConfig(
        name: 'MPV',
        executable: 'mpv',
        args: ['--hwdec=auto'],
      ),
      endpoint: Uri.file(r'C:\session\disc\disc.iso', windows: true),
      ipcPipeName: 'private-pipe',
      scriptPath: r'C:\session\state.lua',
    );
    expect(args, contains(r'--bluray-device=C:\session\disc\disc.iso'));
    expect(args, contains('--hwdec=auto'));
    expect(args, contains('--demuxer-max-bytes=16777216'));
    expect(args.any((arg) => arg.startsWith('--bluray-remote-')), isFalse);
    expect(args.last, 'bd://menu');
    expect(
      () => RemoteMenuPlaybackService.buildArgs(
        const PlayerConfig(name: 'MPV', executable: 'mpv'),
        endpoint: Uri.file(r'C:\other\disc.iso', windows: true),
        ipcPipeName: 'p',
        scriptPath: r'C:\session\state.lua',
      ),
      throwsArgumentError,
    );
  });
  test('WinFsp ready 限定会话内挂载路径，不能被旧协议冒充', () {
    final ready = <String, dynamic>{
      'type': 'ready',
      'version': 1,
      'port': 0,
      'token': 'a' * 32,
      'totalBytes': 4194304,
      'titles': <Object>[],
      'capability': 'winfsp-disc-v1',
      'mode': 'hdmv',
      'discPath': r'C:\session\disc\disc.iso',
    };
    expect(
      IsoBridgeReady.fromMessage(
        ready,
        remoteMenu: true,
        mountedSessionPath: r'C:\session',
      ).discPath,
      r'C:\session\disc\disc.iso',
    );
    expect(
      () => IsoBridgeReady.fromMessage(ready, remoteMenu: true),
      throwsException,
    );
    ready['discPath'] = r'C:\elsewhere\disc.iso';
    expect(
      () => IsoBridgeReady.fromMessage(
        ready,
        remoteMenu: true,
        mountedSessionPath: r'C:\session',
      ),
      throwsException,
    );
  });
  test('旧历史缺省保留原模式，菜单历史往返及复制保留独立模式', () {
    final history = PlaybackHistory(
      dirCrumbs: const ['disc'],
      fileName: 'film.iso',
      videoIndex: 0,
      updatedAt: DateTime(2026),
      kind: PlaybackHistoryKind.iso,
      playbackMode: PlaybackMode.webdavHdmvMenu,
    );
    expect(
      PlaybackHistory.fromJson(history.toJson()).playbackMode,
      PlaybackMode.webdavHdmvMenu,
    );
    expect(
      history.copyWith(fileName: 'copy.iso').playbackMode,
      PlaybackMode.webdavHdmvMenu,
    );
    final old = history.toJson()..remove('playbackMode');
    expect(
      PlaybackHistory.fromJson(old).playbackMode,
      PlaybackMode.legacyTitle,
    );
  });
  test('菜单参数复用 ISO 秘密过滤并固定设备、模式和缓存预算', () {
    final args = RemoteMenuPlaybackService.buildArgs(
      const PlayerConfig(
        name: 'MPV',
        executable: 'unused',
        args: [
          '--hwdec=auto',
          '--http-header-fields=Authorization: secret',
          '--cookies-file',
          'private-cookie.txt',
          '--http-proxy=https://secret',
          '--bluray-device=old.iso',
          '--demuxer-max-bytes=999999999',
          '--idle=yes',
          '--playlist=https://private',
          '--start=900',
          'https://upstream/secret.iso',
        ],
      ),
      endpoint: Uri.file(r'C:\session\disc\disc.iso', windows: true),
      ipcPipeName: 'private-pipe',
      scriptPath: r'C:\session\state.lua',
    );
    expect(args, contains('--hwdec=auto'));
    expect(args.last, 'bd://menu');
    expect(args.where((arg) => arg.startsWith('--bluray-device=')).length, 1);
    expect(args.any((arg) => arg.startsWith('--bluray-remote-')), isFalse);
    expect(args, contains('--demuxer-max-bytes=16777216'));
    expect(args.join(' '), isNot(contains('secret')));
    expect(args.join(' '), isNot(contains('private-cookie')));
    expect(args.join(' '), isNot(contains('old.iso')));
    expect(args.join(' '), isNot(contains('900')));
  });

  test('菜单端点拒绝远端 URL、查询参数、错误 token 和盘外路径', () {
    for (final url in [
      'https://example.com/disc.iso',
      'http://127.0.0.1:80/short/disc.iso',
      'http://127.0.0.1:80/0123456789abcdef0123456789abcdef/disc.iso?secret=1',
      'http://user:pass@127.0.0.1:80/0123456789abcdef0123456789abcdef/disc.iso',
    ]) {
      expect(
        () => RemoteMenuPlaybackService.buildArgs(
          const PlayerConfig(name: 'MPV', executable: 'unused'),
          endpoint: Uri.parse(url),
          ipcPipeName: 'p',
          scriptPath: 's',
        ),
        throwsArgumentError,
      );
    }
  });

  test('remote ready 不能冒充 Title ready，也不能把 Title ready 用于菜单', () {
    final ready = <String, dynamic>{
      'type': 'ready',
      'version': 1,
      'port': 45678,
      'token': '0123456789abcdef0123456789abcdef',
      'totalBytes': 4194304,
      'titles': <Object>[],
      'capability': 'remote-disc-blocks-v1',
      'mode': 'hdmv',
    };
    expect(
      () => IsoBridgeReady.fromMessage(ready, remoteMenu: true),
      throwsException,
    );
    expect(() => IsoBridgeReady.fromMessage(ready), throwsException);
    ready['mode'] = 'bdj';
    expect(
      () => IsoBridgeReady.fromMessage(ready, remoteMenu: true),
      throwsException,
    );
  });
}
