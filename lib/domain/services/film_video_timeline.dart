import '../../data/models/film_catalog_item.dart';
import '../../data/models/video_queue.dart';
import 'season_video_playlist_collector.dart';

/// 按首播日期排序，可将季归属明确的小数番外插入正片之间。
List<VideoQueueItem> buildFilmVideoTimeline(
  List<FilmResource> resources,
  Map<int, Map<String, dynamic>> seasons, {
  required String selectedPath,
  required bool autoSeason,
  required bool allowGap,
  bool insertDecimalEpisodes = false,
}) {
  final ordered = buildFilmVideoOrder(resources, seasons);
  final placements = insertDecimalEpisodes
      ? _decimalEpisodePlacements(ordered, seasons)
      : <VideoQueueItem, (int, double)>{};
  final filtered = _filterFilmVideoTimeline(
    ordered,
    resources,
    seasons,
    selectedPath: selectedPath,
    autoSeason: autoSeason,
    allowGap: allowGap,
    decimalSeasons: {
      for (final entry in placements.entries) entry.key: entry.value.$1,
    },
  );
  if (placements.isEmpty) return filtered;
  final result = filtered
      .where((item) => !placements.containsKey(item))
      .toList();
  final decimals = filtered.where(placements.containsKey).toList()
    ..sort((a, b) {
      final left = placements[a]!, right = placements[b]!;
      final season = left.$1.compareTo(right.$1);
      final number = left.$2.compareTo(right.$2);
      return season != 0
          ? season
          : number != 0
          ? number
          : ordered.indexOf(a).compareTo(ordered.indexOf(b));
    });
  for (final item in decimals) {
    final (season, number) = placements[item]!;
    var insertion = -1;
    var previous = double.negativeInfinity;
    for (var i = 0; i < result.length; i++) {
      final other = result[i];
      final otherSeason = placements[other]?.$1 ?? other.season;
      final otherNumber = placements[other]?.$2 ?? other.episode!.toDouble();
      if (otherSeason == season &&
          otherNumber <= number &&
          otherNumber >= previous) {
        insertion = i + 1;
        previous = otherNumber;
      }
    }
    if (insertion < 0) {
      final next = result.firstWhere((other) => other.season == season);
      insertion = result.indexOf(next);
    }
    result.insert(insertion, item);
  }
  return result;
}

final _decimalEpisodeNumber = RegExp(
  r'(?<![\d.+-])(?:\b(?:s\d+\s*e|episode|ep|e)\s*(\d+\.\d+)(?![\d.a-z])|(\d+\.\d+)\s*[集话話]|(?:^|[（(])\s*(\d+\.\d+)(?=\s*(?:$|[）):：]|[-–])))',
  caseSensitive: false,
);

/// 只移动有明确小数集标识、季范围唯一且存在正片资源的已映射特别篇。
Map<VideoQueueItem, (int, double)> _decimalEpisodePlacements(
  List<VideoQueueItem> ordered,
  Map<int, Map<String, dynamic>> seasons,
) {
  final ranges = <int, (int, int)>{};
  for (final entry in seasons.entries.where((entry) => entry.key > 0)) {
    final numbers =
        (entry.value['episodes'] as List? ?? const [])
            .whereType<Map>()
            .map((row) => row['episode_number'])
            .whereType<int>()
            .where((number) => number > 0)
            .toList()
          ..sort();
    if (numbers.isNotEmpty) ranges[entry.key] = (numbers.first, numbers.last);
  }
  final result = <VideoQueueItem, (int, double)>{};
  for (final item in ordered.where((item) => item.season == 0)) {
    final metadata = (seasons[0]?['episodes'] as List? ?? const [])
        .whereType<Map>()
        .where((row) => row['episode_number'] == item.episode)
        .firstOrNull;
    final title = metadata?['name'];
    if (title is! String) continue;
    final numbers = <double>{};
    for (final match in _decimalEpisodeNumber.allMatches(title)) {
      final number = double.parse(match[1] ?? match[2] ?? match[3]!);
      if (number.isFinite && number > number.floor()) numbers.add(number);
    }
    final explicitSeason = SeasonVideoPlaylistCollector.seasonFromVideo(title);
    if (numbers.length != 1) continue;
    final number = numbers.single;
    final candidates = ranges.entries
        .where(
          (entry) =>
              number >= entry.value.$1 &&
              number < entry.value.$2 &&
              (explicitSeason == null || explicitSeason == entry.key),
        )
        .toList();
    if (candidates.length != 1) continue;
    final season = candidates.single.key;
    if (!ordered.any((other) => other.season == season)) continue;
    result[item] = (season, number);
  }
  return result;
}

/// 自定义范围与隐式队列共用季集分组和首播顺序。
List<VideoQueueItem> buildFilmVideoOrder(
  List<FilmResource> resources,
  Map<int, Map<String, dynamic>> seasons,
) {
  final groups = <(int, int), List<FilmResource>>{};
  for (final r in resources) {
    if (r.availability != 'present' ||
        r.season == null ||
        r.episode == null ||
        r.mediaKind != 'video' && r.mediaKind != 'strm') {
      continue;
    }
    groups.putIfAbsent((r.season!, r.episode!), () => []).add(r);
  }
  DateTime? date(int s, int e) {
    final rows = seasons[s]?['episodes'] as List? ?? const [];
    final value = rows
        .whereType<Map>()
        .where((r) => r['episode_number'] == e)
        .firstOrNull?['air_date'];
    return parseAirDate(value);
  }

  final result = <VideoQueueItem>[];
  for (final entry in groups.entries) {
    final (s, e) = entry.key;
    final versions =
        entry.value
            .map(
              (r) => VideoQueueVersion(
                path: r.path,
                name: r.name,
                rootId: r.rootId,
              ),
            )
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    result.add(
      VideoQueueItem(
        versions: versions,
        season: s,
        episode: e,
        airDate: date(s, e),
      ),
    );
  }
  result.sort((a, b) {
    if (a.airDate == null && b.airDate != null) return 1;
    if (a.airDate != null && b.airDate == null) return -1;
    final dated = a.airDate == null ? 0 : a.airDate!.compareTo(b.airDate!);
    if (dated != 0) return dated;
    if (a.airDate == null && a.season != b.season) {
      if (a.season == 0) return 1;
      if (b.season == 0) return -1;
    }
    final season = a.season!.compareTo(b.season!);
    return season != 0 ? season : a.episode!.compareTo(b.episode!);
  });
  return result;
}

List<VideoQueueItem> _filterFilmVideoTimeline(
  List<VideoQueueItem> ordered,
  List<FilmResource> resources,
  Map<int, Map<String, dynamic>> seasons, {
  required String selectedPath,
  required bool autoSeason,
  required bool allowGap,
  required Map<VideoQueueItem, int> decimalSeasons,
}) {
  final groups = {
    for (final item in ordered) (item.season!, item.episode!): item,
  };
  DateTime? date(int s, int e) => groups[(s, e)]?.airDate;
  final starts = <int, DateTime>{};
  for (final key in groups.keys.where((k) => k.$1 > 0)) {
    final value = date(key.$1, key.$2);
    if (value != null &&
        (starts[key.$1] == null || value.isBefore(starts[key.$1]!))) {
      starts[key.$1] = value;
    }
  }
  for (final s in groups.keys.map((k) => k.$1).where((s) => s > 0).toSet()) {
    final value = seasons[s]?['air_date'];
    final parsed = parseAirDate(value);
    if (parsed != null) starts[s] = parsed;
  }
  final positives =
      groups.keys.map((k) => k.$1).where((s) => s > 0).toSet().toList()..sort();
  int specialSeason(DateTime? value) {
    if (positives.isEmpty) return 0;
    if (value == null) return positives.last;
    final eligible = positives
        .where((s) => starts[s] != null && !starts[s]!.isAfter(value))
        .toList();
    eligible.sort((a, b) => starts[a]!.compareTo(starts[b]!));
    return eligible.isEmpty ? positives.first : eligible.last;
  }

  final selected = resources.firstWhere((r) => r.path == selectedPath);
  final anchor = selected.season == 0
      ? decimalSeasons[groups[(0, selected.episode!)]] ??
            specialSeason(date(0, selected.episode!))
      : selected.season!;
  final allowed = <int>{anchor};
  if (autoSeason) {
    if (allowGap) {
      allowed.addAll(positives);
    } else {
      for (var s = anchor - 1; positives.contains(s); s--) {
        allowed.add(s);
      }
      for (var s = anchor + 1; positives.contains(s); s++) {
        allowed.add(s);
      }
    }
  }
  return ordered
      .where(
        (item) => item.season! > 0
            ? allowed.contains(item.season)
            : decimalSeasons.containsKey(item)
            ? allowed.contains(decimalSeasons[item])
            : item.airDate == null ||
                  allowed.contains(specialSeason(item.airDate)),
      )
      .toList();
}

DateTime? parseAirDate(Object? value) {
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    return null;
  }
  final date = DateTime.tryParse(value);
  return date != null && date.toIso8601String().substring(0, 10) == value
      ? date
      : null;
}
