import '../../data/models/media_directory_entry.dart';
import '../../data/models/media_source.dart';

/// WebDAV 与本地目录共用的按需浏览边界。
abstract interface class MediaDirectorySource {
  MediaSourceDescriptor get descriptor;

  Future<List<MediaDirectoryEntry>> fetchDirectory(
    String relativePath, {
    bool forceRefresh = false,
  });

  List<MediaDirectoryEntry>? cachedDirectory(String relativePath);

  Future<MediaOpenTarget> resolve(MediaDirectoryEntry entry);

  bool get supportsRemoteSearch;
}
