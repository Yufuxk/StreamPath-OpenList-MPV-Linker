// 生成带真值的虚拟影视库清单：题名、年份与季集全部来自 TMDB 公开资料。
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:streampath/data/local/tmdb_credential_store.dart';

const _host = 'api.tmdb.org';

Future<Map<String, dynamic>> _get(
  String token,
  String path,
  Map<String, String> query,
) async {
  final uri = Uri.https(_host, '/3/$path', query);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw StateError('TMDB $path failed with ${response.statusCode}');
    }
    return jsonDecode(body) as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

Future<List<Map<String, dynamic>>> _recordPool(String token) async {
  final works = <Map<String, dynamic>>[];
  // 已知易混作品：同名不同年份、不同续作、名称带区分后缀。
  const fixed = [
    ('movie', 1163), // 秒速五厘米 2007
    ('movie', 1125510), // 秒速5厘米 2025 重制/新作
    ('movie', 1726), // 钢铁侠
    ('movie', 1724), // 复仇者联盟
    ('tv', 1429), // 进击的巨人
    ('tv', 224499), // 《进击の巨人》Q版剧场
    ('tv', 63510), // 进击！巨人中学
    ('tv', 45782), // 刀剑神域
  ];
  final ids = <(String, int)>{
    ...fixed,
    for (final type in ['movie', 'tv'])
      for (final page in [1, 2, 3])
        for (final row
            in ((await _get(token, 'discover/$type', {
                  'sort_by': 'vote_count.desc',
                  'vote_count.gte': type == 'movie' ? '500' : '200',
                  'language': 'zh-CN',
                  'page': '$page',
                }))['results']
                as List))
          (type, (row as Map)['id'] as int),
  };
  for (final (type, id) in ids) {
    try {
      final detail = await _get(token, '$type/$id', {'language': 'zh-CN'});
      final alternatives = await _get(
        token,
        '$type/$id/alternative_titles',
        {},
      );
      final translations = await _get(token, '$type/$id/translations', {});
      final title =
          (type == 'movie' ? detail['title'] : detail['name']) as String?;
      final original =
          (type == 'movie' ? detail['original_title'] : detail['original_name'])
              as String?;
      final date =
          (type == 'movie' ? detail['release_date'] : detail['first_air_date'])
              as String?;
      if (title == null ||
          original == null ||
          date == null ||
          date.length < 4) {
        continue;
      }
      final variants = <String>{title, original};
      for (final row
          in (alternatives['titles'] ?? alternatives['results'] ?? [])
              as List) {
        final value = (row as Map)['title'];
        if (value is String && value.trim().isNotEmpty) {
          variants.add(value.trim());
        }
      }
      for (final row in (translations['translations'] ?? []) as List) {
        final data = (row as Map)['data'];
        if (data is Map) {
          final value = data[type == 'movie' ? 'title' : 'name'];
          if (value is String && value.trim().isNotEmpty) {
            variants.add(value.trim());
          }
        }
      }
      works.add({
        'type': type,
        'tmdbId': id,
        'title': title,
        'originalTitle': original,
        'year': int.parse(date.substring(0, 4)),
        'variants': variants.toList(),
        'seasons': [
          for (final season in (detail['seasons'] as List? ?? []))
            if (season is Map && (season['season_number'] as int) > 0)
              season['season_number'] as int,
        ],
      });
    } on StateError {
      continue;
    }
  }
  return works;
}

class _Rng {
  _Rng(this.state);
  int state;
  int next(int bound) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    return state % bound;
  }

  T pick<T>(List<T> values) => values[next(values.length)];
}

String _safe(String value) =>
    value.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim();

class _Library {
  final entries = <Map<String, Object?>>[];
  final expected = <Map<String, Object?>>[];

  void add(
    String parent,
    String name,
    Map<String, Object?> truth, {
    bool directory = false,
  }) {
    final path = parent.isEmpty ? name : '$parent/$name';
    entries.add({
      'path': path,
      'parent': parent,
      'name': name,
      'directory': directory,
    });
    if (!directory) expected.add({'path': path, ...truth});
  }
}

Map<String, Object?> _truth(
  Map<String, dynamic> work,
  String type, {
  int? season,
  int? episode,
}) => {
  'type': type,
  'tmdbId': work['tmdbId'],
  'season': season,
  'episode': episode,
};

void _movie(_Library library, _Rng rng, Map<String, dynamic> work) {
  final title = _safe(
    (rng.next(2) == 0
            ? work['title']
            : work['variants'][rng.next((work['variants'] as List).length)])
        as String,
  );
  final year = work['year'];
  final grouping = _safe(work['title'] as String);
  final layout = rng.next(7);
  final group = rng.pick(['MTeam', 'FRDS', 'WiKi', 'HDS', 'CHD', 'CMCTV']);
  switch (layout) {
    case 0:
      final folder =
          '$title.$year.2160p.UHD.BluRay.REMUX.HDR.HEVC.TrueHD.Atmos.7.1-$group';
      library.add(
        'Synthetic/Movies/$folder',
        '$title.$year.mkv',
        _truth(work, 'movie'),
      );
      return;
    case 1:
      final folder = '$title ($year) [1080p] [BluRay] [x264]';
      library.add(
        'Synthetic/Movies/$folder',
        '$title ($year).mkv',
        _truth(work, 'movie'),
      );
      return;
    case 2:
      final folder = '$year -《$grouping》';
      library.add(
        'Synthetic/Movies/$folder',
        '$title.$year.BlueRay.REMUX.1080P.AVC.LPCM.strm',
        _truth(work, 'movie'),
      );
      return;
    case 3:
      library.add(
        'Synthetic/Movies/$year -《$grouping》',
        '$title $year.iso',
        _truth(work, 'movie'),
      );
      return;
    case 4:
      library.add(
        'Synthetic/Movies',
        '[$group] $title.$year.1080p.BluRay.x264.DTS-HD.MA.5.1.mkv',
        _truth(work, 'movie'),
      );
      return;
    case 5:
      library.add(
        'Synthetic/Movies/$grouping ($year)',
        '$title.$year.1080p.WEB-DL.DDP5.1.H.264-$group.mkv',
        _truth(work, 'movie'),
      );
      return;
    default:
      library.add(
        'Synthetic/Movies/$grouping ($year)/Extras',
        '$grouping Trailer.mkv',
        _truth(work, 'movie'),
      );
      library.add(
        'Synthetic/Movies/$grouping ($year)',
        '$title.$year.Directors.Cut.1080p.BluRay.x264-$group.mkv',
        _truth(work, 'movie'),
      );
  }
}

void _series(_Library library, _Rng rng, Map<String, dynamic> work) {
  final title = _safe(work['title'] as String);
  final year = work['year'];
  final seasons = (work['seasons'] as List).cast<int>();
  final layout = rng.next(8);
  final seasonCount = seasons.isEmpty
      ? 1
      : min(seasons.length, 1 + rng.next(2));
  // 扁平番剧目录与文件名都没有季标记时只能按第一季生成。
  final selected = layout == 4
      ? [1]
      : seasons.isEmpty
      ? [for (var i = 1; i <= seasonCount; i++) i]
      : seasons.take(seasonCount).toList();
  final group = rng.pick([
    'Lilith-Raws',
    'ANi',
    'VCB-Studio',
    'Nekomoe',
    'Ohys-Raws',
  ]);
  final seriesFolder = switch (layout) {
    0 => '$title ($year)',
    1 => '$year -《$title》',
    2 => '$title $year',
    3 || 6 => title,
    4 => '$group $title ($year)',
    5 => '$title ($year) [tmdb-${work['tmdbId']}]',
    _ => '$title ($year)',
  };
  for (final season in selected) {
    final episodes = 1 + rng.next(4);
    final seasonFolder = switch (layout) {
      0 || 5 => 'Season ${season.toString().padLeft(2, '0')}',
      1 => '$season.《$title 第$season季》',
      2 || 3 => 'Season $season',
      4 => '',
      6 => 'S${season.toString().padLeft(2, '0')}',
      _ => '第$season季',
    };
    for (var episode = 1; episode <= episodes; episode++) {
      final e = episode.toString().padLeft(2, '0');
      final name = switch (layout) {
        0 =>
          '$title - S${season.toString().padLeft(2, '0')}E$e - Episode $episode.mkv',
        1 =>
          '$title.S${season.toString().padLeft(2, '0')}E$e.BlueRay.REMUX.1080P.AVC.LPCM.strm',
        2 =>
          '$title.S${season.toString().padLeft(2, '0')}E$e.$year.2160p.NF.WEB-DL.H265.HDR10.DDP5.1.mkv',
        3 => '$title 第$e话.mkv',
        4 => '[$group] $title - $e [1080p][HEVC_AAC].mkv',
        5 => '$title.${season}x$e.720p.HDTV.mkv',
        6 => '$title EP$e.mkv',
        _ =>
          '$title.S${season.toString().padLeft(2, '0')}E$e.1080p.BluRay.x264-$group.mkv',
      };
      final parent = seasonFolder.isEmpty
          ? 'Synthetic/Series/$seriesFolder'
          : 'Synthetic/Series/$seriesFolder/$seasonFolder';
      library.add(
        parent,
        name,
        _truth(work, 'tv', season: season, episode: episode),
      );
    }
  }
  if (rng.next(2) == 0) {
    library.add(
      'Synthetic/Series/$seriesFolder/Season 00',
      '$title.S00E01.NCOP.01.BlueRay.1080P.AVC.LPCM.mkv',
      _truth(work, 'tv', season: 0, episode: 1),
    );
  }
}

void main(List<String> arguments) async {
  final poolFile = File(
    arguments.isNotEmpty
        ? arguments[0]
        : 'build/scrape-accuracy-20261102/tmdb-work-pool.json',
  );
  final outputFile = File(
    arguments.length > 1
        ? arguments[1]
        : 'build/scrape-accuracy-20261102/synthetic-manifest.json',
  );
  final expectedFile = File(
    arguments.length > 2
        ? arguments[2]
        : 'build/scrape-accuracy-20261102/synthetic-expected.json',
  );
  final seed = arguments.length > 3 ? int.parse(arguments[3]) : 20261102;
  List<Map<String, dynamic>> pool;
  if (!poolFile.existsSync()) {
    final token = await const TmdbCredentialStore().read();
    if (token == null || token.isEmpty) {
      throw StateError('Missing TMDB credential');
    }
    pool = await _recordPool(token);
    await poolFile.parent.create(recursive: true);
    await poolFile.writeAsString(jsonEncode(pool));
    stdout.writeln('SYNTHETIC_POOL works=${pool.length}');
  } else {
    pool = (jsonDecode(await poolFile.readAsString()) as List)
        .cast<Map<String, dynamic>>();
  }
  final rng = _Rng(seed);
  final library = _Library();
  for (final work in pool) {
    if ((work['variants'] as List).isEmpty) continue;
    if (work['type'] == 'movie') {
      _movie(library, rng, work);
    } else {
      _series(library, rng, work);
    }
  }
  // 目录条目必须显式给出，扫描器只会枚举清单里出现过的父目录。
  final directories = <String>{};
  for (final entry in library.entries) {
    final parts = (entry['path'] as String).split('/');
    for (var i = 2; i < parts.length; i++) {
      directories.add(parts.take(i).join('/'));
    }
  }
  final listed = <String>{};
  for (final directory in directories) {
    final parent = directory.substring(0, directory.lastIndexOf('/'));
    if (!listed.add(directory)) continue;
    library.entries.add({
      'path': directory,
      'parent': parent,
      'name': directory.substring(directory.lastIndexOf('/') + 1),
      'directory': true,
    });
  }
  await outputFile.parent.create(recursive: true);
  await outputFile.writeAsString(
    jsonEncode({
      'generator': 'tools/film_scrape_synthetic_library.dart',
      'seed': seed,
      'roots': [
        {
          'path': 'Synthetic/Movies',
          'type': 'movie',
          'name': 'Synthetic Movies',
        },
        {'path': 'Synthetic/Series', 'type': 'tv', 'name': 'Synthetic Series'},
      ],
      'entries': library.entries,
    }),
  );
  await expectedFile.writeAsString(jsonEncode(library.expected));
  stdout.writeln(
    'SYNTHETIC_LIBRARY works=${pool.length} files=${library.expected.length} entries=${library.entries.length}',
  );
}
