import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/domain/services/mpv_session_controller.dart';
import 'package:streampath/features/cache_control/cache_policy_service.dart';
import 'package:streampath/features/cache_control/intelligence/cache_intelligence_service.dart';
import 'package:streampath/features/cache_control/iso_cache_coordinator.dart';
import 'package:streampath/features/cache_control/models/cache_learning_data.dart';
import 'package:streampath/features/cache_control/models/cache_policy_config.dart';
import 'package:streampath/features/cache_control/monitor/playback_monitor.dart';
import 'package:streampath/features/cache_control/providers/system_memory_provider.dart';
import 'package:streampath/features/cache_control/providers/media_probe.dart';
import 'package:streampath/features/cache_control/store/cache_policy_config_store.dart';
import 'package:streampath/features/cache_control/intelligence/storage_classifier.dart';

class _FixedMemoryProvider extends SystemMemoryProvider {
  const _FixedMemoryProvider(this.bytes);

  final int bytes;

  @override
  Future<int?> availableMemoryBytes() async => bytes;
}

const _mib = 1024 * 1024;
const _discKey = 'verified-disc';
const _source = 'https://dav.example/disc.iso';
const _uhd = IsoCacheTitleContext(
  programmeId: '00222',
  streamSize: 18 * _mib * 3600,
  duration: Duration(hours: 1),
);

class _CapacityIpc extends MpvSessionController {
  _CapacityIpc(this.mode);

  final String mode;
  int cap = 512 * _mib;
  int seconds = 90;
  int promotionWrites = 0;
  bool connected = false;
  int connectCalls = 0;
  Future<void> Function()? afterPromotion;

  @override
  bool get isConnected => connected;

  @override
  Future<bool> connect({
    Duration timeout = const Duration(seconds: 10),
    Duration retryInterval = const Duration(milliseconds: 250),
  }) async {
    connectCalls++;
    return connected = true;
  }

  @override
  Future<Object?> getProperty(String name) async {
    if (name == 'options/demuxer-max-bytes' && cap == 640 * _mib) {
      final after = afterPromotion;
      afterPromotion = null;
      await after?.call();
    }
    return switch (name) {
      'options/demuxer-max-bytes' => cap,
      'options/demuxer-max-back-bytes' =>
        mode == 'large-backward' ? 3000 * _mib : 50 * _mib,
      'options/cache-secs' => seconds,
      _ => throw ArgumentError.value(name),
    };
  }

  @override
  Future<Object?> setProperty(String name, Object value) async {
    expect(connected, isTrue);
    if (name == 'cache-secs') {
      seconds = value as int;
      return null;
    }
    expect(name, 'demuxer-max-bytes');
    if (value == 640 * _mib) {
      promotionWrites++;
      if (mode == 'rejected') throw StateError('property unavailable');
      if (mode == 'mismatch') return null;
      if (mode == 'timeout') {
        cap = value as int;
        connected = false;
        throw TimeoutException('missing reply');
      }
    }
    cap = value as int;
    return null;
  }

  @override
  Future<void> dispose() async => connected = false;
}

class _RuntimeMemory extends SystemMemoryProvider {
  int? bytes = 8 * 1024 * _mib;

  @override
  Future<int?> availableMemoryBytes() async => bytes;
}

class _CountingProbe implements MediaProbe {
  int calls = 0;
  @override
  Future<MediaProbeResult> probeContentLength({
    required String url,
    String? authHeader,
  }) async {
    calls++;
    return const MediaProbeResult(error: 'Unexpected probe');
  }
}

class _RecordingIntelligence implements CacheIntelligenceProvider {
  final List<String> adviceUrls = [];
  final List<String> bitrateUrls = [];
  final List<String> sessionUrls = [];

  @override
  Future<CacheIntelligenceAdvice> advise({
    required String url,
    required int baseCacheSecs,
    int? fileSizeBytes,
    double? currentBitrateMbps,
    String? resolution,
  }) async {
    adviceUrls.add(url);
    return CacheIntelligenceAdvice(
      enabled: true,
      applyOptimizations: true,
      storageType: CacheStorageType.remote,
      suggestedBaseCacheSecs: 180,
      confidence: 1,
      reasonCodes: const ['test'],
    );
  }

  @override
  Future<void> observeBitrate({
    required String url,
    required double bitrateMbps,
    int? fileSizeBytes,
    String? resolution,
  }) async {
    bitrateUrls.add(url);
  }

  @override
  Future<void> observeSession({
    required String url,
    required PlaybackSessionOutcome outcome,
  }) async {
    sessionUrls.add(url);
  }
}

class _FailingIntelligence implements CacheIntelligenceProvider {
  @override
  Future<CacheIntelligenceAdvice> advise({
    required String url,
    required int baseCacheSecs,
    int? fileSizeBytes,
    double? currentBitrateMbps,
    String? resolution,
  }) => Future<CacheIntelligenceAdvice>.error(StateError('advice failed'));

  @override
  Future<void> observeBitrate({
    required String url,
    required double bitrateMbps,
    int? fileSizeBytes,
    String? resolution,
  }) => Future<void>.error(StateError('bitrate failed'));

  @override
  Future<void> observeSession({
    required String url,
    required PlaybackSessionOutcome outcome,
  }) => Future<void>.error(StateError('session failed'));
}

void main() {
  late Directory tempDirectory;
  late CachePolicyConfigStore store;

  setUp(() async {
    tempDirectory = Directory.systemTemp.createTempSync(
      'streampath_iso_cache_',
    );
    store = CachePolicyConfigStore.forPath(
      '${tempDirectory.path}${Platform.pathSeparator}cache_policy.json',
    );
    await store.save(CachePolicyConfig.defaults());
  });

  tearDown(() {
    tempDirectory.deleteSync(recursive: true);
  });

  test('640 MiB 只进入获准的远程高码率单标题正常预算', () async {
    final memory = _RuntimeMemory();
    final coordinator = IsoCacheCoordinator(
      policyService: CachePolicyService(store: store, memoryProvider: memory),
      verifiedUhdDiscKey: _discKey,
    );
    Future<IsoTitleCachePlan> plan(
      String? key, [
      List<IsoCacheTitleContext> titles = const [_uhd],
    ]) async => (await coordinator.buildSessionPlan(
      logicalSourceUrl: _source,
      remoteSingleDiscKey: key,
      titles: titles,
    )).planFor(_uhd.programmeId);

    final approved = await plan(_discKey);
    expect(approved.mpvMaxBytes, 512 * _mib);
    expect(approved.forwardCapacityTarget, 640 * _mib);
    expect((await plan(null)).forwardCapacityTarget, isNull);
    expect((await plan('different-source')).forwardCapacityTarget, isNull);
    expect(
      (await plan(_discKey, const [
        _uhd,
        IsoCacheTitleContext(
          programmeId: '00001',
          streamSize: 200 * _mib,
          duration: Duration(minutes: 10),
        ),
      ])).forwardCapacityTarget,
      isNull,
    );
    expect(
      (await plan(_discKey, const [
        IsoCacheTitleContext(
          programmeId: '00222',
          streamSize: 2 * _mib * 3600,
          duration: Duration(hours: 1),
        ),
      ])).forwardCapacityTarget,
      isNull,
    );
    memory.bytes = 2 * 1024 * _mib;
    expect((await plan(_discKey)).forwardCapacityTarget, isNull);
    await store.save(const CachePolicyConfig(enabled: false));
    expect((await plan(_discKey)).forwardCapacityTarget, isNull);
  });

  test('实测供数、连续水位、共享预算和 IPC 读回共同控制一次升档', () async {
    await store.save(const CachePolicyConfig(baseCacheSecs: 45));
    final fixtures = await Future.wait(
      [
        'approved',
        'legacy',
        'slow',
        'paused',
        'large-backward',
        'time-limit',
        'shared',
        'no-memory',
        'rejected',
        'timeout',
        'mismatch',
        'generation',
        'closing',
      ].map((mode) async {
        final status = File('${tempDirectory.path}/$mode.status');
        final metrics = File('${tempDirectory.path}/$mode.metrics');
        final ipc = _CapacityIpc(mode);
        final memory = _RuntimeMemory();
        final monitor = PlaybackMonitor(
          memoryProvider: memory,
          requiredStreak: 1,
          recoveryStreak: 1,
        );
        final policy = CachePolicyService(store: store, memoryProvider: memory);
        final coordinator = IsoCacheCoordinator(
          policyService: policy,
          memoryProvider: memory,
          controllerFactory: (_) => ipc,
          monitorFactory: () => monitor,
          verifiedUhdDiscKey: _discKey,
        );
        final plan = await coordinator.buildSessionPlan(
          logicalSourceUrl: _source,
          titles: const [_uhd],
          remoteSingleDiscKey: _discKey,
        );
        final decisions = <Map<String, Object?>>[];
        if (mode == 'generation') {
          ipc.afterPromotion = () async {
            final lines = status.readAsLinesSync();
            lines[13] = '1';
            lines[14] = '2';
            status.writeAsStringSync(lines.join('\n'));
          };
        } else if (mode == 'closing') {
          ipc.afterPromotion = () => coordinator.stopSession(mode);
        }
        coordinator.startSession(
          sessionId: mode,
          logicalSourceUrl: _source,
          statusFilePath: status.path,
          metricsFilePath: metrics.path,
          ipcPipeName: 'unused',
          orderedProgrammeIds: const ['00222'],
          plan: plan,
          onCapacityDecision: (decision) async => decisions.add(decision),
        );
        final other = mode == 'shared' ? coordinator.forFilmLibrary() : null;
        other?.startSession(
          sessionId: 'other',
          logicalSourceUrl: _source,
          statusFilePath: '${status.path}.missing',
          metricsFilePath: '${metrics.path}.missing',
          ipcPipeName: 'other',
          orderedProgrammeIds: const ['00222'],
          plan: plan,
        );
        if (mode == 'no-memory') memory.bytes = null;
        addTearDown(() async {
          await other?.stopSession('other');
          await coordinator.stopSession(mode);
        });
        return (
          mode: mode,
          status: status,
          metrics: metrics,
          monitor: monitor,
          ipc: ipc,
          memory: memory,
          decisions: decisions,
        );
      }),
    );

    for (var frame = 0; frame < 8; frame++) {
      for (final f in fixtures) {
        f.metrics.writeAsStringSync(
          jsonEncode({
            'version': 2,
            'playbackNetwork': {
              'remoteBodyBytes': frame * (f.mode == 'slow' ? 4 : 32) * _mib,
            },
          }),
        );
        final high = frame >= 4;
        f.status.writeAsStringSync(
          [
            '0',
            'unused',
            f.mode == 'paused' ? '1' : '0',
            '${100 + frame}',
            '3600',
            '100',
            '-1',
            high ? '1' : '0',
            'diagnostic',
            '0',
            '0',
            '0',
            '3840x2160',
            '0',
            f.mode == 'generation' && f.ipc.promotionWrites > 0 ? '2' : '1',
            f.mode == 'time-limit' && high ? '89' : '40',
            if (f.mode != 'legacy') ...[
              '${(high ? 510 : 340) * _mib}',
              '${562 * _mib}',
            ],
          ].join('\n'),
        );
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }

    final reason = <String, String>{
      'approved': 'promoted',
      'timeout': 'write-or-readback-failed',
      'rejected': 'write-or-readback-failed',
      'mismatch': 'readback-mismatch',
      'large-backward': 'memory-budget',
      'no-memory': 'memory-budget',
      'time-limit': 'cache-seconds-limited',
      'generation': 'generation-changed',
    };
    for (final f in fixtures) {
      if (f.mode == 'closing') {
        expect(f.ipc.promotionWrites, 1);
        expect(f.ipc.isConnected, isFalse);
        expect(f.monitor.currentDemuxerMaxBytes, 512 * _mib);
        expect(f.decisions, isEmpty);
        continue;
      }
      if (f.mode == 'generation') {
        expect(f.ipc.promotionWrites, 1);
        expect(f.ipc.cap, 640 * _mib);
        expect(f.monitor.currentDemuxerMaxBytes, 640 * _mib);
        expect(f.decisions.single['reason'], 'generation-changed');
        continue;
      }
      final promoted = f.mode == 'approved' || f.mode == 'timeout';
      final writes = promoted || f.mode == 'rejected' || f.mode == 'mismatch'
          ? 1
          : 0;
      expect(f.ipc.promotionWrites, writes, reason: f.mode);
      expect(f.ipc.cap, (promoted ? 640 : 512) * _mib, reason: f.mode);
      expect(f.monitor.currentDemuxerMaxBytes, f.ipc.cap, reason: f.mode);
      expect(
        f.decisions.map((event) => event['reason']),
        reason[f.mode] == null ? isEmpty : [reason[f.mode]],
        reason: f.mode,
      );
      if (promoted) {
        expect(f.decisions.single['effective_bytes'], 640 * _mib);
        f.memory.bytes = 256 * _mib;
        await f.monitor.sampleOnce();
      }
      if (f.mode == 'timeout') expect(f.ipc.connectCalls, 2);
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    for (final f in fixtures.where(
      (f) => f.mode == 'approved' || f.mode == 'timeout',
    )) {
      expect(f.ipc.cap, 320 * _mib);
      expect(f.monitor.currentCacheSecs, 90);
      f.memory.bytes = 8 * 1024 * _mib;
      await f.monitor.sampleOnce();
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    for (final f in fixtures.where(
      (f) => f.mode == 'approved' || f.mode == 'timeout',
    )) {
      expect(f.ipc.cap, 640 * _mib);
      expect(f.monitor.currentCacheSecs, 90);
    }
  });

  test('菜单复用缓存时长和预算，保留后向空间且不枚举 Title', () async {
    final probe = _CountingProbe();
    final coordinator = IsoCacheCoordinator(
      policyService: CachePolicyService(
        store: store,
        mediaProbe: probe,
        memoryProvider: const _FixedMemoryProvider(8 * 1024 * 1024 * 1024),
        logger: (_) {},
      ),
      logger: (_) {},
    );
    final plan = await coordinator.buildMenuPlan(
      logicalSourceUrl: 'https://dav.invalid/disc.iso',
      totalBytes: 30 * 1024 * 1024 * 1024,
    );
    expect(plan.bridgeBlockCount, 256);
    expect(plan.prefetchBlocks, 192);
    expect(plan.cacheSecs, 120);
    await store.save(CachePolicyConfig.defaults().copyWith(baseCacheSecs: 240));
    final longer = await coordinator.buildMenuPlan(
      logicalSourceUrl: 'https://dav.invalid/disc.iso',
      totalBytes: 30 * 1024 * 1024 * 1024,
    );
    expect(longer.cacheSecs, 240);
    await store.save(CachePolicyConfig.defaults().copyWith(enabled: false));
    final disabled = await coordinator.buildMenuPlan(
      logicalSourceUrl: 'https://dav.invalid/disc.iso',
      totalBytes: 30 * 1024 * 1024 * 1024,
    );
    expect(disabled, (bridgeBlockCount: 12, prefetchBlocks: 4, cacheSecs: 0));
    expect(probe.calls, 0);
  });

  test('菜单字节缓存和 MPV 预算合计不超过可用内存策略', () async {
    final coordinator = IsoCacheCoordinator(
      policyService: CachePolicyService(
        store: store,
        memoryProvider: const _FixedMemoryProvider(1024 * 1024 * 1024),
        logger: (_) {},
      ),
      logger: (_) {},
    );
    final plan = await coordinator.buildMenuPlan(
      logicalSourceUrl: 'https://dav.invalid/disc.iso',
      totalBytes: 30 * 1024 * 1024 * 1024,
    );
    expect(
      plan.bridgeBlockCount * 4 * 1024 * 1024 + 16 * 1024 * 1024,
      lessThanOrEqualTo(1024 * 1024 * 1024 * .35),
    );
    expect(plan.prefetchBlocks, lessThan(plan.bridgeBlockCount));
  });

  test('按 Title 码率拆分 Bridge 与 MPV，总量不突破策略预算', () async {
    final logs = <String>[];
    final intelligence = _RecordingIntelligence();
    final memory = const _FixedMemoryProvider(4 * 1024 * 1024 * 1024);
    final policy = CachePolicyService(
      store: store,
      memoryProvider: memory,
      intelligence: intelligence,
      logger: logs.add,
    );
    final coordinator = IsoCacheCoordinator(
      policyService: policy,
      intelligence: intelligence,
      memoryProvider: memory,
      logger: logs.add,
    );
    const sourceUrl =
        'https://dav.example/media/DISC.iso?token=temporary-secret';
    final plan = await coordinator.buildSessionPlan(
      logicalSourceUrl: sourceUrl,
      titles: const [
        IsoCacheTitleContext(
          programmeId: '00001',
          streamSize: 18 * 1024 * 1024 * 1024,
          duration: Duration(hours: 1),
        ),
        IsoCacheTitleContext(
          programmeId: '00002',
          streamSize: 2 * 1024 * 1024 * 1024,
          duration: Duration(hours: 1),
        ),
      ],
    );

    expect(plan.prefetchBlocks, inInclusiveRange(4, 12));
    expect(plan.bridgeBlockCount, plan.prefetchBlocks + 2);
    for (final titlePlan in plan.titlePlans.values) {
      expect(
        plan.bridgeBytes + titlePlan.mpvMaxBytes,
        lessThanOrEqualTo(titlePlan.memoryBudgetBytes),
      );
      expect(titlePlan.mpvMaxBytes, lessThanOrEqualTo(512 * 1024 * 1024));
    }
    expect(intelligence.adviceUrls, everyElement(sourceUrl));
    expect(intelligence.bitrateUrls, everyElement(sourceUrl));
    expect([
      ...intelligence.adviceUrls,
      ...intelligence.bitrateUrls,
    ], everyElement(isNot(contains('127.0.0.1'))));
    expect(
      logs,
      anyElement(contains('[SPCacheSystem][ISO] Plan ready: bridge=')),
    );
    expect(logs, everyElement(isNot(matches(RegExp(r'[\u3400-\u9fff]')))));
    coordinator.dispose();
  });

  test('学习服务失败时保留基础策略并记录诊断', () async {
    final logs = <String>[];
    final intelligence = _FailingIntelligence();
    final memory = const _FixedMemoryProvider(4 * 1024 * 1024 * 1024);
    final coordinator = IsoCacheCoordinator(
      policyService: CachePolicyService(
        store: store,
        memoryProvider: memory,
        intelligence: intelligence,
        logger: logs.add,
      ),
      intelligence: intelligence,
      memoryProvider: memory,
      logger: logs.add,
    );

    final plan = await coordinator.buildSessionPlan(
      logicalSourceUrl: 'https://dav.example/media/DISC.iso',
      titles: const [
        IsoCacheTitleContext(
          programmeId: '00001',
          streamSize: 4 * 1024 * 1024 * 1024,
          duration: Duration(hours: 1),
        ),
      ],
    );
    await Future<void>.delayed(Duration.zero);

    expect(plan.titlePlans, contains('00001'));
    expect(logs, anyElement(contains('original policy retained')));
    expect(logs, anyElement(contains('Bitrate learning write failed')));
    expect(logs, everyElement(isNot(matches(RegExp(r'[\u3400-\u9fff]')))));
    coordinator.dispose();
  });
}
