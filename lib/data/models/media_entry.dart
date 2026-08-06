import 'subtitle_item.dart';

/// 播放列表条目：一个视频及其匹配的字幕与显示标题。
class MediaEntry {
  const MediaEntry({required this.url, this.title, this.subtitle});

  /// 视频流地址（干净 URL，认证由服务注入）。
  final String url;

  /// 显示标题（当前集文件名）；null 时由播放器层回退到 URL 末段文件名。
  final String? title;

  /// 该视频的字幕（可为 null）。
  final SubtitleItem? subtitle;
}
