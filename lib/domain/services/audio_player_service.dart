import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../../core/errors/app_exception.dart';
import '../../core/utils/app_paths.dart';
import '../../core/utils/url_utils.dart';
import '../../data/local/playback_progress_db.dart';
import '../../data/local/stream_path_config_store.dart';
import '../../data/models/audio_media_entry.dart';
import 'audio_lyrics_localizer.dart';
import 'audio_mpv_scripts.dart';
import 'mpv_idle_completion_marker.dart';
import 'mpv_playback_progress_sync.dart';
import 'mpv_watch_later_sync.dart';
import 'player_process_controller.dart';
import 'session_progress_sync_coordinator.dart';

class AudioPlayerLaunchResult {
  const AudioPlayerLaunchResult({
    required this.process,
    required this.args,
    required this.sessionId,
    required this.launchEpoch,
    this.processIdentity,
    required this.ipcPipeName,
    required this.statusFilePath,
    required this.commandFilePath,
    required this.progressFilePath,
    required this.playlistFilePath,
  });

  final Process process;
  final List<String> args;
  final String sessionId;
  final String launchEpoch;
  final PlayerProcessIdentity? processIdentity;
  final String ipcPipeName;
  final String statusFilePath;
  final String commandFilePath;
  final String progressFilePath;
  final String playlistFilePath;
}

class _AudioSessionRuntime {
  _AudioSessionRuntime({
    required this.sessionId,
    required this.pid,
    this.processIdentity,
    required this.livenessTracker,
    required this.ipcPipeName,
    required this.statusFilePath,
    required this.commandFilePath,
    required this.progressFilePath,
    required this.entries,
    required this.watchLaterUrls,
    required this.localizedLyricsFiles,
    required this.launchEpoch,
    required this.artifactSessionId,
    required this.progressGeneration,
    required this.ownershipGeneration,
    this.profileId = '',
  });

  final String sessionId;
  final int? pid;
  final PlayerProcessIdentity? processIdentity;
  final PlayerProcessLivenessTracker livenessTracker;
  final String? ipcPipeName;
  final String statusFilePath;
  final String commandFilePath;
  final String progressFilePath;
  final List<AudioMediaEntry> entries;
  final List<String> watchLaterUrls;
  final List<File> localizedLyricsFiles;
  final String launchEpoch;
  final String artifactSessionId;
  final int progressGeneration;
  final int ownershipGeneration;
  final String profileId;
  Future<void>? exitSyncFuture;
  Future<PlayerTerminationOutcome>? terminationFuture;
}

/// 独立的 MPV 音频播放服务。
///
/// 音频只共享稳定的 MPV 状态/进度协议，不访问视频缓存策略、动态缓存
/// 监控、OpenList 恢复或字幕匹配服务。所有应用层缓存参数都会从音频
/// 启动模板中移除，使 MPV 使用自身默认缓存行为。
class AudioPlayerService {
  factory AudioPlayerService({
    required StreamPathConfigStore configStore,
    required PlaybackProgressService progressService,
    Directory? watchLaterDirectory,
    PlayerProcessController? processController,
  }) => AudioPlayerService._(
    configStore,
    progressService,
    watchLaterDirectory,
    processController ?? PlayerProcessController(),
  );

  AudioPlayerService._(
    this._configStore,
    this._progressService,
    this._watchLaterDirectory,
    this._processController,
  );

  final StreamPathConfigStore _configStore;
  final PlaybackProgressService _progressService;
  final PlayerProcessController _processController;
  Directory? _watchLaterDirectory;
  final Map<String, _AudioSessionRuntime> _sessions = {};
  final Map<String, int> _launchOwnership = {};
  final SessionProgressSyncCoordinator _progressSyncCoordinator =
      SessionProgressSyncCoordinator();
  final AudioLyricsLocalizer _lyricsLocalizer = const AudioLyricsLocalizer();
  int _launchSequence = 0;
  int _ownershipSequence = 0;

  bool _ownsLaunch(String sessionId, int generation) =>
      _launchOwnership[sessionId] == generation;

  void _ensureLaunchOwnership(String sessionId, int generation) {
    if (!_ownsLaunch(sessionId, generation)) {
      throw AppException.process('该音频启动已被同会话的新请求取代');
    }
  }

  Future<AudioPlayerLaunchResult> launch({
    required List<AudioMediaEntry> entries,
    required String sessionId,
    int playlistStart = 0,
    int? resumeSeconds,
    String? username,
    String? password,
    AudioLyricsBytesLoader? lyricsLoader,
  }) async {
    if (entries.isEmpty) {
      throw AppException.config('音频播放列表为空，无法启动播放器');
    }
    if (playlistStart < 0 || playlistStart >= entries.length) {
      playlistStart = 0;
    }
    final ownershipGeneration = ++_ownershipSequence;
    _launchOwnership[sessionId] = ownershipGeneration;
    final existing = _sessions[sessionId];
    try {
      if (existing != null) {
        final liveness = await _processController.probeOwned(
          existing.processIdentity,
        );
        _ensureLaunchOwnership(sessionId, ownershipGeneration);
        if (liveness != PlayerProcessLiveness.exited) {
          throw AppException.process('该音频播放会话仍在运行，请先关闭或删除后再继续');
        }
        if (identical(_sessions[sessionId], existing)) {
          _sessions.remove(sessionId);
          existing.livenessTracker.stop();
        }
      }
      final launchEpoch =
          '${DateTime.now().microsecondsSinceEpoch}_${++_launchSequence}';
      final artifactSessionId = '${sessionId}__e$launchEpoch';
      Future<void> ensureOwned({
        Iterable<File> localizedFiles = const [],
      }) async {
        if (_ownsLaunch(sessionId, ownershipGeneration)) return;
        await _deleteLaunchArtifacts(
          sessionId: sessionId,
          launchEpoch: launchEpoch,
          artifactSessionId: artifactSessionId,
          localizedLyricsFiles: localizedFiles,
        );
        _ensureLaunchOwnership(sessionId, ownershipGeneration);
      }

      final progressGeneration = await _progressSyncCoordinator.claimAndDrain(
        sessionId,
      );
      await ensureOwned();

      final fullConfig = await _configStore.load();
      await ensureOwned();
      final config = fullConfig.toPlayerConfig();
      final subtitleInjectionEnabled = config.subtitleInjectionEnabled;
      final subtitleAutoSelectEnabled =
          subtitleInjectionEnabled && config.subtitleAutoSelectEnabled;
      if (config.executable.trim().isEmpty) {
        throw AppException.config('未配置播放器路径，请先在「设置」中配置');
      }
      if (!_isMpvExecutable(config.executable)) {
        throw AppException.config('音频播放、LRC 与封面功能需要使用 MPV 播放器');
      }

      final authHeader = username != null && username.isNotEmpty
          ? 'Basic ${base64Encode(utf8.encode('$username:${password ?? ''}'))}'
          : null;
      String authUrl(String url) =>
          authHeader != null && isSameOrigin(fullConfig.serverUrl, url)
          ? embedCredentials(url, username!, password ?? '')
          : url;

      final dataDir = await AppPaths.cacheDirectory();
      await ensureOwned();
      final base = await _scriptBase();
      await ensureOwned();
      final statusFilePath = p.join(
        dataDir.path,
        sessionStatusFileName(sessionId, launchEpoch: launchEpoch),
      );
      final commandFilePath = p.join(
        dataDir.path,
        sessionCommandFileName(sessionId, launchEpoch: launchEpoch),
      );
      final progressFilePath = p.join(
        dataDir.path,
        sessionProgressFileName(sessionId, launchEpoch: launchEpoch),
      );

      final lyricsLocalization = subtitleInjectionEnabled
          ? await _lyricsLocalizer.localize(
              entries: entries,
              base: base,
              sessionId: artifactSessionId,
              loader: lyricsLoader,
            )
          : AudioLyricsLocalizationResult(
              entries: List.unmodifiable(entries),
              sessionFiles: const [],
            );
      await ensureOwned(localizedFiles: lyricsLocalization.sessionFiles);

      final playlistFilePath = await AudioMpvScripts.ensurePlaylistM3u8(
        entries,
        authUrl,
        base,
        sessionId: artifactSessionId,
      );
      await ensureOwned(localizedFiles: lyricsLocalization.sessionFiles);
      final companionScript = await AudioMpvScripts.ensureCompanions(
        lyricsLocalization.entries,
        authUrl,
        base,
        sessionId: artifactSessionId,
        lyricsInjectionEnabled: subtitleInjectionEnabled,
        lyricsAutoSelectEnabled: subtitleAutoSelectEnabled,
      );
      await ensureOwned(localizedFiles: lyricsLocalization.sessionFiles);
      final currentScript = await AudioMpvScripts.ensureCurrent(
        statusFilePath,
        commandFilePath,
        progressFilePath,
        base,
        sessionId: artifactSessionId,
        launchEpoch: launchEpoch,
      );
      await ensureOwned(localizedFiles: lyricsLocalization.sessionFiles);

      final args = _stripTemplateTokens(filterCacheArgs(config.args))
        ..addAll([
          '--playlist=$playlistFilePath',
          if (playlistStart > 0) '--playlist-start=$playlistStart',
          '--input-ipc-server=${_newPipeName(launchEpoch)}',
          '--audio-display=embedded-first',
          '--cover-art-auto=no',
          if (subtitleInjectionEnabled) '--sub-auto=no',
          '--script=$companionScript',
          '--script=$currentScript',
        ]);
      final ipcPipeName = args
          .firstWhere((arg) => arg.startsWith('--input-ipc-server='))
          .substring('--input-ipc-server='.length);

      final watchLaterDirectory = await _ensureWatchLaterDirectory();
      await ensureOwned(localizedFiles: lyricsLocalization.sessionFiles);
      if (config.resumeEnabled) {
        try {
          await const MpvWatchLaterSync().purgeExpiredRecords(
            watchLaterDirectory,
            entries.map((entry) => authUrl(entry.url)),
            maxAge: _progressService.retention,
          );
        } catch (_) {
          // 续播缓存维护失败不阻断音频播放。
        }
        await ensureOwned(localizedFiles: lyricsLocalization.sessionFiles);
        args.addAll([
          '--save-position-on-quit',
          '--watch-later-directory=${watchLaterDirectory.path}',
        ]);
        final startEntry = entries[playlistStart];
        if (resumeSeconds != null) {
          await _writeResumeStart(authUrl(startEntry.url), resumeSeconds);
          await ensureOwned(localizedFiles: lyricsLocalization.sessionFiles);
        } else {
          await _clearWatchLater(startEntry.url);
          await ensureOwned(localizedFiles: lyricsLocalization.sessionFiles);
          final playbackUrl = authUrl(startEntry.url);
          if (playbackUrl != startEntry.url) {
            await _clearWatchLater(playbackUrl);
            await ensureOwned(localizedFiles: lyricsLocalization.sessionFiles);
          }
          args.addAll(['--no-resume-playback', '--start=0']);
        }
      }

      await ensureOwned(localizedFiles: lyricsLocalization.sessionFiles);
      final Process process;
      try {
        process = await Process.start(
          config.executable,
          args,
          mode: ProcessStartMode.detached,
        );
      } on FileSystemException catch (error) {
        await _deleteLaunchArtifacts(
          sessionId: sessionId,
          launchEpoch: launchEpoch,
          artifactSessionId: artifactSessionId,
          localizedLyricsFiles: lyricsLocalization.sessionFiles,
        );
        throw AppException.process(
          '无法启动播放器「${config.executable}」：文件不存在或路径错误',
          error,
        );
      } on ProcessException catch (error) {
        await _deleteLaunchArtifacts(
          sessionId: sessionId,
          launchEpoch: launchEpoch,
          artifactSessionId: artifactSessionId,
          localizedLyricsFiles: lyricsLocalization.sessionFiles,
        );
        throw AppException.process('播放器启动失败：${error.message}', error);
      }
      final processIdentity = await _processController.capture(process.pid);
      if (!_ownsLaunch(sessionId, ownershipGeneration)) {
        final termination = await _terminateCapturedProcess(
          pid: process.pid,
          expected: processIdentity,
          ipcPipeName: ipcPipeName,
          requirePipeOwner: true,
        );
        await _deleteLaunchArtifacts(
          sessionId: sessionId,
          launchEpoch: launchEpoch,
          artifactSessionId: artifactSessionId,
          localizedLyricsFiles: lyricsLocalization.sessionFiles,
        );
        if (!termination.isSafeToRelaunch) {
          throw AppException.process('音频启动已过期，且无法确认旧 MPV 进程归属');
        }
        _ensureLaunchOwnership(sessionId, ownershipGeneration);
      }

      final livenessTracker = PlayerProcessLivenessTracker(
        controller: _processController,
        expectedIdentity: processIdentity,
        initialStatus: processIdentity == null
            ? PlayerProcessLiveness.unknown
            : PlayerProcessLiveness.alive,
      );
      final runtime = _AudioSessionRuntime(
        sessionId: sessionId,
        pid: process.pid,
        processIdentity: processIdentity,
        livenessTracker: livenessTracker,
        ipcPipeName: ipcPipeName,
        statusFilePath: statusFilePath,
        commandFilePath: commandFilePath,
        progressFilePath: progressFilePath,
        entries: List.unmodifiable(entries),
        watchLaterUrls: entries.map((entry) => authUrl(entry.url)).toList(),
        localizedLyricsFiles: lyricsLocalization.sessionFiles,
        launchEpoch: launchEpoch,
        artifactSessionId: artifactSessionId,
        progressGeneration: progressGeneration,
        ownershipGeneration: ownershipGeneration,
        profileId: fullConfig.profileId,
      );
      _sessions[sessionId] = runtime;
      runtime.exitSyncFuture = _watchExitAndSync(runtime);
      unawaited(runtime.exitSyncFuture);

      return AudioPlayerLaunchResult(
        process: process,
        args: args,
        sessionId: sessionId,
        launchEpoch: launchEpoch,
        processIdentity: processIdentity,
        ipcPipeName: ipcPipeName,
        statusFilePath: statusFilePath,
        commandFilePath: commandFilePath,
        progressFilePath: progressFilePath,
        playlistFilePath: playlistFilePath,
      );
    } catch (_) {
      if (_ownsLaunch(sessionId, ownershipGeneration)) {
        if (existing != null && identical(_sessions[sessionId], existing)) {
          _launchOwnership[sessionId] = existing.ownershipGeneration;
        } else if (_sessions[sessionId] == null) {
          _launchOwnership.remove(sessionId);
        }
      }
      rethrow;
    }
  }

  /// 移除模板中的 MPV 缓存参数，避免音频进入应用缓存控制或优化路径。
  @visibleForTesting
  static List<String> filterCacheArgs(List<String> arguments) {
    final output = <String>[];
    for (final argument in arguments) {
      final tokens = argument
          .split(RegExp(r'\s+'))
          .where((token) => token.isNotEmpty)
          .toList();
      final kept = <String>[];
      for (var index = 0; index < tokens.length; index++) {
        final token = tokens[index];
        final splitValue = _isCacheArgumentWithSeparateValue(token);
        if (_isCacheArgument(token)) {
          if (splitValue &&
              index + 1 < tokens.length &&
              !tokens[index + 1].startsWith('-')) {
            index++;
          }
          continue;
        }
        kept.add(token);
      }
      if (kept.isNotEmpty) output.add(kept.join(' '));
    }
    return output;
  }

  static bool _isCacheArgumentWithSeparateValue(String value) {
    final token = value.toLowerCase();
    if (token.startsWith('--demuxer-readahead-') && !token.contains('=')) {
      return true;
    }
    switch (token) {
      case '--cache':
      case '--cache-secs':
      case '--cache-pause-wait':
      case '--cache-pause-initial':
      case '--cache-pause':
      case '--cache-on-disk':
      case '--demuxer-max-bytes':
      case '--demuxer-max-back-bytes':
      case '--demuxer-seekable-cache':
      case '--demuxer-donate-buffer':
      case '--demuxer-hysteresis-secs':
      case '--stream-buffer-size':
        return true;
    }
    return false;
  }

  static List<String> _stripTemplateTokens(List<String> arguments) {
    final output = <String>[];
    for (final argument in arguments) {
      final kept = argument
          .split(RegExp(r'\s+'))
          .where(
            (token) =>
                token.isNotEmpty &&
                !token.contains('{') &&
                !token.contains('}'),
          )
          .join(' ');
      if (kept.isNotEmpty) output.add(kept);
    }
    return output;
  }

  static bool _isCacheArgument(String value) {
    final token = value.toLowerCase();
    const exact = {
      '--cache',
      '--no-cache',
      '--cache-pause',
      '--no-cache-pause',
      '--cache-on-disk',
      '--no-cache-on-disk',
      '--demuxer-seekable-cache',
      '--no-demuxer-seekable-cache',
    };
    if (exact.contains(token)) return true;
    const prefixes = [
      '--cache=',
      '--cache-',
      '--demuxer-max-bytes=',
      '--demuxer-max-back-bytes=',
      '--demuxer-max-bytes',
      '--demuxer-max-back-bytes',
      '--demuxer-seekable-cache=',
      '--demuxer-readahead-',
      '--demuxer-donate-buffer',
      '--demuxer-donate-buffer=',
      '--demuxer-hysteresis-secs',
      '--demuxer-hysteresis-secs=',
      '--stream-buffer-size',
      '--stream-buffer-size=',
    ];
    return prefixes.any(token.startsWith);
  }

  Future<void> restoreSession({
    required String sessionId,
    required int? pid,
    String? executablePath,
    int? creationTime,
    String? ipcPipeName,
    String? launchEpoch,
  }) async {
    if (_sessions.containsKey(sessionId)) return;
    final dataDir = await AppPaths.cacheDirectory();
    final processIdentity = PlayerProcessIdentity.fromStored(
      pid: pid,
      executablePath: executablePath,
      creationTime: creationTime,
    );
    final runtime = _AudioSessionRuntime(
      sessionId: sessionId,
      pid: pid,
      processIdentity: processIdentity,
      livenessTracker: PlayerProcessLivenessTracker(
        controller: _processController,
        expectedIdentity: processIdentity,
      ),
      ipcPipeName: ipcPipeName,
      statusFilePath: p.join(
        dataDir.path,
        sessionStatusFileName(sessionId, launchEpoch: launchEpoch),
      ),
      commandFilePath: p.join(
        dataDir.path,
        sessionCommandFileName(sessionId, launchEpoch: launchEpoch),
      ),
      progressFilePath: p.join(
        dataDir.path,
        sessionProgressFileName(sessionId, launchEpoch: launchEpoch),
      ),
      entries: const [],
      watchLaterUrls: const [],
      localizedLyricsFiles: const [],
      launchEpoch: launchEpoch ?? '',
      artifactSessionId: launchEpoch == null || launchEpoch.isEmpty
          ? sessionId
          : '${sessionId}__e$launchEpoch',
      progressGeneration: _progressSyncCoordinator.claim(sessionId),
      ownershipGeneration: ++_ownershipSequence,
      profileId: _configStore.current.profileId,
    );
    _sessions[sessionId] = runtime;
    _launchOwnership[sessionId] = runtime.ownershipGeneration;
  }

  Future<bool> isPlayerRunning(String sessionId) async {
    final runtime = _sessions[sessionId];
    if (runtime?.pid == null) return false;
    final liveness = await runtime!.livenessTracker.sample();
    // unknown 不能降级为 false；否则 UI 会误删仍可能存活的会话。
    return liveness != PlayerProcessLiveness.exited;
  }

  Future<void> waitForExitSync(
    String sessionId, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final future = _sessions[sessionId]?.exitSyncFuture;
    if (future == null) return;
    try {
      await future.timeout(timeout);
    } catch (_) {
      // 进度同步异常不阻塞下边栏收敛。
    }
  }

  /// 自动切歌时同步当前会话已产生的 JSONL 与 watch_later。
  Future<void> syncActiveProgress(String sessionId) async {
    final runtime = _sessions[sessionId];
    if (runtime == null) return;
    await _syncProgress(runtime);
  }

  /// 继续播放前同步该会话遗留的 JSONL 与 watch_later。
  ///
  /// 处理“应用先退出、MPV 后关闭”的场景：新的应用进程没有原运行时
  /// 监听，但仍可在目录重新加载后凭稳定会话 ID 恢复完整曲目映射。
  Future<void> syncPersistedProgress({
    required String sessionId,
    required List<AudioMediaEntry> entries,
    String? username,
    String? password,
    String? launchEpoch,
    @visibleForTesting File? journalFile,
  }) async {
    if (entries.isEmpty) return;
    final config = await _configStore.load();
    final authHeader = username != null && username.isNotEmpty
        ? 'Basic ${base64Encode(utf8.encode('$username:${password ?? ''}'))}'
        : null;
    String authUrl(String url) =>
        authHeader != null && isSameOrigin(config.serverUrl, url)
        ? embedCredentials(url, username!, password ?? '')
        : url;
    final directory = await _ensureWatchLaterDirectory();
    final dataDir = await AppPaths.cacheDirectory();
    await const MpvPlaybackProgressSynchronizer().sync(
      progressService: _progressService,
      profileId: config.profileId,
      watchLaterDirectory: directory,
      entries: entries,
      watchLaterUrls: entries
          .map((entry) => authUrl(entry.url))
          .toList(growable: false),
      journalFile:
          journalFile ??
          File(
            p.join(
              dataDir.path,
              sessionProgressFileName(sessionId, launchEpoch: launchEpoch),
            ),
          ),
      expectedEpoch: launchEpoch,
    );
  }

  Future<void> sendPause(String sessionId) => _writeCommand(sessionId, 'pause');

  Future<void> sendResume(String sessionId) =>
      _writeCommand(sessionId, 'resume');

  Future<void> _writeCommand(String sessionId, String command) async {
    final path = _sessions[sessionId]?.commandFilePath;
    if (path == null) return;
    try {
      await File(path).writeAsString(command, flush: true);
    } catch (_) {
      // 命令失败不影响其他音频或视频会话。
    }
  }

  /// 页面失效时精确回滚已完成的这一次音频启动。
  Future<PlayerTerminationOutcome> terminateLaunch(
    AudioPlayerLaunchResult result,
  ) async {
    final runtime = _sessions[result.sessionId];
    final termination =
        runtime != null && runtime.launchEpoch == result.launchEpoch
        ? await _terminateRuntimeProcess(runtime)
        : await _terminateCapturedProcess(
            pid: result.process.pid,
            expected: result.processIdentity,
            ipcPipeName: result.ipcPipeName,
            requirePipeOwner: true,
          );
    if (!termination.isSafeToRelaunch) return termination;
    if (runtime != null &&
        runtime.launchEpoch == result.launchEpoch &&
        identical(_sessions[result.sessionId], runtime)) {
      _sessions.remove(result.sessionId);
      runtime.livenessTracker.stop();
      if (_ownsLaunch(result.sessionId, runtime.ownershipGeneration)) {
        _launchOwnership.remove(result.sessionId);
      }
    }
    await _deleteLaunchArtifacts(
      sessionId: result.sessionId,
      launchEpoch: result.launchEpoch,
      artifactSessionId: '${result.sessionId}__e${result.launchEpoch}',
      localizedLyricsFiles: runtime?.launchEpoch == result.launchEpoch
          ? runtime!.localizedLyricsFiles
          : const [],
    );
    return termination;
  }

  Future<PlayerTerminationOutcome> terminateSession(String sessionId) async {
    final runtime = _sessions[sessionId];
    _launchOwnership.remove(sessionId);
    var termination = PlayerTerminationOutcome.alreadyExited;
    if (runtime != null) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      termination = await _terminateRuntimeProcess(runtime);
      if (!termination.isSafeToRelaunch) return termination;
      if (identical(_sessions[sessionId], runtime)) {
        _sessions.remove(sessionId);
        runtime.livenessTracker.stop();
      }
    }
    if (runtime != null) {
      await _deleteSessionArtifacts(runtime);
    } else {
      await _deleteLaunchArtifacts(
        sessionId: sessionId,
        launchEpoch: null,
        artifactSessionId: sessionId,
        localizedLyricsFiles: const [],
      );
    }
    return termination;
  }

  Future<PlayerTerminationOutcome> _terminateRuntimeProcess(
    _AudioSessionRuntime runtime,
  ) async {
    final pending = runtime.terminationFuture;
    if (pending != null) return pending;
    final operation = _terminateRuntimeProcessOnce(runtime);
    runtime.terminationFuture = operation;
    try {
      return await operation;
    } finally {
      if (identical(runtime.terminationFuture, operation)) {
        runtime.terminationFuture = null;
      }
    }
  }

  Future<PlayerTerminationOutcome> _terminateRuntimeProcessOnce(
    _AudioSessionRuntime runtime,
  ) async {
    final pid = runtime.pid;
    if (pid == null) {
      return PlayerTerminationOutcome.alreadyExited;
    }
    final tracker = runtime.livenessTracker;
    var liveness = tracker.status;
    if (liveness == PlayerProcessLiveness.unknown) {
      // 新启动请求可能正等待同一个探活；终止不能等待在途查询，
      // 否则会把同 session 的所有权抢占一并卡住。
      if (tracker.hasInFlightProbe) {
        return PlayerTerminationOutcome.refused;
      }
      liveness = await tracker.sample();
    }
    if (liveness == PlayerProcessLiveness.unknown) {
      return PlayerTerminationOutcome.refused;
    }
    if (liveness == PlayerProcessLiveness.exited) {
      return PlayerTerminationOutcome.alreadyExited;
    }
    return _processController.terminateIfOwned(
      pid: pid,
      expected: runtime.processIdentity,
      ipcPipeName: runtime.ipcPipeName,
      requirePipeOwner: true,
    );
  }

  Future<PlayerTerminationOutcome> _terminateCapturedProcess({
    required int pid,
    required PlayerProcessIdentity? expected,
    required String ipcPipeName,
    required bool requirePipeOwner,
  }) async {
    var outcome = await _processController.terminateIfOwned(
      pid: pid,
      expected: expected,
      ipcPipeName: ipcPipeName,
      requirePipeOwner: requirePipeOwner,
    );
    if (!requirePipeOwner || expected == null) return outcome;
    for (
      var attempt = 0;
      attempt < 20 && !outcome.isSafeToRelaunch;
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      outcome = await _processController.terminateIfOwned(
        pid: pid,
        expected: expected,
        ipcPipeName: ipcPipeName,
        requirePipeOwner: true,
      );
    }
    return outcome;
  }

  void releaseSession(String sessionId) {
    final runtime = _sessions.remove(sessionId);
    if (runtime != null &&
        _ownsLaunch(sessionId, runtime.ownershipGeneration)) {
      _launchOwnership.remove(sessionId);
    }
    if (runtime != null) {
      runtime.livenessTracker.stop();
      unawaited(_deleteSessionArtifacts(runtime));
    }
  }

  Future<void> _watchExitAndSync(_AudioSessionRuntime runtime) async {
    if (runtime.pid == null) return;
    final tracker = runtime.livenessTracker;
    while (true) {
      final liveness = await tracker.sample();
      if (!_ownsLaunch(runtime.sessionId, runtime.ownershipGeneration) ||
          !identical(_sessions[runtime.sessionId], runtime)) {
        return;
      }
      if (liveness == PlayerProcessLiveness.exited) break;
      if (liveness == PlayerProcessLiveness.unknown) {
        if (tracker.unknownRetryExhausted) return;
      } else if (await _hasOwnedIdleCompletion(runtime)) {
        final termination = await _terminateRuntimeProcess(runtime);
        if (termination == PlayerTerminationOutcome.alreadyExited) break;
        if (termination != PlayerTerminationOutcome.terminated) return;
      }
      final delay = tracker.nextProbeDelay;
      if (delay == null) return;
      await Future<void>.delayed(delay);
      if (!_ownsLaunch(runtime.sessionId, runtime.ownershipGeneration) ||
          !identical(_sessions[runtime.sessionId], runtime)) {
        return;
      }
    }
    if (!identical(_sessions[runtime.sessionId], runtime)) return;
    runtime.livenessTracker.stop();
    try {
      await _syncProgress(runtime);
    } catch (_) {
      // 音频进度同步故障不得影响视频或其他音频会话。
    } finally {
      await _lyricsLocalizer.deleteSessionFiles(runtime.localizedLyricsFiles);
    }
  }

  Future<bool> _hasOwnedIdleCompletion(_AudioSessionRuntime runtime) async {
    if (runtime.launchEpoch.isEmpty || runtime.entries.isEmpty) return false;
    try {
      final marker = MpvIdleCompletionMarker.parse(
        await File(runtime.statusFilePath).readAsLines(),
      );
      return marker?.matches(
            expectedLastPlaylistPos: runtime.entries.length - 1,
            expectedLaunchEpoch: runtime.launchEpoch,
          ) ??
          false;
    } on FileSystemException {
      return false;
    }
  }

  Future<void> _syncProgress(_AudioSessionRuntime runtime) async {
    final directory = _watchLaterDirectory;
    if (directory == null || runtime.entries.isEmpty) return;
    await _progressSyncCoordinator.run<void>(
      sessionId: runtime.sessionId,
      generation: runtime.progressGeneration,
      action: () => const MpvPlaybackProgressSynchronizer().sync(
        progressService: _progressService,
        profileId: runtime.profileId,
        watchLaterDirectory: directory,
        entries: runtime.entries,
        watchLaterUrls: runtime.watchLaterUrls,
        journalFile: File(runtime.progressFilePath),
        expectedEpoch: runtime.launchEpoch.isEmpty ? null : runtime.launchEpoch,
      ),
    );
  }

  Future<Directory> _ensureWatchLaterDirectory() async {
    final directory =
        _watchLaterDirectory ??
        Directory(
          p.join(
            (await AppPaths.cacheDirectory()).path,
            'mpv-audio-watch-later',
          ),
        );
    if (!await directory.exists()) await directory.create(recursive: true);
    _watchLaterDirectory = directory;
    return directory;
  }

  Future<Directory> _scriptBase() async =>
      _watchLaterDirectory ?? await _ensureWatchLaterDirectory();

  Future<void> _writeResumeStart(String url, int seconds) async {
    final directory = await _ensureWatchLaterDirectory();
    final file = File(
      p.join(directory.path, MpvWatchLaterSync.md5FileName(url)),
    );
    var content = '';
    if (await file.exists()) {
      try {
        content = await file.readAsString();
      } on FileSystemException {
        content = '';
      }
    }
    final lines = content.split('\n');
    var replaced = false;
    final output = <String>[];
    for (final line in lines) {
      if (RegExp(r'^\s*start\s*=', caseSensitive: false).hasMatch(line)) {
        output.add('start=$seconds');
        replaced = true;
      } else {
        output.add(line);
      }
    }
    if (!replaced) output.add('start=$seconds');
    await file.writeAsString(output.join('\n'), flush: true);
  }

  Future<void> _clearWatchLater(String url) async {
    final directory = await _ensureWatchLaterDirectory();
    await const MpvWatchLaterSync().deleteRecord(directory, url);
  }

  Future<void> _deleteSessionArtifacts(_AudioSessionRuntime runtime) =>
      _deleteLaunchArtifacts(
        sessionId: runtime.sessionId,
        launchEpoch: runtime.launchEpoch.isEmpty ? null : runtime.launchEpoch,
        artifactSessionId: runtime.artifactSessionId,
        localizedLyricsFiles: runtime.localizedLyricsFiles,
      );

  Future<void> _deleteLaunchArtifacts({
    required String sessionId,
    required String? launchEpoch,
    required String artifactSessionId,
    required Iterable<File> localizedLyricsFiles,
  }) async {
    try {
      final dataDir = await AppPaths.cacheDirectory();
      final base = await _scriptBase();
      final paths = [
        p.join(
          dataDir.path,
          sessionStatusFileName(sessionId, launchEpoch: launchEpoch),
        ),
        p.join(
          dataDir.path,
          sessionCommandFileName(sessionId, launchEpoch: launchEpoch),
        ),
        p.join(
          dataDir.path,
          sessionProgressFileName(sessionId, launchEpoch: launchEpoch),
        ),
        ...AudioMpvScripts.sessionArtifactNames(
          artifactSessionId,
        ).map((name) => p.join(base.path, name)),
      ];
      for (final path in paths) {
        await _deleteIfExists(File(path));
      }
      await _lyricsLocalizer.deleteSessionFiles(localizedLyricsFiles);
      await _lyricsLocalizer.deleteSessionArtifacts(
        base: base,
        sessionId: artifactSessionId,
      );
    } catch (_) {
      // 会话清理失败不能波及其他模块。
    }
  }

  String _newPipeName(String launchEpoch) =>
      '${r'\\.\pipe\streampath_audio_'}$launchEpoch';

  static bool _isMpvExecutable(String executable) =>
      p.basenameWithoutExtension(executable).toLowerCase().contains('mpv');

  static Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // 残留资源不阻塞播放。
    }
  }

  static String sessionStatusFileName(
    String sessionId, {
    String? launchEpoch,
  }) => 'mpv-audio-current-${_artifactToken(sessionId, launchEpoch)}.txt';

  static String sessionCommandFileName(
    String sessionId, {
    String? launchEpoch,
  }) => 'mpv-audio-command-${_artifactToken(sessionId, launchEpoch)}.txt';

  static String sessionProgressFileName(
    String sessionId, {
    String? launchEpoch,
  }) => 'mpv-audio-progress-${_artifactToken(sessionId, launchEpoch)}.jsonl';

  static String _artifactToken(String sessionId, String? launchEpoch) {
    final session = AudioMpvScripts.safeSessionToken(sessionId);
    if (launchEpoch == null || launchEpoch.isEmpty) return session;
    return '${session}__e${AudioMpvScripts.safeSessionToken(launchEpoch)}';
  }
}
