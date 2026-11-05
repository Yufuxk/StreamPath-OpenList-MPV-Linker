import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/features/mpv_manager/mpv_document.dart';
import 'package:streampath/features/mpv_manager/mpv_installation.dart';

MpvDocumentSnapshot document(
  String text, [
  MpvDocumentKind kind = MpvDocumentKind.options,
]) => MpvDocumentSnapshot.parse('test.conf', utf8.encode(text), kind);

void main() {
  group('Lossless MPV documents', () {
    test('unchanged bytes include BOM, mixed newlines and final EOF', () {
      final doc = document(
        '\uFEFF# 字幕\r\n sub-font-size = 38  # 字号\n[anime]\r\nvo=gpu',
      );
      expect(doc.apply([]), doc.bytes);
      expect(
        doc.apply(doc.setValue(doc.entries.first, '42')),
        utf8.encode(
          '\uFEFF# 字幕\r\n sub-font-size = 42  # 字号\n[anime]\r\nvo=gpu',
        ),
      );
    });
    test('only selected duplicate is changed', () {
      final doc = document(
        'volume=20\nvolume=30\n[a]\nvolume=40\n[a]\nvolume=50\n',
      );
      expect(
        utf8.decode(doc.apply(doc.setValue(doc.entries.elementAt(2), '41'))),
        'volume=20\nvolume=30\n[a]\nvolume=41\n[a]\nvolume=50\n',
      );
      expect(doc.entries.map((l) => l.block), [0, 0, 1, 2]);
    });
    test('quoted hashes and unchanged quote style survive', () {
      final doc = document('osd-msg1 = "a # b"  # note\n');
      expect(doc.entries.single.value, 'a # b');
      expect(
        utf8.decode(doc.apply(doc.setValue(doc.entries.single, 'c # d'))),
        'osd-msg1 = "c # d"  # note\n',
      );
    });
    test('quote changes affect only the value token', () {
      final doc = document('osd-msg1="hello" # note');
      expect(
        utf8.decode(doc.apply(doc.setValue(doc.entries.single, 'say "hello"'))),
        'osd-msg1=\'say "hello"\' # note',
      );
    });
    test('fixed length values use UTF8 bytes', () {
      final doc = document('osd-msg1 = %6%中文  # note\r\n');
      expect(doc.entries.single.value, '中文');
      expect(
        utf8.decode(doc.apply(doc.setValue(doc.entries.single, '字幕值'))),
        'osd-msg1 = %9%字幕值  # note\r\n',
      );
    });
    test('invalid fixed lengths and unknown syntax remain opaque', () {
      final doc = document('osd-msg1=%999%x\nthis is not valid\nvolume=20');
      expect(doc.lines.where((l) => l.kind == MpvLineKind.invalid).length, 2);
      expect(
        utf8.decode(doc.apply(doc.setValue(doc.entries.single, '21'))),
        'osd-msg1=%999%x\nthis is not valid\nvolume=21',
      );
    });
    test('invalid UTF8 cannot be edited', () {
      final doc = MpvDocumentSnapshot.parse('x', [
        255,
        254,
      ], MpvDocumentKind.options);
      expect(doc.text, isNull);
      expect(() => doc.apply([]), throwsA(isA<MpvManagerException>()));
    });
    test('bare flags gain an equals sign', () {
      final doc = document('  fullscreen\r\n');
      expect(
        utf8.decode(doc.apply(doc.setValue(doc.entries.single, 'no'))),
        '  fullscreen=no\r\n',
      );
    });
    test(
      'bare flag switches can round-trip without rewriting its spelling',
      () {
        final doc = document('  fullscreen\r\n');
        final disabled = doc.apply(doc.setEnabled(doc.entries.single, false));
        final parsed = MpvDocumentSnapshot.parse(doc.path, disabled, doc.kind);
        expect(parsed.entries.single.enabled, isFalse);
        expect(
          parsed.apply(parsed.setEnabled(parsed.entries.single, true)),
          doc.bytes,
        );
      },
    );
    test('enable and disable preserve dash prefixes and spaces', () {
      final doc = document('  #  --volume = 20 # note\r\n');
      final enabled = doc.apply(doc.setEnabled(doc.entries.single, true));
      expect(utf8.decode(enabled), '    --volume = 20 # note\r\n');
      final active = document('  --volume = 20 # note\r\n');
      expect(
        utf8.decode(
          active.apply(active.setEnabled(active.entries.single, false)),
        ),
        '  #--volume = 20 # note\r\n',
      );
    });
    test('global additions precede the first profile', () {
      final doc = document('# note\r\n[a]\r\nvo=gpu\r\n');
      expect(
        utf8.decode(doc.apply(doc.addEntry('volume', '30'))),
        '# note\r\nvolume=30\r\n[a]\r\nvo=gpu\r\n',
      );
    });
    test('selected repeated profile gets the new entry', () {
      final doc = document('[a]\nvolume=10\n[a]\nvolume=20');
      expect(
        utf8.decode(doc.apply(doc.addEntry('vo', 'gpu', block: 1))),
        '[a]\nvolume=10\nvo=gpu\n[a]\nvolume=20',
      );
    });
    test('new values with both quote styles use byte quoting', () {
      final doc = document('');
      final result = utf8.decode(doc.apply(doc.addEntry('osd-msg1', '中#"\'')));
      final parsed = document(result);
      expect(parsed.entries.single.value, '中#"\'');
    });
    test('raw editing preserves original BOM', () {
      final doc = document('\uFEFFvolume=20\r\n# note');
      expect(
        doc.apply(doc.replaceText('volume=30\r\n# note')),
        utf8.encode('\uFEFFvolume=30\r\n# note'),
      );
    });
    test('overlapping or stale patches fail explicitly', () {
      final doc = document('volume=20');
      expect(
        () => doc.apply([doc.edit(0, 4, []), doc.edit(2, 5, [])]),
        throwsA(isA<MpvManagerException>()),
      );
      expect(
        () => doc.apply([
          const MpvTextEdit(0, 1, [1], [2]),
        ]),
        throwsA(isA<MpvManagerException>()),
      );
    });
    test('no-op updates do not make patches', () {
      final doc = document('volume=20');
      expect(doc.setValue(doc.entries.single, '20'), isEmpty);
      expect(doc.replaceText('volume=20'), isEmpty);
    });
  });
  group('Input syntax', () {
    test(
      'menu annotations stop at a trailing unquoted hash without rewriting it',
      () {
        const source =
            'h cycle hdr-compute-peak #menu: 画面 > HDR 相关 > 切换 HDR 动态映射  #@state=(hdr_compute_peak and \'checked\')\r\n';
        final doc = document(source, MpvDocumentKind.input);
        final line = doc.entries.single;
        expect(line.menuPath, '画面 > HDR 相关 > 切换 HDR 动态映射');
        expect(
          utf8.decode(doc.apply(doc.setMenuPath(line, '画面 > HDR > 新名称'))),
          source.replaceFirst('画面 > HDR 相关 > 切换 HDR 动态映射', '画面 > HDR > 新名称'),
        );
        expect(
          utf8.decode(
            doc.apply(doc.setValue(line, 'cycle target-colorspace-hint')),
          ),
          source.replaceFirst(
            'cycle hdr-compute-peak',
            'cycle target-colorspace-hint',
          ),
        );
        final quoted = document(
          'h ignore #! Menu > "Title # literal" # tail',
          MpvDocumentKind.input,
        );
        expect(quoted.entries.single.menuPath, 'Menu > "Title # literal"');
      },
    );
    test('menu metadata edits preserve commands, quotes, BOM and newlines', () {
      const original =
          '\uFEFFCtrl+a {menu} show-text "中#menu:文"  #menu: 着色器 > Anime4K > 开/关  \r\n';
      final doc = document(original, MpvDocumentKind.input);
      final line = doc.entries.single;
      expect(line.menuPath, '着色器 > Anime4K > 开/关');
      expect(line.value, 'show-text "中#menu:文"');
      expect(
        doc.apply(doc.setMenuPath(line, '视频 > 切换')),
        utf8.encode(original.replaceFirst('着色器 > Anime4K > 开/关', '视频 > 切换')),
      );
      expect(
        doc.apply(doc.setValue(line, 'seek 2')),
        utf8.encode(original.replaceFirst('show-text "中#menu:文"', 'seek 2')),
      );
    });
    test('menu-only commands and separators retain their literal hash', () {
      final doc = document(
        '#  cycle ontop #! Window > On top\n#  #menu: Window > ---\n# ordinary "#menu: example"\n',
        MpvDocumentKind.input,
      );
      expect(doc.entries, hasLength(2));
      expect(doc.entries.every((e) => e.menuOnly && e.enabled), isTrue);
      expect(doc.entries.last.value, isEmpty);
      expect(
        utf8.decode(doc.apply(doc.setValue(doc.entries.last, 'ignore'))),
        contains('#  ignore #menu: Window > ---'),
      );
    });
    test('sections and quoted hashes keep original command spans', () {
      final doc = document(
        'Ctrl+a {menu} show-text "中#文" ; seek 2  # note\r\n',
        MpvDocumentKind.input,
      );
      final line = doc.entries.single;
      expect(line.inputSection, 'menu');
      expect(line.value, 'show-text "中#文" ; seek 2');
      expect(
        utf8.decode(doc.apply(doc.setKey(line, 'Ctrl+b'))),
        'Ctrl+b {menu} show-text "中#文" ; seek 2  # note\r\n',
      );
    });
    test('disabled bindings and menu-only entries stay distinct', () {
      final doc = document(
        '#F1 show-text "x"\n#    show-text "menu" #menu: tools\n',
        MpvDocumentKind.input,
      );
      expect(doc.entries.length, 2);
      expect(doc.entries.first.enabled, isFalse);
      expect(doc.entries.last.menuOnly, isTrue);
      expect(doc.entries.last.menuPath, 'tools');
    });
    test('new unquoted comments cannot silently swallow commands', () {
      final doc = document('a show-text "old"', MpvDocumentKind.input);
      expect(
        () => doc.setValue(doc.entries.single, 'show-text abc # quit'),
        throwsA(isA<MpvManagerException>()),
      );
    });
    test('unicode key positions are byte positions', () {
      final doc = document('中 show-text "x" # note', MpvDocumentKind.input);
      expect(
        utf8.decode(doc.apply(doc.setKey(doc.entries.single, '文'))),
        '文 show-text "x" # note',
      );
    });
  });
  group('Script option dialect', () {
    test('inline hashes and quotes are literal values', () {
      final doc = document(
        'title="hello" # literal\n',
        MpvDocumentKind.scriptOptions,
      );
      expect(doc.entries.single.value, '"hello" # literal');
      expect(
        utf8.decode(doc.apply(doc.setValue(doc.entries.single, 'a#b'))),
        'title=a#b\n',
      );
    });
    test('spaces in script option names and values remain significant', () {
      final doc = document(' key = value  \r\n', MpvDocumentKind.scriptOptions);
      expect(doc.entries.single.key, ' key ');
      expect(doc.entries.single.value, ' value  ');
    });
    test('section-like strings are not profile headers', () {
      final doc = document('[theme]\ntitle=x', MpvDocumentKind.scriptOptions);
      expect(doc.lines.first.kind, MpvLineKind.invalid);
      expect(doc.entries.single.scope, '');
    });
  });
  group('Mpv list and option metadata', () {
    test('escaped path separators do not create extra files', () {
      expect(splitMpvPaths(r'A\;B;C'), ['A;B', 'C']);
      expect(splitMpvPathTokens(r'A\;B;C'), [r'A\;B', 'C']);
    });
    test('range validators use the current build metadata', () {
      const info = MpvOptionInfo('x', 'Float', 38, 1, 9000, []);
      expect(info.validate('42.5'), isNull);
      expect(info.validate('0'), 'number');
      expect(info.validate('NaN'), 'number');
      expect(info.validate('Infinity'), 'number');
    });
  });
}
