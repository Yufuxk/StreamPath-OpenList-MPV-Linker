import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/domain/services/webdav_font_localizer.dart';
import 'package:streampath/domain/services/webdav_font_matcher.dart';

void main() {
  late Directory base;

  setUp(() {
    base = Directory.systemTemp.createTempSync('webdav_fonts_');
  });

  tearDown(() {
    try {
      base.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('远程字体保持原始字节并落入单次会话目录', () async {
    const source = WebDavFontDirectory(
      name: 'Fonts',
      requestPath: 'Series/Fonts',
      entryKey: 'https://example.test/dav/Series/Fonts/',
      files: [
        WebDavFontFile(
          name: 'A',
          url: 'https://example.test/dav/Series/Fonts/A.TTF',
          size: 4,
        ),
        WebDavFontFile(
          name: 'B.otf',
          url: 'https://example.test/dav/Series/Fonts/B.otf',
          size: 3,
        ),
      ],
    );
    final requested = <String>[];

    final result = await const WebDavFontLocalizer().localize(
      source: source,
      base: base,
      sessionId: 'video/session',
      loader: (url, {required maxBytes, required timeout}) async {
        requested.add(url);
        expect(maxBytes, WebDavFontLocalizer.maxFontBytes);
        return url.endsWith('A.TTF') ? [0, 1, 2, 3] : [4, 5, 6];
      },
    );

    expect(result, isNotNull);
    expect(p.basename(result!.directory.path), startsWith('streampath-fonts-'));
    expect(result.files, hasLength(2));
    expect(
      result.files.map((file) => p.extension(file.path)),
      contains('.ttf'),
    );
    expect(requested, hasLength(2));
    final bytes = <List<int>>[];
    for (final file in result.files) {
      bytes.add(await file.readAsBytes());
    }
    expect(bytes, contains(equals([0, 1, 2, 3])));
    expect(bytes, contains(equals([4, 5, 6])));
  });

  test('单个字体失败只跳过该文件', () async {
    const source = WebDavFontDirectory(
      name: 'Fonts',
      requestPath: 'Fonts',
      entryKey: 'https://example.test/dav/Fonts/',
      files: [
        WebDavFontFile(
          name: 'bad.ttf',
          url: 'https://example.test/dav/Fonts/bad.ttf',
          size: 1,
        ),
        WebDavFontFile(
          name: 'good.otf',
          url: 'https://example.test/dav/Fonts/good.otf',
          size: 1,
        ),
      ],
    );

    final result = await const WebDavFontLocalizer().localize(
      source: source,
      base: base,
      sessionId: 'partial',
      loader: (url, {required maxBytes, required timeout}) async {
        if (url.endsWith('bad.ttf')) throw StateError('download failed');
        return [1];
      },
    );

    expect(result?.files, hasLength(1));
    expect(p.extension(result!.files.single.path), '.otf');
  });

  test('没有任何可用字体时不留空目录', () async {
    const source = WebDavFontDirectory(
      name: 'Fonts',
      requestPath: 'Fonts',
      entryKey: 'https://example.test/dav/Fonts/',
      files: [
        WebDavFontFile(
          name: 'bad.ttf',
          url: 'https://example.test/dav/Fonts/bad.ttf',
          size: 1,
        ),
      ],
    );

    final result = await const WebDavFontLocalizer().localize(
      source: source,
      base: base,
      sessionId: 'empty',
      loader: (url, {required maxBytes, required timeout}) =>
          throw StateError('download failed'),
    );

    expect(result, isNull);
    expect(base.listSync(), isEmpty);
  });
}
