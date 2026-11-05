import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/features/mpv_manager/mpv_installation.dart';

void main() {
  for (final folder in [
    'mpv-0.34.0-x86_64',
    'mpv-v0.41.0-x86_64-pc-windows-msvc',
  ]) {
    final executable = p.absolute(
      'cross_version_testing',
      '打包版本',
      folder,
      'mpv.exe',
    );
    test(
      'isolated metadata probe supports $folder',
      () async {
        final probe = MpvCapabilityProbe();
        try {
          final result = await probe.read(executable, {
            'sub-font-size',
            'volume',
            'glsl-shaders',
          });
          expect(result.version, contains('mpv'));
          expect(result.optionNames, contains('sub-font-size'));
          expect(result.options['sub-font-size']!.type, 'Float');
          expect(result.options['sub-font-size']!.minimum, 1);
          expect(result.commands, contains('quit'));
          expect(result.keys, contains('LEFT'));
        } finally {
          await probe.close();
        }
      },
      skip: !Platform.isWindows || !File(executable).existsSync()
          ? 'Local MPV fixture is unavailable.'
          : false,
    );
  }
}
