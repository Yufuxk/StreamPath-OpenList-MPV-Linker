import 'dart:typed_data';
import '../../data/models/film_catalog_item.dart';
import '../../data/models/media_connection.dart';
import '../../data/models/media_source.dart';
import '../../data/models/web_dav_file.dart';
import '../../data/remote/webdav_client.dart';
import '../../data/local/playback_progress_db.dart';
import 'native_storage_reader.dart';
import 'storage_range_bridge.dart';
import 'webdav_media_source_adapter.dart';
import 'webdav_service.dart';

class StorageMediaEntry extends WebDavFile {
  const StorageMediaEntry({
    required super.name,
    required super.href,
    required super.isDirectory,
    super.size,
    super.modified,
    required this.kind,
    required this.logicalPath,
  });
  final MediaSourceKind kind;
  final String logicalPath;
  @override
  MediaSourceKind get sourceKind => kind;
  @override
  String get relativePath => logicalPath;
}

/// 原生枚举保留来源类型；现有播放器和蓝光链路通过会话桥读取字节。
class NativeStorageSource extends WebDavMediaSourceAdapter {
  NativeStorageSource._(this.config, this.bridge)
    : super(
        WebDAVService(
          client: WebDavClient(baseUrl: bridge.baseUrl),
          profileId: config.id,
          strmUrlResolver: (file, raw) => resolveStorageStrm(config, bridge, file, raw),
          persistentUrlResolver: (href) {
            final uri = Uri.parse(href);
            final prefix = Uri.parse(bridge.baseUrl).pathSegments.where((part) => part.isNotEmpty).length;
            final logical = uri.pathSegments.skip(prefix).where((part) => part.isNotEmpty).join('/');
            return '${PlaybackProgressService.logicalTarget(config.id, logical)}${uri.path.endsWith('/') ? '/' : ''}';
          },
          crossSessionStructureCache: false,
        ),
      );
  final MediaConnection config;
  final StorageRangeBridge bridge;
  StorageFileReader get reader => bridge.reader;
  final _directories = <String, List<StorageMediaEntry>>{};
  static Future<NativeStorageSource> open(
    MediaConnection config,
    String password, {
    String? libraryPath,
  }) async {
    final reader = await NativeStorageReader.open(
      config,
      password,
      libraryPath: libraryPath,
    );
    try {
      return NativeStorageSource._(
        config,
        await StorageRangeBridge.open(reader),
      );
    } catch (_) {
      await reader.close();
      rethrow;
    }
  }

  @override
  MediaSourceDescriptor get descriptor => MediaSourceDescriptor(
    sourceId: config.id,
    kind: config.kind,
    displayName: config.name,
  );
  @override
  bool get supportsRemoteSearch => false;
  @override
  List<StorageMediaEntry>? cachedDirectory(String relativePath) =>
      _directories[relativePath];
  @override
  Future<List<StorageMediaEntry>> fetchDirectory(
    String relativePath, {
    bool forceRefresh = false,
  }) async {
    final path = validateFilmPath(relativePath);
    if (!forceRefresh) {
      if (_directories[path] case final cached?) return cached;
    }
    final rows = await reader.list(path);
    final entries = <StorageMediaEntry>[];
    for (final row in rows) {
      final name = row['name'] as String;
      if (name.isEmpty ||
          name.contains('/') ||
          name.contains('\\') ||
          name == '.' ||
          name == '..') {
        throw const FilmCatalogException('invalidPath');
      }
      final child = path.isEmpty ? name : '$path/$name';
      entries.add(
        StorageMediaEntry(
          name: name,
          href: bridge.url(child),
          isDirectory: row['directory'] as bool,
          size: row['size'] as int,
          modified: (row['modified'] as int) > 0
              ? DateTime.fromMillisecondsSinceEpoch(row['modified'] as int)
              : null,
          kind: config.kind,
          logicalPath: child,
        ),
      );
    }
    _directories.remove(path);
    _directories[path] = entries;
    if (_directories.length > 128) _directories.remove(_directories.keys.first);
    return entries;
  }

  @override
  Future<List<StorageMediaEntry>> fetchCatalogDirectory(String path) =>
      fetchDirectory(path, forceRefresh: true);
  Future<Uint8List> readFile(String path, {required int maxBytes}) async {
    final stat = await reader.stat(path);
    final size = stat['size'] as int;
    if (size > maxBytes) throw const FilmCatalogException('imageTooLarge');
    final output = BytesBuilder(copy: false);
    while (output.length < size) {
      final chunk = await reader.read(
        path,
        output.length,
        (size - output.length).clamp(1, 1024 * 1024),
      );
      if (chunk.isEmpty) throw const FilmCatalogException('sourceReadFailed');
      output.add(chunk);
    }
    return output.takeBytes();
  }

  Future<void> createMissingFile(String path, Uint8List bytes) async {
    if (config.kind == MediaSourceKind.ftp) {
      throw const FilmCatalogException('sourceCreateUnsupported');
    }
    if (!config.canWrite) throw const FilmCatalogException('sourceReadOnly');
    final parent = path.contains('/')
        ? path.substring(0, path.lastIndexOf('/'))
        : '';
    final name = path.split('/').last;
    if ((await reader.list(parent)).any((row) => row['name'] == name)) return;
    await reader.createFile(path, bytes);
  }

  Future<void> close() => bridge.close();
}

String? resolveStorageStrm(MediaConnection config, StorageRangeBridge bridge, WebDavFile file, String raw) {
  final target = Uri.tryParse(raw);
  if (target == null) return null;
  if (!target.hasScheme) return Uri.parse(file.href).resolveUri(target).toString();
  if (target.scheme == 'http' || target.scheme == 'https') return target.toString();
  final root = Uri.parse(config.url);
  if (target.scheme != root.scheme || target.host != root.host || target.port != root.port) return null;
  final prefix = root.path.endsWith('/') ? root.path : '${root.path}/';
  if (!target.path.startsWith(prefix)) return null;
  return bridge.url(validateFilmPath(Uri.decodeComponent(target.path.substring(prefix.length))));
}
