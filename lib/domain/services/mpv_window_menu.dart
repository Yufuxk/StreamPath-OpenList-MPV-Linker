import 'dart:convert';
import '../../data/models/mpv_menu_shortcuts.dart';

List<String> mpvWindowMenuLabels(String language) => switch (language) {
  'zh-TW' => [
    '視窗控制',
    '全螢幕 / 退出全螢幕',
    '最大化 / 還原',
    '最小化',
    '轉為獨立視窗',
    '結束播放',
    '%s / %s 選擇 · %s 確認 · %s 關閉',
    '快捷鍵已被使用，請在設定中更改',
    '視窗選單快捷鍵：',
    '請先關閉目前的播放器選單',
  ],
  'ja' => [
    'ウィンドウ操作',
    '全画面 / 全画面解除',
    '最大化 / 元に戻す',
    '最小化',
    '独立ウィンドウに切替',
    '再生を終了',
    '%s / %s で選択 · %s で確定 · %s で閉じる',
    'ショートカットが使用中です。設定で変更してください',
    'ウィンドウメニュー：',
    '開いているプレイヤーメニューを閉じてください',
  ],
  'en' => [
    'Window controls',
    'Toggle fullscreen',
    'Maximize / restore',
    'Minimize',
    'Detach window',
    'Stop playback',
    '%s / %s to select · %s to confirm · %s to close',
    'Shortcut is already bound; change it in settings',
    'Window menu: ',
    'Close the current player menu first',
  ],
  _ => [
    '窗口控制',
    '全屏 / 退出全屏',
    '最大化 / 还原',
    '最小化',
    '转为独立窗口',
    '结束播放',
    '%s / %s 选择 · %s 确认 · %s 关闭',
    '快捷键已被占用，请在设置中更改',
    '窗口菜单快捷键：',
    '请先关闭当前播放器菜单',
  ],
};

String mpvWindowMenuScript(
  String pipe,
  String language, [
  MpvMenuShortcuts? shortcuts,
]) {
  final labels = mpvWindowMenuLabels(language);
  final text = '{${labels.map(jsonEncode).join(',')}}';
  final keys = shortcuts ?? const MpvMenuShortcuts();
  return '''
local pipe = ${jsonEncode(pipe)}
local text = $text
local actions = {'fullscreen', 'maximize', 'minimize', 'detach', 'stop'}
local selected, sequence, opened, enabled = 1, 0, false, true
local uosc_pending = false
local utils = require 'mp.utils'
local key = ${shortcuts == null ? "mp.get_opt('streampath-window-menu-key') or " : ''}${jsonEncode(keys.open)}
local up_key, down_key, confirm_key, close_key = ${jsonEncode(keys.up)}, ${jsonEncode(keys.down)}, ${jsonEncode(keys.confirm)}, ${jsonEncode(keys.close)}
local function uosc_menu_type()
    local current = mp.get_property_native('user-data/uosc/menu/type')
    if current ~= nil then return current end
    local shared = mp.get_property_native('shared-script-properties')
    if type(shared) == 'table' then return shared['uosc-menu-type'] end
end
local function dimensions()
    local w, h = mp.get_osd_size()
    if w <= 0 or h <= 0 then return 1280, 0, 0 end
    return math.floor(720 * w / h), w, h
end
local function update_mouse_area()
    local res_x, w, h = dimensions()
    if w > 0 and h > 0 then
        mp.set_mouse_area(0, 0, math.floor(w * 560 / res_x), math.floor(h * 350 / 720), 'streampath-menu-mouse')
        mp.enable_key_bindings('streampath-menu-mouse', 'allow-hide-cursor')
    end
end
local function hide()
    if not opened then return end
    opened = false
    mp.set_osd_ass(0, 0, '')
    for _, name in ipairs({'up', 'down', 'enter', 'esc'}) do
        mp.remove_key_binding('streampath-menu-' .. name)
    end
    mp.disable_key_bindings('streampath-menu-mouse')
end
local function draw()
    local lines = {
        '{\\\\an7\\\\pos(24,38)\\\\p1\\\\1c&H181818&\\\\1a&H28&\\\\bord0}m 0 0 l 520 0 520 312 0 312{\\\\p0}',
        '{\\\\an7\\\\pos(40,55)\\\\fs30\\\\bord2}StreamPath · ' .. text[1],
    }
    for i = 1, #actions do
        local color = i == selected and '&HFFFFFF&' or '&HBBBBBB&'
        lines[#lines + 1] = string.format('{\\\\an7\\\\pos(40,%d)\\\\fs25\\\\bord2\\\\1c%s}%s %s', 65 + i * 42, color, i == selected and '▶' or ' ', text[i + 1])
    end
    lines[#lines + 1] = '{\\\\an7\\\\pos(40,330)\\\\fs18\\\\bord2}' .. string.format(text[7], up_key, down_key, confirm_key, close_key)
    local res_x = dimensions()
    mp.set_osd_ass(res_x, 720, table.concat(lines, '\\n'))
end
local function send_action(action)
    sequence = sequence + 1
    mp.commandv('script-message', 'streampath-window-menu', pipe, tostring(sequence), action)
end
local function execute()
    local action = actions[selected]
    hide()
    send_action(action)
end
local function show_builtin()
    if not enabled then return end
    opened = true
    mp.add_forced_key_binding(up_key, 'streampath-menu-up', function() selected = (selected + #actions - 2) % #actions + 1; draw() end, {repeatable=true})
    mp.add_forced_key_binding(down_key, 'streampath-menu-down', function() selected = selected % #actions + 1; draw() end, {repeatable=true})
    mp.add_forced_key_binding(confirm_key, 'streampath-menu-enter', execute)
    mp.add_forced_key_binding(close_key, 'streampath-menu-esc', hide)
    update_mouse_area()
    draw()
end
local function toggle()
    if not enabled or uosc_pending then return end
    if opened then hide(); return end
    local current = uosc_menu_type()
    if current == 'streampath-window-menu' then
        mp.commandv('script-message-to', 'uosc', 'close-menu', 'streampath-window-menu')
        return
    elseif current ~= nil then
        mp.osd_message('StreamPath: ' .. text[10], 3)
        return
    end
    local has_uosc = false
    for _, binding in ipairs(mp.get_property_native('input-bindings') or {}) do
        if binding.owner == 'uosc' or (binding.cmd and binding.cmd:find('uosc/', 1, true)) then
            has_uosc = true
            break
        end
    end
    if not has_uosc or up_key:upper() ~= 'UP' or down_key:upper() ~= 'DOWN'
        or confirm_key:upper() ~= 'ENTER' or close_key:upper() ~= 'ESC' then
        show_builtin(); return
    end
    local items = {}
    local icons = {'fullscreen', 'crop_square', 'minimize', 'open_in_new', 'close'}
    for i, action in ipairs(actions) do
        items[#items + 1] = {title = text[i + 1], icon = icons[i],
            value = {'script-message-to', mp.get_script_name(), 'streampath-menu-select', action}}
    end
    local menu = {type = 'streampath-window-menu', title = text[1], items = items,
        on_close = {'script-message-to', mp.get_script_name(), 'streampath-menu-uosc-closed'}}
    uosc_pending = true
    mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json(menu))
    mp.add_timeout(0.3, function()
        if not uosc_pending then return end
        uosc_pending = false
        if uosc_menu_type() ~= 'streampath-window-menu' then
            mp.commandv('script-message-to', 'uosc', 'close-menu', 'streampath-window-menu')
            show_builtin()
        end
    end)
end
mp.register_script_message('streampath-menu-select', function(action)
    if not enabled then return end
    for _, allowed in ipairs(actions) do
        if action == allowed then send_action(action); return end
    end
end)
mp.register_script_message('streampath-menu-uosc-closed', function() uosc_pending = false end)
mp.observe_property('osd-dimensions', 'native', function()
    if opened then update_mouse_area(); draw() end
end)
mp.set_key_bindings({{'MBTN_LEFT', function()
    if not opened then return end
    local _, y = mp.get_mouse_pos()
    local _, h = mp.get_osd_size()
    if h > 0 then
        local index = math.floor((y * 720 / h - 86) / 42) + 1
        if index >= 1 and index <= #actions then selected = index; execute() end
    end
end}}, 'streampath-menu-mouse', 'force')
local bindings = mp.get_property_native('input-bindings')
local conflict = type(bindings) ~= 'table'
for _, binding in ipairs(bindings or {}) do
    if binding.key and binding.key:lower() == key:lower() then conflict = true; break end
end
if conflict then
    mp.osd_message('StreamPath: ' .. key .. ' — ' .. text[8], 5)
else
    mp.add_forced_key_binding(key, 'streampath-window-menu-toggle', toggle)
    mp.osd_message('StreamPath: ' .. text[9] .. key, 3)
end
mp.register_script_message('streampath-window-mode', function(mode)
    if mode ~= 'embedded' then
        enabled = false
        uosc_pending = false
        if uosc_menu_type() == 'streampath-window-menu' then
            mp.commandv('script-message-to', 'uosc', 'close-menu', 'streampath-window-menu')
        end
        hide()
        mp.remove_key_binding('streampath-window-menu-toggle')
    end
end)
mp.register_event('shutdown', hide)
''';
}
