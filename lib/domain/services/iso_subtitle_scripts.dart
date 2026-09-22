import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

class IsoSubtitleScripts {
  static Future<String> write(
    Directory directory, {
    required String sessionId,
    required bool menu,
    required bool autoSelect,
    required Map<String, String> bindings,
    required List<Map<String, String>> playlist,
    List<String> overrides = const [],
    List<Map<String, dynamic>> candidates = const [],
    List<Map<String, dynamic>> titles = const [],
    String? fontDirectory,
  }) async {
    final config = jsonEncode({
      'session': sessionId,
      'menu': menu,
      'select': autoSelect,
      'bindings': bindings,
      'playlist': playlist,
      'overrides': overrides,
      'candidates': candidates,
      'titles': titles,
      'fonts': fontDirectory,
    });
    final file = File(p.join(directory.path, 'iso-subtitles.lua'));
    // JSON 字符串先作为 Lua 字符串字面量传入，路径不参与代码拼接。
    await file.writeAsString(
      'local CONFIG_JSON = ${jsonEncode(config)}\n$_body',
    );
    return file.path;
  }

  static const _body = r'''
local mp = require 'mp'
local utils = require 'mp.utils'
local config = utils.parse_json(CONFIG_JSON)
local bindings = config.bindings
local overrides = config.overrides or {}
local candidates = config.candidates or {}
local active, owned, owned_path, owned_tag, previous = nil, nil, nil, nil, nil
local generation, ready, menu_seen, initial = 0, false, false, nil
local attempted = false
local failed = false
local observed_edition = nil
local last_update = ''
local function tracks() return mp.get_property_native('track-list') or {} end
local function current_sid()
    local value = mp.get_property('sid', 'no')
    return tonumber(value) or 'no'
end
local function path_key(value)
    if type(value) ~= 'string' then return nil end
    value = value:gsub('\\', '/')
    if value:match('^%a:/') or value:sub(1,2) == '//' then value=value:lower() end
    return value
end
local function identity(t)
    return tostring(t.id)..':'..tostring(t.type)..':'..tostring(t['external-filename'])..':'..tostring(t.lang)..':'..tostring(t.title)
end
local function owned_track()
    for _, t in ipairs(tracks()) do
        if t.id == owned and t.type == 'sub' and t.external and t.title == owned_tag and path_key(t['external-filename']) == path_key(owned_path) then return t end
    end
end
local function remove_owned()
    local t = owned_track()
    local selected = t and current_sid() == t.id
    if t then mp.commandv('sub-remove', tostring(t.id)) end
    if selected and previous then
        if previous.id == 'no' then mp.set_property('sid', 'no')
        else
            for _, candidate in ipairs(tracks()) do
                if identity(candidate) == previous.identity then mp.set_property_native('sid', candidate.id); break end
            end
        end
    end
    owned, owned_path, owned_tag, previous = nil, nil, nil, nil
end
local function reset()
    remove_owned()
    active, attempted = nil, false
    failed = false
    generation = generation + 1
end
local function disc_titles()
    local result = {}
    if config.titles and #config.titles > 0 then return config.titles end
    if #config.playlist > 0 then
        for _, item in ipairs(config.playlist) do
            result[#result+1] = {id=item.id, duration=tonumber(item.duration) or 0}
        end
        return result
    end
    for _, entry in ipairs(mp.get_property_native('edition-list') or {}) do
        local label = entry.title or ''
        local mpls = label:match('%((%d%d%d%d%d)%.mpls%)')
        local h,m,s = label:match('%((%d+):(%d%d):(%d%d%.%d+)%)')
        if mpls and h then result[#result+1] = {id=mpls, title=label, duration=tonumber(h)*3600+tonumber(m)*60+tonumber(s)} end
    end
    return result
end
local function subtitle_path(id)
    for _, value in ipairs(overrides) do if value == id then return bindings[id] end end
    if #candidates == 0 then return bindings[id] end
    local ids, seen, video = {}, {}, 0
    for _, title in ipairs(disc_titles()) do
        if title.id == id then video=title.duration end
        if title.duration >= 300 and not seen[title.id] then
            seen[title.id]=true; ids[#ids+1]=title.id
        end
    end
    table.sort(ids)
    local episode = 0
    for index, value in ipairs(ids) do if value == id then episode=index end end
    local best, best_name, best_score = nil, nil, -math.huge
    for _, candidate in ipairs(candidates) do
        local path=bindings['candidate:'..candidate.path]
        if path and (not candidate.mpls or candidate.mpls == id) then
            local ending=candidate.duration or 0
            local tolerance=math.max(120, video*0.1)
            local delta=math.abs(video-ending)
            local duration_match=video>0 and ending>0 and ending<=video+5 and delta<=tolerance
            local episode_match=episode>0 and candidate.episode==episode
            if candidate.mpls or duration_match or episode_match then
                local score=candidate.base + (candidate.mpls and 2000 or 0)
                    + (duration_match and 600*(1-delta/tolerance) or 0)
                    + (episode_match and 200 or (candidate.episode and -200 or 0))
                if score>best_score or (score==best_score and (not best_name or candidate.path<best_name)) then
                    best, best_name, best_score=path, candidate.path, score
                end
            end
        end
    end
    return best
end
local function current_id()
    if not ready then return nil end
    if #config.playlist > 0 then
        local item = config.playlist[mp.get_property_number('playlist-pos', -1)+1]
        if item and item.path == mp.get_property('path') then return item.id end
        return nil
    end
    local menu = mp.get_property_native('disc-menu-active')
    if menu == true then menu_seen = true; return nil end
    if config.menu and menu ~= false then return nil end
    local edition = mp.get_property_number('current-edition', -1)
    if edition < 0 then return nil end
    initial = initial or edition
    if config.menu and not menu_seen and initial == edition then return nil end
    local entry = (mp.get_property_native('edition-list') or {})[edition+1]
    local label = entry and entry.title or ''
    local id = label:match('%((%d%d%d%d%d)%.mpls%)')
    local h,m,s = label:match('%((%d+):(%d%d):(%d%d%.%d+)%)')
    if not id or not h then return nil end
    local duration = mp.get_property_number('duration', -1)
    if math.abs(duration-(tonumber(h)*3600+tonumber(m)*60+tonumber(s))) > 0.01 then return nil end
    return id
end
local function report(id, status)
    mp.set_property_native('user-data/streampath/iso-subtitles', {
        session=config.session, current=id or '', generation=generation,
        status=status, titles=disc_titles(), track=owned or -1,
        update=last_update,
    })
end
local function apply()
    local id = current_id()
    if id ~= active then reset(); active=id end
    if not id then report(nil, 'unavailable'); return end
    local path = subtitle_path(id)
    if not path then report(id, 'unbound'); return end
    if attempted then report(id, failed and 'failed' or (owned_track() and 'loaded' or 'manual')); return end
    attempted = true
    local before, prior = {}, current_sid()
    previous = prior == 'no' and {id='no'} or nil
    for _, t in ipairs(tracks()) do
        if t.type == 'sub' then before[t.id] = true end
        if t.type == 'sub' and t.id == prior then previous={id=prior, identity=identity(t)} end
        if t.type == 'sub' and t.external and path_key(t['external-filename']) == path_key(path) then
            previous=nil; report(id, 'manual'); return
        end
    end
    local requested_generation = generation
    local tag = 'StreamPath:'..config.session..':'..generation..':'..id
    mp.command_native({'sub-add', path, 'auto', tag})
    -- 命令执行完后，轨道属性通知可能仍在事件队列中。
    mp.add_timeout(0, function()
        for _, t in ipairs(tracks()) do
            if not before[t.id] and t.type == 'sub' and t.external and
                path_key(t['external-filename']) == path_key(path) and t.title == tag then
                if generation ~= requested_generation or current_id() ~= id then
                    mp.commandv('sub-remove', tostring(t.id)); return
                end
                owned, owned_path, owned_tag = t.id, path, tag
                if config.select then mp.set_property_native('sid', owned)
                else mp.set_property_native('sid', prior) end
                report(id, 'loaded'); return
            end
        end
        if generation == requested_generation then
            failed=true; previous=nil; report(id, 'failed'); mp.msg.warn('ISO subtitle load failed')
        end
    end)
end

if config.fonts then
    local _, err = mp.get_property('sub-fonts-dir')
    if not err then mp.add_hook('on_load', 5, function()
        mp.set_property('file-local-options/sub-fonts-dir', config.fonts)
    end) end
end
mp.register_event('start-file', function() ready=false; reset() end)
mp.register_event('file-loaded', function()
    observed_edition=mp.get_property_number('current-edition', -1)
    if #config.playlist > 0 or not config.menu then ready=true; apply() end
end)
mp.register_event('playback-restart', function()
    observed_edition=mp.get_property_number('current-edition', -1)
    ready=true
    apply()
end)
mp.register_event('end-file', function() ready=false; reset(); report(nil,'unavailable') end)
mp.observe_property('current-edition', 'number', function(_, value)
    if value == observed_edition then return end
    observed_edition=value
    if #config.playlist == 0 then ready=false; reset(); report(nil,'unavailable') end
end)
mp.observe_property('disc-menu-active', 'bool', function(_, value)
    if value then menu_seen=true; reset(); report(nil,'unavailable')
    elseif value == false then apply() end
end)
mp.observe_property('duration', 'number', function() apply() end)
if config.menu then
    mp.observe_property('time-pos', 'number', function()
        if not attempted then apply() end
    end)
end
mp.register_script_message('iso-subtitle-update', function(session, data)
    if session ~= config.session then return end
    local value = utils.parse_json(data)
    if not value or type(value.bindings) ~= 'table' then return end
    if type(value.update) ~= 'string' then return end
    if value.generation ~= generation or value.current ~= (active or '') then return end
    reset(); bindings=value.bindings; overrides=value.overrides or {}; candidates=value.candidates or candidates; last_update=value.update; apply()
end)
''';
}
