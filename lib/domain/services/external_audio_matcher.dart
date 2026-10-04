import 'package:path/path.dart' as p;

import '../../core/utils/file_sort.dart';
import '../../core/utils/url_utils.dart';
import '../../data/models/external_audio_track.dart';
import '../../data/models/media_directory_entry.dart';
import '../../data/models/media_source.dart';

/// 仅从视频或 STRM 的完整同级目录中发现音轨，不读取音频内容。
class ExternalAudioMatcher {
  const ExternalAudioMatcher();

  List<ExternalAudioTrack> matchFor(
    MediaDirectoryEntry video,
    List<MediaDirectoryEntry> siblings, {
    required String baseUrl,
  }) {
    if (video.sourceKind != MediaSourceKind.webdav) return const [];
    final videoUrl = resolveHref(baseUrl, video.entryKey);
    if (!isSameOrigin(baseUrl, videoUrl)) return const [];
    final parent = Uri.parse(videoUrl).pathSegments;
    final stem = p.basenameWithoutExtension(video.name).toLowerCase();
    final matches = <ExternalAudioTrack>[];
    final urls = <String>{};
    for (final file in siblings) {
      if (file.sourceKind != MediaSourceKind.webdav ||
          file.isDirectory ||
          !file.isAudio) {
        continue;
      }
      final audioStem = p.basenameWithoutExtension(file.name).toLowerCase();
      if (audioStem != stem &&
          !(audioStem.startsWith(stem) &&
              _separator.hasMatch(audioStem.substring(stem.length)))) {
        continue;
      }
      final url = resolveHref(baseUrl, file.entryKey);
      if (!isSameOrigin(baseUrl, url)) continue;
      final segments = Uri.parse(url).pathSegments;
      if (segments.length != parent.length) continue;
      var sameParent = true;
      for (var i = 0; i < parent.length - 1; i++) {
        if (parent[i] != segments[i]) {
          sameParent = false;
          break;
        }
      }
      if (sameParent && urls.add(url)) {
        matches.add(ExternalAudioTrack(name: file.name, url: url));
      }
    }
    matches.sort((a, b) {
      final byName = naturalCompare(a.name, b.name);
      return byName != 0 ? byName : a.url.compareTo(b.url);
    });
    return matches;
  }

  static final _separator = RegExp(r'^[._\s\-\[\(（【]');
}
