import '../models/media_metadata.dart';

/// 码率估算器（对应设计文档「码率获取优先级」三级策略）。
///
/// 逐级推进、命中即止（每次只取第一个命中的层级）：
/// ```text
/// Level 2: 平均码率 = 文件大小 × 8 ÷ 时长 ÷ 1,000,000（Mbps）——优先
///     ↓ 无时长
/// Level 1: metadata bit_rate（ffprobe format.bit_rate，bps）
///     ↓ 缺失
/// Level 3: 分辨率估算（480P=2 / 720P=5 / 1080P=10 / 1440P=20 / 4K=35 Mbps）
///     ↓ 全部失败
/// 未知 → 由引擎走内存预算兜底（避免假设码率低估大文件）
/// ```
///
/// 纯 Dart 无 IO，便于单元测试。
class BitrateEstimator {
  const BitrateEstimator();

  /// 分辨率估算模型（按视频宽度上界，对应文档默认模型表）。
  ///
  /// 4K HDR=60 / Remux=80 需要额外 HDR 与封装信息，第一版无来源，
  /// 4K 统一按 SDR=35 保守取值（宁可少估也不超内存预算）。
  static const Map<int, double> _resolutionBitrateTable = {
    854: 2.0, // 480P
    1280: 5.0, // 720P
    1920: 10.0, // 1080P
    2560: 20.0, // 1440P
    // 大于 2560 一律按 4K SDR 处理
  };

  /// 超出分辨率表上界时的保守默认（4K SDR）。
  static const double defaultHighResBitrateMbps = 35.0;

  /// Level 1：metadata bit_rate（bps → Mbps）。
  ///
  /// 无效（null/<=0/非有限）返回 null。
  double? estimateFromBitrateBps(int? bitrateBps) {
    if (bitrateBps == null || bitrateBps <= 0) return null;
    return bitrateBps / 1000000;
  }

  /// Level 2：平均码率 = 文件大小(Byte) × 8 ÷ 时长(秒) ÷ 1,000,000。
  ///
  /// 该值代表整个媒体流（视频+音频+字幕+容器开销）的平均码率，
  /// 对缓存计算比单独视频码率更合理（对应文档第 4 节）。
  /// 任一输入无效返回 null。
  double? estimateFromSizeAndDuration({
    int? fileSizeBytes,
    double? durationSec,
  }) {
    if (fileSizeBytes == null ||
        fileSizeBytes <= 0 ||
        durationSec == null ||
        !durationSec.isFinite ||
        durationSec <= 0) {
      return null;
    }
    return fileSizeBytes * 8 / durationSec / 1000000;
  }

  /// Level 3：分辨率估算（`宽x高` → Mbps）。
  ///
  /// 按宽度匹配文档默认模型表；非法分辨率返回 null。
  double? estimateFromResolution(String? resolution) {
    final dims = MediaMetadata.parseResolution(resolution);
    if (dims == null) return null;
    final width = dims.$1;
    double? result;
    for (final entry in _resolutionBitrateTable.entries) {
      if (width <= entry.key) {
        result = entry.value;
        break;
      }
    }
    return result ?? defaultHighResBitrateMbps;
  }
}
