import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/errors/app_exception.dart';
import '../../data/models/player_config.dart';
import 'local_disc_playback_service.dart';
import 'mpv_scripts.dart';
import 'iso_player_arguments.dart';

/// 只管理受控菜单播放器能力和启动参数，会话收尾复用 IsoPlaybackService。
class RemoteMenuPlaybackService {
  RemoteMenuPlaybackService({
    required this.configLoader,
    String? helperExecutable,
  }) : helperExecutable =
           helperExecutable ??
           p.join(
             p.dirname(Platform.resolvedExecutable),
             'streampath_iso_bridge.exe',
           );

  final Future<PlayerConfig> Function() configLoader;
  final String helperExecutable;
  static const runtimeMissing = '请先安装随附的 WinFsp 运行时，再使用远程蓝光菜单';

  Future<String?> unavailableReason() => _checkAvailability();

  Future<String?> _checkAvailability() async {
    try {
      await requireCapability();
      return null;
    } on AppException catch (error) {
      return error.message;
    }
  }

  Future<String> requireCapability({PlayerConfig? config}) async {
    final player = config ?? await configLoader();
    final error = LocalDiscPlaybackService.validateExecutable(player);
    if (error != null) throw AppException.config(error);
    final runtime = await _probe(helperExecutable, ['--check-winfsp']);
    if (runtime.exitCode != 0) {
      throw AppException.config(runtimeMissing);
    }
    final commands = await _probe(player.executable, [
      '--no-config',
      '--input-cmdlist',
    ]);
    final options = await _probe(player.executable, [
      '--no-config',
      '--list-options',
    ]);
    if (commands.exitCode != 0 ||
        options.exitCode != 0 ||
        !RegExp(
          r'^discnav\s',
          multiLine: true,
        ).hasMatch(commands.stdout as String) ||
        !(options.stdout as String).contains('--bluray-device')) {
      throw AppException.config('当前 MPV 不支持本地蓝光菜单，请选择支持菜单的 MPV');
    }
    return player.executable;
  }

  Future<void> installRuntime() async {
    final script = p.join(
      p.dirname(Platform.resolvedExecutable),
      'winfsp',
      'install_winfsp.ps1',
    );
    if (!await File(script).exists()) throw AppException.config(runtimeMissing);
    final powershell = p.join(
      Platform.environment['SystemRoot']!,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
    try {
      final result = await Process.run(powershell, [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script,
      ]);
      if (result.exitCode != 0) {
        throw AppException.config('WinFsp 安装未完成，请重试或使用标题模式');
      }
    } on ProcessException {
      throw AppException.config('WinFsp 安装未完成，请重试或使用标题模式');
    }
  }

  static Future<ProcessResult> _probe(
    String executable,
    List<String> args,
  ) async {
    Process? process;
    try {
      process = await Process.start(executable, args);
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.transform(utf8.decoder).join();
      final code = await process.exitCode.timeout(const Duration(seconds: 10));
      return ProcessResult(process.pid, code, await stdout, await stderr);
    } on TimeoutException {
      process?.kill();
      if (process != null) await process.exitCode;
      throw AppException.config('远程蓝光菜单组件尚未通过能力验证，请使用标题模式');
    } on ProcessException {
      throw AppException.config('远程蓝光菜单组件尚未通过能力验证，请使用标题模式');
    }
  }

  Future<List<String>> prepareArgs({
    required PlayerConfig config,
    required Directory sessionDirectory,
    required Uri endpoint,
    required String sessionKey,
    required String ipcPipeName,
  }) async {
    final script = await MpvScripts.ensureCurrent(
      p.join(sessionDirectory.path, 'iso-current.txt'),
      p.join(sessionDirectory.path, 'iso-command.txt'),
      sessionDirectory,
      sessionId: p.basename(sessionDirectory.path),
      reportedPath: sessionKey,
    );
    final menuScript = config.menuProgressSharingEnabled
        ? await writeProgressScript(sessionDirectory)
        : null;
    return buildArgs(
      config,
      endpoint: endpoint,
      ipcPipeName: ipcPipeName,
      scriptPath: script,
    )..insertAll(0, [if (menuScript != null) '--script=$menuScript']);
  }

  static Future<String> writeProgressScript(Directory directory) async {
    final script = File(p.join(directory.path, 'menu-progress.lua'));
    final journal = jsonEncode(p.join(directory.path, 'menu-progress.jsonl'));
    await script.writeAsString('''
local mp = require 'mp'
local utils = require 'mp.utils'
local journal = $journal
local initial_edition = nil
local menu_observed = false
local last = nil
local recorded = false
local function sample()
    local menu = mp.get_property_native('disc-menu-active')
    if menu == true then menu_observed = true; return end
    local edition = mp.get_property_number('current-edition', -1)
    local editions = mp.get_property_number('editions', -1)
    if menu ~= false or edition < 0 or edition >= editions then return end
    initial_edition = initial_edition or edition
    -- 与本地菜单一致：菜单出现或离开初始 Title 后才记录正片。
    if not menu_observed and edition == initial_edition then return end
    local position = mp.get_property_number('time-pos', -1)
    local duration = mp.get_property_number('duration', -1)
    if position < 0 or duration <= 0 then return end
    local entry = (mp.get_property_native('edition-list') or {})[edition + 1]
    local mpls = entry and entry.title and entry.title:match('%((%d%d%d%d%d)%.mpls%)')
    local hours, minutes, seconds
    if entry and entry.title then
        hours, minutes, seconds = entry.title:match('%((%d+):(%d%d):(%d%d%.%d+)%)')
    end
    local title_duration = hours and (tonumber(hours) * 3600 + tonumber(minutes) * 60 + tonumber(seconds))
    -- 切换期间 edition 与时长可能尚未同步，不能把菜单背景记入旧 Title。
    if not mpls or not title_duration or math.abs(title_duration - duration) > 0.01 then return end
    last = {edition=edition, editions=editions, mplsId=mpls, position=position,
            duration=duration, completed=position / duration >= 0.99}
end
local function append()
    if not last then return end
    local file = assert(io.open(journal, 'ab'))
    file:write(utils.format_json(last), '\\n')
    file:close()
end
mp.observe_property('disc-menu-active', 'bool', function(_, value)
    if value then menu_observed = true end
end)
mp.register_event('playback-restart', sample)
mp.observe_property('time-pos', 'number', sample)
mp.add_periodic_timer(1, function() sample(); append() end)
mp.register_event('end-file', function()
    -- end-file 后属性可能已卸载，保留最后一个有效 Title 快照。
    append()
    recorded = true
end)
mp.register_event('shutdown', function()
    if not recorded then sample(); append() end
end)
''', flush: true);
    return script.path;
  }

  Future<void> waitUntilReady({
    required Directory sessionDirectory,
    required Duration timeout,
    required Future<bool> Function() playerExited,
    required bool Function() cancelled,
  }) async {
    final clock = Stopwatch()..start();
    final status = File(p.join(sessionDirectory.path, 'iso-current.txt'));
    while (!cancelled() && clock.elapsed < timeout) {
      if (await playerExited()) {
        throw AppException.process('远程蓝光菜单播放器启动失败，请返回标题模式');
      }
      if (await status.exists()) {
        final lines = await status.readAsLines();
        if (lines.length >= 21 && (lines[18] == '0' || lines[18] == '1')) {
          return;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!cancelled()) {
      throw AppException.process('远程蓝光菜单播放器启动失败，请返回标题模式');
    }
  }

  static List<String> buildArgs(
    PlayerConfig config, {
    required Uri endpoint,
    required String ipcPipeName,
    required String scriptPath,
  }) {
    if (endpoint.scheme != 'file' ||
        endpoint.host.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        endpoint.toFilePath(windows: true) !=
            p.join(p.dirname(scriptPath), 'disc', 'disc.iso')) {
      throw ArgumentError('Invalid mounted disc path');
    }
    return [
      ...LocalDiscPlaybackService.filterUserArgs(
        filterIsoPlayerArguments(config.args),
      ).where(
        (arg) => !RegExp(
          r'^--(?:no-)?(?:bluray-|cache|demuxer|stream|start|end|length|log-file|resume|save-position|watch-later|video-latency-hacks)',
        ).hasMatch(arg),
      ),
      '--idle=no',
      '--keep-open=no',
      '--resume-playback=no',
      '--save-position-on-quit=no',
      '--cache=yes',
      '--cache-on-disk=no',
      '--demuxer-max-bytes=16777216',
      '--demuxer-max-back-bytes=0',
      '--video-latency-hacks=no',
      '--input-ipc-server=$ipcPipeName',
      '--script=$scriptPath',
      '--bluray-device=${endpoint.toFilePath(windows: true)}',
      'bd://menu',
    ];
  }
}
