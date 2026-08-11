import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/features/cache_control/cache_policy_service.dart';
import 'package:streampath/features/cache_control/intelligence/cache_intelligence_service.dart';
import 'package:streampath/features/cache_control/intelligence/storage_classifier.dart';
import 'package:streampath/features/cache_control/models/cache_learning_data.dart';
import 'package:streampath/features/cache_control/models/cache_policy_result.dart';
import 'package:streampath/features/cache_control/providers/system_memory_provider.dart';
import 'package:streampath/features/cache_control/store/cache_policy_config_store.dart';

void main() {
  late Directory tempDir;
  late CachePolicyConfigStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('cache_int_integration_');
    store = CachePolicyConfigStore.forPath(
      '${tempDir.path}${Platform.pathSeparator}cache_policy.json',
    );
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  Future<CachePolicyResult> build(CacheIntelligenceProvider intelligence) {
    return CachePolicyService(
      store: store,
      memoryProvider: const _Memory(),
      intelligence: intelligence,
      logger: (_) {},
    ).buildPolicy(
      url: 'https://media.example/movie.mkv',
      knownFileSizeBytes: 7 * 1024 * 1024 * 1024,
      tier: MediaTier.hd1080,
    );
  }

  test('影子模式给出建议但最终策略与原基线一致', () async {
    final result = await build(
      _Intelligence(
        const CacheIntelligenceAdvice(
          enabled: true,
          applyOptimizations: false,
          storageType: CacheStorageType.remote,
          suggestedBaseCacheSecs: 240,
          confidence: 1,
          reasonCodes: ['shadow-mode'],
          predictedBitrateMbps: 40,
        ),
      ),
    );
    expect(result.cacheSecs, 120);
    expect(result.bitrateMbps, isNull);
  });

  test('应用模式只通过引擎输入应用建议和历史码率', () async {
    final result = await build(
      _Intelligence(
        const CacheIntelligenceAdvice(
          enabled: true,
          applyOptimizations: true,
          storageType: CacheStorageType.remote,
          suggestedBaseCacheSecs: 240,
          confidence: 1,
          reasonCodes: ['storage:remote'],
          predictedBitrateMbps: 40,
        ),
      ),
    );
    expect(result.cacheSecs, 240);
    expect(result.bitrateMbps, 40);
    expect(result.bitrateSource, 'Level4 history prediction');
    expect(result.demuxerMaxBytes, lessThanOrEqualTo(result.memoryBudgetBytes));
  });

  test('智能顾问异常时完整回退原策略', () async {
    final result = await build(_Intelligence.throwing());
    expect(result.cacheSecs, 120);
    expect(result.bitrateMbps, isNull);
  });

  test('智能顾问永久不返回时按截止时间回退，不阻塞起播', () async {
    final stopwatch = Stopwatch()..start();
    final result = await build(_Intelligence.hanging());
    stopwatch.stop();
    expect(result.cacheSecs, 120);
    expect(result.bitrateMbps, isNull);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
  });
}

class _Memory extends SystemMemoryProvider {
  const _Memory();

  @override
  Future<int?> availableMemoryBytes() async => 8 * 1024 * 1024 * 1024;
}

class _Intelligence implements CacheIntelligenceProvider {
  _Intelligence(this._advice) : _throwAdvice = false, _hangAdvice = false;
  _Intelligence.throwing()
    : _advice = null,
      _throwAdvice = true,
      _hangAdvice = false;
  _Intelligence.hanging()
    : _advice = null,
      _throwAdvice = false,
      _hangAdvice = true;

  final CacheIntelligenceAdvice? _advice;
  final bool _throwAdvice;
  final bool _hangAdvice;

  @override
  Future<CacheIntelligenceAdvice> advise({
    required String url,
    required int baseCacheSecs,
    int? fileSizeBytes,
    double? currentBitrateMbps,
    String? resolution,
  }) async {
    if (_hangAdvice) return Completer<CacheIntelligenceAdvice>().future;
    if (_throwAdvice) throw StateError('模拟智能模块失败');
    return _advice!;
  }

  @override
  Future<void> observeBitrate({
    required String url,
    required double bitrateMbps,
    int? fileSizeBytes,
    String? resolution,
  }) async {}

  @override
  Future<void> observeSession({
    required String url,
    required PlaybackSessionOutcome outcome,
  }) async {}
}
