import '../../data/models/film_catalog_item.dart';
import '../../data/models/video_queue.dart';

/// 日期缺失项目作为独立尾段排序，比较器保持传递性。
List<VideoQueueItem> buildFilmVideoTimeline(
  List<FilmResource> resources,
  Map<int, Map<String, dynamic>> seasons, {
  required String selectedPath,
  required bool autoSeason,
  required bool allowGap,
}) {
  final ordered = buildFilmVideoOrder(resources, seasons);
  return _filterFilmVideoTimeline(
    ordered,
    resources,
    seasons,
    selectedPath: selectedPath,
    autoSeason: autoSeason,
    allowGap: allowGap,
  );
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
            .map((r) => VideoQueueVersion(path: r.path, name: r.name))
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
      ? specialSeason(date(0, selected.episode!))
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
