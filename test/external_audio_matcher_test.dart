import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/media_directory_entry.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/domain/services/external_audio_matcher.dart';

void main() {
  const base = 'https://example.test/dav';
  const matcher = ExternalAudioMatcher();
  WebDavFile file(String name, {String? href, bool directory = false}) =>
      WebDavFile(
        name: name,
        href: href ?? '/dav/$name',
        isDirectory: directory,
      );

  test('完整主名、分隔符、自然排序与 URL 去重', () {
    final audio = matcher.matchFor(file('Movie.mkv'), [
      file('movie.track10.flac'),
      file('MOVIE.track2.MKA'),
      file('movie.flac'),
      file('duplicate.flac', href: '/dav/movie.flac'),
      file('movie.flac'),
      file('movie2.flac'),
      file('movieOST.flac'),
      file('movie.zh.mka', directory: true),
      file('movie.zh.ass'),
    ], baseUrl: base);
    expect(audio.map((track) => track.name), [
      'movie.flac',
      'MOVIE.track2.MKA',
      'movie.track10.flac',
    ]);
    expect(audio.first.url, '$base/movie.flac');
  });

  test('集数边界、中文与 STRM 使用自身主名', () {
    final audio = matcher.matchFor(file('作品.S01E01.strm'), [
      file('作品.S01E01.国语.ac3'),
      file('作品.S01E010.ac3'),
      file('作品.S01E02.ac3'),
      file('作品.S01E01（日语）.flac'),
      file('实际远程视频.flac'),
    ], baseUrl: base);
    expect(audio.map((track) => track.name), [
      '作品.S01E01.国语.ac3',
      '作品.S01E01（日语）.flac',
    ]);
  });

  test('仅接收同源同父目录，保留服务器 URL 编码', () {
    final audio = matcher
        .matchFor(file('movie.mkv', href: '$base/A%20B/movie.mkv'), [
          file('movie.flac', href: '$base/A%20B/movie.flac'),
          file('movie.ac3', href: '$base/A%20B/Audio/movie.ac3'),
          file('movie.dts', href: 'https://foreign.test/dav/A%20B/movie.dts'),
          file('movie.mka', href: 'http://example.test/dav/A%20B/movie.mka'),
          file(
            'movie.mp3',
            href: 'https://example.test:8443/dav/A%20B/movie.mp3',
          ),
        ], baseUrl: base);
    expect(audio.single.url, '$base/A%20B/movie.flac');
  });

  test('本地条目与跨来源原视频不参与匹配', () {
    const local = LocalMediaEntry(
      name: 'movie.flac',
      relativePath: '/dav/movie.flac',
      absolutePath: r'C:\movie.flac',
      isDirectory: false,
    );
    expect(
      matcher.matchFor(file('movie.mkv'), [local], baseUrl: base),
      isEmpty,
    );
    expect(
      matcher.matchFor(local, [file('movie.flac')], baseUrl: base),
      isEmpty,
    );
    expect(
      matcher.matchFor(
        file('movie.mkv', href: 'https://foreign.test/dav/movie.mkv'),
        [file('movie.flac')],
        baseUrl: base,
      ),
      isEmpty,
    );
  });
}
