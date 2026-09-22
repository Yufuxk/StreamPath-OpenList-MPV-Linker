local mp = require 'mp'
local utils = require 'mp.utils'
local started = mp.get_time()
local samples = {}
local phase = 'load'
local measured = nil
local last_wall, last_pos = nil, nil
local stall_count, stall_seconds, max_gap = 0, 0, 0
local paused_count = 0
local duration = tonumber(mp.get_opt('probe-duration'))
local function record(event)
    samples[#samples + 1] = {event=event, ms=(mp.get_time()-started)*1000,
        phase=phase, time=mp.get_property_number('time-pos'),
        menu=mp.get_property_native('disc-menu-active'),
        cache=mp.get_property_number('demuxer-cache-duration')}
end
mp.register_event('file-loaded', function()
    phase = 'edition'
    assert(mp.set_property_number('edition', 1))
end)
mp.register_event('playback-restart', function()
    record('playback-restart')
    if phase == 'edition' and mp.get_property_number('current-edition') == 1 then
        phase = 'seek'
        assert(mp.commandv('seek', 600, 'absolute+exact'))
    elseif phase == 'seek' then
        phase = 'warmup'
        mp.add_timeout(5, function()
            phase = 'measure'
            measured = mp.get_time()
        end)
    end
end)
mp.observe_property('paused-for-cache', 'bool', function(_, value)
    if value and phase == 'measure' then paused_count = paused_count + 1 end
end)
mp.observe_property('time-pos', 'number', function(_, pos)
    if phase ~= 'measure' or not pos then return end
    local now = mp.get_time()
    if last_wall and pos > last_pos then
        local gap = now - last_wall
        local delay = gap - (pos - last_pos)
        max_gap = math.max(max_gap, gap)
        if delay > 0.15 then
            stall_count = stall_count + 1
            stall_seconds = stall_seconds + delay
            record('stall')
        end
    end
    if not last_pos or pos ~= last_pos then
        last_wall, last_pos = now, pos
    end
end)
mp.add_periodic_timer(1, function()
    record('sample')
    if measured and mp.get_time() - measured >= duration then
        local result = {schema=2, samples=samples, measuredSeconds=mp.get_time()-measured,
            stallCount=stall_count, stallSeconds=stall_seconds, maxFrameGap=max_gap,
            cachePauseCount=paused_count}
        local file = assert(io.open(mp.get_opt('probe-output'), 'wb'))
        file:write(utils.format_json(result))
        file:close()
        mp.commandv('quit')
    end
end)
