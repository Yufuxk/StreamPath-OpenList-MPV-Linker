import 'dart:io';

import 'package:path/path.dart' as p;

import '../../data/models/media_entry.dart';
import '../../data/models/subtitle_item.dart';

/// mpv 注入文件生成器。
///
/// 生成并写入 mpv 播放所需的 Lua 脚本与 m3u 播放列表：
///  - 字幕：外挂字幕优先、播放列表逐集字幕注入；
///  - 字体：为本次播放绑定会话专属字体目录；
///  - 标题：m3u 的 EXTINF/EXTVLCOPT 与老版本标题兜底脚本；
///  - 状态：当前播放状态上报与命令执行脚本。
///
/// 所有文件写入 [base] 目录，返回文件路径供播放器启动参数引用。
class MpvScripts {
  MpvScripts._();

  // ── 外挂字体目录注入 ───────────────────────────────────────

  /// 在每个播放项加载前绑定本次会话的字体目录。
  ///
  /// `file-local-options` 保证播放列表切集时继续使用同一目录；旧版 MPV
  /// 不支持 `sub-fonts-dir` 时只跳过设置，不影响媒体和字幕加载。
  static Future<String> ensureFontDirectory(
    String fontDirectory,
    Directory base, {
    required String sessionId,
  }) async {
    final script =
        '''
-- StreamPath: bind the isolated external-font directory for this session.
local FONT_DIR = ${_luaQuote(fontDirectory)}
local OPTION = "sub-fonts-dir"
local _, option_error = mp.get_property(OPTION)
if option_error then return end

mp.add_hook("on_load", 5, function()
    mp.set_property("file-local-options/" .. OPTION, FONT_DIR)
end)
''';
    return _write(
      base,
      _sessionFileName('streampath-font-directory', 'lua', sessionId),
      script,
    );
  }

  // ── 单集外挂字幕注入 ───────────────────────────────────────

  /// 写入单集外挂字幕注入脚本。
  ///
  /// [autoSelect] 开启时注入并选中；关闭时仅添加轨道，不改变当前字幕。
  static Future<String> ensureSingleSubtitle(
    SubtitleItem subtitle,
    String Function(String) authUrl,
    Directory base, {
    required bool autoSelect,
    String? sessionId,
  }) async {
    final script =
        '''
-- StreamPath: 单集外挂字幕注入。
local URL = ${_luaQuote(authUrl(subtitle.url))}
local TITLE = ${_luaQuote(subtitle.name)}
local LANG = "${subtitle.language == SubtitleLanguage.chinese ? 'chi' : 'und'}"
local MODE = "${autoSelect ? 'select' : 'auto'}"
mp.register_event("file-loaded", function()
    local previous_sid = mp.get_property("sid", "no")
    mp.commandv("sub-add", URL, MODE, TITLE, LANG)
    if MODE == "auto" then
        mp.add_timeout(0, function()
            mp.set_property("sid", previous_sid)
        end)
    end
end)
''';
    return _write(
      base,
      _sessionFileName('streampath-single-subtitle', 'lua', sessionId),
      script,
    );
  }

  // ── 播放列表逐集字幕 ────────────────────────────────────────

  /// 写入播放列表逐集字幕脚本：每集按 `playlist-pos` 用 `sub-add`
  /// 注入各自字幕；是否自动选中由 [autoSelect] 控制。
  static Future<String> ensurePlaylistSubtitles(
    List<MediaEntry> entries,
    String Function(String) authUrl,
    Directory base, {
    required bool autoSelect,
    String? sessionId,
  }) async {
    final subs = <String>[];
    final titles = <String>[];
    final langs = <String>[];
    for (var i = 0; i < entries.length; i++) {
      final sub = entries[i].subtitle;
      if (sub == null) continue;
      subs.add('SUBS[$i] = ${_luaQuote(authUrl(sub.url))}');
      titles.add('TITLES[$i] = ${_luaQuote(sub.name)}');
      langs.add(
        'LANGS[$i] = "${sub.language == SubtitleLanguage.chinese ? 'chi' : 'und'}"',
      );
    }

    final script =
        '''
-- StreamPath: 播放列表逐集字幕注入。
local SUBS = {}
local TITLES = {}
local LANGS = {}
local MODE = "${autoSelect ? 'select' : 'auto'}"
${subs.join('\n')}
${titles.join('\n')}
${langs.join('\n')}
mp.register_event("file-loaded", function()
    local pos = mp.get_property_number("playlist-pos", -1)
    local url = SUBS[pos]
    if not url then return end
    local previous_sid = mp.get_property("sid", "no")
    mp.commandv("sub-add", url, MODE, TITLES[pos], LANGS[pos])
    if MODE == "auto" then
        mp.add_timeout(0, function()
            mp.set_property("sid", previous_sid)
        end)
    end
end)
''';
    return _write(
      base,
      _sessionFileName('streampath-playlist-subtitles', 'lua', sessionId),
      script,
    );
  }

  // ── 多集播放列表（m3u） ─────────────────────────────────────

  /// 写入多集 m3u 播放列表，每集三行：
  /// ```
  /// #EXTINF:0,<显示标题>                    ← 播放列表 UI 标题
  /// #EXTVLCOPT:force-media-title=<显示标题> ← 该集窗口标题（per-file）
  /// <直链 URL>                              ← 播放地址
  /// ```
  /// EXTINF 由 mpv 原生作为播放列表条目名，EXTVLCOPT 作为该条目的
  /// per-file 选项在切集时自动切换。
  static Future<String> ensurePlaylistM3u(
    List<MediaEntry> entries,
    String Function(String) authUrl,
    Directory base, {
    String? sessionId,
  }) async {
    final lines = <String>['#EXTM3U'];
    for (final e in entries) {
      // 标题来自服务器（文件/目录名），剥离控制字符防止
      // CR/LF 注入额外 m3u 行（#EXTINF/#EXTVLCOPT 是逐行解析的）。
      final title = _sanitizeTitle(e.title ?? fallbackTitleFromUrl(e.url));
      lines.add('#EXTINF:0,$title');
      lines.add('#EXTVLCOPT:force-media-title=$title');
      // URL 行同样剥离控制字符（防止服务器返回的 URL 注入额外行）。
      lines.add(_sanitizeTitle(authUrl(e.url)));
    }
    final file = File(
      p.join(
        base.path,
        _sessionFileName('streampath-playlist', 'm3u', sessionId),
      ),
    );
    await file.parent.create(recursive: true);
    await file.writeAsString('${lines.join('\n')}\n', flush: true);
    return file.path;
  }

  // ── 播放列表标题兜底脚本 ────────────────────────────────────

  /// 写入播放列表标题兜底脚本：每集 `file-loaded` 时按 `playlist-pos`
  /// 设置 `force-media-title`（为不支持 EXTVLCOPT 的旧版 mpv 提供标题）。
  static Future<String> ensureTitles(
    List<MediaEntry> entries,
    Directory base, {
    String? sessionId,
  }) async {
    final titles = <String>[];
    for (var i = 0; i < entries.length; i++) {
      final title = entries[i].title ?? fallbackTitleFromUrl(entries[i].url);
      titles.add('TITLES[$i] = ${_luaQuote(title)}');
    }

    final script =
        '''
-- StreamPath: 播放列表标题兜底脚本。
local TITLES = {}
${titles.join('\n')}
mp.register_event("file-loaded", function()
    local pos = mp.get_property_number("playlist-pos", -1)
    local title = TITLES[pos]
    if title then
        mp.set_property("force-media-title", title)
    end
end)
''';
    return _write(
      base,
      _sessionFileName('streampath-titles', 'lua', sessionId),
      script,
    );
  }

  // ── 当前播放状态上报 ────────────────────────────────────────

  /// 写入当前播放状态上报脚本：
  ///  - `file-loaded` 与 `pause` 变化时，把 `playlist-pos`、当前文件
  ///    URL、暂停状态、当前位置和总时长（二十一行，含缓冲、前向水位
  ///    与蓝光菜单/edition 状态）
  ///    写入 [outFile]；
  ///  - 播放中每秒以及 MPV 退出前刷新状态，供直接关窗时判断完成度；
  ///  - 在 [progressFile] 追加逐媒体 JSONL 结果，明确区分完成、0 秒和
  ///    普通退出位置，避免 watch_later 缺失时旧进度残留；
  ///  - 轮询 [cmdFile] 命令文件，执行暂停/恢复；
  ///  - 播放列表播完进入 idle 时写 `-1` 标记（仅限已加载过文件的场景，
  ///    避免启动瞬间误写）。
  static Future<String> ensureCurrent(
    String outFile,
    String cmdFile,
    Directory base, {
    String? sessionId,
    String? progressFile,
    String? launchEpoch,
    String? reportedPath,
  }) async {
    final resolvedProgressFile = progressFile ?? '$outFile.progress.jsonl';
    final script =
        '''
-- StreamPath: 当前播放状态上报 + 命令执行。
-- OUT 二十一行：playlist-pos / path / paused(1|0) / time-pos / duration
--           / buffering(0-100) / net-speed(B/s)
--           / cache-idle(1|0|-1) / 诊断行（speed_src|speed|idle_src|idle_raw）
--           / paused-for-cache / bof-cached / eof-cached / resolution
--           / seeking / playback-restart 序号 / demuxer-cache-duration
--           / fw-bytes / total-bytes / disc-menu-active / current-edition
--           / editions
local utils = require "mp.utils"
local OUT = ${_luaQuote(outFile)}
local CMD = ${_luaQuote(cmdFile)}
local PROGRESS = ${_luaQuote(resolvedProgressFile)}
local EPOCH = ${_luaQuote(launchEpoch ?? '')}
local REPORTED_PATH = ${_luaQuote(reportedPath ?? '')}

local has_loaded = false
local last_playlist_pos = -1
local last_path = ""
local last_time_pos = -1
local last_duration = -1
local last_entry_recorded = false
local entry_started = false
local checkpoint_armed_at = -1
local temporary_checkpoint_active = false
local temporary_clear_written = false
local healthy_since = nil
local was_stalling = false
local restart_serial = 0

local function append_progress(outcome, reason, file_error)
    -- 初次打开即失败时 path 在部分 mpv 版本中可能为空，但 playlist-pos
    -- 仍足以映射原播放项，不能因此丢失恢复事件。
    if last_playlist_pos < 0 and last_path == "" then return end
    local record = {
        epoch = EPOCH,
        outcome = outcome,
        playlist_pos = last_playlist_pos,
        path = last_path,
    }
    if last_time_pos >= 0 then record["position"] = last_time_pos end
    if last_duration > 0 then record["duration"] = last_duration end
    if reason ~= nil and reason ~= "" then record["reason"] = reason end
    if file_error ~= nil and file_error ~= "" then
        record["file_error"] = file_error
    end
    local ok, line = pcall(utils.format_json, record)
    if not ok or line == nil then return end
    local f = io.open(PROGRESS, "a")
    if f then
        f:write(line .. "\\n")
        f:flush()
        f:close()
    end
end

local function clear_temporary_checkpoint()
    if temporary_clear_written and not temporary_checkpoint_active then return end
    append_progress("temporary_cleared", nil, nil)
    temporary_checkpoint_active = false
    temporary_clear_written = true
    healthy_since = nil
    was_stalling = false
end

local function update_temporary_checkpoint()
    if not has_loaded or mp.get_property_bool("idle-active", false) then return end
    if last_duration > 0 and last_time_pos >= 0 and
        last_time_pos / last_duration >= 0.99 then
        clear_temporary_checkpoint()
        return
    end
    local now = mp.get_time()
    if checkpoint_armed_at < 0 or now < checkpoint_armed_at then return end
    local paused_for_cache = mp.get_property("paused-for-cache", nil)
    local stalling = paused_for_cache == "yes"
    if paused_for_cache == nil then
        local buffering = mp.get_property_number("cache-buffering-state", -1)
        local cache_idle = mp.get_property("demuxer-cache-idle", nil)
        if cache_idle == nil then cache_idle = mp.get_property("cache-idle", nil) end
        stalling = buffering > 0 and buffering < 100 and cache_idle ~= "yes"
    end
    if stalling then
        healthy_since = nil
        if not was_stalling and last_time_pos > 0 then
            append_progress("temporary_checkpoint", nil, nil)
            temporary_checkpoint_active = true
            temporary_clear_written = false
        end
        was_stalling = true
        return
    end
    was_stalling = false
    if mp.get_property_bool("pause", false) then
        healthy_since = nil
        return
    end
    if healthy_since == nil then
        healthy_since = now
    elseif now - healthy_since >= 5 then
        clear_temporary_checkpoint()
    end
end

local function write_status(use_cached_progress, skip_diagnostics)
    local pos = mp.get_property_number("playlist-pos", -1)
    local path = REPORTED_PATH ~= "" and REPORTED_PATH or mp.get_property("path", "")
    local paused = mp.get_property_bool("pause", false)
    local time_pos = mp.get_property_number("time-pos", -1)
    local duration = mp.get_property_number("duration", -1)
    if use_cached_progress then
        if last_time_pos >= 0 then
            time_pos = last_time_pos
        end
        if duration <= 0 and last_duration > 0 then
            duration = last_duration
        end
    else
        if pos >= 0 then
            last_playlist_pos = pos
        end
        if path ~= "" then
            last_path = path
        end
        if time_pos >= 0 then
            last_time_pos = time_pos
        end
        if duration > 0 then
            last_duration = duration
        end
    end
    -- 播放中动态保护采样（第二阶段）：缓冲状态 / 实时下载速度。
    -- 旧版 mpv 或属性不可用时全部回落 -1，监控侧按「未知」降级处理。
    -- shutdown 阶段只保存前五行必要进度，不再同步读取 demuxer-cache-state；
    -- 网络源正在拆卸时该属性可能明显阻塞窗口关闭。
    -- paused-for-cache 是 mpv 因缓存不足暂停播放的真值；
    -- cache-buffering-state 仅作为进度展示，不能结合 idle 推断卡顿。
    -- mpv 0.41 使用 demuxer-cache-idle，旧版本使用 cache-idle。
    -- true 表示 EOF 或缓存当前无需继续读取；优先新名并回退旧名。
    local buffering = -1
    local paused_for_cache = -1
    local idle_raw = "skipped"
    local idle_src = "shutdown-fast"
    local cache_idle = -1
    local net_speed = -1
    local speed_src = "shutdown-fast"
    local bof_cached = -1
    local eof_cached = -1
    local resolution = ""
    local seeking = -1
    local cache_duration = -1
    local forward_cache_bytes = -1
    local total_cache_bytes = -1
    local disc_menu_active = -1
    local disc_menu_raw = mp.get_property("disc-menu-active", nil)
    if disc_menu_raw == "yes" then
        disc_menu_active = 1
    elseif disc_menu_raw == "no" then
        disc_menu_active = 0
    end
    local current_edition = mp.get_property_number("current-edition", -1)
    local editions = mp.get_property_number("editions", -1)
    if not skip_diagnostics then
        buffering = mp.get_property_number("cache-buffering-state", -1)
        local paused_for_cache_raw = mp.get_property("paused-for-cache", nil)
        if paused_for_cache_raw == "yes" then
            paused_for_cache = 1
        elseif paused_for_cache_raw == "no" then
            paused_for_cache = 0
        end
        idle_raw = mp.get_property("demuxer-cache-idle", nil)
        idle_src = "demuxer-cache-idle"
        if idle_raw == nil then
            idle_raw = mp.get_property("cache-idle", nil)
            idle_src = "cache-idle"
        end
        if idle_raw == "yes" then
            cache_idle = 1
        elseif idle_raw == "no" then
            cache_idle = 0
        end
    -- 网络读取速率（bytes/s）：
    -- 1) 首选 `cache-speed` 属性（mpv 0.38+）：与 demuxer-cache-state 的
    --    raw-input-rate 同源同值（demux_reader_state.bytes_per_second，
    --    EMA 平滑）。0.36 起 stream cache 已移除，它就是网络下载速率。
    -- 2) 回退读 demuxer-cache-state 顶层 `raw-input-rate`（0.41 结构
    --    无 reader 子表；该键仅当速率 >0 时存在）。
    -- 3) 旧版 mpv 两者皆无时回落 -1（网络判定降级为缓冲驱动）。
        local cstate = mp.get_property_native("demuxer-cache-state", nil)
        net_speed = mp.get_property_number("cache-speed", nil)
        speed_src = "cache-speed"
        if net_speed == nil then
            speed_src = "cstate"
            if type(cstate) == "table" then
                net_speed = cstate["raw-input-rate"]
                if net_speed == nil then
                    net_speed = cstate["reader"] and cstate["reader"]["bytes_per_second"] or nil
                    if net_speed ~= nil then speed_src = "cstate.reader" end
                end
            end
            if net_speed == nil then net_speed = -1 end
        end
        if type(cstate) == "table" then
            if cstate["bof-cached"] ~= nil then
                bof_cached = cstate["bof-cached"] and 1 or 0
            end
            if cstate["eof-cached"] ~= nil then
                eof_cached = cstate["eof-cached"] and 1 or 0
            end
            forward_cache_bytes = cstate["fw-bytes"] or -1
            total_cache_bytes = cstate["total-bytes"] or -1
        end
        local width = mp.get_property_number("width", -1)
        local height = mp.get_property_number("height", -1)
        if width > 0 and height > 0 then
            resolution = tostring(math.floor(width)) .. "x" .. tostring(math.floor(height))
        end
        seeking = mp.get_property_bool("seeking", false) and 1 or 0
        cache_duration = mp.get_property_number("demuxer-cache-duration", -1)
    end
    local f = io.open(OUT, "w")
    if f then
        -- 第 9 行：诊断行（speed_src|speed|idle_src|idle_raw），供排查
        -- net-speed / cache-idle 缺失。
        f:write(tostring(pos) .. "\\n" .. tostring(path) .. "\\n" ..
            (paused and "1" or "0") .. "\\n" .. tostring(time_pos) .. "\\n" .. tostring(duration) ..
            "\\n" .. tostring(buffering) .. "\\n" .. tostring(net_speed) ..
            "\\n" .. tostring(cache_idle) .. "\\n" .. speed_src .. "|" .. tostring(net_speed) ..
            "|" .. idle_src .. "|" .. tostring(idle_raw) ..
            "\\n" .. tostring(paused_for_cache) .. "\\n" .. tostring(bof_cached) ..
            "\\n" .. tostring(eof_cached) .. "\\n" .. resolution ..
            "\\n" .. tostring(seeking) .. "\\n" .. tostring(restart_serial) ..
            "\\n" .. tostring(cache_duration) ..
            "\\n" .. tostring(forward_cache_bytes) ..
            "\\n" .. tostring(total_cache_bytes) ..
            "\\n" .. tostring(disc_menu_active) ..
            "\\n" .. tostring(current_edition) ..
            "\\n" .. tostring(editions))
        f:close()
    end
end

mp.register_event("start-file", function()
    -- 当前曲目不得继承上一集缓存的时长/进度。
    has_loaded = false
    entry_started = true
    last_playlist_pos = -1
    last_path = ""
    last_time_pos = -1
    last_duration = -1
    last_entry_recorded = false
    checkpoint_armed_at = -1
    temporary_checkpoint_active = false
    temporary_clear_written = false
    healthy_since = nil
    was_stalling = false
    restart_serial = 0
    local pos = mp.get_property_number("playlist-pos", -1)
    local path = REPORTED_PATH ~= "" and REPORTED_PATH or mp.get_property("path", "")
    if pos >= 0 then last_playlist_pos = pos end
    if path ~= "" then last_path = path end
end)
mp.register_event("file-loaded", function()
    has_loaded = true
    entry_started = true
    -- 起播阶段的瞬时缓冲不建立临时播放点；稳定窗口结束后才启用。
    checkpoint_armed_at = mp.get_time() + 5
    write_status(false, false)
end)
mp.observe_property("pause", "bool", function()
    write_status(false, false)
end)
mp.observe_property("paused-for-cache", "bool", function()
    if has_loaded then
        write_status(false, false)
        update_temporary_checkpoint()
    end
end)
mp.observe_property("seeking", "bool", function()
    if has_loaded then
        write_status(false, false)
    end
end)
-- 初次起播与 seek 完成后立即采样；尤其要及时保留用户主动跳回 0 秒。
mp.register_event("playback-restart", function()
    if has_loaded and not mp.get_property_bool("idle-active", false) then
        restart_serial = restart_serial + 1
        write_status(false, false)
    end
end)
mp.register_event("end-file", function(event)
    if not entry_started or last_entry_recorded then return end
    local reason = event and event["reason"] or "unknown"
    -- Lua 旧版把错误放在 error，新版使用 file_error；同时读取以兼容
    -- mpv 0.34～0.41+。不解析终端文案，不依赖特定 FFmpeg 日志格式。
    local file_error = event and (event["file_error"] or event["error"]) or nil
    append_progress(reason == "eof" and "completed" or "position", reason, file_error)
    last_entry_recorded = true
end)
mp.register_event("shutdown", function()
    if has_loaded and not last_entry_recorded then
        append_progress("position", "shutdown", nil)
        last_entry_recorded = true
    end
    write_status(true, true)
end)

-- 定期刷新播放进度；idle 时保留专门的 -1 完成标记。
mp.add_periodic_timer(1.0, function()
    if has_loaded and not mp.get_property_bool("idle-active", false) then
        write_status(false, false)
        update_temporary_checkpoint()
    end
end)

-- 命令轮询：执行软件写入的 pause/resume 命令。
mp.add_periodic_timer(0.5, function()
    local f = io.open(CMD, "r")
    if f then
        local cmd = f:read("*a") or ""
        f:close()
        os.remove(CMD)
        if cmd:find("pause") then
            mp.set_property_bool("pause", true)
        elseif cmd:find("resume") then
            mp.set_property_bool("pause", false)
        end
    end
end)

-- 播放列表播完（idle）时写 -1 标记；仅当已加载过文件时写入。
-- 播放中短暂 idle（缓冲/切集间隙）不写：延迟确认仍处于 idle 才写，
-- 避免 UI 误清「继续播放」历史导致下边栏闪烁。
local idle_timer = nil
mp.observe_property("idle-active", "bool", function(name, val)
    if idle_timer then
        idle_timer:kill()
        idle_timer = nil
    end
    if val and has_loaded then
        idle_timer = mp.add_timeout(1.0, function()
            idle_timer = nil
            if mp.get_property_bool("idle-active") then
                local f = io.open(OUT, "w")
                if f then
                    f:write("-1\\n" .. tostring(last_playlist_pos) .. "\\n" .. EPOCH)
                    f:close()
                end
            end
        end)
    end
end)
''';
    return _write(
      base,
      _sessionFileName('streampath-current', 'lua', sessionId),
      script,
    );
  }

  // ── 工具 ───────────────────────────────────────────────────

  /// 从 URL 提取末段文件名作为标题（`pathSegments` 已 percent 解码）。
  static String fallbackTitleFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.pathSegments.isEmpty) return url;
    final last = uri.pathSegments.last;
    return last.isEmpty ? url : last;
  }

  /// Lua 字符串字面量转义。
  static String _luaQuote(String s) =>
      '"${s.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\n', '\\n').replaceAll('\r', '\\r')}"';

  /// 剥离控制字符（标题写入 m3u 的 #EXTINF/#EXTVLCOPT 行，
  /// 逐行解析，控制字符可注入额外行）。
  static String _sanitizeTitle(String title) =>
      title.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ');

  /// 会话安全文件名；未传 [sessionId] 时保持旧文件名兼容。
  static String _sessionFileName(
    String baseName,
    String extension,
    String? sessionId,
  ) {
    if (sessionId == null || sessionId.isEmpty) {
      return '$baseName.$extension';
    }
    return '$baseName-${safeSessionToken(sessionId)}.$extension';
  }

  /// 将会话 ID 转成可安全用于文件名的稳定片段。
  static String safeSessionToken(String sessionId) =>
      sessionId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');

  /// 一个会话生成的全部临时脚本/播放列表文件名。
  static List<String> sessionArtifactNames(String sessionId) {
    final id = safeSessionToken(sessionId);
    return [
      'streampath-single-subtitle-$id.lua',
      'streampath-playlist-subtitles-$id.lua',
      'streampath-font-directory-$id.lua',
      'streampath-playlist-$id.m3u',
      'streampath-titles-$id.lua',
      'streampath-current-$id.lua',
    ];
  }

  /// 写入脚本文件（父目录自动创建）。
  static Future<String> _write(
    Directory base,
    String name,
    String content,
  ) async {
    final file = File(p.join(base.path, name));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
    return file.path;
  }
}
