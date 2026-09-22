import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/domain/services/iso_subtitle_scripts.dart';

void main() {
  final lua =
      Platform.environment['STREAMPATH_MENU_LUA'] ??
      'build/remote-menu-toolchain/root/ucrt64/bin/lua.exe';
  for (final mode in [
    'title',
    'menu',
    'menu-position',
    'no-select',
    'title-score',
    'menu-score',
  ]) {
    test('ISO Lua 轨道归属、重复事件、切集与过期消息：$mode', () async {
      final dir = await Directory.systemTemp.createTemp('iso-subtitle-lua-');
      addTearDown(() => dir.delete(recursive: true));
      final script = await IsoSubtitleScripts.write(
        dir,
        sessionId: 'test',
        menu: mode.startsWith('menu'),
        autoSelect: mode != 'no-select',
        bindings: {'00001': 'C:/subs/one.ass', '00002': 'C:/subs/two.srt'},
        playlist: mode.startsWith('menu')
            ? []
            : [
                {'id': '00002', 'path': 'http://127.0.0.1/title2'},
                {'id': '00001', 'path': 'http://127.0.0.1/title1'},
              ],
      );
      final result = await Process.run(lua, [
        'tools/verify_iso_subtitles.lua',
        script,
        mode,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    }, skip: !File(lua).existsSync());
  }
}
