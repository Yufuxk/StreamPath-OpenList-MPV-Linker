import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/core/utils/app_paths.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/connection_config.dart';
import 'package:streampath/data/models/media_entry.dart';
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/domain/services/external_player_service.dart';
import 'package:streampath/features/cache_control/cache_policy_service.dart';
import 'package:streampath/features/cache_control/models/cache_policy_config.dart';
import 'package:streampath/features/cache_control/models/cache_policy_result.dart';
import 'package:streampath/features/cache_control/models/cache_policy_session_state.dart';
import 'package:streampath/features/cache_control/monitor/playback_monitor.dart';
import 'package:streampath/features/cache_control/providers/media_probe.dart';
import 'package:streampath/features/cache_control/providers/system_memory_provider.dart';
import 'package:streampath/features/cache_control/store/cache_policy_config_store.dart';
import 'package:streampath/features/cache_control/store/media_metadata_store.dart';

/// 缓存控制系统与 ExternalPlayerService 的集成测试。
///
/// 覆盖三态：正常注入 / 用户手动配置时跳过 / 异常降级不阻断播放。
/// 用「存在且立即退出」的程序替代真实 mpv（与 external_player_launch_test
/// 相同策略），不真启动播放器。
void main() {
  final exe = Platform.isWindows
      ? r'C:\Windows\System32\where.exe'
      : '/bin/true';

  /// 轮询等待条件成立（最多 [timeout]，每 200ms 检查一次）。
  ///
  /// 默认超时放宽到 20s：监控侧为 1s/轮的文件轮询，全量测试并发
  /// （多文件同时 launch fake 播放器 + tasklist 探活）时 CPU 争用会
  /// 拖慢轮询节奏，8s 偶发超时（串行运行稳定全绿，纯时序问题）。
  Future<void> waitUntil(
    bool Function() condition, {
    String? reason,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    fail('等待超时${reason != null ? '：$reason' : ''}');
  }

  Future<String> createFakeMpv(Directory dir, {bool keepAlive = false}) async {
    final fakeMpv = File(
      '${dir.path}${Platform.pathSeparator}'
      'mpv-test${Platform.isWindows ? '.exe' : ''}',
    );
    final source = keepAlive
        ? (Platform.isWindows ? r'C:\Windows\System32\cmd.exe' : '/bin/sh')
        : exe;
    await File(source).copy(fakeMpv.path);
    return fakeMpv.path;
  }

  Future<CachePolicyService> cacheService(
    Directory dir,
    CachePolicyConfig config, {
    PlaybackMonitor Function()? monitorFactory,
  }) async {
    final store = CachePolicyConfigStore.forPath(
      '${dir.path}${Platform.pathSeparator}cache_policy.json',
    );
    await store.save(config);
    return CachePolicyService(
      store: store,
      mediaProbe: const _FakeProbe(),
      memoryProvider: const NullMemoryProvider(),
      metadataStore: MediaMetadataStore.forPath(
        '${dir.path}${Platform.pathSeparator}media_metadata.json',
      ),
      monitorFactory: monitorFactory,
      logger: (message) {},
    );
  }

  Future<(ExternalPlayerService, Directory)> makeService({
    CachePolicyProvider? cachePolicy,
    CachePolicyConfig? cacheConfig,
    PlaybackMonitor Function()? monitorFactory,
    void Function(String message)? onCacheWarning,
    List<String> playerArgs = const [
      '--sub-file={subfile}',
      '{url}',
      '--start={start}',
    ],
    bool keepAlive = false,
    List<String>? cacheLogs,
    MpvCacheIpcUpdater? cacheIpcUpdater,
  }) async {
    final dir = Directory.systemTemp.createTempSync('sp_cache_launch_');
    final resolvedPolicy =
        cachePolicy ??
        (cacheConfig != null
            ? await cacheService(
                dir,
                cacheConfig,
                monitorFactory: monitorFactory,
              )
            : null);
    final fakeMpv = await createFakeMpv(dir, keepAlive: keepAlive);
    final effectivePlayerArgs = keepAlive
        ? (Platform.isWindows
              ? const ['/c', 'ping -n 6 127.0.0.1 >nul & rem {url}']
              : const ['-c', 'sleep 5 # {url}'])
        : playerArgs;
    final cfg = StreamPathConfigStore.forPath(
      '${dir.path}${Platform.pathSeparator}cfg.json',
    );
    await cfg.save(
      StreamPathConfig.fromParts(
        PlayerConfig(
          name: 'mpv',
          executable: fakeMpv,
          args: effectivePlayerArgs,
          subtitleInjectionEnabled: false,
          subtitleAutoSelectEnabled: false,
          resumeEnabled: false,
        ),
        const ConnectionConfig(),
      ),
    );
    return (
      ExternalPlayerService(
        configStore: cfg,
        watchLaterDir: Directory('${dir.path}${Platform.pathSeparator}wl'),
        cachePolicy: resolvedPolicy,
        onCacheWarning: onCacheWarning,
        cacheLogger: cacheLogs?.add,
        cacheIpcUpdater: cacheIpcUpdater,
      ),
      dir,
    );
  }

  bool hasCacheArgs(List<String> args) =>
      args.any((a) => a.startsWith('--cache') || a.startsWith('--demuxer-max'));

  group('缓存参数注入集成', () {
    test('未接入缓存系统时参数与原来完全一致（零影响）', () async {
      final (service, _) = await makeService();
      final result = await service.launch(
        entries: const [MediaEntry(url: 'http://127.0.0.1:1/dav/01.mp4')],
      );
      expect(hasCacheArgs(result.args), isFalse);
      expect(result.args, contains('http://127.0.0.1:1/dav/01.mp4'));
    });

    test(
      '默认配置下注入缓存参数（--cache=yes / --cache-secs / --demuxer-max-bytes）',
      () async {
        final (service, _) = await makeService(
          cacheConfig: CachePolicyConfig.defaults(),
        );
        final result = await service.launch(
          entries: const [MediaEntry(url: 'http://127.0.0.1:1/dav/01.mp4')],
        );
        expect(hasCacheArgs(result.args), isTrue);
        expect(result.args, contains('--cache=yes'));
        expect(result.args, contains('--cache-secs=120'));
        // 探测假域名失败降级 + 内存未知：码率未知 → 上限 = 兜底预算 1GiB。
        expect(
          result.args,
          contains('--demuxer-max-bytes=${1024 * 1024 * 1024}'),
        );
        // 注入参数应位于 URL 之后（mpv 后者覆盖前者）。
        final urlIndex = result.args.indexOf('http://127.0.0.1:1/dav/01.mp4');
        final cacheIndex = result.args.indexOf('--cache=yes');
        expect(cacheIndex, greaterThan(urlIndex));
      },
    );

    test('用户已手动配置缓存参数时默认跳过注入（尊重手动配置）', () async {
      final (service, _) = await makeService(
        playerArgs: const ['--cache-secs=999', '{url}'],
        cacheConfig: CachePolicyConfig.defaults(),
      );
      final result = await service.launch(
        entries: const [MediaEntry(url: 'http://127.0.0.1:1/dav/01.mp4')],
      );
      expect(hasCacheArgs(result.args), isTrue);
      expect(result.args, contains('--cache-secs=999'));
      // 未注入新的 --cache=yes / demuxer 参数。
      expect(result.args, isNot(contains('--cache=yes')));
      expect(
        result.args.any((a) => a.startsWith('--demuxer-max-bytes=')),
        isFalse,
      );
    });

    test('overrideUserCacheArgs=true 时覆盖注入（追加在末尾）', () async {
      final (service, _) = await makeService(
        playerArgs: const ['--cache-secs=999', '{url}'],
        cacheConfig: const CachePolicyConfig(overrideUserCacheArgs: true),
      );
      final result = await service.launch(
        entries: const [MediaEntry(url: 'http://127.0.0.1:1/dav/01.mp4')],
      );
      expect(result.args, contains('--cache=yes'));
      expect(result.args, contains('--cache-secs=120'));
      // 注入的 120 在用户 999 之后（后者覆盖前者）。
      final userIndex = result.args.indexOf('--cache-secs=999');
      final injectedIndex = result.args.indexOf('--cache-secs=120');
      expect(injectedIndex, greaterThan(userIndex));
    });

    test('enabled=false 时跳过注入', () async {
      final (service, _) = await makeService(
        cacheConfig: const CachePolicyConfig(enabled: false),
      );
      final result = await service.launch(
        entries: const [MediaEntry(url: 'http://127.0.0.1:1/dav/01.mp4')],
      );
      expect(hasCacheArgs(result.args), isFalse);
    });

    test('非 mpv 播放器不受缓存系统影响', () async {
      final dir = Directory.systemTemp.createTempSync('sp_cache_other_');
      final cfg = StreamPathConfigStore.forPath(
        '${dir.path}${Platform.pathSeparator}cfg.json',
      );
      await cfg.save(
        StreamPathConfig.fromParts(
          PlayerConfig(
            name: 'PotPlayer',
            executable: exe,
            args: const ['{url}'],
            subtitleInjectionEnabled: false,
            subtitleAutoSelectEnabled: false,
            resumeEnabled: false,
          ),
          const ConnectionConfig(),
        ),
      );
      final cacheServiceInstance = await cacheService(
        dir,
        CachePolicyConfig.defaults(),
      );
      final service = ExternalPlayerService(
        configStore: cfg,
        watchLaterDir: Directory('${dir.path}${Platform.pathSeparator}wl'),
        cachePolicy: cacheServiceInstance,
      );
      final result = await service.launch(
        entries: const [MediaEntry(url: 'http://127.0.0.1:1/dav/01.mp4')],
      );
      expect(hasCacheArgs(result.args), isFalse);
    });

    test('缓存服务抛异常时播放不中断且无缓存参数', () async {
      final (service, _) = await makeService(cachePolicy: _ThrowingProvider());
      final result = await service.launch(
        entries: const [MediaEntry(url: 'http://127.0.0.1:1/dav/01.mp4')],
      );
      expect(hasCacheArgs(result.args), isFalse);
      expect(result.args, contains('http://127.0.0.1:1/dav/01.mp4'));
    });

    test('launch 后接线 onPolicyReady：未登记 URL 与已退出会话均静默', () async {
      final dir = Directory.systemTemp.createTempSync('sp_cache_hook_');
      final fakeMpv = await (() async {
        final f = File(
          '${dir.path}${Platform.pathSeparator}'
          'mpv-hook${Platform.isWindows ? '.exe' : ''}',
        );
        await File(exe).copy(f.path);
        return f.path;
      })();
      final cfg = StreamPathConfigStore.forPath(
        '${dir.path}${Platform.pathSeparator}cfg.json',
      );
      await cfg.save(
        StreamPathConfig.fromParts(
          PlayerConfig(
            name: 'mpv',
            executable: fakeMpv,
            args: const ['{url}'],
            subtitleInjectionEnabled: false,
            subtitleAutoSelectEnabled: false,
            resumeEnabled: false,
          ),
          const ConnectionConfig(),
        ),
      );
      final provider = _RecordingProvider();
      final service = ExternalPlayerService(
        configStore: cfg,
        watchLaterDir: Directory('${dir.path}${Platform.pathSeparator}wl'),
        cachePolicy: provider,
      );

      const playUrl = 'http://127.0.0.1:1/dav/hook.mp4';
      await service.launch(entries: const [MediaEntry(url: playUrl)]);

      expect(provider.onPolicyReady, isNotNull, reason: 'launch 后应接线回调');

      const result = CachePolicyResult(
        skipped: false,
        cacheSecs: 120,
        demuxerMaxBytes: 123456,
      );
      // 未登记的 URL：静默跳过（不崩溃）。
      provider.onPolicyReady!('session_none', 'http://unknown/url', result);
      // 已登记 URL 但会话已退出（假 mpv 立即退出）：isPlayerRunning=false，
      // 静默跳过，不尝试 IPC。
      provider.onPolicyReady!('session_1', playUrl, result);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // 静默降级：无异常传播即通过（此处若抛异常测试将失败）。
    });

    test('动态缓存 IPC 成功后输出播放器确认值，而不是只输出策略目标', () async {
      final logs = <String>[];
      final updates = <Map<String, Object?>>[];
      final provider = _RecordingProvider(
        fixedResult: const CachePolicyResult(
          skipped: false,
          cacheSecs: 240,
          demuxerMaxBytes: 1258670080,
          memoryBudgetBytes: 1258670080,
          bitrateMbps: 56,
        ),
      );
      final (service, _) = await makeService(
        cachePolicy: provider,
        keepAlive: true,
        cacheLogs: logs,
        cacheIpcUpdater:
            (
              pipeName, {
              required demuxerMaxBytes,
              required cacheSecs,
              cacheEnabled,
              seekableCacheEnabled,
            }) async {
              updates.add(<String, Object?>{
                'cacheSecs': cacheSecs,
                'demuxerMaxBytes': demuxerMaxBytes,
              });
              return true;
            },
      );
      try {
        await service.launch(
          entries: const [
            MediaEntry(url: 'http://127.0.0.1:1/dav/ipc-log.mkv'),
          ],
          sessionId: 'session_ipc_log',
        );
        expect(provider.adjustmentCallback, isNotNull, reason: '动态监控回调应完成接线');

        provider.adjustmentCallback?.call(
          const CacheAdjustment(
            cacheSecs: 540,
            demuxerMaxBytes: 1258670080,
            reason: 'diagnostic test',
          ),
        );
        await waitUntil(
          () => updates.any((item) => item['cacheSecs'] == 540),
          reason: '动态 540s 目标应通过 IPC',
        );
        await waitUntil(
          () => logs.any((line) => line.contains('IPC cache update applied')),
          reason: 'mpv 确认后应输出 applied 日志',
        );

        final output = logs.join('\n');
        expect(output, contains('session=session_ipc_log'));
        expect(output, contains('cache-secs=540'));
        expect(output, contains('demuxer-max-bytes=1258670080 (1.17GiB)'));
      } finally {
        await service.terminateSession('session_ipc_log');
      }
    });

    test('动态缓存 IPC 连续失败时明确说明播放器可能保留旧值', () async {
      final logs = <String>[];
      var attempts = 0;
      final provider = _RecordingProvider(
        fixedResult: const CachePolicyResult(
          skipped: false,
          cacheSecs: 120,
          demuxerMaxBytes: 1024 * 1024 * 1024,
        ),
      );
      final (service, _) = await makeService(
        cachePolicy: provider,
        keepAlive: true,
        cacheLogs: logs,
        cacheIpcUpdater:
            (
              pipeName, {
              required demuxerMaxBytes,
              required cacheSecs,
              cacheEnabled,
              seekableCacheEnabled,
            }) async {
              attempts++;
              return false;
            },
      );
      try {
        await service.launch(
          entries: const [
            MediaEntry(url: 'http://127.0.0.1:1/dav/ipc-fail.mkv'),
          ],
          sessionId: 'session_ipc_fail',
        );
        expect(provider.adjustmentCallback, isNotNull, reason: '动态监控回调应完成接线');
        provider.adjustmentCallback?.call(
          const CacheAdjustment(
            cacheSecs: 540,
            demuxerMaxBytes: 1024 * 1024 * 1024,
            reason: 'diagnostic failure test',
          ),
        );
        await waitUntil(
          () => logs.any(
            (line) => line.contains('IPC cache update failed after 3 attempts'),
          ),
          reason: '连续失败后应输出最终失败诊断',
        );
        expect(attempts, 3);
        expect(logs.join('\n'), contains('player may keep previous values'));
      } finally {
        await service.terminateSession('session_ipc_fail');
      }
    });

    test('mpv 打开后监控状态文件时长并上报 recordDuration', () async {
      final durations = <double>[];
      final provider = _RecordingProvider(
        durations: durations,
        fixedResult: const CachePolicyResult(
          skipped: false,
          cacheSecs: 120,
          demuxerMaxBytes: 1000000,
        ),
      );
      final (service, _) = await makeService(
        cachePolicy: provider,
        keepAlive: true,
      );
      final dataDir = await AppPaths.cacheDirectory();
      final statusFile = File(
        p.join(
          dataDir.path,
          ExternalPlayerService.sessionStatusFileName('session_dur'),
        ),
      );
      try {
        final result = await service.launch(
          entries: const [MediaEntry(url: 'http://127.0.0.1:1/dav/01.mkv')],
          sessionId: 'session_dur',
        );
        expect(hasCacheArgs(result.args), isTrue);
        // 模拟真实 mpv 打开 mkv 后由 lua 脚本写入的 5 行状态文件
        // （launch 之后写入 → mtime 晚于监控启动，通过新鲜度检查）。
        await statusFile.writeAsString(
          '0\nhttp://127.0.0.1:1/dav/01.mkv\n0\n1.5\n100\n',
        );
        // 等待监控轮询（1s/轮）读到状态文件并上报。
        await waitUntil(
          () => durations.isNotEmpty,
          reason: '监控应读取状态文件 duration 并上报 recordDuration',
        );
        expect(durations.first, 100);
      } finally {
        if (statusFile.existsSync()) {
          await statusFile.delete();
        }
      }
    });

    test('同 URL 双会话：各自会话的监控独立启动（sessionId 正确路由）', () async {
      final monitors = <_RecordingMonitor>[];
      final (service, _) = await makeService(
        cacheConfig: CachePolicyConfig.defaults(),
        monitorFactory: () {
          final m = _RecordingMonitor();
          monitors.add(m);
          return m;
        },
      );
      // 同 URL 先后 launch 两个会话。
      await service.launch(
        entries: const [MediaEntry(url: 'http://127.0.0.1:1/dav/same.mkv')],
        sessionId: 'session_A',
      );
      await service.launch(
        entries: const [MediaEntry(url: 'http://127.0.0.1:1/dav/same.mkv')],
        sessionId: 'session_B',
      );
      // 两个会话各自启动自己的监控（实例独立、状态文件各自对应）。
      expect(monitors.length, 2, reason: '同 URL 双会话各建一个监控实例');
      expect(monitors[0].stopped, isFalse, reason: 'B 启动不得停止 A 的监控');
      expect(
        monitors[0].startedStatusFile,
        contains('session_A'),
        reason: 'A 的监控采样 A 的状态文件',
      );
      expect(
        monitors[1].startedStatusFile,
        contains('session_B'),
        reason: 'B 的监控采样 B 的状态文件',
      );
    });

    test('launch 后自动启动播放中动态监控（非 TS）', () async {
      final monitor = _RecordingMonitor();
      final (service, _) = await makeService(
        cacheConfig: CachePolicyConfig.defaults(),
        monitorFactory: () => monitor,
      );
      final result = await service.launch(
        entries: const [MediaEntry(url: 'http://127.0.0.1:1/dav/01.mkv')],
        sessionId: 'session_mon',
      );
      expect(hasCacheArgs(result.args), isTrue);
      expect(
        monitor.startedStatusFile,
        isNotNull,
        reason: 'mpv 非 TS 播放应自动启动动态监控',
      );
      expect(monitor.startedMax, greaterThan(0));
      expect(monitor.startedSecs, greaterThan(0));
      // 会话退出（fake 播放器立即退出）后应停止监控。
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(monitor.stopped, isTrue, reason: '会话退出应停止动态监控');
    });

    test('TS 起播阶段关闭缓存且禁用 seekable cache，不启动动态监控', () async {
      final monitor = _RecordingMonitor();
      final (service, _) = await makeService(
        cacheConfig: CachePolicyConfig.defaults(),
        monitorFactory: () => monitor,
      );
      final result = await service.launch(
        entries: const [MediaEntry(url: 'http://127.0.0.1:1/dav/movie.m2ts')],
        sessionId: 'session_ts',
      );
      expect(result.args, contains('--cache=no'));
      expect(result.args, contains('--demuxer-seekable-cache=no'));
      expect(result.args, contains('--rebase-start-time=yes'));
      expect(result.args, isNot(contains('--start=0')));
      expect(monitor.startedStatusFile, isNull, reason: 'TS 走直链，不监控');
    });

    test('警告消息带会话标识（同 URL 双会话 UI 可区分来源）', () async {
      final warnings = <String>[];
      // 测试直接构造，onCacheWarning 经构造参数注入。
      final (service, _) = await makeService(
        cacheConfig: CachePolicyConfig.defaults(),
        monitorFactory: () => _WarningMonitor(),
        onCacheWarning: warnings.add,
      );
      await service.launch(
        entries: const [MediaEntry(url: 'http://127.0.0.1:1/dav/warn.mkv')],
        sessionId: 'session_warn',
      );
      // _WarningMonitor.start 立即触发警告 → 闭包捕获 sessionId。
      await waitUntil(() => warnings.isNotEmpty);
      expect(
        warnings.first,
        contains('[会话 session_warn]'),
        reason: '警告消息必须带会话标识（区分来源）',
      );
      expect(warnings.first, contains('网络带宽不足以流畅播放'));
    });

    test('切集重算沿用用户手动缓存参数（userArgs 沿链路传递）', () async {
      final provider = _RecordingProvider(
        fixedResult: CachePolicyResult(
          skipped: false,
          cacheSecs: 120,
          demuxerMaxBytes: 1000000,
          fileSizeBytes: 200 * 1024 * 1024,
          bitrateMbps: 8.0,
        ),
      );
      final (service, _) = await makeService(
        cachePolicy: provider,
        // 用户模板手动配置缓存参数（首集应被尊重、跳过注入）。
        playerArgs: const ['--cache-secs=999', '{url}'],
      );
      final statusFile = File(
        p.join(
          (await AppPaths.cacheDirectory()).path,
          ExternalPlayerService.sessionStatusFileName('session_userargs'),
        ),
      );
      try {
        await service.launch(
          entries: const [MediaEntry(url: 'http://127.0.0.1:1/dav/ep01.mkv')],
          sessionId: 'session_userargs',
        );
        // 首集：用户手动参数已传入（尊重手动配置）。
        expect(
          provider.userArgCalls.single,
          contains('--cache-secs=999'),
          reason: '首集必须传入用户手动缓存参数',
        );
        // 模拟切集到第二集。
        await statusFile.writeAsString(
          '1\nhttp://127.0.0.1:1/dav/ep02.mkv\n0\n5.0\n1800\n0\n'
          '104857600\n512000\n0\n',
        );
        await waitUntil(() => provider.buildCalls >= 2, reason: '切集后应重新计算缓存参数');
        // 切集重算必须沿用用户手动参数（否则手动配置在下一集失效）。
        expect(
          provider.userArgCalls.last,
          contains('--cache-secs=999'),
          reason: '切集重算必须沿用用户手动缓存参数',
        );
      } finally {
        if (statusFile.existsSync()) {
          await statusFile.delete();
        }
      }
    });

    test('首集为 TS 时仍持续监听，切到非 TS 后重新计算正常策略', () async {
      final provider = _RecordingProvider(
        fixedResult: const CachePolicyResult(
          skipped: false,
          cacheSecs: 120,
          demuxerMaxBytes: 1000000,
          fileSizeBytes: 200 * 1024 * 1024,
          bitrateMbps: 8.0,
        ),
      );
      final (service, _) = await makeService(cachePolicy: provider);
      final statusFile = File(
        p.join(
          (await AppPaths.cacheDirectory()).path,
          ExternalPlayerService.sessionStatusFileName('session_ts_switch'),
        ),
      );
      try {
        await service.launch(
          entries: const [MediaEntry(url: 'http://127.0.0.1:1/dav/ep01.m2ts')],
          sessionId: 'session_ts_switch',
        );
        final callsBefore = provider.buildCalls;
        await statusFile.writeAsString(
          '1\nhttp://127.0.0.1:1/dav/ep02.mkv\n0\n5.0\n1800\n0\n'
          '104857600\n512000\n0\ndiag\n0\n0\n0\n1920x1080\n',
        );
        await waitUntil(
          () => provider.buildCalls > callsBefore,
          reason: '首集 TS 不能关闭唯一的切集 watcher',
        );
      } finally {
        if (statusFile.existsSync()) await statusFile.delete();
      }
    });

    test('播放列表相同 URL 但 playlist-pos 改变时仍识别为新一集', () async {
      final provider = _RecordingProvider(
        fixedResult: const CachePolicyResult(
          skipped: false,
          cacheSecs: 120,
          demuxerMaxBytes: 1000000,
        ),
      );
      final (service, _) = await makeService(cachePolicy: provider);
      final statusFile = File(
        p.join(
          (await AppPaths.cacheDirectory()).path,
          ExternalPlayerService.sessionStatusFileName('session_duplicate'),
        ),
      );
      try {
        const sameUrl = 'http://127.0.0.1:1/dav/repeat.mkv';
        await service.launch(
          entries: const [
            MediaEntry(url: sameUrl),
            MediaEntry(url: sameUrl),
          ],
          sessionId: 'session_duplicate',
        );
        final callsBefore = provider.buildCalls;
        await statusFile.writeAsString(
          '1\n$sameUrl\n0\n5.0\n1800\n0\n104857600\n512000\n0\n'
          'diag\n0\n0\n0\n1920x1080\n',
        );
        await waitUntil(
          () => provider.buildCalls > callsBefore,
          reason: '同 URL 重复条目必须用 playlist-pos 区分',
        );
      } finally {
        if (statusFile.existsSync()) await statusFile.delete();
      }
    });

    test('播放列表切集：重新计算缓存参数、更新监控基准并关联新集时长', () async {
      final durations = <double>[];
      final urls = <String>[];
      final monitorUrls = <String>[];
      final provider = _RecordingProvider(
        durations: durations,
        recordedUrls: urls,
        monitorCalls: monitorUrls,
        fixedResult: CachePolicyResult(
          skipped: false,
          cacheSecs: 120,
          demuxerMaxBytes: 1000000,
          fileSizeBytes: 200 * 1024 * 1024,
          bitrateMbps: 8.0,
        ),
      );
      final (service, _) = await makeService(cachePolicy: provider);
      final statusFile = File(
        p.join(
          (await AppPaths.cacheDirectory()).path,
          ExternalPlayerService.sessionStatusFileName('session_switch'),
        ),
      );
      try {
        await service.launch(
          entries: const [MediaEntry(url: 'http://127.0.0.1:1/dav/ep01.mkv')],
          sessionId: 'session_switch',
        );
        final callsBefore = provider.buildCalls;
        // 模拟 mpv 播完第一集后自动切到第二集：状态文件 path 行变化。
        await statusFile.writeAsString(
          '1\nhttp://127.0.0.1:1/dav/ep02.mkv\n0\n5.0\n1800\n0\n'
          '104857600\n512000\n0\n',
        );
        // 轮询等待（最多 8s）监控感知切集（并发负载下轮询节奏不定）。
        await waitUntil(
          () => provider.buildCalls > callsBefore,
          reason: '切集后应重新计算缓存参数',
        );
        // 等待后续关联/基准更新完成。
        await waitUntil(
          () =>
              urls.any((u) => u.contains('ep02.mkv')) &&
              monitorUrls.any((u) => u.contains('ep02.mkv')),
          reason: '切集后时长应关联新集、监控基准应更新到新集',
        );
      } finally {
        if (statusFile.existsSync()) {
          await statusFile.delete();
        }
      }
    });
  });
}

/// 故意抛异常的缓存提供者（验证降级路径）。
class _ThrowingProvider implements CachePolicyProvider {
  @override
  Future<List<String>> buildCacheArgs({
    required String sessionId,
    required String url,
    String? authHeader,
    List<String> userArgs = const [],
    bool runtimeTs = false,
  }) async {
    throw StateError('缓存系统内部故障');
  }

  @override
  void Function(String sessionId, String url, CachePolicyResult result)?
  onPolicyReady;

  @override
  void recordDuration(
    String sessionId,
    String url,
    double durationSec, {
    String? resolution,
  }) {}

  @override
  void startMonitor({
    required String sessionId,
    required String url,
    required String statusFilePath,
    required int initialDemuxerMaxBytes,
    required int initialCacheSecs,
    int? fileSizeBytes,
    double? bitrateMbps,
    int? memoryBudgetBytes,
    int? minCacheSecs,
    int? maxCacheSecs,
    bool fullCache = false,
    void Function(CacheAdjustment adjustment)? onAdjustment,
    void Function(String message)? onWarning,
  }) {}

  @override
  void stopMonitor(String sessionId, {bool clearSession = false}) {}

  @override
  CachePolicyResult? lastResultFor(String url) => null;

  @override
  CachePolicySessionState? sessionState(String sessionId) => null;

  @override
  Map<String, Object?> diagnosticsSnapshot() => const <String, Object?>{};
}

/// 记录回调接线与调用次数的提供者（验证 ExternalPlayerService 接线）。
class _RecordingProvider implements CachePolicyProvider {
  _RecordingProvider({
    this.durations,
    this.recordedUrls,
    this.monitorCalls,
    this.fixedResult,
  });

  /// 收到的时长上报记录。
  final List<double>? durations;

  /// recordDuration 收到的 URL（切集关联验证用）。
  final List<String>? recordedUrls;

  /// startMonitor 收到的 URL（切集后监控基准更新验证用）。
  final List<String>? monitorCalls;

  /// buildCacheArgs 调用次数（切集重算验证用）。
  int buildCalls = 0;

  /// 每次 buildCacheArgs 收到的 userArgs（切集沿用用户参数验证用）。
  final List<List<String>> userArgCalls = [];

  /// 返回给 lastResultFor 的固定结果（null 表示不提供）。
  final CachePolicyResult? fixedResult;
  final Map<String, CachePolicySessionState> _states = {};
  void Function(CacheAdjustment adjustment)? adjustmentCallback;

  @override
  Future<List<String>> buildCacheArgs({
    required String sessionId,
    required String url,
    String? authHeader,
    List<String> userArgs = const [],
    bool runtimeTs = false,
  }) async {
    buildCalls++;
    userArgCalls.add(userArgs);
    final result = fixedResult;
    _states[sessionId] = CachePolicySessionState(
      sessionId: sessionId,
      url: url,
      injected: result != null,
      result: result,
    );
    return const [
      '--cache=yes',
      '--cache-secs=120',
      '--demuxer-max-bytes=1000000',
    ];
  }

  @override
  void Function(String sessionId, String url, CachePolicyResult result)?
  onPolicyReady;

  @override
  void recordDuration(
    String sessionId,
    String url,
    double durationSec, {
    String? resolution,
  }) {
    durations?.add(durationSec);
    recordedUrls?.add(url);
  }

  @override
  void startMonitor({
    required String sessionId,
    required String url,
    required String statusFilePath,
    required int initialDemuxerMaxBytes,
    required int initialCacheSecs,
    int? fileSizeBytes,
    double? bitrateMbps,
    int? memoryBudgetBytes,
    int? minCacheSecs,
    int? maxCacheSecs,
    bool fullCache = false,
    void Function(CacheAdjustment adjustment)? onAdjustment,
    void Function(String message)? onWarning,
  }) {
    monitorCalls?.add(url);
    adjustmentCallback = onAdjustment;
  }

  @override
  void stopMonitor(String sessionId, {bool clearSession = false}) {
    if (clearSession) _states.remove(sessionId);
  }

  @override
  CachePolicyResult? lastResultFor(String url) => fixedResult;

  @override
  CachePolicySessionState? sessionState(String sessionId) => _states[sessionId];

  @override
  Map<String, Object?> diagnosticsSnapshot() => const <String, Object?>{};
}

/// 记录 start/stop 调用的监控 fake（验证 ExternalPlayerService 接线）。
class _RecordingMonitor extends PlaybackMonitor {
  _RecordingMonitor() : super(memoryProvider: const NullMemoryProvider());

  String? startedStatusFile;
  int? startedMax;
  int? startedSecs;
  bool stopped = false;

  @override
  void start({
    required String statusFilePath,
    required int initialDemuxerMaxBytes,
    required int initialCacheSecs,
    int? fileSizeBytes,
    double? bitrateMbps,
    int? memoryBudgetBytes,
    int? minCacheSecs,
    int? maxCacheSecs,
    bool fullCache = false,
    void Function(CacheAdjustment adjustment)? onAdjustment,
    void Function(String message)? onWarning,
  }) {
    startedStatusFile = statusFilePath;
    startedMax = initialDemuxerMaxBytes;
    startedSecs = initialCacheSecs;
  }

  @override
  void stop() {
    stopped = true;
  }
}

/// 监控 fake：start 时立即触发一次警告（验证警告消息带会话标识）。
class _WarningMonitor extends PlaybackMonitor {
  _WarningMonitor() : super(memoryProvider: const NullMemoryProvider());

  @override
  void start({
    required String statusFilePath,
    required int initialDemuxerMaxBytes,
    required int initialCacheSecs,
    int? fileSizeBytes,
    double? bitrateMbps,
    int? memoryBudgetBytes,
    int? minCacheSecs,
    int? maxCacheSecs,
    bool fullCache = false,
    void Function(CacheAdjustment adjustment)? onAdjustment,
    void Function(String message)? onWarning,
  }) {
    onWarning?.call('网络带宽不足以流畅播放');
  }

  @override
  void stop() {}
}

/// fake 媒体探测器：始终报告探测失败（对应真实场景中 HEAD 失败降级）。
class _FakeProbe implements MediaProbe {
  const _FakeProbe();

  @override
  Future<MediaProbeResult> probeContentLength({
    required String url,
    String? authHeader,
  }) async {
    return const MediaProbeResult(error: 'fake 探测失败');
  }
}
