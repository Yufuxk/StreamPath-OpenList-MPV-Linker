import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../../core/cache/cache_retention_policy.dart';
import '../../core/constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/app_paths.dart';
import '../../core/utils/url_utils.dart';
import '../../data/local/stream_path_config_store.dart';
import '../../data/local/playback_progress_db.dart';
import '../../data/models/media_entry.dart';
import '../../data/models/player_config.dart';
import '../../features/cache_control/cache_policy_service.dart';
import '../../features/cache_control/models/cache_policy_result.dart';
import '../../features/cache_control/models/cache_policy_session_state.dart';
import '../../features/cache_control/utils/container_rules.dart';
import '../../features/cache_control/monitor/playback_monitor.dart';
import 'mpv_playback_progress_sync.dart';
import 'mpv_scripts.dart';
import 'mpv_session_controller.dart';
import 'mpv_watch_later_sync.dart';
import 'openlist_recovery_service.dart';

/// 测试或平台适配可注入的 mpv 缓存属性更新器。
typedef MpvCacheIpcUpdater =
    Future<bool> Function(
      String pipeName, {
      required int? demuxerMaxBytes,
      required int? cacheSecs,
      bool? cacheEnabled,
      bool? seekableCacheEnabled,
    });

/// 播放器启动结果（供 UI 诊断展示实际参数）。
class PlayerLaunchResult {
  const PlayerLaunchResult({
    required this.process,
    required this.args,
    required this.sessionId,
    this.ipcPipeName,
    this.statusFilePath,
    this.commandFilePath,
    this.progressFilePath,
  });

  final Process process;
  final List<String> args;
  final String sessionId;
  final String? ipcPipeName;
  final String? statusFilePath;
  final String? commandFilePath;
  final String? progressFilePath;
}

enum PlaybackRecoveryStage { preparing, relaunched, failed }

/// MPV 播放失败自动恢复状态，供界面更新提示和新进程身份。
class PlaybackRecoveryEvent {
  const PlaybackRecoveryEvent({
    required this.sessionId,
    required this.stage,
    required this.message,
    this.launchResult,
  });

  final String sessionId;
  final PlaybackRecoveryStage stage;
  final String message;
  final PlayerLaunchResult? launchResult;
}

class _PlayerSessionRuntime {
  _PlayerSessionRuntime({
    required this.sessionId,
    required this.pid,
    required this.isMpv,
    this.launchedHere = false,
    this.statusFilePath,
    this.commandFilePath,
    this.progressFilePath,
    this.ipcPipeName,
    required this.epoch,
    this.currentTrackUrl,
    this.currentPlaylistPos,
    this.entries = const [],
    this.watchLaterUrls = const [],
    this.username,
    this.password,
  });

  final String sessionId;
  final int? pid;
  final bool isMpv;
  final bool launchedHere;
  final String? statusFilePath;
  final String? commandFilePath;
  final String? progressFilePath;

  /// mpv IPC named pipe（`--input-ipc-server`，动态缓存更新用）。
  final String? ipcPipeName;

  /// 服务生命周期内唯一的 runtime 代际；不因 sessionId 复用而重复。
  final int epoch;
  String? currentTrackUrl;
  int? currentPlaylistPos;
  final List<MediaEntry> entries;
  final List<String> watchLaterUrls;
  final String? username;
  final String? password;
  int trackGeneration = 0;
  int progressJournalLinesRead = 0;

  bool? aliveCache;
  DateTime? aliveCacheAt;
  Future<void>? exitSyncFuture;
}

class _PlaybackRecoveryState {
  int attempts = 0;
  bool recovering = false;
}

class _CacheIpcState {
  int revision = 0;
  int? demuxerMaxBytes;
  int? cacheSecs;
  bool? cacheEnabled;
  bool? seekableCacheEnabled;
  Future<void> tail = Future<void>.value();
}

/// 外部播放器联动服务。
///
/// 职责：
///  1. 读取 [StreamPathConfigStore] 中的播放器配置，展开参数模板
///     （`{url}`/`{subfile}`/`{start}` 占位符）；
///  2. 认证注入：只向 WebDAV 同源 URL 内嵌凭据，避免重定向泄露认证头；
///  3. 自动切集：多集经 m3u 播放列表 + `--playlist-start` 指定起点，
///     每集字幕由注入的 Lua 脚本按 `playlist-pos` 用 `sub-add` 添加，
///     是否自动选中由独立配置控制（脚本生成见 [MpvScripts]）；
///  4. 进度写回：附加 `--save-position-on-quit --watch-later-directory`，
///     退出后合并 Lua 逐媒体结果日志与 watch_later，并把每集位置与时长
///     写回 SQLite；
///  5. 续播：多集预写起点集 watch_later 由 mpv 原生恢复，单集走
///     `--start` 模板参数；无进度时清除旧记录并禁用恢复；
///  6. 完整错误捕获：配置缺失 / 可执行文件不存在 / 启动失败。
class ExternalPlayerService {
  ExternalPlayerService({
    required StreamPathConfigStore configStore,
    this._progressService,
    this._watchLaterDir,
    this._cachePolicy,
    this.onCacheWarning,
    this.onPlaybackRecovery,
    void Function(String message)? cacheLogger,
    this._cacheIpcUpdater,
    PlaybackLinkRecoveryProvider? linkRecoveryProvider,
  }) : _configStore = configStore, // ignore: prefer_initializing_formals
       _cacheLogger = cacheLogger ?? _defaultCacheLogger,
       _linkRecoveryProvider =
           linkRecoveryProvider ?? OpenListRecoveryService();

  final StreamPathConfigStore _configStore;

  final PlaybackProgressService? _progressService;

  /// MPV 智能缓存控制系统门面（可选）。null 时完全不注入缓存参数，
  /// 行为与未接入时一致；非 mpv 播放器同样不受影响。
  final CachePolicyProvider? _cachePolicy;

  /// 播放中动态保护的用户警告回调（如网络带宽持续不足）；
  /// null 时仅记录日志。集成方（UI）负责展示。
  final void Function(String message)? onCacheWarning;

  /// 播放失败自动恢复状态；界面可据此更新 PID/IPC 与显示中文提示。
  final void Function(PlaybackRecoveryEvent event)? onPlaybackRecovery;

  final PlaybackLinkRecoveryProvider _linkRecoveryProvider;

  /// 缓存系统集成层诊断日志；默认输出到 flutter run 控制台。
  final void Function(String message) _cacheLogger;

  /// 测试/平台适配注入；null 时使用 Windows named pipe 实现。
  final MpvCacheIpcUpdater? _cacheIpcUpdater;

  /// watch_later 目录；null 时使用「数据目录/mpv-watch-later」。
  Directory? _watchLaterDir;

  final Map<String, _PlayerSessionRuntime> _sessions = {};
  final Map<String, _PlaybackRecoveryState> _recoveryStates = {};
  int _launchSequence = 0;
  int _runtimeEpoch = 0;
  String? _lastSessionId;

  /// 「会话 id → 认证头」映射（播放列表切集重算时复用 WebDAV 凭据）。
  final Map<String, String?> _authHeaders = {};

  /// 各会话切集代际令牌（快速连续切集时丢弃过期切集结果，防止
  /// 旧集探测完成后用旧基准覆盖新集监控的窄竞态）。
  final Map<String, _CacheIpcState> _cacheIpcStates = {};

  // ignore: avoid_print — 缓存诊断按用户要求输出到运行终端。
  static void _defaultCacheLogger(String message) => print(message);

  void _logCache(String message) {
    try {
      _cacheLogger('[SPCacheSystem] $message');
    } catch (_) {
      // 日志失败不影响播放链路。
    }
  }

  /// 启动外部播放器播放 [entries]（一个或多个视频，自动切集）。
  ///
  /// [entries] 为完整播放列表（含点击集之前的集）；[playlistStart] 为
  /// 播放起点索引（从该集开始播放，之前集仍在播放列表中可手动切回）。
  /// [resumeSeconds] 为**播放起点视频**的续播位置（后续集由 mpv 自身的
  /// watch_later 续播机制接管）。
  /// [username]/[password] 为 WebDAV 凭据（用于播放器认证注入）。
  Future<PlayerLaunchResult> launch({
    required List<MediaEntry> entries,
    String? sessionId,
    int playlistStart = 0,
    int? resumeSeconds,
    String? username,
    String? password,
    bool automaticRecovery = false,
  }) async {
    if (entries.isEmpty) {
      throw AppException.config('播放列表为空，无法启动播放器');
    }
    if (playlistStart < 0 || playlistStart >= entries.length) {
      playlistStart = 0;
    }
    final fullConfig = await _configStore.load();
    final config = fullConfig.toPlayerConfig();
    final launchNumber = ++_launchSequence;
    // 本次注入的缓存策略结果（供播放中动态监控的初值/码率基准）。
    CachePolicySessionState? cacheSession;
    final resolvedSessionId = sessionId ?? 'session_$launchNumber';
    final assetSessionId = sessionId;

    final existing = _sessions[resolvedSessionId];
    if (existing != null && await isPlayerRunning(resolvedSessionId)) {
      throw AppException.process('该播放会话仍在运行，请先关闭或删除后再继续');
    }
    if (existing != null) {
      _sessions.remove(resolvedSessionId);
      _cleanupCacheRuntime(existing);
    }

    // ── 1. 配置校验 ───────────────────────────────────────────
    if (config.executable.trim().isEmpty) {
      throw AppException.config('未配置播放器路径，请先在「设置」中配置');
    }

    // ── 2. 认证注入 ───────────────────────────────────────────
    final isMpv = _isMpvExecutable(config.executable);
    final authHeader = (username != null && username.isNotEmpty)
        ? 'Basic ${base64Encode(utf8.encode('$username:${password ?? ''}'))}'
        : null;

    String authUrl(String url) =>
        authHeader != null && isSameOrigin(fullConfig.serverUrl, url)
        ? embedCredentials(url, username!, password ?? '')
        : url;
    final watchLaterUrls = entries
        .map((entry) => authUrl(entry.url))
        .toList(growable: false);

    final startSec = config.resumeEnabled ? resumeSeconds : null;
    final subtitleInjectionEnabled = config.subtitleInjectionEnabled;
    final subtitleAutoSelectEnabled =
        subtitleInjectionEnabled && config.subtitleAutoSelectEnabled;

    // ── 3. 组装参数 ───────────────────────────────────────────
    final listMode = isMpv && entries.length > 1;
    // 每次启动使用唯一 named pipe，作为会话身份与未来 IPC 扩展入口。
    final pipeToken = '${DateTime.now().microsecondsSinceEpoch}_$launchNumber';
    final ipcPipe = isMpv ? '${r'\\.\pipe\mpvsocket_'}$pipeToken' : null;
    String? progressFilePath;
    // 多集模式：生成 m3u 播放列表（EXTINF 标题 + EXTVLCOPT 窗口标题
    // + 直链 URL），由 mpv 原生绑定标题。
    final playlistPath = listMode
        ? await MpvScripts.ensurePlaylistM3u(
            entries,
            authUrl,
            await _scriptBase(),
            sessionId: assetSessionId,
          )
        : null;
    final args = listMode
        ? _buildListArgs(
            config: config,
            playlistPath: playlistPath!,
            playlistStart: playlistStart,
          )
        : _buildArgs(
            config,
            authUrl(entries.first.url),
            (!isMpv &&
                    subtitleInjectionEnabled &&
                    entries.first.subtitle != null)
                ? authUrl(entries.first.subtitle!.url)
                : null,
            startSec,
          );

    // MPV 使用 URL userinfo 完成源站 Basic 认证。四个实测版本均会在
    // 跨来源重定向时移除该凭据，而全局 http-header-fields 会继续转发。
    if (isMpv) {
      // 自动字幕由 StreamPath 严格按同目录候选注入；关闭 mpv 自身的
      // 模糊搜索，避免 mpv.conf/sub-file-paths 从字幕备份目录载入字幕。
      if (subtitleInjectionEnabled) {
        args.add('--sub-auto=no');
      }
      // named pipe 按播放实例唯一并覆盖 mpv.conf 中的固定配置；当前
      // 稳定控制主通道为每会话 Lua 状态/命令文件，pipe 保留为会话
      // 身份校验与后续无阻塞 IPC 扩展入口。
      args.add('--input-ipc-server=$ipcPipe');
      // 标题显示：单集直接用 `--force-media-title`（per-file 选项，
      // 启动即生效）；多集由 m3u 的 EXTVLCOPT 逐集绑定，标题脚本仅
      // 为不支持 EXTVLCOPT 的旧版 mpv 兜底。
      if (!listMode) {
        // 标题来自服务器（文件/目录名），剥离控制字符防止参数注入
        // 与日志混淆（与 m3u 路径的 _sanitizeTitle 处理一致）。
        final rawTitle =
            entries.first.title ??
            MpvScripts.fallbackTitleFromUrl(entries.first.url);
        final title = rawTitle.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ');
        if (title.trim().isNotEmpty) {
          args.add('--force-media-title=$title');
        }
      }
      if (config.resumeEnabled) {
        final dir = await _ensureWatchLaterDir();
        try {
          await const MpvWatchLaterSync().purgeExpiredRecords(
            dir,
            watchLaterUrls,
            maxAge:
                _progressService?.retention ??
                const DefaultCacheRetentionPolicy().playbackRetention,
          );
        } catch (_) {
          // 续播缓存维护失败不阻断播放器启动。
        }
        args.addAll([
          '--save-position-on-quit',
          '--watch-later-directory=${dir.path}',
        ]);
      }
      // TS 的随机起始时间戳显式归零，但不执行 --start=0 seek。
      // mpv 官方说明 rebase 只移动时间轴，适合 transport stream。
      if (entries.any((entry) => isTsContainerUrl(entry.url))) {
        args.add('--rebase-start-time=yes');
      }
      // StreamPath 只注入明确匹配的同级目录字幕。自动选择开启时使用
      // sub-add select；关闭时使用 auto 并恢复原 sid，仅加入轨道且
      // 保留当前内封字幕。
      if (subtitleInjectionEnabled && entries.any((e) => e.subtitle != null)) {
        args.add(
          '--script=${listMode ? await MpvScripts.ensurePlaylistSubtitles(entries, authUrl, await _scriptBase(), autoSelect: subtitleAutoSelectEnabled, sessionId: assetSessionId) : await MpvScripts.ensureSingleSubtitle(entries.first.subtitle!, authUrl, await _scriptBase(), autoSelect: subtitleAutoSelectEnabled, sessionId: assetSessionId)}',
        );
      }
      // 多集标题兜底脚本（与字幕脚本独立，始终注入）。
      if (listMode) {
        args.add(
          '--script=${await MpvScripts.ensureTitles(entries, await _scriptBase(), sessionId: assetSessionId)}',
        );
      }
      // 当前播放状态上报脚本：file-loaded（含自动切集）与暂停变化时
      // 写 mpv-current.txt，供软件同步「继续播放」条（单集同样注入）。
      {
        final dataDir = await AppPaths.cacheDirectory(); // mpv 会话产物
        final currentPath = p.join(
          dataDir.path,
          assetSessionId == null
              ? AppConstants.mpvCurrentFileName
              : sessionStatusFileName(resolvedSessionId),
        );
        final commandPath = p.join(
          dataDir.path,
          assetSessionId == null
              ? AppConstants.mpvCommandFileName
              : sessionCommandFileName(resolvedSessionId),
        );
        progressFilePath = p.join(
          dataDir.path,
          sessionProgressFileName(resolvedSessionId),
        );
        try {
          final progressFile = File(progressFilePath);
          if (await progressFile.exists()) await progressFile.delete();
        } on FileSystemException {
          // 旧日志清理失败不阻断播放器；同步侧会忽略不完整 JSON 行。
        }
        // 启动前清除残留的「已播完」标记（首行 -1），避免 mpv 加载
        // 文件期间 UI 轮询误读旧状态。
        await clearStaleFinishedMark(File(currentPath));
        args.add(
          '--script=${await MpvScripts.ensureCurrent(currentPath, commandPath, await _scriptBase(), sessionId: assetSessionId, progressFile: progressFilePath)}',
        );
      }
      // 多集续播：`--start` 是全局选项（作用于每一集），因此改为
      // 预写播放起点集的 watch_later 文件，由 mpv 原生恢复；后续集
      // 由 mpv 自身的 watch_later 机制接管。无续播进度（含已看完）
      // 时：清除起点集旧记录并禁用恢复，保证从头播放。
      if (config.resumeEnabled) {
        final startEntry = entries[playlistStart];
        if (listMode && startSec != null) {
          await _writeResumeStart(authUrl(startEntry.url), startSec);
        } else if (startSec == null) {
          await _clearWatchLater(startEntry.url);
          final playerUrl = authUrl(startEntry.url);
          if (playerUrl != startEntry.url) {
            await _clearWatchLater(playerUrl);
          }
          args.add('--no-resume-playback');
          // TS 续播由时间轴重映射处理，MPV 参数仍从媒体起点读取。
          if (!isTsContainerUrl(startEntry.url)) {
            args.add('--start=0');
          }
        }
      }
      // ── 6. 智能缓存策略注入（独立增强层） ─────────────────
      // MPV 缓存控制系统：按媒体/内存/网络生成缓存参数，追加在
      // 参数末尾（mpv 后者覆盖前者）。门面契约保证不抛出，外层
      // 再兜底一次：任何异常只跳过注入，绝不阻断播放。
      // 同时登记「URL → 会话」映射并订阅码率就绪回调，供后台
      // 码率上报后通过 mpv IPC 动态更新本次播放缓存参数。
      if (_cachePolicy != null) {
        try {
          final cacheArgs = await _cachePolicy.buildCacheArgs(
            sessionId: resolvedSessionId,
            url: entries[playlistStart].url,
            authHeader: authHeader,
            userArgs: config.args,
          );
          args.addAll(cacheArgs);
          // 凭**本次会话状态**（非 URL 历史结果）决定是否启动监控。
          cacheSession = _cachePolicy.sessionState(resolvedSessionId);
          _authHeaders[resolvedSessionId] = authHeader;
          _cachePolicy.onPolicyReady = _handlePolicyReady;
        } catch (_) {
          // 缓存增强层失败：跳过注入，不影响播放。
        }
      }
    }

    // ── 4. 启动进程 ───────────────────────────────────────────
    final Process process;
    try {
      // detached 模式：子进程独立运行、正常弹出播放器窗口。
      // 注意：detached 拿不到 exitCode，退出检测改由 tasklist
      // 轮询探活完成（见 _watchExitAndSync）。
      process = await Process.start(
        config.executable,
        args,
        mode: ProcessStartMode.detached,
      );
    } on FileSystemException catch (e) {
      throw AppException.process('无法启动播放器「${config.executable}」：文件不存在或路径错误', e);
    } on ProcessException catch (e) {
      throw AppException.process('播放器启动失败：${e.message}（请检查可执行文件与系统 PATH）', e);
    }

    if (!automaticRecovery) {
      _recoveryStates[resolvedSessionId] = _PlaybackRecoveryState();
    } else {
      _recoveryStates.putIfAbsent(
        resolvedSessionId,
        _PlaybackRecoveryState.new,
      );
    }

    // ── 5. 注册独立会话并监听退出 ─────────────────────────────
    final dataDir = isMpv ? await AppPaths.cacheDirectory() : null; // 会话产物
    final runtime =
        _PlayerSessionRuntime(
            sessionId: resolvedSessionId,
            pid: process.pid,
            isMpv: isMpv,
            launchedHere: true,
            statusFilePath: isMpv
                ? p.join(
                    dataDir!.path,
                    assetSessionId == null
                        ? AppConstants.mpvCurrentFileName
                        : sessionStatusFileName(resolvedSessionId),
                  )
                : null,
            commandFilePath: isMpv
                ? p.join(
                    dataDir!.path,
                    assetSessionId == null
                        ? AppConstants.mpvCommandFileName
                        : sessionCommandFileName(resolvedSessionId),
                  )
                : null,
            progressFilePath: progressFilePath,
            ipcPipeName: ipcPipe,
            epoch: ++_runtimeEpoch,
            currentTrackUrl: entries[playlistStart].url,
            currentPlaylistPos: playlistStart,
            entries: List<MediaEntry>.unmodifiable(entries),
            watchLaterUrls: List<String>.unmodifiable(watchLaterUrls),
            username: username,
            password: password,
          )
          ..aliveCache = true
          ..aliveCacheAt = DateTime.now();
    _sessions[resolvedSessionId] = runtime;
    _lastSessionId = resolvedSessionId;
    // 第二阶段：播放中动态监控（内存压力/网络异常/卡顿记录）。
    // 仅在本次会话状态为「正常注入且非 TS 直链」时启动；监控输出
    // 经 IPC 推送动态调整缓存参数，警告经 [onCacheWarning] 通知 UI。
    final session = cacheSession;
    if (isMpv &&
        _cachePolicy != null &&
        session != null &&
        session.shouldMonitor &&
        !isTsContainerUrl(entries[playlistStart].url)) {
      try {
        // shouldMonitor 已保证 result 非空（正常注入且非 TS 直链）。
        final injected = session.result!;
        _cachePolicy.startMonitor(
          sessionId: resolvedSessionId,
          url: entries[playlistStart].url,
          statusFilePath: runtime.statusFilePath!,
          initialDemuxerMaxBytes: injected.demuxerMaxBytes,
          initialCacheSecs: injected.cacheSecs,
          fileSizeBytes: injected.fileSizeBytes,
          bitrateMbps: injected.bitrateMbps,
          memoryBudgetBytes: injected.memoryBudgetBytes,
          minCacheSecs: injected.minCacheSecs,
          maxCacheSecs: injected.maxCacheSecs,
          fullCache: injected.fullCache,
          // 监控闭包**直接捕获本会话 sessionId**：同 URL 双会话并发
          // 时各推各的，不经过 URL 映射查找。
          onAdjustment: (a) => _handleCacheAdjustment(
            resolvedSessionId,
            a,
            runtime: runtime,
            generation: runtime.trackGeneration,
          ),
          onWarning: (msg) => _handleCacheWarning(resolvedSessionId, msg),
        );
      } catch (_) {
        // 增强层：监控启动失败静默，不影响播放。
      }
    }
    // 曲目检测始终启动：首集为 TS 时仍需发现后续非 TS；TS 稳定起播
    // 后也由此进入轻量顺序预读阶段。runtime 已注册，无需一秒竞态等待。
    if (isMpv && _cachePolicy != null) {
      unawaited(
        _monitorDurationForCache(
          runtime,
          entries[playlistStart].url,
          userArgs: config.args,
        ),
      );
    }
    final exitSync = _watchExitAndSync(
      runtime,
      process,
      entries,
      syncProgress: isMpv,
    );
    runtime.exitSyncFuture = exitSync;
    unawaited(exitSync);

    return PlayerLaunchResult(
      process: process,
      args: args,
      sessionId: resolvedSessionId,
      ipcPipeName: ipcPipe,
      statusFilePath: runtime.statusFilePath,
      commandFilePath: runtime.commandFilePath,
      progressFilePath: runtime.progressFilePath,
    );
  }

  /// 校验可执行文件是否真实存在（仅当配置为绝对/相对路径时）。
  ///
  /// 仅含命令名（如 `mpv`）时交给系统 PATH 解析，返回 null（未知）。
  /// 返回非 null 表示存在问题描述。
  String? validateExecutable(PlayerConfig config) {
    final exe = config.executable.trim();
    if (exe.isEmpty) return '播放器路径不能为空';
    if (exe.contains('\\') || exe.contains('/')) {
      if (!File(exe).existsSync()) {
        return '文件不存在：$exe';
      }
    }
    return null;
  }

  static bool _isMpvExecutable(String executable) {
    final name = p.basename(executable.trim()).toLowerCase();
    // 只检查 basename，避免目录名含 mpv 导致 VLC 等播放器误判；同时
    // 兼容 mpvnet、便携版和测试用 fake_mpv 可执行文件。
    return name.contains('mpv');
  }

  // ── 智能缓存动态更新（mpv 时长上报 → 平均码率 → IPC 推送） ──

  /// 播放开始后监控 mpv 状态文件的 duration（第 5 行），上报缓存模块。
  ///
  /// mkv/mp4 等容器的时长在文件头部，mpv 打开即写入状态文件；
  /// 缓存模块据此计算平均码率（大小 ÷ 时长）并动态更新本次播放。
  /// 增强层：会话退出/读取失败/超时一律静默。
  ///
  /// [userArgs] 为本次播放的用户模板参数（首集注入时已使用）：
  /// 切集重算必须沿用，否则用户手动缓存参数会在下一集被自动策略
  /// 覆盖（尊重手动配置的语义不能随切集丢失）。
  Future<void> _monitorDurationForCache(
    _PlayerSessionRuntime runtime,
    String url, {
    List<String> userArgs = const [],
  }) async {
    final policy = _cachePolicy;
    if (policy == null) return;
    final sessionId = runtime.sessionId;
    if (runtime.statusFilePath == null) return;
    final file = File(runtime.statusFilePath!);
    // 状态文件必须由**本次播放**写入（mtime 不早于监控启动）：
    // 上次播放残留的文件（异常退出未清除）会被此检查拦截，避免
    // 把旧时长误报为本次播放。
    final launchCutoff = DateTime.now().subtract(const Duration(seconds: 1));
    // 当前正在播放的曲目（播放列表切集后更新为新集 URL）。
    var lastTrackUrl = url;
    // 每集时长上报一次（去重，切集后新集重新上报）。
    final reportedDurationGenerations = <int>{};
    final tsRuntimeEnabledGenerations = <int>{};
    final tsFirstStableSampleAt = <int, DateTime>{};
    // 持续轮询直到播放器退出：每轮**先读状态文件**（播放器退出前的
    // 最后数据仍处理），再检查进程存活——避免进程快速退出时漏掉
    // 已写入的状态（同时使测试不依赖进程存活时长）。
    while (true) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!identical(_sessions[sessionId], runtime)) return;
      try {
        if (!file.existsSync()) {
          if (!await isPlayerRunning(sessionId)) return;
          continue;
        }
        final lines = await file.readAsLines();
        if (lines.length < 2) {
          if (!await isPlayerRunning(sessionId)) return;
          continue;
        }
        // ── 播放列表切集检测（状态文件第 2 行为当前 path） ──
        // 与正在监控的曲目不同（URL 编码规范化比较）→ 新集：
        // 重新探测/计算缓存参数并推送，同时更新监控基准。
        if (lines.length >= 2) {
          final track = stripUserInfo(lines[1].trim());
          final playlistPos = int.tryParse(lines.first.trim());
          final playlistEntryChanged =
              playlistPos != null &&
              playlistPos >= 0 &&
              runtime.currentPlaylistPos != null &&
              playlistPos != runtime.currentPlaylistPos;
          if (track.isNotEmpty &&
              (!_sameTrack(track, lastTrackUrl) || playlistEntryChanged)) {
            lastTrackUrl = track;
            // 代际令牌：递增使在途的旧切集调用过期——快速连续切集时
            // （前集探测 HEAD 可能 1.5s 超时，慢于轮询 1s），旧集完成
            // 后不得用旧基准覆盖新集的监控/推送。
            runtime.currentTrackUrl = track;
            runtime.currentPlaylistPos = playlistPos;
            final generation = ++runtime.trackGeneration;
            // 在同一后台 watcher 内等待策略完成，避免同轮 duration 先于
            // HEAD/认证探测写入 null 大小；不阻塞播放器或 UI。
            await _handleTrackChanged(
              track,
              runtime,
              policy,
              file.path,
              userArgs: userArgs,
              generation: generation,
            );
            if (!_isRuntimeCurrent(runtime, generation)) continue;
          }
        }
        final currentState = policy.sessionState(sessionId);
        final timePos = lines.length > 3 ? double.tryParse(lines[3]) : null;
        // TS 启动阶段保持 cache=no；确认已经直接起播后才启用小型顺序
        // 预读，因此不会把容器打开从 5 秒拖到十几秒。这里使用首次
        // 有效状态后的墙钟时间，不用绝对 time-pos：续播 TS 一加载就
        // 可能是数百秒，若按 time-pos>=3 会在恢复 seek 尚未稳定时过早
        // 开缓存，重新拖慢起播。
        final currentGeneration = runtime.trackGeneration;
        if (isTsContainerUrl(lastTrackUrl) &&
            currentState?.tsOnly == true &&
            timePos != null &&
            timePos >= 0 &&
            !tsRuntimeEnabledGenerations.contains(currentGeneration)) {
          final firstStableAt = tsFirstStableSampleAt.putIfAbsent(
            currentGeneration,
            DateTime.now,
          );
          if (DateTime.now().difference(firstStableAt) <
              const Duration(seconds: 2)) {
            if (!await isPlayerRunning(sessionId)) return;
            continue;
          }
          final enabled = await _enableTsRuntimeCache(
            runtime,
            lastTrackUrl,
            policy,
            file.path,
            userArgs: userArgs,
            generation: currentGeneration,
          );
          if (enabled) {
            tsRuntimeEnabledGenerations.add(currentGeneration);
          }
        }
        // ── 当前集时长上报（mpv 打开 mkv/mp4 即写入） ──
        final duration = lines.length > 4 ? double.tryParse(lines[4]) : null;
        if (duration != null &&
            duration > 0 &&
            !isTsContainerUrl(lastTrackUrl) &&
            policy.sessionState(sessionId)?.shouldMonitor == true &&
            file.lastModifiedSync().isAfter(launchCutoff) &&
            reportedDurationGenerations.add(runtime.trackGeneration)) {
          final resolution = lines.length > 13 && lines[13].trim().isNotEmpty
              ? lines[13].trim()
              : null;
          policy.recordDuration(
            sessionId,
            lastTrackUrl,
            duration,
            resolution: resolution,
          );
        }
      } catch (e) {
        _logCache('Duration monitor: status file read failed, stopped ($e)');
        return; // 增强层：监控失败静默。
      }
      if (!await isPlayerRunning(sessionId)) return;
    }
  }

  /// 播放列表切集：重新计算新集的缓存参数并推送 mpv。
  ///
  /// 首集参数（--cache-secs/--demuxer-max-bytes）对 mpv 全局生效，
  /// 但不同集的码率/大小不同，切集后按新集重新探测与计算更精确；
  /// 同时重新注册监控基准（后续动态调整定位到新集）。
  /// [generation] 为本次切集的代际令牌：await 探测期间若又发生了
  /// 更新的切集（代际已递增），本结果过期，副作用（IPC 推送/监控
  /// 重建）全部丢弃——防止旧基准覆盖新集。
  /// 增强层：任何失败静默，mpv 继续使用当前参数。
  Future<void> _handleTrackChanged(
    String track,
    _PlayerSessionRuntime runtime,
    CachePolicyProvider policy,
    String statusFilePath, {
    List<String> userArgs = const [],
    int generation = 0,
  }) async {
    final sessionId = runtime.sessionId;
    try {
      _logCache(
        'Track changed: ${_redactUrlForLog(track)} '
        '-> recomputing cache args',
      );
      await policy.buildCacheArgs(
        sessionId: sessionId,
        url: track,
        authHeader: _authHeaders[sessionId],
        // 沿用用户手动缓存参数（与首集一致：尊重手动配置）。
        userArgs: userArgs,
      );
      // 过期检查：期间又发生了更新的切集 → 本结果丢弃（窄竞态防护）。
      if (!_isRuntimeCurrent(runtime, generation)) return;
      // 更新播放中动态监控的基准（新集码率/大小/缓存初值）。
      // 注意：TS 直链/跳过分支不写入策略结果（lastResultFor 为 null），
      // 此时必须停止上一集遗留的监控——否则旧监控会继续以旧基准
      // 采样同一状态文件的新集数据，产生错误调整。
      _applyPolicyState(
        runtime,
        track,
        policy,
        statusFilePath,
        generation: generation,
        seekableCacheEnabled: !isTsContainerUrl(track),
      );
    } catch (_) {
      // 增强层：切集重算失败静默，不影响播放。
    }
  }

  Future<bool> _enableTsRuntimeCache(
    _PlayerSessionRuntime runtime,
    String track,
    CachePolicyProvider policy,
    String statusFilePath, {
    required List<String> userArgs,
    required int generation,
  }) async {
    try {
      await policy.buildCacheArgs(
        sessionId: runtime.sessionId,
        url: track,
        authHeader: _authHeaders[runtime.sessionId],
        userArgs: userArgs,
        runtimeTs: true,
      );
      if (!_isRuntimeCurrent(runtime, generation)) return false;
      _applyPolicyState(
        runtime,
        track,
        policy,
        statusFilePath,
        generation: generation,
        seekableCacheEnabled: false,
      );
      return policy.sessionState(runtime.sessionId)?.shouldMonitor == true;
    } catch (_) {
      return false;
    }
  }

  void _applyPolicyState(
    _PlayerSessionRuntime runtime,
    String track,
    CachePolicyProvider policy,
    String statusFilePath, {
    required int generation,
    required bool seekableCacheEnabled,
  }) {
    if (!_isRuntimeCurrent(runtime, generation)) return;
    final state = policy.sessionState(runtime.sessionId);
    if (state?.tsOnly == true) {
      policy.stopMonitor(runtime.sessionId);
      _queueCacheUpdate(
        runtime,
        generation: generation,
        reset: true,
        cacheEnabled: false,
        seekableCacheEnabled: false,
      );
      return;
    }
    final result = state?.result;
    if (state?.shouldMonitor != true || result == null || result.skipped) {
      policy.stopMonitor(runtime.sessionId);
      return;
    }
    _queueCacheUpdate(
      runtime,
      generation: generation,
      reset: true,
      cacheEnabled: true,
      seekableCacheEnabled: seekableCacheEnabled,
      demuxerMaxBytes: result.demuxerMaxBytes,
      cacheSecs: result.cacheSecs,
    );
    policy.startMonitor(
      sessionId: runtime.sessionId,
      url: track,
      statusFilePath: statusFilePath,
      initialDemuxerMaxBytes: result.demuxerMaxBytes,
      initialCacheSecs: result.cacheSecs,
      fileSizeBytes: result.fileSizeBytes,
      bitrateMbps: result.bitrateMbps,
      memoryBudgetBytes: result.memoryBudgetBytes,
      minCacheSecs: result.minCacheSecs,
      maxCacheSecs: result.maxCacheSecs,
      fullCache: result.fullCache,
      onAdjustment: (adjustment) => _handleCacheAdjustment(
        runtime.sessionId,
        adjustment,
        runtime: runtime,
        generation: generation,
      ),
      onWarning: (message) => _handleCacheWarning(runtime.sessionId, message),
    );
  }

  /// 日志用 URL 脱敏：仅保留 `scheme://host[:port]/path`（签名 token
  /// 等 query 参数不落终端日志；与缓存模块诊断快照规则一致）。
  static String _redactUrlForLog(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return '<unparseable>';
    final buffer = StringBuffer()
      ..write(uri.scheme)
      ..write('://')
      ..write(uri.host);
    if (uri.hasPort) {
      buffer
        ..write(':')
        ..write(uri.port);
    }
    buffer.write(uri.path.isEmpty ? '/' : uri.path);
    return buffer.toString();
  }

  /// 该切集调用是否为该会话最新的一次（代际一致）。
  bool _isRuntimeCurrent(_PlayerSessionRuntime runtime, int generation) =>
      identical(_sessions[runtime.sessionId], runtime) &&
      runtime.trackGeneration == generation;

  /// URL 规范化比较（mpv 状态文件的 path 与 launch 的 url 可能存在
  /// 百分号编码差异，如 %20 与空格）。
  static bool _sameTrack(String a, String b) {
    if (a == b) return true;
    try {
      if (Uri.decodeFull(a) == Uri.decodeFull(b)) return true;
    } catch (_) {}
    return false;
  }

  /// 码率就绪回调（携带 sessionId：同 URL 双会话并发不串线）。
  ///
  /// 增强层原则：会话不存在/已退出/推送失败一律静默，不影响播放。
  void _handlePolicyReady(
    String sessionId,
    String url,
    CachePolicyResult result,
  ) {
    if (result.skipped) return;
    final runtime = _sessions[sessionId];
    final state = _cachePolicy?.sessionState(sessionId);
    if (runtime == null ||
        state?.shouldMonitor != true ||
        !_sameTrack(runtime.currentTrackUrl ?? '', url)) {
      return;
    }
    _queueCacheUpdate(
      runtime,
      generation: runtime.trackGeneration,
      reset: true,
      cacheEnabled: true,
      seekableCacheEnabled: !isTsContainerUrl(url),
      demuxerMaxBytes: result.demuxerMaxBytes,
      cacheSecs: result.cacheSecs,
    );
  }

  /// 播放中动态调整回调（携带 sessionId，直接推送本会话）：
  /// 经 mpv IPC 推送调整后的缓存参数。
  ///
  /// 增强层原则：会话不存在/已退出/推送失败一律静默。
  void _handleCacheAdjustment(
    String sessionId,
    CacheAdjustment adjustment, {
    required _PlayerSessionRuntime runtime,
    required int generation,
  }) {
    if (runtime.sessionId != sessionId ||
        !_isRuntimeCurrent(runtime, generation)) {
      return;
    }
    _queueCacheUpdate(
      runtime,
      generation: generation,
      demuxerMaxBytes: adjustment.demuxerMaxBytes,
      cacheSecs: adjustment.cacheSecs,
    );
  }

  /// 播放中动态保护的用户警告（携带 sessionId：同 URL 双会话时 UI
  /// 可区分来源）：消息带会话标识后仅转发 UI 回调（弹窗中文提示）；
  /// 终端诊断日志由监控模块内部输出英文。
  void _handleCacheWarning(String sessionId, String message) {
    onCacheWarning?.call('[会话 $sessionId] $message');
  }

  /// 按 session 串行并合并缓存目标。旧任务在真正写入前再次核对
  /// runtime/曲目代际；失败最多重试三次，避免 monitor 已更新内部状态
  /// 而播放器永远停留在旧值。
  void _queueCacheUpdate(
    _PlayerSessionRuntime runtime, {
    required int generation,
    int? demuxerMaxBytes,
    int? cacheSecs,
    bool? cacheEnabled,
    bool? seekableCacheEnabled,
    bool reset = false,
  }) {
    if (!_isRuntimeCurrent(runtime, generation) ||
        !runtime.isMpv ||
        runtime.ipcPipeName == null) {
      return;
    }
    final state = _cacheIpcStates.putIfAbsent(
      runtime.sessionId,
      _CacheIpcState.new,
    );
    if (reset) {
      state
        ..demuxerMaxBytes = null
        ..cacheSecs = null
        ..cacheEnabled = null
        ..seekableCacheEnabled = null;
    }
    if (demuxerMaxBytes != null) state.demuxerMaxBytes = demuxerMaxBytes;
    if (cacheSecs != null) state.cacheSecs = cacheSecs;
    if (cacheEnabled != null) state.cacheEnabled = cacheEnabled;
    if (seekableCacheEnabled != null) {
      state.seekableCacheEnabled = seekableCacheEnabled;
    }
    final revision = ++state.revision;
    state.tail = state.tail
        .then((_) async {
          // 新目标已经入队时直接丢弃旧目标，由最后一项一次性写完整状态。
          if (state.revision != revision ||
              !_isRuntimeCurrent(runtime, generation)) {
            return;
          }
          Object? lastError;
          for (var attempt = 0; attempt < 3; attempt++) {
            if (!_isRuntimeCurrent(runtime, generation) ||
                state.revision != revision) {
              return;
            }
            try {
              if (!await isPlayerRunning(runtime.sessionId)) {
                _logCache(
                  'IPC cache update skipped: session=${runtime.sessionId}, '
                  'player not running | requested ${_cacheIpcSummary(state)}',
                );
                return;
              }
              final ok = await _runIpcUpdate(
                runtime.ipcPipeName!,
                demuxerMaxBytes: state.demuxerMaxBytes,
                cacheSecs: state.cacheSecs,
                cacheEnabled: state.cacheEnabled,
                seekableCacheEnabled: state.seekableCacheEnabled,
              );
              if (ok) {
                _logCache(
                  'IPC cache update applied: session=${runtime.sessionId} | '
                  '${_cacheIpcSummary(state)}',
                );
                return;
              }
              lastError = StateError('mpv returned no success response');
            } catch (e) {
              lastError = e;
            }
            await Future<void>.delayed(
              Duration(milliseconds: 150 * (attempt + 1)),
            );
          }
          _logCache(
            'IPC cache update failed after 3 attempts: '
            'session=${runtime.sessionId} | requested '
            '${_cacheIpcSummary(state)} | player may keep previous values'
            '${lastError != null ? ' | error=$lastError' : ''}',
          );
        })
        .catchError((_) {
          // 增强层：队列异常静默，后续新目标仍可继续入队。
        });
  }

  /// 在独立 isolate 中通过 named pipe 更新 mpv 缓存属性。
  ///
  /// 字段为 null 时跳过对应属性（部分更新）。win32 CreateFile 打开
  /// named pipe 在服务端忙时会同步阻塞主线程（最长约 20 秒），绝不
  /// 能跑在 UI isolate（曾导致软件间歇性"未响应"）。
  Future<bool> _runIpcUpdate(
    String pipeName, {
    required int? demuxerMaxBytes,
    required int? cacheSecs,
    bool? cacheEnabled,
    bool? seekableCacheEnabled,
  }) async {
    final injected = _cacheIpcUpdater;
    if (injected != null) {
      return injected(
        pipeName,
        demuxerMaxBytes: demuxerMaxBytes,
        cacheSecs: cacheSecs,
        cacheEnabled: cacheEnabled,
        seekableCacheEnabled: seekableCacheEnabled,
      );
    }
    return Isolate.run(() async {
      final controller = MpvSessionController(pipeName: pipeName);
      final connected = await controller.connect(
        timeout: const Duration(seconds: 3),
        retryInterval: const Duration(milliseconds: 200),
      );
      if (!connected) return false;
      try {
        if (cacheEnabled != null) {
          await controller.setProperty('cache', cacheEnabled ? 'yes' : 'no');
        }
        if (seekableCacheEnabled != null) {
          await controller.setProperty(
            'demuxer-seekable-cache',
            seekableCacheEnabled ? 'yes' : 'no',
          );
        }
        if (demuxerMaxBytes != null) {
          await controller.setProperty('demuxer-max-bytes', demuxerMaxBytes);
        }
        if (cacheSecs != null) {
          await controller.setProperty('cache-secs', cacheSecs);
        }
        return true;
      } finally {
        await controller.disconnect();
      }
    });
  }

  static String _cacheIpcSummary(_CacheIpcState state) {
    final values = <String>[
      if (state.cacheEnabled != null)
        'cache=${state.cacheEnabled! ? 'yes' : 'no'}',
      if (state.cacheSecs != null) 'cache-secs=${state.cacheSecs}',
      if (state.demuxerMaxBytes != null)
        'demuxer-max-bytes=${state.demuxerMaxBytes} '
            '(${_formatCacheBytes(state.demuxerMaxBytes!)})',
      if (state.seekableCacheEnabled != null)
        'demuxer-seekable-cache='
            '${state.seekableCacheEnabled! ? 'yes' : 'no'}',
    ];
    return values.isEmpty ? 'no cache properties' : values.join(', ');
  }

  static String _formatCacheBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GiB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MiB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)}KiB';
    }
    return '${bytes}B';
  }

  // ── 单集参数（模板渲染） ────────────────────────────────────

  /// 展开参数模板；返回最终参数列表。
  ///
  /// 含占位符但值为空的参数整条移除（如无字幕时的 `--sub-file={subfile}`）；
  /// 模板若未包含 `{url}`，则把视频地址追加到末尾兜底。
  List<String> _buildArgs(
    PlayerConfig config,
    String videoUrl,
    String? subUrl,
    int? startSec,
  ) {
    final values = <String, String>{
      'url': videoUrl,
      'subfile': subUrl ?? '',
      'start': startSec?.toString() ?? '',
    };

    final args = <String>[];
    for (final template in config.args) {
      final resolved = _resolveTemplate(template, values);
      if (resolved != null) args.add(resolved);
    }

    // 兜底：模板里没有任何 {url} 占位符时，保证视频地址一定传入。
    final hasUrlPlaceholder = config.args.any((a) => a.contains('{url}'));
    if (!hasUrlPlaceholder) args.add(videoUrl);

    return args;
  }

  /// 展开单个参数模板；无值占位符从模板中剔除，剔除后若只剩
  /// 「空选项外壳」（如 `--start=`）则整项移除（返回 null）。
  ///
  /// 与旧行为（含任一空值占位符即整项移除）的区别：同一参数项含多个
  /// 占位符时（如 `--sub-file={subfile} --start={start}`），无值的
  /// `{start}` 不再导致有值的 `{subfile}` 一起丢失。
  String? _resolveTemplate(String template, Map<String, String> values) {
    var out = template;
    for (final entry in values.entries) {
      out = out.replaceAll('{${entry.key}}', entry.value);
    }
    return _stripEmptyTokens(out);
  }

  /// 剔除空 token：残留占位符（无值未替换）与空选项外壳（`--start=`）。
  /// 结果为空返回 null（该参数项移除）。
  static String? _stripEmptyTokens(String raw) {
    final tokens = raw.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    final kept = tokens
        .where((t) {
          if (t.contains('{') || t.contains('}')) return false; // 残留占位符
          if (RegExp(r'^--?[\w.-]+=$').hasMatch(t)) {
            return false; // --start= 空外壳
          }
          return true;
        })
        .join(' ');
    return kept.isEmpty ? null : kept;
  }

  // ── 播放列表参数（自动切集） ────────────────────────────────

  /// 组装播放列表参数：仅注入全局项与各集 URL。
  ///
  /// 说明：mpv 的 `--{ ... --}` per-file 作用域只对 per-file 选项有效，
  /// 而 `--sub-file`/`--start` 是全局选项，在作用域内不生效，
  /// 因此字幕与续播分别由：
  /// - 字幕：`--script=` 注入的 sub-add 脚本（每集按 playlist-pos 注入）；
  /// - 续播：预写首集 watch_later 文件（mpv 原生恢复）。
  @visibleForTesting
  List<String> buildListArgs({
    required PlayerConfig config,
    required String playlistPath,
    int playlistStart = 0,
  }) {
    return _buildListArgs(
      config: config,
      playlistPath: playlistPath,
      playlistStart: playlistStart,
    );
  }

  List<String> _buildListArgs({
    required PlayerConfig config,
    required String playlistPath,
    required int playlistStart,
  }) {
    final args = <String>[];

    // 无占位符的静态模板项 → 全局参数。
    for (final t in config.args) {
      if (!t.contains('{')) args.add(t);
    }

    // 多集统一经 m3u 播放列表：每集标题（EXTINF）与窗口标题
    // （EXTVLCOPT force-media-title）由 mpv 原生绑定到对应条目，
    // 切集时由 mpv 自己切换，不存在事件时序错位；URL 直链原样保留。
    // 含 {url} 的模板项在多集模式下不再逐集展开。
    args.add('--playlist=$playlistPath');
    // 播放起点：从点击的集开始（之前的集仍在播放列表中）。
    if (playlistStart > 0) {
      args.add('--playlist-start=$playlistStart');
    }
    return args;
  }

  // ── 退出检测与进度写回 ───────────────────────────────────────

  /// detached 模式无法读取 exitCode，改用系统命令轮询探活：
  /// 进程消失后执行进度同步（逐媒体日志 + watch_later → 进度库）。
  Future<void> _watchExitAndSync(
    _PlayerSessionRuntime runtime,
    Process process,
    List<MediaEntry> entries, {
    required bool syncProgress,
  }) async {
    final pid = process.pid;
    while (await _isProcessAlive(pid)) {
      await Future.delayed(const Duration(seconds: 2));
      if (await _tryHandlePlaybackFailure(runtime)) return;
    }
    // 初次打开失败时 MPV 可能在一个轮询周期内退出；进程消失后再读一次
    // JSONL，避免遗漏 shutdown 前刚写入的 end-file error。
    if (await _tryHandlePlaybackFailure(runtime)) return;
    // 只更新仍指向本 runtime 的会话；同 ID 已重新启动时不干预新进程。
    if (identical(_sessions[runtime.sessionId], runtime)) {
      runtime.aliveCache = false;
      runtime.aliveCacheAt = DateTime.now();
      // 会话退出：停止本会话的播放中动态监控并清理认证头与切集代际。
      // （回调均已携带/捕获 sessionId，无需 URL 映射即可正确路由；
      //  清理必须在 identical 保护块内——同 ID 快速重启时，旧退出
      //  监听不得停掉新会话的监控/代际。）
      _cleanupCacheRuntime(runtime);
    }
    if (syncProgress) {
      try {
        await _syncProgress(runtime, entries);
      } catch (e) {
        // ignore: avoid_print
        print('同步播放进度失败: $e');
      }
    }
  }

  Future<bool> _tryHandlePlaybackFailure(_PlayerSessionRuntime runtime) async {
    if (!runtime.isMpv || runtime.entries.isEmpty) return false;
    final config = _configStore.current.openListRecovery;
    if (!config.enabled) return false;
    final state = _recoveryStates[runtime.sessionId];
    if (state == null || state.recovering || state.attempts >= 2) return false;

    final failure = await _readNextPlaybackFailure(runtime);
    if (failure == null) return false;
    state.attempts++;
    state.recovering = true;
    _emitPlaybackRecovery(
      PlaybackRecoveryEvent(
        sessionId: runtime.sessionId,
        stage: PlaybackRecoveryStage.preparing,
        message: '检测到 MPV 播放失败，正在恢复链接（${state.attempts}/2）…',
      ),
    );

    // 媒体失败后 MPV 可能自动跳到下一集。先定向结束旧进程并保存失败
    // 位置，确保后台刷新期间不会播放错误的列表项。
    await _stopRuntimeForRecovery(runtime);
    if (!identical(_recoveryStates[runtime.sessionId], state)) return true;

    final entryIndex = _failureEntryIndex(runtime, failure);
    final entry = runtime.entries[entryIndex];
    OpenListRecoveryResult preparation;
    try {
      preparation = await _linkRecoveryProvider.prepare(
        config: config,
        mediaUrl: entry.url,
        webDavUsername: runtime.username,
        webDavPassword: runtime.password,
        // 第一次允许直接重新取链；第二次仅在地址仍不可读时强制刷新存储，
        // 地址可读则按非链接失效停止恢复。
        forceStorageReload: state.attempts > 1,
      );
    } catch (_) {
      if (!identical(_recoveryStates[runtime.sessionId], state)) return true;
      state.recovering = false;
      _emitPlaybackRecovery(
        PlaybackRecoveryEvent(
          sessionId: runtime.sessionId,
          stage: PlaybackRecoveryStage.failed,
          message: '自动恢复服务发生异常，已保留继续播放记录',
        ),
      );
      return true;
    }
    if (!identical(_recoveryStates[runtime.sessionId], state)) return true;
    if (!preparation.success) {
      state.recovering = false;
      _emitPlaybackRecovery(
        PlaybackRecoveryEvent(
          sessionId: runtime.sessionId,
          stage: PlaybackRecoveryStage.failed,
          message: '自动恢复失败：${preparation.message}，已保留继续播放记录',
        ),
      );
      return true;
    }

    final rawPosition = failure.positionSeconds;
    final resumeSeconds = rawPosition == null || rawPosition < 0
        ? null
        : (rawPosition.floor() - 2).clamp(0, 1 << 31).toInt();
    try {
      final result = await launch(
        entries: runtime.entries,
        sessionId: runtime.sessionId,
        playlistStart: entryIndex,
        resumeSeconds: resumeSeconds,
        username: runtime.username,
        password: runtime.password,
        automaticRecovery: true,
      );
      if (!identical(_recoveryStates[runtime.sessionId], state)) {
        await terminateSession(runtime.sessionId);
        return true;
      }
      state.recovering = false;
      _emitPlaybackRecovery(
        PlaybackRecoveryEvent(
          sessionId: runtime.sessionId,
          stage: PlaybackRecoveryStage.relaunched,
          message: preparation.storageReloaded
              ? 'OpenList/AList 存储已刷新，播放器已从失败位置恢复'
              : '已重新获取播放链接，播放器已从失败位置恢复',
          launchResult: result,
        ),
      );
    } on AppException catch (error) {
      state.recovering = false;
      _emitPlaybackRecovery(
        PlaybackRecoveryEvent(
          sessionId: runtime.sessionId,
          stage: PlaybackRecoveryStage.failed,
          message: '链接已恢复，但重新启动播放器失败：${error.message}',
        ),
      );
    } catch (_) {
      state.recovering = false;
      _emitPlaybackRecovery(
        PlaybackRecoveryEvent(
          sessionId: runtime.sessionId,
          stage: PlaybackRecoveryStage.failed,
          message: '自动恢复过程中出现异常，已保留继续播放记录',
        ),
      );
    }
    return true;
  }

  Future<MpvPlaybackFailureRecord?> _readNextPlaybackFailure(
    _PlayerSessionRuntime runtime,
  ) async {
    final path = runtime.progressFilePath;
    if (path == null) return null;
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final lines = await file.readAsLines();
      var start = runtime.progressJournalLinesRead;
      if (start > lines.length) start = 0;
      runtime.progressJournalLinesRead = lines.length;
      MpvPlaybackFailureRecord? latest;
      for (var index = start; index < lines.length; index++) {
        latest = MpvPlaybackFailureRecord.tryParse(lines[index]) ?? latest;
      }
      return latest;
    } on FileSystemException {
      return null;
    }
  }

  int _failureEntryIndex(
    _PlayerSessionRuntime runtime,
    MpvPlaybackFailureRecord failure,
  ) {
    final pos = failure.playlistPos ?? runtime.currentPlaylistPos ?? 0;
    if (pos >= 0 && pos < runtime.entries.length) return pos;
    if (failure.path.isNotEmpty) {
      for (var index = 0; index < runtime.entries.length; index++) {
        if (_sameTrack(failure.path, runtime.entries[index].url)) return index;
      }
    }
    return 0;
  }

  Future<void> _stopRuntimeForRecovery(_PlayerSessionRuntime runtime) async {
    if (identical(_sessions[runtime.sessionId], runtime)) {
      _sessions.remove(runtime.sessionId);
      _cleanupCacheRuntime(runtime);
    }
    final pid = runtime.pid;
    if (pid != null && await _isProcessAlive(pid)) {
      final canForceTerminate =
          runtime.launchedHere || (runtime.isMpv && await _isMpvProcess(pid));
      if (canForceTerminate) {
        try {
          await Process.run(
            Platform.isWindows ? 'taskkill' : 'kill',
            Platform.isWindows
                ? ['/PID', '$pid', '/T', '/F']
                : ['-TERM', '$pid'],
          );
        } catch (_) {}
      }
    }
    try {
      await _syncProgress(runtime, runtime.entries);
    } catch (_) {
      // 失败位置已经包含在恢复事件中；进度同步异常不得阻断取链恢复。
    }
    await _deleteSessionArtifacts(runtime.sessionId);
  }

  void _emitPlaybackRecovery(PlaybackRecoveryEvent event) {
    try {
      onPlaybackRecovery?.call(event);
    } catch (_) {
      // 界面提示异常不影响恢复链路。
    }
  }

  /// 探测进程是否存活（Windows 用 tasklist 精确比对 PID）。
  ///
  /// PID 按行精确比对（`/FO CSV` 第二列为 PID），避免
  /// `stdout.contains(pid)` 子串误命中（如映像名含数字）。
  /// 非 Windows 分支为防御性保留（当前仅支持 Windows）。
  Future<bool> _isProcessAlive(int pid) async {
    try {
      final result = await Process.run(
        Platform.isWindows ? 'tasklist' : 'kill',
        Platform.isWindows
            ? ['/FI', 'PID eq $pid', '/NH', '/FO', 'CSV']
            : ['-0', '$pid'],
      );
      if (Platform.isWindows) {
        final out = result.stdout.toString();
        for (final line in out.split(RegExp(r'\r?\n'))) {
          if (line.trim().isEmpty) continue;
          final cols = line.split(',');
          if (cols.length >= 2) {
            final pidField = cols[1].trim().replaceAll(
              String.fromCharCodes([34]),
              '',
            );
            if (pidField == pid.toString()) return true;
          }
        }
        return false;
      }
      return result.exitCode == 0;
    } catch (_) {
      return true; // 查询失败时保守认为存活。
    }
  }

  /// 合并 Lua 逐媒体结果与 watch_later，写回播放进度库。
  Future<void> _syncProgress(
    _PlayerSessionRuntime runtime,
    List<MediaEntry> entries,
  ) async {
    final ps = _progressService;
    final dir = _watchLaterDir;
    if (ps == null || dir == null) return;
    const synchronizer = MpvPlaybackProgressSynchronizer();
    await synchronizer.sync(
      progressService: ps,
      watchLaterDirectory: dir,
      entries: entries,
      watchLaterUrls: runtime.watchLaterUrls,
      journalFile: runtime.progressFilePath == null
          ? null
          : File(runtime.progressFilePath!),
    );
  }

  Future<Directory> _ensureWatchLaterDir() async {
    final dir =
        _watchLaterDir ??
        Directory(
          p.join((await AppPaths.cacheDirectory()).path, 'mpv-watch-later'),
        );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _watchLaterDir = dir;
    return dir;
  }

  /// 脚本/播放列表文件存放目录（watch_later 目录或数据目录）。
  Future<Directory> _scriptBase() async =>
      _watchLaterDir ?? await AppPaths.cacheDirectory(); // 脚本/播放列表产物

  /// 恢复持久化会话的 PID/pipe 身份；应用重启后可继续独立探活和控制。
  Future<void> restoreSession({
    required String sessionId,
    required int? pid,
    String? ipcPipeName,
  }) async {
    if (_sessions.containsKey(sessionId)) return;
    final dataDir = await AppPaths.cacheDirectory(); // mpv 会话产物
    final runtime = _PlayerSessionRuntime(
      sessionId: sessionId,
      pid: pid,
      isMpv: ipcPipeName != null,
      statusFilePath: p.join(dataDir.path, sessionStatusFileName(sessionId)),
      commandFilePath: p.join(dataDir.path, sessionCommandFileName(sessionId)),
      progressFilePath: p.join(
        dataDir.path,
        sessionProgressFileName(sessionId),
      ),
      ipcPipeName: ipcPipeName,
      epoch: ++_runtimeEpoch,
    );
    _sessions[sessionId] = runtime;
    _lastSessionId = sessionId;
    if (pid != null && ipcPipeName != null && await _isProcessAlive(pid)) {
      runtime.aliveCache = true;
      runtime.aliveCacheAt = DateTime.now();
    }
  }

  /// 探测指定会话播放器是否仍在运行；不传 ID 时兼容最近会话。
  Future<bool> isPlayerRunning([String? sessionId]) async {
    final id = sessionId ?? _lastSessionId;
    final runtime = id == null ? null : _sessions[id];
    final pid = runtime?.pid;
    if (pid == null) return false;
    final now = DateTime.now();
    if (runtime!.aliveCacheAt != null &&
        now.difference(runtime.aliveCacheAt!) < const Duration(seconds: 2)) {
      return runtime.aliveCache ?? true;
    }
    final alive = await _isProcessAlive(pid);
    runtime.aliveCache = alive;
    runtime.aliveCacheAt = now;
    return alive;
  }

  /// 等待对应进程退出后的播放进度同步完成。
  ///
  /// UI 可能比后台退出监听更早发现进程消失；等待此 Future 后再判断
  /// 99% 完成状态，避免把刚播到片尾的会话误降级为“继续播放”。
  Future<void> waitForExitSync(
    String sessionId, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final future = _sessions[sessionId]?.exitSyncFuture;
    if (future == null) return;
    try {
      await future.timeout(timeout);
    } catch (_) {
      // 超时或同步失败时继续使用状态文件与已有进度，不阻塞下边栏。
    }
  }

  Future<void> sendPause([String? sessionId]) =>
      _sendPauseCmd(sessionId ?? _lastSessionId, true);

  Future<void> sendResume([String? sessionId]) =>
      _sendPauseCmd(sessionId ?? _lastSessionId, false);

  Future<void> _sendPauseCmd(String? sessionId, bool pause) async {
    if (sessionId == null) return;
    final runtime = _sessions[sessionId];
    final path = runtime?.commandFilePath;
    if (path != null) {
      await _writeCommandFile(path, pause ? 'pause' : 'resume');
    }
  }

  Future<void> _writeCommandFile(String path, String command) async {
    try {
      await File(path).writeAsString(command, flush: true);
    } catch (_) {
      // 命令发送失败（目录不可写等）静默。
    }
  }

  /// 终止并移除指定播放会话，只作用于该会话 PID。
  Future<void> terminateSession(String sessionId) async {
    _recoveryStates.remove(sessionId);
    final runtime = _sessions.remove(sessionId);
    if (runtime != null) {
      _cleanupCacheRuntime(runtime);
      final pid = runtime.pid;
      if (pid != null) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final canForceTerminate =
            runtime.launchedHere || (runtime.isMpv && await _isMpvProcess(pid));
        if (canForceTerminate && await _isProcessAlive(pid)) {
          try {
            await Process.run(
              Platform.isWindows ? 'taskkill' : 'kill',
              Platform.isWindows
                  ? ['/PID', '$pid', '/T', '/F']
                  : ['-TERM', '$pid'],
            );
          } catch (_) {}
        }
      }
    }
    await _deleteSessionArtifacts(sessionId);
    if (_lastSessionId == sessionId) {
      _lastSessionId = _sessions.isEmpty ? null : _sessions.keys.last;
    }
  }

  /// 重启恢复的 PID 可能已被系统复用；强制结束前确认它仍是 MPV。
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
        if (line.trim().isEmpty) continue;
        final columns = line.split(',');
        if (columns.length < 2) continue;
        final imageName = columns.first
            .replaceAll('"', '')
            .trim()
            .toLowerCase();
        final pidField = columns[1].replaceAll('"', '').trim();
        if (pidField == '$pid' && imageName.contains('mpv')) return true;
      }
    } catch (_) {
      // 无法确认进程身份时不执行强制结束。
    }
    return false;
  }

  /// 播放列表自然结束后释放会话控制资源，不额外终止已经退出/空闲的进程。
  void releaseSession(String sessionId) {
    _recoveryStates.remove(sessionId);
    final runtime = _sessions.remove(sessionId);
    if (runtime != null) _cleanupCacheRuntime(runtime);
    unawaited(_deleteSessionArtifacts(sessionId));
    if (_lastSessionId == sessionId) {
      _lastSessionId = _sessions.isEmpty ? null : _sessions.keys.last;
    }
  }

  void _cleanupCacheRuntime(_PlayerSessionRuntime runtime) {
    runtime.trackGeneration++;
    _cachePolicy?.stopMonitor(runtime.sessionId, clearSession: true);
    _authHeaders.remove(runtime.sessionId);
    _cacheIpcStates.remove(runtime.sessionId);
  }

  Future<void> _deleteSessionArtifacts(String sessionId) async {
    try {
      final dataDir = await AppPaths.cacheDirectory(); // mpv 会话产物
      final base = await _scriptBase();
      final paths = <String>[
        p.join(dataDir.path, sessionStatusFileName(sessionId)),
        p.join(dataDir.path, sessionCommandFileName(sessionId)),
        p.join(dataDir.path, sessionProgressFileName(sessionId)),
        ...MpvScripts.sessionArtifactNames(
          sessionId,
        ).map((name) => p.join(base.path, name)),
      ];
      for (final path in paths) {
        final file = File(path);
        if (await file.exists()) {
          try {
            await file.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  static String sessionStatusFileName(String sessionId) =>
      'mpv-current-${MpvScripts.safeSessionToken(sessionId)}.txt';

  static String sessionCommandFileName(String sessionId) =>
      'mpv-command-${MpvScripts.safeSessionToken(sessionId)}.txt';

  static String sessionProgressFileName(String sessionId) =>
      'mpv-progress-${MpvScripts.safeSessionToken(sessionId)}.jsonl';

  /// 清除 mpv 状态文件中残留的「已播完」标记（首行 `-1`），
  /// 供启动播放前调用；正常状态（首行非 -1）原样保留。
  ///
  /// 返回是否执行了删除。读取/删除失败静默（不影响播放，UI 侧另有
  /// mtime 新鲜度校验兜底）。
  @visibleForTesting
  static Future<bool> clearStaleFinishedMark(File statusFile) async {
    try {
      if (!await statusFile.exists()) return false;
      final lines = await statusFile.readAsLines();
      if (lines.isNotEmpty && lines.first.trim() == '-1') {
        await statusFile.delete();
        return true;
      }
    } catch (_) {
      // 读取/删除失败（占用/权限）静默。
    }
    return false;
  }

  // ── 多集续播（预写 watch_later） ────────────────────────────

  /// 把 [seconds] 写入 [url] 对应的 mpv watch_later 文件（仅更新/追加
  /// `start=` 行，保留文件中其他记录），使 mpv 加载时原生恢复续播。
  Future<void> _writeResumeStart(String url, int seconds) async {
    final dir = await _ensureWatchLaterDir();
    final file = File(p.join(dir.path, MpvWatchLaterSync.md5FileName(url)));

    var content = '';
    if (await file.exists()) {
      try {
        content = await file.readAsString();
      } on FileSystemException {
        content = '';
      }
    }

    final lines = content.split('\n');
    final out = <String>[];
    var replaced = false;
    for (final line in lines) {
      if (RegExp(r'^\s*start\s*=', caseSensitive: false).hasMatch(line)) {
        out.add('start=$seconds');
        replaced = true;
      } else {
        out.add(line);
      }
    }
    if (!replaced) {
      out.add('start=$seconds');
    }
    await file.writeAsString(out.join('\n'));
  }

  /// 清除指定 [url] 的 watch_later 文件（无续播进度/已看完时调用，
  /// 避免 mpv 从旧位置恢复）。
  ///
  /// 双通道删除：① MD5 文件名直删（mpv 默认命名）；② 目录扫描 +
  /// 首行注释匹配兜底（兼容 `--write-filename-in-watch-later-config`
  /// 的 sanitize 命名），确保残留片尾记录一定被清掉。
  Future<void> _clearWatchLater(String url) async {
    final dir = await _ensureWatchLaterDir();
    await const MpvWatchLaterSync().deleteRecord(dir, url);
  }
}
