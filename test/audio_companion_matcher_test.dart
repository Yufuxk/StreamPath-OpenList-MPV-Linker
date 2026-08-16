import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/domain/services/audio_companion_matcher.dart';
import 'package:streampath/data/models/web_dav_file.dart';

void main() {
  const matcher = AudioCompanionMatcher();
  const audio = WebDavFile(
    name: 'Song 01.FLAC',
    href: '/music/album/Song%2001.FLAC',
    isDirectory: false,
  );

  test('LRC 只匹配同目录同名文件且大小写不敏感', () {
    const files = [
      WebDavFile(
        name: 'song 01.lRc',
        href: '/music/album/song%2001.lRc',
        isDirectory: false,
      ),
      WebDavFile(
        name: 'Song 01.lrc',
        href: '/music/other/Song%2001.lrc',
        isDirectory: false,
      ),
    ];

    final lyrics = matcher.findLyricsFor(audio, files);

    expect(lyrics?.name, 'song 01.lRc');
    expect(lyrics?.url, '/music/album/song%2001.lRc');
  });

  test('外挂封面优先同名，其次使用标准封面名', () {
    const files = [
      WebDavFile(
        name: 'cover.jpg',
        href: '/music/album/cover.jpg',
        isDirectory: false,
      ),
      WebDavFile(
        name: 'Song 01.webp',
        href: '/music/album/Song%2001.webp',
        isDirectory: false,
      ),
    ];

    expect(matcher.findCoverFor(audio, files)?.name, 'Song 01.webp');
    expect(
      matcher.findCoverFor(audio, files.take(1).toList())?.name,
      'cover.jpg',
    );
  });

  test('不同目录或非标准名称的图片不会误配', () {
    const files = [
      WebDavFile(
        name: 'Song 01.jpg',
        href: '/music/other/Song%2001.jpg',
        isDirectory: false,
      ),
      WebDavFile(
        name: 'random.png',
        href: '/music/album/random.png',
        isDirectory: false,
      ),
    ];

    expect(matcher.findCoverFor(audio, files), isNull);
  });
}
