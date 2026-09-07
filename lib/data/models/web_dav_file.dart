import 'package:path/path.dart' as p;

import '../../core/constants.dart';
import 'media_directory_entry.dart';
import 'media_source.dart';

/// WebDAV PROPFIND 解析后的文件/目录条目（不可变、轻量模型）。
///
/// 设计要点：
///  - 不持有任何 IO / 网络句柄，可直接放入 [ListView.builder] 数据源，
///    万级条目内存占用可控；
///  - 提供 Hive 缓存用的 `toCacheMap` / `fromCacheMap` 序列化对，
///    使目录"秒开"无需重新发 PROPFIND 请求。
class WebDavFile implements MediaDirectoryEntry {
  const WebDavFile({
    required this.name,
    required this.href,
    required this.isDirectory,
    this.size = 0,
    this.modified,
    this.contentType,
    this.isSelfEntry = false,
  });

  /// 显示名（displayname 或 href 最后一段）。
  @override
  final String name;

  /// 服务器返回的 href（相对或绝对路径，通常含 URL 编码）。
  final String href;

  /// 是否为目录（resourcetype 含 collection）。
  @override
  final bool isDirectory;

  /// 是否为「当前目录自身」条目（PROPFIND Depth:1 会返回自身）。
  ///
  /// UI 中将其渲染为「返回上级」入口，并始终置顶排序。
  @override
  final bool isSelfEntry;

  /// 文件大小（字节）；目录为 0。
  @override
  final int size;

  /// 最后修改时间（getlastmodified），服务器未返回时为 null。
  @override
  final DateTime? modified;

  /// MIME 类型（getcontenttype），可能为 null。
  @override
  final String? contentType;

  @override
  MediaSourceKind get sourceKind => MediaSourceKind.webdav;

  @override
  String get relativePath => href;

  @override
  String get entryKey => href;

  // ── 便捷判断 ────────────────────────────────────────────────

  /// 是否为视频文件（按扩展名判断，大小写不敏感）。
  ///
  /// 部分 WebDAV 服务器的 `getdisplayname` 会丢扩展名或与 href 不一致，
  /// 因此 [name] 判定失败时回退到 [href] 末段（解码后）再判一次。
  @override
  bool get isVideo =>
      AppConstants.videoExtensions.contains(_extOf(name)) ||
      AppConstants.videoExtensions.contains(_extOfHref);

  /// 是否为音频文件（按扩展名判断，大小写不敏感）。
  @override
  bool get isAudio =>
      AppConstants.audioExtensions.contains(_extOf(name)) ||
      AppConstants.audioExtensions.contains(_extOfHref);

  /// 是否为字幕文件。
  @override
  bool get isSubtitle =>
      AppConstants.subtitleExtensions.contains(_extOf(name)) ||
      AppConstants.subtitleExtensions.contains(_extOfHref);

  /// 是否为 LRC 歌词文件。
  @override
  bool get isLyrics =>
      AppConstants.lyricsExtensions.contains(_extOf(name)) ||
      AppConstants.lyricsExtensions.contains(_extOfHref);

  /// 是否为可用作外挂封面的图片。
  @override
  bool get isCoverArt =>
      AppConstants.coverArtExtensions.contains(_extOf(name)) ||
      AppConstants.coverArtExtensions.contains(_extOfHref);

  /// 是否为 .strm 流指针文件（内容为一行媒体 URL）。
  @override
  bool get isStrm =>
      AppConstants.strmExtensions.contains(_extOf(name)) ||
      AppConstants.strmExtensions.contains(_extOfHref);

  /// 是否为 Blu-ray ISO 光盘镜像。
  ///
  /// ISO 不并入普通视频类型，由独立 Bridge 链路处理。
  @override
  bool get isIso =>
      AppConstants.isoExtensions.contains(_extOf(name)) ||
      AppConstants.isoExtensions.contains(_extOfHref);

  /// 是否为可播放项（视频文件或 strm 流指针）。
  @override
  bool get isPlayable => isVideo || isStrm;

  /// 是否为软件支持的任意媒体播放项。
  @override
  bool get isMediaPlayable => isPlayable || isAudio;

  /// 文件扩展名（小写、含点）；目录或无法解析时为空字符串。
  ///
  /// 判定顺序与 [isVideo] 一致：优先 [name]，name 无扩展名时回退
  /// href 末段（解码后）。供「隐藏后缀」过滤器使用。
  @override
  String get extension {
    final ext = _extOf(name);
    return ext.isNotEmpty ? ext : _extOfHref;
  }

  /// name 的扩展名（小写，含点）。
  static String _extOf(String fileName) => p.extension(fileName).toLowerCase();

  /// href 末段（解码后）的扩展名（小写，含点）；无法解析时为 ''。
  String get _extOfHref {
    final uri = Uri.tryParse(href);
    if (uri == null) return '';
    final segments = uri.pathSegments;
    if (segments.isEmpty) return '';
    final last = segments.last;
    if (last.isEmpty) return '';
    try {
      return _extOf(Uri.decodeComponent(last));
    } on ArgumentError {
      return _extOf(last);
    }
  }

  /// 格式化文件大小（B/KB/MB/GB）。
  @override
  String get sizeLabel {
    if (isDirectory) return '';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = size.toDouble();
    var u = 0;
    while (v >= 1024 && u < units.length - 1) {
      v /= 1024;
      u++;
    }
    return u == 0 ? '$size B' : '${v.toStringAsFixed(1)} ${units[u]}';
  }

  // ── Hive 缓存序列化 ────────────────────────────────────────

  Map<String, dynamic> toCacheMap() => <String, dynamic>{
    'name': name,
    'href': href,
    'isDirectory': isDirectory,
    'isSelfEntry': isSelfEntry,
    'size': size,
    'modified': modified?.millisecondsSinceEpoch,
    'contentType': contentType,
  };

  factory WebDavFile.fromCacheMap(Map<dynamic, dynamic> map) => WebDavFile(
    name: map['name'] as String? ?? '',
    href: map['href'] as String? ?? '',
    isDirectory: map['isDirectory'] as bool? ?? false,
    isSelfEntry: map['isSelfEntry'] as bool? ?? false,
    size: (map['size'] as num?)?.toInt() ?? 0,
    modified: map['modified'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(map['modified'] as int),
    contentType: map['contentType'] as String?,
  );
}
