local mp = require 'mp'
local utils = require 'mp.utils'
local started = mp.get_time()
local samples = {}
local function record(event, detail)
    samples[#samples + 1] = {
        ms = math.floor((mp.get_time() - started) * 1000),
        event = event,
        detail = detail,
        edition = mp.get_property_number('edition'),
        menu = mp.get_property_native('disc-menu-active'),
        time = mp.get_property_number('time-pos'),
    }
end
mp.observe_property('disc-menu-active', 'bool', function(_, value)
    record('menu', value)
end)
mp.register_event('file-loaded', function() record('file-loaded') end)
mp.register_event('playback-restart', function() record('playback-restart') end)
local function command(delay, args)
    mp.add_timeout(delay, function()
        record('command', {args = args})
        local _, error = mp.command_native(args)
        record('command-result', {args = args, error = error})
    end)
end
command(27, {'discnav', 'menu'})
command(38, {'discnav', 'down'})
command(39, {'discnav', 'select'})
command(42, {'set', 'edition', '1'})
command(44, {'seek', '1450', 'absolute'})
command(46, {'seek', '2850', 'absolute'})
command(48, {'discnav', 'popup'})
mp.add_timeout(52, function()
    record('completed')
    local destination = mp.get_opt('probe-output')
    local file = assert(io.open(destination, 'wb'))
    file:write(utils.format_json({schema = 1, samples = samples}))
    file:close()
    mp.commandv('quit')
end)
