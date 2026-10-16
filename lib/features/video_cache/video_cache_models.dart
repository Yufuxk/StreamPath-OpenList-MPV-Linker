import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../../data/models/media_entry.dart';
import '../../data/models/subtitle_item.dart';
import '../../data/models/external_audio_track.dart';
import '../../data/models/video_queue.dart';

String videoCacheId(String value) =>
    sha256.convert(utf8.encode(value)).toString();

String videoCachePath(String value) {
  final parts = value.split('/');
  if (value.isEmpty ||
      value.startsWith('/') ||
      parts.any(
        (s) =>
            s.isEmpty ||
            s == '.' ||
            s == '..' ||
            RegExp(r'[\\:\x00-\x1f<>"|?*]').hasMatch(s) ||
            s.endsWith('.') ||
            s.endsWith(' ') ||
            RegExp(
              r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
              caseSensitive: false,
            ).hasMatch(s),
      )) {
    throw const VideoCacheException('缓存文件路径无效');
  }
  return parts.join('/');
}

class VideoCacheException implements Exception {
  const VideoCacheException(
    this.message, {
    this.transient = false,
    this.refreshTransfer = false,
  });
  final String message;
  final bool transient;
  final bool refreshTransfer;
  @override
  String toString() => message;
}

class VideoCacheFile {
  VideoCacheFile(this.data);
  final Map<String, dynamic> data;
  String get id => data['id'] as String;
  String get sourceId => data['source'] as String;
  String get path => data['path'] as String;
  String get destination => data['destination'] as String;
  String get state => data['state'] as String? ?? 'queued';
  String? get error => data['error'] as String?;
  int get size => data['size'] as int;
  int get received => data['received'] as int? ?? 0;
  int get committed => data['committed'] as int? ?? 0;
  double get speed => (data['speed'] as num?)?.toDouble() ?? 0;
  bool get complete => state == 'completed';
  bool get pending => !complete && state != 'cancelled';
}

/// 清单保存逻辑身份，传输凭据与临时链接只通过内存命令传递。
class VideoCachePlan {
  VideoCachePlan({required this.bundle, required this.files});
  final Map<String, dynamic> bundle;
  final List<VideoCacheFile> files;
  String get id => bundle['id'] as String;
  String get name => bundle['name'] as String;
  String get sourceId => bundle['source'] as String;
  int get size => files.fold(0, (n, f) => n + f.size);
}

class CachedPlaybackTarget {
  CachedPlaybackTarget(this.bundle, this.files);
  final Map<String, dynamic> bundle;
  final Map<String, VideoCacheFile> files;
  String get path => files[bundle['main']]!.destination;
  String get progressTarget => bundle['progress'] as String;
  String get kind => bundle['kind'] as String;
  String get discPath => kind == 'bdmv'
      ? p.joinAll([
          bundle['root'] as String,
          ...(bundle['discPath'] as String).split('/'),
        ])
      : path;
  PreparedVideoItem prepared({String? title}) {
    final subtitle = bundle['subtitle'] as String?;
    final fonts = (bundle['fonts'] as List).cast<String>();
    return PreparedVideoItem(
      entry: MediaEntry(
        url: path,
        progressTarget: progressTarget,
        catalogPath: bundle['path'] as String,
        title: title ?? bundle['name'] as String,
        subtitle: subtitle == null
            ? null
            : SubtitleItem(
                name: p.basename(files[subtitle]!.destination),
                url: files[subtitle]!.destination,
                language: SubtitleLanguage.values.byName(
                  bundle['subtitleLanguage'] as String,
                ),
                score: 0,
              ),
        externalAudioTracks: [
          for (final id in (bundle['audio'] as List).cast<String>())
            ExternalAudioTrack(
              name: p.basename(files[id]!.destination),
              url: files[id]!.destination,
            ),
        ],
      ),
      localFontDirectory: fonts.isEmpty
          ? null
          : p.dirname(files[fonts.first]!.destination),
    );
  }
}
