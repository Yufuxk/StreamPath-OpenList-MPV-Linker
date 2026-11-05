import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'mpv_installation.dart';

class MpvScriptSchema {
  const MpvScriptSchema(this.identifier, this.options);
  final String identifier;
  final Map<String, MpvOptionInfo> options;
}

MpvOptionInfo _flag(String name, bool value) =>
    MpvOptionInfo(name, 'Flag', value ? 'yes' : 'no', null, null, const []);
MpvOptionInfo _number(String name, num value) =>
    MpvOptionInfo(name, 'Float', value, null, null, const []);

/// 仅接受核验过的完整源码；未知版本继续使用通用键值编辑。
MpvScriptSchema? verifiedScriptSchema(String source) {
  final digest = sha256
      .convert(utf8.encode(source.replaceAll('\r\n', '\n')))
      .toString();
  return switch (digest) {
    // https://github.com/tomasklaen/uosc/blob/main/src/uosc/main.lua (5.13.0)
    '40b84907c4c7fc243ae8b721165b573a132225e934b5c82eff4db7da0369d2fe' =>
      MpvScriptSchema('uosc', {
        'timeline_style': const MpvOptionInfo(
          'timeline_style',
          'Choices',
          'line',
          null,
          null,
          ['line', 'bar'],
        ),
        'timeline_size': _number('timeline_size', 40),
        'scale': _number('scale', 1),
        'scale_fullscreen': _number('scale_fullscreen', 1.3),
        'font_scale': _number('font_scale', 1),
        'autoload': _flag('autoload', false),
        'menu_type_to_search': _flag('menu_type_to_search', true),
      }),
    // https://github.com/po5/thumbfast/blob/master/thumbfast.lua
    'a3d08e71eae8b892f6cd39f9593ea219768e709312d176bca883841b156448bf' =>
      MpvScriptSchema('thumbfast', {
        'max_width': _number('max_width', 200),
        'max_height': _number('max_height', 200),
        'scale_factor': _number('scale_factor', 1),
        'spawn_first': _flag('spawn_first', false),
        'network': _flag('network', false),
        'audio': _flag('audio', false),
        'hwdec': _flag('hwdec', false),
      }),
    // https://github.com/mpv-player/mpv/blob/v0.41.0/TOOLS/lua/autoload.lua
    'c0ef5ac2c928f6a0d3464c14a403104968d7339cb1ed7cda642945f8420d8744' =>
      MpvScriptSchema('autoload', {
        'disabled': _flag('disabled', false),
        'images': _flag('images', true),
        'videos': _flag('videos', true),
        'audio': _flag('audio', true),
        'ignore_hidden': _flag('ignore_hidden', true),
        'same_type': _flag('same_type', false),
      }),
    _ => null,
  };
}
