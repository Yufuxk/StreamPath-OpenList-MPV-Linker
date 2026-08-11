/// 缓存策略模式（对应设计方案「推荐策略等级」：自动 / 性能 / 节省 / 蓝光）。
///
/// 模式通过缩放因子影响内存预算与缓存秒数：
/// - [CachePolicyMode.economy]：压缩缓存，适合低内存设备；
/// - [CachePolicyMode.performance]：更积极缓存，适合高性能设备；
/// - [CachePolicyMode.remux]：允许更高内存预算并放大高码率档位；
/// - [CachePolicyMode.auto]：基准档位，不加缩放。
enum CachePolicyMode {
  auto('auto', '自动模式'),
  performance('performance', '性能模式'),
  economy('economy', '节省模式'),
  remux('remux', '蓝光模式');

  const CachePolicyMode(this.jsonValue, this.label);

  /// JSON 中的字符串值。
  final String jsonValue;

  /// 中文显示名（诊断/日志用）。
  final String label;

  /// 解析 JSON 值；未知值回退 [CachePolicyMode.auto]。
  static CachePolicyMode fromJson(Object? value) {
    for (final m in CachePolicyMode.values) {
      if (m.jsonValue == value) return m;
    }
    return CachePolicyMode.auto;
  }
}

/// MPV 智能缓存控制系统配置（独立配置文件 `cache_policy.json`）。
///
/// 与主配置 `stream_path_config.json` 完全独立：由本模块自行读写，
/// 设置页通过本模块存储接口编辑，不与连接信息混写，保证模块高解耦。
///
/// 所有数值字段都带边界收敛：JSON 中出现越界或非法值时不抛异常，
/// 而是收敛到边界值或默认值（缓存系统是播放链路的增强层，任何配置
/// 问题都不得阻断播放）。
class CachePolicyConfig {
  const CachePolicyConfig({
    this.enabled = true,
    this.mode = CachePolicyMode.auto,
    this.memoryBudgetRatio = defaultMemoryBudgetRatio,
    this.baseCacheSecs = defaultBaseCacheSecs,
    this.smallFileThresholdMB = defaultSmallFileThresholdMB,
    this.assumedBandwidthMbps,
    this.overrideUserCacheArgs = false,
  });

  // ── 边界常量 ─────────────────────────────────────────────────

  /// 内存预算比例默认值（设计方案：系统可用内存的 20%~30%）。
  static const double defaultMemoryBudgetRatio = 0.25;

  /// 内存预算比例合法范围。
  static const double minMemoryBudgetRatio = 0.05;
  static const double maxMemoryBudgetRatio = 0.50;

  /// 基准缓存秒数默认值（对应文档 1080P 档 120 秒）。
  static const int defaultBaseCacheSecs = 120;

  /// 基准缓存秒数合法范围（秒）。
  static const int minBaseCacheSecs = 10;
  static const int maxBaseCacheSecs = 600;

  /// 小文件全量缓存阈值默认值（MB，设计方案示例 500MB）。
  static const int defaultSmallFileThresholdMB = 500;

  /// 小文件阈值合法范围（MB）。
  static const int minSmallFileThresholdMB = 1;
  // 与 CachePolicyResult.fullCacheMaxBytes 对齐，避免出现配置合法但永远
  // 不可能命中全量缓存的区间。
  static const int maxSmallFileThresholdMB = 4096;

  // ── 字段 ─────────────────────────────────────────────────────

  /// 总开关：false 时缓存系统完全关闭，不注入任何缓存参数。
  final bool enabled;

  /// 策略模式（影响内存预算与缓存秒数的缩放）。
  final CachePolicyMode mode;

  /// 内存预算比例：最大缓存 = 系统可用内存 × 该比例。
  final double memoryBudgetRatio;

  /// 基准缓存秒数（1080P 档）；其余档位按比例派生。
  final int baseCacheSecs;

  /// 小文件全量缓存阈值（MB）：文件大小低于该值且低于内存预算时，
  /// 采用「高缓存接近本地播放」策略。
  final int smallFileThresholdMB;

  /// 假设的下行带宽（Mbps）；null 表示未知（网络系数按中性 1.0 处理，
  /// 不修正缓存档位）。第一版不做主动测速，真实带宽由播放中监控
  /// （第二阶段）获取，此处供用户手动预估。
  final double? assumedBandwidthMbps;

  /// 用户已在播放器参数模板中手动配置缓存参数时，是否仍覆盖注入。
  /// false（默认）：尊重手动配置，跳过本模块注入（安全优先）。
  final bool overrideUserCacheArgs;

  CachePolicyConfig copyWith({
    bool? enabled,
    CachePolicyMode? mode,
    double? memoryBudgetRatio,
    int? baseCacheSecs,
    int? smallFileThresholdMB,
    double? assumedBandwidthMbps,
    bool clearAssumedBandwidth = false,
    bool? overrideUserCacheArgs,
  }) {
    return CachePolicyConfig(
      enabled: enabled ?? this.enabled,
      mode: mode ?? this.mode,
      memoryBudgetRatio: memoryBudgetRatio ?? this.memoryBudgetRatio,
      baseCacheSecs: baseCacheSecs ?? this.baseCacheSecs,
      smallFileThresholdMB: smallFileThresholdMB ?? this.smallFileThresholdMB,
      assumedBandwidthMbps: clearAssumedBandwidth
          ? null
          : (assumedBandwidthMbps ?? this.assumedBandwidthMbps),
      overrideUserCacheArgs:
          overrideUserCacheArgs ?? this.overrideUserCacheArgs,
    );
  }

  // ── 工厂与序列化 ─────────────────────────────────────────────

  /// 内置默认配置。
  static CachePolicyConfig defaults() => const CachePolicyConfig();

  Map<String, dynamic> toJson() => <String, dynamic>{
    'enabled': enabled,
    'mode': mode.jsonValue,
    'memoryBudgetRatio': memoryBudgetRatio,
    'baseCacheSecs': baseCacheSecs,
    'smallFileThresholdMB': smallFileThresholdMB,
    'assumedBandwidthMbps': assumedBandwidthMbps,
    'overrideUserCacheArgs': overrideUserCacheArgs,
  };

  /// 从 JSON 解析；非法字段逐项收敛，保证返回配置始终可用。
  factory CachePolicyConfig.fromJson(Map<String, dynamic> json) {
    final enabled = json['enabled'];
    final ratio = json['memoryBudgetRatio'];
    final secs = json['baseCacheSecs'];
    final threshold = json['smallFileThresholdMB'];
    final bandwidth = json['assumedBandwidthMbps'];

    double ratioValue = defaultMemoryBudgetRatio;
    if (ratio is num) {
      ratioValue = ratio.toDouble().clamp(
        minMemoryBudgetRatio,
        maxMemoryBudgetRatio,
      );
    }

    // 越界数值收敛到边界值；非数值回退默认值。
    int secsValue = defaultBaseCacheSecs;
    if (secs is num) {
      secsValue = secs.toInt().clamp(minBaseCacheSecs, maxBaseCacheSecs);
    }

    int thresholdValue = defaultSmallFileThresholdMB;
    if (threshold is num) {
      thresholdValue = threshold.toInt().clamp(
        minSmallFileThresholdMB,
        maxSmallFileThresholdMB,
      );
    }

    double? bandwidthValue;
    if (bandwidth is num && bandwidth.toDouble() > 0) {
      bandwidthValue = bandwidth.toDouble();
    }

    return CachePolicyConfig(
      enabled: enabled is bool ? enabled : true,
      mode: CachePolicyMode.fromJson(json['mode']),
      memoryBudgetRatio: ratioValue,
      baseCacheSecs: secsValue,
      smallFileThresholdMB: thresholdValue,
      assumedBandwidthMbps: bandwidthValue,
      overrideUserCacheArgs: json['overrideUserCacheArgs'] is bool
          ? json['overrideUserCacheArgs'] as bool
          : false,
    );
  }
}
