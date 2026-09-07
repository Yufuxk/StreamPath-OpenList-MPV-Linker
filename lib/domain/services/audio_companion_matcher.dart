import 'package:path/path.dart' as p;

import '../../data/models/audio_media_entry.dart';
import '../../data/models/media_directory_entry.dart';

/// 按同目录规则匹配音频的 LRC 歌词和外挂封面。
class AudioCompanionMatcher {
  const AudioCompanionMatcher();

  AudioCompanionFile? findLyricsFor(
    MediaDirectoryEntry audio,
    List<MediaDirectoryEntry> siblings,
  ) {
    final stem = _stem(audio.name);
    for (final file in siblings) {
      if (!file.isLyrics || !_isSameDirectory(audio.entryKey, file.entryKey)) {
        continue;
      }
      if (_stem(file.name) == stem) return _item(file);
    }
    return null;
  }

  AudioCompanionFile? findCoverFor(
    MediaDirectoryEntry audio,
    List<MediaDirectoryEntry> siblings,
  ) {
    final stem = _stem(audio.name);
    AudioCompanionFile? standardCover;
    for (final file in siblings) {
      if (!file.isCoverArt ||
          !_isSameDirectory(audio.entryKey, file.entryKey)) {
        continue;
      }
      final candidateStem = _stem(file.name);
      if (candidateStem == stem) return _item(file);
      if (standardCover == null &&
          _standardCoverNames.contains(candidateStem)) {
        standardCover = _item(file);
      }
    }
    return standardCover;
  }

  static const Set<String> _standardCoverNames = {
    'cover',
    'folder',
    'front',
    'album',
    'albumart',
    'albumartsmall',
    'thumb',
  };

  static AudioCompanionFile _item(MediaDirectoryEntry file) =>
      AudioCompanionFile(name: file.name, url: file.entryKey);

  static String _stem(String value) =>
      p.basenameWithoutExtension(value).trim().toLowerCase();

  static bool _isSameDirectory(String mediaHref, String companionHref) {
    final media = Uri.tryParse(mediaHref);
    final companion = Uri.tryParse(companionHref);
    if (media == null || companion == null) return false;
    if (media.hasScheme != companion.hasScheme) return false;
    if (media.hasScheme &&
        (media.scheme.toLowerCase() != companion.scheme.toLowerCase() ||
            media.host.toLowerCase() != companion.host.toLowerCase() ||
            media.port != companion.port)) {
      return false;
    }
    return p.posix.dirname(media.path) == p.posix.dirname(companion.path);
  }
}
