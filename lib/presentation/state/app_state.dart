import '../../data/models/video_playlist_mode.dart';
import '../../domain/services/video_entry_preparer.dart';
import 'dart:convert';
import '../../data/models/video_queue.dart';
import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:flutter/foundation.dart';

import '../../core/errors/app_exception.dart';
import '../../core/utils/url_utils.dart';
import '../../data/local/playback_history_store.dart';
import '../../data/local/audio_playback_history_store.dart';
import '../../data/local/stream_path_config_store.dart';
import '../../data/local/directory_cache.dart';
import '../../data/local/playback_progress_db.dart';
import '../../data/local/media_library_store.dart';
import '../../data/local/film_catalog_store.dart';
import '../../data/models/film_catalog_item.dart';
import '../../data/models/media_source.dart';
import '../../domain/services/film_catalog_image_cache.dart';
import '../../domain/services/tmdb_metadata_service.dart';
import '../../domain/services/webdav_media_source_adapter.dart';
import '../../domain/repositories/media_directory_source.dart';
import '../controllers/film_catalog_controller.dart';
import '../controllers/film_media_probe_controller.dart';
import '../../data/local/navigation_location_store.dart';
import '../../data/local/global_search_index.dart';
import '../../core/utils/app_paths.dart';
import '../../data/remote/webdav_client.dart';
import '../../data/models/local_root_config.dart';
import '../../data/models/appearance_config.dart';
import '../../data/models/server_profile.dart';
import '../../data/models/app_language.dart';
import '../../data/models/stream_path_config.dart';
import '../../data/models/media_library_item.dart';
import '../../data/models/web_dav_file.dart';
import '../../data/models/playback_history.dart';
import '../../domain/services/external_player_service.dart';
import '../../domain/services/webdav_font_cache.dart';
import '../../domain/services/audio_companion_matcher.dart';
import '../../domain/services/audio_player_service.dart';
import '../../domain/services/cache_cleanup_service.dart';
import '../../domain/services/diagnostic_service.dart';
import '../../domain/services/iso_playback_service.dart';
import '../../domain/services/local_disc_playback_service.dart';
import '../../domain/services/local_media_source.dart';
import '../../domain/services/openlist_index_service.dart';
import '../../domain/services/openlist_api_client.dart';
import '../../domain/services/subtitle_matcher.dart';
import '../../domain/services/webdav_service.dart';
import '../../domain/services/webdav_font_matcher.dart';
import '../../features/cache_control/cache_policy_service.dart';
import '../../features/cache_control/store/cache_intelligence_config_store.dart';
import '../../features/cache_control/store/cache_policy_config_store.dart';
import '../../features/cache_expiration/store/cache_expiration_config_store.dart';

/// 应用全局状态（provider 单例）。
///
/// 持有所有核心服务实例与当前连接信息；页面通过
/// `context.read<AppState>()` 获取，通过 [ChangeNotifier] 感知变化。
class AppState extends ChangeNotifier {
  AppState({
    required StreamPathConfigStore configStore,
    required PlaybackHistoryStore playbackHistoryStore,
    required PlaybackProgressService progressService,
    AudioPlaybackHistoryStore? audioPlaybackHistoryStore,
    PlaybackProgressService? audioProgressService,
    MediaLibraryStore? mediaLibraryStore,
    DirectoryCache? directoryCache,
    ExternalPlayerService? playerService,
    AudioPlayerService? audioPlayerService,
    SubtitleMatcher? subtitleMatcher,
    WebDavFontMatcher? webDavFontMatcher,
    CachePolicyProvider? cachePolicy,
    CachePolicyConfigStore? cachePolicyConfigStore,
    CacheIntelligenceConfigStore? cacheIntelligenceConfigStore,
    CacheExpirationConfigStore? cacheExpirationConfigStore,
    CacheCleaner? cacheCleaner,
    CacheCleaner? learningDataCleaner,
    IsoPlaybackService? isoPlaybackService,
    LocalDiscPlaybackService? localDiscPlaybackService,
    OpenListIndexService? openListIndexService,
    OpenListIndexUpdateScheduler? openListIndexScheduler,
    NavigationLocationStore? navigationLocationStore,
  }) : _configStore = configStore,
       // ignore: prefer_initializing_formals
       _cachePolicyConfigStore = cachePolicyConfigStore,
       // ignore: prefer_initializing_formals
       _cacheIntelligenceConfigStore = cacheIntelligenceConfigStore,
       // ignore: prefer_initializing_formals
       _cacheExpirationConfigStore = cacheExpirationConfigStore,
       // ignore: prefer_initializing_formals
       _playbackHistoryStore = playbackHistoryStore,
       _filmPlaybackHistoryStore = playbackHistoryStore.forFilmLibrary(),
       _progressService = progressService,
       // ignore: prefer_initializing_formals
       _audioPlaybackHistoryStore = audioPlaybackHistoryStore,
       _audioProgressService = audioProgressService,
       // ignore: prefer_initializing_formals
       _mediaLibraryStore = mediaLibraryStore,
       _filmMediaLibraryStore = mediaLibraryStore?.forFilmLibrary(),
       _directoryCache = directoryCache ?? DirectoryCache(),
       navigationLocations =
           navigationLocationStore ??
           NavigationLocationStore(
             File(
               p.join(
                 p.dirname(configStore.configFilePath),
                 'navigation_locations.json',
               ),
             ),
             mode: configStore.current.appearance.directoryMemoryMode,
           ),
       // ignore: prefer_initializing_formals
       _cacheCleaner = cacheCleaner,
       // ignore: prefer_initializing_formals
       _learningDataCleaner = learningDataCleaner,
       // ignore: prefer_initializing_formals
       _isoPlaybackService = isoPlaybackService,
       _language = configStore.current.language,
       _subtitleMatcher = subtitleMatcher ?? const SubtitleMatcher(),
       _webDavFontMatcher = webDavFontMatcher ?? const WebDavFontMatcher() {
    // 警告流与播放器服务的警告接线放构造器 body（initializer 中
    // 不能引用 this 字段）。
    _cacheWarnings = StreamController<String>.broadcast();
    _playbackRecoveryEvents =
        StreamController<PlaybackRecoveryEvent>.broadcast();
    _playerService =
        playerService ??
        ExternalPlayerService(
          configStore: configStore,
          progressService: progressService,
          cachePolicy: cachePolicy,
          onCacheWarning: (message) => _cacheWarnings.add(message),
          onPlaybackRecovery: (event) => _playbackRecoveryEvents.add(event),
        );
    _playerService.onVideoProgress = _recordVideoWatch;
    _playerService.videoResetBefore = (source, path) async =>
        (await getFilmCatalogStore()).manualWatchResetAt(source, path);
    _audioPlayerService =
        audioPlayerService ??
        (audioProgressService == null
            ? null
            : AudioPlayerService(
                configStore: configStore,
                progressService: audioProgressService,
              ));
    _localDiscPlaybackService =
        localDiscPlaybackService ??
        LocalDiscPlaybackService(
          configStore: configStore,
          progressService: progressService,
          mediaLibraryStore: mediaLibraryStore,
        );
    _openListIndexService = openListIndexService ?? OpenListIndexService();
    _openListIndexScheduler =
        openListIndexScheduler ??
        OpenListIndexUpdateScheduler(service: _openListIndexService);
    refreshOpenListIndexSchedule();
  }

  final StreamPathConfigStore _configStore;
  final CachePolicyConfigStore? _cachePolicyConfigStore;
  final CacheIntelligenceConfigStore? _cacheIntelligenceConfigStore;
  final CacheExpirationConfigStore? _cacheExpirationConfigStore;
  final PlaybackHistoryStore _playbackHistoryStore;
  final PlaybackHistoryStore _filmPlaybackHistoryStore;
  final PlaybackProgressService _progressService;
  final AudioPlaybackHistoryStore? _audioPlaybackHistoryStore;
  final PlaybackProgressService? _audioProgressService;
  final MediaLibraryStore? _mediaLibraryStore;
  final MediaLibraryStore? _filmMediaLibraryStore;
  final DirectoryCache _directoryCache;
  final NavigationLocationStore navigationLocations;
  Future<GlobalSearchIndex>? _globalSearchIndex;
  Future<FilmCatalogStore>? _filmCatalogStore;
  Future<FilmCatalogStore> getFilmCatalogStore() =>
      _filmCatalogStore ??= () async {
        final library = await AppPaths.libraryDirectory();
        final store = await FilmCatalogStore.open(
          p.join(library.path, 'film_catalog.db'),
        );
        await importFilmWatchProgress(store);
        return store;
      }();
  Future<VideoQueueVersion?> Function(VideoQueueItem)? chooseVideoVersion;
  void Function(String)? onImplicitVideoError;
  Future<void> restoreImplicitVideoControls() async {
    if (_disposed || chooseVideoVersion == null) return;
    for (final film in [false, true]) {
      final histories = film
          ? _filmPlaybackHistoryStore
          : _playbackHistoryStore;
      final rows = (await histories.loadAll())
          .where(
            (h) =>
                h.queueItems.isNotEmpty &&
                h.playerPid != null &&
                h.sourceId != null,
          )
          .toList();
      if (rows.isEmpty) continue;
      if (film) await initializeFilmPlayback();
      final player = film ? _filmPlayerService! : _playerService;
      final records = film ? _filmMediaLibraryStore : _mediaLibraryStore;
      for (final history in rows) {
        final sourceId = history.sourceId!;
        final service =
            mountedService(sourceId) ??
            (_webDavService?.sourceId == sourceId ? _webDavService : null);
        final local = localRoots
            .where((r) => r.sourceId == sourceId && r.enabled)
            .firstOrNull;
        if (service == null && local == null) continue;
        final MediaDirectorySource source = local != null
            ? localMediaSource(local)
            : WebDavMediaSourceAdapter(service!);
        await player.restoreSession(
          sessionId: history.sessionId,
          profileId: sourceId,
          pid: history.playerPid,
          executablePath: history.playerExecutablePath,
          creationTime: history.playerCreationTime,
          ipcPipeName: history.ipcPipeName,
          launchEpoch: history.launchEpoch,
        );
        final store = await getFilmCatalogStore();
        final items = history.queueItems;
        final preparer = VideoEntryPreparer(
          source: source,
          config: _configStore.current.toPlayerConfig(),
          subtitleMatcher: _subtitleMatcher,
          fontMatcher: _webDavFontMatcher,
          titles: _configStore.current.videoPlaylistSimpleNaming
              ? await store.videoPlaylistTitles(
                  sourceId,
                  items.expand((i) => i.versions.map((v) => v.path)).toList(),
                )
              : <String, String>{},
        );
        await preparer.prepareSharedFonts(
          history.videoQueueRootPath ?? history.dirCrumbs.join('/'),
        );
        Future<void> target(
          int index,
          VideoQueueVersion version, {
          bool loaded = false,
        }) async {
          final current = (await histories.loadAll())
              .where((h) => h.sessionId == history.sessionId)
              .firstOrNull;
          if (current == null) return;
          if (!loaded) {
            await histories.upsert(current.copyWith(pendingVideoIndex: index));
            notifyListeners();
            return;
          }
          final paths = List<String>.of(current.playlistRelativePaths),
              names = List<String>.of(current.playlistFileNames);
          paths[index] = version.path;
          names[index] = version.name;
          final parent = p.posix.dirname(version.path);
          final updated = current.copyWith(
            videoIndex: index,
            fileName: version.name,
            dirCrumbs: parent == '.' ? [] : parent.split('/'),
            playlistRelativePaths: paths,
            playlistFileNames: names,
            clearPendingVideoIndex: true,
            updatedAt: DateTime.now(),
          );
          await histories.upsert(updated);
          await records?.recordPlayback(
            MediaLibraryItem(
              sourceId: sourceId,
              sourceKind: source.descriptor.kind,
              parentPath: parent == '.' ? '' : parent,
              name: version.name,
              playbackMode: local != null
                  ? PlaybackMode.localFile
                  : PlaybackMode.legacyTitle,
              kind: version.name.endsWith('.strm')
                  ? MediaLibraryKind.strm
                  : MediaLibraryKind.video,
            ),
            playbackSessionId: history.sessionId,
            playlistIndex: index,
            playlistCount: items.length,
          );
          notifyListeners();
        }

        final plan = ImplicitVideoPlan(
          items: items,
          index: history.videoIndex,
          prepare: preparer.prepare,
          chooseVersion: (item) => chooseVideoVersion!(item),
          activated: (i, v) => target(i, v, loaded: true),
          pending: (i) => target(i, items[i].versions.first),
          failed: (message) => onImplicitVideoError?.call(message),
        );
        for (var i = 0; i < items.length; i++) {
          final version = items[i].versions
              .where((v) => v.path == history.playlistRelativePaths[i])
              .firstOrNull;
          if (version != null &&
              (i <= history.videoIndex || items[i].versions.length == 1)) {
            plan.selected[i] = version;
          }
        }
        await player.attachImplicitPlan(
          history.sessionId,
          plan,
          serverUrl: service?.baseUrl,
          username: service?.credentialSnapshot.username,
          password: service?.credentialSnapshot.password,
          fontLoader: service?.fetchFileBytes,
          fontFileLoader: service?.downloadFile,
        );
      }
    }
  }

  @visibleForTesting
  Future<void> importFilmWatchProgress(FilmCatalogStore store) async {
    final snapshots = await Future.wait([
      for (final progress in [
        _progressService,
        _filmProgressService,
      ].whereType<PlaybackProgressService>())
        progress.resumeProgressSnapshot(),
    ]);
    if (snapshots.every((s) => s.isEmpty)) return;
    final paths = <String, String>{};
    final directories = <String, Map<String, List<WebDavFile>>>{};
    final cache = await AppPaths.cacheDirectory();
    for (final histories in [
      _playbackHistoryStore,
      _filmPlaybackHistoryStore,
    ]) {
      for (final history in await histories.loadAll()) {
        final epoch = history.launchEpoch;
        final artifact = epoch == null || epoch.isEmpty
            ? history.sessionId
            : '${history.sessionId}__e$epoch';
        final file = File(
          p.join(cache.path, 'mpv-season-entries-$artifact.json'),
        );
        if (!await file.exists()) continue;
        final data =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        for (final entry in data['entries'] as List? ?? []) {
          if (entry['catalogPath'] is String &&
              entry['url'] is String &&
              (entry['url'] as String).isNotEmpty) {
            paths['${history.sourceId}\u0000${entry['catalogPath']}'] =
                entry['url'] as String;
          }
        }
      }
    }
    for (final r in await store.resources()) {
      if (r.availability != 'present' ||
          r.workId == null ||
          r.mediaKind != 'video' && r.mediaKind != 'strm' ||
          r.type == FilmMediaType.tv &&
              (r.season == null || r.episode == null)) {
        continue;
      }
      final url =
          paths['${r.sourceId}\u0000${r.path}'] ??
          (r.mediaKind == 'strm'
              ? null
              : _resolveMediaLibraryTarget(
                  r.playbackItem,
                  allowLogicalPath: true,
                  cachedDirectories: directories,
                ));
      if (url == null) continue;
      for (final snapshot in snapshots) {
        final sample = snapshot[(r.sourceId, url)];
        if (sample != null &&
            sample.positionMs > 0 &&
            sample.updatedAt != null) {
          await store.recordVideoProgress(
            VideoProgressUpdate(
              sourceId: r.sourceId,
              path: r.path,
              positionMs: sample.positionMs,
              durationMs: sample.durationMs,
              recordedAt: sample.updatedAt!,
            ),
          );
        }
      }
    }
  }

  Future<void> _recordVideoWatch(VideoProgressUpdate update) async {
    if (_disposed) return;
    await (await getFilmCatalogStore()).recordVideoProgress(update);
  }

  Future<void> markFilmWatched(
    List<FilmResource> selected,
    bool watched,
  ) async {
    final store = await getFilmCatalogStore();
    final selectedDiscs = <int, FilmResource>{};
    final episodes = <(String, int), Set<(int?, int?)>>{};
    for (final r in selected) {
      if (!r.canMarkWatched) continue;
      if (r.isDisc) {
        selectedDiscs[r.id] = r;
      } else {
        episodes.putIfAbsent((r.sourceId, r.workId!), () => {}).add((
          r.season,
          r.episode,
        ));
      }
    }
    final resources = selectedDiscs.values.toList();
    for (final group in episodes.entries) {
      final (sourceId, workId) = group.key;
      final candidates = await store.resources(
        workId: workId,
        sourceId: sourceId,
      );
      resources.addAll(
        candidates.where(
          (v) =>
              v.canMarkWatched &&
              !v.isDisc &&
              (v.type == FilmMediaType.movie ||
                  group.value.contains((v.season, v.episode))),
        ),
      );
    }
    final cutoff = DateTime.now();
    await store.markWatched(resources, watched, observedAt: cutoff);
    // 光盘仅标记整片，不修改原有节目级续播点。
    if (resources.every((r) => r.isDisc)) return;
    await initializeFilmPlayback();
    final bySource = <String, List<FilmResource>>{};
    for (final r in resources.where((r) => !r.isDisc)) {
      bySource.putIfAbsent(r.sourceId, () => []).add(r);
    }
    for (final group in bySource.entries) {
      final urls = <String>{};
      final directories = <String, Map<String, List<WebDavFile>>>{};
      for (final r in group.value) {
        final target = _resolveMediaLibraryTarget(
          r.playbackItem,
          allowLogicalPath: true,
          cachedDirectories: directories,
        );
        if (target != null) urls.add(target);
      }
      final paths = group.value.map((r) => r.path).toSet();
      final cache = await AppPaths.cacheDirectory();
      for (final histories in [
        _playbackHistoryStore,
        _filmPlaybackHistoryStore,
      ]) {
        for (final history in (await histories.loadAll()).where(
          (h) => h.sourceId == group.key,
        )) {
          final epoch = history.launchEpoch;
          final artifact = epoch == null || epoch.isEmpty
              ? history.sessionId
              : '${history.sessionId}__e$epoch';
          final file = File(
            p.join(cache.path, 'mpv-season-entries-$artifact.json'),
          );
          if (!await file.exists()) continue;
          final data =
              jsonDecode(await file.readAsString()) as Map<String, dynamic>;
          for (final entry in data['entries'] as List? ?? []) {
            if (paths.contains(entry['catalogPath']) &&
                entry['url'] is String &&
                (entry['url'] as String).isNotEmpty) {
              urls.add(entry['url'] as String);
            }
          }
        }
      }
      await _playerService.clearVideoResume(group.key, paths, urls, cutoff);
      await _filmPlayerService?.clearVideoResume(
        group.key,
        paths,
        urls,
        cutoff,
      );
      for (final histories in [
        _playbackHistoryStore,
        _filmPlaybackHistoryStore,
      ]) {
        final records = identical(histories, _playbackHistoryStore)
            ? _mediaLibraryStore
            : _filmMediaLibraryStore;
        for (final history in (await histories.loadAll()).where(
          (h) => h.sourceId == group.key && h.kind == PlaybackHistoryKind.video,
        )) {
          final current = history.playlistRelativePaths.elementAtOrNull(
            history.videoIndex,
          );
          if (!paths.contains(current)) continue;
          if (watched) {
            var next = history.videoIndex + 1;
            while (next < history.playlistRelativePaths.length &&
                paths.contains(history.playlistRelativePaths[next])) {
              next++;
            }
            if (next >= history.playlistRelativePaths.length) {
              await histories.remove(history.sessionId);
              await records?.dismissVideoContinueSession(
                group.key,
                history.sessionId,
              );
            } else {
              final path = history.playlistRelativePaths[next],
                  parent = history.playlistRelativePaths[next].split('/')
                    ..removeLast();
              final player = identical(histories, _playbackHistoryStore)
                  ? _playerService
                  : _filmPlayerService!;
              final running =
                  history.videoPlaylistMode == VideoPlaylistMode.implicit &&
                  await player.isPlayerRunning(history.sessionId);
              if (running) player.setPendingVideo(history.sessionId, next);
              final updated = history.copyWith(
                pendingVideoIndex: running ? next : null,
                videoIndex: running ? history.videoIndex : next,
                fileName: running
                    ? history.fileName
                    : history.playlistFileNames[next],
                dirCrumbs: running ? history.dirCrumbs : parent,
                updatedAt: DateTime.now(),
                clearPendingVideoIndex: !running,
              );
              await histories.upsert(updated);
              final resource = await store.resourceAt(group.key, path);
              if (resource != null) {
                await records?.recordPlayback(
                  resource.playbackItem,
                  playbackSessionId: history.sessionId,
                  playlistIndex: next,
                  playlistCount: history.playlistRelativePaths.length,
                );
              }
            }
          }
        }
      }
    }
    notifyListeners();
  }

  Future<FilmCatalogController>? _filmCatalog;
  FilmCatalogController? _filmCatalogValue;
  bool _disposed = false;

  Future<FilmCatalogController> getFilmCatalog() => _filmCatalog ??= () async {
    await initializeFilmPlayback();
    final cache = await AppPaths.cacheDirectory();
    final store = await getFilmCatalogStore();
    final tmdb = TmdbMetadataService();
    final controller = FilmCatalogController(
      store: store,
      tmdb: tmdb,
      images: FilmCatalogImageCache(
        Directory(p.join(cache.path, 'film_artwork')),
        tmdb,
      ),
      mediaProbe: FilmMediaProbeController(
        store: store,
        sourceFor: _filmSource,
        snapshots: () => [
          ..._playerService.mediaProbeSnapshots,
          ..._filmPlayerService!.mediaProbeSnapshots,
          ..._localDiscPlaybackService.mediaProbeSnapshots,
          ..._filmLocalDiscPlaybackService!.mediaProbeSnapshots,
          ...?_isoPlaybackService?.mediaProbeSnapshots,
          ...?_filmIsoPlaybackService?.mediaProbeSnapshots,
        ],
        relativePathFor: _filmSnapshotPath,
        isPlaying: () async =>
            await _playerService.anyPlayerRunning() ||
            await _filmPlayerService!.anyPlayerRunning() ||
            await _localDiscPlaybackService.anyPlayerRunning() ||
            await _filmLocalDiscPlaybackService!.anyPlayerRunning() ||
            (await _isoPlaybackService?.hasActivePlayback() ?? false) ||
            (await _filmIsoPlaybackService?.hasActivePlayback() ?? false),
      ),
      sourceFor: _filmSource,
    );
    _filmCatalogValue = controller;
    if (!_disposed) {
      controller.mediaProbe!.start();
    }
    return controller;
  }();

  MediaDirectorySource _filmSource(FilmCatalogRoot root) {
    if (root.sourceKind == MediaSourceKind.local) {
      final local = localRoots
          .where((r) => r.sourceId == root.sourceId && r.enabled)
          .firstOrNull;
      if (local == null) {
        throw const FilmCatalogException('sourceUnavailable');
      }
      return localMediaSource(local);
    }
    final service = mountedService(root.sourceId);
    if (!_configStore.current.mountedProfileIds.contains(root.sourceId) ||
        service == null) {
      throw const FilmCatalogException('sourceUnavailable');
    }
    return WebDavMediaSourceAdapter(service);
  }

  String? _filmSnapshotPath(FilmPlaybackSnapshot snapshot) {
    if (snapshot.resourcePath != null) {
      return validateFilmPath(snapshot.resourcePath!);
    }
    if (snapshot.sourceId.startsWith('local:')) {
      final root = localRoots
          .where((r) => r.sourceId == snapshot.sourceId && r.enabled)
          .firstOrNull;
      if (root == null || !p.isAbsolute(snapshot.target)) return null;
      if (p.equals(root.path, snapshot.target)) return '';
      return p.isWithin(root.path, snapshot.target)
          ? p.relative(snapshot.target, from: root.path).replaceAll('\\', '/')
          : null;
    }
    final service = mountedService(snapshot.sourceId);
    final target = Uri.tryParse(snapshot.target);
    if (service == null || target == null) return null;
    final base = Uri.parse(service.baseUrl);
    if (base.scheme != target.scheme ||
        base.host != target.host ||
        base.port != target.port) {
      return null;
    }
    final prefix = base.pathSegments.where((s) => s.isNotEmpty).toList();
    if (target.pathSegments.length < prefix.length) return null;
    for (var i = 0; i < prefix.length; i++) {
      if (prefix[i] != target.pathSegments[i]) return null;
    }
    return target.pathSegments
        .skip(prefix.length)
        .where((s) => s.isNotEmpty)
        .join('/');
  }

  Future<T> withMediaPlaybackPriority<T>(Future<T> Function() operation) async {
    final catalog = _filmCatalog;
    if (catalog == null) return operation();
    final probe = (await catalog).mediaProbe;
    return probe == null ? operation() : probe.withPlaybackPriority(operation);
  }

  Future<GlobalSearchIndex> getGlobalSearchIndex() =>
      _globalSearchIndex ??= () async {
        final dir = await AppPaths.cacheDirectory();
        return GlobalSearchIndex.open(p.join(dir.path, 'global_search.db'));
      }();
  final CacheCleaner? _cacheCleaner;
  final CacheCleaner? _learningDataCleaner;
  final IsoPlaybackService? _isoPlaybackService;
  Future<void>? _filmPlaybackReady;
  PlaybackProgressService? _filmProgressService;
  ExternalPlayerService? _filmPlayerService;
  LocalDiscPlaybackService? _filmLocalDiscPlaybackService;
  IsoPlaybackService? _filmIsoPlaybackService;

  Future<void> initializeFilmPlayback() => _filmPlaybackReady ??= () async {
    final sources = {
      ...localRoots.map((r) => r.sourceId),
      ..._configStore.current.profiles.map((p) => p.profileId),
    };
    final media = <(String, String)>{};
    final isoKeys = <String>{};
    final records = _filmMediaLibraryStore;
    if (records != null) {
      for (final source in sources) {
        for (final record in [
          ...await records.playbackHistory(source, audio: false),
          ...await records.playbackHistory(source, audio: false, iso: true),
        ]) {
          final target = resolveMediaLibraryTarget(
            record.item,
            allowLogicalPath: true,
          );
          if (target != null) {
            media.add((source, target));
            if (record.item.kind == MediaLibraryKind.iso &&
                record.item.sourceKind == MediaSourceKind.webdav) {
              isoKeys.add(
                IsoPlaybackService.libraryKey(
                  profileId: source,
                  resolvedUrl: target,
                ),
              );
              isoKeys.add(
                IsoPlaybackService.libraryKey(
                  profileId: source,
                  resolvedUrl: target,
                  playbackMode: record.item.playbackMode,
                ),
              );
            }
          }
        }
      }
    }
    final progress = await _progressService.forFilmLibrary(media);
    final player = _playerService.forFilmLibrary(
      progress,
      Directory(
        p.join(
          _filmPlaybackHistoryStore.directory.path,
          'film_mpv_watch_later',
        ),
      ),
    );
    final localDisc = _localDiscPlaybackService.forFilmLibrary(
      progress,
      records,
    );
    IsoPlaybackService? iso;
    try {
      if (_isoPlaybackService != null) {
        final histories = await _filmPlaybackHistoryStore.loadAll();
        isoKeys.addAll(histories.map((h) => h.isoKey).whereType<String>());
        iso = await _isoPlaybackService.forFilmLibrary(_configStore, isoKeys);
      }
    } catch (_) {
      localDisc.dispose();
      await progress.close();
      rethrow;
    }
    _filmProgressService = progress;
    _filmPlayerService = player;
    if (_filmCatalogStore != null) {
      await importFilmWatchProgress(await _filmCatalogStore!);
    }
    _filmLocalDiscPlaybackService = localDisc;
    _filmIsoPlaybackService = iso;
    if (_disposed) await _closeFilmPlayback();
  }();

  Future<void> _closeFilmPlayback() async {
    _filmIsoPlaybackService?.dispose();
    _filmLocalDiscPlaybackService?.dispose();
    await _filmProgressService?.close();
  }

  String? resolveMediaLibraryTarget(
    MediaLibraryItem item, {
    bool allowLogicalPath = false,
  }) => _resolveMediaLibraryTarget(item, allowLogicalPath: allowLogicalPath);

  String? _resolveMediaLibraryTarget(
    MediaLibraryItem item, {
    bool allowLogicalPath = false,
    Map<String, Map<String, List<WebDavFile>>>? cachedDirectories,
  }) {
    if (item.kind == MediaLibraryKind.directory ||
        item.kind == MediaLibraryKind.strm) {
      return null;
    }
    if (item.sourceKind == MediaSourceKind.local) {
      final root = localRoots
          .where((r) => r.sourceId == item.sourceId)
          .firstOrNull;
      if (root == null) return null;
      final path =
          item.kind == MediaLibraryKind.iso &&
              item.parentPath.isEmpty &&
              item.name == root.displayName
          ? ''
          : item.targetPath;
      return localMediaSource(root).lexicalPath(path);
    }
    final profile = _configStore.current.profiles
        .where((p) => p.profileId == item.sourceId)
        .firstOrNull;
    if (profile == null) return null;
    if (item.discRootPath != null) {
      return '${joinUrl(profile.serverUrl, item.discRootPath!).replaceAll(RegExp(r'/+$'), '')}/';
    }
    Iterable<WebDavFile> entries;
    final parent = item.normalizedParentPath;
    if (cachedDirectories != null) {
      // 批量处理期间每个来源只解码一次目录缓存，按父目录查找。
      final directories = cachedDirectories.putIfAbsent(item.sourceId, () {
        final result = <String, List<WebDavFile>>{};
        for (final snapshot in _directoryCache.visitedDirectories(
          item.sourceId,
        )) {
          result
              .putIfAbsent(normalizeLibraryPath(snapshot.path), () => [])
              .addAll(snapshot.entries);
        }
        return result;
      });
      entries = directories[parent] ?? const [];
    } else {
      entries = _directoryCache
          .visitedDirectories(item.sourceId)
          .where((snapshot) => normalizeLibraryPath(snapshot.path) == parent)
          .expand((snapshot) => snapshot.entries);
    }
    final file = entries.where(item.matches).firstOrNull;
    if (file != null) {
      return stripUserInfo(resolveHref(profile.serverUrl, file.href));
    }
    return allowLogicalPath
        ? stripUserInfo(joinUrl(profile.serverUrl, item.targetPath))
        : null;
  }

  late final LocalDiscPlaybackService _localDiscPlaybackService;
  AppLanguage _language;
  late final ExternalPlayerService _playerService;
  late final AudioPlayerService? _audioPlayerService;
  final SubtitleMatcher _subtitleMatcher;
  final WebDavFontMatcher _webDavFontMatcher;
  final AudioCompanionMatcher _audioCompanionMatcher =
      const AudioCompanionMatcher();
  late final OpenListIndexService _openListIndexService;
  late final OpenListIndexUpdateScheduler _openListIndexScheduler;

  /// 播放中动态保护的用户警告（网络带宽持续不足等）；UI 订阅后
  /// 以 SnackBar 展示。
  late final StreamController<String> _cacheWarnings;
  late final StreamController<PlaybackRecoveryEvent> _playbackRecoveryEvents;

  Future<void> pruneWebDavFontCache() =>
      _playerService.pruneWebDavFontCache(() async {
        final active = <String>{};
        for (final history in [
          ...await _playbackHistoryStore.loadAll(),
          ...await _filmPlaybackHistoryStore.loadAll(),
        ]) {
          if (history.kind != PlaybackHistoryKind.video) continue;
          final sourceId = history.sourceId;
          if (sourceId == null || sourceId.isEmpty) continue;
          active.add(WebDavFontCache.sessionKey(sourceId, history.sessionId));
        }
        for (final library in [
          _mediaLibraryStore,
          _filmMediaLibraryStore,
        ].whereType<MediaLibraryStore>()) {
          for (final profile in _configStore.current.profiles) {
            final records = await library.playbackHistory(
              profile.profileId,
              audio: false,
            );
            for (final record in records) {
              if (record.continueDismissed || !record.item.kind.isVideoLane) {
                continue;
              }
              final sessionId = record.playbackSessionId;
              if (sessionId == null) continue;
              active.add(
                WebDavFontCache.sessionKey(record.item.sourceId, sessionId),
              );
            }
          }
        }
        return active;
      });

  void scheduleWebDavFontCachePrune() {
    unawaited(
      pruneWebDavFontCache().catchError((Object error) {
        debugPrint('WebDAV font cache prune failed: $error');
      }),
    );
  }

  /// 播放中动态保护警告流（如「网络带宽不足以流畅播放」）。
  Stream<String> get cacheWarnings => _cacheWarnings.stream;

  /// MPV 播放失败自动恢复状态（准备、重新启动或失败）。
  Stream<PlaybackRecoveryEvent> get playbackRecoveryEvents =>
      _playbackRecoveryEvents.stream;

  WebDAVService? _webDavService;
  // null 表示普通页面；详情页保存滚动顶栏的显现进度。
  final ValueNotifier<double?> filmDetailChrome = ValueNotifier(null);
  final ValueNotifier<bool> filmLibraryActive = ValueNotifier(true);
  final ValueNotifier<bool> startupReady = ValueNotifier(false);
  final Map<String, WebDAVService> _mountedServices = {};
  final Map<String, String> _mountErrors = {};
  String? _username;
  String? _password;

  // ── 对外访问 ─────────────────────────────────────────────────

  /// 当前 WebDAV 服务；未连接时为 null。
  WebDAVService? get webDavService => _webDavService;
  WebDAVService? mountedService(String profileId) =>
      _mountedServices[profileId];
  String? mountError(String profileId) => _mountErrors[profileId];
  bool isProfileConnected(String profileId) =>
      _mountedServices.containsKey(profileId);

  /// 已连接的用户名（显示用）。
  String? get username => _username;

  /// 已连接的密码（供外部播放器认证注入，仅内存持有）。
  String? get password => _password;

  @override
  void dispose() {
    _disposed = true;
    _playerService.stopImplicitPlaybackControl();
    _filmPlayerService?.stopImplicitPlaybackControl();
    _filmCatalogValue?.mediaProbe?.stop();
    if (_filmCatalog != null) {
      unawaited(_filmCatalog!.then((controller) => controller.close()));
    }
    if (_filmCatalog == null && _filmCatalogStore != null) {
      unawaited(_filmCatalogStore!.then((s) => s.close()));
    }
    filmDetailChrome.dispose();
    filmLibraryActive.dispose();
    startupReady.dispose();
    _isoPlaybackService?.dispose();
    unawaited(_closeFilmPlayback());
    _localDiscPlaybackService.dispose();
    _openListIndexScheduler.dispose();
    _cacheWarnings.close();
    _playbackRecoveryEvents.close();
    super.dispose();
  }

  StreamPathConfigStore get configStore => _configStore;
  CachePolicyConfigStore? get cachePolicyConfigStore => _cachePolicyConfigStore;
  CacheIntelligenceConfigStore? get cacheIntelligenceConfigStore =>
      _cacheIntelligenceConfigStore;
  CacheExpirationConfigStore? get cacheExpirationConfigStore =>
      _cacheExpirationConfigStore;
  PlaybackHistoryStore get playbackHistoryStore => _playbackHistoryStore;
  PlaybackHistoryStore get filmPlaybackHistoryStore =>
      _filmPlaybackHistoryStore;
  PlaybackProgressService get progressService => _progressService;
  PlaybackProgressService get filmProgressService => _filmProgressService!;
  ExternalPlayerService get filmPlayerService => _filmPlayerService!;
  LocalDiscPlaybackService get filmLocalDiscPlaybackService =>
      _filmLocalDiscPlaybackService!;
  IsoPlaybackService? get filmIsoPlaybackService => _filmIsoPlaybackService;
  AudioPlaybackHistoryStore? get audioPlaybackHistoryStore =>
      _audioPlaybackHistoryStore;
  PlaybackProgressService? get audioProgressService => _audioProgressService;
  MediaLibraryStore? get mediaLibraryStore => _mediaLibraryStore;
  MediaLibraryStore? get filmMediaLibraryStore => _filmMediaLibraryStore;
  DirectoryCache get directoryCache => _directoryCache;
  String? get mediaSourceId => _webDavService?.sourceId;
  ExternalPlayerService get playerService => _playerService;
  AudioPlayerService? get audioPlayerService => _audioPlayerService;
  IsoPlaybackService? get isoPlaybackService => _isoPlaybackService;
  LocalDiscPlaybackService get localDiscPlaybackService =>
      _localDiscPlaybackService;
  SubtitleMatcher get subtitleMatcher => _subtitleMatcher;
  WebDavFontMatcher get webDavFontMatcher => _webDavFontMatcher;
  AudioCompanionMatcher get audioCompanionMatcher => _audioCompanionMatcher;
  bool get canClearCache => _cacheCleaner != null;
  bool get canClearLearningData => _learningDataCleaner != null;
  AppLanguage get language => _language;
  List<LocalRootConfig> get localRoots => _configStore.current.localRoots;

  LocalMediaSource localMediaSource(LocalRootConfig root) =>
      LocalMediaSource(root);

  /// 添加或编辑本地根目录；相同最终路径会复用既有 rootId。
  Future<LocalRootConfig> saveLocalRoot({
    required String path,
    String? displayName,
    String? rootId,
    bool enabled = true,
  }) async {
    final candidate = await LocalRootConfig.fromDirectory(
      path: path,
      displayName: displayName,
      rootId: rootId,
      enabled: enabled,
    );
    final current = await _configStore.load();
    final duplicate = current.localRoots
        .where(
          (root) =>
              root.rootId != rootId &&
              root.path.toLowerCase() == candidate.path.toLowerCase(),
        )
        .firstOrNull;
    final resolved = duplicate == null
        ? candidate
        : LocalRootConfig(
            rootId: duplicate.rootId,
            displayName: candidate.displayName,
            path: candidate.path,
            enabled: enabled,
          );
    await _configStore.save(current.upsertLocalRoot(resolved));
    notifyListeners();
    return resolved;
  }

  Future<void> removeLocalRoot(String rootId) async {
    final current = await _configStore.load();
    await _configStore.save(current.removeLocalRoot(rootId));
    await navigationLocations.forget('local:$rootId');
    if (_globalSearchIndex != null) {
      await (await _globalSearchIndex!).removeSource('local:$rootId');
    }
    notifyListeners();
  }

  Future<void> setLocalRootEnabled(String rootId, bool enabled) async {
    final current = await _configStore.load();
    final root = current.localRoots
        .where((item) => item.rootId == rootId)
        .firstOrNull;
    if (root == null || root.enabled == enabled) return;
    await _configStore.save(
      current.upsertLocalRoot(root.copyWith(enabled: enabled)),
    );
    notifyListeners();
  }

  /// 配置完成持久化后更新当前界面语言。
  void applyLanguage(AppLanguage language) {
    if (_language == language) return;
    _language = language;
    notifyListeners();
  }

  Future<List<OpenListIndexEntry>> searchOpenListIndex(String query) {
    final profile = _configStore.current.activeProfile;
    if (profile == null) return Future.value(const []);
    return _openListIndexService.search(profile: profile, query: query);
  }

  Future<List<OpenListIndexEntry>> searchOpenListIndexForProfile(
    ServerProfile profile,
    String query,
  ) => _openListIndexService.search(profile: profile, query: query);

  Future<void> setSidebarMode(SidebarDisplayMode mode) async {
    final current = _configStore.current;
    if (current.appearance.sidebarMode == mode) return;
    await _configStore.save(
      current.copyWithGlobalSettings(
        player: current.toPlayerConfig(),
        appearance: current.appearance.copyWith(sidebarMode: mode),
        mediaLibrary: current.mediaLibrary,
      ),
    );
    notifyListeners();
  }

  Future<void> setSidebarCompact(bool compact) async {
    final current = _configStore.current;
    if (current.appearance.sidebarCompact == compact) return;
    await _configStore.save(
      current.copyWithGlobalSettings(
        player: current.toPlayerConfig(),
        appearance: current.appearance.copyWith(sidebarCompact: compact),
        mediaLibrary: current.mediaLibrary,
      ),
    );
    notifyListeners();
  }

  Future<void> applyDirectoryMemoryMode() => navigationLocations.setMode(
    _configStore.current.appearance.directoryMemoryMode,
  );

  Future<OpenListIndexUpdateResult> updateOpenListIndex({
    ServerProfile? profile,
  }) {
    final target = profile ?? _configStore.current.activeProfile;
    if (target == null) {
      return Future.value(
        const OpenListIndexUpdateResult(accepted: false, message: '请先保存服务器档案'),
      );
    }
    return _openListIndexService.updateIndex(target);
  }

  Future<OpenListIndexProgress> getOpenListIndexProgress({
    ServerProfile? profile,
  }) {
    final target = profile ?? _configStore.current.activeProfile;
    if (target == null) {
      return Future.error(const FormatException('请先保存服务器档案'));
    }
    return _openListIndexService.getIndexProgress(target);
  }

  Future<OpenListCapabilities> getOpenListCapabilities({
    ServerProfile? profile,
  }) {
    final target = profile ?? _configStore.current.activeProfile;
    if (target == null) {
      return Future.value(OpenListCapabilities.unknown());
    }
    return _openListIndexService.getCapabilities(target);
  }

  void refreshOpenListIndexSchedule() {
    _openListIndexScheduler.configure(_configStore.current.activeProfile);
  }

  DiagnosticService createDiagnosticService() => DiagnosticService(
    configStore: _configStore,
    progressService: _progressService,
    audioProgressService: _audioProgressService,
    directoryCache: _directoryCache,
    playerService: _playerService,
    webDavService: _webDavService,
  );

  /// 播放器全部停止时，为视频和音频 SQLite 创建一致性备份并重建索引。
  Future<List<DatabaseMaintenanceResult>>
  repairDatabasesNonDestructive() async {
    if (await _hasRunningPlayback()) {
      throw const CacheCleanupBlockedException('请先关闭正在运行的播放器，再维护数据库');
    }
    final results = <DatabaseMaintenanceResult>[
      await _progressService.repairNonDestructive(),
    ];
    final audio = _audioProgressService;
    if (audio != null) results.add(await audio.repairNonDestructive());
    return results;
  }

  /// 清空缓存前确认没有播放器进程仍在使用会话文件。
  Future<CacheCleanupResult> clearCache() async {
    final cleaner = _cacheCleaner;
    if (cleaner == null) {
      throw const CacheCleanupException('缓存清理服务尚未初始化');
    }
    if (await _hasRunningPlayback()) {
      throw const CacheCleanupBlockedException('请先关闭正在运行的播放器，再清理缓存');
    }
    if (await _isoPlaybackService?.hasActivePlayback() ?? false) {
      throw const CacheCleanupBlockedException('请先关闭正在运行的 ISO 播放器，再清理缓存');
    }
    if (await _filmIsoPlaybackService?.hasActivePlayback() ?? false) {
      throw const CacheCleanupBlockedException('请先关闭正在运行的 ISO 播放器，再清理缓存');
    }
    await _releaseStoppedPlaybackSessions();
    final result = await cleaner.clear();
    await _filmPlaybackHistoryStore.clear();
    await _filmMediaLibraryStore?.clearStrmProgress();
    await _filmProgressService?.clearAll();
    notifyListeners();
    return result;
  }

  /// 只清空本地智能缓存的匿名聚合学习数据。
  Future<CacheCleanupResult> clearLearningData() async {
    final cleaner = _learningDataCleaner;
    if (cleaner == null) {
      throw const CacheCleanupException('学习数据清理服务尚未初始化');
    }
    if (await _hasRunningPlayback()) {
      throw const CacheCleanupBlockedException('请先关闭正在运行的播放器，再清理学习数据');
    }
    final result = await cleaner.clear();
    notifyListeners();
    return result;
  }

  Future<bool> _hasRunningPlayback() async {
    if (await _playerService.isPlayerRunning()) return true;
    if (await _filmPlayerService?.anyPlayerRunning() ?? false) return true;
    if (await _filmLocalDiscPlaybackService?.anyPlayerRunning() ?? false) {
      return true;
    }
    final filmHistories = await _filmPlaybackHistoryStore.loadAll();
    if (filmHistories.isNotEmpty) await initializeFilmPlayback();
    final filmIds = filmHistories.map((h) => h.sessionId).toSet();
    final videoHistories = [
      ...await _playbackHistoryStore.loadAll(),
      ...filmHistories,
    ];
    for (final history in videoHistories) {
      final player = filmIds.contains(history.sessionId)
          ? _filmPlayerService!
          : _playerService;
      await player.restoreSession(
        sessionId: history.sessionId,
        profileId: history.sourceId,
        pid: history.playerPid,
        executablePath: history.playerExecutablePath,
        creationTime: history.playerCreationTime,
        ipcPipeName: history.ipcPipeName,
      );
      if (await player.isPlayerRunning(history.sessionId)) return true;
    }

    final audioService = _audioPlayerService;
    final audioStore = _audioPlaybackHistoryStore;
    if (audioService == null || audioStore == null) return false;
    final audioHistories = await audioStore.loadAll();
    for (final history in audioHistories) {
      await audioService.restoreSession(
        sessionId: history.sessionId,
        profileId: history.sourceId,
        pid: history.playerPid,
        executablePath: history.playerExecutablePath,
        creationTime: history.playerCreationTime,
        ipcPipeName: history.ipcPipeName,
      );
      if (await audioService.isPlayerRunning(history.sessionId)) return true;
    }
    return false;
  }

  Future<void> _releaseStoppedPlaybackSessions() async {
    final videoHistories = [
      ...await _playbackHistoryStore.loadAll(),
      ...await _filmPlaybackHistoryStore.loadAll(),
    ];
    for (final history in videoHistories) {
      _playerService.releaseSession(history.sessionId);
      _filmPlayerService?.releaseSession(history.sessionId);
    }
    final audioService = _audioPlayerService;
    final audioStore = _audioPlaybackHistoryStore;
    if (audioService == null || audioStore == null) return;
    final audioHistories = await audioStore.loadAll();
    for (final history in audioHistories) {
      audioService.releaseSession(history.sessionId);
    }
  }

  // ── 连接管理 ─────────────────────────────────────────────────

  /// 建立 WebDAV 连接：创建服务并验证（拉取根目录）。
  ///
  /// 验证失败（认证/网络等）时抛出 [AppException]，调用方负责提示。
  Future<void> connect({
    required String baseUrl,
    required String username,
    required String password,
    String? profileId,
  }) async {
    final resolvedProfileId = profileId ?? _configStore.current.profileId;
    final service = await _verifyConnection(
      baseUrl: baseUrl,
      username: username,
      password: password,
      profileId: resolvedProfileId,
    );
    _commitConnection(
      service: service,
      username: username,
      password: password,
      profileId: resolvedProfileId,
    );
  }

  Future<void> mountProfile(String profileId) async {
    final config = _configStore.current;
    final profile = config.profiles
        .where((item) => item.profileId == profileId)
        .firstOrNull;
    if (profile == null || !profile.isConnectionComplete) {
      throw AppException.config('服务器档案缺少地址或用户名');
    }
    if (!config.mountedProfileIds.contains(profileId)) {
      await _configStore.save(
        config.withMountedProfileIds([...config.mountedProfileIds, profileId]),
      );
      notifyListeners();
    }
    try {
      final service = await _verifyConnection(
        baseUrl: profile.serverUrl,
        username: profile.username,
        password: profile.password,
        profileId: profileId,
      );
      if (!_configStore.current.mountedProfileIds.contains(profileId)) return;
      _mountedServices[profileId] = service;
      _mountErrors.remove(profileId);
      notifyListeners();
      await restoreImplicitVideoControls();
    } on AppException catch (error) {
      _mountErrors[profileId] = error.message;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> restoreMountedProfiles() async {
    final config = _configStore.current;
    await Future.wait([
      for (final profileId in config.mountedProfileIds)
        if (!_mountedServices.containsKey(profileId))
          mountProfile(profileId).onError((AppException error, _) {
            // 离线档案留在挂载列表，用户可以手动重试。
          }),
    ]);
    await restoreImplicitVideoControls();
  }

  Future<void> activateMountedProfile(String profileId) async {
    final config = _configStore.current;
    if (!config.mountedProfileIds.contains(profileId)) {
      throw AppException.config('该服务器未挂载');
    }
    final profile = config.profiles
        .where((item) => item.profileId == profileId)
        .firstOrNull;
    if (profile == null) throw AppException.config('服务器档案不存在');
    var service = _mountedServices[profileId];
    final credentials = service?.credentialSnapshot;
    if (service == null ||
        credentials!.baseUrl != profile.serverUrl ||
        credentials.username != profile.username ||
        credentials.password != profile.password) {
      await mountProfile(profileId);
      service = _mountedServices[profileId];
      if (service == null) throw AppException.config('服务器挂载已移除');
    }
    if (config.profileId != profileId) {
      await _configStore.save(config.activateProfile(profileId));
    }
    _commitConnection(
      service: service,
      username: profile.username,
      password: profile.password,
      profileId: profileId,
    );
  }

  Future<void> unmountProfile(String profileId) async {
    final config = _configStore.current;
    await _configStore.save(
      config.withMountedProfileIds(
        config.mountedProfileIds.where((id) => id != profileId).toList(),
      ),
    );
    _mountedServices.remove(profileId);
    await navigationLocations.forget(profileId);
    if (_globalSearchIndex != null) {
      await (await _globalSearchIndex!).removeSource(profileId);
    }
    _mountErrors.remove(profileId);
    if (_webDavService?.sourceId == profileId) {
      disconnect();
    } else {
      notifyListeners();
    }
  }

  /// 验证候选档案后同时提交活动配置与内存连接。
  Future<StreamPathConfig> connectAndActivateProfile({
    required ServerProfile profile,
    required StreamPathConfig config,
  }) async {
    if (!config.profiles.any(
      (candidate) => candidate.profileId == profile.profileId,
    )) {
      throw ArgumentError.value(profile.profileId, 'profile', '服务器档案不存在');
    }
    late final WebDAVService service;
    try {
      service = await _verifyConnection(
        baseUrl: profile.serverUrl,
        username: profile.username,
        password: profile.password,
        profileId: profile.profileId,
      );
    } on AppException catch (error) {
      throw AppException.network('重新连接失败：${error.message}', error);
    } catch (error) {
      throw AppException.network('重新连接失败：$error', error);
    }

    final activated = config.activateProfile(profile.profileId);
    await _configStore.save(activated);
    _commitConnection(
      service: service,
      username: profile.username,
      password: profile.password,
      profileId: profile.profileId,
    );
    return activated;
  }

  Future<WebDAVService> _verifyConnection({
    required String baseUrl,
    required String username,
    required String password,
    required String profileId,
  }) async {
    final client = WebDavClient(
      baseUrl: baseUrl,
      username: username,
      password: password,
    );
    final service = WebDAVService(
      client: client,
      profileId: profileId,
      cache: _directoryCache,
    );

    // 登录必须真实访问服务器；旧账号的目录缓存不能充当认证结果。
    await service.verifyConnection();
    return service;
  }

  void _commitConnection({
    required WebDAVService service,
    required String username,
    required String password,
    required String profileId,
  }) {
    _webDavService = service;
    _mountedServices[profileId] = service;
    _mountErrors.remove(profileId);
    _username = username;
    _password = password;
    _progressService.useProfile(profileId);
    _audioProgressService?.useProfile(profileId);
    unawaited(_playerService.captureOpenListProcessIdentity());
    notifyListeners();
  }

  /// 断开连接并清空状态。
  void disconnect() {
    final profileId = _webDavService?.sourceId;
    if (profileId != null) _mountedServices.remove(profileId);
    _webDavService = null;
    _username = null;
    _password = null;
    final storedProfileId = _configStore.current.profileId;
    _progressService.useProfile(storedProfileId);
    _audioProgressService?.useProfile(storedProfileId);
    notifyListeners();
  }
}
