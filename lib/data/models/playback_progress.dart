/// 播放进度记录（SQLite 持久化，按视频 URL 主键）。
class PlaybackProgress {
  const PlaybackProgress({
    required this.url,
    required this.positionMs,
    this.durationMs,
    this.updatedAt,
  });

  /// 视频流 URL（唯一键）。
  final String url;

  /// 已播放位置（毫秒）。
  final int positionMs;

  /// 视频总时长（毫秒），可能为 null。
  final int? durationMs;

  /// 最后更新时间。
  final DateTime? updatedAt;

  /// 续播起点（秒）；positionMs <= 0 时返回 null（从头播放）。
  int? get resumeSeconds => positionMs <= 0 ? null : positionMs ~/ 1000;

  /// 是否为「已看完」：时长已知且位置接近片尾（剩余不足 [tailGraceMs]）。
  ///
  /// 时长缺失（null/<=0）时**不**视为已看完——mpv 对网络流写的
  /// watch_later 常没有 `duration=` 行，若把「时长未知」
  /// 误判为「已看完」会导致每次播放都从头开始。「自然播完（EOF）」时
  /// mpv 不写 watch_later，因此无时长时恢复的位置几乎不可能是片尾，
  /// 正常续播是安全的。
  bool isFinishedNearEnd({int tailGraceMs = 60000}) {
    final duration = durationMs;
    if (duration == null || duration <= 0) return false;
    return positionMs >= duration - tailGraceMs;
  }

  /// 是否至少播放到指定比例；仅用于播放器进程退出后的完成判定。
  bool hasReachedFraction({double fraction = 0.99}) {
    final duration = durationMs;
    if (duration == null || duration <= 0 || positionMs < 0) return false;
    return positionMs / duration >= fraction;
  }

  /// 序列化为数据库行。
  Map<String, Object?> toRow() => <String, Object?>{
    'url': url,
    'position_ms': positionMs,
    'duration_ms': durationMs,
    'updated_at': updatedAt?.millisecondsSinceEpoch,
  };

  /// 从数据库行反序列化。
  factory PlaybackProgress.fromRow(Map<String, Object?> row) =>
      PlaybackProgress(
        url: row['url'] as String,
        positionMs: (row['position_ms'] as num).toInt(),
        durationMs: (row['duration_ms'] as num?)?.toInt(),
        updatedAt: row['updated_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
      );
}

/// 判断播放器退出时是否已经达到完成比例。
///
/// mpv 关闭阶段可能上报无效的 `time-pos` 或 `duration`。只有当前值无效
/// 时才回退到最近一次有效状态，避免退出瞬间的哨兵值覆盖 99% 进度。
bool hasReachedExitCompletion({
  double? positionSeconds,
  double? durationSeconds,
  double? fallbackPositionSeconds,
  double? fallbackDurationSeconds,
  double fraction = 0.99,
}) {
  final position = positionSeconds != null && positionSeconds > 0
      ? positionSeconds
      : fallbackPositionSeconds;
  final duration = durationSeconds != null && durationSeconds > 0
      ? durationSeconds
      : fallbackDurationSeconds;
  if (position == null || duration == null || duration <= 0) return false;
  return position / duration >= fraction;
}
