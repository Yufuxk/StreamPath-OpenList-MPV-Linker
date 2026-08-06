import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/subtitle_item.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/domain/services/subtitle_matcher.dart';

void main() {
  const matcher = SubtitleMatcher();

  WebDavFile sub(String name, {String? href}) =>
      WebDavFile(name: name, href: href ?? '/dav/$name', isDirectory: false);

  WebDavFile media(String name, {String? href}) =>
      WebDavFile(name: name, href: href ?? '/dav/$name', isDirectory: false);

  group('SubtitleMatcher 匹配', () {
    test('完全同名（大小写不敏感）匹配为 exact', () {
      final result = matcher.matchFor(media('Movie.MKV'), [sub('movie.srt')]);
      expect(result, hasLength(1));
      expect(result.first.language, SubtitleLanguage.exact);
      expect(result.first.name, 'movie.srt');
    });

    test('中文语言后缀识别（zh / chs / zh-Hans）', () {
      for (final suffix in ['zh', 'chs', 'sc', 'zh-Hans', 'zh-hant']) {
        final result = matcher.matchFor(media('movie.mp4'), [sub('movie.$suffix.srt')]);
        expect(result, hasLength(1), reason: '后缀 $suffix 应匹配');
        expect(
          result.first.language,
          SubtitleLanguage.chinese,
          reason: '后缀 $suffix 应为中文',
        );
      }
    });

    test('GB / 简体 / 繁体 等中文标签识别', () {
      for (final suffix in [
        'GB',
        'gbk',
        'big5',
        '简体',
        '繁体',
        '简',
        '繁',
        '简中',
        '繁中',
        '中英',
        '双语',
        'bilingual',
      ]) {
        final result = matcher.matchFor(media('movie.mp4'), [sub('movie.$suffix.srt')]);
        expect(result, hasLength(1), reason: '后缀 $suffix 应匹配');
        expect(
          result.first.language,
          SubtitleLanguage.chinese,
          reason: '后缀 $suffix 应为中文',
        );
      }
    });

    test('其他语言后缀识别（en / ja）', () {
      final result = matcher.matchFor(media('movie.mp4'), [
        sub('movie.en.srt'),
        sub('movie.ja.ass'),
      ]);
      expect(result, hasLength(2));
      expect(result.every((s) => s.language == SubtitleLanguage.other), isTrue);
    });

    test('不匹配无关文件（同名不同视频/普通文件）', () {
      final result = matcher.matchFor(media('movie.mp4'), [
        sub('movie2.srt'),
        sub('readme.txt'),
        sub('poster.jpg'),
        sub('other.zh.srt'),
      ]);
      expect(result, isEmpty);
    });

    test('优先级：完全同名 > 中文 > 其他语言', () {
      final result = matcher.matchFor(media('movie.mp4'), [
        sub('movie.en.srt'),
        sub('movie.zh.srt'),
        sub('movie.srt'),
      ]);
      expect(result, hasLength(3));
      expect(result[0].name, 'movie.srt');
      expect(result[1].name, 'movie.zh.srt');
      expect(result[2].name, 'movie.en.srt');
    });

    test('findBestFor 返回最佳字幕，无匹配返回 null', () {
      expect(
        matcher.findBestFor(media('movie.mp4'), [sub('movie.zh.srt')])?.name,
        'movie.zh.srt',
      );
      expect(matcher.findBestFor(media('movie.mp4'), [sub('x.srt')]), isNull);
    });

    test('视频带版本号片段也可匹配语言后缀', () {
      final result = matcher.findBestFor(media('movie.2024.1080p.mkv'), [
        sub('movie.2024.1080p.chs.ass'),
      ]);
      expect(result, isNotNull);
      expect(result!.language, SubtitleLanguage.chinese);
    });

    test('vtt/ass/ssa 扩展名均视为字幕', () {
      final result = matcher.matchFor(media('video.webm'), [
        sub('video.vtt'),
        sub('video.zh.ass'),
        sub('video.en.ssa'),
      ]);
      expect(result, hasLength(3));
    });

    test('sub/sup/idx/smi 扩展名也视为字幕', () {
      final result = matcher.matchFor(media('video.mkv'), [
        sub('video.sub'), // MicroDVD
        sub('video.sup'), // PGS
        sub('video.idx'), // VobSub 索引
        sub('video.smi'),
      ]);
      expect(result, hasLength(4));
      expect(result.every((s) => s.language == SubtitleLanguage.exact), isTrue);
    });

    // ── 相似名称 ────────────────────────────────────────────────

    test('相似名称：字幕是视频名的段前缀（视频带版本信息）', () {
      final result = matcher.findBestFor(media('My.Movie.2024.1080p.BluRay.mkv'), [
        sub('My.Movie.chs.srt'),
      ]);
      expect(result, isNotNull, reason: '字幕核心名是视频核心名的段前缀');
      expect(result!.language, SubtitleLanguage.chinese);
    });

    test('相似名称：视频是字幕名的段前缀（字幕带版本信息）', () {
      final result = matcher.findBestFor(media('movie.mkv'), [
        sub('movie.2024.1080p.chs.srt'),
        sub('movie.2024.1080p.srt'), // 无语言标签的默认字幕
      ]);
      expect(result, isNotNull);
      // 中文标签优先于无标签。
      expect(result!.name, 'movie.2024.1080p.chs.srt');
      expect(result.language, SubtitleLanguage.chinese);
    });

    test('相似名称：公共段前缀（集数写法不同 S01E01 vs 01）', () {
      final result = matcher.findBestFor(media('My.Series.S01E01.mkv'), [
        sub('My.Series.01.chs.srt'),
      ]);
      expect(result, isNotNull);
      expect(result!.language, SubtitleLanguage.chinese);
    });

    test('单段剧名与纯数字字幕可按同集匹配', () {
      expect(
        matcher.findBestFor(media('Show.S01E01.mkv'), [sub('Show.01.chs.srt')]),
        isNotNull,
      );
      expect(matcher.findBestFor(media('S01E01.mkv'), [sub('01.srt')]), isNotNull);
    });

    test('支持 1x01、E01、中文集号及分段季集编号', () {
      for (final name in [
        'My.Series.1x01.chs.srt',
        'My.Series.E01.chs.srt',
        'My.Series.第01集.chs.srt',
        'My.Series.S01.E01.chs.srt',
      ]) {
        expect(
          matcher.findBestFor(media('My.Series.S01E01.mkv'), [sub(name)]),
          isNotNull,
          reason: '$name 应识别为同一集',
        );
      }
    });

    test('常见字幕属性后缀不参与片名匹配', () {
      for (final name in [
        'movie.zh.forced.srt',
        'movie.default.srt',
        'movie.en.sdh.ass',
        'movie.chs.commentary.srt',
      ]) {
        expect(
          matcher.findBestFor(media('movie.mkv'), [sub(name)]),
          isNotNull,
          reason: '$name 应匹配 movie.mkv',
        );
      }
    });

    test('支持横线、全角横线和括号分隔的季集编号', () {
      for (final videoName in [
        'My-Series-S01E01.mkv',
        'My Series [S01E01].mkv',
        'My Series－S01E01－标题.mkv',
      ]) {
        expect(
          matcher.findBestFor(media(videoName), [
            sub('My.Series.S01E01.chs.srt'),
          ]),
          isNotNull,
          reason: '$videoName 应识别季集编号',
        );
      }
    });

    test('相似名称：分隔符差异（空格 vs 点）', () {
      final result = matcher.findBestFor(media('My Movie.mkv'), [
        sub('My.Movie.chs.srt'),
      ]);
      expect(result, isNotNull);
    });

    test('相似名称优先级：同名 > 相似中文 > 同名其他语言', () {
      final result = matcher.matchFor(media('My.Movie.2024.mkv'), [
        sub('movie.en.srt'), // 无关，不匹配
        sub('My.Movie.chs.srt'), // 相似 + 中文
        sub('My.Movie.2024.srt'), // 完全同名（无标签）
        sub('My.Movie.en.srt'), // 相似 + 其他语言
      ]);
      expect(result, hasLength(3));
      expect(result[0].name, 'My.Movie.2024.srt');
      expect(result[1].name, 'My.Movie.chs.srt');
      expect(result[2].name, 'My.Movie.en.srt');
    });

    // ── 误报防护 ────────────────────────────────────────────────

    test('误报防护：仅共享首个单词的不同影片不匹配', () {
      final result = matcher.matchFor(media('Star.Wars.mkv'), [
        sub('Star.Trek.chs.srt'),
        sub('Star.srt'),
        sub('Stars.chs.srt'),
      ]);
      expect(result, isEmpty);
    });

    test('误报防护：单段前缀不误伤无关短名', () {
      final result = matcher.matchFor(media('movie.mkv'), [sub('movie2.zh.srt')]);
      expect(result, isEmpty);
    });

    test('误报防护：S01E01 不匹配 S01E23 或 S02E01', () {
      expect(
        matcher.matchFor(media('My.Series.S01E01.mkv'), [
          sub('My.Series.S01E23.chs.srt'),
          sub('My.Series.S02E01.chs.srt'),
        ]),
        isEmpty,
      );
    });

    test('误报防护：剧集不匹配缺少集号的泛化字幕', () {
      expect(
        matcher.findBestFor(media('My.Series.S01E01.mkv'), [sub('My.Series.chs.srt')]),
        isNull,
      );
    });

    test('误报防护：纯数字集号不同时不匹配', () {
      expect(
        matcher.findBestFor(media('My.Series.01.mkv'), [sub('My.Series.23.srt')]),
        isNull,
      );
    });
  });

  group('SubtitleMatcher 同级目录约束', () {
    test('同源且同父目录正常匹配视频与 STRM', () {
      for (final video in [
        media(
          'My.Series.S01E01.mkv',
          href: 'https://dav.example/dav/Series/My.Series.S01E01.mkv',
        ),
        media(
          'My.Series.S01E01.strm',
          href: 'https://dav.example/dav/Series/My.Series.S01E01.strm',
        ),
      ]) {
        final result = matcher.findBestFor(video, [
          sub(
            'My.Series.S01E01.chs.srt',
            href: 'https://dav.example/dav/Series/My.Series.S01E01.chs.srt',
          ),
        ]);
        expect(result, isNotNull, reason: '${video.name} 应匹配同级字幕');
      }
    });

    test('同名字幕位于其他父目录时拒绝', () {
      final video = media(
        'My.Series.S01E01.mkv',
        href: '/dav/Series/My.Series.S01E01.mkv',
      );
      final result = matcher.findBestFor(video, [
        sub(
          'My.Series.S01E01.chs.srt',
          href: '/dav/SubtitleBackup/My.Series.S01E01.chs.srt',
        ),
      ]);
      expect(result, isNull);
    });

    test('同路径但来源服务器不同时拒绝', () {
      final video = media(
        'movie.mkv',
        href: 'https://media.example/dav/Movies/movie.mkv',
      );
      final result = matcher.findBestFor(video, [
        sub('movie.srt', href: 'https://backup.example/dav/Movies/movie.srt'),
      ]);
      expect(result, isNull);
    });
  });
}
