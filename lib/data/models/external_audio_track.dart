/// 普通 WebDAV 视频的远程外挂音轨，URL 不包含应用注入的凭据。
class ExternalAudioTrack {
  const ExternalAudioTrack({required this.name, required this.url});

  final String name;
  final String url;
}
