import 'package:path/path.dart' as p;

import '../../core/constants.dart';
import 'media_source.dart';

/// 不依赖具体存储协议的最小目录条目。
abstract interface class MediaDirectoryEntry {
  String get name;
  bool get isDirectory;
  bool get isSelfEntry;
  int get size;
  DateTime? get modified;
  String? get contentType;
  bool get isVideo;
  bool get isAudio;
  bool get isSubtitle;
  bool get isLyrics;
  bool get isCoverArt;
  bool get isStrm;
  bool get isIso;
  bool get isPlayable;
  bool get isMediaPlayable;
  String get extension;
  String get sizeLabel;
  MediaSourceKind get sourceKind;
  String get relativePath;
  String get entryKey;
}

/// 本地目录按需枚举得到的条目。
class LocalMediaEntry implements MediaDirectoryEntry {
  const LocalMediaEntry({
    required this.name,
    required this.relativePath,
    required this.absolutePath,
    required this.isDirectory,
    this.size = 0,
    this.modified,
    this.contentType,
    this.isSelfEntry = false,
  });

  @override
  final String name;

  @override
  final String relativePath;

  /// 仅用于当前本地 source 内部；实际打开前仍需再次做最终路径校验。
  final String absolutePath;

  @override
  final bool isDirectory;

  @override
  final bool isSelfEntry;

  @override
  final int size;

  @override
  final DateTime? modified;

  @override
  final String? contentType;

  @override
  MediaSourceKind get sourceKind => MediaSourceKind.local;

  @override
  String get entryKey => relativePath;

  @override
  bool get isVideo => AppConstants.videoExtensions.contains(extension);

  @override
  bool get isAudio => AppConstants.audioExtensions.contains(extension);

  @override
  bool get isSubtitle => AppConstants.subtitleExtensions.contains(extension);

  @override
  bool get isLyrics => AppConstants.lyricsExtensions.contains(extension);

  @override
  bool get isCoverArt => AppConstants.coverArtExtensions.contains(extension);

  @override
  bool get isStrm => AppConstants.strmExtensions.contains(extension);

  @override
  bool get isIso => AppConstants.isoExtensions.contains(extension);

  @override
  bool get isPlayable => isVideo || isStrm;

  @override
  bool get isMediaPlayable => isPlayable || isAudio;

  @override
  String get extension => isDirectory ? '' : p.extension(name).toLowerCase();

  @override
  String get sizeLabel {
    if (isDirectory) return '';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = size.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return unit == 0 ? '$size B' : '${value.toStringAsFixed(1)} ${units[unit]}';
  }
}
