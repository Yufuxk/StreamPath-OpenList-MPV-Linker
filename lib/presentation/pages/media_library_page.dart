import 'dart:async';

import 'package:flutter/material.dart';

import '../localization/app_localizations.dart';
import '../localization/app_text.dart';

import '../../core/utils/url_utils.dart';
import '../../data/local/directory_cache.dart';
import '../../data/local/media_library_store.dart';
import '../../data/local/playback_progress_db.dart';
import '../../data/models/media_library_item.dart';
import '../../data/models/media_library_config.dart';
import '../../data/models/playback_progress.dart';
import '../../data/models/web_dav_file.dart';
import '../../domain/services/media_library_search.dart';
import '../theme/glass_tokens.dart';
import '../widgets/clipboard_history_menu.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/glass_surface.dart';

enum _MediaLane { video, audio }

enum _DirectoryLane { favorites, recent }

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
    required this.resolveUrl,
  });

  final String sourceId;
  final MediaLibraryStore store;
  final MediaLibraryConfig config;
  final DirectoryCache directoryCache;
  final PlaybackProgressReader videoProgressService;
  final PlaybackProgressReader? audioProgressService;
  final String Function(String href) resolveUrl;

  @override
  State<MediaLibraryPage> createState() => _MediaLibraryPageState();
}

class _MediaLibraryPageState extends State<MediaLibraryPage> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  Timer? _libraryRefreshDebounce;
  Timer? _progressRefreshDebounce;
  Future<void> _progressOperationTail = Future<void>.value();
  final Set<String> _pendingVideoProgressUrls = {};
  final Set<String> _pendingAudioProgressUrls = {};
  bool _refreshAllVideoProgress = false;
  bool _refreshAllAudioProgress = false;
  int _searchGeneration = 0;
  int _libraryGeneration = 0;
  int _progressGeneration = 0;
  bool _loading = true;
  bool _loadingContinue = false;
  String? _error;
  _MediaLane _favoriteLane = _MediaLane.video;
  _MediaLane _continueLane = _MediaLane.video;
  _MediaLane _recentLane = _MediaLane.video;
  _DirectoryLane _directoryLane = _DirectoryLane.favorites;
  List<MediaLibraryRecord> _favorites = const [];
  List<MediaLibraryRecord> _recentDirectories = const [];
  List<MediaLibraryRecord> _videoHistory = const [];
  List<MediaLibraryRecord> _audioHistory = const [];
  List<VisitedDirectorySnapshot> _snapshots = const [];
  List<MediaLibrarySearchResult> _searchResults = const [];
  Map<String, PlaybackProgress> _videoContinue = const {};
  Map<String, PlaybackProgress> _audioContinue = const {};

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onLibraryChanged);
    widget.videoProgressService.addListener(_onVideoProgressChanged);
    widget.audioProgressService?.addListener(_onAudioProgressChanged);
    _loadAll();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _libraryRefreshDebounce?.cancel();
    _progressRefreshDebounce?.cancel();
    widget.store.removeListener(_onLibraryChanged);
    widget.videoProgressService.removeListener(_onVideoProgressChanged);
    widget.audioProgressService?.removeListener(_onAudioProgressChanged);
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadAll({bool showLoading = true}) async {
    _libraryRefreshDebounce?.cancel();
    final libraryGeneration = ++_libraryGeneration;
    if (mounted && showLoading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final records = await Future.wait<List<MediaLibraryRecord>>([
        widget.store.favorites(widget.sourceId),
        widget.store.recentDirectories(widget.sourceId),
        widget.store.playbackHistory(widget.sourceId, audio: false),
        widget.store.playbackHistory(widget.sourceId, audio: true),
      ]);
      if (!mounted || libraryGeneration != _libraryGeneration) return;
      setState(() {
        _favorites = records[0];
        _recentDirectories = records[1];
        _videoHistory = records[2];
        _audioHistory = records[3];
        _snapshots = widget.directoryCache.visitedDirectories(widget.sourceId);
        _loading = false;
        _error = null;
      });
      _runSearch(_searchController.text);
      await _enqueueProgressOperation(() async {
        final progressGeneration = ++_progressGeneration;
        await _loadContinueProgress(progressGeneration);
      });
    } catch (error) {
      if (!mounted || libraryGeneration != _libraryGeneration) return;
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
    _libraryRefreshDebounce?.cancel();
    _libraryRefreshDebounce = Timer(const Duration(milliseconds: 100), () {
      unawaited(_loadAll(showLoading: false));
    });
  }

  void _onVideoProgressChanged(PlaybackProgressChange change) =>
      _scheduleProgressRefresh(change, audio: false);

  void _onAudioProgressChanged(PlaybackProgressChange change) =>
      _scheduleProgressRefresh(change, audio: true);

  void _scheduleProgressRefresh(
    PlaybackProgressChange change, {
    required bool audio,
  }) {
    if (!mounted) return;
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

  Future<void> _loadContinueProgress(int generation) async {
    if (!mounted || generation != _progressGeneration) return;
    setState(() => _loadingContinue = true);
    final video = <String, PlaybackProgress>{};
    final audio = <String, PlaybackProgress>{};
    await _loadProgressLane(
      records: _continueCandidates(_videoHistory),
      service: widget.videoProgressService,
      useTemporaryCheckpoint: true,
      output: video,
      generation: generation,
    );
    final audioService = widget.audioProgressService;
    if (audioService != null) {
      await _loadProgressLane(
        records: _continueCandidates(_audioHistory),
        service: audioService,
        useTemporaryCheckpoint: false,
        output: audio,
        generation: generation,
      );
    }
    if (!mounted || generation != _progressGeneration) return;
    setState(() {
      _videoContinue = video;
      _audioContinue = audio;
      _loadingContinue = false;
    });
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
      recordsByUrl.putIfAbsent(url, () => []).add(record);
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

  Future<PlaybackProgress?> _readProgress(
    MediaLibraryRecord record, {
    required PlaybackProgressReader service,
    required bool useTemporaryCheckpoint,
  }) async {
    final url = _progressUrlFor(record);
    if (url == null) return null;
    try {
      final progress = useTemporaryCheckpoint
          ? await service.getResumeProgress(url, profileId: widget.sourceId)
          : await service.getProgress(url, profileId: widget.sourceId);
      if (progress == null ||
          progress.positionMs <= 0 ||
          progress.isFinishedNearEnd()) {
        return null;
      }
      return progress;
    } catch (_) {
      // 单条进度读取失败只隐藏该继续播放项。
      return null;
    }
  }

  String? _progressUrlFor(MediaLibraryRecord record) {
    final file = _cachedFileFor(record.item);
    // STRM 的真实媒体地址需要联网解析，媒体中心不在后台读取指针文件。
    if (file == null || record.item.kind == MediaLibraryKind.strm) return null;
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
    final results = searchVisitedMedia(
      sourceId: widget.sourceId,
      query: query,
      snapshots: _snapshots,
    );
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

  Future<void> _clearPlayback(bool audio) async {
    if (!await _confirmClear(audio ? '清空音频最近播放？' : '清空视频最近播放？')) {
      return;
    }
    try {
      await widget.store.clearPlaybackHistory(widget.sourceId, audio: audio);
      await _loadAll();
    } catch (error) {
      _showError('清空最近播放失败：$error');
    }
  }

  Future<void> _clearRecentDirectories() async {
    if (!await _confirmClear('清空最近目录？')) return;
    try {
      await widget.store.clearRecentDirectories(widget.sourceId);
      await _loadAll();
    } catch (error) {
      _showError('清空最近目录失败：$error');
    }
  }

  Future<bool> _confirmClear(String title) async =>
      await showGlassDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
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
      ..showSnackBar(SnackBar(content: AppText(message)));
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 48,
          title: const AppText('媒体中心'),
          bottom: TabBar(
            labelPadding: const EdgeInsets.symmetric(horizontal: 4),
            tabs: [
              _compactNavigationTab(Icons.star_outline, '收藏'),
              _compactNavigationTab(Icons.play_circle_outline, '继续播放'),
              _compactNavigationTab(Icons.history, '最近播放'),
              _compactNavigationTab(Icons.folder_copy_outlined, '目录'),
            ],
          ),
        ),
        body: Column(
          children: [
            _buildSearchField(),
            Expanded(child: _buildContent()),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchField() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
    child: TextField(
      key: const Key('media-library-global-search'),
      controller: _searchController,
      contextMenuBuilder: buildClipboardHistoryMenu,
      onChanged: _scheduleSearch,
      decoration: InputDecoration(
        hintText: context.l10n.text('搜索已访问过的目录'),
        prefixIcon: const Icon(Icons.travel_explore_outlined),
        suffixIcon: _searchController.text.isEmpty
            ? null
            : IconButton(
                tooltip: context.l10n.text('清除搜索'),
                onPressed: () {
                  _searchController.clear();
                  _runSearch('');
                  setState(() {});
                },
                icon: const Icon(Icons.close),
              ),
      ),
    ),
  );

  Widget _buildContent() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _EmptyState(
        icon: Icons.error_outline,
        message: _error!,
        action: OutlinedButton.icon(
          onPressed: _loadAll,
          icon: const Icon(Icons.refresh),
          label: const AppText('重试'),
        ),
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
    final records = _favorites.where((record) {
      return _favoriteLane == _MediaLane.audio
          ? record.item.kind == MediaLibraryKind.audio
          : record.item.kind.isVideoLane;
    }).toList();
    return _buildLanePage(
      selector: _mediaLaneSelector(
        key: const Key('favorite-media-lane'),
        selected: _favoriteLane,
        onChanged: (value) => setState(() => _favoriteLane = value),
      ),
      child: _recordList(
        records,
        emptyMessage: _favoriteLane == _MediaLane.audio ? '还没有收藏音频' : '还没有收藏视频',
        trailing: (record) => IconButton(
          tooltip: context.l10n.text('取消收藏'),
          onPressed: () => _toggleFavorite(record.item),
          icon: const Icon(Icons.star),
        ),
      ),
    );
  }

  Widget _buildContinue() {
    final audio = _continueLane == _MediaLane.audio;
    final source = audio ? _audioHistory : _videoHistory;
    final progress = audio ? _audioContinue : _videoContinue;
    final records = _continueCandidates(source)
        .where((record) => progress.containsKey(record.recordKey))
        .take(widget.config.normalized.maxContinuePerLane)
        .toList();
    return _buildLanePage(
      selector: _mediaLaneSelector(
        key: const Key('continue-media-lane'),
        selected: _continueLane,
        onChanged: (value) => setState(() => _continueLane = value),
      ),
      child: _loadingContinue
          ? const Center(child: CircularProgressIndicator())
          : _recordList(
              records,
              emptyMessage: audio ? '没有可继续播放的音频' : '没有可继续播放的视频',
              subtitle: (record) {
                final value = progress[record.recordKey]!;
                return context.l10n.format('{path}  ·  已播放 {duration}', {
                  'path': record.item.parentPath,
                  'duration': _formatDuration(value.positionMs),
                });
              },
              trailing: (record) => IconButton(
                tooltip: context.l10n.text('从历史中移除'),
                onPressed: () => _removePlayback(record),
                icon: const Icon(Icons.close),
              ),
            ),
    );
  }

  Widget _buildRecentPlayback() {
    final audio = _recentLane == _MediaLane.audio;
    final records = audio ? _audioHistory : _videoHistory;
    return _buildLanePage(
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
            onPressed: records.isEmpty ? null : () => _clearPlayback(audio),
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      child: _recordList(
        records,
        emptyMessage: audio ? '还没有音频播放记录' : '还没有视频播放记录',
        trailing: (record) => IconButton(
          tooltip: context.l10n.text('从历史中移除'),
          onPressed: () => _removePlayback(record),
          icon: const Icon(Icons.close),
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
      selector: Row(
        children: [
          Expanded(
            child: SegmentedButton<_DirectoryLane>(
              key: const Key('directory-media-lane'),
              segments: const [
                ButtonSegment(
                  value: _DirectoryLane.favorites,
                  icon: Icon(Icons.star_outline),
                  label: AppText('收藏目录'),
                ),
                ButtonSegment(
                  value: _DirectoryLane.recent,
                  icon: Icon(Icons.history),
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
              icon: const Icon(Icons.delete_sweep_outlined),
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
                ? Icons.star
                : Icons.close,
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
    if (_searchResults.isEmpty) {
      return const _EmptyState(icon: Icons.search_off, message: '已访问目录中没有匹配项');
    }
    return GlassSurface(
      level: GlassSurfaceLevel.content,
      automaticBorder: false,
      child: ListView(
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
        ],
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
    trailing: const Icon(Icons.chevron_right),
    onTap: () => Navigator.of(context).pop(result.item),
  );

  Widget _buildLanePage({required Widget selector, required Widget child}) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          children: [
            Align(alignment: Alignment.centerLeft, child: selector),
            const SizedBox(height: 12),
            Expanded(
              child: GlassSurface(
                level: GlassSurfaceLevel.content,
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
        icon: Icon(Icons.movie_outlined),
        label: AppText('视频'),
      ),
      ButtonSegment(
        value: _MediaLane.audio,
        icon: Icon(Icons.audiotrack_outlined),
        label: AppText('音频'),
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
      return _EmptyState(icon: Icons.inbox_outlined, message: emptyMessage);
    }
    return ListView.separated(
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
            subtitle?.call(record) ??
                '${record.item.parentPath.isEmpty ? context.l10n.text('根目录') : record.item.parentPath}  ·  ${_formatDate(record.updatedAt)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: trailing?.call(record),
          onTap: () => Navigator.of(context).pop(record.item),
        );
      },
    );
  }

  static IconData _iconFor(MediaLibraryKind kind) => switch (kind) {
    MediaLibraryKind.directory => Icons.folder_outlined,
    MediaLibraryKind.audio => Icons.audiotrack_outlined,
    MediaLibraryKind.video || MediaLibraryKind.strm => Icons.movie_outlined,
  };

  static String _formatDate(DateTime date) {
    final local = date.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  static String _formatDuration(int milliseconds) {
    final totalSeconds = milliseconds ~/ 1000;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    String two(int value) => value.toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:${two(minutes)}:${two(seconds)}'
        : '${two(minutes)}:${two(seconds)}';
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
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w700,
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
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          AppText(message, textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    ),
  );
}
