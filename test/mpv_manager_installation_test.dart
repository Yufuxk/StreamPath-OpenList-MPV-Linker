import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/data/models/playback_media_info.dart';
import 'package:streampath/features/mpv_manager/mpv_document.dart';
import 'package:streampath/features/mpv_manager/mpv_installation.dart';
import 'package:streampath/features/mpv_manager/mpv_script_schema.dart';

void main() {
  late Directory temp, config;
  late String executable;
  void write(String relative, String body) {
    final file = File(p.join(config.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(body);
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('mpv_manager_discovery_');
    executable = p.join(temp.path, 'mpv.exe');
    File(executable).writeAsStringSync('fixture');
    config = Directory(p.join(temp.path, 'portable_config'))..createSync();
  });
  tearDown(() => temp.deleteSync(recursive: true));

  test(
    'script identifiers ignore comments, examples and dynamic expressions',
    () {
      expect(
        scriptOptionsIdentifier('''-- read_options(o, "fake")
local example = "read_options(o, 'example')"
--[=[ read_options(o, "also_fake") ]=]
opt.read_options(o, "actual", callback)''', 'default'),
        'actual',
      );
      expect(
        scriptOptionsIdentifier(
          'read_options(o, "prefix" .. suffix)',
          'default',
        ),
        isNull,
      );
      expect(
        scriptOptionsIdentifier('read_options(o, _, callback)', 'default'),
        'default',
      );
      expect(
        scriptOptionsIdentifier(
          'function options.read_options(t, identifier, callback) end',
          'default',
        ),
        isNull,
      );
    },
  );
  test(
    'inferred script configs must exist and missing references are explicit',
    () async {
      write('scripts/random.lua', 'options.read_options(o, "missing")');
      write('scripts/example.lua', '-- options.read_options(o, "ghost")');
      write(
        'mpv.conf',
        'include=~~/missing.conf\nscripts=;\nglsl-shaders=~~/missing.glsl',
      );
      final installation = await discoverMpv(
        PlayerConfig(name: 'mpv', executable: executable),
      );
      expect(
        installation.files.any(
          (f) =>
              f.path.endsWith('missing.conf') &&
              f.origin == 'include' &&
              !f.exists,
        ),
        isTrue,
      );
      expect(
        installation.files.where(
          (f) => f.kind == MpvDocumentKind.scriptOptions,
        ),
        isEmpty,
      );
      expect(installation.scripts.every((s) => s.configPath == null), isTrue);
      expect(installation.shaders, isEmpty);
      expect(installation.scripts, hasLength(2));
    },
  );

  test(
    'portable directories are found without creating configuration files',
    () async {
      final installation = await discoverMpv(
        PlayerConfig(name: 'mpv', executable: executable),
      );
      expect(installation.roots, [config.path]);
      expect(installation.files.map((f) => p.basename(f.path)), [
        'mpv.conf',
        'input.conf',
      ]);
      expect(File(p.join(config.path, 'mpv.conf')).existsSync(), isFalse);
    },
  );
  test('explicit config-dir and input-conf select the real sources', () async {
    final other = Directory(p.join(temp.path, 'custom'))..createSync();
    final input = File(p.join(temp.path, 'keys.conf'))
      ..writeAsStringSync('a quit');
    final installation = await discoverMpv(
      PlayerConfig(
        name: 'mpv',
        executable: executable,
        args: ['--config-dir=${other.path}', '--input-conf=${input.path}'],
      ),
    );
    expect(installation.roots, [other.path]);
    expect(
      installation.files
          .singleWhere((f) => f.kind == MpvDocumentKind.input)
          .path,
      input.path,
    );
  });
  test('include cycles are bounded and files stay separate', () async {
    write('mpv.conf', 'include=~~/extra.conf\nvolume=20');
    write('extra.conf', 'include=~~/mpv.conf\nvolume=30');
    final installation = await discoverMpv(
      PlayerConfig(name: 'mpv', executable: executable),
    );
    expect(
      installation.files.where((f) => f.kind == MpvDocumentKind.options),
      hasLength(2),
    );
    expect(
      File(p.join(config.path, 'mpv.conf')).readAsStringSync(),
      'include=~~/extra.conf\nvolume=20',
    );
  });
  test(
    'directory scripts, disabled scripts and explicit sources are separate',
    () async {
      write('scripts/x.lua', 'return 1');
      write('scripts/y.js.disable', '1;');
      write('scripts/package/main.lua', 'return 2');
      write('mpv.conf', 'script=~~/scripts/x.lua');
      final installation = await discoverMpv(
        PlayerConfig(name: 'mpv', executable: executable),
      );
      expect(installation.scripts, hasLength(3));
      expect(
        installation.scripts
            .singleWhere((s) => s.path.endsWith('x.lua'))
            .explicit,
        isTrue,
      );
      expect(
        installation.scripts.singleWhere((s) => s.disabled).path,
        endsWith('y.js.disable'),
      );
      expect(
        installation.scripts
            .singleWhere((s) => p.basename(s.path) == 'package')
            .source,
        endsWith('main.lua'),
      );
    },
  );
  test(
    'read_options identifier is used instead of guessing from the filename',
    () async {
      write(
        'scripts/random.lua',
        'local x = {}; require("mp.options").read_options(x, "actual")',
      );
      write('script-opts/actual.conf', 'enabled=yes');
      final installation = await discoverMpv(
        PlayerConfig(name: 'mpv', executable: executable),
      );
      expect(
        installation.scripts.single.configPath,
        p.join(config.path, 'script-opts', 'actual.conf'),
      );
    },
  );
  test('no-config and browse-only states do not imply active files', () async {
    final installation = await discoverMpv(
      PlayerConfig(name: 'mpv', executable: executable, args: ['--no-config']),
    );
    expect(installation.configDisabled, isTrue);
    expect(installation.files.every((f) => !f.active), isTrue);
  });
  test('media category uses the existing injection contract', () async {
    final other = Directory(p.join(temp.path, 'anime'))..createSync();
    final player = PlayerConfig(
      name: 'mpv',
      executable: executable,
      args: ['--config-dir=${other.path}'],
      argInjectionAllEnabled: false,
      argInjectionAnimeEnabled: true,
    );
    expect((await discoverMpv(player)).roots, [config.path]);
    expect(
      (await discoverMpv(
        player,
        mediaInfo: const PlaybackMediaInfo(isSeries: true, isAnime: true),
      )).roots,
      [other.path],
    );
  });
  test('unknown script versions never acquire a guessed typed schema', () {
    expect(
      verifiedScriptSchema('local options = { max_width = 200 }; -- thumbfast'),
      isNull,
    );
    expect(
      scriptOptionsIdentifier(
        'const example = `read_options(o, "fake")`; options.read_options(o, "actual")',
        'default',
      ),
      'actual',
    );
  });
  test(
    'append shader paths are single entries even when containing separators',
    () async {
      write('mpv.conf', 'glsl-shaders-append=~~/shaders/a;b.glsl');
      write('shaders/a;b.glsl', '//!HOOK MAIN');
      final installation = await discoverMpv(
        PlayerConfig(name: 'mpv', executable: executable),
      );
      expect(installation.shaders, [
        p.join(config.path, 'shaders', 'a;b.glsl'),
      ]);
    },
  );
}
