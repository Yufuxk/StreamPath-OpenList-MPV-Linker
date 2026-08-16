import 'dart:io';

import 'package:path/path.dart' as p;

import '../../data/models/audio_media_entry.dart';

/// 音频 MPV 会话资源生成器，与视频脚本保持文件和运行时隔离。
class AudioMpvScripts {
  AudioMpvScripts._();

  /// 生成带自定义曲名的 UTF-8 M3U8 播放列表。
  static Future<String> ensurePlaylistM3u8(
    List<AudioMediaEntry> entries,
    String Function(String) authUrl,
    Directory base, {
    required String sessionId,
  }) async {
    final lines = <String>['#EXTM3U'];
    for (final entry in entries) {
      final title = _sanitize(entry.title);
      lines
        ..add('#EXTINF:-1,$title')
        ..add('#EXTVLCOPT:force-media-title=$title')
        ..add(_sanitize(authUrl(entry.url)));
    }
    return _write(
      base,
      'streampath-audio-playlist-${safeSessionToken(sessionId)}.m3u8',
      '${lines.join('\n')}\n',
    );
  }

  /// 每首曲目加载后按设置注入 LRC，并注入外挂封面和自定义曲名。
  static Future<String> ensureCompanions(
    List<AudioMediaEntry> entries,
    String Function(String) authUrl,
    Directory base, {
    required String sessionId,
    required bool lyricsInjectionEnabled,
    required bool lyricsAutoSelectEnabled,
  }) async {
    final titles = <String>[];
    final lyrics = <String>[];
    final lyricTitles = <String>[];
    final covers = <String>[];
    final coverTitles = <String>[];
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      titles.add('TITLES[$index] = ${_luaQuote(entry.title)}');
      final lyric = entry.lyrics;
      if (lyricsInjectionEnabled && lyric != null) {
        lyrics.add('LYRICS[$index] = ${_luaQuote(authUrl(lyric.url))}');
        lyricTitles.add('LYRIC_TITLES[$index] = ${_luaQuote(lyric.name)}');
      }
      final cover = entry.coverArt;
      if (cover != null) {
        covers.add('COVERS[$index] = ${_luaQuote(authUrl(cover.url))}');
        coverTitles.add('COVER_TITLES[$index] = ${_luaQuote(cover.name)}');
      }
    }
    final lyricSetup = lyricsInjectionEnabled
        ? '''
local LYRICS = {}
local LYRIC_TITLES = {}
local LYRIC_MODE = ${_luaQuote(lyricsAutoSelectEnabled ? 'select' : 'auto')}
${lyrics.join('\n')}
${lyricTitles.join('\n')}
'''
        : '';
    final lyricHandler = lyricsInjectionEnabled
        ? '''
    local lyric = LYRICS[pos]
    if lyric then
        local previous_sid = mp.get_property("sid", "no")
        mp.commandv("sub-add", lyric, LYRIC_MODE, LYRIC_TITLES[pos], "und")
        if LYRIC_MODE == "auto" then
            mp.add_timeout(0, function()
                mp.set_property("sid", previous_sid)
            end)
        end
    end
'''
        : '';
    final script =
        '''
-- StreamPath: 音频曲名、外挂封面与可选 LRC 逐曲目注入。
local TITLES = {}
local COVERS = {}
local COVER_TITLES = {}
${titles.join('\n')}
${covers.join('\n')}
${coverTitles.join('\n')}
$lyricSetup

mp.register_event("file-loaded", function()
    local pos = mp.get_property_number("playlist-pos", -1)
    local title = TITLES[pos]
    if title then mp.set_property("force-media-title", title) end

$lyricHandler

    local cover = COVERS[pos]
    if cover then
        -- 没有内嵌封面时直接选中外挂封面；已有内嵌封面时保持
        -- audio-display=embedded-first，只把外挂封面加入备选轨道。
        local cover_mode = mp.get_property("vid", "no") == "no" and "select" or "auto"
        mp.commandv("video-add", cover, cover_mode, COVER_TITLES[pos], "und", "yes")
    end
end)
''';
    return _write(
      base,
      'streampath-audio-companions-${safeSessionToken(sessionId)}.lua',
      script,
    );
  }

  /// 生成音频会话的五行状态、命令和逐曲目进度脚本。
  ///
  /// 该脚本不读取或修改任何缓存属性；前五行与视频状态协议一致，便于
  /// 下边栏复用相同的启动、暂停、切曲和完成判断语义。
  static Future<String> ensureCurrent(
    String outFile,
    String commandFile,
    String progressFile,
    Directory base, {
    required String sessionId,
  }) async {
    final script =
        '''
-- StreamPath: 音频状态、命令与播放进度上报。
local utils = require "mp.utils"
local OUT = ${_luaQuote(outFile)}
local CMD = ${_luaQuote(commandFile)}
local PROGRESS = ${_luaQuote(progressFile)}

local has_loaded = false
local last_playlist_pos = -1
local last_path = ""
local last_time_pos = -1
local last_duration = -1
local last_entry_recorded = false

local function append_progress(outcome, reason, file_error)
    if last_playlist_pos < 0 and last_path == "" then return end
    local record = {
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
    local file = io.open(PROGRESS, "a")
    if file then
        file:write(line .. "\\n")
        file:flush()
        file:close()
    end
end

local function update_progress()
    local pos = mp.get_property_number("playlist-pos", -1)
    local path = mp.get_property("path", "")
    local time_pos = mp.get_property_number("time-pos", -1)
    local duration = mp.get_property_number("duration", -1)
    if pos >= 0 then last_playlist_pos = pos end
    if path ~= "" then last_path = path end
    if time_pos >= 0 then last_time_pos = time_pos end
    if duration > 0 then last_duration = duration end
end

local function write_status(use_cached_progress)
    if not use_cached_progress then update_progress() end
    local pos = mp.get_property_number("playlist-pos", last_playlist_pos)
    local path = mp.get_property("path", last_path)
    local paused = mp.get_property_bool("pause", false)
    local time_pos = mp.get_property_number("time-pos", last_time_pos)
    local duration = mp.get_property_number("duration", last_duration)
    if use_cached_progress then
        if last_playlist_pos >= 0 then pos = last_playlist_pos end
        if last_path ~= "" then path = last_path end
        if last_time_pos >= 0 then time_pos = last_time_pos end
        if last_duration > 0 then duration = last_duration end
    end
    local file = io.open(OUT, "w")
    if file then
        file:write(tostring(pos) .. "\\n" .. tostring(path) .. "\\n" ..
            (paused and "1" or "0") .. "\\n" .. tostring(time_pos) ..
            "\\n" .. tostring(duration))
        file:close()
    end
end

local function poll_command()
    local file = io.open(CMD, "r")
    if not file then return end
    local command = file:read("*l")
    file:close()
    os.remove(CMD)
    if command == "pause" then
        mp.set_property_bool("pause", true)
    elseif command == "resume" then
        mp.set_property_bool("pause", false)
    end
end

mp.register_event("start-file", function()
    last_playlist_pos = mp.get_property_number("playlist-pos", -1)
    last_path = mp.get_property("path", "")
    last_time_pos = -1
    last_duration = -1
    last_entry_recorded = false
end)

mp.register_event("file-loaded", function()
    has_loaded = true
    update_progress()
    write_status(false)
end)

mp.register_event("playback-restart", function()
    update_progress()
    write_status(false)
end)

mp.observe_property("pause", "bool", function()
    if has_loaded then write_status(false) end
end)

mp.register_event("end-file", function(event)
    update_progress()
    local reason = event and event.reason or ""
    local file_error = event and event.error or ""
    if reason == "eof" then
        append_progress("completed", reason, file_error)
    else
        append_progress("position", reason, file_error)
    end
    last_entry_recorded = true
    write_status(true)
end)

mp.observe_property("idle-active", "bool", function(_, value)
    if value and has_loaded then
        local file = io.open(OUT, "w")
        if file then
            file:write("-1\\n\\n0\\n-1\\n-1")
            file:close()
        end
    end
end)

mp.register_event("shutdown", function()
    update_progress()
    write_status(true)
    if has_loaded and not last_entry_recorded then
        append_progress("position", "shutdown", "")
    end
end)

mp.add_periodic_timer(0.25, poll_command)
mp.add_periodic_timer(1.0, function()
    if has_loaded then write_status(false) end
end)
''';
    return _write(
      base,
      'streampath-audio-current-${safeSessionToken(sessionId)}.lua',
      script,
    );
  }

  static String safeSessionToken(String sessionId) =>
      sessionId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');

  static List<String> sessionArtifactNames(String sessionId) {
    final token = safeSessionToken(sessionId);
    return [
      'streampath-audio-playlist-$token.m3u8',
      'streampath-audio-companions-$token.lua',
      'streampath-audio-current-$token.lua',
    ];
  }

  static String _sanitize(String value) =>
      value.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ');

  static String _luaQuote(String value) =>
      '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\n', '\\n').replaceAll('\r', '\\r')}"';

  static Future<String> _write(
    Directory base,
    String name,
    String content,
  ) async {
    final file = File(p.join(base.path, name));
    await file.parent.create(recursive: true);
    await file.writeAsString(content, flush: true);
    return file.path;
  }
}
