import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../core/constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/app_paths.dart';
import '../../core/utils/expiring_lru_cache.dart';
import '../../core/utils/file_sort.dart';
import '../../core/utils/url_utils.dart';
import '../../data/local/playback_progress_db.dart';
import '../../data/models/audio_media_entry.dart';
import '../../data/models/audio_playback_history.dart';
import '../../data/models/media_library_item.dart';
import '../../data/models/playback_history.dart';
import '../../data/models/playback_progress.dart';
import '../../data/models/web_dav_file.dart';
import '../../data/models/media_entry.dart';
import '../../domain/services/external_player_service.dart';
import '../../domain/services/audio_player_service.dart';
import '../../domain/services/mpv_idle_completion_marker.dart';
import '../../domain/services/openlist_index_service.dart';
import '../../domain/services/player_process_controller.dart';
import '../../domain/services/webdav_service.dart';
import '../controllers/directory_browser_controller.dart';
import '../presenters/playback_session_presenter.dart';
import '../state/app_state.dart';
import '../theme/glass_tokens.dart';
import '../widgets/clipboard_history_menu.dart';
import '../widgets/directory_wheel_scroll_region.dart';
import '../widgets/file_tile.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/glass_surface.dart';
import 'home_page.dart';
import 'media_library_page.dart';
import 'settings_page.dart';

/// 文件浏览页：WebDAV 目录虚拟列表浏览 + 视频一键外部播放。
///
/// 特性：
///  - `ListView.builder` 虚拟列表，万级文件流畅滚动；
///  - 目录点击异步按需加载子目录（面包屑导航）；
///  - 首帧同步读 Hive 缓存秒开，后台自动刷新；
///  - 视频点击 → 字幕自动匹配 → 查询续播进度 → 调起外部播放器。
class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key});

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

/// 独立管理播放底栏悬停动画，鼠标经过时只重建这一条底栏，不触发
/// BrowserPage、面包屑和文件虚拟列表的整页 build。
class _PlaybackBar extends StatefulWidget {
  const _PlaybackBar({
    super.key,
    required this.title,
    required this.dirLabel,
    required this.icon,
    required this.tooltip,
    required this.deleting,
    required this.onPressed,
    required this.onDelete,
    required this.onSecondaryTapDown,
  });

  final String title;
  final String dirLabel;
  final IconData icon;
  final String tooltip;
  final bool deleting;
  final VoidCallback? onPressed;
  final VoidCallback onDelete;
  final GestureTapDownCallback onSecondaryTapDown;

  @override
  State<_PlaybackBar> createState() => _PlaybackBarState();
}

class _PlaybackBarState extends State<_PlaybackBar> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: widget.onSecondaryTapDown,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 68,
          decoration: BoxDecoration(
            color: _hovered ? Theme.of(context).hoverColor : Colors.transparent,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    AppText(
                      widget.dirLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                icon: Icon(widget.icon),
                tooltip: widget.tooltip,
                onPressed: widget.deleting ? null : widget.onPressed,
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: context.l10n.text('删除并关闭对应播放器'),
                onPressed: widget.deleting ? null : widget.onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BrowserPageState extends State<BrowserPage> {
  late final DirectoryBrowserController _directoryBrowser;
  late final PlaybackSessionPresenter _playbackPresenter;
  final TextEditingController _directorySearchController =
      TextEditingController();
  final FocusNode _directorySearchFocusNode = FocusNode();
  Set<String> _favoriteKeys = const {};

  /// 文件列表与右侧滚动条共用的显式控制器。
  ///
  /// Windows 桌面端显式滚动控制器，避免滚动条绑定到已销毁的位置。
  final ScrollController _directoryScrollController = ScrollController(
    keepScrollOffset: false,
  );

  /// 分目录、排序保存的滚动位置，只存在于当前页面内存中。
  late final ExpiringLruCache<String, double> _directoryScrollPositions;

  /// MPV 状态目录在应用生命周期内固定，只解析一次，避免播放监控每轮
  /// 重复执行路径探测和可写目录检查。
  late final Future<Directory?> _sessionCacheDirectory;

  /// 播放中动态保护警告的订阅（网络带宽持续不足等）。
  StreamSubscription<String>? _cacheWarningSub;
  StreamSubscription<PlaybackRecoveryEvent>? _playbackRecoverySub;

  @override
  void dispose() {
    _cacheWarningSub?.cancel();
    _playbackRecoverySub?.cancel();
    _directoryBrowser
      ..removeListener(_handleDirectoryBrowserChanged)
      ..dispose();
    _playbackPresenter
      ..removeListener(_handlePlaybackPresenterChanged)
      ..dispose();
    _directorySearchController.dispose();
    _directorySearchFocusNode.dispose();
    _directoryScrollController.dispose();
    super.dispose();
  }

  WebDAVService get _service => context.read<AppState>().webDavService!;

  List<String> get _crumbs => _directoryBrowser.crumbs;
  List<WebDavFile> get _files => _directoryBrowser.files;
  String? get _error => _directoryBrowser.error;
  bool get _refreshing => _directoryBrowser.refreshing;
  FileSortMode get _sortMode => _directoryBrowser.sortMode;
  FileSortDirection get _sortDirection => _directoryBrowser.sortDirection;
  bool get _directorySearchOpen => _directoryBrowser.searchOpen;
  String get _directorySearchQuery => _directoryBrowser.searchQuery;
  DirectorySearchScope get _directorySearchScope =>
      _directoryBrowser.searchScope;
  String get _currentPath => _directoryBrowser.currentPath;
  List<WebDavFile> get _visibleFiles => _directoryBrowser.visibleFiles;
  bool get _canSortBySize => _directoryBrowser.canSortBySize;
  List<PlaybackUiSession> get _playbackSessions =>
      _playbackPresenter.videoSessions;
  List<AudioPlaybackUiSession> get _audioPlaybackSessions =>
      _playbackPresenter.audioSessions;
  Timer? get _playMonitor => _playbackPresenter.videoMonitor;
  set _playMonitor(Timer? value) => _playbackPresenter.videoMonitor = value;
  Timer? get _audioPlayMonitor => _playbackPresenter.audioMonitor;
  set _audioPlayMonitor(Timer? value) =>
      _playbackPresenter.audioMonitor = value;

  /// 当前目录列表的内存状态键。
  String get _directoryScrollCacheKey =>
      'directory-scroll:${_sortMode.jsonValue}:'
      '${_sortDirection.jsonValue}:$_currentPath:'
      '${_directorySearchOpen ? '${_directorySearchScope.name}:$_directorySearchQuery' : ''}';

  ValueKey<String> get _directoryScrollKey =>
      ValueKey<String>(_directoryScrollCacheKey);

  void _rememberDirectoryScroll() {
    if (!_directoryScrollController.hasClients) return;
    _directoryScrollPositions.write(
      _directoryScrollCacheKey,
      _directoryScrollController.offset,
    );
  }

  void _scheduleDirectoryScrollRestore() {
    final key = _directoryScrollCacheKey;
    final target = _directoryScrollPositions.read(key) ?? 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || key != _directoryScrollCacheKey) return;
      if (!_directoryScrollController.hasClients) return;
      final position = _directoryScrollController.position;
      final offset = target
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if ((position.pixels - offset).abs() > 0.5) {
        _directoryScrollController.jumpTo(offset);
      }
    });
  }

  void _changeDirectoryScrollScope(VoidCallback mutation) {
    _rememberDirectoryScroll();
    mutation();
    _scheduleDirectoryScrollRestore();
  }

  @override
  void initState() {
    super.initState();
    final appState = context.read<AppState>();
    final expirationStore = appState.cacheExpirationConfigStore;
    _directoryScrollPositions = ExpiringLruCache(
      maxEntries: AppConstants.maxDirectoryScrollEntries,
      idleTtl: AppConstants.directoryScrollRetention,
      idleTtlProvider: expirationStore == null
          ? null
          : () => expirationStore.current.directoryScrollRetention,
    );
    _directoryBrowser = DirectoryBrowserController(
      service: _service,
      configStore: appState.configStore,
      onDirectoryLoaded: _recordRecentDirectory,
      onForcedRefresh: appState.playerService.captureOpenListProcessIdentity,
      openListIndexSearch: appState.searchOpenListIndex,
    )..addListener(_handleDirectoryBrowserChanged);
    _playbackPresenter = PlaybackSessionPresenter()
      ..addListener(_handlePlaybackPresenterChanged);
    _sessionCacheDirectory = _resolveSessionCacheDirectory();
    _initLoad();
    _loadFavoriteKeys();
    _loadPlaybackSessions();
    _loadAudioPlaybackSessions();
    // 播放中动态保护警告（如网络带宽不足）：SnackBar 展示。
    _cacheWarningSub = appState.cacheWarnings.listen((message) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: AppText(message)));
    });
    _playbackRecoverySub = appState.playbackRecoveryEvents.listen(
      _handlePlaybackRecoveryEvent,
    );
  }

  void _handleDirectoryBrowserChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _handlePlaybackPresenterChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _handlePlaybackRecoveryEvent(PlaybackRecoveryEvent event) {
    if (!mounted) return;
    final session = _sessionById(event.sessionId);
    final appState = context.read<AppState>();
    if (session != null) {
      switch (event.stage) {
        case PlaybackRecoveryStage.preparing:
          setState(() {
            session
              ..recovering = true
              ..launching = false
              ..paused = null;
          });
          break;
        case PlaybackRecoveryStage.relaunched:
          final result = event.launchResult;
          if (result != null) {
            final now = DateTime.now();
            final timeoutSeconds = appState
                .configStore
                .current
                .playerStartupTimeoutSeconds
                .clamp(
                  AppConstants.minPlayerStartupTimeoutSeconds,
                  AppConstants.maxPlayerStartupTimeoutSeconds,
                )
                .toInt();
            final history = session.history.copyWith(
              playerPid: result.process.pid,
              playerExecutablePath: result.processIdentity?.executablePath,
              clearPlayerExecutablePath: result.processIdentity == null,
              playerCreationTime: result.processIdentity?.creationTime,
              clearPlayerCreationTime: result.processIdentity == null,
              ipcPipeName: result.ipcPipeName,
              updatedAt: now,
            );
            setState(() {
              session.statusNotBefore = now;
              session.activationGuard.start(
                now: now,
                timeout: Duration(seconds: timeoutSeconds),
              );
              session
                ..history = history
                ..recovering = false
                ..launching = false
                ..paused = null
                ..finishPending = 0
                ..lastReportedPositionSeconds = null
                ..lastReportedDurationSeconds = null;
            });
            unawaited(appState.playbackHistoryStore.upsert(history));
            _refreshPlaybackMonitor();
          }
          break;
        case PlaybackRecoveryStage.failed:
          setState(() {
            session
              ..recovering = false
              ..launching = false
              ..paused = null;
          });
          break;
      }
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: AppText(event.message)));
  }

  void _resetDirectorySearch() {
    _directoryBrowser.closeSearch();
    _directorySearchController.clear();
    _directorySearchFocusNode.unfocus();
  }

  void _openDirectorySearch() {
    _changeDirectoryScrollScope(_directoryBrowser.openSearch);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _directorySearchOpen) {
        _directorySearchFocusNode.requestFocus();
      }
    });
  }

  void _closeDirectorySearch() {
    _changeDirectoryScrollScope(_resetDirectorySearch);
  }

  void _onDirectorySearchChanged(String query) {
    if (query == _directorySearchQuery) return;
    _changeDirectoryScrollScope(
      () => _directoryBrowser.updateSearchQuery(query),
    );
  }

  Future<void> _loadFavoriteKeys() async {
    final appState = context.read<AppState>();
    final store = appState.mediaLibraryStore;
    final sourceId = appState.mediaSourceId;
    if (store == null || sourceId == null) return;
    try {
      final favorites = await store.favorites(sourceId);
      if (!mounted || sourceId != context.read<AppState>().mediaSourceId) {
        return;
      }
      setState(() {
        _favoriteKeys = favorites
            .map((record) => record.item.stableKey)
            .toSet();
      });
    } catch (_) {
      // 个人资产读取失败不阻止目录浏览和播放。
    }
  }

  MediaLibraryItem? _libraryItemForFile(WebDavFile file, {String? parentPath}) {
    final sourceId = context.read<AppState>().mediaSourceId;
    final kind = MediaLibraryKindX.fromFile(file);
    if (sourceId == null || kind == null) return null;
    return MediaLibraryItem(
      sourceId: sourceId,
      parentPath: parentPath ?? _currentPath,
      name: file.name,
      kind: kind,
    );
  }

  Future<void> _toggleFavorite(WebDavFile file) async {
    final item = _libraryItemForFile(file);
    final store = context.read<AppState>().mediaLibraryStore;
    if (item == null || store == null) return;
    try {
      final added = await store.toggleFavorite(item);
      if (!mounted) return;
      setState(() {
        final keys = Set<String>.of(_favoriteKeys);
        if (added) {
          keys.add(item.stableKey);
        } else {
          keys.remove(item.stableKey);
        }
        _favoriteKeys = keys;
      });
    } catch (error) {
      _showLibraryError('保存收藏失败：$error');
    }
  }

  Future<void> _recordRecentDirectory(String path) async {
    final normalized = normalizeLibraryPath(path);
    if (normalized.isEmpty) return;
    final appState = context.read<AppState>();
    final store = appState.mediaLibraryStore;
    final sourceId = appState.mediaSourceId;
    if (store == null || sourceId == null) return;
    final segments = normalized.split('/');
    final item = MediaLibraryItem(
      sourceId: sourceId,
      parentPath: segments.length == 1
          ? ''
          : segments.sublist(0, segments.length - 1).join('/'),
      name: segments.last,
      kind: MediaLibraryKind.directory,
    );
    try {
      await store.recordRecentDirectory(item);
    } catch (error) {
      _showLibraryError('保存最近目录失败：$error');
    }
  }

  Future<void> _recordPlaybackFile(
    WebDavFile file, {
    required String parentPath,
    required String playbackSessionId,
  }) async {
    final item = _libraryItemForFile(file, parentPath: parentPath);
    final store = context.read<AppState>().mediaLibraryStore;
    if (item == null || store == null || !item.kind.isMedia) return;
    try {
      await store.recordPlayback(item, playbackSessionId: playbackSessionId);
    } catch (error) {
      _showLibraryError('保存最近播放失败：$error');
    }
  }

  Future<void> _recordPlaybackByName({
    required List<String> dirCrumbs,
    required String fileName,
    required bool audio,
    required String playbackSessionId,
  }) async {
    final appState = context.read<AppState>();
    final store = appState.mediaLibraryStore;
    final sourceId = appState.mediaSourceId;
    if (store == null || sourceId == null) return;
    final parentPath = normalizeLibraryPath(dirCrumbs.join('/'));
    WebDavFile? matched;
    if (normalizeLibraryPath(_currentPath) == parentPath) {
      matched = _files
          .where((file) => file.name == fileName && !file.isDirectory)
          .firstOrNull;
    }
    if (matched == null) {
      for (final snapshot in appState.directoryCache.visitedDirectories(
        sourceId,
      )) {
        if (normalizeLibraryPath(snapshot.path) != parentPath) continue;
        matched = snapshot.entries
            .where((file) => file.name == fileName && !file.isDirectory)
            .firstOrNull;
        break;
      }
    }
    final kind = matched == null
        ? (audio ? MediaLibraryKind.audio : MediaLibraryKind.video)
        : MediaLibraryKindX.fromFile(matched);
    if (kind == null || !kind.isMedia) return;
    final item = MediaLibraryItem(
      sourceId: sourceId,
      parentPath: parentPath,
      name: fileName,
      kind: kind,
    );
    try {
      await store.recordPlayback(item, playbackSessionId: playbackSessionId);
    } catch (error) {
      _showLibraryError('保存最近播放失败：$error');
    }
  }

  void _showLibraryError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: AppText(message)));
  }

  Future<Directory?> _resolveSessionCacheDirectory() async {
    try {
      return await AppPaths.cacheDirectory();
    } catch (_) {
      return null;
    }
  }

  bool get _needsPlaybackMonitor => _playbackSessions.any(
    (session) =>
        !session.deleting &&
        (session.history.playerPid != null ||
            session.history.ipcPipeName != null ||
            session.activationGuard.isWaiting),
  );

  /// 仅在确实有播放器进程需要跟踪时启用 700ms 监控。
  ///
  /// 纯“继续播放”历史没有活动 PID/IPC，不需要常驻计时器；恢复播放成功
  /// 后会重新启动监控，不改变暂停、切集、完成判定和启动保护行为。
  void _refreshPlaybackMonitor() {
    if (!mounted) return;
    if (!_needsPlaybackMonitor) {
      _playMonitor?.cancel();
      _playMonitor = null;
      return;
    }
    if (_playMonitor != null) return;
    _playMonitor = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (!_needsPlaybackMonitor) {
        _refreshPlaybackMonitor();
        return;
      }
      _syncPlaybackSessions();
    });
    _syncPlaybackSessions();
  }

  /// 载入持久化播放会话并恢复各自 PID/IPC 追踪。
  Future<void> _loadPlaybackSessions() async {
    final appState = context.read<AppState>();
    final histories = await appState.playbackHistoryStore.loadAll();
    if (!mounted) return;
    _playbackPresenter.replaceVideoSessions(histories);
    for (final history in histories) {
      await appState.playerService.restoreSession(
        sessionId: history.sessionId,
        pid: history.playerPid,
        executablePath: history.playerExecutablePath,
        creationTime: history.playerCreationTime,
        ipcPipeName: history.ipcPipeName,
        launchEpoch: history.launchEpoch,
      );
    }
    _refreshPlaybackMonitor();
  }

  PlaybackUiSession? _sessionById(String sessionId) =>
      _playbackPresenter.videoSessionById(sessionId);

  String _newSessionId() => _playbackPresenter.newVideoSessionId();

  String _newAudioSessionId() => _playbackPresenter.newAudioSessionId();

  bool get _needsAudioPlaybackMonitor => _audioPlaybackSessions.any(
    (session) =>
        !session.deleting &&
        (session.history.playerPid != null ||
            session.history.ipcPipeName != null ||
            session.activationGuard.isWaiting),
  );

  void _refreshAudioPlaybackMonitor() {
    if (!mounted) return;
    if (!_needsAudioPlaybackMonitor) {
      _audioPlayMonitor?.cancel();
      _audioPlayMonitor = null;
      return;
    }
    if (_audioPlayMonitor != null) return;
    _audioPlayMonitor = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (!_needsAudioPlaybackMonitor) {
        _refreshAudioPlaybackMonitor();
        return;
      }
      _syncAudioPlaybackSessions();
    });
    _syncAudioPlaybackSessions();
  }

  Future<void> _loadAudioPlaybackSessions() async {
    final appState = context.read<AppState>();
    final store = appState.audioPlaybackHistoryStore;
    final player = appState.audioPlayerService;
    if (store == null || player == null) return;
    final histories = await store.loadAll();
    if (!mounted) return;
    _playbackPresenter.replaceAudioSessions(histories);
    for (final history in histories) {
      await player.restoreSession(
        sessionId: history.sessionId,
        pid: history.playerPid,
        executablePath: history.playerExecutablePath,
        creationTime: history.playerCreationTime,
        ipcPipeName: history.ipcPipeName,
        launchEpoch: history.launchEpoch,
      );
    }
    _refreshAudioPlaybackMonitor();
  }

  AudioPlaybackUiSession? _audioSessionById(String sessionId) =>
      _playbackPresenter.audioSessionById(sessionId);

  /// 首帧加载：先同步读缓存秒开，再走网络/缓存编排。
  Future<void> _initLoad() async {
    await _directoryBrowser.initialize();
    if (mounted) _scheduleDirectoryScrollRestore();
  }

  /// 加载当前目录（[force] 为 true 时强制刷新网络）。
  Future<void> _load({bool force = false}) async {
    await _directoryBrowser.load(force: force);
    if (mounted) _scheduleDirectoryScrollRestore();
  }

  // ── 目录导航 ─────────────────────────────────────────────────

  void _enterDirectory(WebDavFile dir) {
    _changeDirectoryScrollScope(() {
      _directorySearchController.clear();
      _directorySearchFocusNode.unfocus();
      _directoryBrowser.enterDirectory(dir);
    });
    unawaited(_load());
  }

  void _backTo(int index) {
    // index 为面包屑位置；切到该层（含其子层移除）。
    _changeDirectoryScrollScope(() {
      _directorySearchController.clear();
      _directorySearchFocusNode.unfocus();
      _directoryBrowser.backTo(index);
    });
    unawaited(_load());
  }

  // ── 视频播放联动（自动切集） ─────────────────────────────────

  Future<void> _playVideo(WebDavFile video, {String? sessionId}) async {
    final appState = context.read<AppState>();
    final libraryParentPath = _currentPath;
    final existingSession = sessionId == null ? null : _sessionById(sessionId);
    if (sessionId == null &&
        _playbackSessions.length >= AppConstants.maxPlaybackSessions) {
      await showGlassDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const AppText('播放位置已占满'),
          content: AppText(
            '当前最多同时保留 ${AppConstants.maxPlaybackSessions} 个播放会话，'
            '请先关闭或删除一个下边栏后再播放。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const AppText('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    if (existingSession?.deleting == true ||
        existingSession?.launching == true) {
      return;
    }

    // 1. 收集播放列表：**全部**同目录可播放项（视频 + strm，含点击项
    //    之前的集，MPV 播放列表可手动切回），播放起点为点击项。
    final videos = _files.where((f) => f.isPlayable).toList();
    final startIndex = videos.indexWhere((f) => f.href == video.href);
    final ordered = (startIndex < 0 ? [video] : videos);

    // strm 流指针条目：分批并发预取指向的真实媒体地址（每批限流，
    // 避免大量 strm 打爆服务器）；解析失败的条目从播放列表剔除。
    final strmUrls = <String, String>{};
    final strmFiles = ordered.where((f) => f.isStrm).toList();
    const batchSize = 4;
    for (var i = 0; i < strmFiles.length; i += batchSize) {
      final batch = strmFiles.sublist(
        i,
        (i + batchSize < strmFiles.length) ? i + batchSize : strmFiles.length,
      );
      await Future.wait(
        batch.map((f) async {
          final url = await _service.fetchStrmUrl(f);
          if (url != null) strmUrls[f.href] = url;
        }),
      );
    }

    final entries = <MediaEntry>[];
    var clickedIndex = -1;
    final subtitleInjectionEnabled =
        appState.configStore.current.subtitleInjectionEnabled;
    for (final v in ordered) {
      final String? url = v.isStrm
          ? strmUrls[v.href]
          : _service.resolveUrl(v.href);
      if (url == null) continue;
      if (v.href == video.href) clickedIndex = entries.length;
      entries.add(
        MediaEntry(
          url: url,
          title: v.name,
          subtitle: subtitleInjectionEnabled
              ? appState.subtitleMatcher.findBestFor(v, _files)
              : null,
        ),
      );
    }
    if (entries.isEmpty || clickedIndex < 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: AppText('无法播放「${video.name}」：strm 内容无效或读取失败')),
        );
      }
      return;
    }
    final playStart = clickedIndex;
    final activeVideos = ordered
        .where((v) => v.isStrm ? strmUrls.containsKey(v.href) : true)
        .toList();
    final resolvedSessionId = sessionId ?? _newSessionId();
    final now = DateTime.now();
    final history = PlaybackHistory(
      sessionId: resolvedSessionId,
      dirCrumbs: List.of(_crumbs),
      fileName: activeVideos[playStart].name,
      videoIndex: playStart,
      updatedAt: now,
      createdAt: existingSession?.history.createdAt ?? now,
      playlistFileNames: activeVideos.map((v) => v.name).toList(),
    );
    final session = existingSession ?? PlaybackUiSession(history);
    session
      ..history = history
      ..lastSyncedPos = playStart
      ..finishPending = 0
      ..paused = null
      ..recovering = false
      ..launching = true;
    session.activationGuard.reset();
    session
      ..lastReportedPositionSeconds = null
      ..lastReportedDurationSeconds = null
      ..lastProgressPersistedAt = null;
    if (mounted && existingSession == null) {
      _playbackPresenter.addVideoSession(session);
    }
    final stored = await appState.playbackHistoryStore.upsert(history);
    if (!stored) {
      if (mounted) _playbackPresenter.removeVideoSession(session);
      return;
    }

    // 2. 查询播放起点视频的续播进度（失败不阻塞播放）。
    //    进度接近结尾（剩余不足 1 分钟，视为已看完）→ 从头播放，
    //    避免 mpv 从片尾恢复导致秒切下一集。
    PlaybackProgress? progress;
    try {
      progress = await appState.progressService.getResumeProgress(
        entries[playStart].url,
        profileId: appState.mediaSourceId,
      );
      // 已看完（时长已知且位置接近片尾，剩余不足 1 分钟）→ 从头播放，
      // 避免 mpv 从片尾恢复导致秒切下一集。
      // 注意：时长缺失（mpv 对网络流不写 duration）时**不**视为已看完，
      // 否则每次播放都会从头开始。
      if (progress != null && progress.isFinishedNearEnd()) {
        progress = null;
      }
    } on AppException {
      // 进度读取失败忽略，正常播放。
    }

    // 3. 调起外部播放器（凭据注入由服务内部按播放器类型处理）。
    try {
      session.statusNotBefore = DateTime.now();
      final result = await appState.playerService.launch(
        entries: entries,
        sessionId: resolvedSessionId,
        playlistStart: playStart,
        resumeSeconds: progress?.resumeSeconds,
        username: appState.username,
        password: appState.password,
      );
      if (!mounted || !_playbackSessions.contains(session)) {
        await appState.playerService.terminateLaunch(result);
        return;
      }
      final launchedHistory = session.history.copyWith(
        playerPid: result.process.pid,
        playerExecutablePath: result.processIdentity?.executablePath,
        clearPlayerExecutablePath: result.processIdentity == null,
        playerCreationTime: result.processIdentity?.creationTime,
        clearPlayerCreationTime: result.processIdentity == null,
        ipcPipeName: result.ipcPipeName,
        launchEpoch: result.launchEpoch,
        updatedAt: DateTime.now(),
      );
      setState(() {
        final activatedAt = DateTime.now();
        final timeoutSeconds = appState
            .configStore
            .current
            .playerStartupTimeoutSeconds
            .clamp(
              AppConstants.minPlayerStartupTimeoutSeconds,
              AppConstants.maxPlayerStartupTimeoutSeconds,
            )
            .toInt();
        session.activationGuard.start(
          now: activatedAt,
          timeout: Duration(seconds: timeoutSeconds),
        );
        session
          ..history = launchedHistory
          ..paused = null
          ..launching = false;
      });
      _refreshPlaybackMonitor();
      unawaited(appState.playbackHistoryStore.upsert(launchedHistory));
      unawaited(
        _recordPlaybackFile(
          video,
          parentPath: libraryParentPath,
          playbackSessionId: resolvedSessionId,
        ),
      );

      final subtitle = entries[playStart].subtitle;
      final parts = <String>[
        '已启动播放器（${entries.length} 集）',
        if (subtitle != null) '字幕：${subtitle.name}',
        if (progress?.resumeSeconds != null) '续播于 ${progress!.resumeSeconds}s',
      ];
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: AppText(parts.join(' · ')),
          duration: const Duration(seconds: 3),
        ),
      );
    } on AppException catch (e) {
      if (!mounted) return;
      if (_playbackSessions.contains(session)) {
        setState(() {
          session
            ..launching = false
            ..paused = null;
        });
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: AppText(e.message)));
    }
  }

  // ── 音频播放联动（独立 M3U8、歌词、封面与进度） ─────────────

  Future<void> _playAudio(WebDavFile audio, {String? sessionId}) async {
    final appState = context.read<AppState>();
    final libraryParentPath = _currentPath;
    final player = appState.audioPlayerService;
    final historyStore = appState.audioPlaybackHistoryStore;
    final progressService = appState.audioProgressService;
    if (player == null || historyStore == null || progressService == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: AppText('音频播放模块初始化失败，视频播放不受影响')));
      return;
    }
    final existingSession = sessionId == null
        ? null
        : _audioSessionById(sessionId);
    if (sessionId == null &&
        _audioPlaybackSessions.length >= AppConstants.maxPlaybackSessions) {
      await showGlassDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const AppText('音频播放位置已占满'),
          content: AppText(
            '当前最多同时保留 ${AppConstants.maxPlaybackSessions} 个音频会话，'
            '请先关闭或删除一个音频下边栏后再播放。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const AppText('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    if (existingSession?.deleting == true ||
        existingSession?.launching == true) {
      return;
    }

    // 与视频稳定列表相同：只取后台全量目录，不受显示排序、搜索或隐藏影响。
    final audioFiles = _files.where((file) => file.isAudio).toList();
    final clickedIndex = audioFiles.indexWhere(
      (file) => file.href == audio.href,
    );
    final ordered = clickedIndex < 0 ? [audio] : audioFiles;
    final subtitleInjectionEnabled =
        appState.configStore.current.subtitleInjectionEnabled;
    final entries = <AudioMediaEntry>[];
    var playStart = -1;
    for (final file in ordered) {
      if (file.href == audio.href) playStart = entries.length;
      final lyrics = subtitleInjectionEnabled
          ? appState.audioCompanionMatcher.findLyricsFor(file, _files)
          : null;
      final cover = appState.audioCompanionMatcher.findCoverFor(file, _files);
      entries.add(
        AudioMediaEntry(
          url: _service.resolveUrl(file.href),
          title: file.name,
          lyrics: lyrics == null
              ? null
              : AudioCompanionFile(
                  name: lyrics.name,
                  url: _service.resolveUrl(lyrics.url),
                ),
          coverArt: cover == null
              ? null
              : AudioCompanionFile(
                  name: cover.name,
                  url: _service.resolveUrl(cover.url),
                ),
        ),
      );
    }
    if (entries.isEmpty || playStart < 0) return;

    final resolvedSessionId = sessionId ?? _newAudioSessionId();
    final now = DateTime.now();
    final history = AudioPlaybackHistory(
      sessionId: resolvedSessionId,
      dirCrumbs: List.of(_crumbs),
      fileName: ordered[playStart].name,
      trackIndex: playStart,
      updatedAt: now,
      createdAt: existingSession?.history.createdAt ?? now,
      playlistFileNames: ordered.map((file) => file.name).toList(),
    );
    final session = existingSession ?? AudioPlaybackUiSession(history);
    session
      ..history = history
      ..lastSyncedPos = playStart
      ..finishPending = 0
      ..paused = null
      ..launching = true
      ..lastReportedPositionSeconds = null
      ..lastReportedDurationSeconds = null
      ..lastProgressPersistedAt = null;
    session.activationGuard.reset();
    if (mounted && existingSession == null) {
      _playbackPresenter.addAudioSession(session);
    }
    if (!await historyStore.upsert(history)) {
      if (mounted) _playbackPresenter.removeAudioSession(session);
      return;
    }

    PlaybackProgress? progress;
    try {
      await player.syncPersistedProgress(
        sessionId: resolvedSessionId,
        entries: entries,
        username: appState.username,
        password: appState.password,
        launchEpoch: existingSession?.history.launchEpoch,
      );
      progress = await progressService.getProgress(
        entries[playStart].url,
        profileId: appState.mediaSourceId,
      );
      if (progress != null && progress.isFinishedNearEnd()) progress = null;
    } on AppException {
      // 音频进度读取失败时从头播放，视频链路不受影响。
    }

    try {
      session.statusNotBefore = DateTime.now();
      final result = await player.launch(
        entries: entries,
        sessionId: resolvedSessionId,
        playlistStart: playStart,
        resumeSeconds: progress?.resumeSeconds,
        username: appState.username,
        password: appState.password,
        lyricsLoader: (url, {required maxBytes, required timeout}) =>
            _service.fetchFileBytes(url, maxBytes: maxBytes, timeout: timeout),
      );
      if (!mounted || !_audioPlaybackSessions.contains(session)) {
        await player.terminateLaunch(result);
        return;
      }
      final launchedHistory = session.history.copyWith(
        playerPid: result.process.pid,
        playerExecutablePath: result.processIdentity?.executablePath,
        clearPlayerExecutablePath: result.processIdentity == null,
        playerCreationTime: result.processIdentity?.creationTime,
        clearPlayerCreationTime: result.processIdentity == null,
        ipcPipeName: result.ipcPipeName,
        launchEpoch: result.launchEpoch,
        updatedAt: DateTime.now(),
      );
      setState(() {
        final activatedAt = DateTime.now();
        final timeoutSeconds = appState
            .configStore
            .current
            .playerStartupTimeoutSeconds
            .clamp(
              AppConstants.minPlayerStartupTimeoutSeconds,
              AppConstants.maxPlayerStartupTimeoutSeconds,
            )
            .toInt();
        session.activationGuard.start(
          now: activatedAt,
          timeout: Duration(seconds: timeoutSeconds),
        );
        session
          ..history = launchedHistory
          ..paused = null
          ..launching = false;
      });
      _refreshAudioPlaybackMonitor();
      unawaited(historyStore.upsert(launchedHistory));
      unawaited(
        _recordPlaybackFile(
          audio,
          parentPath: libraryParentPath,
          playbackSessionId: resolvedSessionId,
        ),
      );

      final current = entries[playStart];
      final parts = <String>[
        '已启动音频播放器（${entries.length} 首）',
        if (current.lyrics != null) '歌词：${current.lyrics!.name}',
        if (current.coverArt != null) '封面：${current.coverArt!.name}',
        if (progress?.resumeSeconds != null) '续播于 ${progress!.resumeSeconds}s',
      ];
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: AppText(parts.join(' · '))));
    } on AppException catch (error) {
      if (!mounted) return;
      if (_audioPlaybackSessions.contains(session)) {
        setState(() {
          session
            ..launching = false
            ..paused = null;
        });
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: AppText(error.message)));
    } catch (_) {
      if (!mounted) return;
      if (_audioPlaybackSessions.contains(session)) {
        setState(() {
          session
            ..launching = false
            ..paused = null;
        });
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: AppText('音频播放模块发生错误，视频播放不受影响')));
    }
  }

  void _syncAudioPlaybackSessions() {
    for (final session in List<AudioPlaybackUiSession>.of(
      _audioPlaybackSessions,
    )) {
      if (session.syncBusy || session.deleting || session.launching) continue;
      session.syncBusy = true;
      unawaited(
        _syncAudioPlaybackSession(session).whenComplete(() {
          session.syncBusy = false;
          _refreshAudioPlaybackMonitor();
        }),
      );
    }
  }

  Future<void> _syncAudioPlaybackSession(AudioPlaybackUiSession session) async {
    if (!_audioPlaybackSessions.contains(session)) return;
    final names = session.playlistFileNames;
    if (names.isEmpty) return;
    final appState = context.read<AppState>();
    final store = appState.audioPlaybackHistoryStore;
    final player = appState.audioPlayerService;
    if (store == null || player == null) return;
    final sessionId = session.history.sessionId;
    final now = DateTime.now();
    final guard = session.activationGuard;
    if (guard.shouldProbe(now)) {
      final running = await player.isPlayerRunning(sessionId);
      guard.recordProbe(now: now, running: running);
    }
    var running = guard.lastKnownRunning ?? false;
    if (!_audioPlaybackSessions.contains(session)) return;

    final Directory? dataDir = await _sessionCacheDirectory;
    if (dataDir == null) return;
    final statusFile = File(
      p.join(
        dataDir.path,
        AudioPlayerService.sessionStatusFileName(
          sessionId,
          launchEpoch: session.history.launchEpoch,
        ),
      ),
    );
    DateTime? statusModifiedAt;
    try {
      final status = await statusFile.stat();
      if (status.type == FileSystemEntityType.file) {
        statusModifiedAt = status.modified;
      }
    } catch (_) {
      // 音频状态文件尚未创建或正在替换，留待下一轮。
    }
    List<String>? lines;
    if (statusModifiedAt?.isAfter(session.statusNotBefore) ?? false) {
      try {
        lines = await statusFile.readAsLines();
      } catch (_) {
        // MPV 正在写状态文件时留待下一轮。
      }
    }

    _rememberAudioProgress(session, lines, running: running);
    final loadedPos = lines == null || lines.isEmpty
        ? null
        : int.tryParse(lines.first.trim());
    final hasLoaded =
        loadedPos != null &&
        loadedPos >= 0 &&
        loadedPos < names.length &&
        lines!.length >= 2 &&
        lines[1].trim().isNotEmpty;
    if (guard.isWaiting && hasLoaded) {
      guard.confirmActivation();
      running = true;
      guard.recordProbe(now: DateTime.now(), running: true);
    }
    if (guard.isWaiting) {
      if (guard.hasTimedOut(now)) {
        await _removeAudioPlaybackSession(session, terminateProcess: true);
      } else if (session.paused != null && mounted) {
        setState(() => session.paused = null);
      }
      return;
    }

    if (!running) {
      await player.waitForExitSync(sessionId);
      if (!_audioPlaybackSessions.contains(session)) return;
      final pos = lines == null || lines.isEmpty
          ? null
          : int.tryParse(lines.first.trim());
      final naturallyFinished =
          _isFreshStatus(statusModifiedAt) &&
          (_isOwnedIdleCompletion(
                lines,
                expectedLastPos: names.length - 1,
                expectedEpoch: session.history.launchEpoch,
              ) ||
              (pos == -1 && session.lastSyncedPos == names.length - 1));
      var completed = _hasReachedAudioCompletion(session, lines);
      if (!completed) {
        completed = await _hasPersistedAudioCompletion(session, lines);
      }
      if (naturallyFinished || completed) {
        await _removeAudioPlaybackSession(session, terminateProcess: false);
        return;
      }
      final needsHistoryUpdate =
          session.history.playerPid != null ||
          session.history.ipcPipeName != null;
      if (needsHistoryUpdate) {
        session.history = session.history.copyWith(
          clearPlayerPid: true,
          clearIpcPipeName: true,
          updatedAt: DateTime.now(),
        );
        await store.upsert(session.history);
      }
      if (session.paused != null && mounted) {
        setState(() => session.paused = null);
      }
      return;
    }

    if (lines == null || lines.length < 2) return;
    final pos = int.tryParse(lines.first.trim());
    if (pos == null || pos < 0 || pos >= names.length) {
      final reachedLast =
          session.lastSyncedPos == names.length - 1 ||
          _isOwnedIdleCompletion(
            lines,
            expectedLastPos: names.length - 1,
            expectedEpoch: session.history.launchEpoch,
          );
      if (pos == -1 && reachedLast && _isFreshStatus(statusModifiedAt)) {
        session.finishPending++;
        if (session.finishPending >= 2) {
          session.finishPending = 0;
          await _removeAudioPlaybackSession(session, terminateProcess: true);
        }
      } else {
        session.finishPending = 0;
      }
      return;
    }
    session.finishPending = 0;
    final paused = lines.length >= 3 ? lines[2].trim() == '1' : false;
    final pauseChanged = paused != session.paused;
    final mediaChanged = pos != session.lastSyncedPos;
    if (mediaChanged) {
      try {
        await player.syncActiveProgress(sessionId);
      } catch (_) {
        // 切歌进度同步失败不影响播放列表和下边栏更新。
      }
    }
    final progressService = appState.audioProgressService;
    if (progressService != null) {
      await _persistLiveProgress(
        service: progressService,
        profileId: appState.mediaSourceId,
        lines: lines,
        running: running,
        force: pauseChanged || mediaChanged,
        lastPersistedAt: session.lastProgressPersistedAt,
        onPersisted: (value) => session.lastProgressPersistedAt = value,
      );
    }
    if (paused != session.paused && mounted) {
      setState(() => session.paused = paused);
    }
    if (pos == session.lastSyncedPos) return;
    session.lastSyncedPos = pos;
    session.history = session.history.copyWith(
      fileName: names[pos],
      trackIndex: pos,
      updatedAt: DateTime.now(),
    );
    await store.upsert(session.history);
    unawaited(
      _recordPlaybackByName(
        dirCrumbs: session.history.dirCrumbs,
        fileName: names[pos],
        audio: true,
        playbackSessionId: session.history.sessionId,
      ),
    );
    if (mounted && _audioPlaybackSessions.contains(session)) setState(() {});
  }

  void _rememberAudioProgress(
    AudioPlaybackUiSession session,
    List<String>? lines, {
    required bool running,
  }) {
    if (lines == null || lines.length < 5) return;
    final playlistPos = int.tryParse(lines.first.trim());
    if (playlistPos == null || playlistPos < 0 || lines[1].trim().isEmpty) {
      return;
    }
    final position = double.tryParse(lines[3].trim());
    final duration = double.tryParse(lines[4].trim());
    if (position != null && position >= 0) {
      final exitZero =
          !running &&
          position == 0 &&
          session.lastReportedPositionSeconds != null;
      if (!exitZero) session.lastReportedPositionSeconds = position;
    }
    if (duration != null && duration > 0) {
      session.lastReportedDurationSeconds = duration;
    }
  }

  Future<void> _persistLiveProgress({
    required PlaybackProgressService service,
    required String? profileId,
    required List<String> lines,
    required bool running,
    required bool force,
    required DateTime? lastPersistedAt,
    required ValueChanged<DateTime> onPersisted,
  }) async {
    if (!running || lines.length < 5) return;
    final url = lines[1].trim();
    final position = double.tryParse(lines[3].trim());
    final duration = double.tryParse(lines[4].trim());
    if (url.isEmpty || position == null || position < 0) return;
    final now = DateTime.now();
    if (!force &&
        lastPersistedAt != null &&
        now.difference(lastPersistedAt) < const Duration(seconds: 10)) {
      return;
    }
    try {
      await service.saveProgress(
        url: stripUserInfo(url),
        positionMs: (position * 1000).round(),
        durationMs: duration != null && duration > 0
            ? (duration * 1000).round()
            : null,
        profileId: profileId,
      );
      onPersisted(now);
    } on AppException {
      // 运行中进度属于旁路刷新，失败时仍由退出同步提供最终进度。
    }
  }

  bool _hasReachedAudioCompletion(
    AudioPlaybackUiSession session,
    List<String>? lines,
  ) => hasReachedExitCompletion(
    positionSeconds: lines != null && lines.length >= 5
        ? double.tryParse(lines[3].trim())
        : null,
    durationSeconds: lines != null && lines.length >= 5
        ? double.tryParse(lines[4].trim())
        : null,
    fallbackPositionSeconds: session.lastReportedPositionSeconds,
    fallbackDurationSeconds: session.lastReportedDurationSeconds,
  );

  Future<bool> _hasPersistedAudioCompletion(
    AudioPlaybackUiSession session,
    List<String>? lines,
  ) async {
    if (lines == null || lines.length < 2 || lines[1].trim().isEmpty) {
      return false;
    }
    final progressService = context.read<AppState>().audioProgressService;
    if (progressService == null) return false;
    try {
      final progress = await progressService.getProgress(
        stripUserInfo(lines[1].trim()),
        profileId: context.read<AppState>().mediaSourceId,
      );
      final updatedAt = progress?.updatedAt;
      if (progress == null ||
          updatedAt == null ||
          updatedAt.isBefore(session.statusNotBefore)) {
        return false;
      }
      return progress.hasReachedFraction();
    } on AppException {
      return false;
    }
  }

  Future<void> _removeAudioPlaybackSession(
    AudioPlaybackUiSession session, {
    required bool terminateProcess,
  }) async {
    if (session.deleting || !_audioPlaybackSessions.contains(session)) return;
    session.deleting = true;
    if (mounted) setState(() {});
    final appState = context.read<AppState>();
    final player = appState.audioPlayerService;
    final store = appState.audioPlaybackHistoryStore;
    if (terminateProcess) {
      final termination = await player?.terminateSession(
        session.history.sessionId,
      );
      if (termination != null && !termination.isSafeToRelaunch) {
        session.deleting = false;
        if (mounted) {
          setState(() {});
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: AppText('无法确认音频播放器身份，已保留会话且未终止进程')),
          );
        }
        return;
      }
    } else {
      player?.releaseSession(session.history.sessionId);
    }
    await store?.remove(session.history.sessionId);
    if (!mounted) return;
    _playbackPresenter.removeAudioSession(session);
    _refreshAudioPlaybackMonitor();
  }

  Future<void> _resumeAudioPlaybackSession(
    AudioPlaybackUiSession session,
  ) async {
    if (session.launching || session.deleting) return;
    final history = session.history;
    _directorySearchController.clear();
    _directorySearchFocusNode.unfocus();
    _directoryBrowser.navigateToPath(history.dirCrumbs.join('/'));
    try {
      await _load();
    } on AppException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: AppText(error.message)));
      return;
    }
    if (!mounted) return;
    final audioFiles = _files.where((file) => file.isAudio).toList();
    if (audioFiles.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: AppText('该目录下没有可播放的音频')));
      return;
    }
    var index = audioFiles.indexWhere((file) => file.name == history.fileName);
    if (index < 0) index = history.trackIndex.clamp(0, audioFiles.length - 1);
    await _playAudio(audioFiles[index], sessionId: history.sessionId);
  }

  void _syncPlaybackSessions() {
    for (final session in List<PlaybackUiSession>.of(_playbackSessions)) {
      if (session.syncBusy || session.deleting || session.launching) continue;
      session.syncBusy = true;
      unawaited(
        _syncPlaybackSession(session).whenComplete(() {
          session.syncBusy = false;
          _refreshPlaybackMonitor();
        }),
      );
    }
  }

  /// 独立同步一个下边栏对应的 PID、状态文件、暂停状态与切集位置。
  Future<void> _syncPlaybackSession(PlaybackUiSession session) async {
    if (!_playbackSessions.contains(session)) return;
    final names = session.playlistFileNames;
    if (names.isEmpty) return;
    final appState = context.read<AppState>();
    final store = appState.playbackHistoryStore;
    final playerService = appState.playerService;
    final sessionId = session.history.sessionId;
    final now = DateTime.now();
    final guard = session.activationGuard;
    if (guard.shouldProbe(now)) {
      final probedRunning = await playerService.isPlayerRunning(sessionId);
      guard.recordProbe(now: now, running: probedRunning);
    }
    var running = guard.lastKnownRunning ?? false;
    if (!_playbackSessions.contains(session)) return;

    final File statusFile;
    try {
      final dataDir = await _sessionCacheDirectory; // mpv 状态文件
      if (dataDir == null) return;
      statusFile = File(
        p.join(
          dataDir.path,
          ExternalPlayerService.sessionStatusFileName(
            sessionId,
            launchEpoch: session.history.launchEpoch,
          ),
        ),
      );
    } catch (_) {
      return;
    }
    DateTime? statusModifiedAt;
    try {
      final status = await statusFile.stat();
      if (status.type == FileSystemEntityType.file) {
        statusModifiedAt = status.modified;
      }
    } catch (_) {
      // 状态文件尚未创建或正在被替换，留待下一轮。
    }
    List<String>? lines;
    if (_isStatusForSession(statusModifiedAt, session)) {
      try {
        lines = await statusFile.readAsLines();
      } catch (_) {
        // MPV 正在写状态文件时留待下一轮读取。
      }
    }

    _rememberReportedProgress(session, lines, running: running);
    final loadedPos = lines == null || lines.isEmpty
        ? null
        : int.tryParse(lines[0].trim());
    final hasLoadedCurrentMedia =
        loadedPos != null &&
        loadedPos >= 0 &&
        loadedPos < names.length &&
        lines!.length >= 2 &&
        lines[1].trim().isNotEmpty;
    final isMpvSession = session.history.ipcPipeName != null;
    if (guard.isWaiting && hasLoadedCurrentMedia) {
      guard.confirmActivation();
      // 状态文件可能先于进程探测结果到达。本轮直接视为已运行，
      // 下一次 1 秒探测再确认进程存活，避免命中短暂 false 缓存。
      running = true;
      guard.recordProbe(now: DateTime.now(), running: true);
    } else if (guard.isWaiting && !isMpvSession && running) {
      guard.confirmActivation();
    }

    // MPV 进程已创建但尚未写出首个 file-loaded 状态时，保留下边栏并
    // 显示“继续播放”。每 1 秒只探测一次进程；超过配置期限仍未激活
    // 才终止对应进程并清理该会话。
    if (guard.isWaiting) {
      if (guard.hasTimedOut(now)) {
        await _removePlaybackSession(session, terminateProcess: true);
      } else if (session.paused != null && mounted) {
        setState(() => session.paused = null);
      }
      return;
    }

    // 进程退出后直接收敛为“完成”或“继续播放”，不再应用残留状态文件
    // 中的 pause 值，避免两个状态在轮询中互相覆盖而闪烁。
    if (!running) {
      await playerService.waitForExitSync(sessionId);
      if (!_playbackSessions.contains(session)) return;
      final pos = lines == null || lines.isEmpty
          ? null
          : int.tryParse(lines[0].trim());
      final naturallyFinished =
          _isFreshStatus(statusModifiedAt) &&
          (_isOwnedIdleCompletion(
                lines,
                expectedLastPos: names.length - 1,
                expectedEpoch: session.history.launchEpoch,
              ) ||
              (pos == -1 && session.lastSyncedPos == names.length - 1));
      var reachedCompletion = _hasReachedCompletionThreshold(session, lines);
      if (!reachedCompletion) {
        reachedCompletion = await _hasPersistedCompletionThreshold(
          session,
          lines,
        );
      }
      if (naturallyFinished || reachedCompletion) {
        await _removePlaybackSession(session, terminateProcess: false);
        return;
      }

      session.finishPending = 0;
      final needsHistoryUpdate =
          session.history.playerPid != null ||
          session.history.ipcPipeName != null;
      if (needsHistoryUpdate) {
        session.history = session.history.copyWith(
          clearPlayerPid: true,
          clearIpcPipeName: true,
          updatedAt: DateTime.now(),
        );
        await store.upsert(session.history);
      }
      if (session.paused != null && mounted) {
        setState(() => session.paused = null);
      }
      return;
    }

    if (lines == null) return;
    if (lines.length < 2) return;
    final pos = int.tryParse(lines[0].trim());
    if (pos == null || pos < 0 || pos >= names.length) {
      final reachedSortedLast =
          session.lastSyncedPos == names.length - 1 ||
          _isOwnedIdleCompletion(
            lines,
            expectedLastPos: names.length - 1,
            expectedEpoch: session.history.launchEpoch,
          );
      if (pos == -1 && reachedSortedLast && _isFreshStatus(statusModifiedAt)) {
        session.finishPending++;
        if (session.finishPending >= 2) {
          session.finishPending = 0;
          await _removePlaybackSession(session, terminateProcess: true);
        }
      } else {
        session.finishPending = 0;
      }
      return;
    }
    session.finishPending = 0;

    final paused = lines.length >= 3 ? lines[2].trim() == '1' : false;
    final pauseChanged = paused != session.paused;
    final mediaChanged = pos != session.lastSyncedPos;
    if (mediaChanged) {
      try {
        await playerService.syncActiveProgress(sessionId);
      } catch (_) {
        // 切集进度同步失败不影响播放列表和下边栏更新。
      }
    }
    await _persistLiveProgress(
      service: appState.progressService,
      profileId: appState.mediaSourceId,
      lines: lines,
      running: running,
      force: pauseChanged || mediaChanged,
      lastPersistedAt: session.lastProgressPersistedAt,
      onPersisted: (value) => session.lastProgressPersistedAt = value,
    );
    if (paused != session.paused && mounted) {
      setState(() => session.paused = paused);
    }

    if (pos == session.lastSyncedPos) return;
    session.lastSyncedPos = pos;
    final history = session.history.copyWith(
      fileName: names[pos],
      videoIndex: pos,
      updatedAt: DateTime.now(),
    );
    session.history = history;
    await store.upsert(history);
    unawaited(
      _recordPlaybackByName(
        dirCrumbs: history.dirCrumbs,
        fileName: names[pos],
        audio: false,
        playbackSessionId: history.sessionId,
      ),
    );
    if (!mounted || !_playbackSessions.contains(session)) return;
    setState(() {});
  }

  /// 只供“MPV 进程已经退出”分支使用；运行中的 99% 不提前隐藏。
  bool _hasReachedCompletionThreshold(
    PlaybackUiSession session,
    List<String>? lines,
  ) {
    final positionSeconds = lines != null && lines.length >= 5
        ? double.tryParse(lines[3].trim())
        : null;
    final durationSeconds = lines != null && lines.length >= 5
        ? double.tryParse(lines[4].trim())
        : null;
    return hasReachedExitCompletion(
      positionSeconds: positionSeconds,
      durationSeconds: durationSeconds,
      fallbackPositionSeconds: session.lastReportedPositionSeconds,
      fallbackDurationSeconds: session.lastReportedDurationSeconds,
    );
  }

  void _rememberReportedProgress(
    PlaybackUiSession session,
    List<String>? lines, {
    required bool running,
  }) {
    if (lines == null || lines.length < 5) return;
    final playlistPos = int.tryParse(lines[0].trim());
    if (playlistPos == null || playlistPos < 0 || lines[1].trim().isEmpty) {
      return;
    }
    final position = double.tryParse(lines[3].trim());
    final duration = double.tryParse(lines[4].trim());
    if (position != null && position >= 0) {
      final exitZero =
          !running &&
          position == 0 &&
          session.lastReportedPositionSeconds != null;
      if (!exitZero) {
        session.lastReportedPositionSeconds = position;
      }
    }
    if (duration != null && duration > 0) {
      session.lastReportedDurationSeconds = duration;
    }
  }

  /// 兼容旧版三行状态脚本：进程退出同步 watch_later 后，从进度库复核。
  /// 只接受本次会话启动后的记录，避免旧的 99% 进度误清当前会话。
  Future<bool> _hasPersistedCompletionThreshold(
    PlaybackUiSession session,
    List<String>? lines,
  ) async {
    if (lines == null || lines.length < 2 || lines[1].trim().isEmpty) {
      return false;
    }
    try {
      final progress = await context
          .read<AppState>()
          .progressService
          .getProgress(
            stripUserInfo(lines[1].trim()),
            profileId: context.read<AppState>().mediaSourceId,
          );
      final updatedAt = progress?.updatedAt;
      if (progress == null ||
          updatedAt == null ||
          updatedAt.isBefore(session.statusNotBefore)) {
        return false;
      }
      return progress.hasReachedFraction();
    } on AppException {
      return false;
    }
  }

  bool _isStatusForSession(
    DateTime? statusModifiedAt,
    PlaybackUiSession session,
  ) => statusModifiedAt?.isAfter(session.statusNotBefore) ?? false;

  bool _isOwnedIdleCompletion(
    List<String>? lines, {
    required int expectedLastPos,
    required String? expectedEpoch,
  }) {
    if (expectedEpoch == null) return false;
    return MpvIdleCompletionMarker.parse(lines)?.matches(
          expectedLastPlaylistPos: expectedLastPos,
          expectedLaunchEpoch: expectedEpoch,
        ) ??
        false;
  }

  /// 状态文件是否「新鲜」（最近 [Duration] 内写入）。
  ///
  /// mpv 的 current 脚本在 file-loaded / idle 时写状态文件；「播完」
  /// 的 `-1` 标记只有刚写出（轮询间隔内）才是本次播放的真实结果，
  /// 陈旧文件不应触发清除「继续播放」历史。
  bool _isFreshStatus(
    DateTime? statusModifiedAt, {
    Duration maxAge = const Duration(seconds: 10),
  }) =>
      statusModifiedAt != null &&
      DateTime.now().difference(statusModifiedAt) <= maxAge;

  Future<void> _removePlaybackSession(
    PlaybackUiSession session, {
    required bool terminateProcess,
  }) async {
    if (session.deleting || !_playbackSessions.contains(session)) return;
    session.deleting = true;
    if (mounted) setState(() {});
    final appState = context.read<AppState>();
    final sessionId = session.history.sessionId;
    if (terminateProcess) {
      final termination = await appState.playerService.terminateSession(
        sessionId,
      );
      if (!termination.isSafeToRelaunch) {
        session.deleting = false;
        if (mounted) {
          setState(() {});
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: AppText('无法确认视频播放器身份，已保留会话且未终止进程')),
          );
        }
        return;
      }
    } else {
      appState.playerService.releaseSession(sessionId);
    }
    await appState.playbackHistoryStore.remove(sessionId);
    if (!mounted) return;
    _playbackPresenter.removeVideoSession(session);
    _refreshPlaybackMonitor();
  }

  /// 「继续播放」：进入上次目录全量扫描，定位上次视频索引，
  /// 复用常规播放逻辑（字幕匹配、播放列表切集、进度由 MPV 原生恢复）。
  Future<void> _resumePlaybackSession(PlaybackUiSession session) async {
    if (session.launching || session.deleting) return;
    final history = session.history;

    _directorySearchController.clear();
    _directorySearchFocusNode.unfocus();
    _directoryBrowser.navigateToPath(history.dirCrumbs.join('/'));
    try {
      await _load();
    } on AppException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: AppText(e.message)));
      return;
    }
    if (!mounted) return;

    final videos = _files.where((f) => f.isPlayable).toList();
    if (videos.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: AppText('该目录下没有可播放的视频')));
      return;
    }
    // 优先按文件名定位（strm 解析失败剔除后索引可能错位）；
    // 找不到或目录内容已变化时回退到历史索引（越界取首项）。
    var index = videos.indexWhere((f) => f.name == history.fileName);
    if (index < 0) {
      index = history.videoIndex.clamp(0, videos.length - 1);
    }
    await _playVideo(videos[index], sessionId: history.sessionId);
  }

  Future<void> _openMediaLibrary() async {
    final appState = context.read<AppState>();
    final store = appState.mediaLibraryStore;
    final sourceId = appState.mediaSourceId;
    if (store == null || sourceId == null) {
      _showLibraryError('媒体中心暂时不可用，目录浏览和播放不受影响');
      return;
    }
    final selected = await Navigator.of(context).push<MediaLibraryItem>(
      MaterialPageRoute<MediaLibraryItem>(
        builder: (_) => MediaLibraryPage(
          sourceId: sourceId,
          store: store,
          config: appState.configStore.current.mediaLibrary,
          directoryCache: appState.directoryCache,
          videoProgressService: appState.progressService,
          audioProgressService: appState.audioProgressService,
          resolveUrl: _service.resolveUrl,
        ),
      ),
    );
    if (!mounted) return;
    await _loadFavoriteKeys();
    if (selected != null) await _openLibraryItem(selected);
  }

  Future<void> _openLibraryItem(MediaLibraryItem item) async {
    final sourceId = context.read<AppState>().mediaSourceId;
    if (sourceId == null || item.sourceId != sourceId) {
      _showLibraryError('该条目不属于当前连接来源');
      return;
    }
    final destination = item.kind == MediaLibraryKind.directory
        ? item.targetPath
        : item.normalizedParentPath;
    _changeDirectoryScrollScope(() {
      _directorySearchController.clear();
      _directorySearchFocusNode.unfocus();
      _directoryBrowser.navigateToPath(normalizeLibraryPath(destination));
    });
    await _load();
    if (!mounted || item.kind == MediaLibraryKind.directory) return;
    final file = _files.where(item.matches).firstOrNull;
    if (file == null) {
      _showLibraryError(
        context.l10n.format('未在当前服务器目录中找到「{name}」', {'name': item.name}),
      );
      return;
    }
    _onFileTap(file);
  }

  void _onFileTap(WebDavFile file) {
    if (file.isSelfEntry) {
      // 「返回上级」条目：回到上级目录（根目录时无操作）。
      if (_crumbs.isEmpty) return;
      _backTo(_crumbs.length - 2);
    } else if (file.isDirectory) {
      _enterDirectory(file);
    } else if (file.isAudio) {
      _playAudio(file);
    } else if (file.isPlayable) {
      _playVideo(file);
    }
    // 其他文件：暂无操作（可后续扩展下载/预览）。
  }

  Future<void> _openIndexEntry(OpenListIndexEntry entry) async {
    final destination = entry.isDirectory ? entry.path : entry.parent;
    _changeDirectoryScrollScope(() {
      _directorySearchController.clear();
      _directorySearchFocusNode.unfocus();
      _directoryBrowser.navigateToPath(destination);
    });
    await _load();
    if (!mounted || entry.isDirectory) return;
    final file = _files
        .where((item) => !item.isSelfEntry && item.name == entry.name)
        .firstOrNull;
    if (file == null) {
      _showLibraryError('索引条目已失效，请更新索引后重试');
      return;
    }
    _onFileTap(file);
  }

  // ── UI ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _directorySearchOpen
            ? TextField(
                key: const Key('browser-directory-search'),
                controller: _directorySearchController,
                focusNode: _directorySearchFocusNode,
                contextMenuBuilder: buildClipboardHistoryMenu,
                onChanged: _onDirectorySearchChanged,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText:
                      _directorySearchScope ==
                          DirectorySearchScope.currentDirectory
                      ? '搜索当前目录'
                      : '搜索全部索引（至少 2 个字符）',
                  prefixIcon: const Icon(Icons.search),
                  border: InputBorder.none,
                ),
              )
            : _buildTitle(),
        actions: [
          if (_directorySearchOpen)
            PopupMenuButton<DirectorySearchScope>(
              key: const Key('browser-search-scope'),
              tooltip: context.l10n.text('搜索范围'),
              icon: const Icon(Icons.manage_search),
              initialValue: _directorySearchScope,
              onSelected: (scope) => _changeDirectoryScrollScope(
                () => _directoryBrowser.updateSearchScope(scope),
              ),
              itemBuilder: (context) => [
                CheckedPopupMenuItem(
                  value: DirectorySearchScope.currentDirectory,
                  checked:
                      _directorySearchScope ==
                      DirectorySearchScope.currentDirectory,
                  child: const AppText('当前目录（默认）'),
                ),
                CheckedPopupMenuItem(
                  value: DirectorySearchScope.openListIndex,
                  checked:
                      _directorySearchScope ==
                      DirectorySearchScope.openListIndex,
                  child: const AppText('OpenList 全部索引'),
                ),
              ],
            ),
          PopupMenuButton<String>(
            tooltip: context.l10n.format('排序：{mode} · {direction}', {
              'mode': context.l10n.text(_sortMode.label),
              'direction': context.l10n.text(_sortDirection.label),
            }),
            icon: const Icon(Icons.sort),
            onSelected: (value) {
              _changeDirectoryScrollScope(() {
                switch (value) {
                  case 'mode:name':
                    _directoryBrowser.updateSortMode(FileSortMode.name);
                  case 'mode:modified':
                    _directoryBrowser.updateSortMode(FileSortMode.modified);
                  case 'mode:size':
                    _directoryBrowser.updateSortMode(FileSortMode.size);
                  case 'direction:ascending':
                    _directoryBrowser.updateSortDirection(
                      FileSortDirection.ascending,
                    );
                  case 'direction:descending':
                    _directoryBrowser.updateSortDirection(
                      FileSortDirection.descending,
                    );
                }
              });
            },
            itemBuilder: (context) => [
              const PopupMenuItem<String>(
                enabled: false,
                height: 32,
                child: AppText('排序方式'),
              ),
              for (final mode in FileSortMode.values)
                CheckedPopupMenuItem<String>(
                  value: 'mode:${mode.jsonValue}',
                  checked: mode == _sortMode,
                  enabled: mode != FileSortMode.size || _canSortBySize,
                  child: AppText(mode.label),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem<String>(
                enabled: false,
                height: 32,
                child: AppText('排序顺序'),
              ),
              for (final direction in FileSortDirection.values)
                CheckedPopupMenuItem<String>(
                  value: 'direction:${direction.jsonValue}',
                  checked: direction == _sortDirection,
                  child: Row(
                    children: [
                      Icon(
                        direction == FileSortDirection.ascending
                            ? Icons.arrow_upward
                            : Icons.arrow_downward,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      AppText(direction.label),
                    ],
                  ),
                ),
            ],
          ),
          if (_directorySearchOpen)
            IconButton(
              key: const Key('close-browser-directory-search'),
              icon: const Icon(Icons.close),
              tooltip: context.l10n.text('关闭搜索'),
              onPressed: _closeDirectorySearch,
            )
          else
            IconButton(
              key: const Key('open-browser-directory-search'),
              icon: const Icon(Icons.search),
              tooltip: context.l10n.text('搜索当前目录'),
              onPressed: _openDirectorySearch,
            ),
          IconButton(
            key: const Key('open-media-library'),
            icon: const Icon(Icons.video_library_outlined),
            tooltip: context.l10n.text('媒体中心'),
            onPressed: _openMediaLibrary,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: context.l10n.text('刷新'),
            onPressed: () => _load(force: true),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: context.l10n.text('设置'),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
              );
              if (!mounted) return;
              // 返回后同步可能被设置页清空的历史，并重算显示列表。
              await Future.wait([
                _loadPlaybackSessions(),
                _loadAudioPlaybackSessions(),
                _loadFavoriteKeys(),
              ]);
              if (mounted) setState(() {});
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: context.l10n.text('断开连接'),
            onPressed: () {
              context.read<AppState>().disconnect();
              // 进入登录界面：清空导航栈（BrowserPage 为 pushReplacement
              // 进入，直接 pop 会得到空栈导致黑屏）；已保存的连接配置
              // 保留（disconnect 仅清内存会话），登录页预填原信息，
              // 未修改配置时下次启动仍走自动连接。
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute<void>(builder: (_) => const HomePage()),
                (route) => false,
              );
            },
          ),
        ],
      ),
      body: _buildBody(),
      bottomNavigationBar:
          _playbackSessions.isEmpty && _audioPlaybackSessions.isEmpty
          ? null
          : _buildPlaybackBars(),
    );
  }

  /// 播放会话垂直堆栈：新会话在上，越早创建的会话越靠下。
  Widget _buildPlaybackBars() {
    final displayed = _playbackSessions.reversed.toList();
    final displayedAudio = _audioPlaybackSessions.reversed.toList();
    final bars = <Widget>[
      for (final session in displayedAudio) _buildAudioPlaybackBar(session),
      for (final session in displayed) _buildPlaybackBar(session),
    ];
    final tokens = Theme.of(context).glass;
    return GlassSurface(
      level: GlassSurfaceLevel.raised,
      automaticBorder: false,
      showShadow: false,
      border: Border(top: BorderSide(color: tokens.dividerColor)),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < bars.length; i++) ...[
              if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
              bars[i],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAudioPlaybackBar(AudioPlaybackUiSession session) {
    final history = session.history;
    final sessionId = history.sessionId;
    final dirLabel =
        '${context.l10n.text('音乐')} · '
        '${history.dirCrumbs.isEmpty ? context.l10n.text('根目录') : history.dirCrumbs.join(' / ')}';
    final paused = session.paused;

    final String title;
    final IconData icon;
    final String tooltip;
    final VoidCallback? onPressed;
    if (session.launching) {
      title = '正在打开音频：${history.fileName}';
      icon = Icons.hourglass_top;
      tooltip = '正在打开播放器';
      onPressed = null;
    } else if (paused == false) {
      title = '正在播放音频：${history.fileName}';
      icon = Icons.pause;
      tooltip = '暂停';
      onPressed = () =>
          context.read<AppState>().audioPlayerService?.sendPause(sessionId);
    } else if (paused == true) {
      title = '音频已暂停：${history.fileName}';
      icon = Icons.play_arrow;
      tooltip = '继续播放';
      onPressed = () =>
          context.read<AppState>().audioPlayerService?.sendResume(sessionId);
    } else {
      title = '继续播放音频：${history.fileName}';
      icon = Icons.play_arrow;
      tooltip = '继续播放';
      onPressed = () => _resumeAudioPlaybackSession(session);
    }

    return _PlaybackBar(
      key: ValueKey<String>('audio-playback-bar-$sessionId'),
      title: title,
      dirLabel: dirLabel,
      icon: icon,
      tooltip: tooltip,
      deleting: session.deleting,
      onPressed: onPressed,
      onDelete: () =>
          _removeAudioPlaybackSession(session, terminateProcess: true),
      onSecondaryTapDown: (details) =>
          _showAudioSessionMenu(session, details.globalPosition),
    );
  }

  Future<void> _showAudioSessionMenu(
    AudioPlaybackUiSession session,
    Offset globalPosition,
  ) async {
    if (session.deleting) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem<String>(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline),
              SizedBox(width: 10),
              AppText('删除并关闭音频播放器'),
            ],
          ),
        ),
      ],
    );
    if (selected == 'delete' && mounted) {
      await _removeAudioPlaybackSession(session, terminateProcess: true);
    }
  }

  Widget _buildPlaybackBar(PlaybackUiSession session) {
    final history = session.history;
    final sessionId = history.sessionId;
    final dirLabel = history.dirCrumbs.isEmpty
        ? '根目录'
        : history.dirCrumbs.join(' / ');
    final paused = session.paused;

    final String title;
    final IconData icon;
    final String tooltip;
    final VoidCallback? onPressed;
    if (session.recovering) {
      title = '正在恢复：${history.fileName}';
      icon = Icons.sync;
      tooltip = '正在刷新链接并恢复播放';
      onPressed = null;
    } else if (session.launching) {
      title = '正在打开：${history.fileName}';
      icon = Icons.hourglass_top;
      tooltip = '正在打开播放器';
      onPressed = null;
    } else if (paused == false) {
      title = '正在播放：${history.fileName}';
      icon = Icons.pause;
      tooltip = '暂停';
      onPressed = () =>
          context.read<AppState>().playerService.sendPause(sessionId);
    } else if (paused == true) {
      title = '已暂停：${history.fileName}';
      icon = Icons.play_arrow;
      tooltip = '继续播放';
      onPressed = () =>
          context.read<AppState>().playerService.sendResume(sessionId);
    } else {
      title = '继续播放：${history.fileName}';
      icon = Icons.play_arrow;
      tooltip = '继续播放';
      onPressed = () => _resumePlaybackSession(session);
    }

    return _PlaybackBar(
      key: ValueKey<String>('playback-bar-$sessionId'),
      title: title,
      dirLabel: dirLabel,
      icon: icon,
      tooltip: tooltip,
      deleting: session.deleting,
      onPressed: onPressed,
      onDelete: () => _removePlaybackSession(session, terminateProcess: true),
      onSecondaryTapDown: (details) =>
          _showSessionMenu(session, details.globalPosition),
    );
  }

  Future<void> _showSessionMenu(
    PlaybackUiSession session,
    Offset globalPosition,
  ) async {
    if (session.deleting) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem<String>(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline),
              SizedBox(width: 10),
              AppText('删除并关闭播放器'),
            ],
          ),
        ),
      ],
    );
    if (selected == 'delete' && mounted) {
      await _removePlaybackSession(session, terminateProcess: true);
    }
  }

  Widget _buildTitle() {
    // 面包屑：根 / 目录1 / 目录2（可点击回跳）
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          TextButton(
            onPressed: _crumbs.isEmpty ? null : () => _backTo(-1),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.only(right: 8),
              minimumSize: const Size(0, 40),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              alignment: Alignment.centerLeft,
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.home_outlined, size: 18),
                SizedBox(width: 6),
                AppText('根目录'),
              ],
            ),
          ),
          for (var i = 0; i < _crumbs.length; i++) ...[
            Icon(
              Icons.chevron_right,
              size: 18,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            TextButton(
              onPressed: () => _backTo(i),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              child: AppText(_crumbs[i]),
            ),
          ],
        ],
      ),
    );
  }

  Widget? _buildFileTrailing(WebDavFile file, int index) {
    if (_refreshing && index == 0) {
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (context.read<AppState>().mediaLibraryStore == null) return null;
    final item = _libraryItemForFile(file);
    if (item == null) return null;
    final selected = _favoriteKeys.contains(item.stableKey);
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        key: ValueKey<String>('favorite-${item.stableKey}'),
        tooltip: context.l10n.text(selected ? '取消收藏' : '收藏'),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        iconSize: 20,
        onPressed: () => _toggleFavorite(file),
        icon: Icon(selected ? Icons.star : Icons.star_border),
      ),
    );
  }

  Widget _buildBody() {
    if (_directorySearchOpen &&
        _directorySearchScope == DirectorySearchScope.openListIndex) {
      return _buildIndexSearchBody();
    }
    if (_error != null && _files.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: AppText(_error!, textAlign: TextAlign.center),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => _load(force: true),
              icon: const Icon(Icons.refresh),
              label: const AppText('重试'),
            ),
          ],
        ),
      );
    }

    if (_files.isEmpty && _refreshing) {
      return const Center(child: CircularProgressIndicator());
    }

    final visibleFiles = _visibleFiles;
    final listView = visibleFiles.isEmpty
        ? ListView(
            key: _directoryScrollKey,
            controller: _directoryScrollController,
            // RefreshIndicator 需要可滚动子组件
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              const SizedBox(height: 200),
              Center(
                child: AppText(
                  _directorySearchQuery.trim().isEmpty ? '空目录' : '未找到匹配项',
                ),
              ),
            ],
          )
        : ListView.builder(
            key: _directoryScrollKey,
            controller: _directoryScrollController,
            // ── 高性能虚拟列表：万级条目仅构建可视区 ──
            // 宽窗口条目统一使用紧凑行高；窄窗口继续按标题和副标题
            // 测量原型高度，减少快速滚动时的重复测量。
            prototypeItem: FileTile(file: visibleFiles.first),
            itemCount: visibleFiles.length,
            itemBuilder: (context, index) {
              final file = visibleFiles[index];
              return FileTile(
                file: file,
                onTap: () => _onFileTap(file),
                trailing: _buildFileTrailing(file, index),
              );
            },
          );
    return FileListSurface(
      child: Column(
        children: [
          const FileListHeader(),
          Expanded(
            child: DirectoryWheelScrollRegion(
              controller: _directoryScrollController,
              child: RefreshIndicator(
                onRefresh: () => _load(force: true),
                child: ScrollConfiguration(
                  // 关闭本列表的桌面自动滚动条，避免与显式滚动条重复绘制。
                  behavior: ScrollConfiguration.of(
                    context,
                  ).copyWith(scrollbars: false),
                  child: Scrollbar(
                    key: const ValueKey<String>('directory-scrollbar'),
                    controller: _directoryScrollController,
                    thumbVisibility: true,
                    interactive: true,
                    child: listView,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIndexSearchBody() {
    final query = _directorySearchQuery.trim();
    final results = _directoryBrowser.indexSearchResults;
    final error = _directoryBrowser.indexSearchError;
    Widget content;
    if (query.length < 2) {
      content = const Center(child: AppText('请输入至少 2 个字符后搜索全部索引'));
    } else if (_directoryBrowser.indexSearching && results.isEmpty) {
      content = const Center(child: CircularProgressIndicator());
    } else if (error != null) {
      content = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: AppText(error, textAlign: TextAlign.center),
        ),
      );
    } else if (results.isEmpty) {
      content = const Center(child: AppText('索引中未找到匹配项'));
    } else {
      content = ListView.builder(
        key: _directoryScrollKey,
        controller: _directoryScrollController,
        itemCount: results.length,
        itemBuilder: (context, index) {
          final entry = results[index];
          final file = WebDavFile(
            name: entry.name,
            href: entry.path,
            isDirectory: entry.isDirectory,
            size: entry.size,
          );
          return FileTile(
            file: file,
            subtitle: entry.parent.isEmpty ? '/' : entry.parent,
            metadataColumnText: entry.parentFolderName,
            onTap: () => _openIndexEntry(entry),
          );
        },
      );
    }
    return FileListSurface(
      child: Column(
        children: [
          const FileListHeader(metadataColumnLabel: '所在文件夹'),
          Expanded(child: content),
        ],
      ),
    );
  }
}
