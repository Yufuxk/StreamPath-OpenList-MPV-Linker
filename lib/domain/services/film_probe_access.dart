import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:dio/dio.dart';

import '../../core/utils/app_paths.dart';
import '../../core/utils/url_utils.dart' as urls;
import '../../data/models/film_catalog_item.dart';
import '../../data/models/web_dav_file.dart';
import '../../data/models/webdav_bdmv.dart';
import '../../data/remote/webdav_client.dart';
import '../repositories/media_directory_source.dart';
import 'iso_access_provider.dart';
import 'local_media_source.dart';
import 'special_video_playlist_collector.dart';
import 'webdav_media_source_adapter.dart';
import 'webdav_service.dart';

class FilmProbeTarget {
  const FilmProbeTarget(
    this.target, {
    this.headers = const {},
    this.metadata = const {},
  });
  final String target;
  final Map<String, String> headers;
  final Map<String, dynamic> metadata;
}

/// 探测复用原蓝光解析器，独立 helper 不连接播放器。
class FilmProbeAccess {
  final _bridge = IsoBridgeAccessProvider(mediaProbe: true);
  IsoAccessHandle? _handle;
  _LocalProbeServer? _server;
  Dio? _directoryClient;
  Timer? _deadline;
  bool _cancelled = false;
  bool _expired = false;
  void _check() {
    if (_expired) throw const FilmCatalogException('probeTimeout');
    if (_cancelled) throw const FilmCatalogException('cancelled');
  }

  Future<void> cancel() async {
    _cancelled = true;
    _bridge.cancel();
    await close();
  }

  Future<void> close() async {
    _deadline?.cancel();
    _directoryClient?.close(force: true);
    _directoryClient = null;
    final handle = _handle, server = _server;
    _handle = null;
    _server = null;
    await handle?.cleanup();
    await server?.close();
  }

  Future<FilmProbeTarget> prepare(
    FilmResource resource,
    MediaDirectorySource source,
  ) async {
    _cancelled = false;
    _expired = false;
    _deadline = Timer(const Duration(seconds: 90), () {
      _expired = true;
      _bridge.cancel();
      _directoryClient?.close(force: true);
    });
    _check();
    final disc = resource.mediaKind == 'iso' || resource.mediaKind == 'bdmv';
    WebDAVService? service;
    WebDavFile? file;
    if (source is LocalMediaSource) {
      final target = disc
          ? await source.resolveDiscDevice(resource.path)
          : await source.resolveRelativePath(resource.path);
      if (!disc) return FilmProbeTarget(target);
      _server = await _LocalProbeServer.open(target);
      service = WebDAVService(
        client: WebDavClient(baseUrl: _server!.baseUrl),
        profileId: resource.sourceId,
      );
      if (resource.mediaKind == 'iso') {
        file = WebDavFile(
          name: resource.name,
          href: _server!.url('disc.iso'),
          isDirectory: false,
        );
      } else {
        final manifest = <Map<String, Object>>[];
        await for (final entity in Directory(
          target,
        ).list(recursive: true, followLinks: false)) {
          _check();
          if (entity is! File && entity is! Directory) continue;
          final relative = p
              .relative(entity.path, from: target)
              .replaceAll('\\', '/');
          final canonical = await entity.resolveSymbolicLinks();
          if (!p.isWithin(target, canonical)) {
            throw const FilmCatalogException('invalidPath');
          }
          final stat = await entity.stat();
          manifest.add({
            'type': 'disc_file',
            'path': relative,
            'url': _server!.url(relative),
            'size': entity is File ? stat.size : 0,
            'directory': entity is Directory,
            'lastModified': HttpDate.format(stat.modified),
          });
          if (manifest.length > 32768) {
            throw const FilmCatalogException('probeBudgetExceeded');
          }
        }
        file = WebDavBdmv(
          name: resource.name,
          href: '${_server!.baseUrl}/',
          rootPath: '',
          files: manifest,
        );
      }
    } else if (source is WebDavMediaSourceAdapter) {
      final credentials = source.service.credentialSnapshot;
      _directoryClient = Dio();
      service = WebDAVService(
        client: WebDavClient(
          baseUrl: credentials.baseUrl,
          username: credentials.username,
          password: credentials.password,
          dio: _directoryClient,
          connectTimeout: const Duration(seconds: 5),
        ),
        profileId: resource.sourceId,
      );
      if (resource.mediaKind == 'strm') {
        throw const FilmCatalogException('probePlaybackOnly');
      }
      if (resource.mediaKind != 'bdmv') {
        final target = service.fullUrl(resource.path);
        file = WebDavFile(
          name: resource.name,
          href: target,
          isDirectory: false,
        );
        if (!urls.isSameOrigin(service.baseUrl, target)) {
          throw const FilmCatalogException('invalidPath');
        }
        if (!disc) return FilmProbeTarget(target, headers: _headers(service));
      } else {
        final queue = <String>[resource.path];
        final manifest = <Map<String, Object>>[];
        var directories = 0;
        while (queue.isNotEmpty) {
          _check();
          if (directories++ > 0) {
            await Future<void>.delayed(const Duration(seconds: 1));
          }
          _check();
          final directory = queue.removeAt(0);
          for (final entry in await service.fetchDirectory(
            directory,
            forceRefresh: true,
          )) {
            if (entry.isSelfEntry) continue;
            final child = SpecialVideoPlaylistCollector.directChildPath(
              source,
              directory,
              entry,
            );
            if (child == null) throw const FilmCatalogException('invalidPath');
            final relative = resource.path.isEmpty
                ? child
                : child.substring(resource.path.length + 1);
            final remoteFile = entry;
            manifest.add({
              'type': 'disc_file',
              'path': relative,
              'url': service.resolveUrl(remoteFile.href),
              'size': entry.isDirectory ? 0 : remoteFile.size,
              'directory': entry.isDirectory,
              if (remoteFile.etag != null) 'etag': remoteFile.etag!,
              if (remoteFile.lastModifiedHeader != null)
                'lastModified': remoteFile.lastModifiedHeader!,
            });
            if (manifest.length > 32768 || directories >= 128) {
              throw const FilmCatalogException('probeBudgetExceeded');
            }
            if (entry.isDirectory &&
                [
                  'bdmv',
                  'certificate',
                ].contains(relative.split('/').first.toLowerCase())) {
              queue.add(child);
            }
          }
        }
        file = WebDavBdmv(
          name: resource.name,
          href:
              '${service.fullUrl(resource.path).replaceAll(RegExp(r'/+$'), '')}/',
          rootPath: resource.path,
          files: manifest,
        );
      }
    } else {
      throw const FilmCatalogException('sourceUnavailable');
    }
    _check();
    final cache = await AppPaths.cacheDirectory();
    final directory = Directory(
      p.join(
        cache.path,
        'film_probe_sessions',
        '${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    final handle = await _bridge.prepare(
      webDavService: service,
      file: file,
      sessionDirectory: directory,
      structureCachePath: p.join(cache.path, 'iso_structure'),
    );
    _handle = handle;
    _check();
    await handle.configureCache(blockCount: 16, prefetchBlocks: 0);
    final titles = [...handle.titles]
      ..sort((a, b) => b.duration.compareTo(a.duration));
    final main = titles.first;
    return FilmProbeTarget(
      handle.playbackUri(main.mplsId).toString(),
      metadata: {
        'fileSize': handle.totalBytes,
        'duration': main.duration.inMilliseconds / 1000,
        'programme': main.mplsId,
        'programmes': [
          for (final title in handle.titles)
            {
              'id': title.mplsId,
              'duration': title.duration.inMilliseconds / 1000,
              'size': title.streamSize,
            },
        ],
      },
    );
  }

  static Map<String, String> _headers(WebDAVService service) {
    final credentials = service.credentialSnapshot;
    return {
      if (credentials.username.isNotEmpty)
        HttpHeaders.authorizationHeader:
            'Basic ${base64Encode(utf8.encode('${credentials.username}:${credentials.password}'))}',
    };
  }
}

/// 只向本次蓝光 helper 提供所选本地光盘的 Range。
class _LocalProbeServer {
  _LocalProbeServer(this.server, this.target, this.token, this.directory);
  final HttpServer server;
  final String target, token;
  final bool directory;
  String get baseUrl => 'http://127.0.0.1:${server.port}/$token';
  String url(String relative) =>
      '$baseUrl/${relative.split('/').map(Uri.encodeComponent).join('/')}';
  static Future<_LocalProbeServer> open(String target) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final token = List.generate(
      24,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final directory = await FileSystemEntity.isDirectory(target);
    final instance = _LocalProbeServer(
      server,
      await (directory ? Directory(target) : File(target))
          .resolveSymbolicLinks(),
      token,
      directory,
    );
    server.listen(instance._serve);
    return instance;
  }

  Future<void> _serve(HttpRequest request) async {
    try {
      final segments = request.uri.pathSegments;
      if (segments.length < 2 ||
          segments.first != token ||
          !['HEAD', 'GET'].contains(request.method)) {
        request.response.statusCode = 404;
        return;
      }
      final relative = validateFilmPath(segments.skip(1).join('/'));
      if (!directory && relative != 'disc.iso') {
        request.response.statusCode = 404;
        return;
      }
      final file = File(
        directory ? p.joinAll([target, ...relative.split('/')]) : target,
      );
      final canonical = await file.resolveSymbolicLinks();
      if (directory && !p.isWithin(target, canonical)) {
        request.response.statusCode = 404;
        return;
      }
      final stat = await file.stat();
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.headers.set(
        HttpHeaders.lastModifiedHeader,
        HttpDate.format(stat.modified),
      );
      request.response.headers.set(
        HttpHeaders.etagHeader,
        '"${stat.size}-${stat.modified.millisecondsSinceEpoch}"',
      );
      if (request.method == 'HEAD') {
        request.response.contentLength = stat.size;
        return;
      }
      final range = RegExp(
        r'^bytes=(\d+)-(\d*)$',
      ).firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
      if (range == null) {
        request.response.statusCode = 400;
        return;
      }
      final start = int.parse(range[1]!);
      final end = range[2]!.isEmpty
          ? stat.size - 1
          : int.parse(range[2]!).clamp(0, stat.size - 1);
      if (start > end) {
        request.response.statusCode = 416;
        return;
      }
      request.response.statusCode = 206;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${stat.size}',
      );
      request.response.contentLength = end - start + 1;
      await request.response.addStream(file.openRead(start, end + 1));
    } on FileSystemException {
      request.response.statusCode = 404;
    } on FilmCatalogException {
      request.response.statusCode = 404;
    } on HttpException {
      request.response.statusCode = 500;
    } on SocketException {
      /* helper 取消时连接关闭。 */
    } finally {
      try {
        await request.response.close();
      } on SocketException {
        /* helper 已断开。 */
      }
    }
  }

  Future<void> close() => server.close(force: true);
}
