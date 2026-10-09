/// 媒体来源类型。
enum MediaSourceKind { webdav, local, smb, ftp, nfs, jellyfin, emby }

extension MediaSourceKindJson on MediaSourceKind {
  String get jsonValue => name;

  static MediaSourceKind fromJson(Object? value) => value == null
      ? MediaSourceKind.webdav
      : MediaSourceKind.values
                .where((kind) => kind.name == value)
                .firstOrNull ??
            (throw const FormatException('Invalid media source kind'));

  bool get isMediaServer =>
      this == MediaSourceKind.jellyfin || this == MediaSourceKind.emby;
  bool get isNativeStorage =>
      this == MediaSourceKind.smb ||
      this == MediaSourceKind.ftp ||
      this == MediaSourceKind.nfs;
}

/// 播放链路使用的显式模式。
enum PlaybackMode {
  legacyTitle,
  localFile,
  localHdmvMenu,
  webdavHdmvMenu,
  webdavBdjMenu,
}

extension PlaybackModeJson on PlaybackMode {
  String get jsonValue => name;

  static PlaybackMode fromJson(Object? value) {
    if (value == null) return PlaybackMode.legacyTitle;
    return PlaybackMode.values
            .where((mode) => mode.name == value)
            .firstOrNull ??
        (throw const FormatException('媒体播放模式无效'));
  }
}

/// 目录来源的稳定身份与显示信息。
class MediaSourceDescriptor {
  const MediaSourceDescriptor({
    required this.sourceId,
    required this.kind,
    required this.displayName,
  });

  final String sourceId;
  final MediaSourceKind kind;
  final String displayName;
}

/// 目录条目解析后的可打开目标。
sealed class MediaOpenTarget {
  const MediaOpenTarget();
}

class WebDavMediaOpenTarget extends MediaOpenTarget {
  const WebDavMediaOpenTarget(this.url);

  final String url;
}

class LocalMediaOpenTarget extends MediaOpenTarget {
  const LocalMediaOpenTarget(this.path);

  final String path;
}
