import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/playback_history.dart';
import 'package:streampath/data/models/video_queue.dart';
import 'package:streampath/domain/services/film_video_timeline.dart';

FilmResource _resource(int season, int episode, {String? path}) =>
    FilmResource.fromRow({
      'id': season * 100 + episode,
      'root_id': 1,
      'source_id': 'fixture',
      'source_kind': 'local',
      'media_type': 'tv',
      'root_path': 'Show',
      'display_name': 'Show',
      'relative_path': path ?? 'Show/$season-$episode.mkv',
      'path_key': path ?? 'Show/$season-$episode.mkv',
      'parent_path': 'Show',
      'name': path ?? '$season-$episode.mkv',
      'media_kind': 'video',
      'availability': 'present',
      'work_id': 1,
      'binding_origin': 'manual',
      'binding_version': 1,
      'season_number': season,
      'episode_number': episode,
      'episode_mapping_origin': 'manual',
    });

Map<String, dynamic> _season(int count, {String start = '2024-01-01'}) => {
  'air_date': start,
  'episodes': [
    for (var episode = 1; episode <= count; episode++)
      {
        'episode_number': episode,
        'air_date': DateTime.parse(
          start,
        ).add(Duration(days: episode)).toIso8601String().substring(0, 10),
      },
  ],
};

List<VideoQueueItem> _build(
  List<FilmResource> resources,
  Map<int, Map<String, dynamic>> seasons, {
  bool enabled = true,
  bool autoSeason = true,
  bool gap = false,
  String? selected,
}) => buildFilmVideoTimeline(
  resources,
  seasons,
  selectedPath: selected ?? resources.first.path,
  autoSeason: autoSeason,
  allowGap: gap,
  insertDecimalEpisodes: enabled,
);

void main() {
  final samples =
      (jsonDecode(
                File(
                  'test/fixtures/film_decimal_episodes/tmdb_samples.json',
                ).readAsStringSync(),
              )
              as List)
          .cast<Map<String, dynamic>>();
  for (final sample in samples) {
    test('TMDB ${sample['series']} 当前季数据验证小数插入与原排序', () {
      final seasons = {
        for (final entry in (sample['seasons'] as Map).entries)
          int.parse(entry.key as String): Map<String, dynamic>.from(
            entry.value as Map,
          ),
      };
      final resources = [
        for (final entry in seasons.entries)
          for (final row in entry.value['episodes'] as List)
            _resource(entry.key, row['episode_number'] as int),
      ];
      final baseline = _build(resources, seasons, enabled: false);
      final enabled = _build(resources, seasons);
      final original = baseline
          .map((item) => (item.season, item.episode))
          .toList();
      if (sample['series'] == 'shiki') {
        expect(enabled.map((item) => (item.season, item.episode)), [
          for (var e = 1; e <= 20; e++) (1, e),
          (0, 1),
          (1, 21),
          (0, 2),
          (1, 22),
          for (var e = 3; e <= 11; e++) (0, e),
        ]);
        expect(original.take(24), [
          for (var e = 1; e <= 22; e++) (1, e),
          (0, 1),
          (0, 2),
        ]);
        expect(
          buildFilmVideoOrder(
            resources,
            seasons,
          ).map((item) => (item.season, item.episode)),
          original,
        );
        final history = PlaybackHistory.fromJson(
          {},
        ).copyWith(queueItems: enabled, pendingVideoIndex: 20);
        final restored = PlaybackHistory.fromJson(history.toJson());
        expect(
          restored.queueItems.map((item) => (item.season, item.episode)),
          enabled.map((item) => (item.season, item.episode)),
        );
        expect(restored.queueItems[20].airDate, DateTime(2011, 5, 25));
        expect(restored.pendingVideoIndex, 20);
      } else {
        expect(enabled.map((item) => (item.season, item.episode)), original);
      }
    });
  }

  for (final title in [
    '第11.5集',
    '第11.5话 TV未放送',
    '第11.5話',
    'Episode 11.5',
    '11.5',
    '11.5: Interlude',
    '特別編（11.5）',
  ]) {
    test('元数据标题识别 $title，文件名无小数也能插入', () {
      final resources = [
        for (var e = 1; e <= 25; e++) _resource(1, e),
        _resource(0, 1),
      ];
      final items = _build(resources, {
        1: _season(25),
        0: {
          'episodes': [
            {'episode_number': 1, 'name': title, 'air_date': '2025-01-01'},
          ],
        },
      });
      expect(items[10].episode, 11);
      expect((items[11].season, items[11].episode), (0, 1));
      expect(items[12].episode, 12);
    });
  }

  for (final title in [
    '第25.5集',
    '第0.5集',
    '第11.0集',
    '第11.5集／第12.5集',
    '23.976fps 特典',
    'BluRay 2.35:1',
    '幕后花絮',
    '第-11.5集',
    '第1.11.5集',
  ]) {
    test('范围外、冲突或非集数元数据保持原序 $title', () {
      final resources = [
        for (var e = 1; e <= 25; e++) _resource(1, e),
        _resource(0, 1, path: 'Show/S00E01 11.5集.mkv'),
      ];
      final seasons = {
        1: _season(25),
        0: {
          'episodes': [
            {'episode_number': 1, 'name': title, 'air_date': '2025-01-01'},
          ],
        },
      };
      expect(
        _build(resources, seasons).map((item) => item.versions.first.path),
        _build(
          resources,
          seasons,
          enabled: false,
        ).map((item) => item.versions.first.path),
      );
    });
  }

  test('两季范围重合时不猜测，缓存中无本地资源的另一季也参与消歧', () {
    final resources = [
      for (var e = 1; e <= 12; e++) _resource(1, e),
      _resource(0, 1),
    ];
    final seasons = {
      1: _season(12),
      2: _season(12, start: '2024-06-01'),
      0: {
        'episodes': [
          {'episode_number': 1, 'name': '第11.5集', 'air_date': '2025-01-01'},
        ],
      },
    };
    expect(_build(resources, seasons).last.season, 0);
  });

  test('明确第二季的小数番外忽略迟播日期，起播与切季限制按第二季归属', () {
    final resources = [
      for (final s in [1, 2, 4])
        for (var e = 1; e <= 12; e++) _resource(s, e),
      _resource(0, 1),
    ];
    final seasons = {
      for (final s in [1, 2, 4]) s: _season(12, start: '2024-0$s-01'),
      0: {
        'episodes': [
          {'episode_number': 1, 'name': '第二季 第11.5集', 'air_date': '2025-01-01'},
        ],
      },
    };
    final special = resources.last;
    final items = _build(
      resources,
      seasons,
      selected: special.path,
      autoSeason: false,
    );
    expect(items.map((item) => item.season).toSet(), {0, 2});
    expect(items[10].episode, 11);
    expect(items[11].season, 0);
    expect(items[12].episode, 12);
    expect(
      _build(
        resources,
        seasons,
        autoSeason: false,
      ).any((item) => item.season == 0),
      isFalse,
    );
    expect(_build(resources, seasons).map((item) => item.season).toSet(), {
      0,
      1,
      2,
    });
    expect(
      _build(resources, seasons, gap: true).map((item) => item.season).toSet(),
      {0, 1, 2, 4},
    );
  });

  test('同集版本仍归组，小数按数值插入；缺少对应正片时保留可播放顺序', () {
    final resources = [
      _resource(1, 10),
      _resource(1, 12),
      _resource(0, 1),
      _resource(0, 1, path: 'Show/alternate.mkv'),
      _resource(0, 2),
      _resource(0, 3),
    ];
    final items = _build(resources, {
      1: _season(25),
      0: {
        'episodes': [
          {'episode_number': 1, 'name': '第11.5集'},
          {'episode_number': 2, 'name': '第11.25集'},
          {'episode_number': 3, 'name': '第9.5集'},
        ],
      },
    });
    expect(items.map((item) => (item.season, item.episode)), [
      (0, 3),
      (1, 10),
      (0, 2),
      (0, 1),
      (1, 12),
    ]);
    expect(items[3].versions, hasLength(2));
  });

  test('缺少正季范围或番外元数据标题时不从文件名推断', () {
    final resources = [
      _resource(1, 11),
      _resource(1, 12),
      _resource(0, 1, path: 'Show/S00E01 11.5集.mkv'),
    ];
    expect(_build(resources, {}).map((item) => item.season), [1, 1, 0]);
    expect(_build(resources, {1: _season(25)}).map((item) => item.season), [
      1,
      1,
      0,
    ]);
  });
}
