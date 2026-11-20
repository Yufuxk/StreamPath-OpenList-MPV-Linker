import '../../core/errors/app_exception.dart';
import '../../data/local/playback_progress_db.dart';
import '../../data/models/media_library_item.dart';
import '../../data/models/playback_progress.dart';

/// 历史按最近播放排序。最新记录即使已隐藏，也占用同一资源的续播资格。
List<MediaLibraryRecord> mediaContinueCandidates(
  List<MediaLibraryRecord> history, {
  required bool latestPerVideo,
}) {
  final seen = <String>{};
  return [
    for (final record in history)
      if ((!latestPerVideo ||
              record.item.kind == MediaLibraryKind.audio ||
              seen.add(record.item.stableKey)) &&
          !record.continueDismissed)
        record,
  ];
}

bool canFilterCompletedProgress(MediaLibraryRecord record) =>
    record.item.kind == MediaLibraryKind.audio ||
    record.playlistIndex == null ||
    record.playlistCount == null ||
    record.playlistIndex == record.playlistCount! - 1;

/// 无进度只影响入口是否展示。零秒是下一项或重播的有效进度。
Future<PlaybackProgress?> readVideoContinueProgress(
  MediaLibraryRecord record, {
  required PlaybackProgressReader reader,
  required String? url,
}) async {
  PlaybackProgress? progress;
  if (record.item.kind == MediaLibraryKind.strm) {
    final position = record.strmPositionMs;
    if (position == null) return null;
    progress = PlaybackProgress(
      url: record.item.targetPath,
      positionMs: position,
      durationMs: record.strmDurationMs,
    );
  } else if (url != null) {
    try {
      progress = await reader.getResumeProgress(
        url,
        profileId: record.item.sourceId,
      );
    } on StorageException {
      // 当前进度未知，保留已持久化的会话状态。
      return null;
    }
  }
  if (progress == null ||
      progress.positionMs < 0 ||
      (canFilterCompletedProgress(record) && progress.hasReachedFraction())) {
    return null;
  }
  return progress;
}
