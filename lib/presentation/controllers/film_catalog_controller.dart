import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../core/errors/app_exception.dart';
import '../../data/local/film_catalog_store.dart';
import '../../data/models/film_catalog_item.dart';
import '../../data/models/film_home_section.dart';
import '../../domain/repositories/media_directory_source.dart';
import '../../domain/services/film_catalog_image_cache.dart';
import '../../domain/services/film_catalog_matcher.dart';
import '../../domain/services/film_catalog_scanner.dart';
import '../../domain/services/tmdb_metadata_service.dart';
import 'film_media_probe_controller.dart';

class FilmCatalogController extends ChangeNotifier {
  FilmCatalogController({
    required this.store,
    required this.tmdb,
    required this.images,
    required this.sourceFor,
    this.mediaProbe,
  }) : scanner = FilmCatalogScanner(store),
       matcher = FilmCatalogMatcher(store, tmdb) {
    store.addListener(_changed);
    mediaProbe?.addListener(_notify);
  }
  final FilmCatalogStore store;
  final TmdbMetadataService tmdb;
  final FilmCatalogImageCache images;
  final MediaDirectorySource Function(FilmCatalogRoot) sourceFor;
  final FilmCatalogScanner scanner;
  final FilmCatalogMatcher matcher;
  final FilmMediaProbeController? mediaProbe;
  List<FilmWork> works = [];
  List<FilmCatalogRoot> roots = [];
  FilmMediaType? type;
  List<FilmWork> recentWorks = [], movies = [], series = [];
  final Map<int, FilmWork> rootCovers = {};
  final Map<int, File> rootCoverFiles = {};
  String query = '';
  int? rootId;
  String? sectionId;
  List<FilmHomeSection> homeSections = FilmHomeSection.defaults;
  Map<String, List<FilmWork>> sectionWorks = {};
  File? backgroundFile;
  final Map<int, String> _customCovers = {};
  bool newest = false;
  bool hasMore = false;
  bool loading = false;
  bool busy = false;
  bool cancelling = false;
  bool _closed = false;
  int pendingCount = 0;
  int _queryGeneration = 0;
  (FilmMediaType?, String, int?, bool, String?)? _loadedFilter;
  String? error;
  FilmScanProgress? progress;
  int scrapedCount = 0;
  int scrapeTotal = 0;
  int scrapeProcessed = 0;
  int scrapeCompletion = 0;
  bool scrapePaused = false;
  String? scrapeError;
  final _scrapeQueue = Queue<_FilmScrapeJob>();
  final _scrapeSessions = <int, Future<FilmScanMetadataSession>>{};
  final _scrapeSeen = <(int, String)>{};
  @visibleForTesting
  int get retainedScrapeSessionCount => _scrapeSessions.length;
  @visibleForTesting
  int get retainedScrapeEntryCount => _scrapeSeen.length;
  int _scrapeInputs = 0;
  Future<void>? _scrapeTask;
  Completer<void>? _scrapeWake;
  bool get scraping => _scrapeTask != null || _scrapeInputs > 0;
  bool isScrapingRoot(int id) => scraping && _scrapeSessions.containsKey(id);
  Timer? _refreshTimer;
  Future<void>? _scanTask;

  void _notify() {
    if (!_closed) notifyListeners();
  }

  void _changed() {
    if (_closed) return;
    _refreshTimer?.cancel();
    _refreshTimer = Timer(
      const Duration(milliseconds: 150),
      () => unawaited(refresh()),
    );
  }

  Future<void> refresh({bool more = false}) async {
    if (_closed || (more && loading)) return;
    final generation = ++_queryGeneration;
    final requestedFilter = (type, query, rootId, newest, sectionId);
    if (!more && _loadedFilter != requestedFilter) {
      works = [];
      hasMore = false;
    }
    loading = true;
    _notify();
    final offset = more ? works.length : 0;
    try {
      final rootList = await store.roots();
      if (_closed || generation != _queryGeneration) return;
      if (rootId != null && !rootList.any((r) => r.id == rootId)) rootId = null;
      final filter = (type, query, rootId, newest, sectionId);
      final pages = (works.length + 59) ~/ 60;
      final limit = !more && _loadedFilter == filter && pages > 1
          ? pages * 60
          : 60;
      final page = await store.works(
        type: type,
        query: query,
        rootId: rootId,
        newest: newest,
        offset: offset,
        limit: limit,
        sectionId: sectionId,
      );
      final count = await store.pendingCount(rootId: rootId);
      final recent = await store.works(type: null, newest: true, limit: 30);
      final filmMovies = await store.works(
        type: FilmMediaType.movie,
        limit: 30,
      );
      final filmSeries = await store.works(type: FilmMediaType.tv, limit: 30);
      final sections = await store.homeSections();
      final extraWorks = <String, List<FilmWork>>{};
      for (final section in sections.where(
        (s) => s.enabled && s.id.contains(':'),
      )) {
        extraWorks[section.id] = await store.works(
          type: null,
          sectionId: section.id,
          limit: 30,
        );
      }
      final background = await store.backgroundPath();
      for (final root in rootList) {
        final custom = await store.customRootCover(root.id);
        if (custom != null) {
          _customCovers[root.id] = custom;
          rootCovers.remove(root.id);
          rootCoverFiles[root.id] = File(custom);
          continue;
        }
        if (_customCovers.remove(root.id) != null) {
          rootCoverFiles.remove(root.id);
        }
        if (rootCoverFiles[root.id] case final file?) {
          if (!await file.exists()) {
            rootCovers.remove(root.id);
            rootCoverFiles.remove(root.id);
          }
        }
        if (!rootCovers.containsKey(root.id)) {
          final files = <int, File>{};
          final cover = await store.chooseRootCover(
            root.id,
            isCached: (work) async {
              final backdrop = work.backdropPath == null
                  ? null
                  : await images.cached(work.backdropPath!, 'w342') ??
                        await images.cached(work.backdropPath!, 'w780') ??
                        await images.cached(work.backdropPath!, 'original');
              final poster =
                  backdrop ?? await images.cached(work.posterPath!, 'w342');
              if (poster == null) return false;
              files[work.id] = poster;
              return true;
            },
          );
          if (cover != null) {
            rootCovers[root.id] = cover;
            rootCoverFiles[root.id] = files[cover.id]!;
          }
        }
      }
      if (_closed || generation != _queryGeneration) return;
      final rootIds = rootList.map((root) => root.id).toSet();
      rootCovers.removeWhere((id, _) => !rootIds.contains(id));
      rootCoverFiles.removeWhere((id, _) => !rootIds.contains(id));
      _customCovers.removeWhere((id, _) => !rootIds.contains(id));
      works = more ? [...works, ...page] : page;
      _loadedFilter = filter;
      roots = rootList;
      pendingCount = count;
      recentWorks = recent;
      movies = filmMovies;
      series = filmSeries;
      homeSections = sections;
      sectionWorks = extraWorks;
      backgroundFile = background == null || background.isEmpty
          ? null
          : File(background);
      hasMore = page.length == limit;
    } on DatabaseException {
      error = 'catalogStorageFailed';
      hasMore = false;
    } finally {
      if (generation == _queryGeneration) {
        loading = false;
        _notify();
      }
    }
  }

  /// 只转换外部 I/O 错误；内部编程错误仍明确失败。
  Future<bool> run(
    Future<void> Function() action, {
    bool clearError = true,
  }) async {
    if (clearError) {
      error = null;
      _notify();
    }
    try {
      await action();
      return true;
    } on FilmCatalogException catch (e) {
      error = e.code;
      return false;
    } on AppException {
      error = 'sourceUnavailable';
      return false;
    } on FileSystemException {
      error = 'catalogStorageFailed';
      return false;
    } on DatabaseException {
      error = 'catalogStorageFailed';
      return false;
    } finally {
      _notify();
    }
  }

  Future<void> scan(FilmCatalogRoot root, {bool incremental = false}) =>
      scanRoots([root], incremental: incremental);

  Future<void> scanRoots(
    List<FilmCatalogRoot> roots, {
    bool incremental = false,
  }) async {
    if (busy) {
      error = 'scanBusy';
      _notify();
      return;
    }
    busy = true;
    cancelling = false;
    error = null;
    _notify();
    _beginScrapeInput();
    final task = () async {
      try {
        for (final selected in roots) {
          if (cancelling || _closed) break;
          final root = await store.root(selected.id);
          if (cancelling || _closed) break;
          if (root == null) continue;
          progress = FilmScanProgress(root.id, 0, 0, root.path);
          _notify();
          await run(() async {
            final source = sourceFor(root);
            final metadata = await _scrapeSession(root);
            if (cancelling || _closed) return;
            await scanner.scan(
              root,
              source,
              incremental: incremental,
              onProgress: (value) {
                progress = value;
                _notify();
              },
              onEntries: (entries) async {
                _queueScraping(metadata, entries);
              },
            );
            // 清单提交后关联此前已完成的资料，不等待后续 TMDB 请求。
            await store.applyMetadata(root.id, metadata.matches);
          }, clearError: false);
        }
      } finally {
        _endScrapeInput();
        busy = false;
        progress = null;
        cancelling = false;
        await refresh();
        _notify();
      }
    }();
    _scanTask = task;
    await task;
  }

  void cancel() {
    cancelling = true;
    scanner.cancel();
    _notify();
  }

  void _beginScrapeInput() {
    if (!scraping) {
      scrapeTotal = scrapeProcessed = scrapedCount = 0;
      scrapePaused = false;
      scrapeError = null;
      _scrapeSessions.clear();
      _scrapeSeen.clear();
    }
    _scrapeInputs++;
    _notify();
  }

  void _endScrapeInput() {
    _scrapeInputs--;
    _wakeScraping();
    _releaseFinishedScraping();
    _notify();
  }

  void _releaseFinishedScraping() {
    if (_scrapeInputs == 0 && _scrapeTask == null && _scrapeQueue.isEmpty) {
      _scrapeSessions.clear();
      _scrapeSeen.clear();
    }
  }

  Future<FilmScanMetadataSession> _scrapeSession(FilmCatalogRoot root) =>
      _scrapeSessions.putIfAbsent(
        root.id,
        () => matcher.scanSession(root, cancelled: () => _closed),
      );

  void _queueScraping(
    FilmScanMetadataSession session,
    List<FilmScanEntry> entries,
  ) {
    if (_closed) return;
    if (!session.enabled) {
      scrapeError = session.error ?? 'noToken';
      _notify();
      return;
    }
    for (final entry in entries) {
      if (_scrapeSeen.add((session.root.id, entry.path))) {
        _scrapeQueue.add(_FilmScrapeJob(session, entry));
        scrapeTotal++;
      }
    }
    if (_scrapeTask == null && _scrapeQueue.isNotEmpty) {
      _scrapeTask = _scrape().whenComplete(() {
        _scrapeTask = null;
        if (!_closed &&
            scrapeProcessed > 0 &&
            _scrapeInputs == 0 &&
            _scrapeQueue.isEmpty) {
          scrapeCompletion++;
        }
        _releaseFinishedScraping();
        _notify();
      });
      unawaited(_scrapeTask!);
    }
    _wakeScraping();
    _notify();
  }

  void _wakeScraping() {
    _scrapeWake?.complete();
    _scrapeWake = null;
  }

  /// 用户暂停和 TMDB 错误只影响刮削队列，不影响目录扫描。
  void toggleScraping() {
    if (scrapePaused) {
      for (final job in _scrapeQueue) {
        job.session.resume();
      }
      scrapeError = null;
      scrapePaused = false;
      _wakeScraping();
    } else {
      scrapePaused = true;
    }
    _notify();
  }

  Future<void> _scrape() async {
    while (!_closed) {
      if (_scrapeQueue.isEmpty && _scrapeInputs == 0) return;
      if (scrapePaused || _scrapeQueue.isEmpty) {
        _scrapeWake = Completer<void>();
        await _scrapeWake!.future;
        continue;
      }
      final job = _scrapeQueue.first;
      final key = filmPathKey(job.entry.path, job.session.root.sourceKind);
      try {
        await job.session.prepare([job.entry]);
        if (_closed) return;
        if (job.session.paused) {
          scrapeError = job.session.error;
          scrapePaused = true;
          _notify();
          continue;
        }
        final match = job.session.matches[key];
        if (match != null) {
          await store.applyMetadata(job.session.root.id, {key: match});
          scrapedCount++;
        }
        scrapeError ??= job.session.error;
        _scrapeQueue.removeFirst();
        scrapeProcessed++;
        _notify();
      } on DatabaseException {
        scrapeError = 'catalogStorageFailed';
        scrapePaused = true;
        _notify();
      }
    }
  }

  /// 对现有清单独立刮削，不重新读取媒体来源目录。
  Future<void> scrape(FilmCatalogRoot root, {bool incremental = false}) async {
    if (_closed ||
        isScrapingRoot(root.id) ||
        (incremental && root.type != FilmMediaType.tv)) {
      return;
    }
    _beginScrapeInput();
    try {
      final session = await _scrapeSession(root);
      final resources = await store.resources(
        rootId: root.id,
        pending: incremental,
      );
      _queueScraping(session, [
        for (final resource in resources)
          if (resource.availability == 'present' &&
              (!incremental || resource.workId == null))
            FilmScanEntry(
              path: resource.path,
              parentPath: resource.parentPath,
              name: resource.name,
              mediaKind: resource.mediaKind,
            ),
      ]);
    } on FilmCatalogException catch (cause) {
      scrapeError = cause.code;
    } on DatabaseException {
      scrapeError = 'catalogStorageFailed';
    } finally {
      _endScrapeInput();
    }
  }

  Future<void> waitForScraping() async => _scrapeTask;

  Future<void> close() async {
    _closed = true;
    ++_queryGeneration;
    _refreshTimer?.cancel();
    store.removeListener(_changed);
    mediaProbe?.removeListener(_notify);
    await mediaProbe?.close();
    cancel();
    _wakeScraping();
    tmdb.close();
    images.close();
    try {
      await scanner.shutdown();
      await _scanTask;
      await _scrapeTask;
    } finally {
      _scrapeQueue.clear();
      _scrapeSessions.clear();
      _scrapeSeen.clear();
      await store.close();
      super.dispose();
    }
  }
}

class _FilmScrapeJob {
  const _FilmScrapeJob(this.session, this.entry);
  final FilmScanMetadataSession session;
  final FilmScanEntry entry;
}

/// 错误键只在界面层翻译，不保存底层异常或敏感请求。
String filmCatalogErrorText(String code) => switch (code) {
  'overlappingRoot' => '同一来源的影视目录不能相同或互相包含',
  'invalidPath' => '目录条目路径无效或超出所选来源',
  'sourceUnavailable' => '来源不可用，请在文件夹管理中重新挂载',
  'directoryReadFailed' => '读取目录失败，已保留上一份完整清单',
  'scanBusy' => '请等待当前影视目录扫描完成',
  'cancelled' => '扫描已取消，原清单保持不变',
  'staleScan' => '扫描已失效，未提交清单',
  'interrupted' => '上次扫描中断，原清单保持不变',
  'unsupportedDirectory' => '影视库暂不收录 DVD 结构',
  'probeUnavailable' => '媒体探测组件不可用，请检查应用完整安装',
  'probeFailed' => '视频信息探测失败，可手动重试',
  'probeTimeout' => '视频信息探测超时，已停止读取',
  'probeRangeUnsupported' => '服务器未正确支持 Range，已停止探测',
  'probeSourceChanged' => '媒体内容在探测期间发生变更，已停止读取',
  'probeBudgetExceeded' => '蓝光探测达到读取上限，已停止读取',
  'probePlaybackOnly' => 'STRM 参数在播放时获取',
  'catalogStorageFailed' => '影视目录库操作失败',
  'noToken' => '请先保存 TMDB Read Access Token',
  'invalidToken' => 'TMDB 凭据无效，请修改后验证',
  'credentialStoreFailed' => '无法访问 Windows 凭据管理器',
  'rateLimited' => 'TMDB 请求受限，请稍后手动重试',
  'metadataNotFound' => 'TMDB 中不存在该作品 ID',
  'metadataRequestFailed' => 'TMDB 请求失败，已保留现有元数据',
  'metadataTimeout' => 'TMDB 连接超时，请检查网络和系统代理',
  'metadataConnectionFailed' => '无法连接 TMDB，请检查网络和系统代理',
  'metadataTlsFailed' => 'TMDB 安全连接失败，请检查网络和证书',
  'systemProxyFailed' => '无法读取 Windows 系统代理设置',
  'invalidMetadata' => 'TMDB 返回的元数据无效',
  'staleMatch' => '文件关联已更改，请重新打开纠错窗口',
  'wrongMediaType' => '作品类型与影视目录类型不一致',
  'invalidEpisode' => '季集编号无效或文件尚未匹配同一剧集',
  'imageTooLarge' => '图片超过下载大小限制',
  'invalidImage' || 'imageFailed' => '图片读取失败，可手动重试',
  'imagePickerFailed' => '无法打开 Windows 图片选择器',
  'imageBusy' => '图片下载中，请稍后清理图片缓存',
  _ => '影视目录库操作失败',
};
