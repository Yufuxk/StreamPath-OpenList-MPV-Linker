import 'dart:async';
import '../../domain/services/remote_menu_playback_service.dart';
import 'dart:io';

import 'package:flutter/material.dart';

import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../core/constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/app_paths.dart';
import '../../core/utils/file_sort.dart';
import '../../core/utils/url_utils.dart';
import '../../data/local/playback_progress_db.dart';
import '../../data/local/media_library_store.dart';
import '../../data/models/audio_media_entry.dart';
import '../../data/models/audio_playback_history.dart';
import '../../data/models/media_library_item.dart';
import '../../data/models/local_root_config.dart';
import '../../data/models/media_directory_entry.dart';
import '../../data/models/media_source.dart';
import '../../data/models/playback_history.dart';
import '../../data/models/playback_progress.dart';
import '../../data/models/subtitle_item.dart';
import '../../data/models/web_dav_file.dart';
import '../../data/models/media_entry.dart';
import '../../domain/services/external_player_service.dart';
import '../../domain/services/audio_player_service.dart';
import '../../domain/services/iso_playback_service.dart';
import '../../domain/services/local_disc_playback_service.dart';
import '../../domain/services/local_media_source.dart';
import '../../domain/services/mpv_idle_completion_marker.dart';
import '../../domain/services/openlist_index_service.dart';
import '../../domain/services/player_process_controller.dart';
import '../../domain/services/webdav_service.dart';
import '../../domain/services/webdav_media_source_adapter.dart';
import '../../domain/services/webdav_font_matcher.dart';
import '../../domain/repositories/media_directory_source.dart';
import '../controllers/directory_browser_controller.dart';
import '../controllers/directory_scroll_state.dart';
import '../presenters/playback_session_presenter.dart';
import '../state/app_state.dart';
import '../widgets/clipboard_history_menu.dart';
import '../widgets/directory_breadcrumbs.dart';
import '../widgets/directory_file_list.dart';
import '../widgets/file_tile.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/playback_bar.dart';
import 'media_library_page.dart';
import 'settings_page.dart';
import 'storage_root_page.dart';

/// 文件浏览页：WebDAV 目录虚拟列表浏览 + 视频一键外部播放。
///
/// 特性：
///  - `ListView.builder` 虚拟列表，万级文件流畅滚动；
///  - 目录点击异步按需加载子目录（面包屑导航）；
///  - 首帧同步读 Hive 缓存秒开，后台自动刷新；
///  - 视频点击 → 字幕自动匹配 → 查询续播进度 → 调起外部播放器。
class BrowserPage extends StatefulWidget {
  const BrowserPage({
    super.key,
    this.localRoot,
    this.initialLibraryItem,
    this.resumeSessionId,
  });

  final LocalRootConfig? localRoot;
  final MediaLibraryItem? initialLibraryItem;
  final String? resumeSessionId;

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _LocalDiscContinueEntry {
  const _LocalDiscContinueEntry({
    required this.record,
    required this.running,
    required this.paused,
  });

  final MediaLibraryRecord record;
  final bool running;
  final bool? paused;

  String? get titleLabel {
    final snapshot = record.localDiscSession;
    if (snapshot?.currentEdition == null || snapshot?.editionCount == null) {
      return null;
    }
    return 'Title ${snapshot!.currentEdition! + 1}/${snapshot.editionCount}';
  }
}

class _LocalDiscLaunchSelection {
  const _LocalDiscLaunchSelection({required this.mode, this.resumeEdition});

  final LocalDiscLaunchMode mode;
  final int? resumeEdition;
  bool get resumesSavedTitle => resumeEdition != null;
}

class _IsoDialogResult {
  const _IsoDialogResult._({
    required this.launched,
    required this.cancelled,
    this.errorMessage,
    this.launchResult,
  });

  const _IsoDialogResult.launched(IsoPlaybackLaunchResult result)
    : this._(launched: true, cancelled: false, launchResult: result);

  const _IsoDialogResult.cancelled() : this._(launched: false, cancelled: true);

  const _IsoDialogResult.failed(String message)
    : this._(launched: false, cancelled: false, errorMessage: message);

  final bool launched;
  final bool cancelled;
  final String? errorMessage;
  final IsoPlaybackLaunchResult? launchResult;
}

class _IsoTitleSelectionDialog extends StatefulWidget {
  const _IsoTitleSelectionDialog({required this.request, this.menuUnavailableReason});

  final IsoTitleSelectionRequest request;
  final String? menuUnavailableReason;

  @override
  State<_IsoTitleSelectionDialog> createState() =>
      _IsoTitleSelectionDialogState();
}

class _IsoTitleSelectionDialogState extends State<_IsoTitleSelectionDialog> {
  late final List<IsoDiscTitle> _titles = List.of(widget.request.titles);
  late final Set<String> _selected = Set.of(widget.request.selectedMplsIds);

  void _move(int index, int offset) {
    final target = index + offset;
    if (target < 0 || target >= _titles.length) return;
    setState(() {
      final title = _titles.removeAt(index);
      _titles.insert(target, title);
    });
  }

  static String _duration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('iso-title-selection-dialog'),
    title: const AppText('选择 Blu-ray 标题'),
    content: SizedBox(
      width: 620,
      height: 430,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.request.discName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          const AppText('选择要播放的 Title，并用箭头调整虚拟播放列表顺序。'),
          if (widget.menuUnavailableReason != null)
            AppText(widget.menuUnavailableReason!),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.builder(
              itemCount: _titles.length,
              itemBuilder: (context, index) {
                final title = _titles[index];
                final resume = widget.request.resumeByMplsId[title.mplsId];
                final isLast = widget.request.lastMplsId == title.mplsId;
                final details = <String>[
                  '${title.mplsId}.mpls',
                  _duration(title.duration),
                  if (resume != null)
                    context.l10n.format('上次播放 {position}', {
                      'position': _duration(resume.position),
                    }),
                  if (isLast) context.l10n.text('上次所在标题'),
                ];
                return CheckboxListTile(
                  key: Key('iso-title-${title.mplsId}'),
                  value: _selected.contains(title.mplsId),
                  onChanged: (selected) => setState(() {
                    if (selected == true) {
                      _selected.add(title.mplsId);
                    } else {
                      _selected.remove(title.mplsId);
                    }
                  }),
                  title: Text('Title ${title.titleIndex}'),
                  subtitle: Text(details.join(' · ')),
                  secondary: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        key: Key('iso-title-up-${title.mplsId}'),
                        tooltip: context.l10n.text('上移'),
                        onPressed: index == 0 ? null : () => _move(index, -1),
                        icon: const Icon(Icons.arrow_upward),
                      ),
                      IconButton(
                        key: Key('iso-title-down-${title.mplsId}'),
                        tooltip: context.l10n.text('下移'),
                        onPressed: index == _titles.length - 1
                            ? null
                            : () => _move(index, 1),
                        icon: const Icon(Icons.arrow_downward),
                      ),
                    ],
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                );
              },
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const AppText('取消播放'),
      ),
      FilledButton(
        key: const Key('iso-title-play'),
        onPressed: _selected.isEmpty
            ? null
            : () => Navigator.of(context).pop(
                IsoTitleSelection(
                  orderedTitles: List<IsoDiscTitle>.unmodifiable(_titles),
                  selectedMplsIds: Set<String>.unmodifiable(_selected),
                ),
              ),
        child: const AppText('播放所选标题'),
      ),
      if (widget.menuUnavailableReason != null)
        const OutlinedButton(onPressed: null,
          child: AppText('蓝光菜单播放')),
    ],
  );
}

class _IsoStreamingDialog extends StatefulWidget {
  const _IsoStreamingDialog({
    required this.service,
    required this.webDavService,
    required this.file,
    this.remoteMenu = false,
    this.menuUnavailableReason,
  });

  final IsoPlaybackService service;
  final WebDAVService webDavService;
  final WebDavFile file;
  final bool remoteMenu;
  final String? menuUnavailableReason;

  @override
  State<_IsoStreamingDialog> createState() => _IsoStreamingDialogState();
}

class _IsoStreamingDialogState extends State<_IsoStreamingDialog> {
  late IsoPlaybackProgress _progress;
  bool _cancelling = false;

  @override
  void initState() {
    super.initState();
    _progress = IsoPlaybackProgress(
      phase: IsoPlaybackPhase.checkingPlayer,
      fileName: widget.file.name,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    try {
      final result = widget.remoteMenu
          ? await widget.service.startRemoteMenu(
              webDavService: widget.webDavService, file: widget.file,
              onProgress: (progress) {
                if (mounted) setState(() => _progress = progress);
              },
            )
          : await widget.service.start(
        webDavService: widget.webDavService,
        file: widget.file,
        selectTitles: _selectTitles,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      if (!mounted) return;
      Navigator.of(context).pop(
        result == null
            ? const _IsoDialogResult.cancelled()
            : _IsoDialogResult.launched(result),
      );
    } on AppException catch (error) {
      if (!mounted) return;
      Navigator.of(context).pop(_IsoDialogResult.failed(error.message));
    } on FileSystemException {
      if (!mounted) return;
      Navigator.of(context).pop(const _IsoDialogResult.failed('ISO 会话文件读写失败'));
    }
  }

  Future<IsoTitleSelection?> _selectTitles(
    IsoTitleSelectionRequest request,
  ) async {
    if (!mounted) return null;
    final selection = await showGlassDialog<IsoTitleSelection>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _IsoTitleSelectionDialog(request: request,
        menuUnavailableReason: widget.menuUnavailableReason),
    );
    return selection;
  }

  void _cancel() {
    if (_cancelling || (!widget.remoteMenu && _progress.phase == IsoPlaybackPhase.launching)) return;
    setState(() => _cancelling = true);
    widget.service.cancel();
  }

  String _statusText() => switch (_progress.phase) {
    IsoPlaybackPhase.checkingPlayer => '正在检查 MPV 播放器…',
    IsoPlaybackPhase.startingBridge => '正在启动 ISO Bridge…',
    IsoPlaybackPhase.probingStream => '正在探测 ISO 流式读取…',
    IsoPlaybackPhase.parsingTitles => '正在解析 Blu-ray Title/MPLS…',
    IsoPlaybackPhase.selectingTitles => '正在等待标题选择…',
    IsoPlaybackPhase.launching => '正在启动 ISO 播放器…',
    IsoPlaybackPhase.playing => 'ISO 播放器已启动',
  };

  @override
  Widget build(BuildContext context) {
    final canCancel =
        !_cancelling &&
        (widget.remoteMenu || _progress.phase != IsoPlaybackPhase.launching) &&
        _progress.phase != IsoPlaybackPhase.playing;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        key: const Key('iso-streaming-dialog'),
        title: const AppText('ISO 远程播放测试'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText(
                _progress.fileName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 16),
              AppText(_statusText()),
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
              const AppText('仅支持未加密 Blu-ray ISO；播放期间请保持网络连接。'),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const Key('iso-streaming-cancel'),
            onPressed: canCancel ? _cancel : null,
            child: AppText(_cancelling ? '正在取消…' : '取消'),
          ),
        ],
      ),
    );
  }
}

class _BrowserPageState extends State<BrowserPage> {
  late final MediaDirectorySource _source;
  LocalMediaSource? _localSource;
  late final DirectoryBrowserController _directoryBrowser;
  late final PlaybackSessionPresenter _playbackPresenter;
  final TextEditingController _directorySearchController =
      TextEditingController();
  final FocusNode _directorySearchFocusNode = FocusNode();
  Set<String> _favoriteKeys = const {};

  late final DirectoryScrollState _directoryScroll;

  /// MPV 状态目录在应用生命周期内固定，只解析一次，避免播放监控每轮
  /// 重复执行路径探测和可写目录检查。
  late final Future<Directory?> _sessionCacheDirectory;

  /// 播放中动态保护警告的订阅（网络带宽持续不足等）。
  StreamSubscription<String>? _cacheWarningSub;
  StreamSubscription<PlaybackRecoveryEvent>? _playbackRecoverySub;
  IsoPlaybackService? _isoPlaybackService;
  late final LocalDiscPlaybackService _localDiscPlaybackService;
  MediaLibraryStore? _mediaLibraryStore;
  bool _hasLocalDisc = false;
  int _localDiscProbeGeneration = 0;
  int _localDiscContinueGeneration = 0;
  Timer? _localDiscContinueDebounce;
  List<_LocalDiscContinueEntry> _localDiscContinue = const [];

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
    _isoPlaybackService?.removeLibraryProgressListener(
      _handleIsoProgressChanged,
    );
    _localDiscProbeGeneration++;
    _localDiscContinueGeneration++;
    _localDiscContinueDebounce?.cancel();
    _mediaLibraryStore?.removeListener(_scheduleLocalDiscContinueRefresh);
    _localDiscPlaybackService.removeLibraryProgressListener(
      _scheduleLocalDiscContinueRefresh,
    );
    _directorySearchController.dispose();
    _directorySearchFocusNode.dispose();
    _directoryScroll.dispose();
    super.dispose();
  }

  WebDAVService get _service => context.read<AppState>().webDavService!;

  bool get _isLocal => widget.localRoot != null;
  String get _sourceId => _source.descriptor.sourceId;

  Set<String> get _visibleSourceIds {
    final config = context.read<AppState>().configStore.current;
    return {
      _sourceId,
      ...config.localRoots
          .where((root) => root.enabled)
          .map((root) => root.sourceId),
      ...config.profiles.map((profile) => profile.profileId),
    }.where((id) => config.mediaLibrary.includesSource(_sourceId, id)).toSet();
  }

  LocalMediaSource? _localSourceFor(String sourceId) {
    if (sourceId == _sourceId && _localSource != null) return _localSource;
    final appState = context.read<AppState>();
    final root = appState.localRoots
        .where((root) => root.sourceId == sourceId && root.enabled)
        .firstOrNull;
    return root == null ? null : appState.localMediaSource(root);
  }

  String? _libraryTarget(MediaLibraryItem item) {
    if (item.kind == MediaLibraryKind.directory ||
        item.kind == MediaLibraryKind.strm) {
      return null;
    }
    final appState = context.read<AppState>();
    if (item.sourceKind == MediaSourceKind.local) {
      final source = _localSourceFor(item.sourceId);
      if (source == null) return null;
      final isRoot =
          item.kind == MediaLibraryKind.iso &&
          item.parentPath.isEmpty &&
          item.name == source.root.displayName;
      return source.lexicalPath(isRoot ? '' : item.targetPath);
    }
    final profile = appState.configStore.current.profiles
        .where((profile) => profile.profileId == item.sourceId)
        .firstOrNull;
    if (profile == null) return null;
    for (final snapshot in appState.directoryCache.visitedDirectories(
      item.sourceId,
    )) {
      if (normalizeLibraryPath(snapshot.path) != item.normalizedParentPath) {
        continue;
      }
      final file = snapshot.entries.where(item.matches).firstOrNull;
      if (file != null) {
        return stripUserInfo(resolveHref(profile.serverUrl, file.href));
      }
    }
    return null;
  }

  List<String> get _crumbs => _directoryBrowser.crumbs;
  List<MediaDirectoryEntry> get _files => _directoryBrowser.files;
  String? get _error => _directoryBrowser.error;
  bool get _refreshing => _directoryBrowser.refreshing;
  FileSortMode get _sortMode => _directoryBrowser.sortMode;
  FileSortDirection get _sortDirection => _directoryBrowser.sortDirection;
  bool get _directorySearchOpen => _directoryBrowser.searchOpen;
  String get _directorySearchQuery => _directoryBrowser.searchQuery;
  DirectorySearchScope get _directorySearchScope =>
      _directoryBrowser.searchScope;
  String get _currentPath => _directoryBrowser.currentPath;
  List<MediaDirectoryEntry> get _visibleFiles => _directoryBrowser.visibleFiles;
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

  ScrollController get _directoryScrollController =>
      _directoryScroll.controller;

  void _rememberDirectoryScroll() {
    _directoryScroll.remember(_directoryScrollCacheKey);
  }

  void _scheduleDirectoryScrollRestore() {
    final key = _directoryScrollCacheKey;
    _directoryScroll.scheduleRestore(
      key: key,
      isCurrent: () => mounted && key == _directoryScrollCacheKey,
    );
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
    _localDiscPlaybackService = appState.localDiscPlaybackService;
    _mediaLibraryStore = appState.mediaLibraryStore;
    _isoPlaybackService = appState.isoPlaybackService;
    final localRoot = widget.localRoot;
    if (localRoot == null) {
      _source = WebDavMediaSourceAdapter(_service);
      _isoPlaybackService = appState.isoPlaybackService;
    } else {
      _localSource = appState.localMediaSource(localRoot);
      _source = _localSource!;
    }
    _mediaLibraryStore?.addListener(_scheduleLocalDiscContinueRefresh);
    _localDiscPlaybackService.addLibraryProgressListener(
      _scheduleLocalDiscContinueRefresh,
    );
    final expirationStore = appState.cacheExpirationConfigStore;
    _directoryScroll = DirectoryScrollState(
      maxEntries: AppConstants.maxDirectoryScrollEntries,
      idleTtl: AppConstants.directoryScrollRetention,
      idleTtlProvider: expirationStore == null
          ? null
          : () => expirationStore.current.directoryScrollRetention,
    );
    _directoryBrowser = DirectoryBrowserController(
      service: _source,
      configStore: appState.configStore,
      onDirectoryLoaded: _recordRecentDirectory,
      onForcedRefresh: _isLocal
          ? null
          : appState.playerService.captureOpenListProcessIdentity,
      openListIndexSearch: _isLocal ? null : appState.searchOpenListIndex,
    )..addListener(_handleDirectoryBrowserChanged);
    _playbackPresenter = PlaybackSessionPresenter()
      ..addListener(_handlePlaybackPresenterChanged);
    _isoPlaybackService?.addLibraryProgressListener(_handleIsoProgressChanged);
    _sessionCacheDirectory = _resolveSessionCacheDirectory();
    _initLoad(
      Future.wait([_loadPlaybackSessions(), _loadAudioPlaybackSessions()]),
    );
    _loadFavoriteKeys();
    _refreshLocalDiscContinue();
    if (_isLocal) {
      _refreshLocalDiscState();
    }
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

  void _handleIsoProgressChanged() {
    if (!mounted) return;
    _syncPlaybackSessions();
  }

  void _scheduleLocalDiscContinueRefresh() {
    if (!mounted) return;
    _localDiscContinueDebounce?.cancel();
    _localDiscContinueDebounce = Timer(const Duration(milliseconds: 120), () {
      unawaited(_refreshLocalDiscContinue());
    });
  }

  Future<void> _refreshLocalDiscContinue() async {
    final generation = ++_localDiscContinueGeneration;
    final store = _mediaLibraryStore;
    if (store == null) return;
    try {
      final history =
          (await Future.wait([
              for (final id in _visibleSourceIds.where(
                (id) => id.startsWith('local:'),
              ))
                store.playbackHistory(id, audio: false, iso: true),
            ])).expand((records) => records).toList()
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      final entries = <_LocalDiscContinueEntry>[];
      for (final record in history.where(
        (record) => !record.continueDismissed && !record.playbackBarDismissed,
      )) {
        final relativePath =
            record.localDiscSession?.relativePath ??
            (_isRootLocalDiscItem(record.item) ? '' : record.item.targetPath);
        try {
          final source = _localSourceFor(record.item.sourceId);
          if (source == null) continue;
          await source.resolveDiscDevice(relativePath);
          final sessionId = record.playbackSessionId;
          final status = sessionId == null
              ? const LocalDiscSessionStatus(running: false)
              : await _localDiscPlaybackService.sessionStatus(sessionId);
          entries.add(
            _LocalDiscContinueEntry(
              record: record,
              running: status.running,
              paused: status.paused,
            ),
          );
          if (entries.length >= store.config.normalized.maxContinuePerLane) {
            break;
          }
        } on AppException {
          // 已移动或失效的本地蓝光不显示为可续播项。
        }
      }
      if (!mounted || generation != _localDiscContinueGeneration) return;
      setState(() => _localDiscContinue = List.unmodifiable(entries));
    } catch (error) {
      if (!mounted || generation != _localDiscContinueGeneration) return;
      _showLibraryError('读取本地蓝光续播记录失败：$error');
    }
  }

  Future<void> _refreshLocalDiscState() async {
    if (!_isLocal) return;
    final generation = ++_localDiscProbeGeneration;
    final path = _currentPath;
    final hasDisc = await _localSource!.hasDiscAt(path);
    if (!mounted ||
        generation != _localDiscProbeGeneration ||
        path != _currentPath) {
      return;
    }
    if (_hasLocalDisc != hasDisc) setState(() => _hasLocalDisc = hasDisc);
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
    final store = context.read<AppState>().mediaLibraryStore;
    final sourceId = _sourceId;
    if (store == null) return;
    try {
      final favorites = await store.favorites(sourceId);
      if (!mounted || sourceId != _sourceId) return;
      setState(() {
        _favoriteKeys = favorites
            .map((record) => record.item.stableKey)
            .toSet();
      });
    } catch (_) {
      // 个人资产读取失败不阻止目录浏览和播放。
    }
  }

  MediaLibraryItem? _libraryItemForFile(
    MediaDirectoryEntry file, {
    String? parentPath,
    PlaybackMode? playbackMode,
  }) {
    final kind = MediaLibraryKindX.fromEntry(file);
    if (kind == null) return null;
    return MediaLibraryItem(
      sourceId: _sourceId,
      sourceKind: _source.descriptor.kind,
      playbackMode: playbackMode ?? (_isLocal
          ? PlaybackMode.localFile
          : PlaybackMode.legacyTitle),
      parentPath: parentPath ?? _currentPath,
      name: file.name,
      kind: kind,
    );
  }

  Future<void> _toggleFavorite(MediaDirectoryEntry file) async {
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
    final store = context.read<AppState>().mediaLibraryStore;
    if (store == null) return;
    final segments = normalized.split('/');
    final item = MediaLibraryItem(
      sourceId: _sourceId,
      sourceKind: _source.descriptor.kind,
      playbackMode: _isLocal
          ? PlaybackMode.localFile
          : PlaybackMode.legacyTitle,
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
    MediaDirectoryEntry file, {
    required String parentPath,
    required String playbackSessionId,
    PlaybackMode? playbackMode,
  }) async {
    final item = _libraryItemForFile(file, parentPath: parentPath,
      playbackMode: playbackMode);
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
    String? playbackSourceId,
  }) async {
    final appState = context.read<AppState>();
    final store = appState.mediaLibraryStore;
    final sourceId = playbackSourceId ?? _sourceId;
    if (store == null) return;
    final parentPath = normalizeLibraryPath(dirCrumbs.join('/'));
    MediaDirectoryEntry? matched;
    if (sourceId == _sourceId &&
        normalizeLibraryPath(_currentPath) == parentPath) {
      matched = _files
          .where((file) => file.name == fileName && !file.isDirectory)
          .firstOrNull;
    }
    if (matched == null && !sourceId.startsWith('local:')) {
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
        : MediaLibraryKindX.fromEntry(matched);
    if (kind == null || !kind.isMedia) return;
    final item = MediaLibraryItem(
      sourceId: sourceId,
      sourceKind: sourceId.startsWith('local:')
          ? MediaSourceKind.local
          : MediaSourceKind.webdav,
      playbackMode: sourceId.startsWith('local:')
          ? PlaybackMode.localFile
          : PlaybackMode.legacyTitle,
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
    final histories = (await appState.playbackHistoryStore.loadAll())
        .where(
          (history) =>
              _visibleSourceIds.contains(history.sourceId) ||
              (!_isLocal && history.sourceId == null),
        )
        .toList();
    if (!mounted) return;
    _playbackPresenter.replaceVideoSessions(histories);
    for (final history in histories) {
      if (history.kind == PlaybackHistoryKind.iso) continue;
      await appState.playerService.restoreSession(
        sessionId: history.sessionId,
        profileId: history.sourceId,
        pid: history.playerPid,
        executablePath: history.playerExecutablePath,
        creationTime: history.playerCreationTime,
        ipcPipeName: history.ipcPipeName,
        launchEpoch: history.launchEpoch,
      );
    }
    _refreshPlaybackMonitor();
    _syncPlaybackSessions();
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
    final histories = (await store.loadAll())
        .where(
          (history) =>
              _visibleSourceIds.contains(history.sourceId) ||
              (!_isLocal && history.sourceId == null),
        )
        .toList();
    if (!mounted) return;
    _playbackPresenter.replaceAudioSessions(histories);
    for (final history in histories) {
      await player.restoreSession(
        sessionId: history.sessionId,
        profileId: history.sourceId,
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
  Future<void> _initLoad(Future<void> sessionsLoaded) async {
    await _directoryBrowser.initialize();
    if (_isLocal) await _refreshLocalDiscState();
    if (mounted) _scheduleDirectoryScrollRestore();
    if (mounted && widget.initialLibraryItem != null) {
      await sessionsLoaded;
      if (!mounted) return;
      await _openLibraryItem(
        widget.initialLibraryItem!,
        resumeSessionId: widget.resumeSessionId,
      );
    }
  }

  /// 加载当前目录（[force] 为 true 时强制刷新网络）。
  Future<void> _load({bool force = false}) async {
    await _directoryBrowser.load(force: force);
    if (_isLocal) await _refreshLocalDiscState();
    if (mounted) _scheduleDirectoryScrollRestore();
  }

  // ── 目录导航 ─────────────────────────────────────────────────

  void _enterDirectory(MediaDirectoryEntry dir) {
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

  // ── Blu-ray ISO 远程流式播放入口 ────────────────────────────

  bool _isRootLocalDiscItem(MediaLibraryItem item) {
    final root = widget.localRoot;
    return root != null &&
        item.kind == MediaLibraryKind.iso &&
        item.normalizedParentPath.isEmpty &&
        item.name == root.displayName;
  }

  Future<MediaLibraryRecord?> _findLocalDiscContinueRecord(
    MediaLibraryItem item,
  ) async {
    final store = _mediaLibraryStore;
    if (store == null) return null;
    final history = await store.playbackHistory(
      _sourceId,
      audio: false,
      iso: true,
    );
    return history
        .where(
          (record) =>
              !record.continueDismissed &&
              record.item.stableKey == item.stableKey,
        )
        .firstOrNull;
  }

  Future<void> _recordLocalDiscPlayback(
    MediaLibraryItem item,
    String sessionId,
    LocalDiscSessionSnapshot snapshot,
  ) async {
    final store = _mediaLibraryStore;
    if (store == null) return;
    try {
      await store.recordPlayback(
        item,
        playbackSessionId: sessionId,
        localDiscSession: snapshot,
      );
    } catch (error) {
      _showLibraryError('保存最近播放失败：$error');
    }
  }

  Future<void> _playLocalDisc({
    required String relativePath,
    required String displayName,
    MediaLibraryRecord? continueRecord,
  }) async {
    final root = widget.localRoot!;
    late final String devicePath;
    try {
      devicePath = await _localSource!.resolveDiscDevice(relativePath);
      final snapshot = continueRecord?.localDiscSession;
      if (snapshot != null &&
          !await LocalDiscPlaybackService.matchesSnapshot(
            snapshot: snapshot,
            devicePath: devicePath,
          )) {
        continueRecord = null;
        _showLibraryError('本地蓝光内容已变更，已忽略旧续播位置');
      }
    } on AppException catch (error) {
      _showLibraryError(error.message);
      return;
    }
    if (!mounted) return;
    final resumeSnapshot = continueRecord?.localDiscSession;
    final resumeEdition = resumeSnapshot?.currentEdition;
    final selection = await showDialog<_LocalDiscLaunchSelection>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: AppText(displayName),
        content: AppText(
          resumeEdition == null
              ? '请选择本地 Blu-ray 的播放方式。菜单失败时不会自动切换模式。'
              : '可继续上次播放的 Title，也可以从头打开菜单或主标题。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const AppText('取消'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.of(dialogContext).pop(
              const _LocalDiscLaunchSelection(
                mode: LocalDiscLaunchMode.longestTitle,
              ),
            ),
            child: const AppText('主标题模式'),
          ),
          if (resumeEdition != null)
            OutlinedButton(
              onPressed: () => Navigator.of(dialogContext).pop(
                const _LocalDiscLaunchSelection(mode: LocalDiscLaunchMode.menu),
              ),
              child: const AppText('从头打开菜单'),
            ),
          OutlinedButton(
            onPressed: () => Navigator.of(dialogContext).pop(
              _LocalDiscLaunchSelection(
                mode: LocalDiscLaunchMode.menu,
                resumeEdition: resumeEdition,
              ),
            ),
            child: AppText(resumeEdition == null ? '蓝光菜单播放' : '继续上次标题'),
          ),
        ],
      ),
    );
    if (!mounted || selection == null) return;
    try {
      final discRelativePath = _localSource!.discRelativePath(devicePath);
      final result = await _localDiscPlaybackService.launch(
        rootId: root.rootId,
        relativePath: discRelativePath,
        devicePath: devicePath,
        mode: selection.mode,
        resumeFromSavedPosition: selection.resumesSavedTitle,
        resumeEdition: selection.resumeEdition,
        expectedFingerprint: selection.resumesSavedTitle
            ? resumeSnapshot?.fingerprint
            : null,
      );
      final normalized = normalizeLibraryPath(discRelativePath);
      final segments = normalized.isEmpty
          ? const <String>[]
          : normalized.split('/');
      final item = MediaLibraryItem(
        sourceId: _sourceId,
        sourceKind: MediaSourceKind.local,
        playbackMode: PlaybackMode.localHdmvMenu,
        parentPath: segments.length <= 1
            ? ''
            : segments.sublist(0, segments.length - 1).join('/'),
        name: segments.isEmpty ? root.displayName : segments.last,
        kind: MediaLibraryKind.iso,
      );
      await _recordLocalDiscPlayback(
        item,
        result.sessionId,
        LocalDiscSessionSnapshot(
          rootId: result.rootId,
          relativePath: result.relativePath,
          size: result.size,
          modified: result.modified,
          fingerprint: result.fingerprint,
          playerPid: result.processIdentity?.pid,
          playerExecutablePath: result.processIdentity?.executablePath,
          playerCreationTime: result.processIdentity?.creationTime,
          currentEdition: selection.resumeEdition,
          editionCount: selection.resumesSavedTitle
              ? resumeSnapshot?.editionCount
              : null,
        ),
      );
      if (continueRecord != null) {
        await _mediaLibraryStore?.removePlaybackRecord(continueRecord);
      }
      await _refreshLocalDiscContinue();
      _showLibraryError('本地蓝光播放器已启动');
    } on AppException catch (error) {
      _showLibraryError(error.message);
    }
  }

  Future<void> _playIso(WebDavFile file, {String? sessionId,
    bool titleOnly = false}) async {
    final appState = context.read<AppState>();
    final isoService = appState.isoPlaybackService;
    final webDavService = appState.webDavService;
    if (isoService == null || webDavService == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: AppText('ISO 远程播放测试模块初始化失败，视频和音频播放不受影响')),
      );
      return;
    }
    final existingSession = sessionId == null ? null : _sessionById(sessionId);
    if (existingSession != null &&
        existingSession.history.kind != PlaybackHistoryKind.iso) {
      return;
    }
    if (sessionId == null &&
        _playbackSessions
                .where(
                  (session) =>
                      (session.history.sourceId ?? _sourceId) == _sourceId,
                )
                .length >=
            AppConstants.maxPlaybackSessions) {
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
    if (isoService.isBusy) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: AppText('ISO 远程播放测试模块正在执行其他任务')));
      return;
    }

    var remoteMenu = false;
    var menuReason = titleOnly ? 'disabled' : await isoService.remoteMenu.unavailableReason();
    if (!mounted) return;
    while (!titleOnly && (menuReason == null || menuReason == RemoteMenuPlaybackService.runtimeMissing)) {
      final mode = await showGlassDialog<Object>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: AppText(file.name),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const AppText('请选择 Blu-ray 播放方式。菜单模式仅支持 HDMV，失败时不会自动切换。'),
              if (menuReason != null) ...[const SizedBox(height: 12), AppText(menuReason)],
              ...[
                const SizedBox(height: 12),
                const SelectableText('WinFsp - Windows File System Proxy\nCopyright (C) Bill Zissimopoulos\nhttps://github.com/winfsp/winfsp', style: TextStyle(fontSize: 11)),
              ],
            ]),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(),
              child: const AppText('取消')),
            OutlinedButton(autofocus: true,
              onPressed: () => Navigator.of(dialogContext).pop(PlaybackMode.legacyTitle),
              child: const AppText('标题/播放列表模式')),
            OutlinedButton(
              onPressed: menuReason == null ? () => Navigator.of(dialogContext).pop(PlaybackMode.webdavHdmvMenu) : null,
              child: const AppText('蓝光菜单播放')),
            if (menuReason == RemoteMenuPlaybackService.runtimeMissing)
              OutlinedButton(onPressed: () => Navigator.of(dialogContext).pop('install'),
                child: const AppText('安装 WinFsp 运行时')),
          ],
        ),
      );
      if (!mounted || mode == null) return;
      if (mode == 'install') {
        try {
          await isoService.remoteMenu.installRuntime();
          menuReason = await isoService.remoteMenu.unavailableReason();
        } on AppException catch (error) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: AppText(error.message)));
          return;
        }
        if (!mounted) return;
        continue;
      }
      remoteMenu = mode == PlaybackMode.webdavHdmvMenu;
      break;
    }
    final result = await showGlassDialog<_IsoDialogResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _IsoStreamingDialog(
        service: isoService,
        webDavService: webDavService,
        file: file,
        remoteMenu: remoteMenu,
        menuUnavailableReason: titleOnly ? null : menuReason,
      ),
    );
    if (!mounted || result == null) return;
    if (result.launched) {
      final launch = result.launchResult!;
      final resolvedSessionId = sessionId ?? _newSessionId();
      final now = DateTime.now();
      final history = PlaybackHistory(
        sessionId: resolvedSessionId,
        dirCrumbs: List<String>.of(_crumbs),
        fileName: file.name,
        videoIndex: 0,
        updatedAt: now,
        createdAt: existingSession?.history.createdAt ?? now,
        playlistFileNames: [file.name],
        playerPid: launch.playerIdentity.pid,
        playerExecutablePath: launch.playerIdentity.executablePath,
        playerCreationTime: launch.playerIdentity.creationTime,
        kind: PlaybackHistoryKind.iso,
        isoKey: launch.isoKey,
        playbackMode: launch.playbackMode,
        isoSessionDirectoryPath: launch.sessionDirectoryPath,
        sourceId: _sourceId,
      );
      final session = existingSession ?? PlaybackUiSession(history);
      session
        ..history = history
        ..lastSyncedPos = 0
        ..paused = false
        ..launching = false;
      if (existingSession == null) {
        _playbackPresenter.addVideoSession(session);
      }
      final stored = await appState.playbackHistoryStore.upsert(history);
      if (!stored) {
        await isoService.terminateSession(launch.sessionDirectoryPath);
        if (mounted) _playbackPresenter.removeVideoSession(session);
        return;
      }
      if (!mounted) return;
      unawaited(
        _recordPlaybackFile(
          file,
          parentPath: _currentPath,
          playbackSessionId: resolvedSessionId,
          playbackMode: launch.playbackMode,
        ),
      );
      _refreshPlaybackMonitor();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: AppText('ISO 播放器已启动，关闭 MPV 后将清理会话文件')),
      );
      return;
    }
    if (result.cancelled) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: AppText('已取消 ISO 播放')));
      return;
    }
    final errorMessage = result.errorMessage ?? '未知错误';
    if (remoteMenu) {
      final returnToTitles = await showGlassDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const AppText('蓝光菜单播放失败'),
          content: AppText(errorMessage),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const AppText('取消')),
            OutlinedButton(onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const AppText('返回选择标题模式')),
          ],
        ),
      );
      if (mounted && returnToTitles == true) {
        await _playIso(file, sessionId: sessionId, titleOnly: true);
      }
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.l10n.format('ISO 流式播放失败：{message}', {
            'message': context.l10n.text(errorMessage),
          }),
        ),
      ),
    );
  }

  // ── 视频播放联动（自动切集） ─────────────────────────────────

  Future<SubtitleItem?> _resolvedSubtitleFor(MediaDirectoryEntry video) async {
    final appState = context.read<AppState>();
    if (!appState.configStore.current.subtitleInjectionEnabled) return null;
    final match = appState.subtitleMatcher.findBestFor(video, _files);
    if (match == null || !_isLocal) return match;
    final subtitleEntry = _files
        .where((entry) => entry.entryKey == match.url)
        .firstOrNull;
    if (subtitleEntry == null) return null;
    final target = await _source.resolve(subtitleEntry);
    if (target is! LocalMediaOpenTarget) return null;
    return SubtitleItem(
      name: match.name,
      url: target.path,
      language: match.language,
      score: match.score,
    );
  }

  Future<WebDavFontDirectory?> _resolvedWebDavFontsFor(
    MediaDirectoryEntry video,
  ) async {
    if (_isLocal) return null;
    final appState = context.read<AppState>();
    if (!appState.configStore.current.subtitleInjectionEnabled) return null;
    final service = _service;
    final match = appState.webDavFontMatcher.findBestFor(
      video,
      _files,
      baseUrl: service.baseUrl,
    );
    if (match == null) return null;
    try {
      final entries = await service.fetchDirectory(match.requestPath);
      final resolved = appState.webDavFontMatcher.withDirectFontFiles(
        match,
        entries,
        baseUrl: service.baseUrl,
      );
      return resolved.files.isEmpty ? null : resolved;
    } on AppException {
      return null;
    }
  }

  Future<String> _resolvedMediaUrl(MediaDirectoryEntry entry) async {
    final target = await _source.resolve(entry);
    return switch (target) {
      WebDavMediaOpenTarget(:final url) => url,
      LocalMediaOpenTarget(:final path) => path,
    };
  }

  Future<AudioCompanionFile?> _resolvedAudioCompanion(
    AudioCompanionFile? companion,
  ) async {
    if (companion == null) return null;
    if (!_isLocal) {
      return AudioCompanionFile(
        name: companion.name,
        url: _service.resolveUrl(companion.url),
      );
    }
    final entry = _files
        .where((item) => item.entryKey == companion.url)
        .firstOrNull;
    if (entry == null) return null;
    final target = await _source.resolve(entry);
    return target is LocalMediaOpenTarget
        ? AudioCompanionFile(name: companion.name, url: target.path)
        : null;
  }

  Future<void> _playVideo(
    MediaDirectoryEntry video, {
    String? sessionId,
  }) async {
    final appState = context.read<AppState>();
    final libraryParentPath = _currentPath;
    final existingSession = sessionId == null ? null : _sessionById(sessionId);
    if (sessionId == null &&
        _playbackSessions
                .where(
                  (session) =>
                      (session.history.sourceId ?? _sourceId) == _sourceId,
                )
                .length >=
            AppConstants.maxPlaybackSessions) {
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
    final videos = _files
        .where((file) => _isLocal ? file.isVideo : file.isPlayable)
        .toList();
    final startIndex = videos.indexWhere(
      (file) => file.entryKey == video.entryKey,
    );
    final ordered = (startIndex < 0 ? [video] : videos);

    // strm 流指针条目：分批并发预取指向的真实媒体地址（每批限流，
    // 避免大量 strm 打爆服务器）；解析失败的条目从播放列表剔除。
    final strmUrls = <String, String>{};
    final strmFiles = ordered
        .whereType<WebDavFile>()
        .where((f) => f.isStrm)
        .toList();
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
      final String? url = v is WebDavFile && v.isStrm
          ? strmUrls[v.href]
          : await _resolvedMediaUrl(v);
      if (url == null) continue;
      if (v.entryKey == video.entryKey) clickedIndex = entries.length;
      entries.add(
        MediaEntry(
          url: url,
          title: v.name,
          subtitle: subtitleInjectionEnabled
              ? await _resolvedSubtitleFor(v)
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
        .where(
          (v) =>
              v is WebDavFile && v.isStrm ? strmUrls.containsKey(v.href) : true,
        )
        .toList();
    final resolvedSessionId = sessionId ?? _newSessionId();
    final webDavFonts = await _resolvedWebDavFontsFor(video);
    final now = DateTime.now();
    final history = PlaybackHistory(
      sessionId: resolvedSessionId,
      dirCrumbs: List.of(_crumbs),
      fileName: activeVideos[playStart].name,
      videoIndex: playStart,
      updatedAt: now,
      createdAt: existingSession?.history.createdAt ?? now,
      playlistFileNames: activeVideos.map((v) => v.name).toList(),
      sourceId: _sourceId,
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
        profileId: _sourceId,
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
      final result = _isLocal
          ? await appState.playerService.launchLocal(
              entries: entries,
              sourceId: _sourceId,
              sessionId: resolvedSessionId,
              playlistStart: playStart,
              resumeSeconds: progress?.resumeSeconds,
            )
          : await appState.playerService.launch(
              entries: entries,
              sessionId: resolvedSessionId,
              playlistStart: playStart,
              resumeSeconds: progress?.resumeSeconds,
              username: appState.username,
              password: appState.password,
              webDavFonts: webDavFonts,
              webDavFontLoader: _service.fetchFileBytes,
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

  Future<void> _playAudio(
    MediaDirectoryEntry audio, {
    String? sessionId,
  }) async {
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
        _audioPlaybackSessions
                .where(
                  (session) =>
                      (session.history.sourceId ?? _sourceId) == _sourceId,
                )
                .length >=
            AppConstants.maxPlaybackSessions) {
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
      (file) => file.entryKey == audio.entryKey,
    );
    final ordered = clickedIndex < 0 ? [audio] : audioFiles;
    final subtitleInjectionEnabled =
        appState.configStore.current.subtitleInjectionEnabled;
    final entries = <AudioMediaEntry>[];
    var playStart = -1;
    for (final file in ordered) {
      if (file.entryKey == audio.entryKey) playStart = entries.length;
      final lyrics = subtitleInjectionEnabled
          ? appState.audioCompanionMatcher.findLyricsFor(file, _files)
          : null;
      final cover = appState.audioCompanionMatcher.findCoverFor(file, _files);
      entries.add(
        AudioMediaEntry(
          url: await _resolvedMediaUrl(file),
          title: file.name,
          lyrics: await _resolvedAudioCompanion(lyrics),
          coverArt: await _resolvedAudioCompanion(cover),
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
      sourceId: _sourceId,
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
      if (!_isLocal) {
        await player.syncPersistedProgress(
          sessionId: resolvedSessionId,
          entries: entries,
          username: appState.username,
          password: appState.password,
          launchEpoch: existingSession?.history.launchEpoch,
        );
      }
      progress = await progressService.getProgress(
        entries[playStart].url,
        profileId: _sourceId,
      );
      if (progress != null && progress.isFinishedNearEnd()) progress = null;
    } on AppException {
      // 音频进度读取失败时从头播放，视频链路不受影响。
    }

    try {
      session.statusNotBefore = DateTime.now();
      final result = _isLocal
          ? await player.launchLocal(
              entries: entries,
              sessionId: resolvedSessionId,
              sourceId: _sourceId,
              playlistStart: playStart,
              resumeSeconds: progress?.resumeSeconds,
            )
          : await player.launch(
              entries: entries,
              sessionId: resolvedSessionId,
              playlistStart: playStart,
              resumeSeconds: progress?.resumeSeconds,
              username: appState.username,
              password: appState.password,
              lyricsLoader: (url, {required maxBytes, required timeout}) =>
                  _service.fetchFileBytes(
                    url,
                    maxBytes: maxBytes,
                    timeout: timeout,
                  ),
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
        profileId: session.history.sourceId ?? _sourceId,
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
        playbackSourceId: session.history.sourceId,
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
        profileId: session.history.sourceId ?? _sourceId,
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
    if (history.sourceId != null && history.sourceId != _sourceId) {
      await _openLibraryItem(
        MediaLibraryItem(
          sourceId: history.sourceId!,
          sourceKind: history.sourceId!.startsWith('local:')
              ? MediaSourceKind.local
              : MediaSourceKind.webdav,
          parentPath: history.dirCrumbs.join('/'),
          name: history.fileName,
          kind: MediaLibraryKind.audio,
        ),
        resumeSessionId: history.sessionId,
      );
      return;
    }
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
      final operation = session.history.kind == PlaybackHistoryKind.iso
          ? _syncIsoPlaybackSession(session)
          : _syncPlaybackSession(session);
      unawaited(
        operation.whenComplete(() {
          session.syncBusy = false;
          _refreshPlaybackMonitor();
        }),
      );
    }
  }

  Future<void> _syncIsoPlaybackSession(PlaybackUiSession session) async {
    if (!_playbackSessions.contains(session)) return;
    final appState = context.read<AppState>();
    final service = appState.isoPlaybackService;
    if (service == null) return;
    final history = session.history;
    final snapshot = await service.sessionSnapshot(
      history.isoSessionDirectoryPath,
    );
    if (!_playbackSessions.contains(session)) return;
    if (snapshot.liveness == PlayerProcessLiveness.unknown) return;
    if (snapshot.liveness == PlayerProcessLiveness.alive) {
      final paused = snapshot.paused;
      if (paused != null && paused != session.paused && mounted) {
        setState(() => session.paused = paused);
      }
      return;
    }
    final failureMessage = snapshot.failureMessage;
    if (failureMessage != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.format('ISO 流式播放失败：{message}', {
              'message': context.l10n.text(failureMessage),
            }),
          ),
        ),
      );
    }

    final isoKey = history.isoKey;
    if (isoKey != null &&
        history.playbackMode != PlaybackMode.webdavHdmvMenu) {
      final progress = await service.getLibraryProgressByKey(
        isoKey,
        playbackMode: history.playbackMode,
      );
      if (!_playbackSessions.contains(session)) return;
      if (progress == null) {
        await _removePlaybackSession(session, terminateProcess: false);
        return;
      }
    }
    final needsHistoryUpdate =
        history.playerPid != null || history.isoSessionDirectoryPath != null;
    if (needsHistoryUpdate) {
      session.history = history.copyWith(
        clearPlayerPid: true,
        clearIsoSessionDirectoryPath: true,
        updatedAt: DateTime.now(),
      );
      await appState.playbackHistoryStore.upsert(session.history);
    }
    if (session.paused != null && mounted) {
      setState(() => session.paused = null);
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
      profileId: session.history.sourceId ?? _sourceId,
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
        playbackSourceId: history.sourceId,
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
            profileId: session.history.sourceId ?? _sourceId,
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
    if (session.history.kind == PlaybackHistoryKind.iso) {
      if (terminateProcess && session.history.playerPid != null) {
        final service = appState.isoPlaybackService;
        final termination = service == null
            ? PlayerTerminationOutcome.refused
            : await service.terminateSession(
                session.history.isoSessionDirectoryPath,
              );
        if (!termination.isSafeToRelaunch) {
          session.deleting = false;
          if (mounted) {
            setState(() {});
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: AppText('无法确认 ISO 播放器身份，已保留会话且未终止进程')),
            );
          }
          return;
        }
      }
      await appState.playbackHistoryStore.remove(sessionId);
      if (!mounted) return;
      _playbackPresenter.removeVideoSession(session);
      _refreshPlaybackMonitor();
      return;
    }
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

  /// 「继续播放」：进入上次目录扫描并复用对应类型的常规播放入口。
  Future<void> _resumePlaybackSession(PlaybackUiSession session) async {
    final origin = session.history.sourceId;
    if (origin != null && origin != _sourceId) {
      await _openLibraryItem(
        MediaLibraryItem(
          sourceId: origin,
          sourceKind: origin.startsWith('local:')
              ? MediaSourceKind.local
              : MediaSourceKind.webdav,
          parentPath: session.history.dirCrumbs.join('/'),
          name: session.history.fileName,
          kind: session.history.kind == PlaybackHistoryKind.iso
              ? MediaLibraryKind.iso
              : MediaLibraryKind.video,
        ),
        resumeSessionId: session.history.sessionId,
      );
      return;
    }
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

    if (history.kind == PlaybackHistoryKind.iso) {
      final iso = _files
          .where((file) => file.isIso && file.name == history.fileName)
          .firstOrNull;
      if (iso == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: AppText('未找到上次播放的 ISO 文件')));
        return;
      }
      if (iso is WebDavFile) {
        await _playIso(iso, sessionId: history.sessionId);
      }
      return;
    }

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
    final sourceId = _sourceId;
    if (store == null) {
      _showLibraryError('媒体中心暂时不可用，目录浏览和播放不受影响');
      return;
    }
    final selected = await Navigator.of(context).push<MediaLibraryItem>(
      MaterialPageRoute<MediaLibraryItem>(
        builder: (_) => MediaLibraryPage(
          sourceId: sourceId,
          sourceIds: _visibleSourceIds,
          sourceNames: {
            for (final root in appState.localRoots)
              root.sourceId: root.displayName,
            for (final profile in appState.configStore.current.profiles)
              profile.profileId: profile.name,
          },
          store: store,
          config: appState.configStore.current.mediaLibrary,
          directoryCache: appState.directoryCache,
          videoProgressService: appState.progressService,
          audioProgressService: appState.audioProgressService,
          isoProgressService: appState.isoPlaybackService,
          localIsoProgressService: appState.localDiscPlaybackService,
          resolveUrl: _isLocal
              ? _localSource!.lexicalPath
              : _service.resolveUrl,
          resolveDirectTarget: _libraryTarget,
        ),
      ),
    );
    if (!mounted) return;
    await _loadFavoriteKeys();
    if (selected != null) await _openLibraryItem(selected);
  }

  Future<void> _openLibraryItem(
    MediaLibraryItem item, {
    String? resumeSessionId,
  }) async {
    if (item.sourceId != _sourceId) {
      if (!_visibleSourceIds.contains(item.sourceId)) {
        _showLibraryError('该条目不属于当前连接来源');
        return;
      }
      final appState = context.read<AppState>();
      LocalRootConfig? root;
      try {
        if (item.sourceKind == MediaSourceKind.local) {
          root = _localSourceFor(item.sourceId)?.root;
          if (root == null) throw AppException.config('本地媒体已移动、删除或来源不可用');
        } else {
          final config = appState.configStore.current;
          final profile = config.profiles
              .where((profile) => profile.profileId == item.sourceId)
              .firstOrNull;
          if (profile == null) throw AppException.config('该条目不属于当前连接来源');
          if (appState.webDavService?.sourceId != item.sourceId) {
            await appState.connectAndActivateProfile(
              profile: profile,
              config: config,
            );
          }
        }
        if (!mounted) return;
        unawaited(
          Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(
              builder: (_) => BrowserPage(
                localRoot: root,
                initialLibraryItem: item,
                resumeSessionId: resumeSessionId,
              ),
            ),
          ),
        );
      } on AppException catch (error) {
        _showLibraryError(error.message);
      }
      return;
    }
    if (_isLocal && item.kind == MediaLibraryKind.iso) {
      final continueRecord = await _findLocalDiscContinueRecord(item);
      if (_isRootLocalDiscItem(item) && await _localSource!.hasDiscAt('')) {
        await _playLocalDisc(
          relativePath: '',
          displayName: widget.localRoot!.displayName,
          continueRecord: continueRecord,
        );
        return;
      }
      // 本地蓝光是目录型资产：直接按记录的相对路径恢复播放，
      // 不做目录导航与条目匹配（目录条目的分类不是 iso，匹配必然失败）。
      await _playLocalDisc(
        relativePath: item.targetPath,
        displayName: item.name,
        continueRecord: continueRecord,
      );
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
        _isLocal
            ? '本地媒体已移动、删除或来源不可用'
            : context.l10n.format('未在当前服务器目录中找到「{name}」', {'name': item.name}),
      );
      return;
    }
    if (_isLocal && item.kind == MediaLibraryKind.iso) {
      await _playLocalDisc(
        relativePath: file.relativePath,
        displayName: file.name,
        continueRecord: await _findLocalDiscContinueRecord(item),
      );
      return;
    }
    if (file.isAudio) {
      await _playAudio(file, sessionId: resumeSessionId);
    } else if (file.isIso && file is WebDavFile) {
      await _playIso(file, sessionId: resumeSessionId);
    } else {
      await _playVideo(file, sessionId: resumeSessionId);
    }
  }

  void _onFileTap(MediaDirectoryEntry file) {
    if (file.isSelfEntry) {
      // 「返回上级」条目：回到上级目录（根目录时无操作）。
      if (_crumbs.isEmpty) return;
      _backTo(_crumbs.length - 2);
    } else if (file.isDirectory) {
      _enterDirectory(file);
    } else if (file.isIso) {
      if (_isLocal) {
        unawaited(
          _playLocalDisc(
            relativePath: file.relativePath,
            displayName: file.name,
          ),
        );
      } else {
        unawaited(_playIso(file as WebDavFile));
      }
    } else if (file.isAudio) {
      unawaited(_playAudio(file));
    } else if (_isLocal ? file.isVideo : file.isPlayable) {
      unawaited(_playVideo(file));
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

  Future<void> _openSettings() async {
    final appState = context.read<AppState>();
    final previousSourceId = appState.mediaSourceId;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
    if (!mounted) return;
    if (_isLocal) {
      final root = widget.localRoot!;
      final current = appState.localRoots
          .where((candidate) => candidate.rootId == root.rootId)
          .firstOrNull;
      if (current == null || !current.enabled || current.path != root.path) {
        Navigator.of(context).pop();
        return;
      }
      await Future.wait([
        _load(force: true),
        _loadPlaybackSessions(),
        _loadAudioPlaybackSessions(),
        _loadFavoriteKeys(),
        _refreshLocalDiscContinue(),
      ]);
      return;
    }
    if (appState.mediaSourceId != previousSourceId) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const BrowserPage()),
      );
      return;
    }
    await Future.wait([
      _loadPlaybackSessions(),
      _refreshLocalDiscContinue(),
      _loadAudioPlaybackSessions(),
      _loadFavoriteKeys(),
    ]);
    if (mounted) setState(() {});
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
          if (_directorySearchOpen && !_isLocal)
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
            onPressed: _openSettings,
          ),
          if (!_isLocal)
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: context.l10n.text('断开连接'),
              onPressed: () {
                context.read<AppState>().disconnect();
                // 进入登录界面时清空导航栈，保留已保存的连接配置。
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute<void>(
                    builder: (_) => const StorageRootPage(),
                  ),
                  (route) => false,
                );
              },
            ),
        ],
      ),
      body: _buildBody(),
      bottomNavigationBar:
          _playbackSessions.isEmpty &&
              _audioPlaybackSessions.isEmpty &&
              _localDiscContinue.isEmpty
          ? null
          : _buildPlaybackBars(),
    );
  }

  /// 共享展示时标注会话的原始来源。
  String _barDirectoryLabel(String? sourceId, String directory) {
    if (_visibleSourceIds.length <= 1) return directory;
    final id = sourceId ?? _sourceId;
    final config = context.read<AppState>().configStore.current;
    final name =
        config.localRoots
            .where((root) => root.sourceId == id)
            .firstOrNull
            ?.displayName ??
        config.profiles
            .where((profile) => profile.profileId == id)
            .firstOrNull
            ?.name ??
        id;
    return '$name · ${context.l10n.text(directory)}';
  }

  /// 播放会话垂直堆栈：新会话在上，越早创建的会话越靠下。
  Widget _buildPlaybackBars() {
    final displayed = _playbackSessions.reversed.toList();
    final displayedAudio = _audioPlaybackSessions.reversed.toList();
    final bars = <Widget>[
      for (final session in displayedAudio) _buildAudioPlaybackBar(session),
      for (final session in displayed) _buildPlaybackBar(session),
      for (final entry in _localDiscContinue) _buildLocalDiscPlaybackBar(entry),
    ];
    final surface = PlaybackBarsSurface(children: bars);
    if (bars.length <= 4) return surface;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.4,
      ),
      child: SingleChildScrollView(child: surface),
    );
  }

  Future<void> _removeLocalDiscContinue(_LocalDiscContinueEntry entry) async {
    final sessionId = entry.record.playbackSessionId;
    if (sessionId != null && entry.running) {
      final outcome = await _localDiscPlaybackService.terminateSession(
        sessionId,
      );
      if (!outcome.isSafeToRelaunch) {
        _showLibraryError('无法确认对应蓝光播放器进程，未删除播放会话');
        return;
      }
    }
    await _mediaLibraryStore?.dismissLocalDiscPlaybackBar(entry.record);
    await _refreshLocalDiscContinue();
  }

  Future<void> _setLocalDiscPaused(
    _LocalDiscContinueEntry entry,
    bool paused,
  ) async {
    final sessionId = entry.record.playbackSessionId;
    if (sessionId == null) return;
    if (paused) {
      await _localDiscPlaybackService.sendPause(sessionId);
    } else {
      await _localDiscPlaybackService.sendResume(sessionId);
    }
    if (!mounted) return;
    setState(() {
      _localDiscContinue = [
        for (final candidate in _localDiscContinue)
          identical(candidate, entry)
              ? _LocalDiscContinueEntry(
                  record: candidate.record,
                  running: candidate.running,
                  paused: paused,
                )
              : candidate,
      ];
    });
  }

  Widget _buildLocalDiscPlaybackBar(_LocalDiscContinueEntry entry) {
    final record = entry.record;
    final String title;
    final IconData icon;
    final String tooltip;
    final VoidCallback? onPressed;
    if (entry.running && entry.paused == true) {
      title = '本地蓝光已暂停：${record.item.name}';
      icon = Icons.play_arrow;
      tooltip = '继续播放';
      onPressed = () => _setLocalDiscPaused(entry, false);
    } else if (entry.running) {
      title = '正在播放本地蓝光：${record.item.name}';
      icon = Icons.pause;
      tooltip = '暂停';
      onPressed = () => _setLocalDiscPaused(entry, true);
    } else {
      title = '继续播放本地蓝光：${record.item.name}';
      icon = Icons.play_arrow;
      tooltip = '继续播放';
      onPressed = record.item.sourceId != _sourceId
          ? () => _openLibraryItem(record.item)
          : () => _playLocalDisc(
              relativePath:
                  record.localDiscSession?.relativePath ??
                  (_isRootLocalDiscItem(record.item)
                      ? ''
                      : record.item.targetPath),
              displayName: record.item.name,
              continueRecord: record,
            );
    }
    final details = <String>[
      record.item.normalizedParentPath.isEmpty
          ? context.l10n.text('根目录')
          : record.item.normalizedParentPath,
      if (entry.titleLabel != null) entry.titleLabel!,
    ];
    return PlaybackBar(
      key: ValueKey<String>('local-disc-playback-bar-${record.recordKey}'),
      title: title,
      dirLabel: _barDirectoryLabel(record.item.sourceId, details.join(' · ')),
      icon: icon,
      tooltip: tooltip,
      deleting: false,
      onPressed: onPressed,
      onDelete: () => _removeLocalDiscContinue(entry),
      onSecondaryTapDown: (details) =>
          _showLocalDiscSessionMenu(entry, details.globalPosition),
    );
  }

  Future<void> _showLocalDiscSessionMenu(
    _LocalDiscContinueEntry entry,
    Offset globalPosition,
  ) async {
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
      await _removeLocalDiscContinue(entry);
    }
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

    return PlaybackBar(
      key: ValueKey<String>('audio-playback-bar-$sessionId'),
      title: title,
      dirLabel: _barDirectoryLabel(history.sourceId, dirLabel),
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
    if (session.history.kind == PlaybackHistoryKind.iso) {
      return _buildIsoPlaybackBar(session);
    }
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

    return PlaybackBar(
      key: ValueKey<String>('playback-bar-$sessionId'),
      title: title,
      dirLabel: _barDirectoryLabel(history.sourceId, dirLabel),
      icon: icon,
      tooltip: tooltip,
      deleting: session.deleting,
      onPressed: onPressed,
      onDelete: () => _removePlaybackSession(session, terminateProcess: true),
      onSecondaryTapDown: (details) =>
          _showSessionMenu(session, details.globalPosition),
    );
  }

  Widget _buildIsoPlaybackBar(PlaybackUiSession session) {
    final history = session.history;
    final sessionId = history.sessionId;
    final dirLabel =
        'ISO · '
        '${history.dirCrumbs.isEmpty ? context.l10n.text('根目录') : history.dirCrumbs.join(' / ')}';
    final paused = session.paused;

    final String title;
    final IconData icon;
    final String tooltip;
    final VoidCallback? onPressed;
    if (session.launching) {
      title = '正在打开 ISO：${history.fileName}';
      icon = Icons.hourglass_top;
      tooltip = '正在打开播放器';
      onPressed = null;
    } else if (paused == false) {
      title = '正在播放 ISO：${history.fileName}';
      icon = Icons.pause;
      tooltip = '暂停';
      onPressed = () => context.read<AppState>().isoPlaybackService?.sendPause(
        history.isoSessionDirectoryPath,
      );
    } else if (paused == true) {
      title = 'ISO 已暂停：${history.fileName}';
      icon = Icons.play_arrow;
      tooltip = '继续播放';
      onPressed = () => context.read<AppState>().isoPlaybackService?.sendResume(
        history.isoSessionDirectoryPath,
      );
    } else {
      title = '继续播放 ISO：${history.fileName}';
      icon = Icons.play_arrow;
      tooltip = '继续播放';
      onPressed = () => _resumePlaybackSession(session);
    }

    return PlaybackBar(
      key: ValueKey<String>('iso-playback-bar-$sessionId'),
      title: title,
      dirLabel: _barDirectoryLabel(history.sourceId, dirLabel),
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

  Widget _buildTitle() =>
      DirectoryBreadcrumbs(crumbs: _crumbs, onNavigate: _backTo);

  Widget? _buildFileTrailing(MediaDirectoryEntry file, int index) {
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
    final fileList = DirectoryFileList(
      entries: visibleFiles,
      controller: _directoryScrollController,
      scrollKey: _directoryScrollKey,
      onRefresh: () => _load(force: true),
      emptyLabel: _directorySearchQuery.trim().isEmpty ? '空目录' : '未找到匹配项',
      itemBuilder: (context, entry, index) {
        return FileTile(
          file: entry,
          onTap: () => _onFileTap(entry),
          trailing: _buildFileTrailing(entry, index),
        );
      },
    );
    if (!_isLocal || !_hasLocalDisc) return fileList;
    return Column(
      children: [
        ListTile(
          key: const Key('local-bdmv-menu-action'),
          leading: const Icon(Icons.album_outlined),
          title: const AppText('检测到 Blu-ray BDMV'),
          subtitle: const AppText('由 MPV/libbluray 显示并控制蓝光菜单'),
          trailing: FilledButton.icon(
            onPressed: () => _playLocalDisc(
              relativePath: _currentPath,
              displayName: _crumbs.lastOrNull ?? widget.localRoot!.displayName,
            ),
            icon: const Icon(Icons.play_arrow),
            label: const AppText('选择播放方式'),
          ),
        ),
        Expanded(child: fileList),
      ],
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
