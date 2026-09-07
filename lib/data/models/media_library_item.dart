import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/utils/url_utils.dart';
import 'media_directory_entry.dart';
import 'media_source.dart';
import 'web_dav_file.dart';

/// 个人媒体资产类型。
enum MediaLibraryKind { directory, video, audio, strm, iso }

extension MediaLibraryKindX on MediaLibraryKind {
  bool get isVideoLane =>
      this == MediaLibraryKind.video || this == MediaLibraryKind.strm;

  bool get isMedia => this != MediaLibraryKind.directory;

  static MediaLibraryKind? fromFile(WebDavFile file) {
    return fromEntry(file);
  }

  static MediaLibraryKind? fromEntry(MediaDirectoryEntry file) {
    if (file.isSelfEntry) return null;
    if (file.isDirectory) return MediaLibraryKind.directory;
    if (file.isIso) return MediaLibraryKind.iso;
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
    this.sourceKind = MediaSourceKind.webdav,
    this.playbackMode = PlaybackMode.legacyTitle,
  });

  final String sourceId;
  final String parentPath;
  final String name;
  final MediaLibraryKind kind;
  final MediaSourceKind sourceKind;
  final PlaybackMode playbackMode;

  String get normalizedParentPath => normalizeLibraryPath(parentPath);

  String get targetPath => normalizeLibraryPath(
    normalizedParentPath.isEmpty ? name : '$normalizedParentPath/$name',
  );

  String get stableKey =>
      '$sourceId\u0000${kind.name}\u0000$targetPath\u0000${playbackMode.name}';

  bool matches(MediaDirectoryEntry file) {
    final fileKind = MediaLibraryKindX.fromEntry(file);
    return file.name == name && fileKind == kind;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sourceId': sourceId,
    'parentPath': normalizedParentPath,
    'name': name,
    'kind': kind.name,
    'sourceKind': sourceKind.jsonValue,
    'playbackMode': playbackMode.jsonValue,
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
      sourceKind: MediaSourceKindJson.fromJson(json['sourceKind']),
      playbackMode: PlaybackModeJson.fromJson(json['playbackMode']),
    );
  }
}

/// 本地 ISO/BDMV 播放会话的来源与进程快照。
///
/// 该快照只用于判断历史条目是否仍指向同一个本地文件，不保存盘内容。
class LocalDiscSessionSnapshot {
  const LocalDiscSessionSnapshot({
    required this.rootId,
    required this.relativePath,
    required this.size,
    required this.modified,
    required this.fingerprint,
    this.playerPid,
    this.playerExecutablePath,
    this.playerCreationTime,
    this.currentEdition,
    this.editionCount,
  });

  final String rootId;
  final String relativePath;
  final int size;
  final DateTime modified;
  final String fingerprint;
  final int? playerPid;
  final String? playerExecutablePath;
  final int? playerCreationTime;
  final int? currentEdition;
  final int? editionCount;

  LocalDiscSessionSnapshot copyWith({int? currentEdition, int? editionCount}) =>
      LocalDiscSessionSnapshot(
        rootId: rootId,
        relativePath: relativePath,
        size: size,
        modified: modified,
        fingerprint: fingerprint,
        playerPid: playerPid,
        playerExecutablePath: playerExecutablePath,
        playerCreationTime: playerCreationTime,
        currentEdition: currentEdition ?? this.currentEdition,
        editionCount: editionCount ?? this.editionCount,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'rootId': rootId,
    'relativePath': relativePath,
    'size': size,
    'modified': modified.millisecondsSinceEpoch,
    'fingerprint': fingerprint,
    if (playerPid != null) 'playerPid': playerPid,
    if (playerExecutablePath != null)
      'playerExecutablePath': playerExecutablePath,
    if (playerCreationTime != null) 'playerCreationTime': playerCreationTime,
    if (currentEdition != null) 'currentEdition': currentEdition,
    if (editionCount != null) 'editionCount': editionCount,
  };

  static LocalDiscSessionSnapshot? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    final rootId = json['rootId'];
    final relativePath = json['relativePath'];
    final size = json['size'];
    final modified = json['modified'];
    final fingerprint = json['fingerprint'];
    if (rootId is! String ||
        rootId.isEmpty ||
        relativePath is! String ||
        relativePath.contains('..') ||
        size is! num ||
        size.toInt() < 0 ||
        modified is! num ||
        fingerprint is! String ||
        fingerprint.isEmpty) {
      return null;
    }
    final playerPid = (json['playerPid'] as num?)?.toInt();
    final playerCreationTime = (json['playerCreationTime'] as num?)?.toInt();
    final playerExecutablePath = json['playerExecutablePath'];
    final currentEdition = (json['currentEdition'] as num?)?.toInt();
    final editionCount = (json['editionCount'] as num?)?.toInt();
    if (playerExecutablePath != null && playerExecutablePath is! String) {
      return null;
    }
    if ((currentEdition == null) != (editionCount == null) ||
        (currentEdition != null &&
            (currentEdition < 0 ||
                editionCount! <= 0 ||
                currentEdition >= editionCount))) {
      return null;
    }
    return LocalDiscSessionSnapshot(
      rootId: rootId,
      relativePath: relativePath,
      size: size.toInt(),
      modified: DateTime.fromMillisecondsSinceEpoch(modified.toInt()),
      fingerprint: fingerprint,
      playerPid: playerPid,
      playerExecutablePath: playerExecutablePath as String?,
      playerCreationTime: playerCreationTime,
      currentEdition: currentEdition,
      editionCount: editionCount,
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
    this.playbackBarDismissed = false,
    this.localDiscSession,
  });

  final MediaLibraryItem item;
  final DateTime updatedAt;
  final String? playbackSessionId;
  final bool continueDismissed;
  final bool playbackBarDismissed;
  final LocalDiscSessionSnapshot? localDiscSession;

  /// 媒体中心内的记录标识；播放会话与具体文件相互独立。
  String get recordKey => playbackSessionId == null
      ? 'item\u0000${item.sourceId}\u0000${item.stableKey}'
      : 'session\u0000${item.sourceId}\u0000${item.kind == MediaLibraryKind.audio
            ? 'audio'
            : item.kind == MediaLibraryKind.iso
            ? 'iso'
            : 'video'}\u0000$playbackSessionId';

  MediaLibraryRecord copyWith({
    MediaLibraryItem? item,
    DateTime? updatedAt,
    String? playbackSessionId,
    bool? continueDismissed,
    bool? playbackBarDismissed,
    LocalDiscSessionSnapshot? localDiscSession,
  }) => MediaLibraryRecord(
    item: item ?? this.item,
    updatedAt: updatedAt ?? this.updatedAt,
    playbackSessionId: playbackSessionId ?? this.playbackSessionId,
    continueDismissed: continueDismissed ?? this.continueDismissed,
    playbackBarDismissed: playbackBarDismissed ?? this.playbackBarDismissed,
    localDiscSession: localDiscSession ?? this.localDiscSession,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    ...item.toJson(),
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    if (playbackSessionId != null) 'playbackSessionId': playbackSessionId,
    if (continueDismissed) 'continueDismissed': true,
    if (playbackBarDismissed) 'playbackBarDismissed': true,
    if (localDiscSession != null)
      'localDiscSession': localDiscSession!.toJson(),
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
      playbackBarDismissed: json['playbackBarDismissed'] == true,
      localDiscSession: LocalDiscSessionSnapshot.tryFromJson(
        json['localDiscSession'],
      ),
    );
  }
}
