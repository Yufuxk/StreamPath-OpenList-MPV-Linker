import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/app_paths.dart';
import '../../core/utils/url_utils.dart';
import '../../data/models/media_entry.dart';
import '../../data/models/subtitle_item.dart';
import 'mpv_scripts.dart';
import 'webdav_font_localizer.dart';

/// 把同源 WebDAV 外挂字幕取回本次播放会话目录。
///
/// 仅用于播放器无法携带来源凭据的会话；本地字幕和非同源 URL 原样返回。
class WebDavSubtitleLocalizer {
  const WebDavSubtitleLocalizer({this.directory});

  static const int maxSubtitleBytes = 16 * 1024 * 1024;
  static const Duration downloadTimeout = Duration(seconds: 20);

  /// 测试可指定缓存根目录；默认 `cache/webdav_subtitles`。
  final Directory? directory;

  Future<Directory> _root() async {
    final existing = directory;
    if (existing != null) {
      await existing.create(recursive: true);
      return existing;
    }
    final cache = await AppPaths.cacheDirectory();
    final root = Directory(p.join(cache.path, 'webdav_subtitles'));
    await root.create(recursive: true);
    return root;
  }

  /// 按条目逐个本地化字幕，[cache] 在会话内复用下载结果（含失败结果）。
  Future<List<MediaEntry>> localizeEntries({
    required List<MediaEntry> entries,
    required String serverUrl,
    required String sessionToken,
    required WebDavFontBytesLoader loader,
    required Map<String, Future<SubtitleItem?>> cache,
    required void Function(String path) registerArtifact,
    int maxBytes = maxSubtitleBytes,
    Duration timeout = downloadTimeout,
  }) async {
    final localizedEntries = <MediaEntry>[];
    var changed = false;
    for (final entry in entries) {
      final subtitle = entry.subtitle;
      if (subtitle == null) {
        localizedEntries.add(entry);
        continue;
      }
      final localized = await cache.putIfAbsent(
        subtitle.url,
        () => localize(
          subtitle: subtitle,
          serverUrl: serverUrl,
          sessionToken: sessionToken,
          loader: loader,
          registerArtifact: registerArtifact,
          maxBytes: maxBytes,
          timeout: timeout,
        ),
      );
      if (localized == null) {
        localizedEntries.add(entry);
        continue;
      }
      changed = true;
      localizedEntries.add(
        MediaEntry(
          url: entry.url,
          progressTarget: entry.progressTarget,
          title: entry.title,
          catalogPath: entry.catalogPath,
          subtitle: localized,
          externalAudioTracks: entry.externalAudioTracks,
        ),
      );
    }
    return changed ? localizedEntries : entries;
  }

  /// 下载单个字幕；不适用的来源返回 null，失败时同样返回 null 由调用方回退。
  Future<SubtitleItem?> localize({
    required SubtitleItem subtitle,
    required String serverUrl,
    required String sessionToken,
    required WebDavFontBytesLoader loader,
    required void Function(String path) registerArtifact,
    int maxBytes = maxSubtitleBytes,
    Duration timeout = downloadTimeout,
  }) async {
    final uri = Uri.tryParse(subtitle.url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        !isSameOrigin(serverUrl, subtitle.url)) {
      return null;
    }
    final fileName = _safeFileName(uri);
    if (fileName == null) return null;
    final token = MpvScripts.safeSessionToken(sessionToken);
    final Directory target;
    try {
      target = Directory(
        p.join((await _root()).path, token.isEmpty ? 'session' : token),
      );
      await target.create(recursive: true);
    } on FileSystemException {
      return null;
    }
    registerArtifact(target.path);
    final file = File(p.join(target.path, fileName));
    final temporary = File('${file.path}.tmp');
    try {
      final bytes = await loader(
        subtitle.url,
        maxBytes: maxBytes,
        timeout: timeout,
      );
      if (bytes.isEmpty || bytes.length > maxBytes) return null;
      await temporary.writeAsBytes(bytes, flush: true);
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
      registerArtifact(file.path);
      return SubtitleItem(
        name: subtitle.name,
        url: file.path,
        language: subtitle.language,
        score: subtitle.score,
      );
    } on AppException {
      await _deleteQuietly(temporary);
      return null;
    } on FileSystemException {
      await _deleteQuietly(temporary);
      return null;
    } on TimeoutException {
      await _deleteQuietly(temporary);
      return null;
    }
  }

  /// 删除不属于当前来源会话的临时字幕目录；会话内旧播放代次保留到会话结束。
  Future<void> prune(
    Future<Set<String>> Function() loadActiveSessionIds,
  ) async {
    final active = <String>{};
    for (final sessionId in await loadActiveSessionIds()) {
      final token = MpvScripts.safeSessionToken(sessionId);
      if (token.isNotEmpty) active.add(token);
    }
    final root = await _root();
    await for (final entity in root.list()) {
      if (entity is! Directory || p.dirname(entity.path) != root.path) {
        continue;
      }
      final name = p.basename(entity.path);
      if (active.any(
        (token) => name == token || name.startsWith('${token}__e'),
      )) {
        continue;
      }
      try {
        await entity.delete(recursive: true);
      } on FileSystemException {
        // 删除失败留待下次清理。
      }
    }
  }

  /// 生成会话目录内的安全文件名，保留原扩展名并避免同名冲突。
  static String? _safeFileName(Uri uri) {
    var name = p.basename(uri.path);
    try {
      name = p.basename(Uri.decodeComponent(uri.path));
    } on ArgumentError {
      // 解码失败时保留原始末段。
    }
    final extension = p.extension(name).toLowerCase();
    if (!AppConstants.subtitleExtensions.contains(extension)) return null;
    var stem = p
        .basenameWithoutExtension(name)
        .replaceAll(RegExp(r'[\x00-\x1F\x7F\\/:*?"<>|]'), '_')
        .trim();
    if (stem.isEmpty || stem == '.' || stem == '..') stem = 'subtitle';
    if (stem.length > 80) stem = stem.substring(0, 80);
    final hash = sha256
        .convert(utf8.encode(uri.toString()))
        .toString()
        .substring(0, 16);
    return '${hash}_$stem$extension';
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // 临时文件删除失败时由会话清理兜底。
    }
  }
}
