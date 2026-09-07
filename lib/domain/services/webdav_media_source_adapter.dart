import '../../data/models/media_directory_entry.dart';
import '../../data/models/media_source.dart';
import '../repositories/media_directory_source.dart';
import 'webdav_service.dart';

/// 保持现有 WebDAV 缓存与 URL 安全语义的来源适配器。
class WebDavMediaSourceAdapter implements MediaDirectorySource {
  const WebDavMediaSourceAdapter(this.service);

  final WebDAVService service;

  @override
  MediaSourceDescriptor get descriptor => MediaSourceDescriptor(
    sourceId: service.sourceId,
    kind: MediaSourceKind.webdav,
    displayName: service.baseUrl,
  );

  @override
  bool get supportsRemoteSearch => true;

  @override
  List<MediaDirectoryEntry>? cachedDirectory(String relativePath) =>
      service.cachedDirectory(relativePath);

  @override
  Future<List<MediaDirectoryEntry>> fetchDirectory(
    String relativePath, {
    bool forceRefresh = false,
  }) async => service.fetchDirectory(relativePath, forceRefresh: forceRefresh);

  @override
  Future<MediaOpenTarget> resolve(MediaDirectoryEntry entry) async =>
      WebDavMediaOpenTarget(service.resolveUrl(entry.entryKey));
}
