import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../../data/models/film_catalog_item.dart';
import '../../data/models/film_version.dart';
import '../../data/models/media_source.dart';
import 'season_video_playlist_collector.dart';
import 'special_video_playlist_collector.dart';
import 'film_video_timeline.dart';
import '../../data/models/video_queue.dart';
import '../../core/errors/app_exception.dart';

class FilmVersionFamily {
  FilmVersionFamily({
    required this.key,
    required this.name,
    required this.sourceId,
    required this.resources,
  });
  final String key, name, sourceId;
  final List<FilmResource> resources;
  int count(int season) => resources
      .where((r) => r.season == season && r.episode != null)
      .map((r) => r.episode)
      .toSet()
      .length;
}

String filmVersionKey(
  String source,
  String root,
  String collection,
  String tag,
) => sha256
    .convert(utf8.encode(jsonEncode([source, root, collection, tag])))
    .toString();

/// 只使用目录与明确标签，不以技术探测结果划分版本。
({String key, String name}) automaticFilmVersion(
  FilmResource resource, {
  String? sourcePath,
  String? sourceName,
}) {
  final path = sourcePath ?? resource.path;
  final parts = path.replaceAll('\\', '/').split('/');
  final marker = RegExp(
    r'\{(?:version|edition)-([^{}]+)\}',
    caseSensitive: false,
  ).firstMatch(path);
  final tag = marker?[1]?.trim() ?? '';
  var seasonIndex = -1;
  final rootDepth = sourcePath == null && resource.rootPath.isNotEmpty
      ? resource.rootPath.split('/').length
      : 0;
  if (resource.season == 0) {
    for (var i = rootDepth; i < parts.length - 1; i++) {
      if (SpecialVideoPlaylistCollector.isSpecialName(parts[i]) ||
          SeasonVideoPlaylistCollector.seasonFromFolder(parts[i]) != null &&
              RegExp(
                r'(?:\bseason\b|\bs\d|季)',
                caseSensitive: false,
              ).hasMatch(parts[i])) {
        seasonIndex = i;
        break;
      }
    }
  } else {
    for (var i = parts.length - 2; i >= rootDepth; i--) {
      if (SeasonVideoPlaylistCollector.seasonFromFolder(parts[i]) ==
          resource.season) {
        seasonIndex = i;
        break;
      }
    }
  }
  final collection = seasonIndex >= 0
      ? parts.take(seasonIndex).join('/')
      : parts.take(parts.length - 1).join('/');
  final server = resource.sourceKind.isMediaServer;
  // 服务器的虚拟路径是单集身份，不能用于跨集分组。
  final anchor = server && sourcePath == null ? '' : collection;
  final technicalCaption = RegExp(
    r'\b(?:h[ ._-]?26[45]|hevc|avc|av1|aac|ac3|dts|flac|truehd)\b',
    caseSensitive: false,
  ).hasMatch(sourceName ?? '');
  final explicitName = tag.isNotEmpty
      ? tag
      : server && !technicalCaption
      ? (sourceName ?? '').trim()
      : '';
  final label = explicitName.isNotEmpty
      ? explicitName
      : anchor.isEmpty
      ? resource.rootName
      : p.posix.basename(anchor);
  return (
    key: filmVersionKey(
      resource.sourceId,
      resource.rootPath,
      filmPathKey(anchor, resource.sourceKind),
      explicitName,
    ),
    name: '${resource.rootName} · $label',
  );
}

class FilmVersionIndex {
  FilmVersionIndex(List<FilmResource> resources) {
    final groups = <String, List<FilmResource>>{};
    final names = <String, String>{};
    for (final r in resources.where(
      (r) =>
          r.type == FilmMediaType.tv &&
          !r.isDisc &&
          r.season != null &&
          r.episode != null,
    )) {
      final automatic = automaticFilmVersion(r);
      final key = r.versionKey ?? automatic.key;
      names[key] = r.versionName ?? automatic.name;
      groups.putIfAbsent(key, () => []).add(r);
      resourceKeys[r.id] = key;
    }
    for (final e in groups.entries) {
      final numbers = <(int?, int?), List<FilmResource>>{};
      for (final r in e.value) {
        numbers.putIfAbsent((r.season, r.episode), () => []).add(r);
      }
      final usable = <FilmResource>[];
      for (final items in numbers.values) {
        if (items.length == 1) {
          usable.add(items.single);
        } else {
          unresolved.addAll(items);
        }
      }
      families.add(
        FilmVersionFamily(
          key: e.key,
          name: names[e.key]!,
          sourceId: e.value.first.sourceId,
          resources: usable,
        ),
      );
    }
    families.sort((a, b) => a.key.compareTo(b.key));
  }
  final List<FilmVersionFamily> families = [];
  final List<FilmResource> unresolved = [];
  final Map<int, String> resourceKeys = {};
  FilmVersionFamily? family(String key) =>
      families.where((f) => f.key == key).firstOrNull;
  List<FilmResource> selected(FilmVersionSelection selection) =>
      [
        for (final f in families)
          ...f.resources.where((r) => selection.forSeason(r.season!) == f.key),
      ]..sort((a, b) {
        final season = a.season!.compareTo(b.season!);
        return season != 0 ? season : a.episode!.compareTo(b.episode!);
      });
  FilmVersionSelection initial({String? recentSource, String? recentPath}) {
    final recent = families
        .where(
          (f) => f.resources.any(
            (r) => r.sourceId == recentSource && r.path == recentPath,
          ),
        )
        .firstOrNull;
    final ranked = List<FilmVersionFamily>.of(families)
      ..sort((a, b) {
        int count(FilmVersionFamily f) => f.resources
            .where((r) => r.season! > 0)
            .map((r) => (r.season, r.episode))
            .toSet()
            .length;
        final total = count(b).compareTo(count(a));
        return total != 0 ? total : a.key.compareTo(b.key);
      });
    return FilmVersionSelection(defaultKey: (recent ?? ranked.first).key);
  }
}

/// 单来源播放段在第一个其他来源处结束，后继由宿主确认后起播。
({List<VideoQueueItem> items, FilmResource? next}) selectedFilmPlayback(
  List<FilmResource> resources,
  Map<int, Map<String, dynamic>> seasons,
  FilmPlaybackContext context, {
  required String sourceId,
  required String targetPath,
  required bool autoSeason,
  required bool allowGap,
  required bool insertDecimalEpisodes,
}) {
  final selected = FilmVersionIndex(resources).selected(context.selection);
  if (!selected.any((r) => r.sourceId == sourceId && r.path == targetPath)) {
    throw AppException.config('所选版本不可用');
  }
  final timeline = buildFilmVideoTimeline(
    selected,
    seasons,
    selectedPath: targetPath,
    autoSeason: autoSeason,
    allowGap: allowGap,
    insertDecimalEpisodes: insertDecimalEpisodes,
  );
  final byPath = {for (final r in selected) (r.season, r.episode): r};
  final index = timeline.indexWhere(
    (i) =>
        i.versions.single.path == targetPath &&
        byPath[(i.season, i.episode)]!.sourceId == sourceId,
  );
  var start = index;
  while (start > 0 &&
      byPath[(timeline[start - 1].season, timeline[start - 1].episode)]!
              .sourceId ==
          sourceId) {
    start--;
  }
  var end = index + 1;
  while (end < timeline.length &&
      byPath[(timeline[end].season, timeline[end].episode)]!.sourceId ==
          sourceId) {
    end++;
  }
  return (
    items: timeline.sublist(start, end),
    next: end == timeline.length
        ? null
        : byPath[(timeline[end].season, timeline[end].episode)],
  );
}
