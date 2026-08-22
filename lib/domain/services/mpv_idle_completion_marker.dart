/// MPV 播放列表进入 idle 后写出的会话完成标记。
class MpvIdleCompletionMarker {
  const MpvIdleCompletionMarker({
    required this.lastPlaylistPos,
    required this.launchEpoch,
  });

  final int lastPlaylistPos;
  final String launchEpoch;

  static MpvIdleCompletionMarker? parse(List<String>? lines) {
    if (lines == null || lines.length < 3 || lines[0].trim() != '-1') {
      return null;
    }
    final lastPlaylistPos = int.tryParse(lines[1].trim());
    final launchEpoch = lines[2].trim();
    if (lastPlaylistPos == null || lastPlaylistPos < 0 || launchEpoch.isEmpty) {
      return null;
    }
    return MpvIdleCompletionMarker(
      lastPlaylistPos: lastPlaylistPos,
      launchEpoch: launchEpoch,
    );
  }

  bool matches({
    required int expectedLastPlaylistPos,
    required String expectedLaunchEpoch,
  }) =>
      lastPlaylistPos == expectedLastPlaylistPos &&
      expectedLaunchEpoch.isNotEmpty &&
      launchEpoch == expectedLaunchEpoch;
}
