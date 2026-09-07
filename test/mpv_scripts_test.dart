import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/domain/services/mpv_scripts.dart';

/// 状态上报脚本（ensureCurrent）生成内容验证。
///
/// 验证「cache-idle 属性 0.41 兼容读取」不回归：
/// mpv 0.41 将该属性改名为 demuxer-cache-idle，旧名返回 nil →
/// 监控侧「全缓存/缓存满」判定失效 → 缓存速度归 0 时误报网络不足。
/// 生成脚本必须优先读新名、回退旧名，且诊断行携带来源。
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('mpv_scripts_');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test(
    'ensureCurrent 脚本包含 demuxer-cache-idle（0.41 新名）优先读取与 cache-idle 回退',
    () async {
      final statusPath = '${dir.path}${Platform.pathSeparator}status.txt';
      final commandPath = '${dir.path}${Platform.pathSeparator}command.txt';
      final scriptPath = await MpvScripts.ensureCurrent(
        statusPath,
        commandPath,
        dir,
        sessionId: 'test',
      );
      final script = await File(scriptPath).readAsString();
      // 0.41+ 新属性名优先。
      expect(script, contains('mp.get_property("demuxer-cache-idle", nil)'));
      // 旧版 mpv 回退链（新名为 nil 时读旧名）。
      expect(script, contains('mp.get_property("cache-idle", nil)'));
      // 回退分支：仅在新名返回 nil 时执行。
      expect(script, contains('if idle_raw == nil then'));
      // 诊断行携带 idle 来源（排障用）。
      expect(script, contains('idle_src .. "|" .. tostring(idle_raw)'));
    },
  );

  test('状态脚本上报真实卡顿、缓存范围、分辨率并在切集时清空旧进度', () async {
    final scriptPath = await MpvScripts.ensureCurrent(
      '${dir.path}${Platform.pathSeparator}status.txt',
      '${dir.path}${Platform.pathSeparator}command.txt',
      dir,
      sessionId: 'fields',
    );
    final script = await File(scriptPath).readAsString();

    expect(script, contains('get_property("paused-for-cache", nil)'));
    expect(script, contains('cstate["bof-cached"]'));
    expect(script, contains('cstate["eof-cached"]'));
    expect(script, contains('get_property_number("width", -1)'));
    expect(script, contains('get_property_number("height", -1)'));
    expect(script, contains('get_property_number("playlist-pos", -1)'));
    expect(script, contains('get_property_bool("seeking", false)'));
    expect(script, contains('restart_serial = restart_serial + 1'));
    expect(
      script,
      contains('get_property_number("demuxer-cache-duration", -1)'),
    );
    expect(script, contains('cstate["fw-bytes"]'));
    expect(script, contains('cstate["total-bytes"]'));
    expect(script, contains('get_property("disc-menu-active", nil)'));
    expect(script, contains('get_property_number("current-edition", -1)'));
    expect(script, contains('get_property_number("editions", -1)'));
    expect(script, contains('tostring(forward_cache_bytes)'));
    expect(script, contains('tostring(total_cache_bytes)'));
    expect(script, contains('last_time_pos = -1'));
    expect(script, contains('last_duration = -1'));
  });

  test('idle 标记携带最后播放项与本次 launch epoch', () async {
    final scriptPath = await MpvScripts.ensureCurrent(
      '${dir.path}${Platform.pathSeparator}status.txt',
      '${dir.path}${Platform.pathSeparator}command.txt',
      dir,
      sessionId: 'idle-owned',
      launchEpoch: 'epoch-idle-owned',
    );
    final script = await File(scriptPath).readAsString();

    expect(
      script,
      contains(
        'f:write("-1\\n" .. tostring(last_playlist_pos) .. '
        '"\\n" .. EPOCH)',
      ),
    );
  });

  test('shutdown 只写必要进度并跳过网络缓存诊断', () async {
    final scriptPath = await MpvScripts.ensureCurrent(
      '${dir.path}${Platform.pathSeparator}status.txt',
      '${dir.path}${Platform.pathSeparator}command.txt',
      dir,
      sessionId: 'shutdown-fast',
    );
    final script = await File(scriptPath).readAsString();

    expect(
      script,
      contains(
        'local function write_status(use_cached_progress, skip_diagnostics)',
      ),
    );
    expect(script, contains('if not skip_diagnostics then'));
    expect(script, contains('mp.register_event("shutdown", function()'));
    expect(script, contains('write_status(true, true)'));
    expect(script, contains('local speed_src = "shutdown-fast"'));
  });

  test('逐媒体日志区分 EOF 完成、普通退出和 seek 到 0 秒', () async {
    final progressPath = '${dir.path}${Platform.pathSeparator}progress.jsonl';
    final scriptPath = await MpvScripts.ensureCurrent(
      '${dir.path}${Platform.pathSeparator}status.txt',
      '${dir.path}${Platform.pathSeparator}command.txt',
      dir,
      sessionId: 'progress',
      progressFile: progressPath,
    );
    final script = await File(scriptPath).readAsString();

    expect(script, contains('local PROGRESS ='));
    expect(
      script,
      contains('local function append_progress(outcome, reason, file_error)'),
    );
    expect(script, contains('mp.register_event("start-file"'));
    expect(script, contains('mp.register_event("playback-restart"'));
    expect(script, contains('mp.register_event("end-file"'));
    expect(script, contains('reason == "eof" and "completed" or "position"'));
    expect(script, contains('event["file_error"] or event["error"]'));
    expect(script, contains('record["reason"] = reason'));
    expect(script, contains('append_progress("position", "shutdown", nil)'));
    expect(script, contains(progressPath.replaceAll('\\', '\\\\')));
  });

  test('缓冲临时播放点排除起播阶段并在健康播放后清除', () async {
    final scriptPath = await MpvScripts.ensureCurrent(
      '${dir.path}${Platform.pathSeparator}status.txt',
      '${dir.path}${Platform.pathSeparator}command.txt',
      dir,
      sessionId: 'temporary-progress',
    );
    final script = await File(scriptPath).readAsString();

    expect(script, contains('checkpoint_armed_at = mp.get_time() + 5'));
    expect(script, contains('append_progress("temporary_checkpoint"'));
    expect(script, contains('append_progress("temporary_cleared"'));
    expect(script, contains('mp.observe_property("paused-for-cache"'));
    expect(script, contains('if not was_stalling and last_time_pos > 0 then'));
    expect(script, contains('now - healthy_since >= 5'));
    expect(script, contains('last_time_pos / last_duration >= 0.99'));
  });

  test('状态脚本可用稳定设备路径替代 bd 菜单入口作为进度键', () async {
    final scriptPath = await MpvScripts.ensureCurrent(
      '${dir.path}${Platform.pathSeparator}status.txt',
      '${dir.path}${Platform.pathSeparator}command.txt',
      dir,
      sessionId: 'local-disc',
      reportedPath: r'C:\Media\disc.iso',
    );
    final script = await File(scriptPath).readAsString();

    expect(script, contains(r'C:\\Media\\disc.iso'));
    expect(
      script,
      contains(
        'REPORTED_PATH ~= "" and REPORTED_PATH or '
        'mp.get_property("path", "")',
      ),
    );
  });
}
