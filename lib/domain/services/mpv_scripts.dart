import 'dart:io';

import 'package:path/path.dart' as p;

import '../../data/models/media_entry.dart';
import '../../data/models/subtitle_item.dart';

/// mpv 注入文件生成器。
///
/// 生成并写入 mpv 播放所需的 Lua 脚本与 m3u 播放列表：
///  - 字幕：外挂字幕优先、播放列表逐集字幕注入；
///  - 标题：m3u 的 EXTINF/EXTVLCOPT 与老版本标题兜底脚本；
///  - 状态：当前播放状态上报与命令执行脚本。
///
/// 所有文件写入 [base] 目录，返回文件路径供播放器启动参数引用。
class MpvScripts {
  MpvScripts._();

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
      final title = e.title ?? fallbackTitleFromUrl(e.url);
      lines.add('#EXTINF:0,$title');
      lines.add('#EXTVLCOPT:force-media-title=$title');
      lines.add(authUrl(e.url));
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
  ///    URL、暂停状态、当前位置和总时长（五行）写入 [outFile]；
  ///  - 播放中每秒以及 MPV 退出前刷新状态，供直接关窗时判断完成度；
  ///  - 轮询 [cmdFile] 命令文件，执行暂停/恢复；
  ///  - 播放列表播完进入 idle 时写 `-1` 标记（仅限已加载过文件的场景，
  ///    避免启动瞬间误写）。
  static Future<String> ensureCurrent(
    String outFile,
    String cmdFile,
    Directory base, {
    String? sessionId,
  }) async {
    final script =
        '''
-- StreamPath: 当前播放状态上报 + 命令执行。
-- OUT 五行：playlist-pos / path / paused(1|0) / time-pos / duration
local OUT = ${_luaQuote(outFile)}
local CMD = ${_luaQuote(cmdFile)}

local has_loaded = false
local last_time_pos = -1
local last_duration = -1

local function write_status(use_cached_progress)
    local pos = mp.get_property_number("playlist-pos", -1)
    local path = mp.get_property("path", "")
    local paused = mp.get_property_bool("pause", false)
    local time_pos = mp.get_property_number("time-pos", -1)
    local duration = mp.get_property_number("duration", -1)
    if use_cached_progress then
        if time_pos <= 0 and last_time_pos >= 0 then
            time_pos = last_time_pos
        end
        if duration <= 0 and last_duration > 0 then
            duration = last_duration
        end
    else
        if time_pos >= 0 then
            last_time_pos = time_pos
        end
        if duration > 0 then
            last_duration = duration
        end
    end
    local f = io.open(OUT, "w")
    if f then
        f:write(tostring(pos) .. "\\n" .. tostring(path) .. "\\n" ..
            (paused and "1" or "0") .. "\\n" .. tostring(time_pos) .. "\\n" .. tostring(duration))
        f:close()
    end
end

mp.register_event("file-loaded", function()
    has_loaded = true
    write_status(false)
end)
mp.observe_property("pause", "bool", function()
    write_status(false)
end)
mp.register_event("shutdown", function()
    write_status(true)
end)

-- 定期刷新播放进度；idle 时保留专门的 -1 完成标记。
mp.add_periodic_timer(1.0, function()
    if has_loaded and not mp.get_property_bool("idle-active", false) then
        write_status(false)
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
                    f:write("-1\\n\\n")
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
      '"${s.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';

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
