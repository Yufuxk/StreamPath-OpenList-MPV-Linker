import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';
import '../../data/models/film_catalog_item.dart';
import 'native_storage_reader.dart';

/// 播放会话只访问本机随机端口；来源内的路径仍由读取器校验。
class StorageRangeBridge {
  StorageRangeBridge._(this.reader, this._server, this._token);
  final StorageFileReader reader;
  final HttpServer _server;
  final String _token;
  final Set<Future<void>> _requests = {};
  StreamSubscription<HttpRequest>? _subscription;
  bool _closed = false;
  String get baseUrl => 'http://127.0.0.1:${_server.port}/$_token/';
  String url(String path) =>
      '$baseUrl${validateFilmPath(path).split('/').map(Uri.encodeComponent).join('/')}';
  static Future<StorageRangeBridge> open(StorageFileReader reader) async {
    final token = base64Url
        .encode(List.generate(24, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');
    final bridge = StorageRangeBridge._(
      reader,
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      token,
    );
    bridge._subscription = bridge._server.listen(bridge._dispatch);
    return bridge;
  }

  void _dispatch(HttpRequest request) {
    if (_closed || _requests.length >= 8) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      unawaited(request.response.close());
      return;
    }
    final task = _serve(request);
    _requests.add(task);
    unawaited(task.whenComplete(() => _requests.remove(task)));
  }

  static String _xml(String text) => XmlText(text).toXmlString();
  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    var started = false;
    try {
      final parts = request.uri.pathSegments;
      if (parts.isEmpty || parts.first != _token) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final segments = parts.skip(1).toList();
      if (segments.isNotEmpty && segments.last.isEmpty) segments.removeLast();
      if (segments.any(
        (part) => part.isEmpty || part.contains('/') || part.contains('\\'),
      )) {
        throw const FilmCatalogException('invalidPath');
      }
      final path = validateFilmPath(segments.join('/'));
      if (request.method == 'PROPFIND') {
        if (!['0', '1'].contains(request.headers.value('Depth') ?? '1')) {
          response.statusCode = HttpStatus.forbidden;
          return;
        }
        final rows = await reader.list(path);
        final body = StringBuffer(
          '<?xml version="1.0" encoding="utf-8"?><d:multistatus xmlns:d="DAV:">',
        );
        void item(
          String name,
          String logicalPath,
          bool directory,
          int size,
          int modified,
        ) {
          final href =
              '${Uri.parse(url(logicalPath)).path}${directory && logicalPath.isNotEmpty ? '/' : ''}';
          body.write(
            '<d:response><d:href>${_xml(href)}</d:href><d:propstat><d:prop>'
            '<d:displayname>${_xml(name)}</d:displayname><d:resourcetype>${directory ? '<d:collection/>' : ''}</d:resourcetype>'
            '<d:getcontentlength>$size</d:getcontentlength>'
            '${modified > 0 ? '<d:getlastmodified>${HttpDate.format(DateTime.fromMillisecondsSinceEpoch(modified, isUtc: true))}</d:getlastmodified>' : ''}'
            '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>',
          );
        }

        item(path.isEmpty ? '' : path.split('/').last, path, true, 0, 0);
        if (request.headers.value('Depth') != '0') {
          for (final row in rows) {
            final name = row['name'] as String;
            if (name.isEmpty ||
                name.contains('/') ||
                name.contains('\\') ||
                name == '.' ||
                name == '..') {
              throw const FilmCatalogException('invalidPath');
            }
            item(
              name,
              path.isEmpty ? name : '$path/$name',
              row['directory'] as bool,
              row['size'] as int? ?? 0,
              row['modified'] as int? ?? 0,
            );
          }
        }
        body.write('</d:multistatus>');
        response.statusCode = 207;
        response.headers.contentType = ContentType(
          'application',
          'xml',
          charset: 'utf-8',
        );
        started = true;
        response.write(body);
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      final stat = await reader.stat(path);
      if (stat['directory'] == true) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final size = stat['size'] as int;
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      response.headers.contentType = ContentType.binary;
      if (stat['version'] case final String version) {
        response.headers.set(
          HttpHeaders.etagHeader,
          '"${sha256.convert(utf8.encode(version))}"',
        );
      }
      if (stat['modified'] case final int modified when modified > 0) {
        response.headers.set(
          HttpHeaders.lastModifiedHeader,
          HttpDate.format(
            DateTime.fromMillisecondsSinceEpoch(modified, isUtc: true),
          ),
        );
      }
      var start = 0, end = size - 1;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range);
        if (match == null || match[1]!.isEmpty && match[2]!.isEmpty) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
          return;
        }
        if (match[1]!.isEmpty) {
          final suffix = int.tryParse(match[2]!);
          if (suffix == null || suffix <= 0) {
            response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
            return;
          }
          start = max(0, size - suffix);
        } else {
          start = int.tryParse(match[1]!) ?? size;
          if (match[2]!.isNotEmpty) {
            end = min(int.tryParse(match[2]!) ?? -1, end);
          }
        }
        if (start >= size || end < start) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
          return;
        }
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$size',
        );
      }
      response.contentLength = end - start + 1;
      if (request.method == 'HEAD' || start > end) return;
      var bytes = await reader.read(
        path,
        start,
        min(1024 * 1024, end - start + 1),
      );
      if (bytes.isEmpty) throw const FilmCatalogException('sourceReadFailed');
      started = true;
      Stream<List<int>> body() async* {
        while (!_closed && start <= end) {
          yield bytes;
          start += bytes.length;
          if (_closed || start > end) break;
          bytes = await reader.read(
            path,
            start,
            min(1024 * 1024, end - start + 1),
          );
          if (bytes.isEmpty) {
            throw const FilmCatalogException('sourceReadFailed');
          }
        }
      }

      // 连接断开时取消数据流，停止继续读取已被播放器放弃的范围。
      await response.addStream(body());
    } on FilmCatalogException catch (error) {
      if (!started) {
        response.statusCode = error.code == 'sourceFileMissing'
            ? HttpStatus.notFound
            : HttpStatus.badGateway;
        response.contentLength = 0;
      }
    } on SocketException {
      // 播放器取消读取或断开会话。
    } on HttpException {
      // 响应已经开始时通过关闭连接报告读取失败。
    } finally {
      try {
        await response.close();
      } on HttpException {
        /* 读取已经取消。 */
      } on SocketException {
        /* 连接已经结束。 */
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    await _server.close(force: true);
    reader.cancelCurrent();
    await Future.wait(_requests.toList());
    await reader.close();
  }
}
