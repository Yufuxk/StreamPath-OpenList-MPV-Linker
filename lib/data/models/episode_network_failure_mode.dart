/// MPV 剧集队列遇到明确网络播放失败时的操作。
enum EpisodeNetworkFailureMode {
  stop,
  autoSkip;

  static EpisodeNetworkFailureMode fromJson(Object? value) =>
      value == autoSkip.name ? autoSkip : stop;
}
