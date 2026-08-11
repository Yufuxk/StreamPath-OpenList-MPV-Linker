import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../core/constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/app_paths.dart';
import '../../core/utils/extension_filter.dart';
import '../../core/utils/file_sort.dart';
import '../../core/utils/url_utils.dart';
import '../../data/models/playback_history.dart';
import '../../data/models/playback_progress.dart';
import '../../data/models/web_dav_file.dart';
import '../../data/models/media_entry.dart';
import '../../domain/services/external_player_service.dart';
import '../../domain/services/playback_activation_guard.dart';
import '../../domain/services/webdav_service.dart';
import '../state/app_state.dart';
import '../widgets/directory_wheel_scroll_region.dart';
import '../widgets/file_tile.dart';
import 'home_page.dart';
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

class _PlaybackUiSession {
  _PlaybackUiSession(this.history)
    : statusNotBefore = history.createdAt,
      lastSyncedPos = history.videoIndex;

  PlaybackHistory history;
  DateTime statusNotBefore;
  int lastSyncedPos;
  int finishPending = 0;
  bool? paused;
  bool syncBusy = false;
  bool deleting = false;
  bool launching = false;
  bool recovering = false;
  final PlaybackActivationGuard activationGuard = PlaybackActivationGuard();
  double? lastReportedPositionSeconds;
  double? lastReportedDurationSeconds;

  List<String> get playlistFileNames => history.playlistFileNames.isEmpty
      ? [history.fileName]
      : history.playlistFileNames;
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
          height: 64,
          color: _hovered
              ? scheme.surfaceContainerHigh
              : scheme.surfaceContainerHighest,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
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
                tooltip: '删除并关闭对应播放器',
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
  /// 当前目录面包屑（每段为目录名；空列表 = 根目录）。
  final List<String> _crumbs = [];

  List<WebDavFile> _files = const [];
  String? _error;
  bool _refreshing = false;
  FileSortMode _sortMode = FileSortMode.name;
  FileSortDirection _sortDirection = FileSortDirection.ascending;
  List<WebDavFile>? _visibleFilesCache;
  List<WebDavFile>? _visibleFilesSource;
  List<String>? _visibleFilesHiddenExtensions;
  FileSortMode? _visibleFilesSortMode;
  FileSortDirection? _visibleFilesSortDirection;
  bool _cachedCanSortBySize = false;

  /// 文件列表与右侧滚动条共用的显式控制器。
  ///
  /// Windows 桌面端默认滚动条依赖 Flutter 为无 controller 的 Scrollable
  /// 临时创建控制器；目录、排序或空目录状态切换时 ListView 会按
  /// PageStorageKey 重建。显式持有控制器可避免滚动条偶发绑定到已销毁的
  /// ScrollPosition，同时仍由 PageStorageKey 分目录恢复滚动位置。
  final ScrollController _directoryScrollController = ScrollController();

  /// 目录加载序号：仅最后一次导航/刷新请求允许更新当前页面。
  /// 防止较早请求晚返回后把新目录内容覆盖掉。
  int _directoryLoadId = 0;

  /// 播放会话（最早创建在前；界面反向绘制，使越早播放越靠下）。
  final List<_PlaybackUiSession> _playbackSessions = [];
  Timer? _playMonitor;
  int _sessionSequence = 0;

  /// MPV 状态目录在应用生命周期内固定，只解析一次，避免播放监控每轮
  /// 重复执行路径探测和可写目录检查。
  late final Future<Directory?> _sessionCacheDirectory;

  /// 播放中动态保护警告的订阅（网络带宽持续不足等）。
  StreamSubscription<String>? _cacheWarningSub;
  StreamSubscription<PlaybackRecoveryEvent>? _playbackRecoverySub;

  @override
  void dispose() {
    _playMonitor?.cancel();
    _cacheWarningSub?.cancel();
    _playbackRecoverySub?.cancel();
    _directoryScrollController.dispose();
    super.dispose();
  }

  WebDAVService get _service => context.read<AppState>().webDavService!;

  String get _currentPath => _crumbs.join('/');

  /// 当前目录列表的内存状态键。
  ///
  /// Flutter 会通过 [PageStorageKey] 自动保存/恢复滚动位置；键只存在于
  /// 当前页面内存中，页面销毁或软件重启后自然清除，不写入本地数据。
  PageStorageKey<String> get _directoryScrollKey => PageStorageKey<String>(
    'directory-scroll:${_sortMode.jsonValue}:'
    '${_sortDirection.jsonValue}:$_currentPath',
  );

  /// 隐藏后缀（用户配置，规范化后小写含点；如 ['.ass']）。
  List<String> get _hiddenExtensions =>
      context.read<AppState>().configStore.current.hiddenExtensions;

  /// 显示列表：应用隐藏后缀过滤；后台全量数据 [\_files] 保持不变，
  /// 保证字幕自动匹配、播放列表切集等功能不受影响。
  List<WebDavFile> get _visibleFiles {
    _ensureVisibleFilesCache();
    return _visibleFilesCache!;
  }

  void _ensureVisibleFilesCache() {
    final hiddenExtensions = _hiddenExtensions;
    if (identical(_visibleFilesSource, _files) &&
        identical(_visibleFilesHiddenExtensions, hiddenExtensions) &&
        _visibleFilesSortMode == _sortMode &&
        _visibleFilesSortDirection == _sortDirection &&
        _visibleFilesCache != null) {
      return;
    }

    final hidden = hiddenExtensions.toSet();
    final visible =
        (hidden.isEmpty
                ? _files
                : _files.where((f) => !shouldHideFile(f, hidden)))
            .toList();
    _cachedCanSortBySize = canSortWebDavFilesBySize(visible);
    _visibleFilesCache = _sortMode == FileSortMode.size && !_cachedCanSortBySize
        ? visible
        : sortedWebDavFiles(
            visible,
            mode: _sortMode,
            direction: _sortDirection,
          );
    _visibleFilesSource = _files;
    _visibleFilesHiddenExtensions = hiddenExtensions;
    _visibleFilesSortMode = _sortMode;
    _visibleFilesSortDirection = _sortDirection;
  }

  bool get _canSortBySize {
    _ensureVisibleFilesCache();
    return _cachedCanSortBySize;
  }

  @override
  void initState() {
    super.initState();
    _sessionCacheDirectory = _resolveSessionCacheDirectory();
    _initLoad();
    _loadPlaybackSessions();
    // 播放中动态保护警告（如网络带宽不足）：SnackBar 展示。
    _cacheWarningSub = context.read<AppState>().cacheWarnings.listen((message) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    });
    _playbackRecoverySub = context
        .read<AppState>()
        .playbackRecoveryEvents
        .listen(_handlePlaybackRecoveryEvent);
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
      ..showSnackBar(SnackBar(content: Text(event.message)));
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
    final sessions = histories.map(_PlaybackUiSession.new).toList();
    setState(() {
      _playbackSessions
        ..clear()
        ..addAll(sessions);
    });
    for (final history in histories) {
      await appState.playerService.restoreSession(
        sessionId: history.sessionId,
        pid: history.playerPid,
        ipcPipeName: history.ipcPipeName,
      );
    }
    _refreshPlaybackMonitor();
  }

  _PlaybackUiSession? _sessionById(String sessionId) {
    for (final session in _playbackSessions) {
      if (session.history.sessionId == sessionId) return session;
    }
    return null;
  }

  String _newSessionId() =>
      'play_${DateTime.now().microsecondsSinceEpoch}_${++_sessionSequence}';

  /// 首帧加载：先同步读缓存秒开，再走网络/缓存编排。
  Future<void> _initLoad() async {
    // 确保配置文件已加载（隐藏后缀过滤生效；配置损坏时回退默认，不阻塞浏览）。
    try {
      await context.read<AppState>().configStore.load();
    } on AppException {
      // 配置损坏时使用默认值。
    }
    if (mounted) {
      setState(() {
        _sortMode = context
            .read<AppState>()
            .configStore
            .current
            .defaultSortMode;
        _sortDirection = context
            .read<AppState>()
            .configStore
            .current
            .defaultSortDirection;
      });
    }
    final cached = _service.cachedDirectory(_currentPath);
    if (cached != null && mounted) {
      setState(() => _files = cached);
    }
    await _load();
  }

  /// 加载当前目录（[force] 为 true 时强制刷新网络）。
  Future<void> _load({bool force = false}) async {
    if (!mounted) return;
    final loadId = ++_directoryLoadId;
    final path = _currentPath;
    setState(() {
      _error = null;
      _refreshing = force;
    });
    try {
      final files = await _service.fetchDirectory(path, forceRefresh: force);
      if (!mounted || loadId != _directoryLoadId || path != _currentPath) {
        return;
      }
      setState(() => _files = files);
    } on AppException catch (e) {
      if (!mounted || loadId != _directoryLoadId || path != _currentPath) {
        return;
      }
      setState(() => _error = e.message);
    } finally {
      if (mounted && loadId == _directoryLoadId) {
        setState(() => _refreshing = false);
      }
    }
  }

  // ── 目录导航 ─────────────────────────────────────────────────

  void _enterDirectory(WebDavFile dir) {
    setState(() {
      _crumbs.add(dir.name);
      _files = const [];
    });
    _load();
  }

  void _backTo(int index) {
    // index 为面包屑位置；切到该层（含其子层移除）。
    setState(() {
      _crumbs.removeRange(index + 1, _crumbs.length);
      _files = const [];
    });
    _load();
  }

  // ── 视频播放联动（自动切集） ─────────────────────────────────

  Future<void> _playVideo(WebDavFile video, {String? sessionId}) async {
    final appState = context.read<AppState>();
    final existingSession = sessionId == null ? null : _sessionById(sessionId);
    if (sessionId == null &&
        _playbackSessions.length >= AppConstants.maxPlaybackSessions) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('播放位置已占满'),
          content: Text(
            '当前最多同时保留 ${AppConstants.maxPlaybackSessions} 个播放会话，'
            '请先关闭或删除一个下边栏后再播放。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('知道了'),
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
          SnackBar(content: Text('无法播放「${video.name}」：strm 内容无效或读取失败')),
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
    final session = existingSession ?? _PlaybackUiSession(history);
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
      ..lastReportedDurationSeconds = null;
    if (mounted) {
      setState(() {
        if (existingSession == null) {
          _playbackSessions.add(session);
          _playbackSessions.sort(
            (a, b) => a.history.createdAt.compareTo(b.history.createdAt),
          );
        }
      });
    }
    final stored = await appState.playbackHistoryStore.upsert(history);
    if (!stored) {
      if (mounted) setState(() => _playbackSessions.remove(session));
      return;
    }

    // 2. 查询播放起点视频的续播进度（失败不阻塞播放）。
    //    进度接近结尾（剩余不足 1 分钟，视为已看完）→ 从头播放，
    //    避免 mpv 从片尾恢复导致秒切下一集。
    PlaybackProgress? progress;
    try {
      progress = await appState.progressService.getProgress(
        entries[playStart].url,
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
      if (!mounted || !_playbackSessions.contains(session)) return;
      final launchedHistory = session.history.copyWith(
        playerPid: result.process.pid,
        ipcPipeName: result.ipcPipeName,
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

      final subtitle = entries[playStart].subtitle;
      final parts = <String>[
        '已启动播放器（${entries.length} 集）',
        if (subtitle != null) '字幕：${subtitle.name}',
        if (progress?.resumeSeconds != null) '续播于 ${progress!.resumeSeconds}s',
      ];
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(parts.join(' · ')),
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
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  void _syncPlaybackSessions() {
    for (final session in List<_PlaybackUiSession>.of(_playbackSessions)) {
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
  Future<void> _syncPlaybackSession(_PlaybackUiSession session) async {
    if (!_playbackSessions.contains(session)) return;
    final names = session.playlistFileNames;
    if (names.isEmpty) return;
    final store = context.read<AppState>().playbackHistoryStore;
    final playerService = context.read<AppState>().playerService;
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
          ExternalPlayerService.sessionStatusFileName(sessionId),
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
          pos == -1 &&
          session.lastSyncedPos == names.length - 1 &&
          _isFreshStatus(statusModifiedAt);
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
      final reachedSortedLast = session.lastSyncedPos == names.length - 1;
      if (pos == -1 && reachedSortedLast && _isFreshStatus(statusModifiedAt)) {
        session.finishPending++;
        if (session.finishPending >= 2) {
          session.finishPending = 0;
          await _removePlaybackSession(session, terminateProcess: false);
        }
      } else {
        session.finishPending = 0;
      }
      return;
    }
    session.finishPending = 0;

    final paused = lines.length >= 3 ? lines[2].trim() == '1' : false;
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
    if (!mounted || !_playbackSessions.contains(session)) return;
    setState(() {});
  }

  /// 只供“MPV 进程已经退出”分支使用；运行中的 99% 不提前隐藏。
  bool _hasReachedCompletionThreshold(
    _PlaybackUiSession session,
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
    _PlaybackUiSession session,
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
    _PlaybackUiSession session,
    List<String>? lines,
  ) async {
    if (lines == null || lines.length < 2 || lines[1].trim().isEmpty) {
      return false;
    }
    try {
      final progress = await context
          .read<AppState>()
          .progressService
          .getProgress(stripUserInfo(lines[1].trim()));
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
    _PlaybackUiSession session,
  ) => statusModifiedAt?.isAfter(session.statusNotBefore) ?? false;

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
    _PlaybackUiSession session, {
    required bool terminateProcess,
  }) async {
    if (session.deleting || !_playbackSessions.contains(session)) return;
    session.deleting = true;
    if (mounted) setState(() {});
    final appState = context.read<AppState>();
    final sessionId = session.history.sessionId;
    if (terminateProcess) {
      await appState.playerService.terminateSession(sessionId);
    } else {
      appState.playerService.releaseSession(sessionId);
    }
    await appState.playbackHistoryStore.remove(sessionId);
    if (!mounted) return;
    setState(() {
      _playbackSessions.remove(session);
    });
    _refreshPlaybackMonitor();
  }

  /// 「继续播放」：进入上次目录全量扫描，定位上次视频索引，
  /// 复用常规播放逻辑（字幕匹配、播放列表切集、进度由 MPV 原生恢复）。
  Future<void> _resumePlaybackSession(_PlaybackUiSession session) async {
    if (session.launching || session.deleting) return;
    final history = session.history;

    setState(() {
      _crumbs
        ..clear()
        ..addAll(history.dirCrumbs);
      _files = const [];
      _error = null;
    });
    try {
      await _load();
    } on AppException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    if (!mounted) return;

    final videos = _files.where((f) => f.isPlayable).toList();
    if (videos.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('该目录下没有可播放的视频')));
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

  void _onFileTap(WebDavFile file) {
    if (file.isSelfEntry) {
      // 「返回上级」条目：回到上级目录（根目录时无操作）。
      if (_crumbs.isEmpty) return;
      _backTo(_crumbs.length - 2);
    } else if (file.isDirectory) {
      _enterDirectory(file);
    } else if (file.isPlayable) {
      _playVideo(file);
    }
    // 其他文件：暂无操作（可后续扩展下载/预览）。
  }

  // ── UI ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _buildTitle(),
        actions: [
          PopupMenuButton<String>(
            tooltip: '排序：${_sortMode.label} · ${_sortDirection.label}',
            icon: const Icon(Icons.sort),
            onSelected: (value) {
              setState(() {
                switch (value) {
                  case 'mode:name':
                    _sortMode = FileSortMode.name;
                  case 'mode:modified':
                    _sortMode = FileSortMode.modified;
                  case 'mode:size':
                    _sortMode = FileSortMode.size;
                  case 'direction:ascending':
                    _sortDirection = FileSortDirection.ascending;
                  case 'direction:descending':
                    _sortDirection = FileSortDirection.descending;
                }
              });
            },
            itemBuilder: (context) => [
              const PopupMenuItem<String>(
                enabled: false,
                height: 32,
                child: Text('排序方式'),
              ),
              for (final mode in FileSortMode.values)
                CheckedPopupMenuItem<String>(
                  value: 'mode:${mode.jsonValue}',
                  checked: mode == _sortMode,
                  enabled: mode != FileSortMode.size || _canSortBySize,
                  child: Text(mode.label),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem<String>(
                enabled: false,
                height: 32,
                child: Text('排序顺序'),
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
                      Text(direction.label),
                    ],
                  ),
                ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: () => _load(force: true),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
              );
              // 返回后重算显示列表（隐藏后缀可能已修改）。
              if (mounted) setState(() {});
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: '断开连接',
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
      bottomNavigationBar: _playbackSessions.isEmpty
          ? null
          : _buildPlaybackBars(),
    );
  }

  /// 播放会话垂直堆栈：新会话在上，越早创建的会话越靠下。
  Widget _buildPlaybackBars() {
    final displayed = _playbackSessions.reversed.toList();
    return Material(
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < displayed.length; i++) ...[
              if (i > 0) const Divider(height: 1),
              _buildPlaybackBar(displayed[i]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPlaybackBar(_PlaybackUiSession session) {
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
    _PlaybackUiSession session,
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
              Text('删除并关闭播放器'),
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
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('根目录'),
          ),
          for (var i = 0; i < _crumbs.length; i++) ...[
            const Text('/'),
            TextButton(
              onPressed: () => _backTo(i),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              child: Text(_crumbs[i]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBody() {
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
              child: Text(_error!, textAlign: TextAlign.center),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => _load(force: true),
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
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
            children: const [
              SizedBox(height: 200),
              Center(child: Text('空目录')),
            ],
          )
        : ListView.builder(
            key: _directoryScrollKey,
            controller: _directoryScrollController,
            // ── 高性能虚拟列表：万级条目仅构建可视区 ──
            // 所有文件项均为单行标题 + 单行副标题，使用原型项固定当前
            // 主题/文字缩放下的布局高度，减少快速滚动时的重复测量。
            prototypeItem: FileTile(file: visibleFiles.first),
            itemCount: visibleFiles.length,
            itemBuilder: (context, index) {
              final file = visibleFiles[index];
              return FileTile(
                file: file,
                onTap: () => _onFileTap(file),
                trailing: _refreshing && index == 0
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
              );
            },
          );
    return DirectoryWheelScrollRegion(
      controller: _directoryScrollController,
      child: RefreshIndicator(
        onRefresh: () => _load(force: true),
        child: ScrollConfiguration(
          // 关闭本列表的桌面自动滚动条，避免与显式滚动条重复绘制。
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: Scrollbar(
            key: const ValueKey<String>('directory-scrollbar'),
            controller: _directoryScrollController,
            thumbVisibility: true,
            interactive: true,
            child: listView,
          ),
        ),
      ),
    );
  }
}
