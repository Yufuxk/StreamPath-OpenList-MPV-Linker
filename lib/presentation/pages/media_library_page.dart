import '../widgets/directory_scroll_view.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../widgets/sp_icons.dart';
import '../widgets/sp_dialog.dart';
import '../widgets/sp_notice.dart';

import '../localization/app_localizations.dart';
import '../localization/app_text.dart';

import '../../core/utils/url_utils.dart';
import '../../data/local/directory_cache.dart';
import '../../data/local/media_library_store.dart';
import '../../data/local/playback_progress_db.dart';
import '../../data/models/media_library_item.dart';
import '../../data/models/media_library_config.dart';
import '../../data/models/playback_progress.dart';
import '../../data/models/media_source.dart';
import '../../data/models/web_dav_file.dart';
import '../../domain/services/media_library_search.dart';
import '../../domain/services/iso_playback_service.dart';
import '../theme/glass_tokens.dart';
import '../widgets/clipboard_history_menu.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/glass_surface.dart';
import '../widgets/film_favorites_wall.dart';
import '../widgets/film_shelf.dart';
import '../widgets/film_continue_card.dart';
import '../widgets/film_library_background.dart';
import '../controllers/film_catalog_controller.dart';

enum _FavoriteLane { media, video, audio, iso }

enum _MediaLane { video, audio, iso }

enum _DirectoryLane { favorites, recent }

/// 展开续播时复用当前已就绪的展示数据。
class FilmContinueSnapshot {
  FilmContinueSnapshot({
    required List<MediaLibraryRecord> videos,
    required List<MediaLibraryRecord> discs,
    required Map<String, PlaybackProgress> videoProgress,
    required Map<String, IsoLibraryProgress> discProgress,
  }) : videos = List.of(videos),
       discs = List.of(discs),
       videoProgress = Map.of(videoProgress),
       discProgress = Map.of(discProgress);

  final List<MediaLibraryRecord> videos, discs;
  final Map<String, PlaybackProgress> videoProgress;
  final Map<String, IsoLibraryProgress> discProgress;
}

/// 收藏、继续播放、最近播放和访问型全局搜索入口。
class MediaLibraryPage extends StatefulWidget {
  const MediaLibraryPage({
    super.key,
    required this.sourceId,
    required this.store,
    this.config = const MediaLibraryConfig(),
    required this.directoryCache,
    required this.videoProgressService,
    required this.audioProgressService,
    this.isoProgressService,
    required this.resolveUrl,
    this.resolveDirectTarget,
    this.sourceIds,
    this.sourceNames = const {},
    this.localIsoProgressService,
    this.onVideoPlaybackRecordsChanged,
    this.onItemSelected,
    this.sourceFilter,
    this.filmCatalog,
    this.onContinueSelected,
    this.loadFilmCatalog,
    this.onContinueMenu,
    this.filmContinueAll = false,
    this.filmCenter = false,
    this.headerAction,
    this.sidebarInset = 0,
    this.onReadyChanged,
    this.initialContinue,
  });

  final String sourceId;
  final Set<String>? sourceIds;
  final Map<String, String> sourceNames;
  final IsoLibraryProgressReader? localIsoProgressService;
  final MediaLibraryStore store;
  final MediaLibraryConfig config;
  final DirectoryCache directoryCache;
  final PlaybackProgressReader videoProgressService;
  final PlaybackProgressReader? audioProgressService;
  final IsoLibraryProgressReader? isoProgressService;
  final String Function(String href) resolveUrl;
  final String? Function(MediaLibraryItem item)? resolveDirectTarget;
  final VoidCallback? onVideoPlaybackRecordsChanged;
  final ValueChanged<MediaLibraryItem>? onItemSelected;
  final Widget? sourceFilter;
  final FilmCatalogController? filmCatalog;
  final bool filmContinueAll;
  final bool filmCenter;
  final Widget? headerAction;
  final double sidebarInset;
  final ValueChanged<bool>? onReadyChanged;
  final FilmContinueSnapshot? initialContinue;
  final ValueChanged<MediaLibraryRecord>? onContinueSelected;
  final Future<FilmCatalogController> Function()? loadFilmCatalog;
  final void Function(MediaLibraryRecord, Offset)? onContinueMenu;

  @override
  State<MediaLibraryPage> createState() => _MediaLibraryPageState();
}

class _MediaLibraryPageState extends State<MediaLibraryPage> {
  void _selectItem(MediaLibraryItem item) {
    final callback = widget.onItemSelected;
    if (callback != null) {
      callback(item);
    } else {
      Navigator.of(context).pop(item);
    }
  }

  Set<String> get _sourceIds => widget.sourceIds ?? {widget.sourceId};
  Set<(int, String, String)> _disabledRoots = {};

  void _onCatalogChanged() {
    final disabled =
        widget.filmCatalog?.roots
            .where((root) => !root.enabled)
            .map((root) => (root.id, root.sourceId, root.path))
            .toSet() ??
        <(int, String, String)>{};
    if (setEquals(disabled, _disabledRoots)) return;
    _disabledRoots = disabled;
    _onLibraryChanged();
  }

  Future<List<MediaLibraryRecord>> _collectRecords(
    Future<List<MediaLibraryRecord>> Function(String) read,
  ) async {
    final records = (await Future.wait(_sourceIds.map(read)))
        .expand((items) => items)
        .where(
          (record) => widget.filmCatalog?.isItemEnabled(record.item) != false,
        )
        .toList();
    records.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return records;
  }

  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  Timer? _libraryRefreshDebounce;
  Timer? _progressRefreshDebounce;
  Timer? _isoProgressRefreshDebounce;
  Future<void> _progressOperationTail = Future<void>.value();
  final Set<String> _pendingVideoProgressUrls = {};
  final Set<String> _pendingAudioProgressUrls = {};
  bool _refreshAllVideoProgress = false;
  bool _refreshAllAudioProgress = false;
  int _searchGeneration = 0;
  int _libraryGeneration = 0;
  int _progressGeneration = 0;
  bool _loading = true;
  bool _sourcePending = false;
  bool _loadingContinue = false;
  String? _error;
  _FavoriteLane _favoriteLane = _FavoriteLane.media;
  _MediaLane _continueLane = _MediaLane.video;
  _MediaLane _recentLane = _MediaLane.video;
  _DirectoryLane _directoryLane = _DirectoryLane.favorites;
  List<MediaLibraryRecord> _favorites = const [];
  List<MediaLibraryRecord> _recentDirectories = const [];
  List<MediaLibraryRecord> _videoHistory = const [];
  List<MediaLibraryRecord> _audioHistory = const [];
  List<MediaLibraryRecord> _isoHistory = const [];
  Map<String, String> _filmTitles = {};
  List<VisitedDirectorySnapshot> _snapshots = const [];
  List<MediaLibrarySearchResult> _searchResults = const [];
  Map<String, PlaybackProgress> _videoContinue = const {};
  Map<String, PlaybackProgress> _audioContinue = const {};
  Map<String, IsoLibraryProgress> _isoContinue = const {};

  @override
  void initState() {
    super.initState();
    if (widget.initialContinue case final initial?) {
      _videoHistory = initial.videos;
      _isoHistory = initial.discs;
      _videoContinue = initial.videoProgress;
      _isoContinue = initial.discProgress;
      _loading = false;
    }
    widget.onReadyChanged?.call(false);
    widget.store.addListener(_onLibraryChanged);
    widget.filmCatalog?.addListener(_onCatalogChanged);
    _disabledRoots =
        widget.filmCatalog?.roots
            .where((root) => !root.enabled)
            .map((root) => (root.id, root.sourceId, root.path))
            .toSet() ??
        <(int, String, String)>{};
    widget.videoProgressService.addListener(_onVideoProgressChanged);
    widget.audioProgressService?.addListener(_onAudioProgressChanged);
    widget.isoProgressService?.addLibraryProgressListener(
      _onIsoProgressChanged,
    );
    widget.localIsoProgressService?.addLibraryProgressListener(
      _onIsoProgressChanged,
    );
    _loadAll(showLoading: widget.initialContinue == null);
  }

  @override
  void didUpdateWidget(MediaLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filmCatalog != widget.filmCatalog) {
      oldWidget.filmCatalog?.removeListener(_onCatalogChanged);
      widget.filmCatalog?.addListener(_onCatalogChanged);
    }
    if (oldWidget.filmCatalog != widget.filmCatalog ||
        !setEquals(oldWidget.sourceIds ?? {oldWidget.sourceId}, _sourceIds)) {
      _sourcePending = widget.filmCatalog != null;
      _disabledRoots =
          widget.filmCatalog?.roots
              .where((root) => !root.enabled)
              .map((root) => (root.id, root.sourceId, root.path))
              .toSet() ??
          <(int, String, String)>{};
      unawaited(_loadAll(showLoading: false));
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _libraryRefreshDebounce?.cancel();
    _progressRefreshDebounce?.cancel();
    _isoProgressRefreshDebounce?.cancel();
    widget.store.removeListener(_onLibraryChanged);
    widget.filmCatalog?.removeListener(_onCatalogChanged);
    widget.videoProgressService.removeListener(_onVideoProgressChanged);
    widget.audioProgressService?.removeListener(_onAudioProgressChanged);
    widget.isoProgressService?.removeLibraryProgressListener(
      _onIsoProgressChanged,
    );
    widget.localIsoProgressService?.removeLibraryProgressListener(
      _onIsoProgressChanged,
    );
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadAll({bool showLoading = true}) async {
    _libraryRefreshDebounce?.cancel();
    final libraryGeneration = ++_libraryGeneration;
    if (widget.filmCatalog != null) ++_progressGeneration;
    if (mounted && showLoading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final records = await Future.wait<List<MediaLibraryRecord>>([
        _collectRecords(widget.store.favorites),
        _collectRecords(widget.store.recentDirectories),
        _collectRecords((id) => widget.store.playbackHistory(id, audio: false)),
        _collectRecords((id) => widget.store.playbackHistory(id, audio: true)),
        _collectRecords(
          (id) => widget.store.playbackHistory(id, audio: false, iso: true),
        ),
      ]);
      final titles = widget.filmCenter
          ? await widget.filmCatalog!.store.playbackTitles([
              ...records[2],
              ...records[4],
            ])
          : <String, String>{};
      if (!mounted || libraryGeneration != _libraryGeneration) return;
      void publishRecords() {
        _favorites = records[0];
        _recentDirectories = records[1];
        _videoHistory = records[2];
        _audioHistory = records[3];
        _isoHistory = records[4];
        _filmTitles = titles;
        _snapshots =
            widget.filmCatalog == null || widget.resolveDirectTarget == null
            ? widget.directoryCache.visitedDirectories(widget.sourceId)
            : const [];
        _loading = false;
        _sourcePending = false;
        _error = null;
      }

      if (widget.filmCatalog == null) setState(publishRecords);
      await _enqueueProgressOperation(() async {
        if (!mounted || libraryGeneration != _libraryGeneration) return;
        final progressGeneration = ++_progressGeneration;
        await _loadContinueProgress(
          progressGeneration,
          records: widget.filmCatalog == null ? null : records,
          onLoaded: widget.filmCatalog == null ? null : publishRecords,
        );
      });
      if (!mounted || libraryGeneration != _libraryGeneration) return;
      _runSearch(_searchController.text);
      if (mounted && libraryGeneration == _libraryGeneration) {
        widget.onReadyChanged?.call(true);
      }
    } catch (error) {
      if (!mounted || libraryGeneration != _libraryGeneration) return;
      widget.onReadyChanged?.call(true);
      if (showLoading) {
        setState(() {
          _loading = false;
          _error = '读取媒体资产失败：$error';
        });
      } else {
        _showError('刷新媒体资产失败：$error');
      }
    }
  }

  void _onLibraryChanged() {
    if (!mounted) return;
    if (widget.filmCatalog != null && !_sourcePending) {
      List<MediaLibraryRecord> snapshot({bool iso = false}) =>
          [
                for (final source in _sourceIds)
                  ...widget.store.playbackHistorySnapshot(
                    source,
                    audio: false,
                    iso: iso,
                  ),
              ]
              .where((record) => widget.filmCatalog!.isItemEnabled(record.item))
              .toList()
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      setState(() {
        final previous = {
          for (final record in _videoHistory)
            record.recordKey: record.item.stableKey,
        };
        _videoHistory = snapshot();
        for (final record in _videoHistory) {
          if (previous[record.recordKey] != null &&
              previous[record.recordKey] != record.item.stableKey &&
              _videoContinue.containsKey(record.recordKey)) {
            ++_progressGeneration;
            _videoContinue[record.recordKey] = PlaybackProgress(
              url: _progressUrlFor(record) ?? record.item.targetPath,
              positionMs: record.strmPositionMs ?? 0,
              durationMs: record.strmDurationMs,
            );
          }
        }
        _isoHistory = snapshot(iso: true);
      });
    }
    _libraryRefreshDebounce?.cancel();
    _libraryRefreshDebounce = Timer(const Duration(milliseconds: 100), () {
      unawaited(_loadAll(showLoading: false));
    });
  }

  void _onVideoProgressChanged(PlaybackProgressChange change) =>
      _scheduleProgressRefresh(change, audio: false);

  void _onAudioProgressChanged(PlaybackProgressChange change) =>
      _scheduleProgressRefresh(change, audio: true);

  void _onIsoProgressChanged() {
    if (!mounted) return;
    _isoProgressRefreshDebounce?.cancel();
    _isoProgressRefreshDebounce = Timer(const Duration(milliseconds: 120), () {
      unawaited(
        _enqueueProgressOperation(() async {
          final generation = ++_progressGeneration;
          await _loadContinueProgress(generation, showLoading: false);
        }),
      );
    });
  }

  void _scheduleProgressRefresh(
    PlaybackProgressChange change, {
    required bool audio,
  }) {
    if (!mounted) return;
    if (change.profileId.isNotEmpty && !_sourceIds.contains(change.profileId)) {
      return;
    }
    final urls = audio ? _pendingAudioProgressUrls : _pendingVideoProgressUrls;
    if (change.affectsAll) {
      if (audio) {
        _refreshAllAudioProgress = true;
      } else {
        _refreshAllVideoProgress = true;
      }
      urls.clear();
    } else {
      urls.add(stripUserInfo(change.url!));
    }
    _progressRefreshDebounce?.cancel();
    _progressRefreshDebounce = Timer(const Duration(milliseconds: 120), () {
      final videoUrls = Set<String>.of(_pendingVideoProgressUrls);
      final audioUrls = Set<String>.of(_pendingAudioProgressUrls);
      final allVideo = _refreshAllVideoProgress;
      final allAudio = _refreshAllAudioProgress;
      _pendingVideoProgressUrls.clear();
      _pendingAudioProgressUrls.clear();
      _refreshAllVideoProgress = false;
      _refreshAllAudioProgress = false;
      unawaited(
        _enqueueProgressOperation(
          () => _refreshChangedProgress(
            videoUrls: videoUrls,
            audioUrls: audioUrls,
            allVideo: allVideo,
            allAudio: allAudio,
          ),
        ),
      );
    });
  }

  Future<void> _enqueueProgressOperation(Future<void> Function() operation) {
    final next = _progressOperationTail.then((_) => operation());
    _progressOperationTail = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  Future<void> _refreshChangedProgress({
    required Set<String> videoUrls,
    required Set<String> audioUrls,
    required bool allVideo,
    required bool allAudio,
  }) async {
    final generation = ++_progressGeneration;
    final limit = widget.config.normalized.maxContinuePerLane;
    final videoRecords = _continueCandidates(_videoHistory);
    final video = Map<String, PlaybackProgress>.of(_videoContinue);
    if (allVideo) {
      video.clear();
      await _loadProgressLane(
        records: videoRecords,
        service: widget.videoProgressService,
        useTemporaryCheckpoint: true,
        output: video,
        generation: generation,
      );
    } else if (videoUrls.isNotEmpty) {
      final wasFull = video.length >= limit;
      final refreshedKeys = await _refreshProgressLane(
        records: videoRecords,
        service: widget.videoProgressService,
        useTemporaryCheckpoint: true,
        output: video,
        urls: videoUrls,
        generation: generation,
      );
      _trimProgressLane(video, videoRecords, limit);
      if (wasFull && video.length < limit) {
        await _loadProgressLane(
          records: videoRecords,
          service: widget.videoProgressService,
          useTemporaryCheckpoint: true,
          output: video,
          generation: generation,
          skipRecordKeys: refreshedKeys,
        );
      }
    }
    final audioService = widget.audioProgressService;
    final audioRecords = _continueCandidates(_audioHistory);
    final audio = Map<String, PlaybackProgress>.of(_audioContinue);
    if (audioService != null) {
      if (allAudio) {
        audio.clear();
        await _loadProgressLane(
          records: audioRecords,
          service: audioService,
          useTemporaryCheckpoint: false,
          output: audio,
          generation: generation,
        );
      } else if (audioUrls.isNotEmpty) {
        final wasFull = audio.length >= limit;
        final refreshedKeys = await _refreshProgressLane(
          records: audioRecords,
          service: audioService,
          useTemporaryCheckpoint: false,
          output: audio,
          urls: audioUrls,
          generation: generation,
        );
        _trimProgressLane(audio, audioRecords, limit);
        if (wasFull && audio.length < limit) {
          await _loadProgressLane(
            records: audioRecords,
            service: audioService,
            useTemporaryCheckpoint: false,
            output: audio,
            generation: generation,
            skipRecordKeys: refreshedKeys,
          );
        }
      }
    }
    if (!mounted || generation != _progressGeneration) return;
    setState(() {
      _videoContinue = video;
      _audioContinue = audio;
      _loadingContinue = false;
    });
  }

  Future<void> _loadContinueProgress(
    int generation, {
    bool showLoading = true,
    List<List<MediaLibraryRecord>>? records,
    VoidCallback? onLoaded,
  }) async {
    if (!mounted || generation != _progressGeneration) return;
    if (showLoading) setState(() => _loadingContinue = true);
    final video = <String, PlaybackProgress>{};
    final audio = <String, PlaybackProgress>{};
    final iso = <String, IsoLibraryProgress>{};
    await _loadProgressLane(
      records: _continueCandidates(records?[2] ?? _videoHistory),
      service: widget.videoProgressService,
      useTemporaryCheckpoint: true,
      output: video,
      generation: generation,
    );
    final audioService = widget.audioProgressService;
    if (audioService != null) {
      await _loadProgressLane(
        records: _continueCandidates(records?[3] ?? _audioHistory),
        service: audioService,
        useTemporaryCheckpoint: false,
        output: audio,
        generation: generation,
      );
    }
    final isoService =
        widget.isoProgressService ?? widget.localIsoProgressService;
    if (isoService != null) {
      await _loadIsoProgressLane(
        records: _continueCandidates(records?[4] ?? _isoHistory),
        service: isoService,
        output: iso,
        generation: generation,
      );
    }
    if (!mounted || generation != _progressGeneration) return;
    setState(() {
      onLoaded?.call();
      _videoContinue = video;
      _audioContinue = audio;
      _isoContinue = iso;
      _loadingContinue = false;
    });
  }

  Future<void> _loadIsoProgressLane({
    required List<MediaLibraryRecord> records,
    required IsoLibraryProgressReader service,
    required Map<String, IsoLibraryProgress> output,
    required int generation,
  }) async {
    const batchSize = 8;
    final limit = widget.config.normalized.maxContinuePerLane;
    for (var start = 0; start < records.length; start += batchSize) {
      if (!mounted || generation != _progressGeneration) return;
      if (output.length >= limit) return;
      final end = (start + batchSize).clamp(0, records.length).toInt();
      final batch = records.sublist(start, end);
      final results = await Future.wait(
        batch.map((record) => _readIsoProgress(record, service)),
      );
      for (var index = 0; index < batch.length; index++) {
        if (output.length >= limit) return;
        final progress = results[index];
        if (progress != null) output[batch[index].recordKey] = progress;
      }
    }
  }

  Future<IsoLibraryProgress?> _readIsoProgress(
    MediaLibraryRecord record,
    IsoLibraryProgressReader service,
  ) async {
    if (record.item.playbackMode == PlaybackMode.webdavHdmvMenu) return null;
    final url = _progressUrlFor(record);
    if (url == null) return null;
    try {
      final reader = record.item.sourceId.startsWith('local:')
          ? widget.localIsoProgressService ?? service
          : service;
      return await reader.getLibraryProgress(
        profileId: record.item.sourceId,
        resolvedUrl: url,
        playbackMode: record.item.playbackMode,
      );
    } catch (_) {
      // 单个 ISO 续播状态读取失败只隐藏该条目。
      return null;
    }
  }

  Future<void> _loadProgressLane({
    required List<MediaLibraryRecord> records,
    required PlaybackProgressReader service,
    required bool useTemporaryCheckpoint,
    required Map<String, PlaybackProgress> output,
    required int generation,
    Set<String> skipRecordKeys = const {},
  }) async {
    const batchSize = 8;
    final limit = widget.config.normalized.maxContinuePerLane;
    for (var start = 0; start < records.length; start += batchSize) {
      if (!mounted || generation != _progressGeneration) return;
      if (output.length >= limit) return;
      final end = (start + batchSize).clamp(0, records.length).toInt();
      final batch = records.sublist(start, end);
      final results = await Future.wait(
        batch.map((record) async {
          if (output.containsKey(record.recordKey) ||
              skipRecordKeys.contains(record.recordKey)) {
            return null;
          }
          return _readProgress(
            record,
            service: service,
            useTemporaryCheckpoint: useTemporaryCheckpoint,
          );
        }),
      );
      for (var index = 0; index < batch.length; index++) {
        if (output.length >= limit) return;
        final progress = results[index];
        if (progress != null) output[batch[index].recordKey] = progress;
      }
    }
  }

  List<MediaLibraryRecord> _continueCandidates(
    List<MediaLibraryRecord> records,
  ) => records.where((record) => !record.continueDismissed).toList();

  void _trimProgressLane(
    Map<String, PlaybackProgress> output,
    List<MediaLibraryRecord> records,
    int limit,
  ) {
    if (output.length <= limit) return;
    final retained = records
        .map((record) => record.recordKey)
        .where(output.containsKey)
        .take(limit)
        .toSet();
    output.removeWhere((key, _) => !retained.contains(key));
  }

  Future<Set<String>> _refreshProgressLane({
    required List<MediaLibraryRecord> records,
    required PlaybackProgressReader service,
    required bool useTemporaryCheckpoint,
    required Map<String, PlaybackProgress> output,
    required Set<String> urls,
    required int generation,
  }) async {
    final refreshedKeys = <String>{};
    if (urls.isEmpty) return refreshedKeys;
    final recordsByUrl = <String, List<MediaLibraryRecord>>{};
    for (final record in records) {
      if (!mounted || generation != _progressGeneration) {
        return refreshedKeys;
      }
      final url = _progressUrlFor(record);
      if (url == null || !urls.contains(url)) continue;
      recordsByUrl
          .putIfAbsent(
            '${record.item.sourceId}\u0000$url\u0000${_canFilterCompletedProgress(record)}',
            () => [],
          )
          .add(record);
    }
    for (final entry in recordsByUrl.entries) {
      if (!mounted || generation != _progressGeneration) {
        return refreshedKeys;
      }
      final matchingRecords = entry.value;
      for (final record in matchingRecords) {
        refreshedKeys.add(record.recordKey);
        output.remove(record.recordKey);
      }
      final progress = await _readProgress(
        matchingRecords.first,
        service: service,
        useTemporaryCheckpoint: useTemporaryCheckpoint,
      );
      if (progress != null) {
        for (final record in matchingRecords) {
          output[record.recordKey] = progress;
        }
      }
    }
    return refreshedKeys;
  }

  /// 无列表信息的旧记录沿用单项完成过滤。
  bool _canFilterCompletedProgress(MediaLibraryRecord record) =>
      record.item.kind == MediaLibraryKind.audio ||
      record.playlistIndex == null ||
      record.playlistCount == null ||
      record.playlistIndex == record.playlistCount! - 1;

  Future<PlaybackProgress?> _readProgress(
    MediaLibraryRecord record, {
    required PlaybackProgressReader service,
    required bool useTemporaryCheckpoint,
  }) async {
    final canFilterCompleted = _canFilterCompletedProgress(record);
    if (record.item.kind == MediaLibraryKind.strm) {
      final positionMs = record.strmPositionMs;
      if (positionMs == null || positionMs < 0) return null;
      final progress = PlaybackProgress(
        url: record.item.targetPath,
        positionMs: positionMs,
        durationMs: record.strmDurationMs,
      );
      return canFilterCompleted && progress.hasReachedFraction()
          ? null
          : progress;
    }
    final url = _progressUrlFor(record);
    if (url == null) return null;
    try {
      final progress = useTemporaryCheckpoint
          ? await service.getResumeProgress(
              url,
              profileId: record.item.sourceId,
            )
          : await service.getProgress(url, profileId: record.item.sourceId);
      if (progress == null ||
          progress.positionMs < 0 ||
          (progress.positionMs == 0 &&
              record.item.kind == MediaLibraryKind.audio) ||
          (canFilterCompleted &&
              progress.positionMs > 0 &&
              (record.item.kind == MediaLibraryKind.audio
                  ? progress.isFinishedNearEnd()
                  : progress.hasReachedFraction()))) {
        return null;
      }
      return progress;
    } catch (_) {
      // 单条进度读取失败只隐藏该继续播放项。
      return null;
    }
  }

  String? _progressUrlFor(MediaLibraryRecord record) {
    if (record.item.kind == MediaLibraryKind.strm) return null;
    final direct = widget.resolveDirectTarget?.call(record.item);
    if (direct != null) return direct;
    if (record.item.sourceId != widget.sourceId) return null;
    final file = _cachedFileFor(record.item);
    // STRM 的真实媒体地址需要联网解析，媒体中心不在后台读取指针文件。
    if (file == null) return null;
    return stripUserInfo(widget.resolveUrl(file.href));
  }

  WebDavFile? _cachedFileFor(MediaLibraryItem item) {
    final parentPath = normalizeLibraryPath(item.parentPath);
    for (final snapshot in _snapshots) {
      if (normalizeLibraryPath(snapshot.path) != parentPath) continue;
      for (final file in snapshot.entries) {
        if (item.matches(file)) return file;
      }
    }
    return null;
  }

  void _scheduleSearch(String query) {
    _searchDebounce?.cancel();
    final generation = ++_searchGeneration;
    if (query.trim().isEmpty) {
      _runSearch(query);
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 180), () {
      if (!mounted || generation != _searchGeneration) return;
      _runSearch(query);
    });
  }

  void _runSearch(String query) {
    if (!mounted) return;
    if (widget.filmCenter) {
      setState(() {});
      return;
    }
    final results = [
      for (final source in _sourceIds)
        ...searchVisitedMedia(
          sourceId: source,
          query: query,
          snapshots: widget.directoryCache.visitedDirectories(source),
        ),
    ].take(200).toList();
    setState(() => _searchResults = results);
  }

  Future<void> _toggleFavorite(MediaLibraryItem item) async {
    try {
      await widget.store.toggleFavorite(item);
      await _loadAll();
    } catch (error) {
      _showError('保存收藏失败：$error');
    }
  }

  Future<void> _removePlayback(MediaLibraryRecord record) async {
    try {
      await widget.store.removePlaybackRecord(record);
      if (record.item.kind.isVideoLane) {
        widget.onVideoPlaybackRecordsChanged?.call();
      }
      await _loadAll();
    } catch (error) {
      _showError('删除最近播放失败：$error');
    }
  }

  Future<void> _removeRecentDirectory(MediaLibraryItem item) async {
    try {
      await widget.store.removeRecentDirectory(item);
      await _loadAll();
    } catch (error) {
      _showError('删除最近目录失败：$error');
    }
  }

  Future<void> _clearPlayback(_MediaLane lane) async {
    final title = switch (lane) {
      _MediaLane.video => '清空视频最近播放？',
      _MediaLane.audio => '清空音频最近播放？',
      _MediaLane.iso => '清空 ISO 最近播放？',
    };
    if (!await _confirmClear(title)) {
      return;
    }
    try {
      for (final source in _sourceIds) {
        await widget.store.clearPlaybackHistory(
          source,
          audio: lane == _MediaLane.audio,
          iso: lane == _MediaLane.iso,
        );
      }
      if (lane == _MediaLane.video) {
        widget.onVideoPlaybackRecordsChanged?.call();
      }
      await _loadAll();
    } catch (error) {
      _showError('清空最近播放失败：$error');
    }
  }

  Future<void> _clearRecentDirectories() async {
    if (!await _confirmClear('清空最近目录？')) return;
    try {
      for (final source in _sourceIds) {
        await widget.store.clearRecentDirectories(source);
      }
      await _loadAll();
    } catch (error) {
      _showError('清空最近目录失败：$error');
    }
  }

  Future<bool> _confirmClear(String title) async =>
      await showGlassDialog<bool>(
        context: context,
        builder: (dialogContext) => SPDialog(
          title: AppText(title),
          content: const AppText('此操作只删除媒体中心的 UI 记录，不删除播放进度。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const AppText('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const AppText('清空'),
            ),
          ],
        ),
      ) ??
      false;

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SPNotice(content: AppText(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.filmCatalog != null && !widget.filmCenter) {
      return IgnorePointer(
        ignoring: _sourcePending,
        child: ExcludeFocus(
          excluding: _sourcePending,
          child: _buildFilmContinue(),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final searchInToolbar = constraints.maxWidth >= 900;
        return DefaultTabController(
          length: widget.filmCenter ? 3 : 4,
          child: Scaffold(
            appBar: AppBar(
              toolbarHeight: 48,
              automaticallyImplyLeading: widget.headerAction == null,
              title: Row(
                children: [
                  const Expanded(
                    child: AppText(
                      '媒体中心',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.headerAction != null) ...[
                    widget.headerAction!,
                    const SizedBox(width: 12),
                  ],
                  if (searchInToolbar) ...[
                    SizedBox(
                      width: 340,
                      child: _buildSearchField(inToolbar: true),
                    ),
                    if (widget.sourceFilter != null) const SizedBox(width: 12),
                  ],
                  if (widget.sourceFilter != null) widget.sourceFilter!,
                ],
              ),
              bottom: TabBar(
                dividerColor: Colors.transparent,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                labelPadding: const EdgeInsets.symmetric(horizontal: 14),
                tabs: [
                  _compactNavigationTab(SPIcons.favorite, '收藏'),
                  _compactNavigationTab(SPIcons.play, '继续播放'),
                  _compactNavigationTab(SPIcons.history, '最近播放'),
                  if (!widget.filmCenter)
                    _compactNavigationTab(SPIcons.folderOpen, '目录'),
                ],
              ),
            ),
            body: Column(
              children: [
                if (!searchInToolbar) _buildSearchField(),
                Expanded(child: _buildContent()),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSearchField({bool inToolbar = false}) => Padding(
    padding: inToolbar
        ? EdgeInsets.zero
        : const EdgeInsets.fromLTRB(20, 16, 20, 12),
    child: TextField(
      key: const Key('media-library-global-search'),
      controller: _searchController,
      contextMenuBuilder: buildClipboardHistoryMenu,
      onChanged: _scheduleSearch,
      decoration: InputDecoration(
        isDense: inToolbar,
        contentPadding: inToolbar
            ? const EdgeInsets.symmetric(horizontal: 12, vertical: 8)
            : null,
        hintText: context.l10n.text(widget.filmCenter ? '搜索库内作品' : '搜索已访问过的目录'),
        prefixIcon: const Icon(SPIcons.globe),
        suffixIcon: _searchController.text.isEmpty
            ? null
            : IconButton(
                tooltip: context.l10n.text('清除搜索'),
                onPressed: () {
                  _searchController.clear();
                  _runSearch('');
                  setState(() {});
                },
                icon: const Icon(SPIcons.close),
              ),
      ),
    ),
  );

  Widget _buildContent() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _EmptyState(
        icon: SPIcons.error,
        message: _error!,
        action: OutlinedButton.icon(
          onPressed: _loadAll,
          icon: const Icon(SPIcons.refresh),
          label: const AppText('重试'),
        ),
      );
    }
    if (widget.filmCenter) {
      return TabBarView(
        children: [
          FilmFavoritesWall(
            loadCatalog: () async => widget.filmCatalog!,
            onOpenItem: (item) async => _selectItem(item),
            sourceIds: _sourceIds,
            query: _searchController.text.trim(),
          ),
          _buildFilmContinue(center: true),
          _buildFilmRecent(),
        ],
      );
    }
    if (_searchController.text.trim().isNotEmpty) return _buildSearchResults();
    return TabBarView(
      children: [
        _buildFavorites(),
        _buildContinue(),
        _buildRecentPlayback(),
        _buildDirectories(),
      ],
    );
  }

  Widget _buildFavorites() {
    final selector = SegmentedButton<_FavoriteLane>(
      key: const Key('favorite-media-lane'),
      segments: const [
        ButtonSegment(
          value: _FavoriteLane.media,
          label: AppText('媒体'),
          icon: Icon(SPIcons.library),
        ),
        ButtonSegment(
          value: _FavoriteLane.video,
          label: AppText('视频'),
          icon: Icon(SPIcons.video),
        ),
        ButtonSegment(
          value: _FavoriteLane.audio,
          label: AppText('音频'),
          icon: Icon(SPIcons.music),
        ),
        ButtonSegment(
          value: _FavoriteLane.iso,
          label: AppText('ISO'),
          icon: Icon(SPIcons.disc),
        ),
      ],
      selected: {_favoriteLane},
      onSelectionChanged: (value) =>
          setState(() => _favoriteLane = value.single),
    );
    if (_favoriteLane == _FavoriteLane.media &&
        widget.loadFilmCatalog != null) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Align(alignment: Alignment.centerLeft, child: selector),
          ),
          Expanded(
            child: widget.loadFilmCatalog == null
                ? const Center(child: AppText('还没有收藏媒体'))
                : FilmFavoritesWall(
                    loadCatalog: widget.loadFilmCatalog!,
                    onOpenItem: (item) async => _selectItem(item),
                    sourceIds: _sourceIds,
                  ),
          ),
        ],
      );
    }
    final records = _favorites.where((record) {
      return switch (_favoriteLane) {
        _FavoriteLane.media => record.item.kind != MediaLibraryKind.directory,
        _FavoriteLane.video => record.item.kind.isVideoLane,
        _FavoriteLane.audio => record.item.kind == MediaLibraryKind.audio,
        _FavoriteLane.iso => record.item.kind == MediaLibraryKind.iso,
      };
    }).toList();
    return _buildLanePage(
      empty: records.isEmpty,
      selector: selector,
      child: _recordList(
        records,
        emptyMessage: switch (_favoriteLane) {
          _FavoriteLane.media => '还没有收藏媒体',
          _FavoriteLane.video => '还没有收藏视频',
          _FavoriteLane.audio => '还没有收藏音频',
          _FavoriteLane.iso => '还没有收藏 ISO',
        },
        trailing: (record) => IconButton(
          tooltip: context.l10n.text('取消收藏'),
          onPressed: () => _toggleFavorite(record.item),
          icon: const Icon(SPIcons.favoriteFill),
        ),
      ),
    );
  }

  Widget _buildFilmContinue({bool center = false}) {
    final records = [
      ..._continueCandidates(
        _videoHistory,
      ).where((r) => _videoContinue.containsKey(r.recordKey)),
      ..._continueCandidates(_isoHistory).where(
        (r) =>
            _isoContinue.containsKey(r.recordKey) ||
            r.item.playbackMode == PlaybackMode.webdavHdmvMenu,
      ),
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final counts = <String, int>{};
    records.removeWhere((record) {
      final count = counts.update(
        record.item.sourceId,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
      return count > widget.config.normalized.maxContinuePerLane;
    });
    if (center) records.removeWhere((r) => !_matchesFilmQuery(r));
    Widget card(int i) {
      final record = records[i];
      final video = _videoContinue[record.recordKey];
      final iso = _isoContinue[record.recordKey];
      return FilmContinueCard(
        key: ValueKey(record.recordKey),
        catalog: widget.filmCatalog!,
        poster: center,
        record: record,
        positionMs: video?.positionMs ?? iso?.position.inMilliseconds,
        durationMs: video?.durationMs ?? iso?.duration?.inMilliseconds,
        onMenu: widget.onContinueMenu == null
            ? null
            : (position) => widget.onContinueMenu!(record, position),
        onTap: () => widget.onContinueSelected != null
            ? widget.onContinueSelected!(record)
            : _selectItem(record.item),
      );
    }

    if (widget.filmContinueAll || center) {
      final grid = DirectoryScrollView(
        builder: (scrollController) => GridView.builder(
          controller: scrollController,
          padding: const EdgeInsets.all(20),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: center ? 220 : 340,
            mainAxisExtent: center ? 400 : 220,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
          ),
          itemCount: records.length,
          itemBuilder: (_, i) => card(i),
        ),
      );
      if (center) return grid;
      final catalog = widget.filmCatalog!;
      return AnimatedBuilder(
        animation: catalog,
        builder: (context, _) => Stack(
          children: [
            Positioned.fill(
              child: ExcludeSemantics(
                child: IgnorePointer(
                  child: FilmLibraryBackground(file: catalog.backgroundFile),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.only(left: widget.sidebarInset),
              child: Scaffold(
                backgroundColor: Colors.transparent,
                appBar: AppBar(
                  toolbarHeight: 48,
                  backgroundColor: Colors.transparent,
                  shape: const Border(),
                  automaticallyImplyLeading: false,
                  title: const AppText('继续播放'),
                ),
                body: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: SizedBox(
                        height: 48,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const AppText('主页'),
                          ),
                        ),
                      ),
                    ),
                    Expanded(child: grid),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    return FilmShelf(
      title: '继续播放',
      count: records.length,
      height: FilmContinueCard.landscapeHeight,
      itemWidth: FilmContinueCard.landscapeWidth,
      onShowAll: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MediaLibraryPage(
            sourceId: widget.sourceId,
            sourceIds: widget.sourceIds,
            sourceNames: widget.sourceNames,
            store: widget.store,
            config: widget.config,
            directoryCache: widget.directoryCache,
            videoProgressService: widget.videoProgressService,
            audioProgressService: widget.audioProgressService,
            isoProgressService: widget.isoProgressService,
            localIsoProgressService: widget.localIsoProgressService,
            resolveUrl: widget.resolveUrl,
            resolveDirectTarget: widget.resolveDirectTarget,
            onVideoPlaybackRecordsChanged: widget.onVideoPlaybackRecordsChanged,
            onItemSelected: widget.onItemSelected,
            filmCatalog: widget.filmCatalog,
            onContinueSelected: widget.onContinueSelected,
            onContinueMenu: widget.onContinueMenu,
            filmContinueAll: true,
            initialContinue: FilmContinueSnapshot(
              videos: _videoHistory,
              discs: _isoHistory,
              videoProgress: _videoContinue,
              discProgress: _isoContinue,
            ),
            sidebarInset: widget.sidebarInset,
          ),
        ),
      ),
      builder: (_, i) => card(i),
    );
  }

  bool _matchesFilmQuery(MediaLibraryRecord record) =>
      (_filmTitles[record.recordKey] ?? record.item.name)
          .toLowerCase()
          .contains(_searchController.text.trim().toLowerCase());

  Widget _buildFilmRecent() {
    final records =
        [..._videoHistory, ..._isoHistory].where(_matchesFilmQuery).toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return DirectoryScrollView(
      builder: (scrollController) => GridView.builder(
        controller: scrollController,
        padding: const EdgeInsets.all(20),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 220,
          mainAxisExtent: 400,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
        ),
        itemCount: records.length,
        itemBuilder: (_, i) => FilmContinueCard(
          catalog: widget.filmCatalog!,
          record: records[i],
          poster: true,
          onTap: () => _selectItem(records[i].item),
          onMenu: (position) =>
              widget.onContinueMenu?.call(records[i], position),
        ),
      ),
    );
  }

  Widget _buildContinue() {
    final source = switch (_continueLane) {
      _MediaLane.video => _videoHistory,
      _MediaLane.audio => _audioHistory,
      _MediaLane.iso => _isoHistory,
    };
    final progressKeys = (switch (_continueLane) {
      _MediaLane.video => _videoContinue.keys,
      _MediaLane.audio => _audioContinue.keys,
      _MediaLane.iso => _isoContinue.keys,
    }).toSet();
    final records = _continueCandidates(source)
        .where(
          (record) =>
              progressKeys.contains(record.recordKey) ||
              (_continueLane == _MediaLane.iso &&
                  record.item.playbackMode == PlaybackMode.webdavHdmvMenu),
        )
        .take(widget.config.normalized.maxContinuePerLane)
        .toList();
    return _buildLanePage(
      empty: records.isEmpty && !_loadingContinue,
      selector: _mediaLaneSelector(
        key: const Key('continue-media-lane'),
        selected: _continueLane,
        onChanged: (value) => setState(() => _continueLane = value),
      ),
      child: _loadingContinue
          ? const Center(child: CircularProgressIndicator())
          : _recordList(
              records,
              emptyMessage: switch (_continueLane) {
                _MediaLane.video => '没有可继续播放的视频',
                _MediaLane.audio => '没有可继续播放的音频',
                _MediaLane.iso => '没有可继续播放的 ISO',
              },
              subtitle: (record) {
                if (_continueLane == _MediaLane.iso) {
                  if (record.item.playbackMode == PlaybackMode.webdavHdmvMenu) {
                    return record.item.parentPath;
                  }
                  final value = _isoContinue[record.recordKey]!;
                  return context.l10n.playbackDetails(
                    record.item.parentPath,
                    episodeNumber: value.episodeNumber,
                    episodeCount: value.episodeCount,
                    positionMs: value.position.inMilliseconds,
                  );
                }
                final value = _continueLane == _MediaLane.audio
                    ? _audioContinue[record.recordKey]!
                    : _videoContinue[record.recordKey]!;
                return context.l10n.playbackDetails(
                  record.item.parentPath,
                  episodeNumber: record.playlistIndex == null
                      ? null
                      : record.playlistIndex! + 1,
                  episodeCount: record.playlistCount,
                  positionMs: value.positionMs,
                  audio: _continueLane == _MediaLane.audio,
                );
              },
              trailing: (record) => IconButton(
                tooltip: context.l10n.text('从历史中移除'),
                onPressed: () => _removePlayback(record),
                icon: const Icon(SPIcons.close),
              ),
            ),
    );
  }

  Widget _buildRecentPlayback() {
    final records = switch (_recentLane) {
      _MediaLane.video => _videoHistory,
      _MediaLane.audio => _audioHistory,
      _MediaLane.iso => _isoHistory,
    };
    return _buildLanePage(
      empty: records.isEmpty,
      selector: Row(
        children: [
          Expanded(
            child: _mediaLaneSelector(
              key: const Key('recent-media-lane'),
              selected: _recentLane,
              onChanged: (value) => setState(() => _recentLane = value),
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            tooltip: context.l10n.text('清空当前分栏'),
            onPressed: records.isEmpty
                ? null
                : () => _clearPlayback(_recentLane),
            icon: const Icon(SPIcons.delete),
          ),
        ],
      ),
      child: _recordList(
        records,
        emptyMessage: switch (_recentLane) {
          _MediaLane.video => '还没有视频播放记录',
          _MediaLane.audio => '还没有音频播放记录',
          _MediaLane.iso => '还没有 ISO 播放记录',
        },
        trailing: (record) => IconButton(
          tooltip: context.l10n.text('从历史中移除'),
          onPressed: () => _removePlayback(record),
          icon: const Icon(SPIcons.close),
        ),
      ),
    );
  }

  Widget _buildDirectories() {
    final records = _directoryLane == _DirectoryLane.favorites
        ? _favorites
              .where((record) => record.item.kind == MediaLibraryKind.directory)
              .toList()
        : _recentDirectories;
    return _buildLanePage(
      empty: records.isEmpty,
      selector: Row(
        children: [
          Expanded(
            child: SegmentedButton<_DirectoryLane>(
              key: const Key('directory-media-lane'),
              segments: const [
                ButtonSegment(
                  value: _DirectoryLane.favorites,
                  icon: Icon(SPIcons.favorite),
                  label: AppText('收藏目录'),
                ),
                ButtonSegment(
                  value: _DirectoryLane.recent,
                  icon: Icon(SPIcons.history),
                  label: AppText('最近目录'),
                ),
              ],
              selected: {_directoryLane},
              onSelectionChanged: (value) =>
                  setState(() => _directoryLane = value.single),
            ),
          ),
          if (_directoryLane == _DirectoryLane.recent) ...[
            const SizedBox(width: 12),
            IconButton(
              tooltip: context.l10n.text('清空最近目录'),
              onPressed: records.isEmpty ? null : _clearRecentDirectories,
              icon: const Icon(SPIcons.delete),
            ),
          ],
        ],
      ),
      child: _recordList(
        records,
        emptyMessage: _directoryLane == _DirectoryLane.favorites
            ? '还没有收藏目录'
            : '还没有最近目录',
        trailing: (record) => IconButton(
          tooltip: context.l10n.text(
            _directoryLane == _DirectoryLane.favorites ? '取消收藏' : '从最近目录中移除',
          ),
          onPressed: () => _directoryLane == _DirectoryLane.favorites
              ? _toggleFavorite(record.item)
              : _removeRecentDirectory(record.item),
          icon: Icon(
            _directoryLane == _DirectoryLane.favorites
                ? SPIcons.favoriteFill
                : SPIcons.close,
          ),
        ),
      ),
    );
  }

  Widget _buildSearchResults() {
    final directories = _searchResults
        .where((result) => result.item.kind == MediaLibraryKind.directory)
        .toList();
    final videos = _searchResults
        .where((result) => result.item.kind.isVideoLane)
        .toList();
    final audio = _searchResults
        .where((result) => result.item.kind == MediaLibraryKind.audio)
        .toList();
    final iso = _searchResults
        .where((result) => result.item.kind == MediaLibraryKind.iso)
        .toList();
    if (_searchResults.isEmpty) {
      return const _EmptyState(icon: SPIcons.search, message: '已访问目录中没有匹配项');
    }
    return GlassSurface(
      level: GlassSurfaceLevel.content,
      automaticBorder: false,
      child: DirectoryScrollView(
        builder: (scrollController) => ListView(
          controller: scrollController,
          key: const Key('media-library-search-results'),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            if (directories.isNotEmpty) ...[
              const _SectionHeader(label: '目录'),
              ...directories.map(_searchTile),
            ],
            if (videos.isNotEmpty) ...[
              const _SectionHeader(label: '视频'),
              ...videos.map(_searchTile),
            ],
            if (audio.isNotEmpty) ...[
              const _SectionHeader(label: '音频'),
              ...audio.map(_searchTile),
            ],
            if (iso.isNotEmpty) ...[
              const _SectionHeader(label: 'ISO'),
              ...iso.map(_searchTile),
            ],
          ],
        ),
      ),
    );
  }

  Widget _searchTile(MediaLibrarySearchResult result) => ListTile(
    leading: Icon(_iconFor(result.item.kind)),
    title: AppText(
      result.item.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    subtitle: AppText(
      result.item.parentPath.isEmpty ? '根目录' : result.item.parentPath,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: const Icon(SPIcons.chevronRight),
    onTap: () => _selectItem(result.item),
  );

  Widget _buildLanePage({
    required Widget selector,
    required Widget child,
    required bool empty,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
    child: Column(
      children: [
        Align(alignment: Alignment.centerLeft, child: selector),
        const SizedBox(height: 12),
        Expanded(
          child: empty
              ? child
              : GlassSurface(
                  level: GlassSurfaceLevel.raised,
                  borderRadius: BorderRadius.circular(14),
                  clipBehavior: Clip.antiAlias,
                  automaticBorder: true,
                  child: child,
                ),
        ),
      ],
    ),
  );

  Widget _mediaLaneSelector({
    required Key key,
    required _MediaLane selected,
    required ValueChanged<_MediaLane> onChanged,
  }) => SegmentedButton<_MediaLane>(
    key: key,
    segments: const [
      ButtonSegment(
        value: _MediaLane.video,
        icon: Icon(SPIcons.video),
        label: AppText('视频'),
      ),
      ButtonSegment(
        value: _MediaLane.audio,
        icon: Icon(SPIcons.music),
        label: AppText('音频'),
      ),
      ButtonSegment(
        value: _MediaLane.iso,
        icon: Icon(SPIcons.disc),
        label: AppText('ISO'),
      ),
    ],
    selected: {selected},
    onSelectionChanged: (value) => onChanged(value.single),
  );

  Widget _recordList(
    List<MediaLibraryRecord> records, {
    required String emptyMessage,
    String Function(MediaLibraryRecord)? subtitle,
    Widget Function(MediaLibraryRecord)? trailing,
  }) {
    if (records.isEmpty) {
      return _EmptyState(icon: SPIcons.library, message: emptyMessage);
    }
    return DirectoryScrollView(
      builder: (scrollController) => ListView.separated(
        controller: scrollController,
        itemCount: records.length,
        separatorBuilder: (_, _) => const Divider(),
        itemBuilder: (context, index) {
          final record = records[index];
          return ListTile(
            leading: Icon(_iconFor(record.item.kind)),
            title: AppText(
              record.item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: AppText(
              '${_sourceIds.length > 1 ? '${widget.sourceNames[record.item.sourceId] ?? record.item.sourceId} · ' : ''}'
              '${subtitle?.call(record) ?? '${record.item.parentPath.isEmpty ? context.l10n.text('根目录') : record.item.parentPath}  ·  ${_formatDate(record.updatedAt)}'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: trailing?.call(record),
            onTap: () => _selectItem(record.item),
          );
        },
      ),
    );
  }

  static IconData _iconFor(MediaLibraryKind kind) => switch (kind) {
    MediaLibraryKind.directory => SPIcons.folder,
    MediaLibraryKind.audio => SPIcons.music,
    MediaLibraryKind.video || MediaLibraryKind.strm => SPIcons.video,
    MediaLibraryKind.iso => SPIcons.disc,
  };

  static String _formatDate(DateTime date) {
    final local = date.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }
}

Tab _compactNavigationTab(IconData icon, String label) => Tab(
  height: 40,
  child: FittedBox(
    fit: BoxFit.scaleDown,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 8),
        AppText(label),
      ],
    ),
  ),
);

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
    child: AppText(
      label,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.message, this.action});

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 36,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          AppText(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    ),
  );
}
