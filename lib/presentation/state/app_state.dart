import '../../domain/services/film_scan_scheduler.dart';
import '../../data/local/media_connection_store.dart';
import '../../data/models/media_connection.dart';
import '../../domain/services/native_storage_source.dart';
import '../../domain/services/media_server_api.dart';
import '../../domain/services/media_server_source.dart';
import '../../domain/services/media_server_library.dart';
import '../../domain/services/media_server_sync.dart';
import '../../domain/services/film_file_metadata.dart';
import '../../domain/services/film_library_transfer.dart';
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
        if (mediaSourceKind(sourceId).isNativeStorage ||
            mediaSourceKind(sourceId).isMediaServer) {
          try {
            await mountMediaConnection(sourceId);
          } on FilmCatalogException {
            continue;
          }
        }
        final service =
            _nativeSources[sourceId]?.service ??
            _serverSources[sourceId]?.service ??
            mountedService(sourceId) ??
            (_webDavService?.sourceId == sourceId ? _webDavService : null);
        final local = localRoots
            .where((r) => r.sourceId == sourceId && r.enabled)
            .firstOrNull;
        if (service == null && local == null) continue;
        final MediaDirectorySource source = local != null
            ? localMediaSource(local)
            : _nativeSources[sourceId] ??
                  _serverSources[sourceId] ??
                  WebDavMediaSourceAdapter(service!);
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
    for (var offset = 0; ; offset += 128) {
      final resources = await store.resources(limit: 128, offset: offset);
      for (final r in resources) {
        if (r.availability != 'present' ||
            r.workId == null ||
            r.mediaKind != 'video' && r.mediaKind != 'strm' ||
            r.type == FilmMediaType.tv &&
                (r.season == null || r.episode == null)) {
          continue;
        }
        if (r.sourceKind == MediaSourceKind.webdav &&
            !directories.containsKey(r.sourceId)) {
          final index = <String, List<WebDavFile>>{};
          for (final directory in await _directoryCache.visitedDirectoriesAsync(
            r.sourceId,
          )) {
            index
                .putIfAbsent(normalizeLibraryPath(directory.path), () => [])
                .addAll(directory.entries);
          }
          directories[r.sourceId] = index;
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
      if (resources.length < 128) break;
      // 分批归还事件循环，加载遮罩与原生窗口消息继续推进。
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> _recordVideoWatch(VideoProgressUpdate update) async {
    if (_disposed || catalogWritesSuspended) return;
    await (await getFilmCatalogStore()).recordVideoProgress(update);
    await _serverSync[update.sourceId]?.progress(update);
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
    for (final source
        in resources
            .where((r) => r.sourceKind.isMediaServer)
            .map((r) => r.sourceId)
            .toSet()) {
      final sync = _serverSync[source];
      if (sync != null) {
        await sync.watched(
          resources.where((r) => r.sourceId == source).toList(),
          watched,
        );
      } else {
        for (final resource in resources.where((r) => r.sourceId == source)) {
          final row = await store.serverResource(source, resource.path);
          if (row != null) {
            await store.queueServerState(source, row['item_id'] as String, {
              'watched': watched,
              'positionMs': 0,
            });
          }
        }
      }
    }
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
                if (resource.mediaKind != 'strm') {
                  final progress = identical(histories, _playbackHistoryStore)
                      ? _progressService
                      : _filmProgressService!;
                  final target = _resolveMediaLibraryTarget(
                    resource.playbackItem,
                    allowLogicalPath: true,
                  );
                  if (target != null &&
                      await progress.getResumeProgress(
                            target,
                            profileId: group.key,
                          ) ==
                          null) {
                    await progress.saveProgress(
                      url: target,
                      profileId: group.key,
                      positionMs: 0,
                    );
                  }
                }
                await records?.advanceVideoRecord(
                  resource.playbackItem,
                  sessionId: history.sessionId,
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

  FilmScanScheduler? _filmScanScheduler;
  bool catalogWritesSuspended = false;
  Future<FilmLibraryTransfer> filmTransfer() async {
    final catalog = await getFilmCatalog();
    await initializeFilmPlayback();
    return FilmLibraryTransfer(
      store: catalog.store,
      images: catalog.images,
      records: {
        if (_mediaLibraryStore != null) 'normal': _mediaLibraryStore,
        if (_filmMediaLibraryStore != null) 'film': _filmMediaLibraryStore,
      },
      progress: {
        'normal': _progressService,
        'film': _filmProgressService!,
        if (_audioProgressService != null) 'audio': _audioProgressService,
      },
      targetFor: (item) =>
          _resolveMediaLibraryTarget(item, allowLogicalPath: true),
      dataDirectory: await AppPaths.dataDirectory(),
      players: {'normal': _playerService, 'film': _filmPlayerService!},
      isoServices: {
        'normal': ?_isoPlaybackService,
        'film': ?_filmIsoPlaybackService,
      },
    );
  }

  Future<Map<String, int>> importFilmTransfer(
    FilmTransferPreview preview,
    Set<String> categories,
    Map<String, String> sources,
  ) async {
    if (_closing) throw const FilmCatalogException('cancelled');
    final catalog = await getFilmCatalog();
    if (categories.contains('playback') && await anyPlaybackActive()) {
      throw const FilmCatalogException('importPlaybackActive');
    }
    final transfer = await filmTransfer();
    if (_closing) throw const FilmCatalogException('cancelled');
    catalogWritesSuspended = true;
    final finished = Completer<void>();
    _filmImportFinished = finished.future;
    try {
      await Future.wait(_serverSync.values.map((sync) => sync.waitForIdle()));
      await Future.wait(
        _serverLibraries.values.map((library) => library.waitForIdle()),
      );
      return await catalog.withWritesSuspended(() async {
        Future<Map<String, int>> operation() => transfer.import(
          preview,
          categories,
          sources,
          sourceKinds: {
            for (final source in sources.values)
              source: mediaSourceKind(source),
          },
          matches: (item) async {
            if (await catalog.store.resourceAt(
                  item.sourceId,
                  item.targetPath,
                ) !=
                null) {
              return true;
            }
            try {
              await mountMediaConnectionIfConfigured(item.sourceId);
              final rows = await directorySource(
                item.sourceId,
              ).fetchDirectory(item.parentPath, forceRefresh: true);
              return rows.where(item.matches).length == 1;
            } on FilmCatalogException {
              return false;
            } on AppException {
              return false;
            }
          },
        );
        if (_mediaLibraryStore != null) {
          return _mediaLibraryStore.withWritesSuspended(() async {
            if (_filmMediaLibraryStore != null) {
              return _filmMediaLibraryStore.withWritesSuspended(operation);
            }
            return operation();
          });
        }
        return operation();
      });
    } finally {
      catalogWritesSuspended = _closing;
      try {
        if (!_closing) await catalog.refresh();
      } finally {
        finished.complete();
        _filmImportFinished = null;
      }
    }
  }

  Future<MediaConnectionStore>? _mediaConnections;
  MediaConnectionStore? _mediaConnectionsValue;
  final _nativeSources = <String, NativeStorageSource>{};
  final _serverApis = <String, MediaServerApi>{};
  final _serverSources = <String, MediaServerSource>{};
  final _serverLibraries = <String, MediaServerLibrary>{};
  final _serverSync = <String, MediaServerSync>{};
  MediaServerSource? serverSource(String id) => _serverSources[id];
  String? serverSyncError(String id) => _serverSync[id]?.error;
  bool mediaSourcesVisible = false;
  Future<void> refreshMediaServer(String id, {bool metadata = true}) async {
    await mountMediaConnection(id);
    if (catalogWritesSuspended) return;
    if (metadata) {
      await _serverSync[id]!.flushPending();
      if (catalogWritesSuspended) return;
      await _serverLibraries[id]!.refresh();
      if (!catalogWritesSuspended) await _serverSync[id]!.refresh();
    } else {
      await _serverSync[id]!.refresh();
    }
    if (!_disposed) notifyListeners();
  }

  MediaServerApi? serverApi(String id) => _serverApis[id];
  final _nativeMounting = <String, Future<void>>{};
  final _nativeConnectingSources = <String, NativeStorageSource>{};
  List<MediaConnection> get mediaConnections =>
      _mediaConnectionsValue?.connections ?? const [];
  NativeStorageSource? nativeSource(String id) => _nativeSources[id];
  Future<void> mountMediaConnectionIfConfigured(String id) async {
    await getMediaConnections();
    if (mediaConnections.any((row) => row.id == id)) {
      await mountMediaConnection(id);
    } else if (!id.startsWith('local:') && mountedService(id) == null) {
      await mountProfile(id);
    }
  }

  Future<MediaConnectionStore> getMediaConnections() =>
      _mediaConnections ??= () async {
        final store = MediaConnectionStore(
          File(
            p.join(
              p.dirname(_configStore.configFilePath),
              'media_sources.json',
            ),
          ),
        );
        await store.load();
        _mediaConnectionsValue = store;
        if (!_disposed) notifyListeners();
        return store;
      }();
  MediaSourceKind mediaSourceKind(String id) => id.startsWith('local:')
      ? MediaSourceKind.local
      : mediaConnections.where((row) => row.id == id).firstOrNull?.kind ??
            MediaSourceKind.webdav;
  MediaDirectorySource directorySource(String id) {
    if (_nativeSources[id] case final source?) return source;
    if (_serverSources[id] case final source?) return source;
    final root = localRoots
        .where((r) => r.sourceId == id && r.enabled)
        .firstOrNull;
    if (root != null) return localMediaSource(root);
    if (mountedService(id) case final service?) {
      return WebDavMediaSourceAdapter(service);
    }
    throw const FilmCatalogException('sourceUnavailable');
  }

  Future<void> mountMediaConnection(String id) => _nativeMounting.putIfAbsent(
    id,
    () =>
        () async {
          final store = await getMediaConnections();
          final config = store.connections
              .where((row) => row.id == id)
              .firstOrNull;
          if (config == null || !config.enabled) {
            throw const FilmCatalogException('sourceUnavailable');
          }
          final secrets = await store.secrets(id);
          if (config.kind.isMediaServer) {
            if (_serverApis.containsKey(id)) return;
            final api = mediaServerApi(config, credentials: secrets);
            try {
              if (api.token == null) {
                final authenticated = await api.authenticate(
                  secrets['password'] as String? ?? '',
                );
                if (!store.connections.contains(config)) {
                  api.close();
                  throw const FilmCatalogException('sourceUnavailable');
                }
                await store.save(config, secrets: authenticated);
              } else {
                await api.verify();
              }
              if (_disposed) {
                api.close();
                return;
              }
              if (!store.connections.contains(config)) {
                api.close();
                throw const FilmCatalogException('sourceUnavailable');
              }
              final catalog = await getFilmCatalogStore();
              await catalog.rememberServerIdentity(
                id,
                '${api.serverId!}:${api.userId!}',
              );
              final source = await MediaServerSource.open(catalog, api);
              if (_disposed || !store.connections.contains(config)) {
                await source.close();
                api.close();
                if (!_disposed) {
                  throw const FilmCatalogException('sourceUnavailable');
                }
                return;
              }
              _serverApis[id] = api;
              _serverSources[id] = source;
              _serverLibraries[id] = MediaServerLibrary(catalog, api);
              _serverSync[id] = MediaServerSync(
                catalog,
                source,
                onErrorChanged: () {
                  if (!_disposed) notifyListeners();
                },
                onUserData: (item) async {
                  if (catalogWritesSuspended) return;
                  await initializeFilmPlayback();
                  final userData = item['UserData'] as Map? ?? {};
                  final position =
                      ((userData['PlaybackPositionTicks'] as num? ?? 0) / 10000)
                          .round();
                  final watched = userData['Played'] == true;
                  final duration = ((item['RunTimeTicks'] as num? ?? 0) / 10000)
                      .round();
                  final versions = await catalog.serverResources(
                    id,
                    itemId: item['Id'] as String,
                  );
                  for (final row in versions) {
                    final resource = await catalog.resourceAt(
                      id,
                      row['relative_path'] as String,
                    );
                    if (resource == null) continue;
                    final target = PlaybackProgressService.logicalTarget(
                      id,
                      resource.path,
                    );
                    final previous = await _filmProgressService!.getProgress(
                      target,
                      profileId: id,
                    );
                    if (watched || position <= 0) {
                      if (previous != null) {
                        await _filmProgressService!.deleteProgress(
                          target,
                          profileId: id,
                        );
                      }
                    } else if (previous?.positionMs != position ||
                        previous?.durationMs != duration) {
                      await _filmProgressService!.saveProgress(
                        url: target,
                        profileId: id,
                        positionMs: position,
                        durationMs: duration > 0 ? duration : null,
                      );
                      await _filmMediaLibraryStore?.recordRemoteContinue(
                        resource.playbackItem,
                      );
                    }
                  }
                },
              );
              _progressService.registerSessionOrigin(id, source.bridge.baseUrl);
              _filmProgressService?.registerSessionOrigin(
                id,
                source.bridge.baseUrl,
              );
              notifyListeners();
            } catch (_) {
              api.close();
              rethrow;
            }
            return;
          }
          if (_nativeSources.containsKey(id)) return;
          if (_disposed || _closing) return;
          if (!store.connections.contains(config)) {
            throw const FilmCatalogException('sourceUnavailable');
          }
          final source = await NativeStorageSource.open(
            config,
            secrets['password'] as String? ?? '',
          );
          if (_disposed || _closing) {
            await source.close();
            return;
          }
          _nativeConnectingSources[id] = source;
          try {
            await source.fetchDirectory('', forceRefresh: true);
            if (_disposed || _closing || !store.connections.contains(config)) {
              await source.close();
              if (!_disposed && !_closing) {
                throw const FilmCatalogException('sourceUnavailable');
              }
              return;
            }
            _nativeSources[id] = source;
            _progressService.registerSessionOrigin(id, source.bridge.baseUrl);
            _filmProgressService?.registerSessionOrigin(
              id,
              source.bridge.baseUrl,
            );
            notifyListeners();
          } catch (_) {
            await source.close();
            rethrow;
          } finally {
            _nativeConnectingSources.remove(id);
          }
        }().whenComplete(() {
          _nativeMounting.remove(id);
        }),
  );
  Future<void> saveMediaConnection(
    MediaConnection config, {
    Map<String, dynamic>? secrets,
  }) async {
    final store = await getMediaConnections();
    if ((_nativeSources.containsKey(config.id) ||
            _serverSources.containsKey(config.id)) &&
        await anyPlaybackActive()) {
      throw const FilmCatalogException('sourcePlaybackActive');
    }
    await store.save(config, secrets: secrets);
    _nativeConnectingSources[config.id]?.reader.cancelCurrent();
    _serverApis[config.id]?.close();
    await _nativeSources.remove(config.id)?.close();
    await _serverLibraries.remove(config.id)?.close();
    await _serverSync.remove(config.id)?.close();
    await _serverSources.remove(config.id)?.close();
    _serverApis.remove(config.id)?.close();
    if (!_disposed) notifyListeners();
  }

  Future<void> removeMediaConnection(String id) async {
    if ((_nativeSources.containsKey(id) || _serverSources.containsKey(id)) &&
        await anyPlaybackActive()) {
      throw const FilmCatalogException('sourcePlaybackActive');
    }
    final connections = await getMediaConnections();
    final server = connections.connections.any(
      (row) => row.id == id && row.kind.isMediaServer,
    );
    await connections.remove(id);
    _nativeConnectingSources[id]?.reader.cancelCurrent();
    _serverApis[id]?.close();
    await _nativeSources.remove(id)?.close();
    await _serverLibraries.remove(id)?.close();
    await _serverSync.remove(id)?.close();
    await _serverSources.remove(id)?.close();
    _serverApis.remove(id)?.close();
    if (server) await (await getFilmCatalogStore()).removeServerData(id);
    if (!_disposed) notifyListeners();
  }

  void startFilmScanSchedule() {
    startupReady.addListener(_startFilmSchedule);
    _startFilmSchedule();
  }

  void _startFilmSchedule() {
    if (!startupReady.value || _disposed || _closing) return;
    unawaited(
      getFilmCatalog().then((catalog) {
        if (_disposed || _closing) return;
        (_filmScanScheduler ??= FilmScanScheduler(
          store: catalog.store,
          isBusy: () => anyPlaybackActive(catalog: catalog),
          scan: (roots) async {
            await catalog.run(() async {
              final enabled = roots
                  .where(
                    (root) =>
                        root.sourceKind.isNativeStorage ||
                            root.sourceKind.isMediaServer
                        ? mediaConnections.any(
                            (connection) =>
                                connection.id == root.sourceId &&
                                connection.enabled,
                          )
                        : root.sourceKind == MediaSourceKind.local
                        ? localRoots.any(
                            (local) =>
                                local.sourceId == root.sourceId &&
                                local.enabled,
                          )
                        : _configStore.current.mountedProfileIds.contains(
                            root.sourceId,
                          ),
                  )
                  .toList();
              for (final root in enabled.where(
                (r) => r.sourceKind.isNativeStorage,
              )) {
                await mountMediaConnection(root.sourceId);
              }
              await catalog.scanRoots(enabled);
            });
          },
        )).start();
      }),
    );
  }

  Future<bool> anyPlaybackActive({FilmCatalogController? catalog}) async =>
      catalogWritesSuspended ||
      (catalog?.busy ?? false) ||
      (catalog?.scraping ?? false) ||
      await _hasRunningPlayback() ||
      await _playerService.anyPlayerRunning() ||
      (await _filmPlayerService?.anyPlayerRunning() ?? false) ||
      await _localDiscPlaybackService.anyPlayerRunning() ||
      (await _filmLocalDiscPlaybackService?.anyPlayerRunning() ?? false) ||
      (await _isoPlaybackService?.hasActivePlayback() ?? false) ||
      (await _filmIsoPlaybackService?.hasActivePlayback() ?? false);
  Future<FilmCatalogController>? _filmCatalog;
  FilmCatalogController? _filmCatalogValue;
  bool _disposed = false;
  bool _closing = false;
  Future<void>? _filmImportFinished;
  Future<void>? _closePreparation;

  Future<bool> updateBlocked() => anyPlaybackActive(catalog: _filmCatalogValue);

  /// 更新关闭先等待播放器结束后的进度写入，不主动结束播放器。
  Future<bool> prepareForUpdate() async {
    if (await updateBlocked()) return false;
    _playerService.stopImplicitPlaybackControl();
    _filmPlayerService?.stopImplicitPlaybackControl();
    await _playerService.finishStoppedSessions();
    await _filmPlayerService?.finishStoppedSessions();
    await _audioPlayerService?.finishStoppedSessions();
    await prepareForClose();
    return true;
  }

  Future<void> prepareForClose() => _closePreparation ??= () async {
    _closing = true;
    catalogWritesSuspended = true;
    await _filmImportFinished;
    _filmScanScheduler?.stop();
    _playerService.stopImplicitPlaybackControl();
    _filmPlayerService?.stopImplicitPlaybackControl();
    _filmCatalogValue?.cancel();
    _filmCatalogValue?.mediaProbe?.stop();
    // 先解除服务器请求等待，再等待扫描提交取消状态。
    for (final api in _serverApis.values) {
      api.close();
    }
    for (final source in _nativeConnectingSources.values.toList()) {
      source.reader.cancelCurrent();
    }
    await _filmScanScheduler?.close();
    if (_filmCatalog != null) {
      await (await _filmCatalog!).withWritesSuspended(() async {});
    }
    await _finishPendingNativeMounts();
    for (final library in _serverLibraries.values) {
      await library.close();
    }
    for (final sync in _serverSync.values) {
      await sync.close();
    }
    for (final source in _nativeSources.values) {
      await source.close();
    }
    for (final source in _serverSources.values) {
      await source.close();
    }
  }();

  Future<void> _finishPendingNativeMounts() => Future.wait([
    for (final mounting in _nativeMounting.values.toList())
      () async {
        try {
          await mounting;
        } on FilmCatalogException {
          // 挂载调用方接收连接错误，退出继续释放其他来源。
        }
      }(),
  ]);

  Future<FilmCatalogController> getFilmCatalog() => _filmCatalog ??= () async {
    await getMediaConnections();
    await initializeFilmPlayback();
    final cache = await AppPaths.cacheDirectory();
    final store = await getFilmCatalogStore();
    final connections = await getMediaConnections();
    final servers = connections.connections
        .where((row) => row.kind.isMediaServer)
        .toList();
    await store.reconcileServerSources(servers.map((row) => row.id).toSet());
    for (final server in servers) {
      final identity = await connections.secrets(server.id);
      if (identity['serverId'] is String && identity['userId'] is String) {
        await store.rememberServerIdentity(
          server.id,
          '${identity['serverId']}:${identity['userId']}',
        );
      }
    }
    final tmdb = TmdbMetadataService();
    final controller = FilmCatalogController(
      store: store,
      tmdb: tmdb,
      images: FilmCatalogImageCache(
        Directory(p.join(cache.path, 'film_artwork')),
        tmdb,
        readReference: (ref, maxBytes) async {
          if (ref.origin == 'asset') {
            if (!RegExp(
              r'^imported_artwork/[a-f0-9]{64}\.bin$',
            ).hasMatch(ref.path)) {
              throw const FilmCatalogException('invalidImage');
            }
            final file = File(
              p.join((await AppPaths.libraryDirectory()).path, ref.path),
            );
            if (await file.length() > maxBytes) {
              throw const FilmCatalogException('imageTooLarge');
            }
            return file.readAsBytes();
          }
          await mountMediaConnectionIfConfigured(ref.sourceId);
          if (ref.origin == 'server') {
            return _serverApis[ref.sourceId]!.image(
              ref.path,
              ref.type!,
              ref.tag!,
              index: ref.index,
            );
          }
          final source = directorySource(ref.sourceId);
          if (source is NativeStorageSource) {
            return source.readFile(ref.path, maxBytes: maxBytes);
          }
          if (source is LocalMediaSource) {
            final file = File(await source.resolveRelativePath(ref.path));
            if (await file.length() > maxBytes) {
              throw const FilmCatalogException('imageTooLarge');
            }
            return file.readAsBytes();
          }
          final webdav = source as WebDavMediaSourceAdapter;
          return Uint8List.fromList(
            await webdav.service.fetchFileBytes(
              webdav.service.resolveUrl(ref.path),
              maxBytes: maxBytes,
              timeout: const Duration(seconds: 30),
            ),
          );
        },
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
      serverRefresh: (root) => refreshMediaServer(root.sourceId),
      filesFor: (root) async {
        if (root.sourceKind.isMediaServer) return null;
        final config = mediaConnections
            .where((row) => row.id == root.sourceId)
            .firstOrNull;
        return FilmFileMetadata(
          _filmSource(root),
          root,
          localMode:
              config?.localMetadata ??
              await store.preference('local_metadata:${root.sourceId}') == true,
          canWrite:
              config?.canWrite ??
              (await store.preference('write_back:${root.sourceId}') == true &&
                  await store.preference('read_only:${root.sourceId}') != true),
        );
      },
    );
    _filmCatalogValue = controller;
    if (!_disposed) {
      controller.mediaProbe!.start();
    }
    return controller;
  }();

  MediaDirectorySource _filmSource(FilmCatalogRoot root) {
    if (root.sourceKind.isNativeStorage || root.sourceKind.isMediaServer) {
      return directorySource(root.sourceId);
    }
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
    final service =
        nativeSource(snapshot.sourceId)?.service ??
        serverSource(snapshot.sourceId)?.service ??
        mountedService(snapshot.sourceId);
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
    for (final source in _nativeSources.values) {
      progress.registerSessionOrigin(source.config.id, source.bridge.baseUrl);
    }
    for (final source in _serverSources.values) {
      progress.registerSessionOrigin(
        source.api.config.id,
        source.bridge.baseUrl,
      );
    }
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
    if (item.sourceKind.isNativeStorage || item.sourceKind.isMediaServer) {
      final target = PlaybackProgressService.logicalTarget(
        item.sourceId,
        item.targetPath,
      );
      return item.discRootPath == null ? target : '$target/';
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
      final file = _directoryCache.visitedFile(item);
      entries = file == null ? const [] : [file];
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
    startupReady.removeListener(_startFilmSchedule);
    _filmScanScheduler?.stop();
    for (final source in _nativeConnectingSources.values.toList()) {
      source.reader.cancelCurrent();
    }
    if (_mediaConnections != null) {
      unawaited(() async {
        await _finishPendingNativeMounts();
        for (final source in _nativeSources.values) {
          await source.close();
        }
        for (final library in _serverLibraries.values) {
          await library.close();
        }
        for (final sync in _serverSync.values) {
          await sync.close();
        }
        for (final source in _serverSources.values) {
          await source.close();
        }
        for (final api in _serverApis.values) {
          api.close();
        }
        await (await _mediaConnections!).close();
      }());
    }
    _playerService.stopImplicitPlaybackControl();
    _filmPlayerService?.stopImplicitPlaybackControl();
    _filmCatalogValue?.mediaProbe?.stop();
    if (_filmCatalog != null) {
      unawaited(
        _filmCatalog!.then((controller) async {
          await _filmScanScheduler?.close();
          await controller.close();
        }),
      );
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
  Future<CacheCleanupResult> clearCache({
    CacheCleanupScope scope = CacheCleanupScope.all,
  }) async {
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
    if (scope == CacheCleanupScope.all || scope == CacheCleanupScope.playback) {
      await _clearUnreferencedProgress(_progressService, _mediaLibraryStore);
      if (_audioProgressService case final audio?) {
        await _clearUnreferencedProgress(
          audio,
          _mediaLibraryStore,
          audio: true,
        );
      }
      if (_filmProgressService case final film?) {
        await _clearUnreferencedProgress(film, _filmMediaLibraryStore);
      }
    }
    if ((scope == CacheCleanupScope.all ||
            scope == CacheCleanupScope.metadata) &&
        _filmCatalog != null) {
      try {
        final catalog = await _filmCatalog!;
        await catalog.images.clear();
        await catalog.store.clearProbeMetadata();
      } on FilmCatalogException catch (error) {
        throw CacheCleanupException(filmCatalogErrorText(error.code), error);
      }
    }
    final result = await cleaner.clear(scope: scope);
    if (scope == CacheCleanupScope.all || scope == CacheCleanupScope.playback) {
      await _filmPlaybackHistoryStore.clear();
    }
    notifyListeners();
    return result;
  }

  Future<void> _clearUnreferencedProgress(
    PlaybackProgressService service,
    MediaLibraryStore? store, {
    bool audio = false,
  }) async {
    final preserved = <(String, String)>{};
    final directories = <String, Map<String, List<WebDavFile>>>{};
    final snapshot = await service.resumeProgressSnapshot();
    for (final item
        in await store?.playbackProgressItems(audio: audio) ??
            <MediaLibraryItem>[]) {
      if (item.kind == MediaLibraryKind.strm) continue;
      final url = _resolveMediaLibraryTarget(
        item,
        allowLogicalPath: true,
        cachedDirectories: directories,
      );
      if (url != null) {
        preserved.add((item.sourceId, url));
      } else {
        // 暂时不可用的来源仍保留媒体中心引用的进度。
        preserved.addAll(snapshot.keys.where((key) => key.$1 == item.sourceId));
      }
    }
    await service.clearAll(preserved: preserved);
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
    final changed =
        !identical(_webDavService, service) ||
        _username != username ||
        _password != password ||
        _mountErrors.containsKey(profileId);
    _webDavService = service;
    _mountedServices[profileId] = service;
    _mountErrors.remove(profileId);
    _username = username;
    _password = password;
    _progressService.useProfile(profileId);
    _audioProgressService?.useProfile(profileId);
    unawaited(_playerService.captureOpenListProcessIdentity());
    if (changed) notifyListeners();
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
