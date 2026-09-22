local script, mode = arg[1], arg[2]
local events, observers, messages = {}, {}, {}
local list, next_id, additions, removals = {{id=1,type='sub',lang='jpn',title='PGS'},{id=7,type='video'}}, 7, 0, 0
local menu = mode:match('^menu') ~= nil
local props = {sid=1, ['playlist-pos']=0, path='http://127.0.0.1/title2',
    ['time-pos']=120, seeking=false,
    ['current-edition']=0, duration=100, ['disc-menu-active']=false,
    ['edition-list']={{title='Title (00:01:40.000) (00001.mpls)'}, {title='Title (00:01:40.000) (00002.mpls)'}}}
local mp = {msg={warn=function() end}}
function mp.get_property_native(key) if key=='track-list' then return list end return props[key] end
function mp.get_property(key,default) return props[key] or default end
function mp.get_property_number(key,default) return props[key] or default end
function mp.set_property_native(key,value) props[key]=value end
mp.set_property=mp.set_property_native
function mp.command_native(cmd)
    assert(cmd[1]=='sub-add'); additions=additions+1
    list[#list+1]={id=next_id,type='sub',external=true,['external-filename']=cmd[2],title=cmd[4]}; next_id=next_id+1
    return true
end
function mp.commandv(cmd,id)
    assert(cmd=='sub-remove'); removals=removals+1
    assert(tonumber(id)~=1,'removed embedded PGS')
    for i,t in ipairs(list) do if t.type=='sub' and t.id==tonumber(id) then table.remove(list,i); break end end
end
function mp.register_event(name,callback) events[name]=callback end
function mp.observe_property(name,_,callback) observers[name]=callback end
function mp.register_script_message(name,callback) messages[name]=callback end
function mp.add_hook() end
local clock, timers = 0, {}
function mp.add_timeout(delay, callback)
    local timer={at=clock+delay, callback=callback, alive=true}
    function timer:kill() self.alive=false end
    timers[#timers+1]=timer
    return timer
end
local function advance(seconds)
    clock=clock+seconds
    while true do
        local due=nil
        for _,timer in ipairs(timers) do
            if timer.alive and timer.at<=clock then due=timer; break end
        end
        if not due then return end
        due.alive=false; due.callback()
    end
end
local function settle() advance(0) end
package.preload.mp=function() return mp end
-- 测试仅解析生成器配置与预先构造的更新，不实现 JSON 解码器。
local config={session='test',menu=menu,select=mode~='no-select',
    bindings={['00001']='C:/subs/one.ass',['00002']='C:/subs/two.srt'},playlist={}}
if not menu then config.playlist={{id='00002',path=props.path},{id='00001',path='http://127.0.0.1/title1'}} end
if mode:match('score$') then
    config.bindings={['candidate:01.chs.ass']='C:/subs/one.ass', ['candidate:02.en.srt']='C:/subs/two.srt'}
    config.candidates={{path='01.chs.ass',episode=1,base=63,duration=1000},
        {path='02.en.srt',episode=2,base=11,duration=1500}}
    config.titles={{id='00001',duration=1400},{id='00002',duration=1500},{id='00000',duration=20}}
    props['current-edition']=1; props.duration=1500
    props['edition-list']={{title='Title (00:23:20.000) (00001.mpls)'},{title='Title (00:25:00.000) (00002.mpls)'}}
end
local update
package.preload['mp.utils']=function() return {parse_json=function(data) if data=='update' then return update end return config end} end
dofile(script)
if mode:match('score$') then
    events['file-loaded'](); events['playback-restart']()
    if menu then
        props['disc-menu-active']=true; observers['disc-menu-active']('',true)
        props['disc-menu-active']=false; observers['disc-menu-active']('',false)
        events['playback-restart']()
    end
    settle()
    local state=props['user-data/streampath/iso-subtitles']
    assert(state.status=='loaded' and additions==1,'automatic scoring did not load without manual binding')
    assert(list[#list]['external-filename']=='C:/subs/two.srt','duration/episode ranking selected wrong subtitle')
    if menu then
        assert(props['time-pos']==120,'subtitle loading changed playback position')
        props['time-pos']=45; events['playback-restart'](); advance(0)
        assert(additions==1 and props['time-pos']==45,
            'scored subtitle reset position during ordinary seek')
    end
    -- 显式禁用阻止候选回退；恢复自动后，时长可推翻错误集数。
    update={generation=state.generation,current=state.current,bindings=config.bindings,
        overrides={'00002'},update='disable'}
    messages['iso-subtitle-update']('test','update'); settle()
    state=props['user-data/streampath/iso-subtitles']
    assert(state.status=='unbound','manual disable did not block automatic fallback')
    config.candidates[1].duration=1500; config.candidates[2].duration=1000
    update={generation=state.generation,current=state.current,bindings=config.bindings,
        candidates=config.candidates,overrides={},update='restore'}
    messages['iso-subtitle-update']('test','update'); settle()
    assert(list[#list]['external-filename']=='C:/subs/one.ass','duration did not outweigh wrong episode')
    state=props['user-data/streampath/iso-subtitles']
    config.bindings['00002']='C:/subs/manual.srt'
    update={generation=state.generation,current=state.current,bindings=config.bindings,
        overrides={'00002'},update='manual'}
    messages['iso-subtitle-update']('test','update'); settle()
    assert(list[#list]['external-filename']=='C:/subs/manual.srt','manual binding lost priority')
    print('ISO subtitle composite scoring passed: '..mode)
    return
end
if mode=='menu-position' then
    events['file-loaded'](); events['playback-restart']()
    props['disc-menu-active']=true; observers['disc-menu-active']('',true)
    props['disc-menu-active']=false; observers['disc-menu-active']('',false)
    settle()
    assert(additions==1 and props['time-pos']==120,'initial loading changed position')
    for _, position in ipairs({6.4, 40, 65, 80}) do
        props['time-pos']=position
        props['current-edition']=1-props['current-edition']
        observers['current-edition']('',props['current-edition'])
        events['playback-restart'](); settle()
        assert(props['time-pos']==position,'title transition changed position')
        local before=additions
        events['playback-restart'](); observers.duration(); settle()
        assert(additions==before,'ordinary restart reloaded subtitles')
        props['disc-menu-active']=true; observers['disc-menu-active']('',true)
        props['disc-menu-active']=false; observers['disc-menu-active']('',false); settle()
        assert(props['time-pos']==position,'popup return changed position')
    end
    print('ISO subtitle playback position preservation passed')
    return
end

events['file-loaded'](); events['playback-restart']()
if mode=='menu' then
    assert(additions==0,'injected during First Play')
    props['disc-menu-active']=true; observers['disc-menu-active']('',true)
    props['disc-menu-active']=false; observers['disc-menu-active']('',false)
    events['playback-restart']()
end
settle()
assert(additions==1,'initial subtitle not loaded')
assert(props.sid==(mode=='no-select' and 1 or 7),'selection policy failed')
props.sid='no'; observers.duration(); events['playback-restart']()
assert(additions==1 and props.sid=='no','repeated event stole manual selection')
local state=props['user-data/streampath/iso-subtitles']
update={generation=state.generation-1,current=state.current,bindings={},update='stale'}
messages['iso-subtitle-update']('test','update')
assert(additions==1 and removals==0,'accepted stale update')
-- 手动加入相同文件路径的轨道不得被本系统接管。
list[#list+1]={id=90,type='sub',external=true,['external-filename']='C:/user/manual.ass'}
if mode=='menu' then
    props['current-edition']=1; observers['current-edition']('',1)
    assert(removals==1 and additions==1,'edition change did not invalidate subtitle')
    observers.duration(); assert(additions==1,'loaded before playback restart')
    events['playback-restart']()
else
    events['end-file'](); props['playlist-pos']=1;props.path='http://127.0.0.1/title1'
    events['file-loaded']()
end
settle()
assert(additions==2,'new playlist subtitle not loaded')
assert(list[1].id==1,'embedded PGS changed')
local manual=false
for _,t in ipairs(list) do if t.id==90 then manual=true end end
assert(manual,'manual subtitle removed')
-- 同一路径与 Track ID 被手动轨道复用后，卸载不能删除新拥有者。
for _,t in ipairs(list) do if t.id==8 then t.title='Manual subtitle' end end
local before=removals
events['end-file']()
assert(removals==before,'removed reused track ID')
events['file-loaded'](); events['playback-restart']()
settle()
state=props['user-data/streampath/iso-subtitles']
update={generation=state.generation,current=state.current,bindings={},update='confirmed'}
messages['iso-subtitle-update']('other-session','update')
assert(props['user-data/streampath/iso-subtitles'].update~='confirmed','accepted wrong session')
messages['iso-subtitle-update']('test','update')
assert(props['user-data/streampath/iso-subtitles'].update=='confirmed','missing update acknowledgement')
assert(props['user-data/streampath/iso-subtitles'].status=='unbound','disable did not apply')
assert(removals==before,'update removed manual track')
state=props['user-data/streampath/iso-subtitles']
mp.command_native=function() return nil,'invalid subtitle' end
update={generation=state.generation,current=state.current,
    bindings={[state.current]='C:/subs/broken.ass'},update='failed-load'}
messages['iso-subtitle-update']('test','update')
observers.duration(); events['playback-restart']()
settle()
assert(props['user-data/streampath/iso-subtitles'].status=='failed','lost subtitle failure status')
print('ISO subtitle ownership and transitions passed: '..mode)
