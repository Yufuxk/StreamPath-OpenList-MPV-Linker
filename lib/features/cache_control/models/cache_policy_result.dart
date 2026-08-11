/// 媒体码率档位（对应设计方案「视频类型策略表」）。
///
/// 第一版集成方暂无 ffprobe 能力，播放前默认按 [MediaTier.hd1080]（基准档）
/// 处理；显式档位供后续接入真实媒体分析（第二阶段）时直接使用。
enum MediaTier {
  hd720('720P'),
  hd1080('1080P'),
  uhd4k('4K'),
  remux('REMUX');

  const MediaTier(this.label);

  /// 中文显示名（诊断/日志用）。
  final String label;
}

/// 缓存策略计算结果：分层算法输出 + 最终 mpv 参数。
///
/// [args] 为注入播放器的缓存参数列表；[skipped] 为 true 时表示本次
/// 不注入（缓存系统关闭或集成方决定跳过），[args] 为空。
class CachePolicyResult {
  const CachePolicyResult({
    required this.skipped,
    this.cacheSecs = 0,
    this.demuxerMaxBytes = 0,
    this.memoryBudgetBytes = 0,
    this.minCacheSecs = 10,
    this.maxCacheSecs = 600,
    this.fullCache = false,
    this.fileSizeBytes,
    this.bitrateMbps,
    this.bitrateSource,
    this.networkFactor,
    this.healthScore = 0,
    this.layers = const [],
    this.args = const [],
  });

  /// 是否跳过注入（配置关闭时）。
  final bool skipped;

  /// 目标缓存秒数（对应 mpv `--cache-secs`）。
  final int cacheSecs;

  /// 缓存字节上限（对应 mpv `--demuxer-max-bytes`）。
  final int demuxerMaxBytes;

  /// 本策略可使用的内存预算上限。动态调整字节上限时必须继续受它约束。
  final int memoryBudgetBytes;

  /// 动态缓存时长的合法下限。
  final int minCacheSecs;

  /// 动态缓存时长的合法上限。全量缓存分支可高于普通配置上限。
  final int maxCacheSecs;

  /// 小文件全量缓存策略是否生效。
  final bool fullCache;

  /// 探测到的媒体文件大小（字节）；未知为 null。
  final int? fileSizeBytes;

  /// 决策采用的码率（Mbps）；未知（预算兜底）为 null。
  final double? bitrateMbps;

  /// 码率来源标签（Level1/2/3 等，日志展示用）。
  final String? bitrateSource;

  /// 网络系数（带宽/码率）；无法计算时为 null（中性）。
  final double? networkFactor;

  /// Buffer Health Score（0~100，诊断展示用）。
  final int healthScore;

  /// 四层算法的逐层说明（诊断/日志）。
  final List<String> layers;

  /// 最终注入 mpv 的参数列表。
  final List<String> args;

  /// 全量缓存时的 `--demuxer-max-bytes` 上限兜底（避免极端文件撑爆内存）。
  static const int fullCacheMaxBytes = 4 * 1024 * 1024 * 1024; // 4GiB
}
