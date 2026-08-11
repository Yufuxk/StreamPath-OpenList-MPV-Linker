import 'dart:math' as math;

import '../models/cache_learning_data.dart';
import '../models/cache_policy_config.dart';
import '../store/cache_intelligence_config_store.dart';
import '../store/cache_intelligence_learning_store.dart';
import 'storage_classifier.dart';

/// 播放门面依赖的智能顾问抽象。未来替换模型时只需实现此接口。
abstract class CacheIntelligenceProvider {
  Future<CacheIntelligenceAdvice> advise({
    required String url,
    required int baseCacheSecs,
    int? fileSizeBytes,
    double? currentBitrateMbps,
    String? resolution,
  });

  Future<void> observeBitrate({
    required String url,
    required double bitrateMbps,
    int? fileSizeBytes,
    String? resolution,
  });

  Future<void> observeSession({
    required String url,
    required PlaybackSessionOutcome outcome,
  });
}

/// 本地轻量自适应实现：流式统计 + 存储画像 + 有界策略修正。
class LocalCacheIntelligenceService implements CacheIntelligenceProvider {
  LocalCacheIntelligenceService({
    required CacheIntelligenceConfigStore configStore,
    required CacheIntelligenceLearningStore learningStore,
    this.classifier = const StorageClassifier(),
  }) : _configStore = configStore, // ignore: prefer_initializing_formals
       _learningStore = learningStore; // ignore: prefer_initializing_formals

  final CacheIntelligenceConfigStore _configStore;
  final CacheIntelligenceLearningStore _learningStore;
  final StorageClassifier classifier;

  @override
  Future<CacheIntelligenceAdvice> advise({
    required String url,
    required int baseCacheSecs,
    int? fileSizeBytes,
    double? currentBitrateMbps,
    String? resolution,
  }) async {
    final config = await _configStore.load();
    final storageType = classifier.classify(url);
    if (!config.enabled) {
      return CacheIntelligenceAdvice(
        enabled: false,
        applyOptimizations: false,
        storageType: storageType,
        suggestedBaseCacheSecs: baseCacheSecs,
        confidence: 0,
        reasonCodes: const ['intelligence-disabled'],
      );
    }

    return _learningStore.read((data) {
      final reasons = <String>[];
      double? predictedBitrate;
      if (config.bitratePredictionEnabled &&
          (currentBitrateMbps == null || currentBitrateMbps <= 0)) {
        for (final key in _bitrateLookupKeys(
          url: url,
          fileSizeBytes: fileSizeBytes,
          resolution: resolution,
        )) {
          final stats = data.bitrateBuckets[key];
          if (stats != null && stats.count >= config.minSamples) {
            predictedBitrate = (stats.mean + stats.standardDeviation * 0.5)
                .clamp(0.05, 500.0);
            reasons.add('bitrate-history:${stats.count}');
            break;
          }
        }
      }

      final origin = classifier.originHash(url);
      final source = data.sourceProfiles[origin];
      final global = data.globalProfile;
      final sourceConfidence = source == null
          ? 0.0
          : (source.sessionCount / config.minSamples).clamp(0.0, 1.0);
      final habitConfidence = (global.sessionCount / config.minSamples).clamp(
        0.0,
        1.0,
      );
      var storageConfidence = 0.0;
      var adjustment = 0.0;

      if (config.storageOptimizationEnabled) {
        final prior = switch (storageType) {
          CacheStorageType.local => -0.12,
          CacheStorageType.lan => -0.06,
          CacheStorageType.cloud => 0.08,
          CacheStorageType.remote => 0.10,
          CacheStorageType.unknown => 0.0,
        };
        // 无样本时先验只占四分之一；实测样本足够后才逐步增强。
        storageConfidence = prior == 0
            ? sourceConfidence
            : 0.25 + sourceConfidence * 0.75;
        adjustment += prior * storageConfidence;
        if (prior != 0) reasons.add('storage:${storageType.jsonValue}');

        if (source != null && source.sessionCount >= config.minSamples) {
          if (source.stallRate >= 0.20) {
            adjustment += 0.08;
            reasons.add('source-stall-rate-high');
          }
          final throughput = source.throughputMbps;
          final bitrate = currentBitrateMbps ?? predictedBitrate;
          if (bitrate != null &&
              bitrate > 0 &&
              throughput.count >= config.minSamples) {
            final factor = throughput.mean / bitrate;
            if (factor < 1.5) {
              adjustment += 0.07;
              reasons.add('source-bandwidth-tight');
            } else if (factor > 5 && source.stallRate < 0.05) {
              adjustment -= 0.05;
              reasons.add('source-bandwidth-abundant');
            }
          }
        }
      }

      if (config.habitLearningEnabled &&
          global.sessionCount >= config.minSamples) {
        final forwardPerSession =
            global.forwardSeekCount / math.max(1, global.sessionCount);
        final backwardPerSession =
            global.backwardSeekCount / math.max(1, global.sessionCount);
        if (forwardPerSession >= 1) {
          adjustment += 0.03;
          reasons.add('habit-forward-seek');
        }
        if (backwardPerSession >= 1) {
          adjustment += 0.03;
          reasons.add('habit-backward-seek');
        }
        if (global.completionRate < 0.25) {
          adjustment -= 0.05;
          reasons.add('habit-low-completion');
        }
      }

      final confidence = math.max(storageConfidence, habitConfidence);
      final bounded = adjustment.clamp(
        -config.maxAdjustmentRatio,
        config.maxAdjustmentRatio,
      );
      final suggested = (baseCacheSecs * (1 + bounded)).round().clamp(
        CachePolicyConfig.minBaseCacheSecs,
        CachePolicyConfig.maxBaseCacheSecs,
      );
      if (suggested == baseCacheSecs) reasons.add('neutral');
      if (!config.applyOptimizations) reasons.add('shadow-mode');

      return CacheIntelligenceAdvice(
        enabled: true,
        applyOptimizations: config.applyOptimizations,
        storageType: storageType,
        suggestedBaseCacheSecs: suggested,
        confidence: confidence,
        reasonCodes: List<String>.unmodifiable(reasons),
        predictedBitrateMbps: predictedBitrate,
      );
    });
  }

  @override
  Future<void> observeBitrate({
    required String url,
    required double bitrateMbps,
    int? fileSizeBytes,
    String? resolution,
  }) async {
    try {
      final config = await _configStore.load();
      if (!config.enabled ||
          !config.bitratePredictionEnabled ||
          !bitrateMbps.isFinite ||
          bitrateMbps < 0.05 ||
          bitrateMbps > 500) {
        return;
      }
      final keys = _bitrateLookupKeys(
        url: url,
        fileSizeBytes: fileSizeBytes,
        resolution: resolution,
      );
      await _learningStore.update((data) {
        for (final key in keys) {
          data.bitrateBuckets
              .putIfAbsent(key, RunningStatistics.new)
              .add(bitrateMbps);
        }
      });
    } catch (_) {}
  }

  @override
  Future<void> observeSession({
    required String url,
    required PlaybackSessionOutcome outcome,
  }) async {
    try {
      final config = await _configStore.load();
      if (!config.enabled ||
          !outcome.hasUsefulSamples ||
          (!config.storageOptimizationEnabled &&
              !config.habitLearningEnabled)) {
        return;
      }
      final origin = classifier.originHash(url);
      final now = DateTime.now();
      await _learningStore.update((data) {
        if (config.storageOptimizationEnabled) {
          data.sourceProfiles
              .putIfAbsent(origin, SourceLearningProfile.new)
              .add(outcome, now);
        }
        if (config.habitLearningEnabled) {
          data.globalProfile.add(outcome, now);
        }
      });
    } catch (_) {}
  }

  static List<String> _bitrateLookupKeys({
    required String url,
    int? fileSizeBytes,
    String? resolution,
  }) {
    final container = _containerOf(url);
    final resolutionBucket = _resolutionBucket(resolution);
    final sizeBucket = _sizeBucket(fileSizeBytes);
    return <String>[
      'exact|$container|$resolutionBucket|$sizeBucket',
      'resolution|$resolutionBucket',
      'container|$container',
      'global',
    ];
  }

  static String _containerOf(String url) {
    try {
      final path = Uri.parse(url).path;
      final slash = path.lastIndexOf('/');
      final dot = path.lastIndexOf('.');
      if (dot > slash && dot < path.length - 1) {
        return path.substring(dot + 1).toLowerCase();
      }
    } catch (_) {}
    return 'unknown';
  }

  static String _resolutionBucket(String? resolution) {
    if (resolution == null || resolution.trim().isEmpty) return 'unknown';
    final numbers = RegExp(r'\d+')
        .allMatches(resolution)
        .map((match) => int.tryParse(match.group(0) ?? '') ?? 0);
    final values = numbers.toList();
    final height = values.length >= 2
        ? math.min(values[0], values[1])
        : values.firstOrNull;
    if (height == null || height <= 0) return 'unknown';
    if (height <= 576) return 'sd';
    if (height <= 800) return '720p';
    if (height <= 1200) return '1080p';
    if (height <= 1600) return '1440p';
    if (height <= 2400) return '2160p';
    return '8k';
  }

  static String _sizeBucket(int? bytes) {
    if (bytes == null || bytes <= 0) return 'unknown';
    const mib = 1024 * 1024;
    const gib = 1024 * mib;
    if (bytes < 500 * mib) return 'lt500m';
    if (bytes < 2 * gib) return 'lt2g';
    if (bytes < 8 * gib) return 'lt8g';
    if (bytes < 30 * gib) return 'lt30g';
    return 'gte30g';
  }
}
