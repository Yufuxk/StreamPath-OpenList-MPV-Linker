import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../data/models/app_language.dart';
import '../localization/app_localizations.dart';

class MenuCachePanelScript {
  static Future<String> write(Directory directory, AppLanguage language) async {
    final l10n = AppLocalizations(language);
    final config = jsonEncode({
      'metrics': p.absolute(directory.path, 'iso-bridge-metrics.json'),
      'labels': {
        for (final label in const [
          'ISO 前向缓存',
          '连续已缓存',
          '估算顺序可读时长',
          '采样中或暂不可用',
          '按近期播放速度估算，非音视频队列时长',
          'Ctrl+Alt+i 关闭',
        ])
          label: l10n.text(label),
      },
    });
    final file = File(p.join(directory.path, 'sp-menu-cache.lua'));
    await file.writeAsString(
      'local CONFIG_JSON = ${jsonEncode(config)}\n$_body',
    );
    return file.path;
  }

  static const _body = r'''
local mp = require 'mp'
local utils = require 'mp.utils'
local config = utils.parse_json(CONFIG_JSON)
local labels = config.labels
local overlay = mp.create_osd_overlay('ass-events')
local visible = false
local serial, refreshed, reset_at = nil, 0, mp.get_time()
local anchor, rate, last_sequence = nil, nil, nil
local last_reads, invalid_reads = nil, nil
local function clear_estimate()
    anchor, rate, last_sequence = nil, nil, nil
    reset_at = mp.get_time()
    invalid_reads = last_reads
end
local function text(s) return mp.command_native({'escape-ass', s}) end
local function sample()
    local now = mp.get_time()
    local file = io.open(config.metrics, 'rb')
    local data
    if file then
        data = utils.parse_json(file:read('*a'))
        file:close()
    end
    local disc = data and data.virtualDisc
    if disc then last_reads = disc.readCalls end
    local pos = mp.get_property_number('time-pos')
    local unavailable = not disc or disc.failed or not disc.forwardReady
    if disc and disc.snapshotSerial ~= serial then
        serial, refreshed = disc.snapshotSerial, now
    end
    unavailable = unavailable or now - refreshed > 3 or now - reset_at < 2
        or (invalid_reads and last_reads == invalid_reads)
        or not pos or mp.get_property_native('seeking')
        or mp.get_property_native('disc-menu-active')
        or (data and data.bridge and data.bridge.final)
    local seconds, forward
    if unavailable then
        anchor, rate = nil, nil
    else
        forward = disc.forwardBytes
        if disc.readSequence ~= last_sequence then
            anchor, rate = nil, nil
            last_sequence = disc.readSequence
        end
        if not anchor or pos < anchor.pos or disc.sequenceBytes < anchor.bytes then
            anchor = {pos=pos, bytes=disc.sequenceBytes}
            rate = nil
        elseif pos - anchor.pos >= 3 then
            local delta = disc.sequenceBytes - anchor.bytes
            if delta >= 262144 then
                rate = delta / (pos - anchor.pos)
            else
                rate = nil
            end
            anchor = {pos=pos, bytes=disc.sequenceBytes}
        end
        if rate then seconds = forward / rate end
    end
    -- 独立命名空间便于诊断，不改写 MPV 原生缓存属性。
    mp.set_property_native('user-data/streampath/menu-cache', {
        available=forward ~= nil, forwardBytes=forward,
        estimatedSeconds=seconds, visible=visible,
    })
    if not visible then return end
    local duration = labels['采样中或暂不可用']
    if seconds then
        local s = math.floor(seconds)
        duration = string.format('~ %02d:%02d:%02d', math.floor(s/3600), math.floor(s/60)%60, s%60)
    end
    local bytes = forward and string.format('%.1f MiB', forward/1048576)
        or labels['采样中或暂不可用']
    overlay.res_x, overlay.res_y = 1280, 720
    overlay.data = [[{\an9\pos(1250,30)\fs24\bord2\shad0\1c&HFFFFFF&\3c&H000000&}]]
        .. text(labels['ISO 前向缓存']) .. [[\N]]
        .. text(labels['连续已缓存'] .. ': ' .. bytes) .. [[\N]]
        .. text(labels['估算顺序可读时长'] .. ': ' .. duration) .. [[\N{\fs18}]]
        .. text(labels['按近期播放速度估算，非音视频队列时长']) .. [[\N]]
        .. text(labels['Ctrl+Alt+i 关闭'])
    overlay:update()
end
mp.add_forced_key_binding('Ctrl+Alt+i', 'toggle', function()
    visible = not visible
    if not visible then overlay:remove() end
    sample()
end)
mp.register_event('seek', clear_estimate)
mp.register_event('start-file', clear_estimate)
mp.register_event('end-file', function()
    clear_estimate()
    overlay:remove()
end)
mp.observe_property('current-edition', 'number', clear_estimate)
mp.observe_property('disc-menu-active', 'bool', clear_estimate)
mp.add_periodic_timer(1, sample)
''';
}
