import 'package:path/path.dart' as p;
import 'dart:typed_data';
import 'dart:io';
import '../../core/errors/app_exception.dart';

import '../../core/utils/video_filename_parser.dart';
import '../../data/local/film_catalog_store.dart';
import '../../data/models/film_catalog_item.dart';
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
  FilmCatalogMatcher(this.store, this.tmdb, {this.filesFor, this.artworkBytes});
  final FilmCatalogStore store;
  final TmdbMetadataService tmdb;
  final Future<FilmFileMetadata?> Function(FilmCatalogRoot)? filesFor;
  final Future<Uint8List> Function(String)? artworkBytes;
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
          break;
        }
      }
    }
    var year = info?.year ?? episodeYear;
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
    return tmdb.details(type, id, language);
  }

  Future<FilmScanMetadataSession> scanSession(
    FilmCatalogRoot root, {
    required bool Function() cancelled,
  }) async {
    final resources = await store.resources(rootId: root.id);
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
        resources,
        enabled || local != null,
        await store.language(),
        cancelled,
      )
      ..error = credentialError
      ..files = local
      ..networkEnabled = enabled;
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
    List<FilmResource> resources,
    this.enabled,
    this.language,
    this.cancelled,
  ) : _existing = {for (final r in resources) r.pathKey: r};
  final FilmCatalogMatcher matcher;
  final FilmCatalogRoot root;
  final bool enabled;
  final String language;
  final bool Function() cancelled;
  final Map<String, FilmResource> _existing;
  final matches = <String, FilmScanMatch>{};
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
  bool get paused => _paused;

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

  Future<FilmWork> _lookup(int id) async {
    if (_works[id] case final work?) return work;
    final cached = await matcher.store.cachedWork(root.type, id);
    return _works[id] =
        cached?.language == language &&
            (root.type != FilmMediaType.movie ||
                cached!.metadataOrigin != 'network' ||
                cached.metadata.containsKey('belongs_to_collection'))
        ? cached!
        : await matcher.tmdb.details(root.type, id, language);
  }

  Future<FilmWork?> _search(FilmMatchHint hint) async {
    if (hint.title.isEmpty) return null;
    final key = (_nameKey(hint.title), hint.year);
    if (_queries.containsKey(key)) return _queries[key];
    final bilingual = root.type == FilmMediaType.tv
        ? _bilingualTitle.firstMatch(hint.title)
        : null;
    final digits = RegExp(r'\d+');
    final splitNames =
        bilingual != null &&
        digits.allMatches(bilingual[1]!).map((m) => m[0]).join(',') ==
            digits.allMatches(bilingual[2]!).map((m) => m[0]).join(',');
    final names = [
      hint.title,
      if (splitNames) ...[bilingual[1]!.trim(), bilingual[2]!.trim()],
    ];
    final nameKeys = names.map(_nameKey).toSet();
    final candidates = <int, FilmWork>{};
    // 双语名称分别检索并合并候选，名称证据冲突时保留待整理。
    for (final name in names) {
      if (cancelled()) return null;
      for (final candidate in await matcher.tmdb.search(
        root.type,
        name,
        language,
        year: hint.year,
      )) {
        candidates[candidate.tmdbId] = candidate;
      }
    }
    final eligible = {
      for (final work in candidates.values)
        if (root.type != FilmMediaType.movie ||
            key.$2 == null ||
            work.year == key.$2)
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
        final titles = _titles[candidate.tmdbId] ??= await matcher.tmdb
            .matchingTitles(root.type, candidate.tmdbId);
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
    if (root.type == FilmMediaType.tv &&
        exact.length > 1 &&
        hint.year != null) {
      final sameYear = exact.values
          .where((work) => work.year == hint.year)
          .toList();
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
              key.$2 != null &&
              work.year != key.$2)) {
        work = null;
      }
    }
    return _queries[key] = work;
  }

  Future<void> prepare(List<FilmScanEntry> entries) async {
    if (!enabled || _paused) return;
    for (final entry in entries) {
      if (cancelled() || _paused) return;
      final key = filmPathKey(entry.path, root.sourceKind);
      final existing = _existing[key];
      final hint = FilmCatalogMatcher.scanHint(
        entry.name,
        entry.parentPath,
        root.path,
        type: root.type,
      );
      if (hint.conflicting && existing?.bindingOrigin != 'manual') continue;
      FilmWork? work;
      var origin = existing?.workId != null
          ? existing!.bindingOrigin
          : 'search';
      FilmLocalMetadata? local;
      try {
        if (files?.localMode == true) {
          local = await files!.load(entry, language);
        }
        if (local != null && existing?.bindingOrigin != 'manual') {
          work = local.work;
          origin = 'nfo';
        } else if (existing?.workId != null) {
          work = await matcher.store.work(existing!.workId!);
        } else {
          final folderWork = root.type == FilmMediaType.tv && existing != null
              ? await matcher.store.directoryWork(existing)
              : root.type == FilmMediaType.tv
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
            work = await _search(hint);
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
            _seasons[seasonKey] =
                (work.id == 0
                    ? null
                    : await matcher.store.season(
                        work.id,
                        number,
                        language: language,
                      )) ??
                await matcher.tmdb.season(work.tmdbId, number, language);
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
