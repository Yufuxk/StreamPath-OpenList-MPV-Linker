import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/core/utils/video_filename_parser.dart';
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/data/models/media_entry.dart';
import 'package:streampath/domain/services/mpv_scripts.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';

void main() {
  test('REMUX 发布标记不阻断片名年份，保留片名数字', () {
    const parser = VideoFilenameParser();
    for (final sample in <String, (String, int)>{
      'Iron.Man.3.2013.PROPER.2160P.BluRay.REMUX.HEVC.DTS-HD.MA.TrueHD.7.1.Atmos.mkv':
          ('Iron Man 3', 2013),
      'Avengers.Infinity.War.2018.PROPER.2160P.BluRay.REMUX.HEVC.DTS-HD.MA.TrueHD.Atmos.mkv':
          ('Avengers Infinity War', 2018),
      'The.Avengers.2012.2160P.BluRay.REMUX.HEVC.DTS-HD.MA.TrueHD.Atmos.mkv': (
        'The Avengers',
        2012,
      ),
      '2001.A.Space.Odyssey.1968.REPACK.2160p.mkv': (
        '2001 A Space Odyssey',
        1968,
      ),
    }.entries) {
      final parsed = parser.parse(sample.key)!;
      expect(parsed.title, sample.value.$1);
      expect(parsed.year, sample.value.$2);
      expect(parsed.description, isEmpty);
    }
  });
  const zh = AppLocalizations(AppLanguage.simplifiedChinese);
  const cases = {
    '葬送的芙莉莲.2023.S01E29.BlueRay.REMUX.1080P.AVC.FLAC': '葬送的芙莉莲·2023·第一季·第29集',
    '葬送的芙莉莲.2023.S00E01.BluRay.1080p.mkv': '葬送的芙莉莲·2023·特别篇·第1集',
    'Show.S0E02.WEB-DL.mkv': 'Show·特别篇·第2集',
    'Show.S00.mkv': 'Show·特别篇',
    'Show.s1e2.mkv': 'Show·第一季·第2集',
    'Show.S01.E02.1080p.mkv': 'Show·第一季·第2集',
    'Show.S01_E02.mkv': 'Show·第一季·第2集',
    'Show.S01xE02.mkv': 'Show·第一季·第2集',
    'Show.1x29.HDTV.mkv': 'Show·第一季·第29集',
    'Show Season 02 Episode 03.mkv': 'Show·第二季·第3集',
    '作品.2023.第二季.第二十九话.BDRip.mkv': '作品·2023·第二季·第29集',
    '作品.第十集.mkv': '作品·第10集',
    '作品.第101話.mkv': '作品·第101集',
    'Show.EP_002.1080p.mkv': 'Show·第2集',
    'Show.E03.mkv': 'Show·第3集',
    '[SubsPlease] Frieren - 029 (1080p) [ABCDEF12].mkv': 'Frieren·第29集',
    '[TaigaSubs]_Toradora!_(2008)_-_01v2_-_Tiger_and_Dragon_[1280x720_H.264_FLAC][1234ABCD].mkv':
        'Toradora!·2008·第1集·Tiger and Dragon',
    'Frieren - 01.mkv': 'Frieren·第1集',
    'Show.S01E01-E03.BluRay.mkv': 'Show·第一季·第1–3集',
    'Show.S01E01E03.mkv': 'Show·第一季·第1, 3集',
    'Show.S01E01-S01E03.mkv': 'Show·第一季·第1–3集',
    'Show.1x01-1x03.mkv': 'Show·第一季·第1–3集',
    'Show.EP01-EP03.mkv': 'Show·第1–3集',
    'Daily.Show.2024.10.01.HDTV.mkv': 'Daily Show·2024-10-01',
    'Daily.Show.01.10.2024.HDTV.mkv': 'Daily Show·2024-10-01',
    '作品.OVA.01.BDRip.mkv': '作品·特别篇·第1集·OVA',
    '作品.特别篇.mkv': '作品·特别篇',
    'Band of Brothers (2001) - s01e01 - Currahee.mkv':
        'Band of Brothers·2001·第一季·第1集·Currahee',
    'Show.S01E01.Part.1.mkv': 'Show·第一季·第1集·Part 1',
    'Alien (1979) {imdb-tt0078748}.mkv': 'Alien·1979',
    'The.Matrix.1999.BluRay.REMUX.2160p.HEVC.TrueHD.mkv': 'The Matrix·1999',
    '1917.2019.BluRay.1080p.mkv': '1917·2019',
    '2001.A.Space.Odyssey.1968.BluRay.mkv': '2001 A Space Odyssey·1968',
    'Blade.Runner.2049.2017.BluRay.mkv': 'Blade Runner 2049·2017',
    'Show (2023) [tmdbid-1234] S01E01.mkv': 'Show·2023·第一季·第1集',
    'Show.2023.01.1080p.mkv': 'Show·2023·第1集',
    '86.S01E01.mkv': '86·第一季·第1集',
    'Эпизод.S01E01.mkv': 'Эпизод·第一季·第1集',
    'Movie.2023.Extended.BluRay.mkv': 'Movie·2023·Extended',
    "Movie.2023.BluRay.1080p.Director's.Cut.mkv": "Movie·2023·Director's Cut",
    'Show.S01E01.BluRay.Part.2.mkv': 'Show·第一季·第1集·Part 2',
    'Show.S01E01-02-04.mkv': 'Show·第一季·第1, 2, 4集',
    'Show.S01E01.strm': 'Show·第一季·第1集',
  };
  for (final entry in cases.entries) {
    test('解析 ${entry.key}', () {
      expect(zh.videoPlaylistTitle(entry.key), entry.value);
    });
  }
  for (final filename in [
    '01.mkv',
    '2023.mkv',
    '1080p.mkv',
    '1917.mkv',
    'My.Video.mkv',
    'Show.102.mkv',
    'Show - 1080.mkv',
    'Show.S01E01.S02E03.mkv',
    'Show.S01E01-S02E03.mkv',
    'Show.2024.02.30.mkv',
    'Show.1280x720.mkv',
    '作品.第999999999999999999999集.mkv',
  ]) {
    test('保留不足或冲突的文件名 $filename', () {
      expect(zh.videoPlaylistTitle(filename), filename);
    });
  }
  test('四语言格式保留原始片名，季号零显示特别篇', () {
    const input = '葬送的芙莉莲.2023.S01E29.BlueRay.REMUX.1080P.AVC.FLAC.mkv';
    const normal = [
      '葬送的芙莉莲·2023·第一季·第29集',
      '葬送的芙莉莲·2023·第一季·第29集',
      '葬送的芙莉莲·2023·シーズン1·第29話',
      '葬送的芙莉莲·2023·Season 1·Episode 29',
    ];
    const specials = [
      '作品·特别篇·第1集',
      '作品·特別篇·第1集',
      '作品·特別編·第1話',
      '作品·Specials·Episode 1',
    ];
    for (var i = 0; i < AppLanguage.values.length; i++) {
      final l10n = AppLocalizations(AppLanguage.values[i]);
      expect(l10n.videoPlaylistTitle(input), normal[i]);
      expect(l10n.videoPlaylistTitle('作品.S00E01.mkv'), specials[i]);
    }
  });
  test('评分明确标记高于动漫和年份候选', () {
    const parser = VideoFilenameParser();
    expect(
      parser.parse('Show.S01E01.mkv')!.score,
      greaterThan(parser.parse('Show - 01.mkv')!.score),
    );
    expect(
      parser.parse('Movie.2023.mkv')!.score,
      greaterThanOrEqualTo(VideoFilenameParser.minimumScore),
    );
  });
  for (final total in [9, 10, 12, 99, 100, 123, 1000]) {
    test('$total 集按整季位宽补零并使用四语言分段', () {
      final filenames = [
        for (var episode = 1; episode <= total; episode++)
          '神无月的巫女.2004.S01E$episode.BluRay.mkv',
      ];
      final digits = total.toString().length;
      const seasons = ['第一季', '第一季', 'シーズン1', 'Season 1'];
      for (final language in AppLanguage.values) {
        final titles = AppLocalizations(
          language,
        ).videoPlaylistTitles(filenames);
        expect(titles, hasLength(total));
        for (var i = 0; i < total; i++) {
          final number = '${i + 1}'.padLeft(digits, '0');
          final episode = switch (language) {
            AppLanguage.japanese => '第$number話',
            AppLanguage.english => 'Episode $number',
            _ => '第$number集',
          };
          expect(titles[i], '神无月的巫女·2004·${seasons[language.index]}·$episode');
        }
      }
    });
  }
  test('缺集、合并集数和无季号集数按最大集号补零', () {
    expect(
      zh.videoPlaylistTitles([
        'Show.S01E01-E03.mkv',
        'Show.S01E04E06.mkv',
        'Show.S01E123.mkv',
        'Anime - 01.mkv',
        'Anime.EP12.mkv',
      ]),
      [
        'Show·第一季·第001–003集',
        'Show·第一季·第004, 006集',
        'Show·第一季·第123集',
        'Anime·第01集',
        'Anime·第12集',
      ],
    );
  });
  test('不同作品、年份、季和特别篇分别计算位宽，保留片名和其他信息', () {
    expect(
      zh.videoPlaylistTitles([
        'Show.2023.S01E01.Part.1.mkv',
        'Show.2023.S01E12.mkv',
        'Show.2023.S02E01.mkv',
        'Show.2023.S02E100.mkv',
        'Show.2023.S00E01.mkv',
        'Show.2024.S01E01.mkv',
        'Other.2023.S01E01.mkv',
        'Movie.2023.Extended.BluRay.mkv',
        'Daily.Show.2024.10.01.HDTV.mkv',
        '作品.OVA.01.BDRip.mkv',
        '作品.OVA.12.BDRip.mkv',
        'Band of Brothers (2001) - s01e01 - Currahee.mkv',
        'My.Video.mkv',
      ]),
      [
        'Show·2023·第一季·第01集·Part 1',
        'Show·2023·第一季·第12集',
        'Show·2023·第二季·第001集',
        'Show·2023·第二季·第100集',
        'Show·2023·特别篇·第1集',
        'Show·2024·第一季·第1集',
        'Other·2023·第一季·第1集',
        'Movie·2023·Extended',
        'Daily Show·2024-10-01',
        '作品·特别篇·第01集·OVA',
        '作品·特别篇·第12集·OVA',
        'Band of Brothers·2001·第一季·第1集·Currahee',
        'My.Video.mkv',
      ],
    );
    expect(zh.videoPlaylistTitles([]), isEmpty);
  });
  test('同一显示名写入 M3U、旧版标题和季资源脚本，地址原样保留', () async {
    final dir = await Directory.systemTemp.createTemp('sp_simple_title_');
    addTearDown(() => dir.delete(recursive: true));
    const filename = '作品.2023.S00E01.BluRay.1080p.mkv';
    final title = zh.videoPlaylistTitles([
      filename,
      '作品.2023.S00E123.BluRay.1080p.mkv',
    ]).first;
    expect(title, '作品·2023·特别篇·第001集');
    final entries = [MediaEntry(url: 'http://h/dav/$filename', title: title)];
    final playlist = await MpvScripts.ensurePlaylistM3u(
      entries,
      (url) => url,
      dir,
    );
    expect(
      await File(playlist).readAsString(),
      '#EXTM3U\n#EXTINF:0,$title\n#EXTVLCOPT:force-media-title=$title\nhttp://h/dav/$filename\n',
    );
    final script = await MpvScripts.ensureTitles(entries, dir);
    expect(await File(script).readAsString(), contains(title));
    final resources = await MpvScripts.ensureSeasonResources(
      entries,
      const [],
      (url) => url,
      playlist,
      dir,
      subtitleInjectionEnabled: false,
      autoSelect: false,
      sessionId: 'next',
    );
    expect(await File(resources).readAsString(), contains(title));
  });
}
