import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import '../../data/local/film_catalog_store.dart';
import '../../data/models/film_catalog_item.dart';
import '../../data/models/media_directory_entry.dart';
import '../../data/models/media_source.dart';
import '../../data/models/web_dav_file.dart';
import '../../data/remote/webdav_client.dart';
import 'media_server_api.dart';
import 'native_storage_reader.dart';
import 'native_storage_source.dart';
import 'storage_range_bridge.dart';
import 'webdav_media_source_adapter.dart';
import 'webdav_service.dart';

/// 虚拟目录只投影服务器条目和版本，字节读取始终走服务器静态直播放接口。
class MediaServerSource extends WebDavMediaSourceAdapter {
  MediaServerSource._(this.api, this.reader, this.bridge)
    : super(
        WebDAVService(
          client: WebDavClient(baseUrl: bridge.baseUrl),
          profileId: api.config.id,
        ),
      );
  final MediaServerApi api;
  final ServerFileReader reader;
  final StorageRangeBridge bridge;
  final _directories = <String, List<WebDavFile>>{};
  static Future<MediaServerSource> open(
    FilmCatalogStore store,
    MediaServerApi api,
  ) async {
    final reader = ServerFileReader(store, api);
    try {
      return MediaServerSource._(
        api,
        reader,
        await StorageRangeBridge.open(reader),
      );
    } catch (_) {
      await reader.close();
      rethrow;
    }
  }

  @override
  MediaSourceDescriptor get descriptor => MediaSourceDescriptor(
    sourceId: api.config.id,
    kind: api.config.kind,
    displayName: api.config.name,
  );
  @override
  bool get supportsRemoteSearch => false;
  @override
  List<MediaDirectoryEntry>? cachedDirectory(String relativePath) =>
      _directories[relativePath];
  @override
  Future<List<WebDavFile>> fetchDirectory(
    String relativePath, {
    bool forceRefresh = false,
  }) async {
    validateFilmPath(relativePath);
    final rows = await reader.list(relativePath);
    final entries = [
      for (final row in rows)
        StorageMediaEntry(
          name: row['name'] as String,
          href: bridge.url(
            relativePath.isEmpty
                ? row['name'] as String
                : '$relativePath/${row['name']}',
          ),
          isDirectory: row['directory'] as bool,
          kind: api.config.kind,
          logicalPath: relativePath.isEmpty
              ? row['name'] as String
              : '$relativePath/${row['name']}',
        ),
    ];
    _directories.remove(relativePath);
    _directories[relativePath] = entries;
    if (_directories.length > 128) _directories.remove(_directories.keys.first);
    return entries;
  }

  @override
  Future<List<WebDavFile>> fetchCatalogDirectory(String path) =>
      fetchDirectory(path, forceRefresh: true);
  Future<void> close() => bridge.close();
}

class ServerFileReader implements StorageFileReader {
  ServerFileReader(this.store, this.api);
  final FilmCatalogStore store;
  final MediaServerApi api;
  final _client = HttpClient();
  final _playback = <String, ServerPlaybackInfo>{};
  final _requests = <HttpClientRequest>{};
  bool _closed = false;
  ServerPlaybackInfo? playbackInfo(String path) => _playback[path];
  void releasePlayback(String path) => _playback.remove(path);
  Future<ServerPlaybackInfo> prepare(String path) async {
    if (_closed) throw const FilmCatalogException('cancelled');
    if (_playback[path] case final info?) return info;
    final row = await store.serverResource(api.config.id, path);
    if (row == null) throw const FilmCatalogException('sourceFileMissing');
    final state = jsonDecode(row['user_data_json'] as String) as Map;
    final pending = (await store.pendingServerStates(
      api.config.id,
    )).where((entry) => entry['itemId'] == row['item_id']).firstOrNull;
    final position = (pending?['state'] as Map?)?['positionMs'] as int?;
    final info = await api.playback(
      row['item_id'] as String,
      mediaSourceId: row['media_source_id'] as String,
      startTicks: position == null
          ? (state['PlaybackPositionTicks'] as num? ?? 0).toInt()
          : position * 10000,
    );
    _playback[path] = info;
    if (_playback.length > 128) _playback.remove(_playback.keys.first);
    return info;
  }

  @override
  Future<List<Map<String, dynamic>>> list(String path) async =>
      (await store.serverDirectory(
        api.config.id,
        path,
      )).map((row) => Map<String, dynamic>.from(row)).toList();
  Future<HttpClientResponse> _request(
    String path,
    String method, {
    String? range,
  }) async {
    final info = await prepare(path);
    final request = await _client
        .openUrl(method, Uri.parse(info.url))
        .timeout(const Duration(seconds: 15));
    request.followRedirects = false;
    request.headers.set('X-Emby-Token', api.token!);
    if (range != null) request.headers.set('Range', range);
    _requests.add(request);
    try {
      return await request.close().timeout(const Duration(seconds: 30));
    } on SocketException {
      throw const FilmCatalogException('serverConnectionFailed');
    } on HttpException {
      throw const FilmCatalogException('serverConnectionFailed');
    } finally {
      _requests.remove(request);
    }
  }

  @override
  Future<Map<String, dynamic>> stat(String path) async {
    final info = await prepare(path);
    if (info.size case final size?) {
      return {'size': size, 'directory': false, 'version': null};
    }
    final response = await _request(path, 'HEAD');
    await response.drain<void>();
    if (response.statusCode != 200 || response.contentLength < 0) {
      throw const FilmCatalogException('serverDirectPlayUnavailable');
    }
    return {
      'size': response.contentLength,
      'directory': false,
      'version': null,
    };
  }

  @override
  Future<Uint8List> read(String path, int offset, int count) async {
    if (count <= 0 || count > 1024 * 1024 || offset < 0) {
      throw ArgumentError('Invalid server read range');
    }
    final response = await _request(
      path,
      'GET',
      range: 'bytes=$offset-${offset + count - 1}',
    );
    if (response.statusCode != 206) {
      await response.listen((_) {}).cancel();
      throw const FilmCatalogException('sourceRangeUnsupported');
    }
    final contentRange = response.headers.value('Content-Range');
    if (contentRange == null || !contentRange.startsWith('bytes $offset-')) {
      await response.listen((_) {}).cancel();
      throw const FilmCatalogException('sourceRangeUnsupported');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      if (_closed) throw const FilmCatalogException('cancelled');
      bytes.add(chunk);
      if (bytes.length > count) {
        throw const FilmCatalogException('sourceRangeUnsupported');
      }
    }
    return bytes.takeBytes();
  }

  @override
  Future<void> createFile(String path, Uint8List bytes) async =>
      throw const FilmCatalogException('sourceReadOnly');
  @override
  void cancelCurrent() {
    for (final request in _requests.toList()) {
      request.abort();
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    cancelCurrent();
    _client.close(force: true);
    _playback.clear();
  }
}
