/// 普通视频队列的提交方式。
enum VideoPlaylistMode {
  implicit,
  legacy;

  static VideoPlaylistMode fromJson(Object? value) =>
      value == 'legacy' ? legacy : implicit;
}
