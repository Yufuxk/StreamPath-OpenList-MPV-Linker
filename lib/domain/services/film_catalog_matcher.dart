import 'package:path/path.dart' as p;
import 'dart:typed_data';
import 'dart:io';
import '../../core/errors/app_exception.dart';

import '../../core/utils/video_filename_parser.dart';
import '../../data/local/film_catalog_store.dart';
import '../../data/models/film_catalog_item.dart';
import 'film_logo_selector.dart';
import 'season_video_playlist_collector.dart';
import 'special_video_playlist_collector.dart';
import 'tmdb_metadata_service.dart';
import 'film_file_metadata.dart';

class FilmMatchHint {
  const FilmMatchHint(this.title, this.year, this.ids, this.episode);
  final String title;
  final int? year;
  final Set<int> ids;
  final (int, int)? episode;
  bool get conflicting => ids.length > 1;
}

/// 核验 ID、标题与相近名称，歧义保留人工确认。
class FilmCatalogMatcher {
  FilmCatalogMatcher(
    this.store,
    this.tmdb, {
    this.filesFor,
    this.artworkBytes,
    this.logoBytes,
  });

  /// 匹配规则版本；升级后自动重算非人工绑定。
  static const matchingVersion = 1;
  final FilmCatalogStore store;
  final TmdbMetadataService tmdb;
  final Future<FilmFileMetadata?> Function(FilmCatalogRoot)? filesFor;
  final Future<Uint8List> Function(String)? artworkBytes;
  final Future<Uint8List> Function(String)? logoBytes;
  static final _explicitId = RegExp(
    r'\{tmdb-(\d+)\}|\[tmdb-(\d+)\]|\[tmdbid-(\d+)\]',
    caseSensitive: false,
  );
  static final _singleEpisode = RegExp(
    r'(?<![a-z0-9])s(\d{1,2})[ ._-]*e(\d{1,4})(?![a-z0-9])',
    caseSensitive: false,
  );
  static final _episodeTail = RegExp(
    r'^(?:[ ._+&~–—-]|to|and)*(?:e\d|s\d{1,2}[ ._-]*e\d|\d{1,4}(?![a-z0-9]))',
    caseSensitive: false,
  );
  static final _directoryYear = RegExp(r'(?<!\d)((?:19|20)\d{2})(?!\d)');
  static final _postEpisodeYear = RegExp(
    r'^[ ._-]+((?:19|20)\d{2})(?=$|[ ._-])',
  );
  static final _fractionalEpisodeDescription = RegExp(
    r'^[ ._-]+\d+\.\d+\s*(?:集|话|話|回)(?=$|[ ._+&~–—-])',
  );

  /// 番剧三位以上编号视为绝对集号，季号未知时留给人工映射。
  static final _absoluteEpisode = RegExp(
    r'(?:[ ._]+-[ ._]+|\[)(\d{3,4})(?:v\d+)?(?![a-z0-9])',
  );
  static final _resolution = RegExp(
    r'(?<![a-z0-9])(?:[248]k|(?:480|576|720|1080|1440|2160|4320)[pi]|\d{3,4}x\d{3,4})(?![a-z0-9])',
    caseSensitive: false,
  );

  static FilmMatchHint hint(FilmResource resource) {
    return scanHint(
      resource.name,
      resource.parentPath,
      resource.rootPath,
      type: resource.type,
    );
  }

  static FilmMatchHint scanHint(
    String name,
    String parentPath,
    String rootPath, {
    FilmMediaType? type,
  }) {
    final names = <String>[name];
    var directory = parentPath;
    while (filmPathWithin(directory, rootPath)) {
      if (directory.isNotEmpty) names.add(directory.split('/').last);
      if (directory == rootPath || directory.isEmpty) break;
      directory = p.posix.dirname(directory);
      if (directory == '.') directory = '';
    }
    final ids = <int>{};
    for (final name in names) {
      for (final match in _explicitId.allMatches(name)) {
        final id = int.parse(match[1] ?? match[2] ?? match[3]!);
        if (id > 0) ids.add(id);
      }
    }
    final matches = _singleEpisode.allMatches(name).toList();
    (int, int)? episode;
    int? episodeYear;
    if (matches.length == 1) {
      final tail = name.substring(matches.single.end);
      final year = _postEpisodeYear.firstMatch(tail);
      // 后置年份和描述性小数集号不表示合并集，整数季集仍须唯一。
      final episodeTail = tail
          .replaceFirst(_postEpisodeYear, '')
          .replaceFirst(_fractionalEpisodeDescription, '');
      if (!_episodeTail.hasMatch(episodeTail)) {
        final s = int.parse(matches.single[1]!);
        final e = int.parse(matches.single[2]!);
        if (e > 0) {
          episode = (s, e);
          episodeYear = year == null ? null : int.parse(year[1]!);
        }
      }
    }
    // 季集前的画质标记不参与作品名识别，季集仍从原文件名提取。
    var info = const VideoFilenameParser().parse(
      type == FilmMediaType.tv && episode != null
          ? name.replaceAll(_resolution, ' ')
          : name,
      movie: type == FilmMediaType.movie,
    );
    final clean = p
        .basenameWithoutExtension(name)
        .replaceAll(_explicitId, '')
        .trim();
    var title = info?.title ?? clean.replaceAll(RegExp(r'[._]+'), ' ');
    // 季集标记缺失时用解析结果补全，季号缺失再取最近的季目录。
    // 已存在 SxxExx 标记的文件由上面的合并集判定负责；三位以上的
    // 番剧编号按绝对集号处理，不在此补全。
    if (episode == null &&
        type == FilmMediaType.tv &&
        info != null &&
        !_singleEpisode.hasMatch(name) &&
        !(info.season == null && _absoluteEpisode.hasMatch(name))) {
      final number = info.special == null
          ? int.tryParse(info.episodes ?? '')
          : null;
      if (number != null && number > 0) {
        var season = info.season;
        if (season == null) {
          for (final folder in names.skip(1)) {
            final value = SeasonVideoPlaylistCollector.seasonFromFolder(folder);
            if (value != null) {
              season = value;
              break;
            }
          }
        }
        episode = (season ?? 1, number);
      }
    }
    // 解析失败时仍要去掉版本标记与尾部年份，避免年份进入检索词。
    final fallback = info == null ? VideoFilenameParser.fallback(name) : null;
    var fallbackYear = fallback?.year;
    if (info == null && fallback != null && fallback.title.isNotEmpty) {
      title = fallback.title;
    }
    // 只有季集标记的文件从作品目录取名，忽略中间的季目录。
    if (episode != null && info == null) {
      for (final folder in names.skip(1)) {
        final cleanFolder = folder
            .replaceAll(_explicitId, '')
            .replaceFirst(RegExp(r'^(?:19|20)\d{2}\s*[-–—]\s*'), '')
            .replaceFirst(RegExp(r'^\d{1,2}[.、]\s*'), '')
            .replaceAll(RegExp(r'^[《「『]+|[》」』]+$'), '')
            .trim();
        final parsed = const VideoFilenameParser().parse('$cleanFolder.mkv');
        final candidate =
            parsed?.title ??
            cleanFolder.replaceAll(RegExp(r'[._]+'), ' ').trim();
        if (RegExp(
          r'^(?:s\d+|season\s*\d+|第.+季|specials?|extras?|特[别別]篇|特典)$',
          caseSensitive: false,
        ).hasMatch(candidate)) {
          continue;
        }
        if (candidate.isNotEmpty) {
          title = candidate;
          info = parsed;
          fallbackYear = null;
          break;
        }
      }
    }
    var year = info?.year ?? fallbackYear ?? episodeYear;
    if (type == FilmMediaType.tv && episode != null && year == null) {
      for (final folder in names.skip(1)) {
        final years = _directoryYear.allMatches(folder).toList();
        if (years.length == 1) {
          year = int.parse(years.single[1]!);
          break;
        }
      }
    }
    return FilmMatchHint(title.trim(), year, ids, episode);
  }

  /// 容器名称是否只是季、特典或纯数字，不能代表作品身份。
  static bool genericContainerTitle(String title) {
    final value = title.trim();
    if (value.length < 2) return true;
    if (RegExp(r'^\d{1,4}$').hasMatch(value)) return true;
    if (SpecialVideoPlaylistCollector.isSpecialName(value)) return true;
    return SeasonVideoPlaylistCollector.seasonFromFolder(value) != null;
  }

  /// 条目容器（根下第一层目录）的名称与年份，作为文件名检索失败时的兜底依据。
  static ({String title, int? year})? containerHint(
    String parentPath,
    String rootPath,
  ) {
    final parent = parentPath.replaceAll('\\', '/');
    final root = rootPath.replaceAll('\\', '/');
    if (parent == root || !filmPathWithin(parent, root)) return null;
    final prefix = root.isEmpty ? '' : '$root/';
    final inside = parent.substring(prefix.length);
    if (inside.isEmpty) return null;
    var label = inside
        .split('/')
        .first
        .replaceFirst(RegExp(r'^(?:19|20)\d{2}\s*[-–—]\s*'), '')
        .replaceFirst(RegExp(r'^\d{1,2}[.、]\s*'), '')
        .trim();
    if (label.isEmpty) return null;
    int? year;
    final years = _directoryYear.allMatches(label).toList();
    if (years.length == 1) {
      year = int.parse(years.single[1]!);
      label = label.replaceFirst(years.single[0]!, ' ');
    }
    label = label
        .replaceAll(RegExp(r'[《》「」『』]'), ' ')
        .replaceAll(RegExp(r'^[\s\-–—.:：]+|[\s\-–—.:：]+$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final stripped = VideoFilenameParser.stripVersionMarkers(label);
    final title = stripped.isEmpty ? label : stripped;
    return title.isEmpty ? null : (title: title, year: year);
  }

  Future<FilmWork> _details(FilmMediaType type, int id, String language) async {
    final read = logoBytes;
    final cached = read == null ? null : await store.cachedWork(type, id);
    final previous = cached?.metadata['logo_path'] as String?;
    return tmdb.details(
      type,
      id,
      language,
      chooseLogo: read == null
          ? null
          : (candidates) async {
              if (previous != null &&
                  cached?.metadata['logo_selection_version'] == 1 &&
                  candidates.any((c) => c.path == previous)) {
                return previous;
              }
              return selectBestLogo(
                candidates,
                read: read,
                preferredPath: previous,
              );
            },
    );
  }

  Future<FilmWork> lookup(
    FilmMediaType type,
    int id, {
    bool refresh = false,
  }) async {
    final language = await store.language();
    final cached = await store.cachedWork(type, id);
    if (!refresh &&
        cached?.language == language &&
        (type != FilmMediaType.movie ||
            cached!.metadataOrigin != 'network' ||
            cached.metadata.containsKey('belongs_to_collection') ||
            !await tmdb.hasToken())) {
      return cached!;
    }
    return _details(type, id, language);
  }

  Future<FilmScanMetadataSession> scanSession(
    FilmCatalogRoot root, {
    required bool Function() cancelled,
    bool lazyBindings = false,
  }) async {
    final bindings = lazyBindings
        ? <String, FilmScanBinding>{}
        : await store.scanBindings(root.id);
    final local = await filesFor?.call(root);
    var enabled = false;
    String? credentialError;
    try {
      enabled = local?.localMode != true && await tmdb.hasToken();
    } on FilmCatalogException catch (cause) {
      credentialError = cause.code;
    }
    return FilmScanMetadataSession(
        this,
        root,
        bindings,
        enabled || local != null,
        await store.language(),
        cancelled,
      )
      ..lazyBindings = lazyBindings
      ..error = credentialError
      ..files = local
      ..networkEnabled = enabled
      ..staleBindings = await store.matcherVersion() < matchingVersion;
  }

  Future<Map<String, dynamic>?> loadSeason(
    FilmWork work,
    int number, {
    bool refresh = false,
  }) async {
    final language = await store.language();
    final cached = await store.season(work.id, number, language: language);
    if (filesFor != null) {
      final resources = await store.resources(workId: work.id, limit: 1);
      if (resources.isNotEmpty) {
        final root = (await store.root(resources.first.rootId))!;
        if ((await filesFor!(root))?.localMode == true && !refresh) {
          return cached;
        }
      }
    }
    if (work.tmdbId <= 0 || work.metadataOrigin != 'network') return cached;
    if (!refresh && cached != null) return cached;
    Map<String, dynamic> metadata;
    try {
      metadata = await tmdb.season(work.tmdbId, number, language);
    } on FilmCatalogException catch (cause) {
      // TMDB 未收录的季使用作品资料展示，其他请求错误继续上报。
      if (cause.code == 'metadataNotFound') return null;
      rethrow;
    }
    await store.saveSeason(work.id, number, language, metadata);
    return metadata;
  }

  /// 整理已提交资源，人工关联与人工季集始终优先。
  Future<void> organize(int rootId, {bool Function()? cancelled}) async {
    if (!await tmdb.hasToken()) return;
    final details = <(FilmMediaType, int), FilmWork>{};
    final seasons = <(int, int)>{};
    var offset = 0;
    while (true) {
      if (cancelled?.call() == true) return;
      final batch = await store.resources(
        rootId: rootId,
        limit: 200,
        offset: offset,
      );
      if (batch.isEmpty) break;
      offset += batch.length;
      for (final initial in batch) {
        if (cancelled?.call() == true) return;
        if (initial.availability != 'present') continue;
        var resource = initial;
        final suggestion = hint(resource);
        if (resource.workId == null && !suggestion.conflicting) {
          final folderWork = resource.type == FilmMediaType.tv
              ? await store.directoryWork(resource)
              : null;
          if (folderWork != null &&
              suggestion.ids.isNotEmpty &&
              suggestion.ids.single != folderWork.tmdbId) {
            continue;
          }
          FilmWork? work;
          if (suggestion.ids.isNotEmpty) {
            final key = (resource.type, suggestion.ids.single);
            work = details[key] ??= await lookup(key.$1, key.$2);
          } else {
            work = folderWork;
          }
          if (work == null) continue;
          if (cancelled?.call() == true) return;
          await store.bind(
            [resource],
            work,
            origin: suggestion.ids.isNotEmpty ? 'explicit' : 'folder',
          );
          resource = (await store.resource(resource.id))!;
        }
        if (resource.type != FilmMediaType.tv ||
            resource.workId == null ||
            resource.mappingOrigin == 'manual' ||
            suggestion.episode == null) {
          continue;
        }
        if (suggestion.conflicting && resource.bindingOrigin != 'manual') {
          continue;
        }
        final work = (await store.work(resource.workId!))!;
        final episode = suggestion.episode!;
        final key = (work.id, episode.$1);
        if (seasons.add(key)) await loadSeason(work, episode.$1);
        if (cancelled?.call() == true) return;
        if (resource.season != episode.$1 || resource.episode != episode.$2) {
          await store.mapEpisodes({resource: episode}, origin: 'filename');
        }
      }
    }
  }

  Future<void> confirm(
    List<FilmResource> resources,
    FilmMediaType type,
    int id, {
    String? directoryPath,
  }) async {
    final work = await lookup(type, id);
    await store.bind(resources, work, directoryPath: directoryPath);
    for (final resource in resources) {
      final root = (await store.root(resource.rootId))!;
      final files = await filesFor?.call(root);
      if (files?.canWrite != true) continue;
      try {
        final current = (await store.resourceAt(
          resource.sourceId,
          resource.path,
        ))!;
        await files!.writeWork(
          work,
          current,
          seriesDirectory: directoryPath,
          seasonMetadata: current.season == null
              ? null
              : await store.season(current.workId!, current.season!),
          poster: work.posterPath == null
              ? null
              : await artworkBytes?.call(work.posterPath!),
          backdrop: work.backdropPath == null
              ? null
              : await artworkBytes?.call(work.backdropPath!),
        );
      } on FilmCatalogException {
        throw const FilmCatalogException('metadataWriteFailed');
      } on FileSystemException {
        throw const FilmCatalogException('metadataWriteFailed');
      } on AppException {
        throw const FilmCatalogException('metadataWriteFailed');
      }
    }
    // 作品关联先保存，季资料请求错误由界面单独显示。
  }

  Future<void> verifyEpisodes(List<int> resourceIds) async {
    final seasons = <(int, int)>{};
    for (final id in resourceIds) {
      final resource = await store.resource(id);
      if (resource == null ||
          resource.type != FilmMediaType.tv ||
          resource.workId == null ||
          resource.mappingOrigin == 'manual') {
        continue;
      }
      final episode = hint(resource).episode;
      if (episode == null) continue;
      final work = (await store.work(resource.workId!))!;
      final key = (work.id, episode.$1);
      if (seasons.add(key)) await loadSeason(work, episode.$1);
      await store.mapEpisodes({resource: episode}, origin: 'filename');
    }
  }

  /// 同一作品的兄弟容器若剧集重叠且名称差异不是版本标记，保留证据最强的一方。
  /// 真实库中同级目录代表不同作品，把两个作品当作版本是身份识别错误。
  Future<int> resolveConflicts(int rootId) async {
    final resources = await store.resources(rootId: rootId);
    final containers = <String, List<FilmResource>>{};
    final episodes = <String, Set<(int?, int?)>>{};
    for (final resource in resources) {
      if (resource.type != FilmMediaType.tv || resource.workId == null) {
        continue;
      }
      final container = _containerOf(resource);
      if (container == null) continue;
      (containers[container] ??= []).add(resource);
      (episodes[container] ??= {}).add((resource.season, resource.episode));
    }
    final byWork = <int, List<String>>{};
    for (final entry in containers.entries) {
      final workId = entry.value.first.workId!;
      (byWork[workId] ??= []).add(entry.key);
    }
    final losers = <int>[];
    for (final group in byWork.entries) {
      if (group.value.length < 2) continue;
      final labels = {
        for (final path in group.value)
          path: VideoFilenameParser.stripVersionMarkers(p.posix.basename(path)),
      };
      final conflicts = <String, Set<String>>{
        for (final path in group.value) path: <String>{},
      };
      var conflict = false;
      for (var i = 0; i < group.value.length; i++) {
        for (var j = i + 1; j < group.value.length; j++) {
          final a = group.value[i];
          final b = group.value[j];
          if (p.posix.dirname(a) != p.posix.dirname(b)) continue;
          if (_identityKey(labels[a]!) == _identityKey(labels[b]!)) continue;
          if (episodes[a]!.intersection(episodes[b]!).isEmpty) continue;
          conflict = true;
          conflicts[a]!.add(b);
          conflicts[b]!.add(a);
        }
      }
      if (!conflict) continue;
      final work = await store.work(group.key);
      if (work == null) continue;
      double score(String path) {
        final key = FilmScanMetadataSession._nameKey(labels[path]!);
        return [
              FilmScanMetadataSession._nameKey(work.title),
              FilmScanMetadataSession._nameKey(work.originalTitle),
            ]
            .map((title) => FilmScanMetadataSession._similarity(key, title))
            .reduce((x, y) => x > y ? x : y);
      }

      final pending = Set<String>.of(conflicts.keys);
      while (pending.isNotEmpty) {
        final seed = pending.first;
        final component = <String>{seed};
        final queue = <String>[seed];
        while (queue.isNotEmpty) {
          for (final next in conflicts[queue.removeLast()]!) {
            if (component.add(next)) {
              queue.add(next);
            }
          }
        }
        pending.removeAll(component);
        if (component.length < 2) continue;
        final ranked = component.toList()
          ..sort((a, b) {
            final byScore = score(b).compareTo(score(a));
            if (byScore != 0) return byScore;
            final byCount = containers[b]!.length.compareTo(
              containers[a]!.length,
            );
            return byCount != 0 ? byCount : a.compareTo(b);
          });
        for (final path in ranked.skip(1)) {
          losers.addAll(
            containers[path]!
                .where((r) => r.bindingOrigin != 'manual')
                .map((r) => r.id),
          );
        }
      }
    }
    return losers.isEmpty ? 0 : store.clearBindings(losers);
  }

  /// 特典目录内没有季集标记的媒体按 S00 顺序编号，避免长期留在待整理。
  Future<int> assignExtras(int rootId) async {
    final resources = await store.resources(rootId: rootId);
    final pending = <int, List<FilmResource>>{};
    for (final resource in resources) {
      if (resource.type != FilmMediaType.tv ||
          resource.workId == null ||
          resource.season != null ||
          resource.mappingOrigin == 'manual' ||
          !_insideSpecials(resource)) {
        continue;
      }
      (pending[resource.workId!] ??= []).add(resource);
    }
    var assigned = 0;
    for (final entry in pending.entries) {
      var next = 1;
      for (final resource in resources) {
        if (resource.workId != entry.key ||
            resource.season != 0 ||
            resource.episode == null) {
          continue;
        }
        if (resource.episode! >= next) next = resource.episode! + 1;
      }
      final ordered = entry.value..sort((a, b) => a.path.compareTo(b.path));
      final mappings = <FilmResource, (int, int)>{};
      for (final resource in ordered) {
        mappings[resource] = (0, next++);
      }
      await store.mapEpisodes(mappings, origin: 'filename');
      assigned += mappings.length;
    }
    return assigned;
  }

  /// 资源是否位于条目容器下的特典目录中。
  static bool _insideSpecials(FilmResource resource) {
    final path = resource.path.replaceAll('\\', '/');
    final root = resource.rootPath.replaceAll('\\', '/');
    final prefix = root.isEmpty ? '' : '$root/';
    if (!path.startsWith(prefix)) return false;
    final parts = path.substring(prefix.length).split('/');
    if (parts.length < 3) return false;
    for (final part in parts.skip(1).take(parts.length - 2)) {
      if (SpecialVideoPlaylistCollector.isSpecialName(part)) return true;
    }
    return false;
  }

  /// 容器名称归一化：只去标点与大小写，不抹掉剧场版等区分后缀。
  static String _identityKey(String value) => value.toLowerCase().replaceAll(
    RegExp(r'''[\s._:\-–—'’"()\[\]{}!?，。：、！？」「『』《》·・~～〜]+'''),
    '',
  );

  static String? _containerOf(FilmResource resource) {
    final parent = resource.parentPath.replaceAll('\\', '/');
    final root = resource.rootPath.replaceAll('\\', '/');
    if (parent == root) return null;
    final prefix = root.isEmpty ? '' : '$root/';
    if (!parent.startsWith(prefix)) return null;
    final rest = parent.substring(prefix.length);
    if (rest.isEmpty) return null;
    return '$prefix${rest.split('/').first}';
  }

  Future<Map<FilmResource, (int, int)>> mappingPreview(
    List<FilmResource> resources,
    int season,
    int firstEpisode,
  ) async {
    if (resources.isEmpty ||
        season < 0 ||
        firstEpisode <= 0 ||
        resources.first.workId == null ||
        resources.any((r) => r.workId != resources.first.workId)) {
      throw const FilmCatalogException('invalidEpisode');
    }
    final mappings = <FilmResource, (int, int)>{};
    for (var i = 0; i < resources.length; i++) {
      final episode = firstEpisode + i;
      mappings[resources[i]] = (season, episode);
    }
    return mappings;
  }

  Future<void> refresh(FilmWork work) async {
    await store.refreshWork(
      await lookup(work.type, work.tmdbId, refresh: true),
    );
    if (work.type == FilmMediaType.tv) {
      final resources = await store.resources(workId: work.id);
      final numbers = resources
          .map((r) => r.season ?? hint(r).episode?.$1)
          .whereType<int>()
          .toSet();
      for (final number in numbers) {
        await loadSeason(work, number, refresh: true);
      }
    }
  }
}

/// 刮削任务共享作品与季缓存，扫描任务只提供发现的文件。
class FilmScanMetadataSession {
  FilmScanMetadataSession(
    this.matcher,
    this.root,
    this._existing,
    this.enabled,
    this.language,
    this.cancelled,
  );
  final FilmCatalogMatcher matcher;
  final FilmCatalogRoot root;
  final bool enabled;
  final String language;
  final bool Function() cancelled;
  final Map<String, FilmScanBinding> _existing;
  final matches = <String, FilmScanMatch>{};
  final _lookupRequests = <int, Future<FilmWork>>{};
  final _queryRequests = <(String, int?), Future<FilmWork?>>{};
  final _titleRequests = <int, Future<List<String>>>{};
  final _seasonLoads = <(int, int), Future<Map<String, dynamic>?>>{};
  final _queries = <(String, int?), FilmWork?>{};
  final _works = <int, FilmWork>{};
  final _titles = <int, List<String>>{};
  final _seasons = <(int, int), Map<String, dynamic>?>{};
  static final _bilingualTitle = RegExp(
    r'^([\u3400-\u9fff][\u3400-\u9fff\s\d:：·!?！？~～–—-]*?)\s+([a-zA-Z].*)$',
  );
  String? error;
  bool _paused = false;
  bool networkEnabled = true;
  FilmFileMetadata? files;
  int scraped = 0;
  bool staleBindings = false;
  bool lazyBindings = false;
  bool get paused => _paused;

  void releaseCommitted(Iterable<String> keys) {
    for (final key in keys) {
      matches.remove(key);
      _existing.remove(key);
    }
  }

  void resume() {
    _paused = false;
    error = null;
  }

  static String _nameKey(String name) => name
      .toLowerCase()
      .replaceAll(RegExp(r'剧场版|劇場版'), '')
      .replaceAll(
        RegExp(r'''[\s._:\-–—'’"()\[\]{}!?，。：、！？」「『』《》·・~～〜]+'''),
        '',
      );

  // 归一化编辑距离支持错字、漏字和相邻字对调，保留续作数字。
  static double _similarity(String a, String b) {
    if (a == b) return 1;
    if (a.length < 4 || b.length < 4) return 0;
    final digits = RegExp(r'\d+');
    if (digits.allMatches(a).map((m) => m[0]).join(',') !=
        digits.allMatches(b).map((m) => m[0]).join(',')) {
      return 0;
    }
    final distances = List.generate(
      a.length + 1,
      (_) => List<int>.filled(b.length + 1, 0),
    );
    for (var i = 0; i <= a.length; i++) {
      distances[i][0] = i;
    }
    for (var j = 0; j <= b.length; j++) {
      distances[0][j] = j;
    }
    for (var i = 1; i <= a.length; i++) {
      for (var j = 1; j <= b.length; j++) {
        final costs = [
          distances[i - 1][j] + 1,
          distances[i][j - 1] + 1,
          distances[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1),
          if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1])
            distances[i - 2][j - 2] + 1,
        ];
        distances[i][j] = costs.reduce((x, y) => x < y ? x : y);
      }
    }
    final length = a.length > b.length ? a.length : b.length;
    return 1 - distances[a.length][b.length] / length;
  }

  void _failed(FilmCatalogException cause) {
    error ??= cause.code;
    // 认证、限流与网络故障停止本轮后续请求，目录枚举仍继续。
    if (cause.code != 'metadataNotFound') _paused = true;
  }

  Future<FilmWork> _lookup(int id) => _lookupRequests.putIfAbsent(
    id,
    () => _lookupUnshared(id).whenComplete(() {
      _lookupRequests.remove(id);
    }),
  );

  Future<FilmWork> _lookupUnshared(int id) async {
    if (_works[id] case final work?) return work;
    final cached = await matcher.store.cachedWork(root.type, id);
    return _works[id] =
        cached?.language == language &&
            (root.type != FilmMediaType.movie ||
                cached!.metadataOrigin != 'network' ||
                cached.metadata.containsKey('belongs_to_collection'))
        ? cached!
        : await matcher._details(root.type, id, language);
  }

  Future<FilmWork?> _search(FilmMatchHint hint) => _queryRequests.putIfAbsent(
    (_nameKey(hint.title), hint.year),
    () => _searchUnshared(hint).whenComplete(() {
      _queryRequests.remove((_nameKey(hint.title), hint.year));
    }),
  );

  Future<FilmWork?> _searchUnshared(FilmMatchHint hint) async {
    if (hint.title.isEmpty) return null;
    final key = (_nameKey(hint.title), hint.year);
    if (_queries.containsKey(key)) return _queries[key];
    // 完整名称是主要证据，双语拆分只补充解释，不能推翻完整名称的结论。
    var work = await _matchTitles(hint, [hint.title]);
    if (work == null) {
      final parts = _splitBilingualTitle(hint.title);
      if (parts != null) {
        work = await _matchTitles(hint, [hint.title, ...parts]);
      }
    }
    return _queries[key] = work;
  }

  /// 仅当两段分别以中文字符与拉丁字母为主时，才视为同一作品的双语标题并列。
  static List<String>? _splitBilingualTitle(String title) {
    final match = _bilingualTitle.firstMatch(title);
    if (match == null) return null;
    final cjk = match[1]!.trim();
    final latin = match[2]!.trim();
    if (cjk.length < 2 || latin.length < 2) return null;
    if (_cjkRatio(cjk) < .6 || _latinRatio(latin) < .6) return null;
    final digits = RegExp(r'\d+');
    if (digits.allMatches(cjk).map((m) => m[0]).join(',') !=
        digits.allMatches(latin).map((m) => m[0]).join(',')) {
      return null;
    }
    return [cjk, latin];
  }

  static double _cjkRatio(String value) => value.isEmpty
      ? 0
      : value.runes.where((r) => r >= 0x3400 && r <= 0x9fff).length /
            value.runes.length;

  static double _latinRatio(String value) => value.isEmpty
      ? 0
      : value.runes
                .where(
                  (r) =>
                      (r >= 0x41 && r <= 0x5a) ||
                      (r >= 0x61 && r <= 0x7a) ||
                      r == 0x20,
                )
                .length /
            value.runes.length;

  Future<FilmWork?> _matchTitles(FilmMatchHint hint, List<String> names) async {
    final nameKeys = names.map(_nameKey).toSet();
    final candidates = <int, FilmWork>{};
    Future<void> collect(int page) async {
      // 双语名称分别检索并合并候选，名称证据冲突时保留待整理。
      for (final name in names) {
        if (cancelled()) return;
        for (final candidate in await matcher.tmdb.search(
          root.type,
          name,
          language,
          year: hint.year,
          page: page,
        )) {
          candidates[candidate.tmdbId] = candidate;
        }
      }
    }

    await collect(1);
    var work = await _rankTitles(hint, nameKeys, candidates);
    // 首页候选没有可用结论时补读第二页，只额外消耗一次请求。
    if (work == null && candidates.length >= 20) {
      await collect(2);
      work = await _rankTitles(hint, nameKeys, candidates);
    }
    return work;
  }

  Future<FilmWork?> _rankTitles(
    FilmMatchHint hint,
    Set<String> nameKeys,
    Map<int, FilmWork> candidates,
  ) async {
    final year = hint.year;
    final eligible = {
      for (final work in candidates.values)
        if (root.type != FilmMediaType.movie ||
            year == null ||
            work.year == year)
          work.tmdbId: work,
    };
    final exact = {
      for (final work in eligible.values)
        if (nameKeys.contains(_nameKey(work.title)) ||
            nameKeys.contains(_nameKey(work.originalTitle)))
          work.tmdbId: work,
    };
    var fuzzy = false;
    if (exact.isEmpty) {
      final scores = <(int, double)>[];
      for (final candidate in eligible.values) {
        if (cancelled()) return null;
        final titles = _titles[candidate.tmdbId] ??= await _titleRequests
            .putIfAbsent(
              candidate.tmdbId,
              () => matcher.tmdb
                  .matchingTitles(root.type, candidate.tmdbId)
                  .whenComplete(() {
                    _titleRequests.remove(candidate.tmdbId);
                  }),
            );
        final score = [candidate.title, candidate.originalTitle, ...titles]
            .expand(
              (title) =>
                  nameKeys.map((name) => _similarity(_nameKey(title), name)),
            )
            .reduce((a, b) => a > b ? a : b);
        scores.add((candidate.tmdbId, score));
        if (score == 1) {
          exact[candidate.tmdbId] = candidate;
        }
      }
      if (exact.isEmpty && scores.isNotEmpty) {
        scores.sort((a, b) => b.$2.compareTo(a.$2));
        if (scores.first.$2 >= .85 &&
            (scores.length == 1 || scores.first.$2 - scores[1].$2 >= .08)) {
          exact[scores.first.$1] = eligible[scores.first.$1]!;
          fuzzy = true;
        }
      }
    }
    // 剧集年份仅消除同名歧义，后续季的发行年可以不同于首播年。
    var matchedYear = false;
    if (root.type == FilmMediaType.tv && exact.length > 1 && year != null) {
      final sameYear = exact.values.where((work) => work.year == year).toList();
      if (sameYear.length == 1) {
        exact
          ..clear()
          ..[sameYear.single.tmdbId] = sameYear.single;
        matchedYear = true;
      }
    }
    FilmWork? work;
    if (exact.length == 1) {
      work = await _lookup(exact.keys.single);
      final titles = [work.title, work.originalTitle, ...?_titles[work.tmdbId]];
      if (!titles.any((title) {
            return nameKeys.any(
              (name) => _similarity(_nameKey(title), name) >= (fuzzy ? .85 : 1),
            );
          }) ||
          ((root.type == FilmMediaType.movie || matchedYear) &&
              year != null &&
              work.year != year)) {
        work = null;
      }
    }
    return work;
  }

  Future<void> prepare(
    List<FilmScanEntry> entries, {
    Map<int, FilmWork?>? workCache,
    bool deferLocalFallback = false,
  }) async {
    if (!enabled || _paused) return;
    if (lazyBindings && entries.isNotEmpty) {
      _existing.addAll(
        await matcher.store.scanBindings(
          root.id,
          paths: entries
              .map((entry) => filmPathKey(entry.path, root.sourceKind))
              .toList(),
        ),
      );
    }
    final works = workCache ?? <int, FilmWork?>{};
    for (final entry in entries) {
      if (cancelled() || _paused) return;
      final key = filmPathKey(entry.path, root.sourceKind);
      final existing = _existing[key];
      // 匹配算法升级后非人工绑定视为可重算；人工绑定与人工季集始终保留。
      final bound = staleBindings && existing?.bindingOrigin != 'manual'
          ? null
          : existing;
      final hint = FilmCatalogMatcher.scanHint(
        entry.name,
        entry.parentPath,
        root.path,
        type: root.type,
      );
      if (hint.conflicting && existing?.bindingOrigin != 'manual') continue;
      FilmWork? work;
      var origin = bound?.workId != null ? bound!.bindingOrigin : 'search';
      FilmLocalMetadata? local;
      try {
        if (files?.localMode == true) {
          local = await files!.load(entry, language);
        }
        if (local != null && existing?.bindingOrigin != 'manual') {
          work = local.work;
          origin = 'nfo';
        } else if (bound?.workId != null) {
          final id = bound!.workId!;
          if (!works.containsKey(id)) works[id] = await matcher.store.work(id);
          work = works[id];
        } else {
          final folderWork = root.type == FilmMediaType.tv
              ? await matcher.store.directoryWorkAt(
                  root.id,
                  entry.parentPath,
                  root.sourceKind,
                )
              : null;
          if (folderWork != null &&
              hint.ids.isNotEmpty &&
              hint.ids.single != folderWork.tmdbId) {
            continue;
          }
          if (hint.ids.isNotEmpty && networkEnabled) {
            work = await _lookup(hint.ids.single);
            origin = 'explicit';
          } else if (folderWork != null) {
            work = folderWork;
            origin = 'folder';
          } else if (networkEnabled) {
            final container = FilmCatalogMatcher.containerHint(
              entry.parentPath,
              root.path,
            );
            // 剧集的条目容器就是作品身份，先按容器检索再退回文件名。
            if (root.type == FilmMediaType.tv &&
                container != null &&
                !FilmCatalogMatcher.genericContainerTitle(container.title)) {
              try {
                work = await _search(
                  FilmMatchHint(
                    container.title,
                    container.year,
                    const {},
                    null,
                  ),
                );
              } on FilmCatalogException catch (cause) {
                // 容器只是补充依据，数据类错误退回文件名检索；其余错误继续上报。
                if (cause.code != 'metadataNotFound' &&
                    cause.code != 'invalidMetadata') {
                  rethrow;
                }
              }
              if (work != null) origin = 'folder';
            }
            work ??= await _search(hint);
            // 电影的文件名无法确定时，用条目目录名称再检索一次；剧集已先按容器检索。
            if (work == null &&
                root.type == FilmMediaType.movie &&
                container != null &&
                _nameKey(container.title) != _nameKey(hint.title)) {
              // 电影先带目录年份筛选，目录年份过期时再去掉年份重试。
              work = await _search(
                FilmMatchHint(container.title, container.year, const {}, null),
              );
              if (work == null && container.year != null) {
                work = await _search(
                  FilmMatchHint(container.title, null, const {}, null),
                );
              }
            }
          }
        }
        if (work != null &&
            (work.language != language ||
                work.type == FilmMediaType.movie &&
                    work.metadataOrigin == 'network' &&
                    !work.metadata.containsKey('belongs_to_collection')) &&
            networkEnabled &&
            work.tmdbId > 0) {
          work = await _lookup(work.tmdbId);
        }
      } on FilmCatalogException catch (cause) {
        _failed(cause);
        if (files == null) continue;
        networkEnabled = false;
        _paused = false;
      }
      if (work == null && files != null && !cancelled()) {
        if (deferLocalFallback) continue;
        local = await files!.load(entry, language);
        if (local != null) {
          work = local.work;
          origin = 'nfo';
        }
      }
      if (work == null || cancelled()) continue;
      Map<String, dynamic>? metadata;
      final episode =
          local?.episode ??
          (root.type == FilmMediaType.tv && existing?.mappingOrigin != 'manual'
              ? hint.episode
              : null);
      final number =
          local?.episode?.$1 ??
          (existing?.mappingOrigin == 'manual'
              ? existing?.season
              : hint.episode?.$1);
      metadata = local?.season;
      if (root.type == FilmMediaType.tv &&
          number != null &&
          metadata == null &&
          networkEnabled &&
          work.tmdbId > 0) {
        try {
          final seasonKey = (work.tmdbId, number);
          if (!_seasons.containsKey(seasonKey)) {
            _seasons[seasonKey] = await _seasonLoads.putIfAbsent(
              seasonKey,
              () async {
                try {
                  return (work!.id == 0
                          ? null
                          : await matcher.store.season(
                              work.id,
                              number,
                              language: language,
                            )) ??
                      await matcher.tmdb.season(work.tmdbId, number, language);
                } finally {
                  _seasonLoads.remove(seasonKey);
                }
              },
            );
          }
          metadata = _seasons[seasonKey];
        } on FilmCatalogException catch (cause) {
          if (cause.code == 'metadataNotFound') {
            _seasons[(work.tmdbId, number)] = null;
          } else {
            _failed(cause);
            continue;
          }
        }
      }
      if (cancelled()) return;
      matches[key] = FilmScanMatch(
        work: work,
        origin: origin,
        bindingVersion: existing?.bindingVersion ?? 0,
        episode: episode,
        seasonNumber: number,
        seasonMetadata: metadata,
      );
      scraped++;
    }
  }
}
