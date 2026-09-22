import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/domain/services/iso_subtitle_matcher.dart';

void main() {
  final titles = <Map<String, dynamic>>[
    {'id': '00009', 'duration': 1500},
    {'id': '00001', 'duration': 20},
    {'id': '00003', 'duration': 1400},
    {'id': '00003', 'duration': 1400},
  ];
  Map<String, dynamic> candidate(String path, double? duration) => {
    ...IsoSubtitleMatcher.describe(path, 'anime', 1)!,
    'duration': duration,
  };
  test('ASS/SSA 依据 Events Format 读取正文结束时间，忽略注释和其他区段', () {
    const text =
        '[Events]\nFormat: Layer, End, Start, Text\n'
        'Dialogue: 0,0:23:19.50,0:00:01.00,hello,world\n'
        'Comment: 0,9:00:00.00,0:00:01.00,ignore\n'
        '[Other]\nDialogue: 0,9:00:00.00,0:00:01.00,ignore';
    expect(IsoSubtitleMatcher.duration(utf8.encode(text), 'x.ass'), 1399.5);
    final bytes = [
      255,
      254,
      for (final c in text.codeUnits) ...[c & 255, c >> 8],
    ];
    expect(IsoSubtitleMatcher.duration(bytes, 'x.ssa'), 1399.5);
    expect(
      IsoSubtitleMatcher.duration(utf8.encode('garbage'), 'x.ass'),
      isNull,
    );
    expect(
      IsoSubtitleMatcher.duration(
        utf8.encode('1\n00:00:01,000 --> 00:24:59,999\nHi'),
        'x.srt',
      ),
      1499.999,
    );
  });
  test('综合时长分数优先于错误集数和语言，明确 MPLS 优先于推测', () {
    final a = candidate('01.chs.ass', 1400), b = candidate('02.en.srt', 1500);
    expect(IsoSubtitleMatcher.best('00009', titles, [a, b]), '02.en.srt');
    // 时长证据足够强时可推翻集数推测。
    expect(
      IsoSubtitleMatcher.best('00009', titles, [
        candidate('02.chs.ass', 1000),
        candidate('01.en.srt', 1500),
      ]),
      '01.en.srt',
    );
    final explicit = candidate('Anime.mpls00009.en.srt', 1400);
    expect(
      IsoSubtitleMatcher.best('00009', titles, [b, explicit]),
      explicit['path'],
    );
    expect(IsoSubtitleMatcher.best('00003', titles, [explicit]), isNull);
  });
  test('语言、格式、ISO 名前缀参与评分，同分路径稳定；不会只因中文而注入', () {
    final options = [
      candidate('random.chs.ass', 1500),
      candidate('Anime.chs.srt', 1500),
      candidate('Anime.chs.ass', 1500),
    ];
    expect(
      IsoSubtitleMatcher.best('00009', titles, options.reversed.toList()),
      'Anime.chs.ass',
    );
    expect(
      IsoSubtitleMatcher.best('00009', titles, [
        candidate('unknown.chs.ass', null),
      ]),
      isNull,
    );
    expect(
      IsoSubtitleMatcher.best('00009', titles, [
        candidate('b.chs.ass', 1500),
        candidate('a.chs.ass', 1500),
      ]),
      'a.chs.ass',
    );
  });
  test('完整节目表去重并跳过短片；多 ISO 拒绝无归属候选', () {
    expect(
      IsoSubtitleMatcher.best('00009', titles, [candidate('02.ass', null)]),
      '02.ass',
    );
    expect(
      IsoSubtitleMatcher.best('00001', titles, [candidate('01.ass', null)]),
      isNull,
    );
    expect(IsoSubtitleMatcher.describe('Other.01.ass', 'anime', 2), isNull);
    expect(
      IsoSubtitleMatcher.describe('Anime_01.ass', 'anime', 2)?['episode'],
      1,
    );
    expect(
      IsoSubtitleMatcher.describe(
        '[Group] Anime [S01E02].chs.ass',
        'anime',
        1,
      )?['episode'],
      2,
    );
    expect(
      IsoSubtitleMatcher.describe('第03話.chs.ass', 'anime', 1)?['episode'],
      3,
    );
  });
}
