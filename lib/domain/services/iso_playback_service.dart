import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../../core/errors/app_exception.dart';
import '../../core/utils/app_paths.dart';
import '../../data/local/stream_path_config_store.dart';
import '../../data/models/player_config.dart';
import '../../data/models/media_source.dart';
import '../../data/models/web_dav_file.dart';
import '../../features/cache_control/iso_cache_coordinator.dart';
import 'iso_access_provider.dart';
import 'iso_player_arguments.dart';
import 'mpv_watch_later_sync.dart';
import 'player_process_controller.dart';
import 'webdav_service.dart';
import 'remote_menu_playback_service.dart';

enum IsoPlaybackPhase {
  checkingPlayer,
  startingBridge,
  probingStream,
  parsingTitles,
  selectingTitles,
  launching,
  playing,
}

@immutable
class IsoDiscChapter {
  const IsoDiscChapter({
    required this.start,
    required this.duration,
    this.name,
  });

  final Duration start;
  final Duration duration;
  final String? name;
}

@immutable
class IsoDiscTitle {
  IsoDiscTitle({
    required this.titleIndex,
    required this.mplsId,
    required this.duration,
    required this.streamSize,
    List<IsoDiscChapter> chapters = const [],
  }) : chapters = List<IsoDiscChapter>.unmodifiable(chapters);

  final int titleIndex;
  final String mplsId;
  final Duration duration;
  final int streamSize;
  final List<IsoDiscChapter> chapters;

  String get resumeId => 'bd://mpls/$mplsId';
}

@immutable
class IsoTitleResume {
  const IsoTitleResume({required this.position, this.duration});

  final Duration position;
  final Duration? duration;
}

@immutable
class IsoLibraryProgress {
  const IsoLibraryProgress({
    required this.episodeNumber,
    required this.episodeCount,
    required this.position,
    this.duration,
  });

  final int episodeNumber;
  final int episodeCount;
  final Duration position;
  final Duration? duration;
}

typedef IsoLibraryProgressListener = void Function();

abstract interface class IsoLibraryProgressReader {
  void addLibraryProgressListener(IsoLibraryProgressListener listener);

  void removeLibraryProgressListener(IsoLibraryProgressListener listener);

  Future<IsoLibraryProgress?> getLibraryProgress({
    required String profileId,
    required String resolvedUrl,
    PlaybackMode playbackMode = PlaybackMode.legacyTitle,
  });
}

@immutable
class IsoPlaybackSessionSnapshot {
  const IsoPlaybackSessionSnapshot({
    required this.liveness,
    this.paused,
    this.failureMessage,
  });

  final PlayerProcessLiveness liveness;
  final bool? paused;
  final String? failureMessage;
}

@immutable
class IsoTitleSelectionRequest {
  const IsoTitleSelectionRequest({
    required this.discName,
    required this.titles,
    required this.selectedMplsIds,
    required this.resumeByMplsId,
    this.lastMplsId,
  });

  final String discName;
  final List<IsoDiscTitle> titles;
  final Set<String> selectedMplsIds;
  final Map<String, IsoTitleResume> resumeByMplsId;
  final String? lastMplsId;
}

@immutable
class IsoTitleSelection {
  const IsoTitleSelection({
    required this.orderedTitles,
    required this.selectedMplsIds,
  });

  factory IsoTitleSelection.all(List<IsoDiscTitle> titles) => IsoTitleSelection(
    orderedTitles: List<IsoDiscTitle>.unmodifiable(titles),
    selectedMplsIds: titles.map((title) => title.mplsId).toSet(),
  );

  final List<IsoDiscTitle> orderedTitles;
  final Set<String> selectedMplsIds;

  List<IsoDiscTitle> get selectedTitles => orderedTitles
      .where((title) => selectedMplsIds.contains(title.mplsId))
      .toList(growable: false);
}

class IsoPlaybackProgress {
  const IsoPlaybackProgress({required this.phase, required this.fileName});

  final IsoPlaybackPhase phase;
  final String fileName;
}

class IsoPlaybackLaunchResult {
  const IsoPlaybackLaunchResult({
    required this.pid,
    required this.args,
    required this.sessionDirectoryPath,
    required this.playerIdentity,
    required this.isoKey,
    this.playbackMode = PlaybackMode.legacyTitle,
  });

  final int pid;
  final List<String> args;
  final String sessionDirectoryPath;
  final PlayerProcessIdentity playerIdentity;
  final String isoKey;
  final PlaybackMode playbackMode;
}

typedef IsoPlayerConfigLoader = Future<PlayerConfig> Function();
typedef IsoTitleSelector =
    Future<IsoTitleSelection?> Function(IsoTitleSelectionRequest request);
typedef IsoProcessStarter =
    Future<int> Function(String executable, List<String> args);
typedef IsoProgressCallback = void Function(IsoPlaybackProgress progress);
typedef IsoTempRootProvider = Future<Directory> Function();
typedef IsoOwnerIdentityLoader = Future<PlayerProcessIdentity?> Function();

class _IsoRuntime {
  _IsoRuntime({
    required this.sessionDirectory,
    required this.handle,
    required this.playerIdentity,
    required this.playerTracker,
    required this.helperIdentity,
    required this.helperTracker,
    required this.isoKey,
    required this.titles,
    required this.journalFile,
    this.cacheSessionId,
    this.performanceTracker,
    this.sharedResumeKey,
    this.playbackMode = PlaybackMode.legacyTitle,
  });

  final Directory sessionDirectory;
  final IsoAccessHandle? handle;
  final PlayerProcessIdentity playerIdentity;
  final PlayerProcessLivenessTracker playerTracker;
  final PlayerProcessIdentity? helperIdentity;
  final PlayerProcessLivenessTracker? helperTracker;
  final String? isoKey;
  final List<IsoDiscTitle> titles;
  final File? journalFile;
  final String? cacheSessionId;
  final String? sharedResumeKey;
  final _IsoPerformanceTracker? performanceTracker;
  final PlaybackMode playbackMode;
}

/// WebDAV Blu-ray ISO 无驱动远程流式播放服务。
class IsoPlaybackService implements IsoLibraryProgressReader {
  IsoPlaybackService({
    required StreamPathConfigStore configStore,
    IsoAccessProvider? accessProvider,
    IsoAccessProvider? remoteMenuAccessProvider,
    RemoteMenuPlaybackService? remoteMenuService,
    PlayerProcessController? processController,
    IsoPlayerConfigLoader? configLoader,
    IsoProcessStarter? processStarter,
    IsoTempRootProvider? tempRootProvider,
    IsoOwnerIdentityLoader? ownerIdentityLoader,
    DateTime Function()? now,
    IsoCacheCoordinator? cacheCoordinator,
    this.orphanRetention = const Duration(hours: 24),
  }) : _accessProvider = accessProvider ?? IsoBridgeAccessProvider(),
       _remoteMenuAccess =
           remoteMenuAccessProvider ??
           IsoBridgeAccessProvider(remoteMenu: true),
       remoteMenu =
           remoteMenuService ??
           RemoteMenuPlaybackService(
             configLoader:
                 configLoader ??
                 (() async => (await configStore.load()).toPlayerConfig()),
           ),
       _processController = processController ?? PlayerProcessController(),
       _configLoader =
           configLoader ??
           (() async => (await configStore.load()).toPlayerConfig()),
       _processStarter = processStarter ?? IsoPlaybackService._startMpv,
       _tempRootProvider =
           tempRootProvider ?? IsoPlaybackService._defaultTempRoot,
       // 对外保留可读的命名参数，私有字段不能用 initializing formal 暴露。
       // ignore: prefer_initializing_formals
       _ownerIdentityLoader = ownerIdentityLoader,
       _now = now ?? DateTime.now,
       // ignore: prefer_initializing_formals
       _cacheCoordinator = cacheCoordinator;

  static const String tempDirectoryName = 'iso_temp';
  static const String manifestFileName = 'iso-session.json';
  static const String catalogFileName = 'iso_catalog.json';
  static const String watchLaterDirectoryName = 'iso_watch_later';
  static const String statusFileName = 'iso-current.txt';
  static const String commandFileName = 'iso-command.txt';
  static const String performanceSummaryFileName = 'iso-performance.json';
  static const String performanceEventsFileName =
      'iso-performance-events.jsonl';
  static const String performanceArchiveDirectoryName = 'iso_benchmarks';
  static const String structureCacheDirectoryName = 'iso_structure';

  final IsoAccessProvider _accessProvider;
  final PlayerProcessController _processController;
  final IsoPlayerConfigLoader _configLoader;
  final IsoProcessStarter _processStarter;
  final IsoTempRootProvider _tempRootProvider;
  final IsoOwnerIdentityLoader? _ownerIdentityLoader;
  final DateTime Function() _now;
  final IsoCacheCoordinator? _cacheCoordinator;
  final Duration orphanRetention;
  final Map<String, _IsoRuntime> _runtimes = {};
  final RemoteMenuPlaybackService remoteMenu;
  final IsoAccessProvider _remoteMenuAccess;
  final Set<String> _uncertainSessionPaths = {};
  final Map<String, Future<void>> _finishingRuntimeOperations = {};
  final Map<String, String> _terminalFailureMessages = {};
  final Set<IsoLibraryProgressListener> _libraryProgressListeners = {};
  _IsoCatalogStore? _catalogStore;

  Directory? _tempRoot;
  bool _operationActive = false;
  bool _cancelRequested = false;
  bool _disposed = false;
  int _sessionSequence = 0;

  bool get isBusy =>
      _operationActive ||
      _runtimes.isNotEmpty ||
      _finishingRuntimeOperations.isNotEmpty ||
      _uncertainSessionPaths.isNotEmpty;

  @override
  void addLibraryProgressListener(IsoLibraryProgressListener listener) =>
      _libraryProgressListeners.add(listener);

  @override
  void removeLibraryProgressListener(IsoLibraryProgressListener listener) =>
      _libraryProgressListeners.remove(listener);

  Future<void> initialize() async {
    unawaited(remoteMenu.unavailableReason());
    final root = await _rootDirectory();
    if (!await root.exists()) await root.create(recursive: true);
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory || !p.basename(entity.path).startsWith('iso_')) {
        continue;
      }
      final restored = await _restoreRuntime(entity);
      if (restored) continue;
      final stat = await entity.stat();
      if (_now().difference(stat.modified) >= orphanRetention) {
        await _cleanupDirectory(entity);
      }
    }
  }

  Future<IsoPlaybackLaunchResult?> start({
    required WebDAVService webDavService,
    required WebDavFile file,
    IsoProgressCallback? onProgress,
    IsoTitleSelector? selectTitles,
  }) async {
    if (_disposed) throw AppException.process('ISO 远程播放测试模块已关闭');
    if (isBusy) {
      throw AppException.process('ISO 远程播放测试模块正在执行其他任务');
    }
    if (!file.isIso) throw AppException.config('仅支持 Blu-ray ISO 文件');

    final performanceClock = Stopwatch()..start();
    int? probeCompletedAtMs;
    _operationActive = true;
    _cancelRequested = false;
    IsoAccessHandle? handle;
    Directory? sessionDirectory;
    var runtimeOwnsSession = false;
    try {
      onProgress?.call(
        IsoPlaybackProgress(
          phase: IsoPlaybackPhase.checkingPlayer,
          fileName: file.name,
        ),
      );
      final config = await _configLoader();
      if (_cancelRequested) return null;
      if (!_isMpvExecutable(config.executable)) {
        throw AppException.config('ISO 远程播放测试需要使用 MPV 播放器');
      }
      final ownerIdentity = await _loadOwnerIdentity();
      if (ownerIdentity == null) {
        throw AppException.process('无法确认 StreamPath 进程身份');
      }

      final resolvedIsoUrl = webDavService.resolveUrl(file.href);
      final isoKey = _buildIsoKey(
        profileId: webDavService.sourceId,
        resolvedUrl: resolvedIsoUrl,
      );
      final tempRoot = await _rootDirectory();
      final structureCachePath = p.normalize(
        p.absolute(
          tempRoot.parent.path,
          structureCacheDirectoryName,
          '$isoKey.cache',
        ),
      );

      sessionDirectory = Directory(
        p.join(
          tempRoot.path,
          'iso_${_now().microsecondsSinceEpoch}_${++_sessionSequence}',
        ),
      );
      await sessionDirectory.create(recursive: true);
      await _writeBridgeStartingManifest(sessionDirectory, ownerIdentity);
      handle = await _accessProvider.prepare(
        webDavService: webDavService,
        file: file,
        sessionDirectory: sessionDirectory,
        structureCachePath: structureCachePath,
        onPhase: (phase) {
          onProgress?.call(
            IsoPlaybackProgress(
              phase: switch (phase) {
                IsoAccessPhase.startingBridge =>
                  IsoPlaybackPhase.startingBridge,
                IsoAccessPhase.probingStream => IsoPlaybackPhase.probingStream,
                IsoAccessPhase.parsingTitles => IsoPlaybackPhase.parsingTitles,
              },
              fileName: file.name,
            ),
          );
          if (phase == IsoAccessPhase.parsingTitles) {
            probeCompletedAtMs ??= performanceClock.elapsedMilliseconds;
          }
        },
        onHelperStarted: (helperIdentity) => _writeBridgeStartingManifest(
          sessionDirectory!,
          ownerIdentity,
          helperIdentity: helperIdentity,
        ),
      );
      if (_cancelRequested) {
        await handle.cleanup();
        return null;
      }
      final performance = _IsoPerformanceTracker(
        sessionDirectory: handle.sessionDirectory,
        clock: performanceClock,
        probeCompletedAtMs: probeCompletedAtMs,
        titlesReadyAtMs: performanceClock.elapsedMilliseconds,
        helperExecutablePath: handle.helperIdentity.executablePath,
      );
      unawaited(performance.initialize());

      final probedTitles = handle.titles
          .map(
            (title) => IsoDiscTitle(
              titleIndex: title.titleIndex,
              mplsId: title.mplsId,
              duration: title.duration,
              streamSize: title.streamSize,
              chapters: List<IsoDiscChapter>.unmodifiable(
                title.chapters.map(
                  (chapter) => IsoDiscChapter(
                    start: chapter.start,
                    duration: chapter.duration,
                    name: chapter.name,
                  ),
                ),
              ),
            ),
          )
          .toList(growable: false);
      if (probedTitles.isEmpty) {
        throw AppException.process('没有解析到可播放的 Blu-ray Title/MPLS');
      }
      if (_cancelRequested) {
        await handle.cleanup();
        return null;
      }

      final catalog = await _catalog();
      final saved = await catalog.load(isoKey);
      final orderedTitles = _applySavedOrder(probedTitles, saved.order);
      final availableIds = orderedTitles.map((title) => title.mplsId).toSet();
      final initiallySelected = saved.selected
          .where(availableIds.contains)
          .toSet();
      if (initiallySelected.isEmpty) initiallySelected.addAll(availableIds);
      final resumeByMplsId = await _loadResumeState(isoKey, orderedTitles);
      onProgress?.call(
        IsoPlaybackProgress(
          phase: IsoPlaybackPhase.selectingTitles,
          fileName: file.name,
        ),
      );
      final request = IsoTitleSelectionRequest(
        discName: file.name,
        titles: List<IsoDiscTitle>.unmodifiable(orderedTitles),
        selectedMplsIds: Set<String>.unmodifiable(initiallySelected),
        resumeByMplsId: Map<String, IsoTitleResume>.unmodifiable(
          resumeByMplsId,
        ),
        lastMplsId: saved.lastMplsId,
      );
      final selection = selectTitles == null
          ? IsoTitleSelection.all(orderedTitles)
          : await selectTitles(request);
      if (selection == null || _cancelRequested) {
        await handle.cleanup();
        return null;
      }
      performance.markSelectionConfirmed();
      final validatedSelection = _validateSelection(
        availableTitles: orderedTitles,
        selection: selection,
      );
      final selectedTitles = validatedSelection.selectedTitles;
      if (selectedTitles.isEmpty) {
        throw AppException.config('至少选择一个 Blu-ray Title');
      }
      await catalog.saveSelection(
        isoKey,
        order: validatedSelection.orderedTitles
            .map((title) => title.mplsId)
            .toList(growable: false),
        selected: validatedSelection.selectedMplsIds.toList(growable: false),
      );
      IsoCacheSessionPlan? cachePlan;
      final cacheCoordinator = _cacheCoordinator;
      if (cacheCoordinator != null) {
        cachePlan = await cacheCoordinator.buildSessionPlan(
          logicalSourceUrl: resolvedIsoUrl,
          titles: selectedTitles
              .map(
                (title) => IsoCacheTitleContext(
                  mplsId: title.mplsId,
                  streamSize: title.streamSize,
                  duration: title.duration,
                ),
              )
              .toList(growable: false),
        );
        await handle.configureCache(
          blockCount: cachePlan.bridgeBlockCount,
          prefetchBlocks: cachePlan.prefetchBlocks,
        );
      }
      performance.markPlaybackPlan(
        titles: selectedTitles,
        cachePlan: cachePlan,
      );

      onProgress?.call(
        IsoPlaybackProgress(
          phase: IsoPlaybackPhase.launching,
          fileName: file.name,
        ),
      );
      final playlistFile = await _writePlaylist(
        handle.sessionDirectory,
        discName: file.name,
        titles: selectedTitles,
        playbackUri: handle.playbackUri,
      );
      final journalFile = File(
        p.join(handle.sessionDirectory.path, 'iso-progress.jsonl'),
      );
      final performanceEventsFile = File(
        p.join(handle.sessionDirectory.path, performanceEventsFileName),
      );
      final statusFile = File(
        p.join(handle.sessionDirectory.path, statusFileName),
      );
      final commandFile = File(
        p.join(handle.sessionDirectory.path, commandFileName),
      );
      final progressScript = await _writeProgressScript(
        handle.sessionDirectory,
        journalFile,
        statusFile,
        commandFile,
        performanceEventsFile,
        selectedTitles,
        resumeByMplsId,
      );
      final startIndex = _resolvePlaylistStart(
        selectedTitles,
        saved.lastMplsId,
        resumeByMplsId,
      );
      final ipcPipeName =
          r'\\.\pipe\streampath_iso_' +
          _buildPipeToken(handle.sessionDirectory.path);
      final startCachePlan = cachePlan?.planFor(
        selectedTitles[startIndex].mplsId,
      );
      final args = buildMpvArgs(
        config: config,
        title: file.name,
        playlistPath: playlistFile.path,
        playlistStart: startIndex,
        progressScriptPath: progressScript.path,
        ipcPipeName: ipcPipeName,
        cacheSecs: startCachePlan?.cacheSecs,
        mpvMaxBytes: startCachePlan?.mpvMaxBytes,
      );
      await _writeLaunchingManifest(
        handle,
        ownerIdentity: ownerIdentity,
        isoKey: isoKey,
        titles: selectedTitles,
        journalFile: journalFile,
      );
      performance.markMpvLaunch();
      final pid = await _processStarter(config.executable, args);
      final identity = await _captureIdentityWithRetry(pid);
      if (identity == null) {
        throw AppException.process('无法确认 ISO 播放器进程身份');
      }
      await handle.attachPlayer(pid);
      final playerTracker = PlayerProcessLivenessTracker(
        controller: _processController,
        expectedIdentity: identity,
      );
      final helperTracker = PlayerProcessLivenessTracker(
        controller: _processController,
        expectedIdentity: handle.helperIdentity,
      );
      final runtime = _IsoRuntime(
        sessionDirectory: handle.sessionDirectory,
        handle: handle,
        playerIdentity: identity,
        playerTracker: playerTracker,
        helperIdentity: handle.helperIdentity,
        helperTracker: helperTracker,
        isoKey: isoKey,
        titles: List<IsoDiscTitle>.unmodifiable(selectedTitles),
        journalFile: journalFile,
        cacheSessionId: cachePlan == null
            ? null
            : p.basename(handle.sessionDirectory.path),
        performanceTracker: performance,
      );
      _runtimes[handle.sessionDirectory.path] = runtime;
      runtimeOwnsSession = true;
      performance.startObservation(
        metricsFile: File(
          p.join(handle.sessionDirectory.path, 'iso-bridge-metrics.json'),
        ),
        eventsFile: performanceEventsFile,
      );
      if (cachePlan != null) {
        cacheCoordinator!.startSession(
          sessionId: runtime.cacheSessionId!,
          logicalSourceUrl: resolvedIsoUrl,
          statusFilePath: statusFile.path,
          metricsFilePath: p.join(
            handle.sessionDirectory.path,
            'iso-bridge-metrics.json',
          ),
          ipcPipeName: ipcPipeName,
          orderedMplsIds: selectedTitles
              .map((title) => title.mplsId)
              .toList(growable: false),
          plan: cachePlan,
        );
      }
      try {
        await _writeManifest(runtime);
      } on FileSystemException {
        // 当前进程仍由内存身份跟踪；遗留目录由启动清理保守处理。
      }
      unawaited(_watchRuntime(runtime));
      onProgress?.call(
        IsoPlaybackProgress(
          phase: IsoPlaybackPhase.playing,
          fileName: file.name,
        ),
      );
      return IsoPlaybackLaunchResult(
        pid: pid,
        args: List.unmodifiable(args),
        sessionDirectoryPath: handle.sessionDirectory.path,
        playerIdentity: identity,
        isoKey: isoKey,
      );
    } catch (error, stackTrace) {
      if (!runtimeOwnsSession && handle != null) {
        try {
          await handle.cleanup();
        } on FileSystemException {
          // 启动清理会再次处理未被播放器占用的遗留目录。
        }
      } else if (!runtimeOwnsSession && sessionDirectory != null) {
        await _cleanupDirectory(sessionDirectory);
      }
      if (_cancelRequested) return null;
      if (error is AppException || error is FileSystemException) rethrow;
      Error.throwWithStackTrace(
        AppException.process('ISO Bridge 启动失败', error),
        stackTrace,
      );
    } finally {
      _operationActive = false;
    }
  }

  Future<IsoPlaybackLaunchResult?> startRemoteMenu({
    required WebDAVService webDavService,
    required WebDavFile file,
    IsoProgressCallback? onProgress,
  }) async {
    if (_disposed || isBusy) {
      throw AppException.process('ISO 远程播放测试模块正在执行其他任务');
    }
    _operationActive = true;
    _cancelRequested = false;
    IsoAccessHandle? handle;
    PlayerProcessIdentity? player;
    Directory? directory;
    var registered = false;
    try {
      final config = await _configLoader();
      final executable = await remoteMenu.requireCapability(config: config);
      if (_cancelRequested) return null;
      final owner = await _loadOwnerIdentity();
      if (owner == null) throw AppException.process('无法确认 StreamPath 进程身份');
      final titleKey = _buildIsoKey(
        profileId: webDavService.sourceId,
        resolvedUrl: webDavService.resolveUrl(file.href),
      );
      final key = _menuKey(titleKey);
      if (_runtimes.values.any((runtime) => runtime.isoKey == key)) {
        throw AppException.process('此光盘的菜单会话已打开，请先关闭现有会话');
      }
      final root = await _rootDirectory();
      directory = Directory(
        p.join(
          root.path,
          'iso_menu_${_now().microsecondsSinceEpoch}_${++_sessionSequence}',
        ),
      );
      await directory.create(recursive: true);
      await _writeBridgeStartingManifest(
        directory,
        owner,
        playbackMode: PlaybackMode.webdavHdmvMenu,
      );
      handle = await _remoteMenuAccess.prepare(
        webDavService: webDavService,
        file: file,
        sessionDirectory: directory,
        structureCachePath: p.absolute(
          root.parent.path,
          structureCacheDirectoryName,
          '$key.cache',
        ),
        onHelperStarted: (identity) => _writeBridgeStartingManifest(
          directory!,
          owner,
          helperIdentity: identity,
          playbackMode: PlaybackMode.webdavHdmvMenu,
        ),
        onPhase: (phase) => onProgress?.call(
          IsoPlaybackProgress(
            phase: phase == IsoAccessPhase.startingBridge
                ? IsoPlaybackPhase.startingBridge
                : IsoPlaybackPhase.probingStream,
            fileName: file.name,
          ),
        ),
      );
      if (_cancelRequested) return null;
      final menuPlan = await _cacheCoordinator?.buildMenuPlan(
        logicalSourceUrl: webDavService.resolveUrl(file.href),
        totalBytes: handle.totalBytes,
      );
      await handle.configureCache(
        blockCount: menuPlan?.bridgeBlockCount ?? 128,
        prefetchBlocks: menuPlan?.prefetchBlocks ?? 96,
        cacheSecs: menuPlan?.cacheSecs ?? 60,
      );
      final args = await remoteMenu.prepareArgs(
        config: config,
        sessionDirectory: directory,
        endpoint: (handle as RemoteDiscAccessHandle).discUri,
        sessionKey: key,
        ipcPipeName:
            '${r'\\.\pipe\streampath_menu_'}${_buildPipeToken(directory.path)}',
      );
      if (_cancelRequested) return null;
      final journal = config.menuProgressSharingEnabled
          ? File(p.join(directory.path, 'menu-progress.jsonl'))
          : null;
      await _writeLaunchingManifest(
        handle,
        ownerIdentity: owner,
        isoKey: key,
        sharedResumeKey: config.menuProgressSharingEnabled ? titleKey : null,
        titles: const [],
        journalFile: journal,
        playbackMode: PlaybackMode.webdavHdmvMenu,
      );
      onProgress?.call(
        IsoPlaybackProgress(
          phase: IsoPlaybackPhase.launching,
          fileName: file.name,
        ),
      );
      final pid = await _processStarter(executable, args);
      player = await _captureIdentityWithRetry(pid);
      if (player == null) {
        throw AppException.process('无法确认 MPV 播放器身份');
      }
      final runtime = _IsoRuntime(
        sessionDirectory: directory,
        handle: handle,
        playerIdentity: player,
        playerTracker: PlayerProcessLivenessTracker(
          controller: _processController,
          expectedIdentity: player,
        ),
        helperIdentity: handle.helperIdentity,
        helperTracker: PlayerProcessLivenessTracker(
          controller: _processController,
          expectedIdentity: handle.helperIdentity,
        ),
        isoKey: key,
        sharedResumeKey: config.menuProgressSharingEnabled ? titleKey : null,
        titles: const [],
        journalFile: journal,
        playbackMode: PlaybackMode.webdavHdmvMenu,
      );
      await _writeManifest(runtime);
      await handle.attachPlayer(pid);
      await remoteMenu.waitUntilReady(
        sessionDirectory: directory,
        timeout: Duration(seconds: config.playerStartupTimeoutSeconds),
        playerExited: () async =>
            await runtime.playerTracker.probe() == PlayerProcessLiveness.exited,
        cancelled: () => _cancelRequested,
      );
      if (_cancelRequested) return null;
      _runtimes[directory.path] = runtime;
      registered = true;
      unawaited(_watchRuntime(runtime));
      return IsoPlaybackLaunchResult(
        pid: pid,
        args: List.unmodifiable(args),
        sessionDirectoryPath: directory.path,
        playerIdentity: player,
        isoKey: key,
        playbackMode: PlaybackMode.webdavHdmvMenu,
      );
    } on ProcessException catch (error) {
      throw AppException.process('远程蓝光菜单播放器启动失败，请返回标题模式', error);
    } on AppException {
      if (_cancelRequested) return null;
      rethrow;
    } finally {
      try {
        if (!registered) {
          if (player != null) {
            await _processController.terminateIfOwned(
              pid: player.pid,
              expected: player,
              requirePipeOwner: false,
            );
          }
          if (handle != null) {
            await handle.cleanup();
          } else if (directory != null && await directory.exists()) {
            await _cleanupDirectory(directory);
          }
        }
      } finally {
        _operationActive = false;
      }
    }
  }

  void cancel() {
    if (!_operationActive) return;
    _cancelRequested = true;
    _accessProvider.cancel();
    _remoteMenuAccess.cancel();
  }

  Future<bool> hasActivePlayback() async {
    if (_operationActive ||
        _uncertainSessionPaths.isNotEmpty ||
        _finishingRuntimeOperations.isNotEmpty) {
      return true;
    }
    for (final runtime in List<_IsoRuntime>.of(_runtimes.values)) {
      final player = await runtime.playerTracker.probe();
      final helper = await runtime.helperTracker?.probe();
      if (player == PlayerProcessLiveness.exited &&
          (helper == null || helper == PlayerProcessLiveness.exited)) {
        await _finishRuntime(runtime);
        continue;
      }
      return true;
    }
    return false;
  }

  Future<IsoPlaybackSessionSnapshot> sessionSnapshot(
    String? sessionDirectoryPath,
  ) async {
    if (sessionDirectoryPath == null || sessionDirectoryPath.isEmpty) {
      return const IsoPlaybackSessionSnapshot(
        liveness: PlayerProcessLiveness.exited,
      );
    }
    final runtime = _runtimes[sessionDirectoryPath];
    if (runtime == null) {
      return IsoPlaybackSessionSnapshot(
        liveness: _finishingRuntimeOperations.containsKey(sessionDirectoryPath)
            ? PlayerProcessLiveness.unknown
            : PlayerProcessLiveness.exited,
        failureMessage:
            _finishingRuntimeOperations.containsKey(sessionDirectoryPath)
            ? null
            : _terminalFailureMessages.remove(sessionDirectoryPath),
      );
    }
    final states = await Future.wait([
      runtime.playerTracker.probe(),
      runtime.helperTracker?.probe() ??
          Future.value(PlayerProcessLiveness.exited),
    ]);
    if (states.every((state) => state == PlayerProcessLiveness.exited)) {
      await _finishRuntime(runtime);
      return IsoPlaybackSessionSnapshot(
        liveness: _finishingRuntimeOperations.containsKey(sessionDirectoryPath)
            ? PlayerProcessLiveness.unknown
            : PlayerProcessLiveness.exited,
        failureMessage:
            _finishingRuntimeOperations.containsKey(sessionDirectoryPath)
            ? null
            : _terminalFailureMessages.remove(sessionDirectoryPath),
      );
    }
    if (states.any((state) => state == PlayerProcessLiveness.unknown)) {
      return const IsoPlaybackSessionSnapshot(
        liveness: PlayerProcessLiveness.unknown,
      );
    }
    return IsoPlaybackSessionSnapshot(
      liveness: PlayerProcessLiveness.alive,
      paused: await _readPausedState(runtime.sessionDirectory),
    );
  }

  Future<void> sendPause(String? sessionDirectoryPath) =>
      _writeSessionCommand(sessionDirectoryPath, 'pause');

  Future<void> sendResume(String? sessionDirectoryPath) =>
      _writeSessionCommand(sessionDirectoryPath, 'resume');

  Future<PlayerTerminationOutcome> terminateSession(
    String? sessionDirectoryPath,
  ) async {
    if (sessionDirectoryPath == null || sessionDirectoryPath.isEmpty) {
      return PlayerTerminationOutcome.alreadyExited;
    }
    final runtime = _runtimes[sessionDirectoryPath];
    if (runtime == null) return PlayerTerminationOutcome.alreadyExited;
    return _processController.terminateIfOwned(
      pid: runtime.playerIdentity.pid,
      expected: runtime.playerIdentity,
      requirePipeOwner: false,
    );
  }

  @override
  Future<IsoLibraryProgress?> getLibraryProgress({
    required String profileId,
    required String resolvedUrl,
    PlaybackMode playbackMode = PlaybackMode.legacyTitle,
  }) => playbackMode == PlaybackMode.webdavHdmvMenu
      ? _getMenuLibraryProgressByKey(
          _menuKey(_buildIsoKey(profileId: profileId, resolvedUrl: resolvedUrl)),
        )
      : _getLibraryProgressByKey(
          _buildIsoKey(profileId: profileId, resolvedUrl: resolvedUrl),
        );

  Future<IsoLibraryProgress?> getLibraryProgressByKey(
    String isoKey, {
    PlaybackMode playbackMode = PlaybackMode.legacyTitle,
  }) => playbackMode == PlaybackMode.webdavHdmvMenu
      ? _getMenuLibraryProgressByKey(isoKey)
      : _getLibraryProgressByKey(isoKey);

  void dispose() {
    _disposed = true;
    cancel();
    for (final runtime in _runtimes.values) {
      runtime.playerTracker.stop();
      runtime.helperTracker?.stop();
      runtime.performanceTracker?.stop();
    }
    _libraryProgressListeners.clear();
    _terminalFailureMessages.clear();
    _cacheCoordinator?.dispose();
  }

  Future<bool?> _readPausedState(Directory sessionDirectory) async {
    try {
      final lines = await File(
        p.join(sessionDirectory.path, statusFileName),
      ).readAsLines();
      if (lines.length < 3) return null;
      return switch (lines[2].trim()) {
        '1' => true,
        '0' => false,
        _ => null,
      };
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _writeSessionCommand(
    String? sessionDirectoryPath,
    String command,
  ) async {
    if (sessionDirectoryPath == null ||
        !_runtimes.containsKey(sessionDirectoryPath)) {
      return;
    }
    try {
      await File(
        p.join(sessionDirectoryPath, commandFileName),
      ).writeAsString(command, flush: true);
    } on FileSystemException {
      // 控制文件写入失败不改变播放和续播状态。
    }
  }

  @visibleForTesting
  static List<String> buildMpvArgs({
    required PlayerConfig config,
    required String title,
    required String playlistPath,
    required int playlistStart,
    required String progressScriptPath,
    String? ipcPipeName,
    int? cacheSecs,
    int? mpvMaxBytes,
  }) {
    final args = filterIsoPlayerArguments(config.args);
    final safeTitle = title.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ').trim();
    args.addAll([
      '--resume-playback=no',
      '--save-position-on-quit=no',
      '--idle=no',
      '--keep-open=no',
      '--cookies=no',
      '--http-proxy=',
      '--rebase-start-time=yes',
      '--demuxer-lavf-linearize-timestamps=no',
      '--demuxer-lavf-o-add=correct_ts_overflow=1',
      '--cache=yes',
      '--cache-secs=${cacheSecs ?? 60}',
      '--cache-on-disk=no',
      '--cache-pause=yes',
      '--cache-pause-initial=yes',
      '--cache-pause-wait=3',
      '--demuxer-cache-wait=no',
      '--demuxer-max-bytes=${mpvMaxBytes ?? '512MiB'}',
      '--demuxer-readahead-secs=${cacheSecs ?? 60}',
      '--prefetch-playlist=no',
      if (ipcPipeName != null) '--input-ipc-server=$ipcPipeName',
      if (safeTitle.isNotEmpty) '--force-media-title=$safeTitle',
      '--script=$progressScriptPath',
      '--playlist-start=$playlistStart',
      '--playlist=$playlistPath',
    ]);
    return args;
  }

  Future<bool> _restoreRuntime(Directory directory) async {
    final manifest = File(p.join(directory.path, manifestFileName));
    if (!await manifest.exists()) {
      return _retainLegacySessionIfIsoExists(directory);
    }
    try {
      final json = jsonDecode(await manifest.readAsString());
      if (json is! Map<String, dynamic>) {
        return _retainLegacySessionIfIsoExists(directory);
      }
      final version = (json['version'] as num?)?.toInt() ?? 1;
      if (version == 1) return _restoreLegacyRuntime(directory, json);
      if (version != 2 ||
          !const ['loopback-http', 'winfsp'].contains(json['transport'])) {
        return _retainUncertainSession(directory);
      }
      final state = json['state'];
      if (state == 'bridge-starting' || state == 'launching') {
        return _restoreStartingRuntime(directory, json);
      }
      if (state == 'identity-unknown') {
        return _retainUncertainSession(directory);
      }
      if (state != 'playing') {
        return false;
      }
      final playerIdentity = PlayerProcessIdentity.fromStored(
        pid: (json['playerPid'] as num?)?.toInt(),
        executablePath: json['playerExecutablePath'] as String?,
        creationTime: (json['playerCreationTime'] as num?)?.toInt(),
      );
      final helperIdentity = PlayerProcessIdentity.fromStored(
        pid: (json['helperPid'] as num?)?.toInt(),
        executablePath: json['helperExecutablePath'] as String?,
        creationTime: (json['helperCreationTime'] as num?)?.toInt(),
      );
      if (playerIdentity == null || helperIdentity == null) {
        return _retainUncertainSession(directory);
      }
      final playerTracker = PlayerProcessLivenessTracker(
        controller: _processController,
        expectedIdentity: playerIdentity,
      );
      final helperTracker = PlayerProcessLivenessTracker(
        controller: _processController,
        expectedIdentity: helperIdentity,
      );
      final isoKey = json['isoKey'] is String ? json['isoKey'] as String : null;
      final titles = _titlesFromManifest(json['titles']);
      final journalName = json['journalFile'] is String
          ? p.basename(json['journalFile'] as String)
          : null;
      final runtime = _IsoRuntime(
        sessionDirectory: directory,
        handle: null,
        playbackMode: PlaybackModeJson.fromJson(json['playbackMode']),
        sharedResumeKey: json['sharedResumeKey'] is String &&
                RegExp(r'^[a-f0-9]{64}$').hasMatch(json['sharedResumeKey'] as String)
            ? json['sharedResumeKey'] as String : null,
        playerIdentity: playerIdentity,
        playerTracker: playerTracker,
        helperIdentity: helperIdentity,
        helperTracker: helperTracker,
        isoKey: isoKey,
        titles: titles,
        journalFile: journalName == null
            ? null
            : File(p.join(directory.path, journalName)),
      );
      final states = await Future.wait([
        playerTracker.probe(),
        helperTracker.probe(),
      ]);
      if (states.every((state) => state == PlayerProcessLiveness.exited)) {
        await _syncRuntimeProgress(runtime);
        await _cleanupDirectory(directory);
        return true;
      }
      _runtimes[directory.path] = runtime;
      unawaited(_watchRuntime(runtime));
      return true;
    } on FormatException {
      return _retainLegacySessionIfIsoExists(directory);
    } on FileSystemException {
      return false;
    } on TypeError {
      return _retainLegacySessionIfIsoExists(directory);
    }
  }

  Future<bool> _restoreStartingRuntime(
    Directory directory,
    Map<String, dynamic> json,
  ) async {
    final ownerIdentity = PlayerProcessIdentity.fromStored(
      pid: (json['ownerPid'] as num?)?.toInt(),
      executablePath: json['ownerExecutablePath'] as String?,
      creationTime: (json['ownerCreationTime'] as num?)?.toInt(),
    );
    if (ownerIdentity == null) return _retainUncertainSession(directory);
    final ownerState = await _processController.probeOwned(ownerIdentity);
    if (ownerState != PlayerProcessLiveness.exited) {
      return _retainUncertainSession(directory);
    }

    final helperIdentity = PlayerProcessIdentity.fromStored(
      pid: (json['helperPid'] as num?)?.toInt(),
      executablePath: json['helperExecutablePath'] as String?,
      creationTime: (json['helperCreationTime'] as num?)?.toInt(),
    );
    final hasHelperIdentityFields =
        json.containsKey('helperPid') ||
        json.containsKey('helperExecutablePath') ||
        json.containsKey('helperCreationTime');
    if (helperIdentity == null && hasHelperIdentityFields) {
      return _retainUncertainSession(directory);
    }
    if (helperIdentity != null) {
      final helperState = await _processController.probeOwned(helperIdentity);
      if (helperState == PlayerProcessLiveness.unknown) {
        return _retainUncertainSession(directory);
      }
      if (helperState == PlayerProcessLiveness.alive) {
        final outcome = await _processController.terminateIfOwned(
          pid: helperIdentity.pid,
          expected: helperIdentity,
          requirePipeOwner: false,
        );
        if (!outcome.isSafeToRelaunch) {
          return _retainUncertainSession(directory);
        }
      }
    }
    await _cleanupDirectory(directory);
    return true;
  }

  Future<bool> _restoreLegacyRuntime(
    Directory directory,
    Map<String, dynamic> json,
  ) async {
    if (json['state'] != 'playing') {
      return _retainLegacySessionIfIsoExists(directory);
    }
    final isoFile = File(p.join(directory.path, 'disc.iso'));
    if (!await isoFile.exists()) return false;
    final identity = PlayerProcessIdentity.fromStored(
      pid: (json['pid'] as num?)?.toInt(),
      executablePath: json['executablePath'] as String?,
      creationTime: (json['creationTime'] as num?)?.toInt(),
    );
    if (identity == null) return _retainUncertainSession(directory);
    final tracker = PlayerProcessLivenessTracker(
      controller: _processController,
      expectedIdentity: identity,
    );
    final runtime = _IsoRuntime(
      sessionDirectory: directory,
      handle: null,
      playerIdentity: identity,
      playerTracker: tracker,
      helperIdentity: null,
      helperTracker: null,
      isoKey: json['isoKey'] is String ? json['isoKey'] as String : null,
      titles: _titlesFromManifest(json['titles']),
      journalFile: json['journalFile'] is String
          ? File(
              p.join(directory.path, p.basename(json['journalFile'] as String)),
            )
          : null,
    );
    final state = await tracker.probe();
    if (state == PlayerProcessLiveness.exited) {
      await _syncRuntimeProgress(runtime);
      await _cleanupDirectory(directory);
      return true;
    }
    _runtimes[directory.path] = runtime;
    unawaited(_watchRuntime(runtime));
    return true;
  }

  Future<bool> _retainLegacySessionIfIsoExists(Directory directory) async {
    if (!await File(p.join(directory.path, 'disc.iso')).exists()) return false;
    return _retainUncertainSession(directory);
  }

  bool _retainUncertainSession(Directory directory) {
    _uncertainSessionPaths.add(directory.path);
    return true;
  }

  Future<void> _watchRuntime(_IsoRuntime runtime) async {
    while (!_disposed &&
        identical(_runtimes[runtime.sessionDirectory.path], runtime)) {
      final player = await runtime.playerTracker.probe();
      final helper = await runtime.helperTracker?.probe();
      if (runtime.playbackMode == PlaybackMode.webdavHdmvMenu &&
          helper == PlayerProcessLiveness.exited &&
          player == PlayerProcessLiveness.alive) {
        await _processController.terminateIfOwned(
          pid: runtime.playerIdentity.pid,
          expected: runtime.playerIdentity,
          requirePipeOwner: false,
        );
      }
      if (player == PlayerProcessLiveness.exited &&
          (helper == null || helper == PlayerProcessLiveness.exited)) {
        await _finishRuntime(runtime);
        return;
      }
      if (runtime.playerTracker.unknownRetryExhausted ||
          runtime.helperTracker?.unknownRetryExhausted == true) {
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  Future<void> _finishRuntime(_IsoRuntime runtime) {
    final path = runtime.sessionDirectory.path;
    final existing = _finishingRuntimeOperations[path];
    if (existing != null) return existing;
    if (!identical(_runtimes[path], runtime)) return Future<void>.value();
    late final Future<void> operation;
    operation = _finishRuntimeOnce(runtime).whenComplete(() {
      if (identical(_finishingRuntimeOperations[path], operation)) {
        _finishingRuntimeOperations.remove(path);
      }
    });
    _finishingRuntimeOperations[path] = operation;
    return operation;
  }

  Future<void> _finishRuntimeOnce(_IsoRuntime runtime) async {
    final path = runtime.sessionDirectory.path;
    runtime.playerTracker.stop();
    runtime.helperTracker?.stop();
    try {
      await _syncRuntimeProgress(runtime);
    } on FileSystemException {
      // 续播记录失败不应阻止已经退出的播放器释放会话文件。
    } on FormatException {
      // 损坏的进度日志不影响会话文件清理。
    }
    final cacheSessionId = runtime.cacheSessionId;
    if (cacheSessionId != null) {
      try {
        await _cacheCoordinator?.stopSession(cacheSessionId);
      } catch (error) {
        stderr.writeln(
          '[SPCacheSystem][ISO] Cache session finalization failed '
          '(error-type=${error.runtimeType})',
        );
      }
    }
    await runtime.performanceTracker?.finalizeAndArchive();
    if (runtime.playbackMode == PlaybackMode.webdavHdmvMenu) {
      try {
        final root = await _rootDirectory();
        final archive = Directory(
          p.join(
            root.parent.path,
            performanceArchiveDirectoryName,
            p.basename(runtime.sessionDirectory.path),
          ),
        );
        for (final name in [
          'iso-bridge-metrics.json',
          'remote-menu-mpv.json',
        ]) {
          final source = File(p.join(runtime.sessionDirectory.path, name));
          if (await source.exists()) {
            await archive.create(recursive: true);
            await source.copy(p.join(archive.path, name));
          }
        }
      } on FileSystemException catch (error) {
        stderr.writeln(
          'Remote menu metrics archive failed (${error.runtimeType})',
        );
      }
    }
    final failureMessage = await _readTerminalFailureMessage(runtime);
    if (failureMessage != null) {
      _terminalFailureMessages[path] = failureMessage;
    }
    try {
      final handle = runtime.handle;
      if (handle == null) {
        await _cleanupDirectory(runtime.sessionDirectory);
      } else {
        await handle.cleanup();
      }
    } on FileSystemException {
      // 文件占用或权限错误保留给后续启动清理。
    } finally {
      _runtimes.remove(path);
      _notifyLibraryProgressChanged();
    }
  }

  Future<String?> _readTerminalFailureMessage(_IsoRuntime runtime) async {
    final metricsFile = File(
      p.join(runtime.sessionDirectory.path, 'iso-bridge-metrics.json'),
    );
    if (await metricsFile.exists()) {
      try {
        final metrics = IsoBridgeMetricsSnapshot.tryParse(
          jsonDecode(await metricsFile.readAsString()),
        );
        final errorCode = metrics?.lastErrorCode;
        if (errorCode != null && errorCode.isNotEmpty) {
          return isoBridgePlaybackErrorMessage(errorCode);
        }
      } on FileSystemException {
        // 清理前的最终指标不可读时，继续检查 MPV 的失败记录。
      } on FormatException {
        // 损坏的最终指标不能掩盖 MPV 已记录的加载失败。
      }
    }
    if (runtime.playbackMode == PlaybackMode.webdavHdmvMenu) {
      final progress = File(
        p.join(runtime.sessionDirectory.path, '$statusFileName.progress.jsonl'),
      );
      if (await progress.exists()) {
        try {
          for (final line in (await progress.readAsLines()).reversed) {
            final record = jsonDecode(line);
            if (record is Map &&
                (record['reason'] == 'error' ||
                    (record['file_error'] is String &&
                        (record['file_error'] as String).isNotEmpty))) {
              return '蓝光菜单播放失败';
            }
          }
        } on FormatException {
          return '蓝光菜单播放失败';
        } on FileSystemException {
          return '蓝光菜单播放失败';
        }
      }
    }
    final journal = runtime.journalFile;
    if (journal == null || !await journal.exists()) return null;
    try {
      for (final line in (await journal.readAsLines()).reversed) {
        final record = _IsoJournalRecord.tryParse(line);
        if (record?.failed == true) return 'ISO Bridge 远端读取失败';
        if (record?.prematureEof == true) return 'ISO 播放流提前结束';
      }
    } on FileSystemException {
      return null;
    }
    return null;
  }

  void _notifyLibraryProgressChanged() {
    for (final listener in List<IsoLibraryProgressListener>.of(
      _libraryProgressListeners,
    )) {
      try {
        listener();
      } catch (_) {
        // 界面监听异常不能影响 ISO 会话收尾。
      }
    }
  }

  Future<PlayerProcessIdentity?> _captureIdentityWithRetry(int pid) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      final identity = await _processController.capture(pid);
      if (identity != null) return identity;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return null;
  }

  Future<PlayerProcessIdentity?> _loadOwnerIdentity() async {
    final identity =
        await (_ownerIdentityLoader?.call() ?? _captureIdentityWithRetry(pid));
    return identity != null && identity.isComplete ? identity : null;
  }

  Future<void> _writeManifest(_IsoRuntime runtime) async {
    final helperIdentity = runtime.helperIdentity;
    await _writeManifestData(runtime.sessionDirectory, <String, Object?>{
      'version': 2,
      'transport': runtime.playbackMode == PlaybackMode.webdavHdmvMenu
          ? 'winfsp'
          : 'loopback-http',
      'state': helperIdentity == null ? 'identity-unknown' : 'playing',
      if (runtime.playbackMode != PlaybackMode.legacyTitle)
        'playbackMode': runtime.playbackMode.name,
      'playerPid': runtime.playerIdentity.pid,
      'playerExecutablePath': runtime.playerIdentity.executablePath,
      'playerCreationTime': runtime.playerIdentity.creationTime,
      if (helperIdentity != null) 'helperPid': helperIdentity.pid,
      if (helperIdentity != null)
        'helperExecutablePath': helperIdentity.executablePath,
      if (helperIdentity != null)
        'helperCreationTime': helperIdentity.creationTime,
      if (runtime.isoKey != null) 'isoKey': runtime.isoKey,
      if (runtime.sharedResumeKey != null) 'sharedResumeKey': runtime.sharedResumeKey,
      if (runtime.journalFile != null)
        'journalFile': p.basename(runtime.journalFile!.path),
      if (runtime.titles.isNotEmpty)
        'titles': _titlesToManifest(runtime.titles),
      'createdAt': _now().toUtc().toIso8601String(),
    });
  }

  Future<void> _writeLaunchingManifest(
    IsoAccessHandle handle, {
    required PlayerProcessIdentity ownerIdentity,
    required String isoKey,
    required List<IsoDiscTitle> titles,
    required File? journalFile,
    String? sharedResumeKey,
    PlaybackMode playbackMode = PlaybackMode.legacyTitle,
  }) => _writeManifestData(handle.sessionDirectory, <String, Object?>{
    'version': 2,
    'transport': playbackMode == PlaybackMode.webdavHdmvMenu
        ? 'winfsp'
        : 'loopback-http',
    if (playbackMode != PlaybackMode.legacyTitle)
      'playbackMode': playbackMode.name,
    'state': 'launching',
    'ownerPid': ownerIdentity.pid,
    'ownerExecutablePath': ownerIdentity.executablePath,
    'ownerCreationTime': ownerIdentity.creationTime,
    'helperPid': handle.helperIdentity.pid,
    'helperExecutablePath': handle.helperIdentity.executablePath,
    'helperCreationTime': handle.helperIdentity.creationTime,
    'isoKey': isoKey,
    if (journalFile != null) 'journalFile': p.basename(journalFile.path),
    'sharedResumeKey': ?sharedResumeKey,
    'titles': _titlesToManifest(titles),
    'createdAt': _now().toUtc().toIso8601String(),
  });

  Future<void> _writeBridgeStartingManifest(
    Directory sessionDirectory,
    PlayerProcessIdentity ownerIdentity, {
    PlayerProcessIdentity? helperIdentity,
    PlaybackMode playbackMode = PlaybackMode.legacyTitle,
  }) => _writeManifestData(sessionDirectory, <String, Object?>{
    'version': 2,
    'transport': playbackMode == PlaybackMode.webdavHdmvMenu
        ? 'winfsp'
        : 'loopback-http',
    if (playbackMode != PlaybackMode.legacyTitle)
      'playbackMode': playbackMode.name,
    'state': 'bridge-starting',
    'ownerPid': ownerIdentity.pid,
    'ownerExecutablePath': ownerIdentity.executablePath,
    'ownerCreationTime': ownerIdentity.creationTime,
    if (helperIdentity != null) 'helperPid': helperIdentity.pid,
    if (helperIdentity != null)
      'helperExecutablePath': helperIdentity.executablePath,
    if (helperIdentity != null)
      'helperCreationTime': helperIdentity.creationTime,
    'createdAt': _now().toUtc().toIso8601String(),
  });

  static List<Map<String, Object?>> _titlesToManifest(
    List<IsoDiscTitle> titles,
  ) => titles
      .map(
        (title) => <String, Object?>{
          'titleIndex': title.titleIndex,
          'mplsId': title.mplsId,
          'durationMs': title.duration.inMilliseconds,
          'streamSize': title.streamSize,
          'chapters': title.chapters
              .map(
                (chapter) => <String, Object?>{
                  'startMs': chapter.start.inMilliseconds,
                  'durationMs': chapter.duration.inMilliseconds,
                  if (chapter.name != null) 'name': chapter.name,
                },
              )
              .toList(growable: false),
        },
      )
      .toList(growable: false);

  Future<void> _writeManifestData(
    Directory sessionDirectory,
    Map<String, Object?> data,
  ) async {
    final manifest = File(p.join(sessionDirectory.path, manifestFileName));
    final temporary = File('${manifest.path}.tmp');
    await temporary.writeAsString(jsonEncode(data), flush: true);
    if (await manifest.exists()) await manifest.delete();
    await temporary.rename(manifest.path);
  }

  IsoTitleSelection _validateSelection({
    required List<IsoDiscTitle> availableTitles,
    required IsoTitleSelection selection,
  }) {
    final available = <String, IsoDiscTitle>{
      for (final title in availableTitles) title.mplsId: title,
    };
    final orderedIds = selection.orderedTitles
        .map((title) => title.mplsId)
        .toList(growable: false);
    if (orderedIds.length != available.length ||
        orderedIds.toSet().length != available.length ||
        !orderedIds.every(available.containsKey) ||
        !selection.selectedMplsIds.every(available.containsKey)) {
      throw AppException.config('Blu-ray Title 选择结果无效');
    }
    return IsoTitleSelection(
      orderedTitles: List<IsoDiscTitle>.unmodifiable(
        orderedIds.map((id) => available[id]!),
      ),
      selectedMplsIds: Set<String>.unmodifiable(selection.selectedMplsIds),
    );
  }

  static String _buildIsoKey({
    required String profileId,
    required String resolvedUrl,
  }) {
    final uri = Uri.parse(resolvedUrl);
    final canonical = uri
        .replace(userInfo: '', query: '', fragment: '')
        .normalizePath()
        .toString();
    return sha256.convert(utf8.encode('$profileId\n$canonical')).toString();
  }

  static String _buildPipeToken(String sessionDirectoryPath) => sha256
      .convert(utf8.encode(sessionDirectoryPath))
      .toString()
      .substring(0, 24);

  static List<IsoDiscTitle> _applySavedOrder(
    List<IsoDiscTitle> titles,
    List<String> savedOrder,
  ) {
    final byId = <String, IsoDiscTitle>{
      for (final title in titles) title.mplsId: title,
    };
    final ordered = <IsoDiscTitle>[];
    for (final id in savedOrder) {
      final title = byId.remove(id);
      if (title != null) ordered.add(title);
    }
    ordered.addAll(titles.where((title) => byId.containsKey(title.mplsId)));
    return ordered;
  }

  Future<Map<String, IsoTitleResume>> _loadResumeState(
    String isoKey,
    List<IsoDiscTitle> titles,
  ) async {
    final directory = await _watchLaterDirectory(isoKey);
    final index = await const MpvWatchLaterSync().buildIndex(
      directory,
      titles.map((title) => title.resumeId),
    );
    final result = <String, IsoTitleResume>{};
    for (final title in titles) {
      final record = index.recordFor(title.resumeId);
      final seconds = record?.startSeconds;
      if (seconds == null || seconds <= 0) continue;
      result[title.mplsId] = IsoTitleResume(
        position: Duration(milliseconds: (seconds * 1000).round()),
        duration: record?.durationSeconds == null
            ? null
            : Duration(milliseconds: (record!.durationSeconds! * 1000).round()),
      );
    }
    return result;
  }

  Future<IsoLibraryProgress?> _getMenuLibraryProgressByKey(String isoKey) async {
    final menuRuntime = _runtimes.values
        .where((runtime) => runtime.isoKey == isoKey &&
            runtime.playbackMode == PlaybackMode.webdavHdmvMenu)
        .firstOrNull;
    final menuFile = File(
      p.join(
        (await _watchLaterDirectory(isoKey, create: false)).path,
        'menu-resume.json',
      ),
    );
    Map<String, dynamic>? menuRecord;
    final journal = menuRuntime?.journalFile;
    if (journal != null && await journal.exists()) {
      for (final line in (await journal.readAsLines()).reversed) {
        menuRecord = _parseMenuProgress(line);
        if (menuRecord != null) break;
      }
    }
    if (menuRecord == null && await menuFile.exists()) {
      menuRecord = _parseMenuProgress(await menuFile.readAsString());
    }
    if (menuRecord == null || menuRecord['completed'] == true) return null;
    final position = (menuRecord['position'] as num).toDouble();
    final duration = (menuRecord['duration'] as num).toDouble();
    if (position <= 0 || position / duration >= 0.99) return null;
    return IsoLibraryProgress(
      episodeNumber: (menuRecord['edition'] as int) + 1,
      episodeCount: menuRecord['editions'] as int,
      position: Duration(milliseconds: (position * 1000).round()),
      duration: Duration(milliseconds: (duration * 1000).round()),
    );
  }

  Future<IsoLibraryProgress?> _getLibraryProgressByKey(String isoKey) async {
    final saved = await (await _catalog()).load(isoKey);
    final selected = saved.selected.toSet();
    final orderedIds = saved.order
        .where((mplsId) => selected.contains(mplsId))
        .toList(growable: false);
    if (orderedIds.isEmpty) return null;
    final activeProgress = await _readActiveLibraryProgress(isoKey, orderedIds);
    if (activeProgress != null) return activeProgress;

    final resumeIds = <String, String>{
      for (final mplsId in orderedIds) mplsId: 'bd://mpls/$mplsId',
    };
    final index = await const MpvWatchLaterSync().buildIndex(
      await _watchLaterDirectory(isoKey, create: false),
      resumeIds.values,
    );
    String? activeMplsId;
    final lastMplsId = saved.lastMplsId;
    final lastPosition = lastMplsId == null
        ? null
        : index.recordFor(resumeIds[lastMplsId] ?? '')?.startSeconds;
    if (lastMplsId != null && lastPosition != null && lastPosition > 0) {
      activeMplsId = lastMplsId;
    } else {
      for (final mplsId in orderedIds) {
        final position = index.recordFor(resumeIds[mplsId]!)?.startSeconds;
        if (position != null && position > 0) {
          activeMplsId = mplsId;
          break;
        }
      }
    }
    if (activeMplsId == null) return null;
    final record = index.recordFor(resumeIds[activeMplsId]!);
    final positionSeconds = record?.startSeconds;
    if (positionSeconds == null || positionSeconds <= 0) return null;
    final durationSeconds = record?.durationSeconds;
    if (durationSeconds != null &&
        durationSeconds > 0 &&
        positionSeconds / durationSeconds >= 0.99) {
      return null;
    }
    return IsoLibraryProgress(
      episodeNumber: orderedIds.indexOf(activeMplsId) + 1,
      episodeCount: orderedIds.length,
      position: Duration(milliseconds: (positionSeconds * 1000).round()),
      duration: durationSeconds == null || durationSeconds <= 0
          ? null
          : Duration(milliseconds: (durationSeconds * 1000).round()),
    );
  }

  Future<IsoLibraryProgress?> _readActiveLibraryProgress(
    String isoKey,
    List<String> orderedIds,
  ) async {
    final runtime = _runtimes.values
        .where((value) => value.isoKey == isoKey)
        .firstOrNull;
    if (runtime == null) return null;
    try {
      final lines = await File(
        p.join(runtime.sessionDirectory.path, statusFileName),
      ).readAsLines();
      if (lines.length < 5) return null;
      final playlistPosition = int.tryParse(lines[0].trim());
      final positionSeconds = double.tryParse(lines[3].trim());
      final durationSeconds = double.tryParse(lines[4].trim());
      if (playlistPosition == null ||
          playlistPosition < 0 ||
          playlistPosition >= runtime.titles.length ||
          positionSeconds == null ||
          positionSeconds <= 0) {
        return null;
      }
      if (durationSeconds != null &&
          durationSeconds > 0 &&
          positionSeconds / durationSeconds >= 0.99) {
        return null;
      }
      final mplsId = runtime.titles[playlistPosition].mplsId;
      final episodeIndex = orderedIds.indexOf(mplsId);
      if (episodeIndex < 0) return null;
      return IsoLibraryProgress(
        episodeNumber: episodeIndex + 1,
        episodeCount: orderedIds.length,
        position: Duration(milliseconds: (positionSeconds * 1000).round()),
        duration: durationSeconds == null || durationSeconds <= 0
            ? null
            : Duration(milliseconds: (durationSeconds * 1000).round()),
      );
    } on FileSystemException {
      return null;
    }
  }

  static int _resolvePlaylistStart(
    List<IsoDiscTitle> selectedTitles,
    String? lastMplsId,
    Map<String, IsoTitleResume> resumeByMplsId,
  ) {
    if (lastMplsId != null) {
      final index = selectedTitles.indexWhere(
        (title) => title.mplsId == lastMplsId,
      );
      if (index >= 0) return index;
    }
    final resumeIndex = selectedTitles.indexWhere(
      (title) => resumeByMplsId.containsKey(title.mplsId),
    );
    return resumeIndex < 0 ? 0 : resumeIndex;
  }

  Future<_IsoCatalogStore> _catalog() async {
    final existing = _catalogStore;
    if (existing != null) return existing;
    final root = await _rootDirectory();
    final store = _IsoCatalogStore(
      File(p.join(root.parent.path, catalogFileName)),
      _now,
    );
    _catalogStore = store;
    return store;
  }

  Future<Directory> _watchLaterDirectory(
    String isoKey, {
    bool create = true,
  }) async {
    final root = await _rootDirectory();
    final directory = Directory(
      p.join(root.parent.path, watchLaterDirectoryName, isoKey),
    );
    if (create && !await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  static Future<File> _writePlaylist(
    Directory sessionDirectory, {
    required String discName,
    required List<IsoDiscTitle> titles,
    required Uri Function(String mplsId) playbackUri,
  }) async {
    final safeDisc = _safeText(discName);
    final lines = <String>['#EXTM3U'];
    for (var index = 0; index < titles.length; index++) {
      final title = titles[index];
      final label = _safeText(
        '$safeDisc · ${index + 1} · ${title.mplsId}.mpls',
      );
      lines
        ..add('#EXTINF:${title.duration.inSeconds},$label')
        ..add('#EXTVLCOPT:force-media-title=$label')
        ..add(playbackUri(title.mplsId).toString());
    }
    final file = File(p.join(sessionDirectory.path, 'iso-playlist.m3u8'));
    await file.writeAsString('${lines.join('\n')}\n', flush: true);
    return file;
  }

  static Future<File> _writeProgressScript(
    Directory sessionDirectory,
    File journalFile,
    File statusFile,
    File commandFile,
    File performanceEventsFile,
    List<IsoDiscTitle> titles,
    Map<String, IsoTitleResume> resumeByMplsId,
  ) async {
    final script = File(p.join(sessionDirectory.path, 'iso-progress.lua'));
    final journalPath = jsonEncode(journalFile.path);
    final statusPath = jsonEncode(statusFile.path);
    final statusTempPath = jsonEncode('${statusFile.path}.tmp');
    final commandPath = jsonEncode(commandFile.path);
    final performanceEventsPath = jsonEncode(performanceEventsFile.path);
    final titleDataJson = jsonEncode(
      titles
          .map(
            (title) => <String, Object?>{
              'mplsId': title.mplsId,
              'resume': resumeByMplsId[title.mplsId] == null
                  ? null
                  : resumeByMplsId[title.mplsId]!.position.inMilliseconds /
                        1000,
              'chapters': title.chapters
                  .map(
                    (chapter) => <String, Object?>{
                      'time': chapter.start.inMilliseconds / 1000,
                      if (chapter.name != null) 'title': chapter.name,
                    },
                  )
                  .toList(growable: false),
            },
          )
          .toList(growable: false),
    );
    final titleDataLiteral = jsonEncode(titleDataJson);
    await script.writeAsString('''
local utils = require "mp.utils"
local JOURNAL = $journalPath
local STATUS = $statusPath
local STATUS_TMP = $statusTempPath
local COMMAND = $commandPath
local PERFORMANCE_EVENTS = $performanceEventsPath
local TITLES = utils.parse_json($titleDataLiteral) or {}
local resumed = {}
local loaded = false
local recorded = false
local playlist_pos = -1
local path = ""
local position = -1
local duration = -1
local restart_serial = 0
local resume_pending = nil
local resume_inflight = false
local resume_restore_pause = false
local resume_target = nil
local resume_seek_issued = false
local resume_restart_floor = 0
local resume_restart_seen = false
local stability_generation = 0
local stable_restart_serial = -1
local was_seeking = false
local was_paused_for_cache = false

local function sanitize_end_reason(value)
    if value == "eof" or value == "error" or value == "stop" or
        value == "quit" or value == "redirect" then
        return value
    end
    return "unknown"
end

local function sanitize_file_error(value)
    if type(value) ~= "string" or value == "" then return nil end
    local category = string.lower(value):gsub("[^%w _%-]", "")
    category = category:gsub("%s+", "_"):sub(1, 64)
    if category == "" then return "other" end
    return category
end

local function append_performance_event(name, position_override, end_reason, file_error)
    local record = {
        event = name,
        time = mp.get_time(),
        playlist_pos = position_override or mp.get_property_number("playlist-pos", -1),
        restart_serial = restart_serial,
    }
    local event_position = mp.get_property_number("time-pos", -1)
    local event_duration = mp.get_property_number("duration", -1)
    if event_position >= 0 then record["position"] = event_position end
    if event_duration > 0 then record["duration"] = event_duration end
    if end_reason ~= nil then
        record["end_reason"] = sanitize_end_reason(end_reason)
        local category = sanitize_file_error(file_error)
        if category ~= nil then record["file_error_category"] = category end
    end
    local ok, line = pcall(utils.format_json, record)
    if not ok or line == nil then return end
    local file = io.open(PERFORMANCE_EVENTS, "a")
    if not file then return end
    file:write(line .. "\\n")
    file:flush()
    file:close()
end

local function schedule_stable_event(serial)
    stability_generation = stability_generation + 1
    local generation = stability_generation
    local initial_position = mp.get_property_number("time-pos", -1)
    local deadline = mp.get_time() + 120
    local function check()
        if generation ~= stability_generation or not loaded then return end
        if mp.get_time() >= deadline then return end
        if mp.get_property_bool("seeking", false) or resume_inflight then
            mp.add_timeout(0.1, check)
            return
        end
        local current_position = mp.get_property_number("time-pos", -1)
        if current_position >= 0 and
            (initial_position < 0 or current_position > initial_position + 0.05) then
            if stable_restart_serial ~= serial then
                stable_restart_serial = serial
                append_performance_event("stable-playback")
            end
            return
        end
        mp.add_timeout(0.1, check)
    end
    mp.add_timeout(0.1, check)
end

local function sample()
    local current_pos = mp.get_property_number("playlist-pos", -1)
    local current_path = mp.get_property("path", "")
    local current_time = mp.get_property_number("time-pos", -1)
    local current_duration = mp.get_property_number("duration", -1)
    if current_pos >= 0 then playlist_pos = current_pos end
    if current_path ~= "" then path = current_path end
    if current_time >= 0 then position = current_time end
    if current_duration > 0 then duration = current_duration end
end

local function try_finish_resume()
    if not resume_inflight or not resume_seek_issued or
        not resume_restart_seen or resume_target == nil then
        return
    end
    if mp.get_property_bool("seeking", false) then return end
    sample()
    if position < 0 or math.abs(position - resume_target) > 2.0 then return end
    resume_inflight = false
    resume_seek_issued = false
    resume_restart_seen = false
    resume_target = nil
    mp.set_property_bool("pause", resume_restore_pause)
end

local function append(outcome, reason)
    sample()
    if playlist_pos < 0 and path == "" then return end
    local record = {
        outcome = outcome,
        playlist_pos = playlist_pos,
        path = path,
    }
    if position >= 0 then record["position"] = position end
    if duration > 0 then record["duration"] = duration end
    if reason ~= nil and reason ~= "" then record["reason"] = reason end
    local ok, line = pcall(utils.format_json, record)
    if not ok or line == nil then return end
    local file = io.open(JOURNAL, "a")
    if file then
        file:write(line .. "\\n")
        file:flush()
        file:close()
    end
end

local function write_status()
    if not loaded then return end
    sample()
    local paused = mp.get_property_bool("pause", false)
    local buffering = mp.get_property_number("cache-buffering-state", -1)
    local paused_for_cache_raw = mp.get_property("paused-for-cache", nil)
    local paused_for_cache = -1
    if paused_for_cache_raw == "yes" then
        paused_for_cache = 1
    elseif paused_for_cache_raw == "no" then
        paused_for_cache = 0
    end
    local idle_raw = mp.get_property("demuxer-cache-idle", nil)
    local idle_src = "demuxer-cache-idle"
    if idle_raw == nil then
        idle_raw = mp.get_property("cache-idle", nil)
        idle_src = "cache-idle"
    end
    local cache_idle = -1
    if idle_raw == "yes" then
        cache_idle = 1
    elseif idle_raw == "no" then
        cache_idle = 0
    end
    local cstate = mp.get_property_native("demuxer-cache-state", nil)
    local bof_cached = -1
    local eof_cached = -1
    if type(cstate) == "table" then
        if cstate["bof-cached"] ~= nil then
            bof_cached = cstate["bof-cached"] and 1 or 0
        end
        if cstate["eof-cached"] ~= nil then
            eof_cached = cstate["eof-cached"] and 1 or 0
        end
    end
    local width = mp.get_property_number("width", -1)
    local height = mp.get_property_number("height", -1)
    local resolution = ""
    if width > 0 and height > 0 then
        resolution = tostring(math.floor(width)) .. "x" .. tostring(math.floor(height))
    end
    local seeking = (mp.get_property_bool("seeking", false) or resume_inflight) and 1 or 0
    local cache_duration = mp.get_property_number("demuxer-cache-duration", -1)
    local resume_state = "none"
    if resume_inflight then
        if not resume_seek_issued then
            resume_state = "scheduled"
        elseif not resume_restart_seen then
            resume_state = "seek-issued"
        else
            resume_state = "target-wait"
        end
    end
    local file = io.open(STATUS_TMP, "w")
    if not file then return end
    -- ISO 的 MPV 输入是 localhost；网络吞吐由 Bridge 远端指标提供。
    file:write(tostring(playlist_pos) .. "\\n" .. path .. "\\n" ..
        (paused and "1" or "0") .. "\\n" .. tostring(position) .. "\\n" ..
        tostring(duration) .. "\\n" .. tostring(buffering) .. "\\n-1\\n" ..
        tostring(cache_idle) .. "\\niso-bridge|-1|" .. idle_src .. "|" ..
        tostring(idle_raw) .. "|resume|" .. resume_state .. "\\n" ..
        tostring(paused_for_cache) .. "\\n" ..
        tostring(bof_cached) .. "\\n" .. tostring(eof_cached) .. "\\n" ..
        resolution .. "\\n" .. tostring(seeking) .. "\\n" ..
        tostring(restart_serial) .. "\\n" .. tostring(cache_duration))
    file:flush()
    file:close()
    os.remove(STATUS)
    os.rename(STATUS_TMP, STATUS)
end

mp.register_event("start-file", function()
    loaded = false
    recorded = false
    playlist_pos = mp.get_property_number("playlist-pos", -1)
    path = mp.get_property("path", "")
    position = -1
    duration = -1
    restart_serial = 0
    resume_pending = nil
    resume_inflight = false
    resume_target = nil
    resume_seek_issued = false
    resume_restart_floor = 0
    resume_restart_seen = false
    stability_generation = stability_generation + 1
    stable_restart_serial = -1
    was_seeking = false
    append_performance_event("start-file")
end)

mp.register_event("file-loaded", function()
    loaded = true
    sample()
    local info = TITLES[playlist_pos + 1]
    if info ~= nil then
        local chapters = {}
        for _, chapter in ipairs(info["chapters"] or {}) do
            table.insert(chapters, {
                time = chapter["time"] or 0,
                title = chapter["title"] or "",
            })
        end
        mp.set_property_native("chapter-list", chapters)
        local resume = info["resume"]
        if resume ~= nil and resume > 0 and not resumed[playlist_pos] then
            resumed[playlist_pos] = true
            resume_pending = resume
        end
    end
    write_status()
    append_performance_event("file-loaded")
end)

mp.register_event("playback-restart", function()
    if not loaded then return end
    restart_serial = restart_serial + 1
    append_performance_event("playback-restart")
    if resume_pending ~= nil and not resume_inflight then
        local target = resume_pending
        resume_pending = nil
        resume_inflight = true
        resume_target = target
        resume_seek_issued = false
        resume_restart_floor = restart_serial
        resume_restart_seen = false
        resume_restore_pause = mp.get_property_bool("pause", false)
        mp.set_property_bool("pause", true)
        mp.add_timeout(0, function()
            if not resume_inflight or resume_target ~= target then return end
            resume_seek_issued = true
            mp.commandv("seek", target, "absolute+exact")
            write_status()
        end)
    elseif resume_inflight then
        if resume_seek_issued and restart_serial > resume_restart_floor then
            resume_restart_seen = true
        end
        try_finish_resume()
    end
    write_status()
    schedule_stable_event(restart_serial)
end)

mp.add_periodic_timer(1, function()
    try_finish_resume()
    write_status()
end)

mp.observe_property("pause", "bool", function()
    write_status()
end)

mp.observe_property("paused-for-cache", "bool", function()
    local paused_now = mp.get_property_bool("paused-for-cache", false)
    if paused_now and not was_paused_for_cache then
        append_performance_event("cache-pause-start")
    elseif not paused_now and was_paused_for_cache then
        append_performance_event("cache-pause-end")
    end
    was_paused_for_cache = paused_now
    write_status()
end)

mp.observe_property("seeking", "bool", function(_, value)
    local seeking_now = value == true
    if seeking_now and not was_seeking and not resume_inflight then
        append_performance_event("seek-start")
    end
    was_seeking = seeking_now
    try_finish_resume()
    write_status()
end)

mp.add_periodic_timer(0.2, function()
    local file = io.open(COMMAND, "r")
    if not file then return end
    local command = file:read("*a") or ""
    file:close()
    os.remove(COMMAND)
    if command:find("pause") then
        mp.set_property_bool("pause", true)
    elseif command:find("resume") then
        mp.set_property_bool("pause", false)
    end
end)

mp.register_event("end-file", function(event)
    if recorded then return end
    if was_paused_for_cache then
        append_performance_event("cache-pause-end")
        was_paused_for_cache = false
    end
    local reason = event and event["reason"] or "unknown"
    local file_error = event and (event["error"] or event["file_error"]) or ""
    sample()
    local completed = reason == "eof" and position >= 0 and duration > 0 and
        position / duration >= 0.99
    if reason == "error" then
        -- stop 会清空播放列表，并在 idle=no 下按既有约束退出。
        mp.commandv("stop")
        append_performance_event("playback-failure", playlist_pos)
    end
    append_performance_event(
        completed and "title-eof" or "end-file", playlist_pos, reason, file_error)
    append(completed and "completed" or "position", reason)
    recorded = true
end)

mp.register_event("shutdown", function()
    if was_paused_for_cache then
        append_performance_event("cache-pause-end")
        was_paused_for_cache = false
    end
    append_performance_event("shutdown")
    if loaded and not recorded then
        append("position", "shutdown")
        recorded = true
    end
end)
''', flush: true);
    return script;
  }

  Future<void> _syncRuntimeProgress(_IsoRuntime runtime) async {
    final isoKey = runtime.isoKey;
    final journal = runtime.journalFile;
    if (runtime.playbackMode == PlaybackMode.webdavHdmvMenu) {
      if (isoKey == null || journal == null || !await journal.exists()) return;
      final lines = await journal.readAsLines();
      final sharedKey = runtime.sharedResumeKey;
      if (sharedKey != null) {
        final latest = <String, Map<String, dynamic>>{};
        for (final line in lines.reversed) {
          final record = _parseMenuProgress(line);
          final mpls = record?['mplsId'];
          if (mpls is String && RegExp(r'^\d{5}$').hasMatch(mpls)) {
            latest.putIfAbsent(mpls, () => record!);
          }
        }
        final directory = await _watchLaterDirectory(sharedKey);
        for (final entry in latest.entries) {
          final record = entry.value;
          final position = (record['position'] as num).toDouble();
          final duration = (record['duration'] as num).toDouble();
          final url = 'bd://mpls/${entry.key}';
          if (position == 0 || record['completed'] == true || position / duration >= 0.99) {
            await const MpvWatchLaterSync().deleteRecord(directory, url);
          } else {
            await _writeResumeRecord(directory, url,
                positionSeconds: position, durationSeconds: duration);
          }
        }
        if (latest.isNotEmpty) {
          final last = latest.values.first;
          final position = (last['position'] as num).toDouble();
          final duration = (last['duration'] as num).toDouble();
          await (await _catalog()).saveLastMpls(sharedKey,
              position == 0 || last['completed'] == true || position / duration >= 0.99
                  ? null : latest.keys.first);
        }
      }
      for (final line in lines.reversed) {
        final record = _parseMenuProgress(line);
        if (record == null) continue;
        final target = File(p.join(
          (await _watchLaterDirectory(isoKey)).path, 'menu-resume.json',
        ));
        final temporary = File('${target.path}.tmp');
        await temporary.writeAsString(jsonEncode(record), flush: true);
        await temporary.rename(target.path);
        return;
      }
      return;
    }
    if (isoKey == null || runtime.titles.isEmpty || journal == null) return;
    if (!await journal.exists()) return;
    final lines = await journal.readAsLines();
    final watchLater = await _watchLaterDirectory(isoKey);
    String? lastMplsId;
    var foundRecord = false;
    for (final line in lines) {
      final record = _IsoJournalRecord.tryParse(line);
      if (record == null) continue;
      final title = _titleForJournalRecord(record, runtime.titles);
      if (title == null) continue;
      final position = record.positionSeconds;
      final completed =
          record.completed ||
          (position != null &&
              record.durationSeconds != null &&
              record.durationSeconds! > 0 &&
              position / record.durationSeconds! >= 0.99);
      if (completed) {
        await const MpvWatchLaterSync().deleteRecord(
          watchLater,
          title.resumeId,
        );
        foundRecord = true;
        lastMplsId = null;
        continue;
      }
      if (position == null || position <= 0) continue;
      await _writeResumeRecord(
        watchLater,
        title.resumeId,
        positionSeconds: position,
        durationSeconds: record.durationSeconds,
      );
      foundRecord = true;
      lastMplsId = title.mplsId;
    }
    if (foundRecord) {
      await (await _catalog()).saveLastMpls(isoKey, lastMplsId);
    }
  }

  static String _menuKey(String isoKey) =>
      sha256.convert(utf8.encode('webdavHdmvMenu\n$isoKey')).toString();

  static Map<String, dynamic>? _parseMenuProgress(String line) {
    try {
      final value = jsonDecode(line);
      if (value is! Map<String, dynamic>) return null;
      final edition = value['edition'];
      final editions = value['editions'];
      final position = value['position'];
      final duration = value['duration'];
      if (edition is! int || editions is! int || edition < 0 ||
          edition >= editions || position is! num || !position.isFinite ||
          position < 0 || duration is! num || !duration.isFinite ||
          duration <= 0 || value['completed'] is! bool) {
        return null;
      }
      return value;
    } on FormatException {
      return null;
    }
  }

  static IsoDiscTitle? _titleForJournalRecord(
    _IsoJournalRecord record,
    List<IsoDiscTitle> titles,
  ) {
    final index = record.playlistPos;
    if (index != null && index >= 0 && index < titles.length) {
      return titles[index];
    }
    return null;
  }

  static Future<void> _writeResumeRecord(
    Directory directory,
    String playbackUrl, {
    required double positionSeconds,
    double? durationSeconds,
  }) async {
    final file = File(
      p.join(directory.path, MpvWatchLaterSync.md5FileName(playbackUrl)),
    );
    var existing = <String>[];
    if (await file.exists()) existing = await file.readAsLines();
    final output = existing
        .where(
          (line) => !RegExp(
            r'^\s*(start|duration)\s*=',
            caseSensitive: false,
          ).hasMatch(line),
        )
        .toList();
    output.insert(0, 'start=$positionSeconds');
    if (durationSeconds != null && durationSeconds > 0) {
      output.insert(1, 'duration=$durationSeconds');
    }
    await file.writeAsString('${output.join('\n')}\n', flush: true);
  }

  static List<IsoDiscTitle> _titlesFromManifest(Object? value) {
    if (value is! List) return const [];
    final titles = <IsoDiscTitle>[];
    for (final item in value) {
      if (item is! Map) continue;
      final titleIndex = item['titleIndex'];
      final mplsId = item['mplsId'];
      final durationMs = item['durationMs'];
      final streamSize = item['streamSize'];
      if (titleIndex is! num ||
          mplsId is! String ||
          !RegExp(r'^\d{5}$').hasMatch(mplsId) ||
          durationMs is! num ||
          durationMs <= 0 ||
          (streamSize != null && (streamSize is! num || streamSize < 0))) {
        continue;
      }
      titles.add(
        IsoDiscTitle(
          titleIndex: titleIndex.toInt(),
          mplsId: mplsId,
          duration: Duration(milliseconds: durationMs.toInt()),
          streamSize: (streamSize as num?)?.toInt() ?? 0,
          chapters: _chaptersFromManifest(item['chapters']),
        ),
      );
    }
    return List<IsoDiscTitle>.unmodifiable(titles);
  }

  static List<IsoDiscChapter> _chaptersFromManifest(Object? value) {
    if (value is! List) return const [];
    final chapters = <IsoDiscChapter>[];
    for (final item in value) {
      if (item is! Map) continue;
      final startMs = item['startMs'];
      final durationMs = item['durationMs'];
      final name = item['name'];
      if (startMs is! num ||
          startMs < 0 ||
          durationMs is! num ||
          durationMs < 0 ||
          (name != null && name is! String)) {
        continue;
      }
      chapters.add(
        IsoDiscChapter(
          start: Duration(milliseconds: startMs.toInt()),
          duration: Duration(milliseconds: durationMs.toInt()),
          name: name as String?,
        ),
      );
    }
    return List<IsoDiscChapter>.unmodifiable(chapters);
  }

  static String _safeText(String value) =>
      value.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ').trim();

  Future<Directory> _rootDirectory() async {
    final existing = _tempRoot;
    if (existing != null) return existing;
    final root = await _tempRootProvider();
    _tempRoot = root;
    return root;
  }

  static Future<Directory> _defaultTempRoot() async => Directory(
    p.join((await AppPaths.cacheDirectory()).path, tempDirectoryName),
  );

  Future<bool> _cleanupDirectory(Directory directory) async {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  static bool _isMpvExecutable(String executable) {
    final name = p.basenameWithoutExtension(executable.trim()).toLowerCase();
    return name == 'mpv' || name.startsWith('mpv-');
  }

  static Future<int> _startMpv(String executable, List<String> args) async {
    try {
      final process = await Process.start(
        executable,
        args,
        mode: ProcessStartMode.detached,
      );
      return process.pid;
    } on ProcessException catch (error) {
      throw AppException.process('无法启动 ISO 播放器', error);
    }
  }
}

class _IsoPerformanceTracker {
  _IsoPerformanceTracker({
    required this.sessionDirectory,
    required this.clock,
    required this.probeCompletedAtMs,
    required this.titlesReadyAtMs,
    required this.helperExecutablePath,
  }) : summaryFile = File(
         p.join(
           sessionDirectory.path,
           IsoPlaybackService.performanceSummaryFileName,
         ),
       );

  static const Duration _observerInterval = Duration(milliseconds: 50);
  static const Duration _observerDeadline = Duration(minutes: 2);
  static const int _archiveLimit = 20;

  final Directory sessionDirectory;
  final Stopwatch clock;
  final int? probeCompletedAtMs;
  final int titlesReadyAtMs;
  final String helperExecutablePath;
  final File summaryFile;
  final Set<String> _errorTypes = {};
  final List<int> _seekRecoveryMs = [];
  final List<Map<String, Object>> _seekSamples = [];
  final List<int> _titleSwitchGapMs = [];
  List<String> _orderedMplsIds = const [];
  Map<String, Object>? _cachePlanSummary;
  int _pausedForCacheCount = 0;
  int _pausedForCacheDurationMs = 0;
  int _rapidEndFileCascadeCount = 0;

  File? _metricsFile;
  File? _eventsFile;
  Timer? _timer;
  Future<void> _writeQueue = Future<void>.value();
  Future<void>? _activeSample;
  bool _stopped = false;
  int? _selectionConfirmedAtMs;
  int? _mpvLaunchAtMs;
  int? _selectionToLoopbackReadyMs;
  int? _selectionToStablePlaybackMs;
  int? _mpvLaunchToStablePlaybackMs;
  String? _helperSha256;
  String? _terminalClassification;
  String? _terminalEndReason;
  int? _terminalPositionMs;
  int? _terminalDurationMs;
  int? _terminalPlaylistPosition;
  String? _terminalFileErrorCategory;
  bool _shutdownObserved = false;

  Future<void> initialize() => _queueSummaryWrite('preparing');

  Future<void> _loadHelperHash() async {
    if (_helperSha256 != null) return;
    final helper = File(helperExecutablePath);
    try {
      if (await helper.exists()) {
        _helperSha256 = (await sha256.bind(helper.openRead()).first).toString();
      }
    } on FileSystemException {
      // 二进制身份缺失不影响播放，最终归档会保留其余诊断字段。
    }
  }

  void markSelectionConfirmed() {
    _selectionConfirmedAtMs = clock.elapsedMilliseconds;
    unawaited(_queueSummaryWrite('selected'));
  }

  void markMpvLaunch() {
    _mpvLaunchAtMs = clock.elapsedMilliseconds;
    unawaited(_queueSummaryWrite('launching'));
  }

  void markPlaybackPlan({
    required List<IsoDiscTitle> titles,
    required IsoCacheSessionPlan? cachePlan,
  }) {
    _orderedMplsIds = List<String>.unmodifiable(
      titles.map((title) => title.mplsId),
    );
    if (cachePlan != null) {
      _cachePlanSummary = <String, Object>{
        'bridgeBytes': cachePlan.bridgeBytes,
        'titles': _orderedMplsIds
            .map((mplsId) {
              final plan = cachePlan.planFor(mplsId);
              return <String, Object>{
                'playlist': mplsId,
                'bitrateMbps': plan.bitrateMbps,
                'mpvMaxBytes': plan.mpvMaxBytes,
                'totalBudgetBytes': cachePlan.bridgeBytes + plan.mpvMaxBytes,
              };
            })
            .toList(growable: false),
      };
    }
    unawaited(_queueSummaryWrite('selected'));
  }

  void startObservation({required File metricsFile, required File eventsFile}) {
    _metricsFile = metricsFile;
    _eventsFile = eventsFile;
    final deadlineMs =
        clock.elapsedMilliseconds + _observerDeadline.inMilliseconds;
    _timer = Timer.periodic(_observerInterval, (_) {
      if (clock.elapsedMilliseconds >= deadlineMs) {
        stop();
        _errorTypes.add('TimeoutException');
        unawaited(_queueSummaryWrite('observing'));
        return;
      }
      unawaited(_sample());
    });
    unawaited(_sample());
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _sample() async {
    if (_stopped) return;
    final active = _activeSample;
    if (active != null) {
      await active;
      return;
    }
    final completed = Completer<void>();
    _activeSample = completed.future;
    var changed = false;
    try {
      IsoBridgeMetricsSnapshot? metrics;
      final metricsFile = _metricsFile;
      if (metricsFile != null && await metricsFile.exists()) {
        try {
          metrics = IsoBridgeMetricsSnapshot.tryParse(
            jsonDecode(await metricsFile.readAsString()),
          );
        } on FormatException {
          // 原子替换边界上的旧快照由下一次采样重读。
        }
      }
      final selectionAt = _selectionConfirmedAtMs;
      if (_selectionToLoopbackReadyMs == null &&
          selectionAt != null &&
          metrics?.firstMediaResponseReadyMicroseconds != null) {
        _selectionToLoopbackReadyMs = clock.elapsedMilliseconds - selectionAt;
        changed = true;
      }
      if (metrics != null) {
        final previousErrorCount = _errorTypes.length;
        _errorTypes.addAll(metrics.errorTypes);
        changed = changed || _errorTypes.length != previousErrorCount;
      }

      final eventsFile = _eventsFile;
      final events = eventsFile == null
          ? const <_IsoPerformanceEvent>[]
          : await _readEvents(eventsFile, recordMalformed: false);
      final stableSeen = events.any((event) => event.name == 'stable-playback');
      if (_selectionToStablePlaybackMs == null &&
          selectionAt != null &&
          stableSeen) {
        final observedAt = clock.elapsedMilliseconds;
        _selectionToStablePlaybackMs = observedAt - selectionAt;
        final launchAt = _mpvLaunchAtMs;
        if (launchAt != null) {
          _mpvLaunchToStablePlaybackMs = observedAt - launchAt;
        }
        changed = true;
      }
      if (_selectionToStablePlaybackMs != null &&
          (_selectionToLoopbackReadyMs != null || metrics?.version == 1)) {
        stop();
      }
    } on FileSystemException {
      // 文件尚未创建或正在替换时由下一次有界采样重试。
    } catch (error) {
      changed = _errorTypes.add(error.runtimeType.toString()) || changed;
    } finally {
      if (changed) await _queueSummaryWrite('observing');
      _activeSample = null;
      completed.complete();
    }
  }

  Future<void> finalizeAndArchive() async {
    stop();
    await _activeSample;
    _stopped = false;
    await _sample();
    stop();

    final metricsFile = _metricsFile;
    if (metricsFile == null || !await metricsFile.exists()) {
      _errorTypes.add('FileSystemException');
    } else {
      try {
        final metrics = IsoBridgeMetricsSnapshot.tryParse(
          jsonDecode(await metricsFile.readAsString()),
        );
        if (metrics == null) {
          _errorTypes.add('FormatException');
        } else {
          _errorTypes.addAll(metrics.errorTypes);
          if (metrics.version == 2 && metrics.finalSnapshot != true) {
            _errorTypes.add('StateError');
          }
          final created = metrics.requestContextCreatedCount;
          final closed = metrics.requestContextClosedCount;
          final live = metrics.requestContextLive;
          if (metrics.version == 2 &&
              metrics.finalSnapshot == true &&
              created != null &&
              closed != null &&
              live != null &&
              (created != closed || live != 0)) {
            _errorTypes.add('StateError');
          }
        }
      } on FormatException {
        _errorTypes.add('FormatException');
      } on FileSystemException {
        _errorTypes.add('FileSystemException');
      }
    }

    final eventsFile = _eventsFile;
    final events = eventsFile == null
        ? const <_IsoPerformanceEvent>[]
        : await _readEvents(eventsFile, recordMalformed: true);
    _deriveMpvDurations(events);
    await _loadHelperHash();
    await _queueSummaryWrite('complete');
    await _writeQueue;
    await _archiveFinalArtifacts(metricsFile, eventsFile);
  }

  void _deriveMpvDurations(List<_IsoPerformanceEvent> events) {
    _seekRecoveryMs.clear();
    _seekSamples.clear();
    _titleSwitchGapMs.clear();
    _pausedForCacheCount = 0;
    _pausedForCacheDurationMs = 0;
    _rapidEndFileCascadeCount = 0;
    _terminalClassification = null;
    _terminalEndReason = null;
    _terminalPositionMs = null;
    _terminalDurationMs = null;
    _terminalPlaylistPosition = null;
    _terminalFileErrorCategory = null;
    _shutdownObserved = false;
    _IsoPerformanceEvent? pendingSeek;
    _IsoPerformanceEvent? pendingEof;
    _IsoPerformanceEvent? pendingCachePause;
    _IsoPerformanceEvent? previousFailure;
    for (final event in events) {
      if (event.name == 'shutdown') _shutdownObserved = true;
      if (event.name == 'cache-pause-start') {
        pendingCachePause ??= event;
      } else if (event.name == 'cache-pause-end') {
        final started = pendingCachePause;
        if (started != null && event.timeSeconds >= started.timeSeconds) {
          _pausedForCacheCount++;
          _pausedForCacheDurationMs +=
              ((event.timeSeconds - started.timeSeconds) * 1000).round();
          pendingCachePause = null;
        }
      }
      final endReason = event.endReason;
      if (endReason != null) {
        _terminalEndReason = endReason;
        _terminalPositionMs = event.positionSeconds == null
            ? null
            : (event.positionSeconds! * 1000).round();
        _terminalDurationMs = event.durationSeconds == null
            ? null
            : (event.durationSeconds! * 1000).round();
        _terminalPlaylistPosition = event.playlistPosition;
        _terminalFileErrorCategory = event.fileErrorCategory;
        _terminalClassification = switch (endReason) {
          'eof' when event.name == 'title-eof' => 'normal_eof',
          'eof' => 'premature_eof',
          'error' => 'file_error',
          'stop' || 'quit' => 'user_stop',
          'redirect' => 'redirect',
          _ => 'unknown',
        };
      }
      if (event.name == 'end-file') {
        final previous = previousFailure;
        if (previous != null &&
            event.timeSeconds >= previous.timeSeconds &&
            event.timeSeconds - previous.timeSeconds < 1) {
          _rapidEndFileCascadeCount++;
        }
        previousFailure = event;
      }
      if (event.name == 'seek-start') {
        pendingSeek = event;
      } else if (event.name == 'title-eof') {
        pendingEof = event;
      } else if (event.name == 'stable-playback') {
        final seek = pendingSeek;
        if (seek != null &&
            seek.playlistPosition == event.playlistPosition &&
            event.timeSeconds >= seek.timeSeconds) {
          _seekRecoveryMs.add(
            ((event.timeSeconds - seek.timeSeconds) * 1000).round(),
          );
          final startPosition = seek.positionSeconds;
          final endPosition = event.positionSeconds;
          if (startPosition != null && endPosition != null) {
            final playlist =
                seek.playlistPosition >= 0 &&
                    seek.playlistPosition < _orderedMplsIds.length
                ? _orderedMplsIds[seek.playlistPosition]
                : seek.playlistPosition.toString();
            _seekSamples.add(<String, Object>{
              'playlist': playlist,
              'startPositionMs': (startPosition * 1000).round(),
              'endPositionMs': (endPosition * 1000).round(),
              'recoveryMs': ((event.timeSeconds - seek.timeSeconds) * 1000)
                  .round(),
            });
          }
          pendingSeek = null;
        }
        final eof = pendingEof;
        if (eof != null &&
            eof.playlistPosition != event.playlistPosition &&
            event.timeSeconds >= eof.timeSeconds) {
          _titleSwitchGapMs.add(
            ((event.timeSeconds - eof.timeSeconds) * 1000).round(),
          );
          pendingEof = null;
        }
      }
    }
    if (_terminalClassification == null && _shutdownObserved) {
      _terminalClassification = 'shutdown';
    }
  }

  Future<List<_IsoPerformanceEvent>> _readEvents(
    File file, {
    required bool recordMalformed,
  }) async {
    if (!await file.exists()) {
      if (recordMalformed) _errorTypes.add('FileSystemException');
      return const [];
    }
    try {
      final events = <_IsoPerformanceEvent>[];
      for (final line in await file.readAsLines()) {
        if (line.trim().isEmpty) continue;
        final event = _IsoPerformanceEvent.tryParse(line);
        if (event == null) {
          if (recordMalformed) _errorTypes.add('FormatException');
          continue;
        }
        events.add(event);
      }
      return events;
    } on FileSystemException {
      if (recordMalformed) _errorTypes.add('FileSystemException');
      return const [];
    }
  }

  Future<void> _archiveFinalArtifacts(
    File? metricsFile,
    File? eventsFile,
  ) async {
    final cacheDirectory = p.dirname(p.dirname(sessionDirectory.path));
    final archiveRoot = Directory(
      p.join(
        cacheDirectory,
        IsoPlaybackService.performanceArchiveDirectoryName,
      ),
    );
    final archive = Directory(
      p.join(archiveRoot.path, p.basename(sessionDirectory.path)),
    );
    try {
      await archive.create(recursive: true);
      for (final source in <File?>[metricsFile, eventsFile]) {
        if (source != null && await source.exists()) {
          await source.copy(p.join(archive.path, p.basename(source.path)));
        }
      }
    } on FileSystemException catch (error) {
      _errorTypes.add(error.runtimeType.toString());
    }
    await _queueSummaryWrite('complete');
    await _writeQueue;
    try {
      await summaryFile.copy(
        p.join(archive.path, IsoPlaybackService.performanceSummaryFileName),
      );
      await _trimArchives(archiveRoot);
    } on FileSystemException {
      // 归档失败不影响播放会话清理。
    }
  }

  Future<void> _trimArchives(Directory archiveRoot) async {
    if (!await archiveRoot.exists()) return;
    final rootPath = p.normalize(p.absolute(archiveRoot.path));
    final archives = <({Directory directory, DateTime modified})>[];
    await for (final entity in archiveRoot.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final entityPath = p.normalize(p.absolute(entity.path));
      if (!p.isWithin(rootPath, entityPath)) continue;
      archives.add((
        directory: entity,
        modified: (await entity.stat()).modified,
      ));
    }
    archives.sort((left, right) => right.modified.compareTo(left.modified));
    for (final archive in archives.skip(_archiveLimit)) {
      await archive.directory.delete(recursive: true);
    }
  }

  Future<void> _queueSummaryWrite(String status) {
    _writeQueue = _writeQueue.then((_) async {
      try {
        final temporary = File('${summaryFile.path}.tmp');
        await temporary.writeAsString(
          jsonEncode(_summary(status)),
          flush: true,
        );
        if (await summaryFile.exists()) await summaryFile.delete();
        await temporary.rename(summaryFile.path);
      } on FileSystemException catch (error) {
        _errorTypes.add(error.runtimeType.toString());
      }
    });
    return _writeQueue;
  }

  Map<String, Object?> _summary(String status) {
    final timings = <String, Object?>{};
    final probeAt = probeCompletedAtMs;
    if (probeAt != null) {
      timings['openToProbeMs'] = probeAt;
      timings['probeToTitlesMs'] = titlesReadyAtMs - probeAt;
    }
    final loopback = _selectionToLoopbackReadyMs;
    if (loopback != null) {
      timings['selectionToLoopbackReadyMs'] = loopback;
    }
    final stable = _selectionToStablePlaybackMs;
    if (stable != null) {
      timings['selectionToStablePlaybackMs'] = stable;
    }
    final launch = _mpvLaunchToStablePlaybackMs;
    if (launch != null) {
      timings['mpvLaunchToStablePlaybackMs'] = launch;
    }
    return <String, Object?>{
      'version': 1,
      'status': status,
      'stablePlaybackProxy': 'playback-restart-seeking-false-progressing',
      'observerIntervalMs': _observerInterval.inMilliseconds,
      'timings': timings,
      'seekRecoveryMs': List<int>.unmodifiable(_seekRecoveryMs),
      'seekSamples': List<Map<String, Object>>.unmodifiable(_seekSamples),
      'titleSwitchGapMs': List<int>.unmodifiable(_titleSwitchGapMs),
      'pausedForCacheCount': _pausedForCacheCount,
      'pausedForCacheDurationMs': _pausedForCacheDurationMs,
      if (_cachePlanSummary != null) 'cachePlan': _cachePlanSummary,
      'rapidEndFileCascadeCount': _rapidEndFileCascadeCount,
      if (_helperSha256 != null) 'helperSha256': _helperSha256,
      if (_terminalClassification != null)
        'terminalClassification': _terminalClassification,
      if (_terminalEndReason != null) 'terminalEndReason': _terminalEndReason,
      if (_terminalPositionMs != null)
        'terminalPositionMs': _terminalPositionMs,
      if (_terminalDurationMs != null)
        'terminalDurationMs': _terminalDurationMs,
      if (_terminalPlaylistPosition != null)
        'terminalPlaylistPos': _terminalPlaylistPosition,
      if (_terminalFileErrorCategory != null)
        'terminalFileErrorCategory': _terminalFileErrorCategory,
      'shutdownObserved': _shutdownObserved,
      if (_errorTypes.isNotEmpty)
        'errors': _errorTypes
            .map((type) => <String, String>{'error-type': type})
            .toList(growable: false),
    };
  }
}

class _IsoPerformanceEvent {
  const _IsoPerformanceEvent({
    required this.name,
    required this.timeSeconds,
    required this.playlistPosition,
    required this.restartSerial,
    this.endReason,
    this.positionSeconds,
    this.durationSeconds,
    this.fileErrorCategory,
  });

  static const Set<String> _allowedNames = {
    'start-file',
    'file-loaded',
    'playback-restart',
    'stable-playback',
    'seek-start',
    'cache-pause-start',
    'cache-pause-end',
    'title-eof',
    'end-file',
    'playback-failure',
    'shutdown',
  };
  static const Set<String> _allowedEndReasons = {
    'eof',
    'error',
    'stop',
    'quit',
    'redirect',
    'unknown',
  };

  final String name;
  final double timeSeconds;
  final int playlistPosition;
  final int restartSerial;
  final String? endReason;
  final double? positionSeconds;
  final double? durationSeconds;
  final String? fileErrorCategory;

  static _IsoPerformanceEvent? tryParse(String line) {
    try {
      final value = jsonDecode(line);
      if (value is! Map<String, dynamic>) return null;
      final name = value['event'];
      final time = (value['time'] as num?)?.toDouble();
      final playlistPosition = (value['playlist_pos'] as num?)?.toInt();
      final restartSerial = (value['restart_serial'] as num?)?.toInt();
      final endReason = value['end_reason'];
      final position = (value['position'] as num?)?.toDouble();
      final duration = (value['duration'] as num?)?.toDouble();
      final fileErrorCategory = value['file_error_category'];
      if (name is! String ||
          !_allowedNames.contains(name) ||
          time == null ||
          !time.isFinite ||
          time < 0 ||
          playlistPosition == null ||
          playlistPosition < -1 ||
          restartSerial == null ||
          restartSerial < 0 ||
          (endReason != null &&
              (endReason is! String ||
                  !_allowedEndReasons.contains(endReason))) ||
          (position != null && (!position.isFinite || position < 0)) ||
          (duration != null && (!duration.isFinite || duration <= 0)) ||
          (fileErrorCategory != null &&
              (fileErrorCategory is! String ||
                  !RegExp(
                    r'^[a-z0-9_-]{1,64}$',
                  ).hasMatch(fileErrorCategory)))) {
        return null;
      }
      return _IsoPerformanceEvent(
        name: name,
        timeSeconds: time,
        playlistPosition: playlistPosition,
        restartSerial: restartSerial,
        endReason: endReason as String?,
        positionSeconds: position,
        durationSeconds: duration,
        fileErrorCategory: fileErrorCategory as String?,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}

class _IsoJournalRecord {
  const _IsoJournalRecord({
    required this.completed,
    required this.failed,
    required this.playlistPos,
    required this.path,
    required this.positionSeconds,
    required this.durationSeconds,
    required this.reason,
  });

  final bool completed;
  final bool failed;
  final int? playlistPos;
  final String path;
  final double? positionSeconds;
  final double? durationSeconds;
  final String? reason;

  bool get prematureEof {
    final position = positionSeconds;
    final duration = durationSeconds;
    return !completed &&
        reason == 'eof' &&
        position != null &&
        duration != null &&
        duration > 0 &&
        position / duration < 0.99;
  }

  static _IsoJournalRecord? tryParse(String line) {
    if (line.trim().isEmpty) return null;
    try {
      final value = jsonDecode(line);
      if (value is! Map<String, dynamic>) return null;
      final outcome = value['outcome'];
      if (outcome != 'position' && outcome != 'completed') return null;
      return _IsoJournalRecord(
        completed: outcome == 'completed',
        failed: value['reason'] == 'error',
        playlistPos: (value['playlist_pos'] as num?)?.toInt(),
        path: value['path'] is String ? value['path'] as String : '',
        positionSeconds: (value['position'] as num?)?.toDouble(),
        durationSeconds: (value['duration'] as num?)?.toDouble(),
        reason: value['reason'] is String ? value['reason'] as String : null,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}

class _IsoCatalogRecord {
  const _IsoCatalogRecord({
    this.order = const [],
    this.selected = const [],
    this.lastMplsId,
  });

  final List<String> order;
  final List<String> selected;
  final String? lastMplsId;

  factory _IsoCatalogRecord.fromJson(Object? value) {
    if (value is! Map) return const _IsoCatalogRecord();
    List<String> ids(Object? raw) => raw is List
        ? raw
              .whereType<String>()
              .where((id) => RegExp(r'^\d{5}$').hasMatch(id))
              .toSet()
              .toList(growable: false)
        : const [];
    final last = value['lastMplsId'];
    return _IsoCatalogRecord(
      order: ids(value['order']),
      selected: ids(value['selected']),
      lastMplsId: last is String && RegExp(r'^\d{5}$').hasMatch(last)
          ? last
          : null,
    );
  }

  Map<String, Object?> toJson(DateTime updatedAt) => <String, Object?>{
    'order': order,
    'selected': selected,
    if (lastMplsId != null) 'lastMplsId': lastMplsId,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}

class _IsoCatalogStore {
  _IsoCatalogStore(this.file, this.now);

  final File file;
  final DateTime Function() now;

  Future<_IsoCatalogRecord> load(String isoKey) async {
    final all = await _readAll();
    return all[isoKey] ?? const _IsoCatalogRecord();
  }

  Future<void> saveSelection(
    String isoKey, {
    required List<String> order,
    required List<String> selected,
  }) async {
    final all = await _readAll();
    final current = all[isoKey] ?? const _IsoCatalogRecord();
    all[isoKey] = _IsoCatalogRecord(
      order: List<String>.unmodifiable(order),
      selected: List<String>.unmodifiable(selected),
      lastMplsId: current.lastMplsId,
    );
    await _writeAll(all);
  }

  Future<void> saveLastMpls(String isoKey, String? mplsId) async {
    final all = await _readAll();
    final current = all[isoKey] ?? const _IsoCatalogRecord();
    all[isoKey] = _IsoCatalogRecord(
      order: current.order,
      selected: current.selected,
      lastMplsId: mplsId,
    );
    await _writeAll(all);
  }

  Future<Map<String, _IsoCatalogRecord>> _readAll() async {
    if (!await file.exists()) return <String, _IsoCatalogRecord>{};
    try {
      final root = jsonDecode(await file.readAsString());
      if (root is! Map<String, dynamic> || root['discs'] is! Map) {
        return <String, _IsoCatalogRecord>{};
      }
      final discs = root['discs'] as Map;
      return <String, _IsoCatalogRecord>{
        for (final entry in discs.entries)
          if (entry.key is String)
            entry.key as String: _IsoCatalogRecord.fromJson(entry.value),
      };
    } on FormatException {
      return <String, _IsoCatalogRecord>{};
    } on TypeError {
      return <String, _IsoCatalogRecord>{};
    }
  }

  Future<void> _writeAll(Map<String, _IsoCatalogRecord> records) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode(<String, Object?>{
        'version': 1,
        'discs': <String, Object?>{
          for (final entry in records.entries)
            entry.key: entry.value.toJson(now()),
        },
      }),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }
}
