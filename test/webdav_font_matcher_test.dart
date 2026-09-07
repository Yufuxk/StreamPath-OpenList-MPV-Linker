import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/domain/services/webdav_font_matcher.dart';

void main() {
  const matcher = WebDavFontMatcher();
  const baseUrl = 'https://example.test/dav';
  const video = WebDavFile(
    name: 'Episode 01.mkv',
    href: 'https://example.test/dav/Series/Episode%2001.mkv',
    isDirectory: false,
  );

  WebDavFile directory(String name, String href) =>
      WebDavFile(name: name, href: href, isDirectory: true);

  group('WebDavFontMatcher 字体目录识别', () {
    for (final name in const [
      'Font',
      'Fonts',
      'font',
      'fonts',
      '字体',
      '字体文件',
      '字体备份',
      '字幕字体',
      '字体——',
      'Subtitle Fonts',
      'ASS_Fonts',
      '字體',
      'フォント',
      '폰트',
    ]) {
      test('识别 $name', () {
        final match = matcher.findBestFor(video, [
          video,
          directory(name, 'https://example.test/dav/Series/$name/'),
        ], baseUrl: baseUrl);

        expect(match, isNotNull);
        expect(match!.name, name);
      });
    }

    test('优先使用字幕专用目录，备份目录只作低优先级候选', () {
      final match = matcher.findBestFor(video, [
        video,
        directory(
          '字体备份',
          'https://example.test/dav/Series/%E5%AD%97%E4%BD%93%E5%A4%87%E4%BB%BD/',
        ),
        directory('Fonts', 'https://example.test/dav/Series/Fonts/'),
        directory(
          '字幕字体',
          'https://example.test/dav/Series/%E5%AD%97%E5%B9%95%E5%AD%97%E4%BD%93/',
        ),
      ], baseUrl: baseUrl);

      expect(match?.name, '字幕字体');
    });

    test('拒绝媒体父目录以外的同名字体目录', () {
      final match = matcher.findBestFor(video, [
        video,
        directory('Fonts', 'https://example.test/dav/Other/Fonts/'),
        directory('Fonts', 'https://other.test/dav/Series/Fonts/'),
      ], baseUrl: baseUrl);

      expect(match, isNull);
    });

    test('绝对与相对 href 混用时仍按同级目录匹配', () {
      final match = matcher.findBestFor(video, [
        video,
        directory('Fonts', '/dav/Series/Fonts/'),
      ], baseUrl: baseUrl);

      expect(match?.requestPath, 'Series/Fonts');
    });

    test('不对包含 font 的任意目录做模糊命中', () {
      final match = matcher.findBestFor(video, [
        video,
        directory(
          'Old Fonts 2024',
          'https://example.test/dav/Series/Old%20Fonts%202024/',
        ),
      ], baseUrl: baseUrl);

      expect(match, isNull);
    });
  });

  test('只返回命中字体目录的直属字体文件', () {
    final folder = matcher.findBestFor(video, [
      video,
      directory('Fonts', 'https://example.test/dav/Series/Fonts/'),
    ], baseUrl: baseUrl)!;

    final resolved = matcher.withDirectFontFiles(folder, const [
      WebDavFile(
        name: 'A.TTF',
        href: 'https://example.test/dav/Series/Fonts/A.TTF',
        isDirectory: false,
        size: 10,
      ),
      WebDavFile(
        name: 'B.otc',
        href: 'https://example.test/dav/Series/Fonts/B.otc',
        isDirectory: false,
        size: 20,
      ),
      WebDavFile(
        name: 'note.txt',
        href: 'https://example.test/dav/Series/Fonts/note.txt',
        isDirectory: false,
      ),
      WebDavFile(
        name: 'nested.ttf',
        href: 'https://example.test/dav/Series/Fonts/Backup/nested.ttf',
        isDirectory: false,
      ),
      WebDavFile(
        name: 'foreign.ttf',
        href: 'https://other.test/dav/Series/Fonts/foreign.ttf',
        isDirectory: false,
      ),
    ], baseUrl: baseUrl);

    expect(resolved.files.map((file) => file.name), ['A.TTF', 'B.otc']);
    expect(resolved.files.map((file) => file.size), [10, 20]);
  });

  test('相对文件 href 也必须是命中目录的直属文件', () {
    final folder = matcher.findBestFor(video, [
      video,
      directory('Fonts', '/dav/Series/Fonts/'),
    ], baseUrl: baseUrl)!;

    final resolved = matcher.withDirectFontFiles(folder, const [
      WebDavFile(
        name: 'A.ttf',
        href: '/dav/Series/Fonts/A.ttf',
        isDirectory: false,
      ),
      WebDavFile(
        name: 'B.ttf',
        href: '/dav/Other/Fonts/B.ttf',
        isDirectory: false,
      ),
    ], baseUrl: baseUrl);

    expect(resolved.files.map((file) => file.name), ['A.ttf']);
  });
}
