import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/features/cache_control/engine/cache_policy_engine.dart';
import 'package:streampath/features/cache_control/models/cache_policy_config.dart';
import 'package:streampath/features/cache_control/models/cache_policy_result.dart';

const _mb = 1024 * 1024;
const _gb = 1024 * _mb;

void main() {
  const engine = CachePolicyEngine();

  group('Layer 1 内存预算', () {
    test('可用内存 × 安全比例', () {
      // 8GB × 25% = 2GB
      expect(
        engine.computeMemoryBudget(
          budgetRatio: 0.25,
          availableMemoryBytes: 8 * _gb,
        ),
        2 * _gb,
      );
    });

    test('内存未知/非法时使用 1GiB 保守兜底', () {
      expect(
        engine.computeMemoryBudget(budgetRatio: 0.25),
        CachePolicyEngine.fallbackMemoryBudgetBytes,
      );
      expect(
        engine.computeMemoryBudget(budgetRatio: 0.25, availableMemoryBytes: -1),
        CachePolicyEngine.fallbackMemoryBudgetBytes,
      );
      expect(
        engine.computeMemoryBudget(budgetRatio: 0.25, availableMemoryBytes: 0),
        CachePolicyEngine.fallbackMemoryBudgetBytes,
      );
    });
  });

  group('缓存目标诊断估算', () {
    test('按码率、安全系数和字节上限计算可达秒数', () {
      expect(
        engine.estimateReachableCacheSecs(
          demuxerMaxBytes: 1258670080,
          bitrateMbps: 56,
        ),
        138,
      );
      expect(
        engine.estimateRequiredCacheBytes(cacheSecs: 540, bitrateMbps: 56),
        4914000000,
      );
    });

    test('码率未知或输入非法时不伪造可达时长', () {
      expect(engine.estimateReachableCacheSecs(demuxerMaxBytes: _gb), isNull);
      expect(engine.estimateRequiredCacheBytes(cacheSecs: 120), isNull);
      expect(
        engine.estimateReachableCacheSecs(demuxerMaxBytes: 0, bitrateMbps: 10),
        isNull,
      );
    });
  });

  group('Layer 2 档位与模式', () {
    test('档位表按基准 120s 派生：720=60 / 1080=120 / 4K=180 / REMUX=240', () {
      expect(
        engine.pickBaseCacheSecs(
          mode: CachePolicyMode.auto,
          baseCacheSecs: 120,
          tier: MediaTier.hd720,
        ),
        60,
      );
      expect(
        engine.pickBaseCacheSecs(
          mode: CachePolicyMode.auto,
          baseCacheSecs: 120,
          tier: MediaTier.hd1080,
        ),
        120,
      );
      expect(
        engine.pickBaseCacheSecs(
          mode: CachePolicyMode.auto,
          baseCacheSecs: 120,
          tier: MediaTier.uhd4k,
        ),
        180,
      );
      expect(
        engine.pickBaseCacheSecs(
          mode: CachePolicyMode.auto,
          baseCacheSecs: 120,
          tier: MediaTier.remux,
        ),
        240,
      );
    });

    test('未指定档位时走基准档（1080P）', () {
      expect(
        engine.pickBaseCacheSecs(
          mode: CachePolicyMode.auto,
          baseCacheSecs: 120,
        ),
        120,
      );
    });

    test('模式缩放：economy 压缩、performance/remux 放大', () {
      final economy = engine.pickBaseCacheSecs(
        mode: CachePolicyMode.economy,
        baseCacheSecs: 120,
      );
      expect(economy, lessThan(120));

      final performance = engine.pickBaseCacheSecs(
        mode: CachePolicyMode.performance,
        baseCacheSecs: 120,
      );
      expect(performance, greaterThan(120));

      final remux = engine.pickBaseCacheSecs(
        mode: CachePolicyMode.remux,
        baseCacheSecs: 120,
        tier: MediaTier.remux,
      );
      // 240 × 1.25 = 300，在文档 REMUX 180~300s 区间上界。
      expect(remux, 300);
    });

    test('档位秒数 clamp 到 [10, 600]', () {
      final tiny = engine.pickBaseCacheSecs(
        mode: CachePolicyMode.economy,
        baseCacheSecs: CachePolicyConfig.minBaseCacheSecs,
        tier: MediaTier.hd720,
      );
      expect(tiny, greaterThanOrEqualTo(CachePolicyConfig.minBaseCacheSecs));

      final huge = engine.pickBaseCacheSecs(
        mode: CachePolicyMode.performance,
        baseCacheSecs: CachePolicyConfig.maxBaseCacheSecs,
        tier: MediaTier.remux,
      );
      expect(huge, CachePolicyConfig.maxBaseCacheSecs);
    });

    test('模式对预算比例缩放并 clamp', () {
      const config = CachePolicyConfig(mode: CachePolicyMode.performance);
      expect(engine.effectiveBudgetRatio(config), 0.3); // 0.25 × 1.2

      const economy = CachePolicyConfig(mode: CachePolicyMode.economy);
      expect(engine.effectiveBudgetRatio(economy), closeTo(0.15, 0.001));

      const maxed = CachePolicyConfig(
        mode: CachePolicyMode.performance,
        memoryBudgetRatio: 0.5,
      );
      expect(
        engine.effectiveBudgetRatio(maxed),
        CachePolicyConfig.maxMemoryBudgetRatio,
      );
    });
  });

  group('Layer 3 网络系数', () {
    test('factor = 带宽 / 码率', () {
      expect(
        engine.networkFactor(assumedBandwidthMbps: 200, bitrateMbps: 80),
        closeTo(2.5, 0.001),
      );
    });

    test('任一输入未知时返回 null（中性不修正）', () {
      expect(engine.networkFactor(assumedBandwidthMbps: 200), isNull);
      expect(engine.networkFactor(bitrateMbps: 80), isNull);
      expect(
        engine.networkFactor(assumedBandwidthMbps: 0, bitrateMbps: 80),
        isNull,
      );
    });

    test('>3 降档 20%，<1 增档 50%，1~3 保持', () {
      expect(engine.adjustCacheSecsForNetwork(120, 4.0), 96);
      expect(engine.adjustCacheSecsForNetwork(120, 2.0), 120);
      expect(engine.adjustCacheSecsForNetwork(120, 0.5), 180);
      expect(engine.adjustCacheSecsForNetwork(120, null), 120);
    });

    test('网络修正后仍 clamp 到合法范围', () {
      final low = engine.adjustCacheSecsForNetwork(5, 0.1);
      expect(low, CachePolicyConfig.minBaseCacheSecs);

      final high = engine.adjustCacheSecsForNetwork(
        CachePolicyConfig.maxBaseCacheSecs,
        0.1, // 增档 1.5 倍 → 900，clamp 回 600
      );
      expect(high, CachePolicyConfig.maxBaseCacheSecs);
    });
  });

  group('Health Score', () {
    test('满分场景：网络远高 + 缓存充足 + 内存健康 = 100', () {
      expect(
        engine.computeHealthScore(
          networkFactor: 2.5,
          cacheSecs: 240,
          availableMemoryBytes: 16 * _gb,
        ),
        100,
      );
    });

    test('危险场景：网络低于 + 缓存不足 + 内存紧张 = 20', () {
      expect(
        engine.computeHealthScore(
          networkFactor: 0.5,
          cacheSecs: 30,
          availableMemoryBytes: 3 * _gb,
        ),
        20, // 10 + 10 + 0
      );
    });

    test('中性场景：未知网络 = 25 + 缓存一般 25 + 内存压力 10 = 60', () {
      expect(
        engine.computeHealthScore(
          networkFactor: null,
          cacheSecs: 120,
          availableMemoryBytes: 6 * _gb,
        ),
        60,
      );
    });
  });

  group('buildPolicy 综合编排', () {
    test('enabled=false 时返回 skipped 且无参数', () {
      const config = CachePolicyConfig(enabled: false);
      final result = engine.buildPolicy(config: config);
      expect(result.skipped, isTrue);
      expect(result.args, isEmpty);
    });

    test('默认上下文（码率未知）：上限 = 内存预算，目标秒数 120s', () {
      const config = CachePolicyConfig();
      final result = engine.buildPolicy(config: config);
      expect(result.skipped, isFalse);
      expect(result.cacheSecs, 120);
      // 码率未知：不再用假设码率估算，直接以预算为上限
      // （内存未知走 1GiB 兜底预算）。
      expect(result.demuxerMaxBytes, 1024 * 1024 * 1024);
      expect(result.fullCache, isFalse);
      expect(result.args, [
        '--cache=yes',
        '--cache-secs=120',
        '--demuxer-max-bytes=${1024 * 1024 * 1024}',
        '--cache-pause=yes',
        '--cache-pause-initial=yes',
        '--cache-pause-wait=${CachePolicyEngine.initialBufferWaitSecs}',
      ]);
      expect(result.healthScore, greaterThan(0));
      expect(result.layers.length, greaterThanOrEqualTo(4));
      expect(
        result.layers.any(
          (l) => l.contains('bitrate unknown -> use memory budget'),
        ),
        isTrue,
      );
    });

    test('码率已知：上限 = 码率 × 秒数 × 安全系数（小于预算时不被截断）', () {
      const config = CachePolicyConfig();
      final result = engine.buildPolicy(
        config: config,
        bitrateMbps: 8,
        availableMemoryBytes: 16 * _gb, // 预算 4GiB，不截断
      );
      // 8Mbps × 120s × 125000 × 安全系数 1.3 ≈ 156,000,000 字节。
      final expected = (8 * 120 * 125000 * CachePolicyEngine.safetyFactor)
          .round();
      expect(result.demuxerMaxBytes, expected);
      expect(result.layers.any((l) => l.contains('8.0Mbps x 120s')), isTrue);
    });

    test('小文件全量缓存：100MiB < 500MiB 阈值且 < 预算', () {
      const config = CachePolicyConfig();
      final result = engine.buildPolicy(
        config: config,
        fileSizeBytes: 100 * _mb,
      );
      expect(result.fullCache, isTrue);
      final withOverhead =
          (100 * _mb * CachePolicyEngine.fullCacheOverheadFactor).ceil();
      expect(result.demuxerMaxBytes, withOverhead);
      expect(result.cacheSecs, CachePolicyEngine.fullCacheFallbackSecs);
      expect(result.args, contains('--demuxer-max-bytes=$withOverhead'));
    });

    test('超过全量阈值的大文件不走全量策略（码率未知 → 上限 = 预算）', () {
      const config = CachePolicyConfig();
      final result = engine.buildPolicy(config: config, fileSizeBytes: 2 * _gb);
      expect(result.fullCache, isFalse);
      // 码率未知：上限 = 兜底预算 1GiB。
      expect(result.demuxerMaxBytes, 1024 * 1024 * 1024);
    });

    test('内存紧张时高码率上限被预算截断', () {
      const config = CachePolicyConfig(); // 25% 预算
      final result = engine.buildPolicy(
        config: config,
        bitrateMbps: 100,
        availableMemoryBytes: 4 * _gb, // 预算 1GiB
      );
      // 100Mbps × 120s = 1.5GiB → 截断到 1GiB。
      expect(result.demuxerMaxBytes, 1 * _gb);
    });

    test('网络充足时降档、危险时增档', () {
      const rich = CachePolicyConfig(assumedBandwidthMbps: 400);
      final richResult = engine.buildPolicy(config: rich, bitrateMbps: 8);
      expect(richResult.cacheSecs, 96); // 120 × 0.8
      expect(richResult.networkFactor, closeTo(50, 0.001));

      const poor = CachePolicyConfig(assumedBandwidthMbps: 4);
      final poorResult = engine.buildPolicy(config: poor, bitrateMbps: 8);
      expect(poorResult.cacheSecs, 180); // 120 × 1.5
    });

    test('显式 REMUX 档位放大缓存秒数', () {
      const config = CachePolicyConfig();
      final result = engine.buildPolicy(config: config, tier: MediaTier.remux);
      expect(result.cacheSecs, 240);
    });
  });
}
