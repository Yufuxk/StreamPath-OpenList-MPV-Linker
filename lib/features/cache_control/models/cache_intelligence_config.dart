/// 第三阶段本地智能缓存配置（独立文件 `cache_intelligence.json`）。
///
/// 默认开启采集但不应用优化，即“影子模式”。所有数值在解析时收敛，
/// 配置损坏也不会把非法参数带入播放链路。
class CacheIntelligenceConfig {
  const CacheIntelligenceConfig({
    this.enabled = true,
    this.applyOptimizations = false,
    this.bitratePredictionEnabled = true,
    this.storageOptimizationEnabled = true,
    this.habitLearningEnabled = true,
    this.minSamples = defaultMinSamples,
    this.maxAdjustmentRatio = defaultMaxAdjustmentRatio,
  });

  static const int defaultMinSamples = 5;
  static const int minMinSamples = 2;
  static const int maxMinSamples = 100;
  static const double defaultMaxAdjustmentRatio = 0.20;
  static const double minMaxAdjustmentRatio = 0.05;
  static const double maxMaxAdjustmentRatio = 0.30;

  final bool enabled;
  final bool applyOptimizations;
  final bool bitratePredictionEnabled;
  final bool storageOptimizationEnabled;
  final bool habitLearningEnabled;
  final int minSamples;
  final double maxAdjustmentRatio;

  static CacheIntelligenceConfig defaults() => const CacheIntelligenceConfig();

  Map<String, dynamic> toJson() => <String, dynamic>{
    'enabled': enabled,
    'applyOptimizations': applyOptimizations,
    'bitratePredictionEnabled': bitratePredictionEnabled,
    'storageOptimizationEnabled': storageOptimizationEnabled,
    'habitLearningEnabled': habitLearningEnabled,
    'minSamples': minSamples,
    'maxAdjustmentRatio': maxAdjustmentRatio,
  };

  factory CacheIntelligenceConfig.fromJson(Map<String, dynamic> json) {
    final minSamples = json['minSamples'];
    final maxAdjustment = json['maxAdjustmentRatio'];
    return CacheIntelligenceConfig(
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      applyOptimizations: json['applyOptimizations'] is bool
          ? json['applyOptimizations'] as bool
          : false,
      bitratePredictionEnabled: json['bitratePredictionEnabled'] is bool
          ? json['bitratePredictionEnabled'] as bool
          : true,
      storageOptimizationEnabled: json['storageOptimizationEnabled'] is bool
          ? json['storageOptimizationEnabled'] as bool
          : true,
      habitLearningEnabled: json['habitLearningEnabled'] is bool
          ? json['habitLearningEnabled'] as bool
          : true,
      minSamples: minSamples is num
          ? minSamples.toInt().clamp(minMinSamples, maxMinSamples)
          : defaultMinSamples,
      maxAdjustmentRatio: maxAdjustment is num
          ? maxAdjustment.toDouble().clamp(
              minMaxAdjustmentRatio,
              maxMaxAdjustmentRatio,
            )
          : defaultMaxAdjustmentRatio,
    );
  }
}
