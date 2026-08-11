/// 媒体元数据（码率计算依据，对应设计文档「Metadata 缓存结构」）。
///
/// 持久化于数据目录 `media_metadata.json`，以 URL 哈希为键：
/// ```json
/// {
///   "url_hash": "xxxx",
///   "file_size": 7400000000,
///   "duration": 7200,
///   "bitrate": 8200000,
///   "resolution": "1920x1080",
///   "duration_source": "mpv",
///   "bitrate_source": "average",
///   "updated": 123456789
/// }
/// ```
///
/// 字段语义（与文档一致）：
/// - [bitrateBps]：媒体容器码率（bps），Level 1 码率来源；
/// - [fileSize] + [durationSec]：Level 2 平均码率计算的输入；
/// - [resolution]：`宽x高` 字符串，Level 3 分辨率估算的输入；
/// - [durationSource]/[bitrateSource]：来源标签（`mpv`/`ffprobe`、
///   `average`/`metadata`/`estimate`），区分不同取值路径（旧数据缺省）。
class MediaMetadata {
  const MediaMetadata({
    required this.urlHash,
    this.fileSize,
    this.durationSec,
    this.bitrateBps,
    this.resolution,
    this.etag,
    this.lastModified,
    this.durationSource,
    this.bitrateSource,
    required this.updatedAt,
  });

  /// URL 的 SHA-256 哈希（缓存键）。
  final String urlHash;

  /// 文件大小（字节）；未知为 null。
  final int? fileSize;

  /// 播放时长（秒）；未知为 null。
  final double? durationSec;

  /// ffprobe 元数据码率（bps）；缺失/为 0 时表示不可用。
  final int? bitrateBps;

  /// 分辨率（如 `1920x1080`）；未知为 null。
  final String? resolution;

  /// HTTP 资源验证器；用于识别 URL 与大小都相同但内容已替换的情况。
  final String? etag;
  final String? lastModified;

  /// 时长来源标签（`mpv` 状态文件 / `ffprobe` 等）；旧数据为 null。
  final String? durationSource;

  /// 码率来源标签（`average` 平均码率 / `metadata` / `estimate`）；
  /// 旧数据为 null。
  final String? bitrateSource;

  /// 写入时间戳（诊断用）。
  final DateTime updatedAt;

  /// 是否包含有效的 Level 1 码率（> 0）。
  bool get hasBitrate => bitrateBps != null && bitrateBps! > 0;

  /// 是否包含有效的时长（> 0）。
  bool get hasDuration => durationSec != null && durationSec! > 0;

  /// 是否包含有效的分辨率（宽高均 > 0）。
  bool get hasResolution {
    final dims = parseResolution(resolution);
    return dims != null;
  }

  /// 解析 `宽x高` 字符串 → (width, height)；非法返回 null。
  static (int, int)? parseResolution(String? resolution) {
    if (resolution == null) return null;
    final parts = resolution.split(RegExp(r'[xX×]'));
    if (parts.length != 2) return null;
    final w = int.tryParse(parts[0].trim());
    final h = int.tryParse(parts[1].trim());
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    return (w, h);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'url_hash': urlHash,
    'file_size': fileSize,
    'duration': durationSec,
    'bitrate': bitrateBps,
    'resolution': resolution,
    'etag': etag,
    'last_modified': lastModified,
    'duration_source': durationSource,
    'bitrate_source': bitrateSource,
    'updated': updatedAt.millisecondsSinceEpoch,
  };

  factory MediaMetadata.fromJson(Map<String, dynamic> json) {
    final duration = json['duration'];
    final updated = json['updated'];
    return MediaMetadata(
      urlHash: (json['url_hash'] as String?) ?? '',
      fileSize: json['file_size'] is int ? json['file_size'] as int : null,
      durationSec: duration is num && duration > 0 ? duration.toDouble() : null,
      bitrateBps: json['bitrate'] is int ? json['bitrate'] as int : null,
      resolution: json['resolution'] is String
          ? json['resolution'] as String
          : null,
      etag: json['etag'] is String ? json['etag'] as String : null,
      lastModified: json['last_modified'] is String
          ? json['last_modified'] as String
          : null,
      durationSource: json['duration_source'] is String
          ? json['duration_source'] as String
          : null,
      bitrateSource: json['bitrate_source'] is String
          ? json['bitrate_source'] as String
          : null,
      updatedAt: updated is int
          ? DateTime.fromMillisecondsSinceEpoch(updated)
          : DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
