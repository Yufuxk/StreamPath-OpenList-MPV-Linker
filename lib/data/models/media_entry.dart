import 'playback_media_entry.dart';
import 'external_audio_track.dart';
import 'subtitle_item.dart';

/// 播放列表条目：视频、匹配的外挂字幕与音轨、显示标题。
class MediaEntry implements PlaybackMediaEntry {
  const MediaEntry({
    required this.url,
    this.title,
    this.catalogPath,
    this.subtitle,
    this.externalAudioTracks = const [],
  });

  /// 视频流地址（干净 URL，认证由服务注入）。
  @override
  final String url;

  /// 显示标题（文件名或本地化简洁名）；null 时由播放器层回退到 URL 末段文件名。
  final String? title;

  /// 来源内的原始逻辑路径；STRM 解析后的 URL 仍关联该条目。
  final String? catalogPath;

  /// 该视频的字幕（可为 null）。
  final SubtitleItem? subtitle;

  final List<ExternalAudioTrack> externalAudioTracks;
}
