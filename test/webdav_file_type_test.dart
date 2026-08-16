import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/web_dav_file.dart';

/// WebDavFile 类型判定：displayname 丢扩展名 / 与 href 不一致时，
/// 应回退到 href 末段判定（否则字幕/视频会被漏识别）。
void main() {
  group('音频、歌词与封面类型识别', () {
    test('常见音频扩展名均可识别', () {
      for (final name in const [
        'a.mp3',
        'a.FLAC',
        'a.m4a',
        'a.opus',
        'a.ape',
        'a.dsf',
        'a.wv',
        'a.mka',
      ]) {
        final file = WebDavFile(
          name: name,
          href: '/music/$name',
          isDirectory: false,
        );
        expect(file.isAudio, isTrue, reason: name);
        expect(file.isMediaPlayable, isTrue, reason: name);
        expect(file.isPlayable, isFalse, reason: '音频不得混入视频/STRM 列表');
      }
    });

    test('name 缺扩展名时回退 href 识别音频、LRC 与图片', () {
      expect(
        const WebDavFile(
          name: 'track',
          href: '/music/track%2001.FLAC',
          isDirectory: false,
        ).isAudio,
        isTrue,
      );
      expect(
        const WebDavFile(
          name: 'lyrics',
          href: '/music/track%2001.LRC',
          isDirectory: false,
        ).isLyrics,
        isTrue,
      );
      expect(
        const WebDavFile(
          name: 'cover',
          href: '/music/cover.JPEG',
          isDirectory: false,
        ).isCoverArt,
        isTrue,
      );
    });
  });

  group('WebDavFile 类型判定（href 兜底）', () {
    test('name 正常时按 name 判定', () {
      const f = WebDavFile(
        name: 'movie.srt',
        href: '/dav/movie.srt',
        isDirectory: false,
      );
      expect(f.isSubtitle, isTrue);
      expect(f.isVideo, isFalse);
    });

    test('name 丢失扩展名时回退 href 判定字幕', () {
      const f = WebDavFile(
        name: 'movie',
        href: '/dav/movie.srt',
        isDirectory: false,
      );
      expect(f.isSubtitle, isTrue, reason: 'href 末段是 .srt，应识别为字幕');
      expect(f.isVideo, isFalse);
    });

    test('name 丢失扩展名时回退 href 判定视频', () {
      const f = WebDavFile(
        name: 'movie',
        href: '/dav/movie.mkv',
        isDirectory: false,
      );
      expect(f.isVideo, isTrue, reason: 'href 末段是 .mkv，应识别为视频');
    });

    test('href 末段含百分号编码时先解码再判定', () {
      const f = WebDavFile(
        name: 'movie',
        href: '/dav/movie%20%E4%B8%AD%E6%96%87.SRT',
        isDirectory: false,
      );
      expect(f.isSubtitle, isTrue, reason: '解码后为 movie 中文.SRT，应识别为字幕');
    });

    test('name 与 href 扩展名不一致时任一命中即可', () {
      // 服务器 displayname 异常（把 .srt 写成了 .txt），href 才是真相。
      const f = WebDavFile(
        name: 'movie.txt',
        href: '/dav/movie.srt',
        isDirectory: false,
      );
      expect(f.isSubtitle, isTrue);
    });

    test('普通文件两种判定均为 false', () {
      const f = WebDavFile(
        name: 'poster.jpg',
        href: '/dav/poster.jpg',
        isDirectory: false,
      );
      expect(f.isSubtitle, isFalse);
      expect(f.isVideo, isFalse);
    });

    test('sub/sup/idx/smi 扩展名识别为字幕', () {
      for (final ext in ['.sub', '.sup', '.idx', '.smi', '.SRT']) {
        final f = WebDavFile(
          name: 'movie$ext',
          href: '/dav/movie$ext',
          isDirectory: false,
        );
        expect(f.isSubtitle, isTrue, reason: '$ext 应为字幕');
      }
    });
  });

  group('WebDavFile.extension（隐藏后缀过滤用）', () {
    test('name 优先', () {
      const f = WebDavFile(
        name: '01.ass',
        href: '/dav/01.ass',
        isDirectory: false,
      );
      expect(f.extension, '.ass');
    });

    test('name 大写归一为小写', () {
      const f = WebDavFile(
        name: '01.ASS',
        href: '/dav/01.ass',
        isDirectory: false,
      );
      expect(f.extension, '.ass');
    });

    test('name 无扩展名时回退 href 末段（解码后）', () {
      const f = WebDavFile(
        name: 'movie',
        href: '/dav/movie%2Eass',
        isDirectory: false,
      );
      expect(f.extension, '.ass');
    });

    test('目录返回空字符串（不会被过滤）', () {
      const f = WebDavFile(
        name: 'Season 1',
        href: '/dav/Season%201',
        isDirectory: true,
      );
      expect(f.extension, '');
    });
  });
  group('strm 流指针判定', () {
    test('.strm 识别为可播放项', () {
      const f = WebDavFile(
        name: 'movie.strm',
        href: '/dav/movie.strm',
        isDirectory: false,
      );
      expect(f.isStrm, isTrue);
      expect(f.isPlayable, isTrue);
      expect(f.isVideo, isFalse);
      expect(f.isSubtitle, isFalse);
    });

    test('name 丢扩展名时回退 href 判定 strm', () {
      const f = WebDavFile(
        name: 'movie',
        href: '/dav/movie.strm',
        isDirectory: false,
      );
      expect(f.isStrm, isTrue);
      expect(f.isPlayable, isTrue);
    });

    test('视频仍是可播放项', () {
      const f = WebDavFile(
        name: 'movie.mkv',
        href: '/dav/movie.mkv',
        isDirectory: false,
      );
      expect(f.isPlayable, isTrue);
      expect(f.isStrm, isFalse);
    });
  });
}
