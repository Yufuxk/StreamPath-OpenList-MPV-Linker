local now, tick, toggle, result = 0, nil, nil, nil
local events, observers = {}, {}
local properties = {['time-pos']=0, ['seeking']=false, ['disc-menu-active']=false}
local snapshot = {virtualDisc={snapshotSerial=1, readCalls=1, readSequence=1,
    sequenceBytes=0, forwardReady=true, forwardBytes=100*1048576}}
local overlay = {update=function() end, remove=function() end}
package.preload['mp'] = function() return {
    get_time=function() return now end,
    get_script_directory=function() return '.' end,
    create_osd_overlay=function() return overlay end,
    command_native=function(args) return args[2] end,
    get_property_number=function(name) return properties[name] end,
    get_property_native=function(name) return properties[name] end,
    set_property_native=function(name,value)
        assert(name=='user-data/streampath/menu-cache', 'Native cache must not be modified')
        result=value
    end,
    add_forced_key_binding=function(key,_,callback) assert(key=='Ctrl+Alt+i'); toggle=callback end,
    register_event=function(name,callback) events[name]=callback end,
    observe_property=function(name,_,callback) observers[name]=callback end,
    add_periodic_timer=function(_,callback) tick=callback end,
} end
local first = true
package.preload['mp.utils'] = function() return {
    join_path=function() return 'metrics' end,
    parse_json=function()
        if first then
            first=false
            return {labels=setmetatable({}, {__index=function(_,key) return key end})}
        end
        return snapshot
    end,
} end
io.open = function() return {read=function() return '{}' end, close=function() end} end
dofile(assert(arg[1]))
local function step(seconds, pos, bytes, fresh)
    now=seconds
    properties['time-pos']=pos
    if fresh ~= false then
        snapshot.virtualDisc.snapshotSerial=snapshot.virtualDisc.snapshotSerial+1
        snapshot.virtualDisc.readCalls=snapshot.virtualDisc.readCalls+1
    end
    snapshot.virtualDisc.sequenceBytes=bytes
    tick()
end
step(3,3,3*1048576)
step(6,6,6*1048576)
assert(result.estimatedSeconds==100, 'Estimate must use actual forward bytes and media time')
toggle()
assert(result.visible and overlay.data:find('00:01:40',1,true), 'Panel renders estimated time')
step(7,6,6*1048576)
assert(result.estimatedSeconds==100, 'Pause must not inflate the estimate')
events.seek()
step(8,600,6*1048576)
assert(not result.available and not result.estimatedSeconds, 'Seek invalidates old data')
snapshot.virtualDisc.readSequence=2
step(10,602,2*1048576)
step(13,605,5*1048576)
assert(result.estimatedSeconds==100)
snapshot.virtualDisc.forwardBytes=0
step(14,606,6*1048576)
assert(result.estimatedSeconds==0, 'Empty forward cache must display zero')
step(18,606,6*1048576,false)
assert(not result.available, 'Stale snapshots must not show cached seconds')
snapshot.virtualDisc.forwardReady=false
step(19,607,7*1048576)
assert(not result.available, 'In-flight or failed reads must not count')
snapshot.virtualDisc.forwardReady=true
properties['disc-menu-active']=true
observers['disc-menu-active']()
step(22,608,8*1048576)
assert(not result.available, 'Menu has no linear cache duration')
properties['disc-menu-active']=false
observers['current-edition']()
step(23,0,0)
assert(not result.available, 'Episode changes clear the estimate')
snapshot=nil
now=30; tick()
assert(not result.available, 'Missing or malformed metrics remain unavailable')
print('menu cache panel: PASS')
