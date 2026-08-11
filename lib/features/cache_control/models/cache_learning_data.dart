import 'dart:math' as math;

import '../intelligence/storage_classifier.dart';

/// O(1) 流式均值/方差（Welford）。
class RunningStatistics {
  RunningStatistics({this.count = 0, this.mean = 0, this.m2 = 0});

  int count;
  double mean;
  double m2;

  double get variance => count > 1 ? math.max(0, m2 / (count - 1)) : 0;
  double get standardDeviation => math.sqrt(variance);

  void add(double value) {
    if (!value.isFinite) return;
    count++;
    final delta = value - mean;
    mean += delta / count;
    m2 += delta * (value - mean);
  }

  void reset() {
    count = 0;
    mean = 0;
    m2 = 0;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'count': count,
    'mean': mean,
    'm2': m2,
  };

  factory RunningStatistics.fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return RunningStatistics();
    final count = raw['count'];
    final mean = raw['mean'];
    final m2 = raw['m2'];
    return RunningStatistics(
      count: count is num ? math.max(0, count.toInt()) : 0,
      mean: mean is num && mean.toDouble().isFinite ? mean.toDouble() : 0,
      m2: m2 is num && m2.toDouble().isFinite ? math.max(0, m2.toDouble()) : 0,
    );
  }
}

/// 监控器输出的不可变会话聚合结果；不包含 URL 或标题。
class PlaybackSessionOutcome {
  const PlaybackSessionOutcome({
    required this.sampleCount,
    required this.stallCount,
    required this.forwardSeekCount,
    required this.backwardSeekCount,
    required this.pausedSampleCount,
    this.meanNetworkSpeedBps,
    this.networkSpeedStdDevBps,
    this.lastPositionSec,
    this.durationSec,
    required this.completed,
  });

  final int sampleCount;
  final int stallCount;
  final int forwardSeekCount;
  final int backwardSeekCount;
  final int pausedSampleCount;
  final double? meanNetworkSpeedBps;
  final double? networkSpeedStdDevBps;
  final double? lastPositionSec;
  final double? durationSec;
  final bool completed;

  bool get hasUsefulSamples => sampleCount > 0;
}

/// 单一来源的匿名聚合画像。
class SourceLearningProfile {
  SourceLearningProfile({
    this.sessionCount = 0,
    this.stalledSessionCount = 0,
    this.completedSessionCount = 0,
    this.forwardSeekCount = 0,
    this.backwardSeekCount = 0,
    RunningStatistics? throughputMbps,
    this.updatedAtEpochMs = 0,
  }) : throughputMbps = throughputMbps ?? RunningStatistics();

  int sessionCount;
  int stalledSessionCount;
  int completedSessionCount;
  int forwardSeekCount;
  int backwardSeekCount;
  final RunningStatistics throughputMbps;
  int updatedAtEpochMs;

  double get stallRate =>
      sessionCount == 0 ? 0 : stalledSessionCount / sessionCount;
  double get completionRate =>
      sessionCount == 0 ? 0 : completedSessionCount / sessionCount;

  void add(PlaybackSessionOutcome outcome, DateTime now) {
    if (!outcome.hasUsefulSamples) return;
    sessionCount++;
    if (outcome.stallCount > 0) stalledSessionCount++;
    if (outcome.completed) completedSessionCount++;
    forwardSeekCount += outcome.forwardSeekCount;
    backwardSeekCount += outcome.backwardSeekCount;
    final speed = outcome.meanNetworkSpeedBps;
    if (speed != null && speed > 0) throughputMbps.add(speed * 8 / 1000000);
    updatedAtEpochMs = now.millisecondsSinceEpoch;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sessionCount': sessionCount,
    'stalledSessionCount': stalledSessionCount,
    'completedSessionCount': completedSessionCount,
    'forwardSeekCount': forwardSeekCount,
    'backwardSeekCount': backwardSeekCount,
    'throughputMbps': throughputMbps.toJson(),
    'updatedAtEpochMs': updatedAtEpochMs,
  };

  factory SourceLearningProfile.fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return SourceLearningProfile();
    int safeInt(String key) {
      final value = raw[key];
      return value is num ? math.max(0, value.toInt()) : 0;
    }

    return SourceLearningProfile(
      sessionCount: safeInt('sessionCount'),
      stalledSessionCount: safeInt('stalledSessionCount'),
      completedSessionCount: safeInt('completedSessionCount'),
      forwardSeekCount: safeInt('forwardSeekCount'),
      backwardSeekCount: safeInt('backwardSeekCount'),
      throughputMbps: RunningStatistics.fromJson(raw['throughputMbps']),
      updatedAtEpochMs: safeInt('updatedAtEpochMs'),
    );
  }
}

/// 智能缓存学习文件的内存模型。
class CacheLearningData {
  CacheLearningData({
    Map<String, RunningStatistics>? bitrateBuckets,
    Map<String, SourceLearningProfile>? sourceProfiles,
    SourceLearningProfile? globalProfile,
  }) : bitrateBuckets = bitrateBuckets ?? <String, RunningStatistics>{},
       sourceProfiles = sourceProfiles ?? <String, SourceLearningProfile>{},
       globalProfile = globalProfile ?? SourceLearningProfile();

  static const int schemaVersion = 1;

  final Map<String, RunningStatistics> bitrateBuckets;
  final Map<String, SourceLearningProfile> sourceProfiles;
  final SourceLearningProfile globalProfile;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schemaVersion': schemaVersion,
    'bitrateBuckets': bitrateBuckets.map(
      (key, value) => MapEntry(key, value.toJson()),
    ),
    'sourceProfiles': sourceProfiles.map(
      (key, value) => MapEntry(key, value.toJson()),
    ),
    'globalProfile': globalProfile.toJson(),
  };

  factory CacheLearningData.fromJson(Map<String, dynamic> json) {
    Map<String, T> decodeMap<T>(Object? raw, T Function(Object?) decode) {
      if (raw is! Map<String, dynamic>) return <String, T>{};
      return raw.map((key, value) => MapEntry(key, decode(value)));
    }

    return CacheLearningData(
      bitrateBuckets: decodeMap(
        json['bitrateBuckets'],
        RunningStatistics.fromJson,
      ),
      sourceProfiles: decodeMap(
        json['sourceProfiles'],
        SourceLearningProfile.fromJson,
      ),
      globalProfile: SourceLearningProfile.fromJson(json['globalProfile']),
    );
  }
}

/// 智能顾问输出。是否应用由 [applyOptimizations] 明确标记。
class CacheIntelligenceAdvice {
  const CacheIntelligenceAdvice({
    required this.enabled,
    required this.applyOptimizations,
    required this.storageType,
    required this.suggestedBaseCacheSecs,
    required this.confidence,
    required this.reasonCodes,
    this.predictedBitrateMbps,
  });

  final bool enabled;
  final bool applyOptimizations;
  final CacheStorageType storageType;
  final int suggestedBaseCacheSecs;
  final double confidence;
  final List<String> reasonCodes;
  final double? predictedBitrateMbps;
}
