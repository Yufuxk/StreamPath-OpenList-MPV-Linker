import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../../core/constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/app_paths.dart';
import '../../core/utils/url_utils.dart';
import '../../data/local/stream_path_config_store.dart';
import '../../data/local/playback_progress_db.dart';
import '../../data/models/media_entry.dart';
import '../../data/models/player_config.dart';
import 'mpv_scripts.dart';
import 'mpv_watch_later_sync.dart';

/// 播放器启动结果（供 UI 诊断展示实际参数）。
class PlayerLaunchResult {
  const PlayerLaunchResult({
    required this.process,
    required this.args,
    required this.sessionId,
    this.ipcPipeName,
    this.statusFilePath,
    this.commandFilePath,
  });

  final Process process;
  final List<String> args;
  final String sessionId;
  final String? ipcPipeName;
  final String? statusFilePath;
  final String? commandFilePath;
}

class _PlayerSessionRuntime {
  _PlayerSessionRuntime({
    required this.sessionId,
    required this.pid,
    required this.isMpv,
    this.launchedHere = false,
    this.statusFilePath,
    this.commandFilePath,
  });

  final String sessionId;
  final int? pid;
  final bool isMpv;
  final bool launchedHere;
  final String? statusFilePath;
  final String? commandFilePath;

  bool? aliveCache;
  DateTime? aliveCacheAt;
  Future<void>? exitSyncFuture;
}

/// 外部播放器联动服务。
///
/// 职责：
///  1. 读取 [StreamPathConfigStore] 中的播放器配置，展开参数模板
///     （`{url}`/`{subfile}`/`{start}` 占位符）；
///  2. 认证注入：mpv 走 `--http-header-fields`，其他播放器 URL 内嵌凭据；
///  3. 自动切集：多集经 m3u 播放列表 + `--playlist-start` 指定起点，
///     每集字幕由注入的 Lua 脚本按 `playlist-pos` 用 `sub-add` 添加，
///     是否自动选中由独立配置控制（脚本生成见 [MpvScripts]）；
///  4. 进度写回：附加 `--save-position-on-quit --watch-later-directory`，
///     退出后按 URL 的 MD5 直查 watch_later 文件并把每集位置与时长
///     写回 SQLite；
///  5. 续播：多集预写起点集 watch_later 由 mpv 原生恢复，单集走
///     `--start` 模板参数；无进度时清除旧记录并禁用恢复；
///  6. 完整错误捕获：配置缺失 / 可执行文件不存在 / 启动失败。
class ExternalPlayerService {
  ExternalPlayerService({
    required StreamPathConfigStore configStore,
    this._progressService,
    this._watchLaterDir,
  }) : _configStore = configStore; // ignore: prefer_initializing_formals

  final StreamPathConfigStore _configStore;

  final PlaybackProgressService? _progressService;

  /// watch_later 目录；null 时使用「数据目录/mpv-watch-later」。
  Directory? _watchLaterDir;

  final Map<String, _PlayerSessionRuntime> _sessions = {};
  int _launchSequence = 0;
  String? _lastSessionId;

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
  }) async {
    if (entries.isEmpty) {
      throw AppException.config('播放列表为空，无法启动播放器');
    }
    if (playlistStart < 0 || playlistStart >= entries.length) {
      playlistStart = 0;
    }
    if (entries.isEmpty) {
      throw AppException.config('播放列表为空，无法启动播放器');
    }
    final config = await _configStore.loadPlayer();
    final launchNumber = ++_launchSequence;
    final resolvedSessionId = sessionId ?? 'session_$launchNumber';
    final assetSessionId = sessionId;

    final existing = _sessions[resolvedSessionId];
    if (existing != null && await isPlayerRunning(resolvedSessionId)) {
      throw AppException.process('该播放会话仍在运行，请先关闭或删除后再继续');
    }
    if (existing != null) {
      _sessions.remove(resolvedSessionId);
    }

    // ── 1. 配置校验 ───────────────────────────────────────────
    if (config.executable.trim().isEmpty) {
      throw AppException.config('未配置播放器路径，请先在「设置」中配置');
    }

    // ── 2. 认证注入（mpv 走 header；其他播放器 URL 内嵌） ───────
    final isMpv = config.executable.toLowerCase().contains('mpv');
    final authHeader = (username != null && username.isNotEmpty)
        ? 'Basic ${base64Encode(utf8.encode('$username:${password ?? ''}'))}'
        : null;

    String authUrl(String url) => (!isMpv && authHeader != null)
        ? embedCredentials(url, username!, password ?? '')
        : url;

    final startSec = config.resumeEnabled ? resumeSeconds : null;
    final subtitleInjectionEnabled = config.subtitleInjectionEnabled;
    final subtitleAutoSelectEnabled =
        subtitleInjectionEnabled && config.subtitleAutoSelectEnabled;

    // ── 3. 组装参数 ───────────────────────────────────────────
    final listMode = isMpv && entries.length > 1;
    // 每次启动使用唯一 named pipe，作为会话身份与未来 IPC 扩展入口。
    final ipcPipe = isMpv ? '${r'\\.\pipe\mpvsocket_'}$launchNumber' : null;
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
            authHeader: authHeader,
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

    // mpv 增强：认证 header（单集模式未注入时）+ 进度写回参数。
    if (isMpv) {
      if (authHeader != null && !args.contains('--http-header-fields')) {
        args.add('--http-header-fields=Authorization: $authHeader');
      }
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
        final title =
            entries.first.title ??
            MpvScripts.fallbackTitleFromUrl(entries.first.url);
        if (title.isNotEmpty) {
          args.add('--force-media-title=$title');
        }
      }
      if (config.resumeEnabled) {
        final dir = await _ensureWatchLaterDir();
        args.addAll([
          '--save-position-on-quit',
          '--watch-later-directory=${dir.path}',
          // watch_later 文件首行写入 URL 注释，便于按 URL 精确定位。
          '--write-filename-in-watch-later-config',
        ]);
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
        final dataDir = await AppPaths.dataDirectory();
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
        // 启动前清除残留的「已播完」标记（首行 -1），避免 mpv 加载
        // 文件期间 UI 轮询误读旧状态。
        await clearStaleFinishedMark(File(currentPath));
        args.add(
          '--script=${await MpvScripts.ensureCurrent(currentPath, commandPath, await _scriptBase(), sessionId: assetSessionId)}',
        );
      }
      // 多集续播：`--start` 是全局选项（作用于每一集），因此改为
      // 预写播放起点集的 watch_later 文件，由 mpv 原生恢复；后续集
      // 由 mpv 自身的 watch_later 机制接管。无续播进度（含已看完）
      // 时：清除起点集旧记录并禁用恢复，保证从头播放。
      if (config.resumeEnabled) {
        final startEntry = entries[playlistStart];
        if (listMode && startSec != null) {
          await _writeResumeStart(startEntry.url, startSec);
        } else if (startSec == null) {
          await _clearWatchLater(startEntry.url);
          args.add('--no-resume-playback');
          args.add('--start=0');
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

    // ── 5. 注册独立会话并监听退出 ─────────────────────────────
    final dataDir = isMpv ? await AppPaths.dataDirectory() : null;
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
          )
          ..aliveCache = true
          ..aliveCacheAt = DateTime.now();
    _sessions[resolvedSessionId] = runtime;
    _lastSessionId = resolvedSessionId;
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
    String? authHeader,
    required String playlistPath,
    int playlistStart = 0,
  }) {
    return _buildListArgs(
      config: config,
      authHeader: authHeader,
      playlistPath: playlistPath,
      playlistStart: playlistStart,
    );
  }

  List<String> _buildListArgs({
    required PlayerConfig config,
    required String? authHeader,
    required String playlistPath,
    required int playlistStart,
  }) {
    final args = <String>[];

    // 认证 header（mpv 全局，仅注入一次）。
    if (authHeader != null) {
      args.add('--http-header-fields=Authorization: $authHeader');
    }
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
  /// 进程消失后执行进度同步（watch_later → 进度库）。
  Future<void> _watchExitAndSync(
    _PlayerSessionRuntime runtime,
    Process process,
    List<MediaEntry> entries, {
    required bool syncProgress,
  }) async {
    final pid = process.pid;
    while (await _isProcessAlive(pid)) {
      await Future.delayed(const Duration(seconds: 2));
    }
    // 只更新仍指向本 runtime 的会话；同 ID 已重新启动时不干预新进程。
    if (identical(_sessions[runtime.sessionId], runtime)) {
      runtime.aliveCache = false;
      runtime.aliveCacheAt = DateTime.now();
    }
    if (syncProgress) {
      try {
        await _syncProgress(entries);
      } catch (e) {
        // ignore: avoid_print
        print('同步播放进度失败: $e');
      }
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

  /// 扫描 mpv watch_later 并写回各集播放进度（失败静默，不打扰用户）。
  Future<void> _syncProgress(List<MediaEntry> entries) async {
    final ps = _progressService;
    final dir = _watchLaterDir;
    if (ps == null || dir == null) return;

    const sync = MpvWatchLaterSync();
    for (final e in entries) {
      final start = await sync.readStartSeconds(dir, e.url);
      if (start == null) continue;
      // 同时读取时长并入库：供「已看完（片尾位置）」判定使用，
      // 避免把片尾位置当作续播点导致 mpv 秒切下一集。
      final duration = await sync.readDurationSeconds(dir, e.url);
      // 存储键使用干净 URL（无内嵌凭据），与查询侧保持一致。
      await ps.saveProgress(
        url: stripUserInfo(e.url),
        positionMs: (start * 1000).round(),
        durationMs: duration == null ? null : (duration * 1000).round(),
      );
    }
  }

  Future<Directory> _ensureWatchLaterDir() async {
    final dir =
        _watchLaterDir ??
        Directory(
          p.join((await AppPaths.dataDirectory()).path, 'mpv-watch-later'),
        );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _watchLaterDir = dir;
    return dir;
  }

  /// 脚本/播放列表文件存放目录（watch_later 目录或数据目录）。
  Future<Directory> _scriptBase() async =>
      _watchLaterDir ?? await AppPaths.dataDirectory();

  /// 恢复持久化会话的 PID/pipe 身份；应用重启后可继续独立探活和控制。
  Future<void> restoreSession({
    required String sessionId,
    required int? pid,
    String? ipcPipeName,
  }) async {
    if (_sessions.containsKey(sessionId)) return;
    final dataDir = await AppPaths.dataDirectory();
    final runtime = _PlayerSessionRuntime(
      sessionId: sessionId,
      pid: pid,
      isMpv: ipcPipeName != null,
      statusFilePath: p.join(dataDir.path, sessionStatusFileName(sessionId)),
      commandFilePath: p.join(dataDir.path, sessionCommandFileName(sessionId)),
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

  /// 等待对应进程退出后的 watch_later 进度同步完成。
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
    final runtime = _sessions.remove(sessionId);
    if (runtime != null) {
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
    _sessions.remove(sessionId);
    unawaited(_deleteSessionArtifacts(sessionId));
    if (_lastSessionId == sessionId) {
      _lastSessionId = _sessions.isEmpty ? null : _sessions.keys.last;
    }
  }

  Future<void> _deleteSessionArtifacts(String sessionId) async {
    try {
      final dataDir = await AppPaths.dataDirectory();
      final base = await _scriptBase();
      final paths = <String>[
        p.join(dataDir.path, sessionStatusFileName(sessionId)),
        p.join(dataDir.path, sessionCommandFileName(sessionId)),
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
    if (!dir.existsSync()) return;

    // ① MD5 文件名直删。
    final md5File = File(p.join(dir.path, MpvWatchLaterSync.md5FileName(url)));
    try {
      if (await md5File.exists()) {
        await md5File.delete();
      }
    } on FileSystemException {
      // 继续走扫描兜底。
    }

    // ② 目录扫描 + 注释行匹配兜底删除。
    try {
      for (final f in dir.listSync().whereType<File>()) {
        final String content;
        try {
          content = await f.readAsString();
        } on FileSystemException {
          continue;
        }
        final referenced = content.split('\n').any((line) {
          final trimmed = line.trim();
          if (!trimmed.startsWith('#')) return false;
          final ref = trimmed.substring(1).trim();
          final unquoted =
              ref.length >= 2 &&
                  ((ref.startsWith('"') && ref.endsWith('"')) ||
                      (ref.startsWith("'") && ref.endsWith("'")))
              ? ref.substring(1, ref.length - 1)
              : ref;
          return unquoted == url;
        });
        if (referenced) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    } on FileSystemException {
      // 目录不存在/不可读：忽略。
    }
  }
}
