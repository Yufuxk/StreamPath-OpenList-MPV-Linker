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
import 'mpv_playback_progress_sync.dart';
import 'mpv_watch_later_sync.dart';

class AudioPlayerLaunchResult {
  const AudioPlayerLaunchResult({
    required this.process,
    required this.args,
    required this.sessionId,
    required this.ipcPipeName,
    required this.statusFilePath,
    required this.commandFilePath,
    required this.progressFilePath,
    required this.playlistFilePath,
  });

  final Process process;
  final List<String> args;
  final String sessionId;
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
    required this.launchedHere,
    required this.ipcPipeName,
    required this.statusFilePath,
    required this.commandFilePath,
    required this.progressFilePath,
    required this.entries,
    required this.watchLaterUrls,
    required this.localizedLyricsFiles,
  });

  final String sessionId;
  final int? pid;
  final bool launchedHere;
  final String? ipcPipeName;
  final String statusFilePath;
  final String commandFilePath;
  final String progressFilePath;
  final List<AudioMediaEntry> entries;
  final List<String> watchLaterUrls;
  final List<File> localizedLyricsFiles;
  bool? aliveCache;
  DateTime? aliveCacheAt;
  Future<void>? exitSyncFuture;
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
  }) => AudioPlayerService._(configStore, progressService, watchLaterDirectory);

  AudioPlayerService._(
    this._configStore,
    this._progressService,
    this._watchLaterDirectory,
  );

  final StreamPathConfigStore _configStore;
  final PlaybackProgressService _progressService;
  Directory? _watchLaterDirectory;
  final Map<String, _AudioSessionRuntime> _sessions = {};
  final AudioLyricsLocalizer _lyricsLocalizer = const AudioLyricsLocalizer();
  int _launchSequence = 0;

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
    final existing = _sessions[sessionId];
    if (existing != null && await isPlayerRunning(sessionId)) {
      throw AppException.process('该音频播放会话仍在运行，请先关闭或删除后再继续');
    }
    if (existing != null) _sessions.remove(sessionId);

    final fullConfig = await _configStore.load();
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
    final base = await _scriptBase();
    final statusFilePath = p.join(
      dataDir.path,
      sessionStatusFileName(sessionId),
    );
    final commandFilePath = p.join(
      dataDir.path,
      sessionCommandFileName(sessionId),
    );
    final progressFilePath = p.join(
      dataDir.path,
      sessionProgressFileName(sessionId),
    );
    await _deleteIfExists(File(progressFilePath));
    await _clearStaleFinishedMark(File(statusFilePath));

    final lyricsLocalization = subtitleInjectionEnabled
        ? await _lyricsLocalizer.localize(
            entries: entries,
            base: base,
            sessionId: sessionId,
            loader: lyricsLoader,
          )
        : AudioLyricsLocalizationResult(
            entries: List.unmodifiable(entries),
            sessionFiles: const [],
          );

    final playlistFilePath = await AudioMpvScripts.ensurePlaylistM3u8(
      entries,
      authUrl,
      base,
      sessionId: sessionId,
    );
    final companionScript = await AudioMpvScripts.ensureCompanions(
      lyricsLocalization.entries,
      authUrl,
      base,
      sessionId: sessionId,
      lyricsInjectionEnabled: subtitleInjectionEnabled,
      lyricsAutoSelectEnabled: subtitleAutoSelectEnabled,
    );
    final currentScript = await AudioMpvScripts.ensureCurrent(
      statusFilePath,
      commandFilePath,
      progressFilePath,
      base,
      sessionId: sessionId,
    );

    final args = _stripTemplateTokens(filterCacheArgs(config.args))
      ..addAll([
        '--playlist=$playlistFilePath',
        if (playlistStart > 0) '--playlist-start=$playlistStart',
        '--input-ipc-server=${_newPipeName()}',
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
      args.addAll([
        '--save-position-on-quit',
        '--watch-later-directory=${watchLaterDirectory.path}',
      ]);
      final startEntry = entries[playlistStart];
      if (resumeSeconds != null) {
        await _writeResumeStart(authUrl(startEntry.url), resumeSeconds);
      } else {
        await _clearWatchLater(startEntry.url);
        final playbackUrl = authUrl(startEntry.url);
        if (playbackUrl != startEntry.url) {
          await _clearWatchLater(playbackUrl);
        }
        args.addAll(['--no-resume-playback', '--start=0']);
      }
    }

    final Process process;
    try {
      process = await Process.start(
        config.executable,
        args,
        mode: ProcessStartMode.detached,
      );
    } on FileSystemException catch (error) {
      await _lyricsLocalizer.deleteSessionFiles(
        lyricsLocalization.sessionFiles,
      );
      throw AppException.process(
        '无法启动播放器「${config.executable}」：文件不存在或路径错误',
        error,
      );
    } on ProcessException catch (error) {
      await _lyricsLocalizer.deleteSessionFiles(
        lyricsLocalization.sessionFiles,
      );
      throw AppException.process('播放器启动失败：${error.message}', error);
    }

    final runtime =
        _AudioSessionRuntime(
            sessionId: sessionId,
            pid: process.pid,
            launchedHere: true,
            ipcPipeName: ipcPipeName,
            statusFilePath: statusFilePath,
            commandFilePath: commandFilePath,
            progressFilePath: progressFilePath,
            entries: List.unmodifiable(entries),
            watchLaterUrls: entries.map((entry) => authUrl(entry.url)).toList(),
            localizedLyricsFiles: lyricsLocalization.sessionFiles,
          )
          ..aliveCache = true
          ..aliveCacheAt = DateTime.now();
    _sessions[sessionId] = runtime;
    runtime.exitSyncFuture = _watchExitAndSync(runtime);
    unawaited(runtime.exitSyncFuture);

    return AudioPlayerLaunchResult(
      process: process,
      args: args,
      sessionId: sessionId,
      ipcPipeName: ipcPipeName,
      statusFilePath: statusFilePath,
      commandFilePath: commandFilePath,
      progressFilePath: progressFilePath,
      playlistFilePath: playlistFilePath,
    );
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
    switch (value.toLowerCase()) {
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
    String? ipcPipeName,
  }) async {
    if (_sessions.containsKey(sessionId)) return;
    final dataDir = await AppPaths.cacheDirectory();
    final runtime = _AudioSessionRuntime(
      sessionId: sessionId,
      pid: pid,
      launchedHere: false,
      ipcPipeName: ipcPipeName,
      statusFilePath: p.join(dataDir.path, sessionStatusFileName(sessionId)),
      commandFilePath: p.join(dataDir.path, sessionCommandFileName(sessionId)),
      progressFilePath: p.join(
        dataDir.path,
        sessionProgressFileName(sessionId),
      ),
      entries: const [],
      watchLaterUrls: const [],
      localizedLyricsFiles: const [],
    );
    _sessions[sessionId] = runtime;
    if (pid != null && ipcPipeName != null && await _isProcessAlive(pid)) {
      runtime
        ..aliveCache = true
        ..aliveCacheAt = DateTime.now();
    }
  }

  Future<bool> isPlayerRunning(String sessionId) async {
    final runtime = _sessions[sessionId];
    final pid = runtime?.pid;
    if (runtime == null || pid == null) return false;
    final now = DateTime.now();
    if (runtime.aliveCacheAt != null &&
        now.difference(runtime.aliveCacheAt!) < const Duration(seconds: 2)) {
      return runtime.aliveCache ?? true;
    }
    final alive = await _isProcessAlive(pid);
    runtime
      ..aliveCache = alive
      ..aliveCacheAt = now;
    return alive;
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

  /// 继续播放前同步该会话遗留的 JSONL 与 watch_later。
  ///
  /// 处理“应用先退出、MPV 后关闭”的场景：新的应用进程没有原运行时
  /// 监听，但仍可在目录重新加载后凭稳定会话 ID 恢复完整曲目映射。
  Future<void> syncPersistedProgress({
    required String sessionId,
    required List<AudioMediaEntry> entries,
    String? username,
    String? password,
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
      watchLaterDirectory: directory,
      entries: entries,
      watchLaterUrls: entries
          .map((entry) => authUrl(entry.url))
          .toList(growable: false),
      journalFile:
          journalFile ??
          File(p.join(dataDir.path, sessionProgressFileName(sessionId))),
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

  Future<void> terminateSession(String sessionId) async {
    final runtime = _sessions.remove(sessionId);
    final pid = runtime?.pid;
    if (runtime != null && pid != null) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final canTerminate = runtime.launchedHere || await _isMpvProcess(pid);
      if (canTerminate && await _isProcessAlive(pid)) {
        try {
          await Process.run('taskkill', ['/PID', '$pid', '/T', '/F']);
        } catch (_) {
          // 结束失败由后续进程探测反映，不扩大清理范围。
        }
      }
    }
    if (pid != null && await _isProcessAlive(pid)) return;
    await _deleteSessionArtifacts(sessionId);
  }

  void releaseSession(String sessionId) {
    _sessions.remove(sessionId);
    unawaited(_deleteSessionArtifacts(sessionId));
  }

  Future<void> _watchExitAndSync(_AudioSessionRuntime runtime) async {
    final pid = runtime.pid;
    if (pid == null) return;
    while (await _isProcessAlive(pid)) {
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    if (!identical(_sessions[runtime.sessionId], runtime)) return;
    runtime
      ..aliveCache = false
      ..aliveCacheAt = DateTime.now();
    try {
      await _syncProgress(runtime);
    } catch (_) {
      // 音频进度同步故障不得影响视频或其他音频会话。
    } finally {
      await _lyricsLocalizer.deleteSessionFiles(runtime.localizedLyricsFiles);
    }
  }

  Future<void> _syncProgress(_AudioSessionRuntime runtime) async {
    final directory = _watchLaterDirectory;
    if (directory == null || runtime.entries.isEmpty) return;
    await const MpvPlaybackProgressSynchronizer().sync(
      progressService: _progressService,
      watchLaterDirectory: directory,
      entries: runtime.entries,
      watchLaterUrls: runtime.watchLaterUrls,
      journalFile: File(runtime.progressFilePath),
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

  Future<void> _deleteSessionArtifacts(String sessionId) async {
    try {
      final dataDir = await AppPaths.cacheDirectory();
      final base = await _scriptBase();
      final paths = [
        p.join(dataDir.path, sessionStatusFileName(sessionId)),
        p.join(dataDir.path, sessionCommandFileName(sessionId)),
        p.join(dataDir.path, sessionProgressFileName(sessionId)),
        ...AudioMpvScripts.sessionArtifactNames(
          sessionId,
        ).map((name) => p.join(base.path, name)),
      ];
      for (final path in paths) {
        await _deleteIfExists(File(path));
      }
      await _lyricsLocalizer.deleteSessionArtifacts(
        base: base,
        sessionId: sessionId,
      );
    } catch (_) {
      // 会话清理失败不能波及其他模块。
    }
  }

  Future<bool> _isProcessAlive(int pid) async {
    try {
      final result = await Process.run(
        Platform.isWindows ? 'tasklist' : 'kill',
        Platform.isWindows
            ? ['/FI', 'PID eq $pid', '/NH', '/FO', 'CSV']
            : ['-0', '$pid'],
      );
      if (!Platform.isWindows) return result.exitCode == 0;
      for (final line in result.stdout.toString().split(RegExp(r'\r?\n'))) {
        final columns = line.split(',');
        if (columns.length < 2) continue;
        if (columns[1].replaceAll('"', '').trim() == '$pid') return true;
      }
      return false;
    } catch (_) {
      return true;
    }
  }

  Future<bool> _isMpvProcess(int pid) async {
    if (!Platform.isWindows) return false;
    try {
      final result = await Process.run('tasklist', [
        '/FI',
        'PID eq $pid',
        '/NH',
        '/FO',
        'CSV',
      ]);
      for (final line in result.stdout.toString().split(RegExp(r'\r?\n'))) {
        final columns = line.split(',');
        if (columns.length < 2) continue;
        final image = columns.first.replaceAll('"', '').trim().toLowerCase();
        final foundPid = columns[1].replaceAll('"', '').trim();
        if (foundPid == '$pid' && image.contains('mpv')) return true;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  String _newPipeName() {
    final token =
        '${DateTime.now().microsecondsSinceEpoch}_${++_launchSequence}';
    return '${r'\\.\pipe\streampath_audio_'}$token';
  }

  static bool _isMpvExecutable(String executable) =>
      p.basenameWithoutExtension(executable).toLowerCase().contains('mpv');

  static Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // 残留资源不阻塞播放。
    }
  }

  static Future<void> _clearStaleFinishedMark(File file) async {
    try {
      if (!await file.exists()) return;
      final lines = await file.readAsLines();
      if (lines.isNotEmpty && lines.first.trim() == '-1') await file.delete();
    } on FileSystemException {
      // 状态清理失败不阻塞播放。
    }
  }

  static String sessionStatusFileName(String sessionId) =>
      'mpv-audio-current-${AudioMpvScripts.safeSessionToken(sessionId)}.txt';

  static String sessionCommandFileName(String sessionId) =>
      'mpv-audio-command-${AudioMpvScripts.safeSessionToken(sessionId)}.txt';

  static String sessionProgressFileName(String sessionId) =>
      'mpv-audio-progress-${AudioMpvScripts.safeSessionToken(sessionId)}.jsonl';
}
