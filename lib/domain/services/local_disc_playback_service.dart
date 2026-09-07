import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../../core/errors/app_exception.dart';
import '../../core/utils/app_paths.dart';
import '../../data/local/media_library_store.dart';
import '../../data/local/playback_progress_db.dart';
import '../../data/local/stream_path_config_store.dart';
import '../../data/models/media_library_item.dart';
import '../../data/models/media_source.dart';
import '../../data/models/player_config.dart';
import 'iso_playback_service.dart';
import 'mpv_scripts.dart';
import 'player_process_controller.dart';

enum LocalDiscLaunchMode { menu, longestTitle }

class LocalDiscPlaybackResult {
  const LocalDiscPlaybackResult({
    required this.sessionId,
    required this.process,
    required this.args,
    required this.mode,
    required this.rootId,
    required this.relativePath,
    required this.devicePath,
    required this.fingerprint,
    required this.size,
    required this.modified,
    this.processIdentity,
  });

  final String sessionId;
  final Process process;
  final List<String> args;
  final LocalDiscLaunchMode mode;
  final String rootId;
  final String relativePath;
  final String devicePath;
  final String fingerprint;
  final int size;
  final DateTime modified;
  final PlayerProcessIdentity? processIdentity;
  PlaybackMode get playbackMode => PlaybackMode.localHdmvMenu;
}

class LocalDiscSessionStatus {
  const LocalDiscSessionStatus({required this.running, this.paused});

  final bool running;
  final bool? paused;
}

class _LocalDiscRuntime {
  _LocalDiscRuntime({
    required this.result,
    required this.tracker,
    required this.profileId,
    required this.statusFilePath,
    required this.commandFilePath,
    required this.ipcPipeName,
    required this.allowInitialEditionProgress,
  });

  final LocalDiscPlaybackResult result;
  final PlayerProcessLivenessTracker tracker;
  final String profileId;
  final String statusFilePath;
  final String commandFilePath;
  final String ipcPipeName;
  final bool allowInitialEditionProgress;
  int? lastSavedPositionMs;
  int? initialEdition;
  int? currentEdition;
  int? editionCount;
  int? storedEdition;
  bool? lastPaused;
  DateTime? lastProgressPersistedAt;
  bool menuObserved = false;
}

/// 本地 ISO/BDMV 的受控 MPV 启动与播放进度服务。
class LocalDiscPlaybackService implements IsoLibraryProgressReader {
  factory LocalDiscPlaybackService({
    required StreamPathConfigStore configStore,
    required PlaybackProgressService progressService,
    MediaLibraryStore? mediaLibraryStore,
    PlayerProcessController? processController,
  }) => LocalDiscPlaybackService._(
    configStore,
    progressService,
    mediaLibraryStore,
    processController ?? PlayerProcessController(),
  );

  LocalDiscPlaybackService._(
    this._configStore,
    this._progressService,
    this._mediaLibraryStore,
    this._processController,
  ) {
    _progressService.addListener(_handleProgressChanged);
  }

  final StreamPathConfigStore _configStore;
  final PlaybackProgressService _progressService;
  final MediaLibraryStore? _mediaLibraryStore;
  final PlayerProcessController _processController;
  final Map<String, _LocalDiscRuntime> _sessions = {};
  final Set<IsoLibraryProgressListener> _libraryProgressListeners = {};
  bool _disposed = false;

  Future<LocalDiscPlaybackResult> launch({
    required String rootId,
    required String relativePath,
    required String devicePath,
    required LocalDiscLaunchMode mode,
    bool resumeFromSavedPosition = false,
    int? resumeEdition,
    String? expectedFingerprint,
  }) async {
    if (_disposed) {
      throw AppException.process('本地蓝光播放服务已关闭');
    }
    final config = (await _configStore.load()).toPlayerConfig();
    final executableError = validateExecutable(config);
    if (executableError != null) {
      throw AppException.config(executableError);
    }
    final stat = await _discStat(devicePath);
    final fingerprint = _fingerprint(
      relativePath: relativePath,
      size: stat.size,
      modified: stat.modified,
    );
    if (resumeFromSavedPosition &&
        expectedFingerprint != null &&
        fingerprint != expectedFingerprint) {
      throw AppException.config('本地蓝光内容已变更，请从头播放');
    }
    if (_disposed) {
      throw AppException.process('本地蓝光播放服务已关闭');
    }

    final now = DateTime.now().microsecondsSinceEpoch;
    final sessionId = 'local_disc_${now}_${_sessions.length + 1}';
    final launchEpoch = '$now';
    final profileId = 'local:$rootId';
    final pipeName = '${r'\\.\pipe\streampath_local_disc_'}$now';
    final dataDirectory = await AppPaths.cacheDirectory();
    final statusFilePath = p.join(
      dataDirectory.path,
      'local-disc-current-$sessionId.txt',
    );
    final commandFilePath = p.join(
      dataDirectory.path,
      'local-disc-command-$sessionId.txt',
    );
    final progressFilePath = p.join(
      dataDirectory.path,
      'local-disc-progress-$sessionId.jsonl',
    );
    final progressFile = File(progressFilePath);
    if (await progressFile.exists()) await progressFile.delete();
    final progressScriptPath = await MpvScripts.ensureCurrent(
      statusFilePath,
      commandFilePath,
      dataDirectory,
      sessionId: sessionId,
      progressFile: progressFilePath,
      launchEpoch: launchEpoch,
      reportedPath: devicePath,
    );
    final resume = config.resumeEnabled && resumeFromSavedPosition
        ? await _progressService.getResumeProgress(
            devicePath,
            profileId: profileId,
          )
        : null;
    final args = buildMpvArgs(
      config,
      devicePath: devicePath,
      mode: mode,
      ipcPipeName: pipeName,
      progressScriptPath: progressScriptPath,
      resumeEdition: resumeEdition,
      resumeSeconds: resume != null && resume.positionMs > 0
          ? resume.positionMs ~/ 1000
          : null,
    );
    final Process process;
    try {
      process = await Process.start(
        config.executable,
        args,
        mode: ProcessStartMode.detached,
      );
    } on FileSystemException catch (error) {
      throw AppException.process(
        '无法启动播放器「${config.executable}」：文件不存在或路径错误',
        error,
      );
    } on ProcessException catch (error) {
      throw AppException.process('播放器启动失败：${error.message}', error);
    }
    final identity = await _processController.capture(process.pid);
    final result = LocalDiscPlaybackResult(
      sessionId: sessionId,
      process: process,
      args: List.unmodifiable(args),
      mode: mode,
      rootId: rootId,
      relativePath: relativePath,
      devicePath: devicePath,
      fingerprint: fingerprint,
      size: stat.size,
      modified: stat.modified,
      processIdentity: identity,
    );
    final runtime = _LocalDiscRuntime(
      result: result,
      tracker: PlayerProcessLivenessTracker(
        controller: _processController,
        expectedIdentity: identity,
        initialStatus: identity == null
            ? PlayerProcessLiveness.unknown
            : PlayerProcessLiveness.alive,
      ),
      profileId: profileId,
      statusFilePath: statusFilePath,
      commandFilePath: commandFilePath,
      ipcPipeName: pipeName,
      allowInitialEditionProgress:
          resumeFromSavedPosition && resumeEdition != null,
    );
    _sessions[sessionId] = runtime;
    unawaited(_watchExit(runtime));
    return result;
  }

  /// 释放探活任务；不会终止由本服务启动的播放器进程。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _progressService.removeListener(_handleProgressChanged);
    for (final runtime in _sessions.values) {
      runtime.tracker.stop();
    }
    _sessions.clear();
    _libraryProgressListeners.clear();
  }

  Future<bool> isPlayerRunning(String sessionId) async {
    return (await sessionStatus(sessionId)).running;
  }

  Future<LocalDiscSessionStatus> sessionStatus(String sessionId) async {
    final runtime = _sessions[sessionId];
    if (runtime == null) return const LocalDiscSessionStatus(running: false);
    final liveness = await runtime.tracker.sample();
    if (liveness == PlayerProcessLiveness.exited) {
      return const LocalDiscSessionStatus(running: false);
    }
    bool? paused;
    try {
      final lines = await File(runtime.statusFilePath).readAsLines();
      if (lines.length >= 3) paused = lines[2].trim() == '1';
    } on FileSystemException {
      // MPV 尚未写出首个状态时保持未知。
    }
    return LocalDiscSessionStatus(running: true, paused: paused);
  }

  Future<PlayerTerminationOutcome> terminateSession(String sessionId) async {
    final runtime = _sessions[sessionId];
    if (runtime == null) return PlayerTerminationOutcome.alreadyExited;
    await _saveFinalProgress(runtime);
    final result = runtime.result;
    final outcome = await _processController.terminateIfOwned(
      pid: result.process.pid,
      expected: result.processIdentity,
      ipcPipeName: runtime.ipcPipeName,
      requirePipeOwner: true,
    );
    if (outcome.isSafeToRelaunch && identical(_sessions[sessionId], runtime)) {
      runtime.tracker.stop();
      _sessions.remove(sessionId);
      _notifyLibraryProgress();
    }
    return outcome;
  }

  Future<void> sendPause(String sessionId) => _writeCommand(sessionId, 'pause');

  Future<void> sendResume(String sessionId) =>
      _writeCommand(sessionId, 'resume');

  Future<void> _writeCommand(String sessionId, String command) async {
    final runtime = _sessions[sessionId];
    if (runtime == null) return;
    await File(runtime.commandFilePath).writeAsString(command, flush: true);
  }

  Future<void> _watchExit(_LocalDiscRuntime runtime) async {
    while (identical(_sessions[runtime.result.sessionId], runtime)) {
      final liveness = await runtime.tracker.sample();
      if (liveness == PlayerProcessLiveness.exited) {
        runtime.tracker.stop();
        await _saveFinalProgress(runtime);
        _sessions.remove(runtime.result.sessionId);
        _notifyLibraryProgress();
        return;
      }
      try {
        await _saveLiveProgress(runtime);
      } catch (error) {
        // ignore: avoid_print
        print(
          'Local disc progress update failed '
          '(error-type=${error.runtimeType})',
        );
      }
      final delay = runtime.tracker.nextProbeDelay;
      if (delay == null) return;
      await Future<void>.delayed(delay);
    }
  }

  Future<void> _saveLiveProgress(
    _LocalDiscRuntime runtime, {
    bool force = false,
  }) async {
    final file = File(runtime.statusFilePath);
    if (!await file.exists()) return;
    final lines = await file.readAsLines();
    if (lines.length >= 3) {
      final paused = switch (lines[2].trim()) {
        '1' => true,
        '0' => false,
        _ => null,
      };
      if (paused != null && paused != runtime.lastPaused) {
        runtime.lastPaused = paused;
        _notifyLibraryProgress();
      }
    }
    if (int.tryParse(lines.first.trim()) == -1) {
      if (runtime.currentEdition != null) {
        await _progressService.deleteProgress(
          runtime.result.devicePath,
          profileId: runtime.profileId,
        );
      }
      return;
    }
    if (lines.length < 21) return;
    final menuActive = int.tryParse(lines[18].trim());
    final currentEdition = int.tryParse(lines[19].trim());
    final editionCount = int.tryParse(lines[20].trim());
    if (menuActive == 1) {
      runtime.menuObserved = true;
      return;
    }
    if (menuActive != 0 ||
        currentEdition == null ||
        currentEdition < 0 ||
        editionCount == null ||
        editionCount <= 0 ||
        currentEdition >= editionCount) {
      return;
    }
    runtime.initialEdition ??= currentEdition;
    if (!isStableDiscTitle(
      mode: runtime.result.mode,
      currentEdition: currentEdition,
      initialEdition: runtime.initialEdition!,
      menuObserved: runtime.menuObserved,
      allowInitialEditionProgress: runtime.allowInitialEditionProgress,
    )) {
      return;
    }
    final titleChanged = runtime.currentEdition != currentEdition;
    runtime.currentEdition = currentEdition;
    runtime.editionCount = editionCount;
    final position = double.tryParse(lines[3].trim());
    final duration = double.tryParse(lines[4].trim());
    if (position == null || position <= 0) return;
    final positionMs = (position * 1000).round();
    if (runtime.lastSavedPositionMs == positionMs) return;
    final now = DateTime.now();
    if (!force &&
        !titleChanged &&
        runtime.lastProgressPersistedAt != null &&
        now.difference(runtime.lastProgressPersistedAt!) <
            const Duration(seconds: 10)) {
      return;
    }
    runtime.lastSavedPositionMs = positionMs;
    if (runtime.storedEdition != currentEdition) {
      final stored = await _mediaLibraryStore?.updateLocalDiscTitleContext(
        sourceId: runtime.profileId,
        playbackSessionId: runtime.result.sessionId,
        currentEdition: currentEdition,
        editionCount: editionCount,
      );
      if (stored == true) runtime.storedEdition = currentEdition;
    }
    await _progressService.saveProgress(
      url: runtime.result.devicePath,
      positionMs: positionMs,
      durationMs: duration != null && duration > 0
          ? (duration * 1000).round()
          : null,
      profileId: runtime.profileId,
    );
    runtime.lastProgressPersistedAt = now;
  }

  Future<void> _saveFinalProgress(_LocalDiscRuntime runtime) async {
    try {
      await _saveLiveProgress(runtime, force: true);
    } catch (error) {
      // ignore: avoid_print
      print(
        'Local disc final progress synchronization failed '
        '(error-type=${error.runtimeType})',
      );
    }
  }

  @override
  void addLibraryProgressListener(IsoLibraryProgressListener listener) {
    _libraryProgressListeners.add(listener);
  }

  @override
  void removeLibraryProgressListener(IsoLibraryProgressListener listener) {
    _libraryProgressListeners.remove(listener);
  }

  @override
  Future<IsoLibraryProgress?> getLibraryProgress({
    required String profileId,
    required String resolvedUrl,
    PlaybackMode playbackMode = PlaybackMode.legacyTitle,
  }) async {
    final progress = await _progressService.getResumeProgress(
      resolvedUrl,
      profileId: profileId,
    );
    if (progress == null || progress.positionMs <= 0) return null;
    final durationMs = progress.durationMs;
    if (durationMs != null &&
        durationMs > 0 &&
        progress.positionMs / durationMs >= 0.99) {
      return null;
    }
    final titleContext = await _readDiscContext(profileId, resolvedUrl);
    if (titleContext != null && !titleContext.snapshotMatches) return null;
    return IsoLibraryProgress(
      episodeNumber: (titleContext?.currentEdition ?? 0) + 1,
      episodeCount: titleContext?.editionCount ?? 1,
      position: Duration(milliseconds: progress.positionMs),
      duration: durationMs == null ? null : Duration(milliseconds: durationMs),
    );
  }

  Future<({int? currentEdition, int? editionCount, bool snapshotMatches})?>
  _readDiscContext(String profileId, String resolvedUrl) async {
    final store = _mediaLibraryStore;
    if (store == null) return null;
    final history = await store.playbackHistory(
      profileId,
      audio: false,
      iso: true,
    );
    final normalizedDevice = p.normalize(resolvedUrl).toLowerCase();
    final snapshots = history
        .map((record) => record.localDiscSession)
        .whereType<LocalDiscSessionSnapshot>();
    LocalDiscSessionSnapshot? snapshot;
    for (final candidate in snapshots.where(
      (candidate) => candidate.relativePath.isNotEmpty,
    )) {
      final relative = candidate.relativePath.replaceAll('/', p.separator);
      if (normalizedDevice.endsWith(
        '${p.separator}${p.normalize(relative).toLowerCase()}',
      )) {
        snapshot = candidate;
        break;
      }
    }
    snapshot ??= snapshots
        .where((candidate) => candidate.relativePath.isEmpty)
        .firstOrNull;
    if (snapshot == null) return null;
    return (
      currentEdition: snapshot.currentEdition,
      editionCount: snapshot.editionCount,
      snapshotMatches: await matchesSnapshot(
        snapshot: snapshot,
        devicePath: resolvedUrl,
      ),
    );
  }

  static Future<bool> matchesSnapshot({
    required LocalDiscSessionSnapshot snapshot,
    required String devicePath,
  }) async {
    try {
      final stat = await _discStat(devicePath);
      return _fingerprint(
            relativePath: snapshot.relativePath,
            size: stat.size,
            modified: stat.modified,
          ) ==
          snapshot.fingerprint;
    } on AppException {
      return false;
    } on FileSystemException {
      return false;
    }
  }

  void _handleProgressChanged(PlaybackProgressChange change) {
    if (!change.affectsAll &&
        !_sessions.values.any(
          (runtime) =>
              runtime.profileId == change.profileId &&
              runtime.result.devicePath == change.url,
        )) {
      return;
    }
    _notifyLibraryProgress();
  }

  void _notifyLibraryProgress() {
    for (final listener in List<IsoLibraryProgressListener>.of(
      _libraryProgressListeners,
    )) {
      listener();
    }
  }

  static String? validateExecutable(PlayerConfig config) {
    final executable = config.executable.trim();
    if (executable.isEmpty) {
      return '未配置播放器路径，请先在「设置」中配置';
    }
    if (!p.basename(executable).toLowerCase().contains('mpv')) {
      return '本地蓝光菜单需要使用 MPV 播放器';
    }
    if ((executable.contains('\\') || executable.contains('/')) &&
        !File(executable).existsSync()) {
      return '播放器文件不存在：$executable';
    }
    return null;
  }

  @visibleForTesting
  static bool isStableDiscTitle({
    required LocalDiscLaunchMode mode,
    required int currentEdition,
    required int initialEdition,
    required bool menuObserved,
    required bool allowInitialEditionProgress,
  }) =>
      mode == LocalDiscLaunchMode.longestTitle ||
      allowInitialEditionProgress ||
      menuObserved ||
      currentEdition != initialEdition;

  @visibleForTesting
  static List<String> buildMpvArgs(
    PlayerConfig config, {
    required String devicePath,
    required LocalDiscLaunchMode mode,
    required String ipcPipeName,
    String? progressScriptPath,
    int? resumeSeconds,
    int? resumeEdition,
  }) => <String>[
    ...filterUserArgs(config.args),
    '--idle=no',
    '--keep-open=no',
    '--input-ipc-server=$ipcPipeName',
    '--bluray-device=$devicePath',
    if (progressScriptPath != null) '--script=$progressScriptPath',
    if (resumeEdition != null && resumeEdition >= 0) '--edition=$resumeEdition',
    if (resumeSeconds != null && resumeSeconds > 0) '--start=$resumeSeconds',
    mode == LocalDiscLaunchMode.menu ? 'bd://menu' : 'bd://longest',
  ];

  static List<String> filterUserArgs(List<String> arguments) {
    final output = <String>[];
    for (final raw in arguments) {
      final value = raw.trim();
      if (value.isEmpty || value.contains('{') || value.contains('}')) continue;
      final normalized = value.toLowerCase();
      if (!value.startsWith('-') ||
          normalized.contains('bd://') ||
          _blockedPrefixes.any(normalized.startsWith)) {
        continue;
      }
      output.add(value);
    }
    return output;
  }

  static const _blockedPrefixes = <String>[
    '--bluray-device',
    '--input-ipc-server',
    '--idle',
    '--keep-open',
    '--edition',
    '--playlist',
  ];

  static Future<FileStat> _discStat(String devicePath) async {
    final type = await FileSystemEntity.type(devicePath, followLinks: true);
    if (type == FileSystemEntityType.file) return File(devicePath).stat();
    if (type == FileSystemEntityType.directory) {
      final stat = await File(p.join(devicePath, 'BDMV', 'index.bdmv')).stat();
      if (stat.type == FileSystemEntityType.file) return stat;
    }
    throw AppException.config('请选择 Blu-ray ISO 或有效的 BDMV 文件夹');
  }

  static String _fingerprint({
    required String relativePath,
    required int size,
    required DateTime modified,
  }) => sha256
      .convert(
        utf8.encode(
          '${relativePath.replaceAll('\\', '/')}\n$size\n${modified.millisecondsSinceEpoch}',
        ),
      )
      .toString();
}
