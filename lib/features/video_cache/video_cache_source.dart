import 'dart:io';
import 'package:path/path.dart' as p;
import '../../data/models/media_directory_entry.dart';
import '../../data/models/media_source.dart';
import '../../data/models/web_dav_file.dart';
import '../../data/remote/webdav_client.dart';
import '../../domain/repositories/media_directory_source.dart';
import '../../domain/services/native_storage_source.dart';
import '../../domain/services/webdav_media_source_adapter.dart';
import '../../domain/services/webdav_service.dart';
import 'video_cache_models.dart';
import 'video_cache_service.dart';

/// 播放宿主使用已保存目录；未缓存资源按需回到原来源。
class VideoCacheSource extends WebDavMediaSourceAdapter {
  VideoCacheSource(
    VideoCacheService cache,
    this.description, {
    required this.identity,
    required String baseUrl,
    required String Function(String path) persistent,
    required Future<MediaDirectorySource> Function() remote,
  }) : super(
         _CachedWebDav(
           cache,
           description,
           identity,
           baseUrl,
           persistent,
           remote,
         ),
       );
  final MediaSourceDescriptor description;
  final String identity;
  @override
  MediaSourceDescriptor get descriptor => description;
  @override
  bool get supportsRemoteSearch => false;
  @override
  Future<MediaOpenTarget> resolve(MediaDirectoryEntry entry) async {
    final cached = service as _CachedWebDav;
    final path = cached.relative(entry.entryKey);
    final local = await cached.cache.localFile(
      descriptor.sourceId,
      path,
      identity: cached.identity,
    );
    if (local != null) return LocalMediaOpenTarget(local);
    if (entry.isDirectory &&
        cached.cache.directorySnapshot(
              descriptor.sourceId,
              path,
              identity: cached.identity,
            ) !=
            null) {
      return WebDavMediaOpenTarget(service.fullUrl(path));
    }
    final source = await cached.remote();
    final parent = p.posix.dirname(path);
    final current = (await source.fetchDirectory(
      parent == '.' ? '' : parent,
    )).where((e) => e.name == entry.name).firstOrNull;
    if (current == null) throw const VideoCacheException('缓存来源文件不存在');
    return source.resolve(current);
  }
}

class _CachedWebDav extends WebDAVService {
  _CachedWebDav(
    this.cache,
    this.descriptor,
    this.identity,
    String base,
    this.persistent,
    this.remote,
  ) : super(
        client: WebDavClient(baseUrl: base),
        profileId: descriptor.sourceId,
      );
  final VideoCacheService cache;
  final MediaSourceDescriptor descriptor;
  final String identity;
  final String Function(String path) persistent;
  final Future<MediaDirectorySource> Function() remote;
  String relative(String href) {
    if (!Uri.parse(href).hasScheme && !href.startsWith('/')) return href;
    final root = Uri.parse(
      baseUrl,
    ).pathSegments.where((s) => s.isNotEmpty).length;
    return Uri.parse(
      resolveUrl(href),
    ).pathSegments.skip(root).where((s) => s.isNotEmpty).join('/');
  }

  List<WebDavFile>? snapshot(String path) {
    final rows = cache.directorySnapshot(
      descriptor.sourceId,
      path,
      identity: identity,
    );
    return rows == null
        ? null
        : [
            for (final row in rows)
              StorageMediaEntry(
                name: row['name'] as String,
                href: fullUrl(row['path'] as String),
                logicalPath: row['path'] as String,
                kind: descriptor.kind,
                isDirectory: row['directory'] as bool,
                size: row['size'] as int,
                modified: row['modified'] == null
                    ? null
                    : DateTime.fromMillisecondsSinceEpoch(
                        row['modified'] as int,
                      ),
              ),
          ];
  }

  @override
  List<WebDavFile>? cachedDirectory(String path) => snapshot(path);
  @override
  Future<List<WebDavFile>> fetchDirectory(
    String path, {
    bool forceRefresh = false,
  }) async {
    final cached = snapshot(path);
    if (cached != null) return cached;
    return (await (await remote()).fetchDirectory(
      path,
      forceRefresh: forceRefresh,
    )).cast<WebDavFile>();
  }

  @override
  Future<List<WebDavFile>> fetchCatalogDirectory(String path) =>
      fetchDirectory(path);
  @override
  String persistentUrl(String href) => persistent(relative(href));
  @override
  Future<String?> cachedDiscPath(WebDavFile file) async => (await cache.lookup(
    sourceId,
    relative(file.href),
    identity: identity,
  ))?.discPath;
  @override
  Future<String?> fetchStrmUrl(WebDavFile file) async {
    final hit = await cache.lookup(
      sourceId,
      relative(file.href),
      identity: identity,
    );
    if (hit != null) return hit.path;
    final source = await remote() as WebDavMediaSourceAdapter;
    final path = relative(file.href);
    final parent = p.posix.dirname(path);
    final entry = (await source.fetchDirectory(
      parent == '.' ? '' : parent,
    )).where((e) => e.name == file.name).firstOrNull;
    return entry == null
        ? null
        : source.service.fetchStrmUrl(entry as WebDavFile);
  }

  @override
  Future<List<int>> fetchFileBytes(
    String url, {
    required int maxBytes,
    required Duration timeout,
  }) async {
    final local = await cache.localFile(
      sourceId,
      relative(url),
      identity: identity,
    );
    if (local != null) {
      final file = File(local);
      if (await file.length() > maxBytes) {
        throw const VideoCacheException('缓存附件超过大小限制');
      }
      return file.readAsBytes();
    }
    return (await remote() as WebDavMediaSourceAdapter).service.fetchFileBytes(
      url,
      maxBytes: maxBytes,
      timeout: timeout,
    );
  }

  @override
  Future<int> downloadFile(
    String url,
    File destination, {
    required int maxBytes,
    required Duration timeout,
    void Function(int received)? onProgress,
  }) async {
    final local = await cache.localFile(
      sourceId,
      relative(url),
      identity: identity,
    );
    if (local == null) {
      return (await remote() as WebDavMediaSourceAdapter).service.downloadFile(
        url,
        destination,
        maxBytes: maxBytes,
        timeout: timeout,
        onProgress: onProgress,
      );
    }
    final file = File(local), length = await File(local).length();
    if (length > maxBytes) throw const VideoCacheException('缓存附件超过大小限制');
    await file.copy(destination.path);
    onProgress?.call(length);
    return length;
  }
}
