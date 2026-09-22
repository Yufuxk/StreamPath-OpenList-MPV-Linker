import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/domain/services/iso_subtitle_scripts.dart';

void main() {
  final executable = Platform.environment['STREAMPATH_MENU_MPV'];
  final disc = Platform.environment['STREAMPATH_MENU_BDMV'];
  for (final menu in [false, true]) {
    test(
      '实体 MPV ISO 字幕时间轴与${menu ? "菜单/同长度切换" : "主标题/Seek"}',
      () async {
        final dir = await Directory.systemTemp.createTemp('iso-subtitle-real-');
        addTearDown(() => dir.delete(recursive: true));
        final bindings = <String, String>{};
        for (final id in ['00001', '00002', '00003']) {
          final sub = File('${dir.path}/$id.${id == '00003' ? 'ass' : 'srt'}');
          await sub.writeAsString(
            id == '00003'
                ? '''[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,54,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,20,20,30,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:08.00,Default,,0,0,0,,00003 START
'''
                : '1\n00:00:00,000 --> 00:00:08,000\n$id START\n\n2\n00:02:00,000 --> 00:02:10,000\n$id SEEK\n',
          );
          bindings[id] = sub.path;
        }
        final fonts = Directory('${dir.path}/fonts')..createSync();
        await File(
          r'C:\Windows\Fonts\arial.ttf',
        ).copy('${fonts.path}/test.ttf');
        final script = await IsoSubtitleScripts.write(
          dir,
          sessionId: 'real',
          menu: menu,
          autoSelect: true,
          bindings: bindings,
          playlist: [],
          fontDirectory: fonts.path,
        );
        final output = File('${dir.path}/result.json');
        final probe = File('${dir.path}/probe.lua');
        final start = menu ? 30 : 0;
        await probe.writeAsString('''
local mp=require 'mp'
local utils=require 'mp.utils'
local results={}
local function sample(label)
  results[label]={state=mp.get_property_native('user-data/streampath/iso-subtitles'),
    text=mp.get_property('sub-text'), sid=mp.get_property_native('sid'),
    menu=mp.get_property_native('disc-menu-active'), edition=mp.get_property_native('current-edition'),
    tracks=mp.get_property_native('track-list'), position=mp.get_property_native('time-pos'),
    fonts=mp.get_property('sub-fonts-dir')}
end
local function finish()
  local file=assert(io.open(${jsonEncode(output.path)},'wb'))
  file:write(utils.format_json(results)); file:close(); mp.commandv('quit')
end
${menu ? "mp.add_timeout(2,function() sample('intro') end)\nmp.add_timeout(27,function() sample('top'); mp.commandv('discnav','select') end)\nmp.add_timeout(30,function() mp.set_property_number('edition',1) end)" : ''}
mp.add_timeout(${start + 3},function() sample('start'); mp.commandv('seek',123,'absolute+exact') end)
mp.add_timeout(${start + 6},function() sample('seek'); mp.set_property('sid','no') end)
mp.add_timeout(${start + 7},function() sample('manual') ${menu ? "; mp.set_property_number('edition',2)" : ''} end)
${menu ? "mp.add_timeout(40,function() sample('second'); mp.set_property_number('edition',3) end)\nmp.add_timeout(43,function() sample('third'); mp.commandv('discnav','menu') end)" : ''}
mp.add_timeout(${menu ? 53 : 9},function()
  sample('return')
  ${menu ? "mp.set_property_number('edition',1)" : 'finish()'}
end)
${menu ? "mp.add_timeout(56,function() mp.commandv('discnav','popup') end)\nmp.add_timeout(57,function() sample('popup') end)\nmp.add_timeout(59,function() mp.commandv('discnav','popup') end)\nmp.add_timeout(61,function() sample('popup-closed'); finish() end)" : ''}
''');
        final player = await Process.start(executable!, [
          '--no-config',
          '--vo=null',
          '--ao=null',
          '--idle=no',
          '--keep-open=no',
          '--sub-auto=no',
          '--script=$script',
          '--script=${probe.path}',
          '--bluray-device=$disc',
          menu ? 'bd://menu' : 'bd://longest',
        ]);
        final stdout = player.stdout.transform(utf8.decoder).join();
        final stderr = player.stderr.transform(utf8.decoder).join();
        try {
          expect(await player.exitCode.timeout(const Duration(seconds: 75)), 0);
          final logs = Directory('build/iso-subtitle-tests')
            ..createSync(recursive: true);
          await File(
            '${logs.path}/${menu ? "menu" : "title"}.log',
          ).writeAsString('${await stdout}\n${await stderr}');
          final result = jsonDecode(await output.readAsString()) as Map;
          await File(
            '${logs.path}/${menu ? "menu" : "title"}.json',
          ).writeAsString(jsonEncode(result));
          expect(result['start']['state']['current'], '00001');
          expect(result['start']['text'], contains('00001 START'));
          expect(result['seek']['text'], contains('00001 SEEK'));
          expect(result['manual']['sid'], isFalse);
          if (menu) {
            expect(result['second']['text'], contains('00002 START'));
            expect(result['third']['text'], contains('00003 START'));
            expect(result['intro']['state']['current'], '');
            // 此盘 First Play 自动进入正片，不保证先显示 Top Menu。
            expect(result['top']['state']['current'], '00001');
            expect(result['return']['menu'], isTrue);
            expect(result['return']['state']['track'], -1);
            if (result['popup']['menu'] == true) {
              expect(result['popup']['state']['track'], -1);
            } else {
              // 本盘没有产生弹出菜单叠层；无效菜单命令不得卸载正片字幕。
              expect(result['popup']['state']['track'], greaterThan(0));
              // ignore: avoid_print
              print(
                'Popup overlay was not emitted by this disc; overlay transitions remain Lua-tested only.',
              );
            }
            expect(result['popup-closed']['menu'], isFalse);
            expect(result['popup-closed']['state']['track'], greaterThan(0));
            expect(result['third']['fonts'], fonts.path);
          }
        } finally {
          player.kill();
          await player.exitCode;
        }
      },
      skip: executable == null || disc == null,
      timeout: const Timeout(Duration(seconds: 85)),
    );
  }
}
