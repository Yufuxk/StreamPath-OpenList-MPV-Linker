import 'media_entry.dart';
import '../../domain/services/webdav_font_matcher.dart';

class VideoQueueVersion {
  const VideoQueueVersion({required this.path, required this.name});
  final String path, name;
}

/// 同一集的资源版本共同占用一个逻辑位置。
class VideoQueueItem {
  const VideoQueueItem({
    required this.versions,
    this.season,
    this.episode,
    this.airDate,
    this.unavailable = false,
  });
  final List<VideoQueueVersion> versions;
  final int? season, episode;
  final DateTime? airDate;
  final bool unavailable;
  Map<String, dynamic> toJson() => {
    'versions': [
      for (final v in versions) {'path': v.path, 'name': v.name},
    ],
    'season': season,
    'episode': episode,
    'airDate': airDate?.toIso8601String(),
    if (unavailable) 'unavailable': true,
  };
  factory VideoQueueItem.fromJson(Map<String, dynamic> json) => VideoQueueItem(
    versions: [
      for (final v in json['versions'] as List)
        VideoQueueVersion(path: v['path'] as String, name: v['name'] as String),
    ],
    season: json['season'] as int?,
    episode: json['episode'] as int?,
    airDate: DateTime.tryParse(json['airDate'] as String? ?? ''),
    unavailable: json['unavailable'] == true,
  );
}

class PreparedVideoItem {
  const PreparedVideoItem({
    required this.entry,
    this.localFontDirectory,
    this.remoteFonts,
  });
  final MediaEntry entry;
  final String? localFontDirectory;
  final WebDavFontDirectory? remoteFonts;
}

/// 只保存逻辑身份；真实媒体与附属资源由当前来源按需准备。
class ImplicitVideoPlan {
  ImplicitVideoPlan({
    required this.items,
    required this.index,
    required this.prepare,
    required this.chooseVersion,
    required this.activated,
    this.pending,
    this.failed,
  });
  final List<VideoQueueItem> items;
  int index;
  final Future<PreparedVideoItem> Function(VideoQueueVersion) prepare;
  final Future<VideoQueueVersion?> Function(VideoQueueItem) chooseVersion;
  final Future<void> Function(int, VideoQueueVersion) activated;
  final Future<void> Function(int)? pending;
  final void Function(String)? failed;
  final Map<int, VideoQueueVersion> selected = {};
  final Map<String, PreparedVideoItem> prepared = {};
}

class VideoProgressUpdate {
  const VideoProgressUpdate({
    required this.sourceId,
    required this.path,
    required this.positionMs,
    required this.recordedAt,
    this.durationMs,
    this.completed = false,
    this.paused = false,
    this.stopped = false,
  });
  final String sourceId, path;
  final int positionMs;
  final int? durationMs;
  final DateTime recordedAt;
  final bool completed;
  final bool paused, stopped;
}
