import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/features/cache_control/cache_policy_service.dart';
import 'package:streampath/features/cache_control/engine/cache_policy_engine.dart';
import 'package:streampath/features/cache_control/models/cache_policy_config.dart';
import 'package:streampath/features/cache_control/models/cache_policy_result.dart';
import 'package:streampath/features/cache_control/models/media_metadata.dart';
import 'package:streampath/features/cache_control/monitor/playback_monitor.dart';
import 'package:streampath/features/cache_control/providers/media_probe.dart';
import 'package:streampath/features/cache_control/providers/system_memory_provider.dart';
import 'package:streampath/features/cache_control/store/cache_policy_config_store.dart';
import 'package:streampath/features/cache_control/store/media_metadata_store.dart';

/// 缓存门面诊断日志测试：验证 [CachePolicyService] 在控制台输出
/// 配置/探测/决策/注入参数等关键信息（logger 可注入收集）。
void main() {
  late Directory tempDir;
  late CachePolicyConfigStore store;
  late MediaMetadataStore metadataStore;
  final logs = <String>[];

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('sp_cache_log_');
    store = CachePolicyConfigStore.forPath(
      '${tempDir.path}${Platform.pathSeparator}cache_policy.json',
    );
    metadataStore = MediaMetadataStore.forPath(
      '${tempDir.path}${Platform.pathSeparator}media_metadata.json',
    );
    logs.clear();
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  CachePolicyService makeService({
    CachePolicyConfig? config,
    MediaProbe? probe,
  }) {
    // 默认 fake probe：报告 7GB 文件（对应大文件播放场景）。
    return CachePolicyService(
      store: store,
      mediaProbe: probe ?? const _FakeProbe(sizeBytes: 7 * 1024 * 1024 * 1024),
      memoryProvider: const NullMemoryProvider(),
      metadataStore: metadataStore,
      logger: logs.add,
    );
  }

  const url = 'http://h/dav/movie.mkv';

  test('正常路径：输出一行摘要与一行注入参数', () async {
    await store.save(CachePolicyConfig.defaults());
    final service = makeService();
    final args = await service.buildCacheArgs(sessionId: 's1', url: url);

    expect(args, isNotEmpty);
    expect(logs.join('\n'), contains('Cache: 7.00GiB | bitrate unknown'));
    expect(logs.join('\n'), contains('cache target requested=120s'));
    expect(logs.join('\n'), contains('estimated-reachable=unknown'));
    expect(logs.join('\n'), contains('byte-cap=1.00GiB (1073741824B)'));
    expect(logs.join('\n'), contains('Injected: --cache=yes --cache-secs=120'));
  });

  test('小文件全量缓存日志不套用普通媒体的可达秒数公式', () async {
    await store.save(CachePolicyConfig.defaults());
    final service = makeService(
      probe: const _FakeProbe(sizeBytes: 100 * 1024 * 1024),
    );
    final args = await service.buildCacheArgs(sessionId: 's1', url: url);

    expect(args, isNotEmpty);
    expect(logs.join('\n'), contains('cache target=full-file'));
    expect(logs.join('\n'), contains('byte-cap=110.0MiB'));
    expect(logs.join('\n'), isNot(contains('byte-cap limited')));
  });

  test('enabled=false：输出跳过原因', () async {
    await store.save(const CachePolicyConfig(enabled: false));
    final service = makeService();
    final args = await service.buildCacheArgs(sessionId: 's1', url: url);

    expect(args, isEmpty);
    expect(logs.join('\n'), contains('Cache system disabled (enabled=false)'));
  });

  test('用户已手动配置缓存参数：输出尊重手动配置', () async {
    await store.save(CachePolicyConfig.defaults());
    final service = makeService();
    final args = await service.buildCacheArgs(
      sessionId: 's1',
      url: url,
      userArgs: const ['--cache-secs=999', '{url}'],
    );

    expect(args, isEmpty);
    expect(
      logs.join('\n'),
      contains('Player template already has cache args; skipping injection'),
    );
  });

  test('--no-cache / --no-demuxer-* 同样视为用户手动缓存配置', () async {
    await store.save(CachePolicyConfig.defaults());
    final service = makeService();
    for (final arg in const ['--no-cache', '--no-demuxer-seekable-cache']) {
      final args = await service.buildCacheArgs(
        sessionId: 's_$arg',
        url: url,
        userArgs: [arg, '{url}'],
      );
      expect(args, isEmpty, reason: '$arg 必须获得最高优先级');
    }
  });

  test('探测失败：输出降级信息且策略仍有效', () async {
    await store.save(CachePolicyConfig.defaults());
    final service = makeService(
      probe: const _FakeProbe(sizeBytes: null, error: 'fake 探测失败'),
    );
    final args = await service.buildCacheArgs(sessionId: 's1', url: url);

    expect(args, isNotEmpty);
    expect(logs.join('\n'), contains('Cache: size unknown | bitrate unknown'));
  });

  test('logger 自身抛异常不影响策略计算', () async {
    await store.save(CachePolicyConfig.defaults());
    final service = CachePolicyService(
      store: store,
      mediaProbe: const _FakeProbe(sizeBytes: 100),
      memoryProvider: const NullMemoryProvider(),
      metadataStore: metadataStore,
      logger: (message) => throw StateError('logger 故障'),
    );
    final args = await service.buildCacheArgs(sessionId: 's1', url: url);
    expect(args, isNotEmpty);
  });

  group('码率三级策略（设计文档）', () {
    test('Level 2 优先：有 duration 时平均码率优先于 metadata bit_rate', () async {
      await store.save(CachePolicyConfig.defaults());
      final hash = MediaMetadataStore.urlHashOf(url);
      await metadataStore.write(
        MediaMetadata(
          urlHash: hash,
          fileSize: 7 * 1024 * 1024 * 1024,
          durationSec: 7200,
          bitrateBps: 12000000, // 12 Mbps（但 Level 2 优先）
          resolution: '1920x1080',
          updatedAt: DateTime.now(),
        ),
      );
      final service = makeService();
      final result = await service.buildPolicy(url: url);

      // 逐级推进：Level 2 优先（平均码率 7GiB÷7200s ≈ 8.3Mbps）。
      expect(result.bitrateMbps, closeTo(8.3, 0.1));
      expect(result.bitrateSource, contains('Level2 avg bitrate'));
      final bitrate = 7 * 1024 * 1024 * 1024 * 8 / 7200 / 1000000;
      final expected = (bitrate * 120 * 125000 * CachePolicyEngine.safetyFactor)
          .round();
      expect(result.demuxerMaxBytes, expected);
    });

    test('无 duration 时逐级推进到 Level 1（metadata bit_rate）', () async {
      await store.save(CachePolicyConfig.defaults());
      final hash = MediaMetadataStore.urlHashOf(url);
      await metadataStore.write(
        MediaMetadata(
          urlHash: hash,
          fileSize: 7 * 1024 * 1024 * 1024, // 大小匹配（当前探测 7GB）
          bitrateBps: 12000000, // 12 Mbps，无 duration
          updatedAt: DateTime.now(),
        ),
      );
      final service = makeService();
      final result = await service.buildPolicy(url: url);

      expect(result.bitrateMbps, closeTo(12.0, 0.01));
      expect(result.bitrateSource, contains('Level1 metadata bit_rate'));
      final expected = (12 * 120 * 125000 * CachePolicyEngine.safetyFactor)
          .round();
      expect(result.demuxerMaxBytes, expected);
    });

    test('Level 2：平均码率 = 大小 ÷ 时长', () async {
      await store.save(CachePolicyConfig.defaults());
      final hash = MediaMetadataStore.urlHashOf(url);
      await metadataStore.write(
        MediaMetadata(
          urlHash: hash,
          fileSize: 7 * 1024 * 1024 * 1024,
          durationSec: 7200,
          resolution: '1920x1080',
          updatedAt: DateTime.now(),
        ),
      );
      final service = makeService();
      final result = await service.buildPolicy(url: url);

      expect(result.bitrateMbps, closeTo(8.3, 0.1));
      expect(result.bitrateSource, contains('Level2 avg bitrate'));
      // 7GiB × 8 / 7200s / 1e6 ≈ 8.3Mbps。
      final bitrate = 7 * 1024 * 1024 * 1024 * 8 / 7200 / 1000000;
      final expected = (bitrate * 120 * 125000 * CachePolicyEngine.safetyFactor)
          .round();
      expect(result.demuxerMaxBytes, expected);
    });

    test('Level 3：分辨率估算（无 bitrate 无 duration）', () async {
      await store.save(CachePolicyConfig.defaults());
      final hash = MediaMetadataStore.urlHashOf(url);
      await metadataStore.write(
        MediaMetadata(
          urlHash: hash,
          fileSize: 7 * 1024 * 1024 * 1024, // 大小匹配（当前探测 7GB）
          resolution: '3840x2160', // 4K → 35Mbps
          updatedAt: DateTime.now(),
        ),
      );
      final service = makeService();
      final result = await service.buildPolicy(url: url);

      expect(result.bitrateMbps, closeTo(35.0, 0.01));
      expect(result.bitrateSource, contains('Level3 resolution estimate'));
      expect(result.cacheSecs, 180, reason: '4K 分辨率应接通生产档位');
      final expected = (35 * 180 * 125000 * CachePolicyEngine.safetyFactor)
          .round();
      expect(result.demuxerMaxBytes, expected);
    });

    test('metadata 未命中：预算兜底，recordDuration 后写入缓存并二次命中', () async {
      await store.save(CachePolicyConfig.defaults());
      final service = makeService();
      final args = await service.buildCacheArgs(sessionId: 's1', url: url);

      expect(args, isNotEmpty);
      expect(logs.join('\n'), contains('Cache: 7.00GiB | bitrate unknown'));
      expect(logs.join('\n'), contains('--demuxer-max-bytes=1073741824'));

      // mpv 打开后上报时长（模拟状态文件读取）。
      service.recordDuration('s1', url, 7200);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final meta = await metadataStore.read(MediaMetadataStore.urlHashOf(url));
      expect(meta, isNotNull);
      expect(meta!.durationSec, 7200);
      expect(logs.join('\n'), contains('Bitrate updated'));

      // 第二次播放：Level 2 平均码率命中。
      logs.clear();
      final second = await service.buildCacheArgs(sessionId: 's1', url: url);
      expect(second, isNotEmpty);
      // 7GiB × 8 / 7200s ≈ 8.4Mbps。
      expect(logs.join('\n'), contains('bitrate 8.4Mbps (Level2 avg bitrate)'));
    });

    test('metadata 文件大小不匹配时视为未命中', () async {
      await store.save(CachePolicyConfig.defaults());
      final hash = MediaMetadataStore.urlHashOf(url);
      await metadataStore.write(
        MediaMetadata(
          urlHash: hash,
          fileSize: 12345, // 与 HEAD 探测的 7GB 不符
          durationSec: 7200,
          updatedAt: DateTime.now(),
        ),
      );
      final service = makeService();
      final args = await service.buildCacheArgs(sessionId: 's1', url: url);

      expect(args, isNotEmpty);
      expect(logs.join('\n'), contains('Cache: 7.00GiB | bitrate unknown'));
    });

    test('recordDuration 后 onPolicyReady 回调携带更新后策略', () async {
      await store.save(CachePolicyConfig.defaults());
      CachePolicyResult? ready;
      final service = makeService();
      service.onPolicyReady = (sessionId, url, result) => ready = result;

      final args = await service.buildCacheArgs(sessionId: 's1', url: url);
      expect(args, isNotEmpty); // 本次仍预算兜底（不阻塞）

      // mpv 打开后上报时长（用户场景 1446s）。
      service.recordDuration('s1', url, 1446);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(ready, isNotNull, reason: '时长上报后应触发回调');
      expect(ready!.cacheSecs, 180, reason: '高码率媒体应自动进入 4K 档');
      // Level 2 平均码率 = 7GiB × 8 ÷ 1446s ÷ 1e6 ≈ 41.5Mbps，
      // × 120s × 125000 × 1.3 < 1GiB 兜底预算。
      final bitrate = 7 * 1024 * 1024 * 1024 * 8 / 1446 / 1000000;
      final expected = math.min(
        (bitrate * 180 * 125000 * CachePolicyEngine.safetyFactor).round(),
        1024 * 1024 * 1024,
      );
      expect(ready!.demuxerMaxBytes, expected);
      expect(logs.join('\n'), contains('Bitrate updated'));
      expect(logs.join('\n'), contains('estimated-reachable='));
      expect(logs.join('\n'), contains('policy ready for IPC'));
      expect(logs.join('\n'), isNot(contains('applied to current playback')));
    });

    test('TS 容器（.m2ts）：起播关闭缓存并预配置运行态补水参数', () async {
      await store.save(CachePolicyConfig.defaults());
      final service = makeService();

      final args = await service.buildCacheArgs(
        sessionId: 's1',
        url: 'http://h/dav/movie.m2ts',
      );

      // 起播阶段显式关闭缓存；稳定播放后再进入轻量顺序预读。
      expect(args, [
        '--cache=no',
        '--demuxer-seekable-cache=no',
        '--cache-pause=yes',
        '--cache-pause-initial=yes',
        '--cache-pause-wait=${CachePolicyEngine.tsInitialBufferWaitSecs}',
      ]);
      expect(logs.join('\n'), contains('TS startup phase: cache disabled'));
    });

    test('TS 稳定起播后切换为小型顺序预读，不启用 seekable cache', () async {
      await store.save(CachePolicyConfig.defaults());
      final service = makeService();
      const tsUrl = 'http://h/dav/movie.m2ts';
      await service.buildCacheArgs(sessionId: 's1', url: tsUrl);

      final runtimeArgs = await service.buildCacheArgs(
        sessionId: 's1',
        url: tsUrl,
        runtimeTs: true,
      );

      expect(runtimeArgs, contains('--cache=yes'));
      expect(runtimeArgs, contains('--demuxer-seekable-cache=no'));
      final maxArg = runtimeArgs.singleWhere(
        (arg) => arg.startsWith('--demuxer-max-bytes='),
      );
      final maxBytes = int.parse(maxArg.split('=').last);
      expect(maxBytes, lessThanOrEqualTo(128 * 1024 * 1024));
      expect(service.sessionState('s1')!.shouldMonitor, isTrue);
    });

    test('非 TS 容器不受影响', () async {
      await store.save(CachePolicyConfig.defaults());
      final service = makeService();
      final args = await service.buildCacheArgs(sessionId: 's1', url: url);
      expect(args, isNotEmpty);
      expect(args, isNot(contains('--demuxer-seekable-cache=no')));
    });

    test('无 metadataStore 时维持预算兜底（向后兼容）', () async {
      await store.save(CachePolicyConfig.defaults());
      final service = CachePolicyService(
        store: store,
        mediaProbe: const _FakeProbe(sizeBytes: 7 * 1024 * 1024 * 1024),
        memoryProvider: const NullMemoryProvider(),
        logger: logs.add,
      );
      final args = await service.buildCacheArgs(sessionId: 's1', url: url);
      expect(args, isNotEmpty);
      expect(logs.join('\n'), contains('Cache: 7.00GiB | bitrate unknown'));
    });
  });

  group('播放中动态监控（第二阶段）', () {
    test('startMonitor 透传参数并启动监控', () async {
      final monitor = _RecordingMonitor();
      final service = CachePolicyService(
        store: store,
        mediaProbe: const _FakeProbe(sizeBytes: 100),
        memoryProvider: const NullMemoryProvider(),
        monitorFactory: () => monitor,
      );
      service.startMonitor(
        sessionId: 's1',
        url: url,
        statusFilePath: r'C:\tmp\status.txt',
        initialDemuxerMaxBytes: 123456789,
        initialCacheSecs: 120,
        bitrateMbps: 40.8,
        onAdjustment: (a) {},
        onWarning: (m) {},
      );
      expect(monitor.startedStatusFile, r'C:\tmp\status.txt');
      expect(monitor.startedMax, 123456789);
      expect(monitor.startedSecs, 120);
      expect(monitor.startedBitrate, 40.8);
      expect(monitor.stopped, isFalse);
    });

    test('stopMonitor 停止监控；重复 startMonitor 幂等替换', () async {
      final monitor = _RecordingMonitor();
      final service = CachePolicyService(
        store: store,
        mediaProbe: const _FakeProbe(sizeBytes: 100),
        memoryProvider: const NullMemoryProvider(),
        monitorFactory: () => monitor,
      );
      service.startMonitor(
        sessionId: 's1',
        url: url,
        statusFilePath: 'a.txt',
        initialDemuxerMaxBytes: 100,
        initialCacheSecs: 120,
      );
      service.stopMonitor('s1');
      expect(monitor.stopped, isTrue);
      // 重新启动（幂等替换）。
      monitor.stopped = false;
      service.startMonitor(
        sessionId: 's1',
        url: url,
        statusFilePath: 'b.txt',
        initialDemuxerMaxBytes: 200,
        initialCacheSecs: 60,
      );
      expect(monitor.stopped, isFalse);
      expect(monitor.startedStatusFile, 'b.txt');
    });

    test('监控启动异常静默（不抛出）', () async {
      final monitor = _ThrowingMonitor();
      final service = CachePolicyService(
        store: store,
        mediaProbe: const _FakeProbe(sizeBytes: 100),
        memoryProvider: const NullMemoryProvider(),
        monitorFactory: () => monitor,
      );
      service.startMonitor(
        sessionId: 's1',
        url: url,
        statusFilePath: 'a.txt',
        initialDemuxerMaxBytes: 100,
        initialCacheSecs: 120,
      );
      // 异常被吞掉即通过。
      service.stopMonitor('s1');
    });

    test('双会话隔离：各自独立实例，停止 A 不影响 B', () async {
      final created = <_RecordingMonitor>[];
      final service = CachePolicyService(
        store: store,
        mediaProbe: const _FakeProbe(sizeBytes: 100),
        memoryProvider: const NullMemoryProvider(),
        monitorFactory: () {
          final m = _RecordingMonitor();
          created.add(m);
          return m;
        },
      );
      service.startMonitor(
        sessionId: 'A',
        url: url,
        statusFilePath: 'a.txt',
        initialDemuxerMaxBytes: 100,
        initialCacheSecs: 120,
      );
      service.startMonitor(
        sessionId: 'B',
        url: 'http://h/dav/b.mkv',
        statusFilePath: 'b.txt',
        initialDemuxerMaxBytes: 200,
        initialCacheSecs: 180,
      );
      expect(created.length, 2, reason: '每会话独立监控实例');
      expect(created[0].stopped, isFalse, reason: '启动 B 不得停止 A');
      service.stopMonitor('A');
      expect(created[0].stopped, isTrue, reason: '停止 A 只停 A');
      expect(created[1].stopped, isFalse, reason: 'B 不受影响');
      // 同会话重复启动：先停旧实例再新建。
      service.startMonitor(
        sessionId: 'B',
        url: 'http://h/dav/b2.mkv',
        statusFilePath: 'b.txt',
        initialDemuxerMaxBytes: 300,
        initialCacheSecs: 240,
      );
      expect(created[1].stopped, isTrue, reason: '同会话重启先停旧实例');
      expect(created.length, 3);
    });

    test('策略状态：正常注入/手动跳过/关闭/TS 四分支', () async {
      await store.save(CachePolicyConfig.defaults());
      final service = CachePolicyService(
        store: store,
        mediaProbe: const _FakeProbe(sizeBytes: 7 * 1024 * 1024 * 1024),
        memoryProvider: const NullMemoryProvider(),
      );
      // 正常注入。
      final args = await service.buildCacheArgs(sessionId: 's1', url: url);
      expect(args, isNotEmpty);
      var state = service.sessionState('s1');
      expect(state, isNotNull);
      expect(state!.injected, isTrue);
      expect(state.shouldMonitor, isTrue);
      expect(state.tsOnly, isFalse);
      // 手动缓存参数：跳过注入，并更新当前会话状态。
      await service.buildCacheArgs(
        sessionId: 's1',
        url: url,
        userArgs: const ['--cache=yes'],
      );
      state = service.sessionState('s1');
      expect(state!.injected, isFalse, reason: '手动参数优先');
      expect(state.shouldMonitor, isFalse);
      // TS 直链：有注入但不启动监控。
      final tsArgs = await service.buildCacheArgs(
        sessionId: 's1',
        url: 'http://h/dav/movie.m2ts',
      );
      expect(tsArgs, [
        '--cache=no',
        '--demuxer-seekable-cache=no',
        '--cache-pause=yes',
        '--cache-pause-initial=yes',
        '--cache-pause-wait=${CachePolicyEngine.tsInitialBufferWaitSecs}',
      ]);
      state = service.sessionState('s1');
      expect(state!.injected, isTrue);
      expect(state.tsOnly, isTrue);
      expect(state.shouldMonitor, isFalse);
      // 配置关闭。
      await store.save(const CachePolicyConfig(enabled: false));
      await service.buildCacheArgs(sessionId: 's2', url: url);
      state = service.sessionState('s2');
      expect(state!.injected, isFalse);
      expect(service.sessionState('unknown'), isNull);
    });

    test('手动参数首次跳过后，迟到 duration 不得恢复自动策略', () async {
      await store.save(CachePolicyConfig.defaults());
      CachePolicyResult? ready;
      final service = makeService()
        ..onPolicyReady = (_, _, result) => ready = result;
      await service.buildCacheArgs(
        sessionId: 'manual',
        url: url,
        userArgs: const ['--cache=yes'],
      );

      service.recordDuration('manual', url, 7200);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(ready, isNull);
      expect(service.sessionState('manual')!.shouldMonitor, isFalse);
    });

    test('旧曲目迟到的探测结果不得覆盖复用 sessionId 的新状态', () async {
      await store.save(CachePolicyConfig.defaults());
      final probe = _DelayedSecondProbe();
      final service = makeService(probe: probe);
      final readies = <String>[];
      service.onPolicyReady = (_, callbackUrl, _) => readies.add(callbackUrl);
      await service.buildCacheArgs(
        sessionId: 'same-session',
        url: url,
        authHeader: 'Basic old',
      );
      service.recordDuration('same-session', url, 7200);
      await probe.secondStarted.future;

      const nextUrl = 'http://h/dav/next.mkv';
      await service.buildCacheArgs(
        sessionId: 'same-session',
        url: nextUrl,
        userArgs: const ['--cache=yes'],
      );
      probe.completeSecond(7 * 1024 * 1024 * 1024);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(readies, isEmpty);
      expect(service.sessionState('same-session')!.url, nextUrl);
      expect(probe.authHeaders, everyElement('Basic old'));
    });

    test('会话状态 LRU：超上限淘汰最久未用，诊断快照 URL 脱敏', () async {
      await store.save(CachePolicyConfig.defaults());
      final service = CachePolicyService(
        store: store,
        mediaProbe: const _FakeProbe(sizeBytes: 100),
        memoryProvider: const NullMemoryProvider(),
      );
      // 写入超过上限的会话（201 条）→ 最早的被淘汰。
      const limit = 200;
      for (var i = 0; i <= limit; i++) {
        await service.buildCacheArgs(
          sessionId: 's$i',
          url: 'http://h/dav/movie$i.mkv',
        );
      }
      // 诊断快照：字段齐全、URL 脱敏（query 剥离）。
      final snap = service.diagnosticsSnapshot();
      expect(snap['activeSessions'], isA<List<Object?>>());
      final states = snap['sessionStates'] as Map<Object?, Object?>;
      expect(states.containsKey('s0'), isFalse, reason: '最久未用的会话被淘汰');
      expect(states.containsKey('s$limit'), isTrue, reason: '最新会话保留');
      final state = states['s$limit'] as Map<Object?, Object?>;
      expect(state['url'], 'http://h/dav/movie$limit.mkv');
      // 脱敏：带 query 的 URL 只保留 scheme://host/path。
      await service.buildCacheArgs(
        sessionId: 'sQ',
        url: 'http://h/dav/secret.mkv?token=abc123',
      );
      final snap2 = service.diagnosticsSnapshot();
      final states2 = snap2['sessionStates'] as Map<Object?, Object?>;
      final state2 = states2['sQ'] as Map<Object?, Object?>;
      expect(
        state2['url'],
        'http://h/dav/secret.mkv',
        reason: 'query（签名 token）必须剥离',
      );
      // 会话退出：stopMonitor 清理对应策略状态。
      service.stopMonitor('sQ', clearSession: true);
      final snap3 = service.diagnosticsSnapshot();
      final states3 = snap3['sessionStates'] as Map<Object?, Object?>;
      expect(states3.containsKey('sQ'), isFalse, reason: '退出后清理');
    });

    test('同 URL 双会话：码率更新路由到上报者自己的会话', () async {
      await store.save(CachePolicyConfig.defaults());
      final readies = <String>[];
      final service = makeService();
      service.onPolicyReady = (sessionId, u, r) => readies.add(sessionId);
      // B 先启动，随后验证 A 的更新仍只归属 A。
      await service.buildCacheArgs(sessionId: 'B', url: url);
      // A 后启动并上报时长。
      await service.buildCacheArgs(sessionId: 'A', url: url);
      service.recordDuration('A', url, 7200);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(readies, ['A'], reason: '码率更新必须路由到上报者 A，而不是后登记的 B（不串线）');
    });

    test('旧 metadata 缺大小：当前大小已知时视为文件已变，重写补全', () async {
      final metaStore = MediaMetadataStore.forPath(
        '${tempDir.path}${Platform.pathSeparator}media_metadata_nullsize.json',
      );
      // 预写旧数据：首次 HEAD 失败场景（fileSize=null，duration 已知）。
      await metaStore.write(
        MediaMetadata(
          urlHash: MediaMetadataStore.urlHashOf(url),
          durationSec: 7200,
          bitrateBps: 12 * 1000000,
          durationSource: 'mpv',
          bitrateSource: 'average',
          updatedAt: DateTime.now(),
        ),
      );
      // 本次 HEAD 成功（大小已知）：旧大小缺失 → 不得视为同一文件。
      final service = CachePolicyService(
        store: store,
        mediaProbe: const _FakeProbe(sizeBytes: 1000),
        memoryProvider: const NullMemoryProvider(),
        metadataStore: metaStore,
      );
      await service.buildCacheArgs(sessionId: 's1', url: url);
      service.recordDuration('s1', url, 50);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final meta = await metaStore.read(MediaMetadataStore.urlHashOf(url));
      expect(meta, isNotNull);
      expect(meta!.fileSize, 1000, reason: '必须补写当前文件大小');
      expect(meta.durationSec, 50, reason: '时长按新文件重写');
      expect(meta.bitrateBps, isNull, reason: '旧文件码率（12Mbps）必须清空，防止误用');
    });

    test('反向边界：本次 HEAD 失败（大小未知）时保留已验证数据', () async {
      final metaStore = MediaMetadataStore.forPath(
        '${tempDir.path}${Platform.pathSeparator}media_metadata_keepsize.json',
      );
      // 预写已验证数据（有大小有码率）。
      await metaStore.write(
        MediaMetadata(
          urlHash: MediaMetadataStore.urlHashOf(url),
          fileSize: 7 * 1024 * 1024 * 1024,
          durationSec: 7200,
          bitrateBps: 8000000,
          durationSource: 'mpv',
          bitrateSource: 'average',
          updatedAt: DateTime.now(),
        ),
      );
      // 本次 HEAD 失败（探测返回失败 → 大小未知）。
      final service = CachePolicyService(
        store: store,
        mediaProbe: const _FakeProbe(error: 'fake 探测失败'),
        memoryProvider: const NullMemoryProvider(),
        metadataStore: metaStore,
      );
      await service.buildCacheArgs(sessionId: 's1', url: url);
      // 时长上报：大小未知 → 视为同一文件 → 不得清空已验证数据。
      service.recordDuration('s1', url, 7200);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final meta = await metaStore.read(MediaMetadataStore.urlHashOf(url));
      expect(meta, isNotNull);
      expect(meta!.fileSize, 7 * 1024 * 1024 * 1024, reason: '大小未知时保留旧大小，不得清空');
      expect(meta.bitrateBps, 8000000, reason: '大小未知时保留旧码率，不得清空');
    });

    test('元数据按文件大小失效重建：文件变更重写并清空旧码率', () async {
      final metaStore = MediaMetadataStore.forPath(
        '${tempDir.path}${Platform.pathSeparator}media_metadata.json',
      );
      // service1：探测 1000 字节 → 上报时长 → 写入 metadata。
      final service1 = CachePolicyService(
        store: store,
        mediaProbe: const _FakeProbe(sizeBytes: 1000),
        memoryProvider: const NullMemoryProvider(),
        metadataStore: metaStore,
      );
      await service1.buildCacheArgs(sessionId: 's1', url: url);
      service1.recordDuration('s1', url, 100);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      var meta = await metaStore.read(MediaMetadataStore.urlHashOf(url));
      expect(meta, isNotNull);
      expect(meta!.fileSize, 1000);
      expect(meta.durationSec, 100);
      expect(meta.durationSource, 'mpv');
      expect(meta.bitrateSource, 'average');
      // 文件大小不变但时长显著变化：无 ETag 时把时长变化视为文件
      // 替换的补充证据，避免同大小替换后永远沿用旧时长。
      service1.recordDuration('s1', url, 200);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      meta = await metaStore.read(MediaMetadataStore.urlHashOf(url));
      expect(meta!.durationSec, 200, reason: '显著变化的时长应刷新');
      // 文件被替换（大小变化）：重写时长并清空旧码率。
      final service2 = CachePolicyService(
        store: store,
        mediaProbe: const _FakeProbe(sizeBytes: 2000),
        memoryProvider: const NullMemoryProvider(),
        metadataStore: metaStore,
      );
      await service2.buildCacheArgs(sessionId: 's2', url: url);
      service2.recordDuration('s2', url, 50);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      meta = await metaStore.read(MediaMetadataStore.urlHashOf(url));
      expect(meta!.fileSize, 2000, reason: '文件大小更新');
      expect(meta.durationSec, 50, reason: '时长按新文件重写');
      expect(meta.bitrateBps, isNull, reason: '旧文件码率必须清空');
      expect(meta.durationSource, 'mpv');
    });

    test('TS 运行态用 HEAD 大小与 MPV duration 生成真实码率和小窗口策略', () async {
      await store.save(CachePolicyConfig.defaults());
      const tsUrl = 'https://dav.example/media/movie.m2ts';
      const size = 900 * 1024 * 1024;
      final ready = Completer<CachePolicyResult>();
      final service = CachePolicyService(
        store: store,
        mediaProbe: const _FakeProbe(sizeBytes: size),
        memoryProvider: const NullMemoryProvider(),
        metadataStore: metadataStore,
      );
      service.onPolicyReady = (sessionId, callbackUrl, result) {
        if (sessionId == 'ts-runtime' && callbackUrl == tsUrl) {
          ready.complete(result);
        }
      };

      final startupArgs = await service.buildCacheArgs(
        sessionId: 'ts-runtime',
        url: tsUrl,
        runtimeTs: true,
      );
      expect(startupArgs, contains('--cache=yes'));
      expect(startupArgs, contains('--demuxer-seekable-cache=no'));
      expect(service.sessionState('ts-runtime')!.tsRuntime, isTrue);

      service.recordDuration('ts-runtime', tsUrl, 900);
      final result = await ready.future.timeout(const Duration(seconds: 2));
      expect(result.bitrateMbps, closeTo(size * 8 / 900 / 1000000, 0.01));
      expect(result.bitrateSource, 'Level2 avg bitrate');
      expect(result.cacheSecs, inInclusiveRange(15, 60));
      expect(
        result.demuxerMaxBytes,
        lessThanOrEqualTo(CachePolicyEngine.tsRuntimeMaxBytes),
      );
      expect(result.args, contains('--demuxer-seekable-cache=no'));
    });
  });
}

/// fake 媒体探测器：返回固定大小或失败。
class _FakeProbe implements MediaProbe {
  const _FakeProbe({this.sizeBytes, this.error});

  final int? sizeBytes;
  final String? error;

  @override
  Future<MediaProbeResult> probeContentLength({
    required String url,
    String? authHeader,
  }) async {
    if (sizeBytes != null && sizeBytes! > 0) {
      return MediaProbeResult(contentLengthBytes: sizeBytes);
    }
    return MediaProbeResult(error: error ?? '探测失败');
  }
}

/// 首次探测失败、第二次探测可控完成，用于构造 duration 回填与切集竞态。
class _DelayedSecondProbe implements MediaProbe {
  final Completer<void> secondStarted = Completer<void>();
  final Completer<MediaProbeResult> _second = Completer<MediaProbeResult>();
  final List<String?> authHeaders = <String?>[];
  int _calls = 0;

  @override
  Future<MediaProbeResult> probeContentLength({
    required String url,
    String? authHeader,
  }) {
    authHeaders.add(authHeader);
    _calls++;
    if (_calls == 1) {
      return Future<MediaProbeResult>.value(
        const MediaProbeResult(error: 'first probe unavailable'),
      );
    }
    if (!secondStarted.isCompleted) secondStarted.complete();
    return _second.future;
  }

  void completeSecond(int bytes) {
    if (!_second.isCompleted) {
      _second.complete(MediaProbeResult(contentLengthBytes: bytes));
    }
  }
}

/// 记录 start/stop 调用的监控 fake（验证 service 透传）。
class _RecordingMonitor extends PlaybackMonitor {
  _RecordingMonitor() : super(memoryProvider: const NullMemoryProvider());

  String? startedStatusFile;
  int? startedMax;
  int? startedSecs;
  double? startedBitrate;
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
    startedBitrate = bitrateMbps;
  }

  @override
  void stop() {
    stopped = true;
  }
}

/// 故意抛异常的监控 fake（验证 service 异常静默）。
class _ThrowingMonitor extends PlaybackMonitor {
  _ThrowingMonitor() : super(memoryProvider: const NullMemoryProvider());

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
    throw StateError('监控启动故障');
  }
}
