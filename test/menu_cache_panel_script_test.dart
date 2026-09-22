import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/domain/services/remote_menu_playback_service.dart';
import 'package:streampath/presentation/playback/menu_cache_panel_script.dart';

void main() {
  final mpv =
      Platform.environment['STREAMPATH_MENU_MPV'] ??
      'D:/MPV_Player/mpv-yuconfig-20260829/mpv.exe';
  test('禁用默认绑定且 Ctrl+I 已占用时，独立面板快捷键仍可开关', () async {
    final directory = await Directory.systemTemp.createTemp('menu-cache-key-');
    addTearDown(() => directory.delete(recursive: true));
    final panel = await MenuCachePanelScript.write(
      directory,
      AppLanguage.simplifiedChinese,
    );
    final input = File('${directory.path}/input.conf');
    await input.writeAsString('CTRL+I cycle icc-profile-auto\n');
    final output = File('${directory.path}/result.json');
    final probe = File('${directory.path}/probe.lua');
    await probe.writeAsString('''
local mp = require 'mp'
local utils = require 'mp.utils'
local result = {}
mp.add_timeout(0.5, function() mp.commandv('keypress', 'Ctrl+Alt+i') end)
mp.add_timeout(1, function()
    result.opened = mp.get_property_native('user-data/streampath/menu-cache').visible
    result.iccBindingPreserved = false
    for _, binding in ipairs(mp.get_property_native('input-bindings')) do
        if binding.key == 'Ctrl+I' and binding.cmd == 'cycle icc-profile-auto' then
            result.iccBindingPreserved = true
        end
    end
    mp.commandv('keypress', 'Ctrl+Alt+i')
end)
mp.add_timeout(1.5, function()
    result.closed = not mp.get_property_native('user-data/streampath/menu-cache').visible
    local file = assert(io.open(${jsonEncode(output.path)}, 'wb'))
    file:write(utils.format_json(result)); file:close(); mp.commandv('quit')
end)
''');
    final result = await Process.run(mpv, [
      '--no-config',
      '--idle=yes',
      '--vo=null',
      '--ao=null',
      '--input-default-bindings=no',
      '--input-conf=${input.path}',
      '--script=$panel',
      '--script=${probe.path}',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(jsonDecode(await output.readAsString()), {
      'opened': true,
      'closed': true,
      'iccBindingPreserved': true,
    });
  }, skip: !File(mpv).existsSync());
  final lua =
      Platform.environment['STREAMPATH_MENU_LUA'] ??
      'build/remote-menu-toolchain/root/ucrt64/bin/lua.exe';
  test('菜单缓存面板估算、Seek/切集失效与陈旧快照', () async {
    final directory = Directory('build/menu-cache-panel-script');
    await directory.create(recursive: true);
    final script = await MenuCachePanelScript.write(
      directory,
      AppLanguage.simplifiedChinese,
    );
    final result = await Process.run(lua, [
      'tools/winfsp_poc/verify_cache_panel.lua',
      script,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  }, skip: !File(lua).existsSync());

  test('仅菜单启动注入面板并沿用用户语言，独立于进度共享', () async {
    final directory = await Directory.systemTemp.createTemp('menu-cache-args-');
    addTearDown(() => directory.delete(recursive: true));
    const config = PlayerConfig(name: 'MPV', executable: 'mpv.exe');
    final service = RemoteMenuPlaybackService(
      configLoader: () async => config,
      languageLoader: () async => AppLanguage.english,
    );
    final args = await service.prepareArgs(
      config: config,
      sessionDirectory: directory,
      endpoint: File('${directory.path}/disc/disc.iso').uri,
      sessionKey: 'test-disc',
      ipcPipeName: r'\\.\pipe\menu-cache-test',
    );
    final panel = args.singleWhere((arg) => arg.endsWith('sp-menu-cache.lua'));
    expect(
      await File(panel.substring('--script='.length)).readAsString(),
      contains('ISO forward cache'),
    );
    expect(args.last, 'bd://menu');
    expect(args, contains('--demuxer-max-bytes=16777216'));
  });

  test('菜单缓存面板四语言文案', () async {
    final directory = await Directory.systemTemp.createTemp('menu-cache-l10n-');
    addTearDown(() => directory.delete(recursive: true));
    for (final entry in {
      AppLanguage.simplifiedChinese: '估算顺序可读时长',
      AppLanguage.traditionalChinese: '估算順序可讀時長',
      AppLanguage.japanese: '推定連続読み取り時間',
      AppLanguage.english: 'Estimated sequential read duration',
    }.entries) {
      final script = await MenuCachePanelScript.write(directory, entry.key);
      expect(await File(script).readAsString(), contains(entry.value));
    }
  });
}
