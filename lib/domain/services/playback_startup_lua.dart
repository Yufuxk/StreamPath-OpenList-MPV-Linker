/// 可选诊断脚本；计时域为 mpv，不能与 Dart Stopwatch 直接相减。
const playbackStartupLua = r'''
local utils = require 'mp.utils'
local origin = mp.get_time()
local serial = 0
local restart_position = nil
local stable = false
local ticks = 0
local collecting = true
local function snapshot(event)
    if not collecting then return end
    local state = mp.get_property_native('demuxer-cache-state', {})
    local cache = {}
    for _, key in ipairs({'fw-bytes', 'total-bytes', 'raw-input-rate', 'reader-pts', 'cache-end', 'bof-cached', 'eof-cached', 'seekable-ranges'}) do
        cache[key] = state[key]
    end
    local record = {event=event, mpvElapsedSec=mp.get_time()-origin,
        clock='mpv-script-relative', restartSerial=serial,
        position=mp.get_property_number('time-pos'),
        duration=mp.get_property_number('duration'),
        cacheDuration=mp.get_property_number('demuxer-cache-duration'),
        cacheState=cache, pausedForCache=mp.get_property_native('paused-for-cache'),
        seeking=mp.get_property_native('seeking'),
        buffering=mp.get_property_number('cache-buffering-state'),
        pause=mp.get_property_native('pause')}
    if event == 'mpvFileLoaded' then
        record.tracks = {}
        for _, track in ipairs(mp.get_property_native('track-list', {})) do
            table.insert(record.tracks, {type=track.type, codec=track.codec, lang=track.lang})
        end
        record.options = {}
        for _, key in ipairs({'cache', 'cache-secs', 'cache-pause', 'cache-pause-initial', 'cache-pause-wait', 'demuxer-max-bytes', 'demuxer-max-back-bytes', 'demuxer-readahead-secs', 'demuxer-seekable-cache', 'demuxer-lavf-probesize', 'demuxer-lavf-analyzeduration', 'demuxer-lavf-hacks', 'force-seekable'}) do
            record.options[key] = mp.get_property_native('options/' .. key)
        end
    end
    if event == 'playbackStable' then record.proxy = true end
    local text = utils.format_json(record)
    if SP_TRACE_OUTPUT then
        local file = io.open(SP_TRACE_OUTPUT, 'a')
        if file then file:write(text .. '\n'); file:close() end
    else
        mp.msg.info('SP_STARTUP ' .. text)
    end
end
snapshot('mpvScriptLoaded')
mp.register_event('start-file', function()
    serial = 0; stable = false; restart_position = nil
    snapshot('mpvStartFile')
end)
mp.register_event('file-loaded', function() snapshot('mpvFileLoaded') end)
mp.register_event('playback-restart', function()
    serial = serial + 1
    restart_position = mp.get_property_number('time-pos')
    snapshot('mpvPlaybackRestart')
end)
mp.observe_property('paused-for-cache', 'bool', function()
    snapshot('mpvBufferingChanged')
end)
mp.observe_property('seeking', 'bool', function()
    snapshot('mpvSeekingChanged')
end)
local timer
timer = mp.add_periodic_timer(1, function()
    ticks = ticks + 1
    snapshot('cacheSample')
    local pos = mp.get_property_number('time-pos')
    if not stable and restart_position and pos and pos - restart_position >= 1
        and not mp.get_property_bool('pause', false)
        and not mp.get_property_bool('seeking', false)
        and not mp.get_property_bool('paused-for-cache', false) then
        stable = true
        snapshot('playbackStable')
    end
    if ticks >= 120 then collecting = false; timer:kill() end
end)
mp.register_event('end-file', function() snapshot('mpvEndFile') end)
''';
