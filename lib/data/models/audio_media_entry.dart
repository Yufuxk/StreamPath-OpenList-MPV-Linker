import 'playback_media_entry.dart';

/// 音频播放列表中的同目录伴随文件。
class AudioCompanionFile {
  const AudioCompanionFile({required this.name, required this.url});

  final String name;
  final String url;
}

/// 音频播放列表条目。
class AudioMediaEntry implements PlaybackMediaEntry {
  const AudioMediaEntry({
    required this.url,
    required this.title,
    this.lyrics,
    this.coverArt,
  });

  /// 干净的音频 URL，认证由音频播放器服务按同源规则注入。
  @override
  final String url;

  /// M3U8 与 MPV 窗口使用的自定义曲名。
  final String title;

  /// 同目录且与音频同名的 LRC 歌词。
  final AudioCompanionFile? lyrics;

  /// 同目录匹配的外挂封面；内嵌封面由 MPV 原生识别。
  final AudioCompanionFile? coverArt;

  AudioMediaEntry copyWith({
    AudioCompanionFile? lyrics,
    bool clearLyrics = false,
  }) => AudioMediaEntry(
    url: url,
    title: title,
    lyrics: clearLyrics ? null : (lyrics ?? this.lyrics),
    coverArt: coverArt,
  );
}
