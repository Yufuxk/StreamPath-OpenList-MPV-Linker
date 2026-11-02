// TMDB 响应录制／重放适配器：首次联网落盘，之后离线可复现。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

class RecordingHttpAdapter implements HttpClientAdapter {
  RecordingHttpAdapter(
    this.directory, {
    this.record = true,
    this.offline = false,
  });

  final String directory;
  final bool record;
  final bool offline;
  int recorded = 0;
  int replayed = 0;

  // 两个固定 TMDB 入口返回同一份数据，缓存键忽略主机名以便离线共用。
  String _key(Uri uri) => sha256
      .convert(utf8.encode('${uri.path}?${uri.query}'))
      .toString()
      .substring(0, 32);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    if (uri.scheme != 'https' ||
        !(uri.host == 'api.themoviedb.org' || uri.host == 'api.tmdb.org')) {
      throw DioException(
        requestOptions: options,
        message: 'Probe TMDB adapter rejected ${uri.scheme}://${uri.host}',
      );
    }
    final file = File(p.join(directory, '${_key(uri)}.json'));
    if (file.existsSync()) {
      replayed++;
      final saved = jsonDecode(await file.readAsString()) as Map;
      return ResponseBody.fromString(
        jsonEncode(saved['body']),
        saved['status'] as int,
        headers: {
          'content-type': ['application/json'],
          if (saved['retryAfter'] is String)
            'retry-after': [saved['retryAfter'] as String],
        },
      );
    }
    if (offline) {
      throw DioException(
        requestOptions: options,
        message: 'Probe TMDB cache miss while offline',
      );
    }
    // 录制阶段允许传输层重试，避免一次握手失败中断整轮取证。
    for (var attempt = 1; ; attempt++) {
      try {
        return await _download(options, uri, file);
      } on IOException catch (error) {
        if (attempt >= 3) {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
            error: error,
          );
        }
        await Future<void>.delayed(Duration(seconds: attempt));
      }
    }
  }

  Future<ResponseBody> _download(
    RequestOptions options,
    Uri uri,
    File file,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(uri);
      request.headers.set(
        HttpHeaders.authorizationHeader,
        '${options.headers['Authorization'] ?? ''}'.toString(),
      );
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final status = response.statusCode;
      if (record) {
        Directory(directory).createSync(recursive: true);
        await file.writeAsString(
          jsonEncode({
            'uri': uri.toString(),
            'status': status,
            'retryAfter': response.headers.value('retry-after'),
            'body':
                body.isEmpty ||
                    status == 404 ||
                    status == 401 ||
                    status == 403 ||
                    status == 429
                ? const <String, Object?>{}
                : jsonDecode(body),
          }),
        );
        recorded++;
      }
      return ResponseBody.fromString(
        body.isEmpty ? '{}' : body,
        status,
        headers: {
          'content-type': ['application/json'],
          if (response.headers.value('retry-after') case final value?)
            'retry-after': [value],
        },
      );
    } finally {
      client.close(force: true);
    }
  }

  @override
  void close({bool force = false}) {}
}
