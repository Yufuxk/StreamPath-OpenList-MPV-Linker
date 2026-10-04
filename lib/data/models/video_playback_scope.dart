/// 目录连播与影视库指定文件播放。
enum VideoPlaybackScope { directory, singleItem }

VideoPlaybackScope parseVideoPlaybackScope(Object? value) => switch (value) {
  null || 'directory' => VideoPlaybackScope.directory,
  'singleItem' => VideoPlaybackScope.singleItem,
  _ => throw const FormatException('Invalid video playback scope'),
};
