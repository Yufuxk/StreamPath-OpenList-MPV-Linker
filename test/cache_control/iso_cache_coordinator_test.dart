import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/features/cache_control/cache_policy_service.dart';
import 'package:streampath/features/cache_control/intelligence/cache_intelligence_service.dart';
import 'package:streampath/features/cache_control/iso_cache_coordinator.dart';
import 'package:streampath/features/cache_control/models/cache_learning_data.dart';
import 'package:streampath/features/cache_control/models/cache_policy_config.dart';
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
    expect(plan.bridgeBlockCount * 4 * 1024 * 1024 + 16 * 1024 * 1024,
        lessThanOrEqualTo(1024 * 1024 * 1024 * .35));
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
          mplsId: '00001',
          streamSize: 18 * 1024 * 1024 * 1024,
          duration: Duration(hours: 1),
        ),
        IsoCacheTitleContext(
          mplsId: '00002',
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
      anyElement(
        contains('[SPCacheSystem][ISO] Plan ready: bridge='),
      ),
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
          mplsId: '00001',
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
