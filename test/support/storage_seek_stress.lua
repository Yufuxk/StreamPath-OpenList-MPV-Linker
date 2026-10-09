local mp = require 'mp'
local msg = require 'mp.msg'
local count = 0
local timer

mp.register_event('file-loaded', function()
    local duration = mp.get_property_number('duration')
    assert(duration and duration > 60, 'Seek test requires a video longer than 60 seconds')
    timer = mp.add_periodic_timer(0.12, function()
        if count < 60 then
            local target = 30 + (count * 137) % (math.floor(duration) - 60)
            mp.commandv('seek', target, 'absolute+exact')
        else
            mp.commandv('seek', count % 2 == 0 and 15 or -15, 'relative+keyframes')
        end
        count = count + 1
        if count == 120 then
            timer:kill()
            msg.warn('SEEK_STRESS_COMPLETE count=' .. count)
            mp.commandv('quit')
        end
    end)
end)

mp.register_event('end-file', function(event)
    msg.warn('SEEK_STRESS_END reason=' .. tostring(event.reason) .. ' error=' .. tostring(event.error) .. ' count=' .. count)
    if timer then timer:kill() end
end)
