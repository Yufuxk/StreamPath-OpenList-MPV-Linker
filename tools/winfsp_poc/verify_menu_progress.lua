-- 验证产品生成的菜单进度脚本，不依赖媒体和网络。
local properties = {}
local events, observers, timers = {}, {}, {}
local output = {}
local commands = {}
package.preload['mp'] = function()
    return {
        get_opt = function(name)
            if arg[2] == 'resume' then
                return name == 'streampath-menu-edition' and '1' or '123.5'
            end
        end,
        set_property_number = function(name, value)
            commands[#commands + 1] = {name, value}
            return true
        end,
        commandv = function(...)
            commands[#commands + 1] = {...}
            return true
        end,
        get_property_native = function(name) return properties[name] end,
        get_property_number = function(name, fallback) return properties[name] or fallback end,
        observe_property = function(name, _, callback) observers[name] = callback end,
        register_event = function(name, callback) events[name] = callback end,
        add_periodic_timer = function(_, callback) timers[#timers + 1] = callback end,
    }
end
package.preload['mp.utils'] = function()
    return {format_json = function(value)
        output[#output + 1] = value
        return '{}'
    end}
end
dofile(assert(arg[1]))
local function title(edition, position, duration)
    properties = {['disc-menu-active']=false, ['current-edition']=edition,
                  editions=5, ['time-pos']=position, duration=duration,
                  ['edition-list']={{title='(00:00:10.000) (00000.mpls)'}, {title='(00:25:00.000) (00007.mpls)'},
                    {title='(00:23:20.000) (00002.mpls)'}, {title='(00:25:00.000) (00003.mpls)'}}}
    observers['time-pos']()
end

title(0, 5, 10)
timers[1]()
assert(#output == 0, 'Initial intro must not become a resume point')
observers['disc-menu-active'](nil, true)
title(1, 123.5, 1500)
timers[1]()
assert(output[#output].position == 123.5 and not output[#output].completed)
assert(output[#output].mplsId == '00007', 'MPLS must not be inferred from edition index')
title(0, 11.8, 600.6)
timers[1]()
assert(output[#output].mplsId == '00007', 'Stale edition with menu duration must not overwrite the feature')
properties = {['disc-menu-active']=true, ['time-pos']=1, duration=1}
timers[1]()
assert(output[#output].position == 123.5, 'Menu must preserve the title position')
title(2, 0, 1400)
timers[1]()
assert(output[#output].edition == 2 and output[#output].position == 0)
title(2, 1386, 1400)
timers[1]()
assert(output[#output].completed, '99 percent must complete')
title(3, 34.125, 1500)
properties = {}
events['end-file']({reason='quit'})
events.shutdown()
assert(output[#output].edition == 3 and output[#output].position == 34.125
       and not output[#output].completed, 'Quit must preserve the last valid title')
print('PASS: menu progress, title switch, 99 percent and shutdown')

assert(#commands == 0, 'Menu must never restore edition or seek, even with legacy options')
