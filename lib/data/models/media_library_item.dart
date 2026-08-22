import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/utils/url_utils.dart';
import 'web_dav_file.dart';

/// 个人媒体资产类型。
enum MediaLibraryKind { directory, video, audio, strm }

extension MediaLibraryKindX on MediaLibraryKind {
  bool get isVideoLane =>
      this == MediaLibraryKind.video || this == MediaLibraryKind.strm;

  bool get isMedia => this != MediaLibraryKind.directory;

  static MediaLibraryKind? fromFile(WebDavFile file) {
    if (file.isSelfEntry) return null;
    if (file.isDirectory) return MediaLibraryKind.directory;
    if (file.isStrm) return MediaLibraryKind.strm;
    if (file.isAudio) return MediaLibraryKind.audio;
    if (file.isVideo) return MediaLibraryKind.video;
    return null;
  }
}

/// 归一化媒体库中使用的相对目录路径。
String normalizeLibraryPath(String value) => value
    .trim()
    .replaceAll('\\', '/')
    .replaceAll(RegExp(r'^/+|/+$'), '')
    .replaceAll(RegExp(r'/+'), '/');

/// 根据当前 WebDAV 连接生成不含凭据的稳定来源标识。
String mediaSourceId({required String baseUrl, required String username}) {
  final clean = stripUserInfo(baseUrl.trim());
  final uri = Uri.tryParse(clean);
  final normalized = uri == null || !uri.hasScheme || uri.host.isEmpty
      ? clean.replaceAll(RegExp(r'[/?#]+$'), '')
      : uri
            .replace(
              scheme: uri.scheme.toLowerCase(),
              host: uri.host.toLowerCase(),
              userInfo: '',
              path: uri.path.replaceAll(RegExp(r'/+$'), ''),
              query: '',
              fragment: '',
            )
            .toString()
            .replaceAll(RegExp(r'[/?#]+$'), '');
  return 'sha256:${sha256.convert(utf8.encode('$username\n$normalized'))}';
}

/// 一个可收藏、记录或从媒体中心打开的位置。
class MediaLibraryItem {
  const MediaLibraryItem({
    required this.sourceId,
    required this.parentPath,
    required this.name,
    required this.kind,
  });

  final String sourceId;
  final String parentPath;
  final String name;
  final MediaLibraryKind kind;

  String get normalizedParentPath => normalizeLibraryPath(parentPath);

  String get targetPath => normalizeLibraryPath(
    normalizedParentPath.isEmpty ? name : '$normalizedParentPath/$name',
  );

  String get stableKey => '${kind.name}\u0000$normalizedParentPath\u0000$name';

  bool matches(WebDavFile file) {
    final fileKind = MediaLibraryKindX.fromFile(file);
    return file.name == name && fileKind == kind;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sourceId': sourceId,
    'parentPath': normalizedParentPath,
    'name': name,
    'kind': kind.name,
  };

  factory MediaLibraryItem.fromJson(Map<String, dynamic> json) {
    final kindName = json['kind'];
    final kind = MediaLibraryKind.values
        .where((item) => item.name == kindName)
        .firstOrNull;
    if (kind == null) throw const FormatException('媒体资产类型无效');
    final sourceId = json['sourceId'];
    final name = json['name'];
    final parentPath = json['parentPath'];
    if (sourceId is! String ||
        sourceId.isEmpty ||
        name is! String ||
        name.isEmpty ||
        parentPath is! String) {
      throw const FormatException('媒体资产字段无效');
    }
    return MediaLibraryItem(
      sourceId: sourceId,
      parentPath: normalizeLibraryPath(parentPath),
      name: name,
      kind: kind,
    );
  }
}

/// 媒体库的带时间记录。
class MediaLibraryRecord {
  const MediaLibraryRecord({
    required this.item,
    required this.updatedAt,
    this.playbackSessionId,
    this.continueDismissed = false,
  });

  final MediaLibraryItem item;
  final DateTime updatedAt;
  final String? playbackSessionId;
  final bool continueDismissed;

  /// 媒体中心内的记录标识；播放会话与具体文件相互独立。
  String get recordKey => playbackSessionId == null
      ? 'item\u0000${item.sourceId}\u0000${item.stableKey}'
      : 'session\u0000${item.sourceId}\u0000${item.kind.isVideoLane ? 'video' : 'audio'}\u0000$playbackSessionId';

  MediaLibraryRecord copyWith({
    MediaLibraryItem? item,
    DateTime? updatedAt,
    String? playbackSessionId,
    bool? continueDismissed,
  }) => MediaLibraryRecord(
    item: item ?? this.item,
    updatedAt: updatedAt ?? this.updatedAt,
    playbackSessionId: playbackSessionId ?? this.playbackSessionId,
    continueDismissed: continueDismissed ?? this.continueDismissed,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    ...item.toJson(),
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    if (playbackSessionId != null) 'playbackSessionId': playbackSessionId,
    if (continueDismissed) 'continueDismissed': true,
  };

  factory MediaLibraryRecord.fromJson(Map<String, dynamic> json) {
    final updatedAt = json['updatedAt'];
    if (updatedAt is! int) throw const FormatException('媒体资产时间无效');
    final rawSessionId = json['playbackSessionId'];
    final playbackSessionId = rawSessionId is String && rawSessionId.isNotEmpty
        ? rawSessionId
        : null;
    return MediaLibraryRecord(
      item: MediaLibraryItem.fromJson(json),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAt),
      playbackSessionId: playbackSessionId,
      continueDismissed: json['continueDismissed'] == true,
    );
  }
}
