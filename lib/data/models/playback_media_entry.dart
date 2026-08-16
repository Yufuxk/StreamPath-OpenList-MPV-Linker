/// MPV 进度同步所需的最小媒体契约，不区分视频或音频。
abstract interface class PlaybackMediaEntry {
  String get url;
}
