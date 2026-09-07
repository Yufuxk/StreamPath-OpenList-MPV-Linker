/// WebDAV ISO 两种播放模式共用的受控参数过滤。
List<String> filterIsoPlayerArguments(List<String> arguments) {
  final args = <String>[];
  var skipControlledValue = false;
  for (final raw in arguments) {
    final value = raw.trim();
    final lower = value.toLowerCase();
    if (skipControlledValue) {
      skipControlledValue = false;
      continue;
    }
    if (const {
      '--bluray-device',
      '--playlist',
      '--playlist-start',
      '--watch-later-directory',
      '--http-header-fields',
      '--cookies-file',
      '--referrer',
      '--http-proxy',
      '--cache-secs',
      '--cache-pause-wait',
      '--demuxer-max-bytes',
      '--demuxer-readahead-secs',
      '--demuxer-hysteresis-secs',
      '--rebase-start-time',
      '--demuxer-lavf-linearize-timestamps',
      '--input-ipc-server',
    }.contains(lower)) {
      skipControlledValue = true;
      continue;
    }
    if (value.isEmpty ||
        value == '--' ||
        value.contains('{url}') ||
        value.contains('{subfile}') ||
        value.contains('{start}') ||
        lower.startsWith('--bluray-device=') ||
        lower.startsWith('--bluray-device ') ||
        lower.startsWith('--playlist=') ||
        lower.startsWith('--playlist-start=') ||
        lower.startsWith('--watch-later-directory=') ||
        lower.startsWith('--http-header-fields=') ||
        lower.startsWith('--cookies-file=') ||
        lower.startsWith('--referrer=') ||
        lower.startsWith('--http-proxy=') ||
        lower == '--cache' ||
        lower == '--no-cache' ||
        lower.startsWith('--cache=') ||
        lower.startsWith('--cache-secs=') ||
        lower == '--cache-on-disk' ||
        lower == '--no-cache-on-disk' ||
        lower.startsWith('--cache-on-disk=') ||
        lower == '--cache-pause' ||
        lower == '--no-cache-pause' ||
        lower.startsWith('--cache-pause=') ||
        lower == '--cache-pause-initial' ||
        lower == '--no-cache-pause-initial' ||
        lower.startsWith('--cache-pause-initial=') ||
        lower.startsWith('--cache-pause-wait=') ||
        lower == '--demuxer-cache-wait' ||
        lower == '--no-demuxer-cache-wait' ||
        lower.startsWith('--demuxer-cache-wait=') ||
        lower.startsWith('--demuxer-max-bytes=') ||
        lower.startsWith('--demuxer-readahead-secs=') ||
        lower.startsWith('--demuxer-hysteresis-secs=') ||
        lower == '--no-rebase-start-time' ||
        lower.startsWith('--rebase-start-time=') ||
        lower.startsWith('--demuxer-lavf-linearize-timestamps=') ||
        lower.startsWith('--input-ipc-server=') ||
        lower == '--prefetch-playlist' ||
        lower == '--no-prefetch-playlist' ||
        lower.startsWith('--prefetch-playlist=') ||
        lower == '--cookies' ||
        lower.startsWith('--cookies=') ||
        lower == '--no-cookies' ||
        lower == '--load-unsafe-playlists' ||
        lower.startsWith('--load-unsafe-playlists=') ||
        lower == '--resume-playback' ||
        lower.startsWith('--resume-playback=') ||
        lower == '--no-resume-playback' ||
        lower == '--save-position-on-quit' ||
        lower == '--no-save-position-on-quit' ||
        lower == '--idle' ||
        lower == '--no-idle' ||
        lower.startsWith('--idle=') ||
        lower == '--keep-open' ||
        lower == '--no-keep-open' ||
        lower.startsWith('--keep-open=') ||
        lower.startsWith('bd://') ||
        lower.startsWith('bluray://')) {
      continue;
    }
    args.add(value);
  }
  return args;
}
