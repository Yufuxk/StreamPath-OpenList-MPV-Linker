import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/data/remote/webdav_client.dart';

void main() {
  final servers = <HttpServer>[];

  Future<HttpServer> serve(
    Future<void> Function(HttpRequest request) handler,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    servers.add(server);
    server.listen(handler);
    return server;
  }

  String origin(HttpServer server) =>
      'http://${server.address.address}:${server.port}';

  tearDown(() async {
    for (final server in servers) {
      await server.close(force: true);
    }
    servers.clear();
  });

  test('空密码仍发送用户名对应的 Basic 认证', () async {
    String? authorization;
    final server = await serve((request) async {
      authorization = request.headers.value(HttpHeaders.authorizationHeader);
      request.response
        ..statusCode = HttpStatus.multiStatus
        ..write('<multistatus/>');
      await request.response.close();
    });
    final client = WebDavClient(
      baseUrl: '${origin(server)}/dav',
      username: 'user',
      password: '',
    );

    await client.propfind('');

    expect(authorization, 'Basic ${base64Encode(utf8.encode('user:'))}');
  });

  test('PROPFIND 同源重定向保留方法、Depth 与认证', () async {
    final methods = <String>[];
    String? depth;
    String? authorization;
    late HttpServer server;
    server = await serve((request) async {
      methods.add(request.method);
      if (request.uri.path != '/final/') {
        request.response
          ..statusCode = HttpStatus.movedPermanently
          ..headers.set(HttpHeaders.locationHeader, '/final/');
      } else {
        depth = request.headers.value('Depth');
        authorization = request.headers.value(HttpHeaders.authorizationHeader);
        request.response
          ..statusCode = HttpStatus.multiStatus
          ..write('<multistatus/>');
      }
      await request.response.close();
    });
    final client = WebDavClient(
      baseUrl: '${origin(server)}/dav',
      username: 'user',
      password: 'secret',
    );

    await client.propfind('');

    expect(methods, ['PROPFIND', 'PROPFIND']);
    expect(depth, '1');
    expect(authorization, isNotNull);
  });

  test('GET 跨源重定向不会向目标服务器发送认证', () async {
    String? sourceAuthorization;
    String? targetAuthorization;
    final target = await serve((request) async {
      targetAuthorization = request.headers.value(
        HttpHeaders.authorizationHeader,
      );
      request.response.write('https://media.example/video.mkv');
      await request.response.close();
    });
    final source = await serve((request) async {
      sourceAuthorization = request.headers.value(
        HttpHeaders.authorizationHeader,
      );
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(
          HttpHeaders.locationHeader,
          '${origin(target)}/pointer.strm',
        );
      await request.response.close();
    });
    final client = WebDavClient(
      baseUrl: '${origin(source)}/dav',
      username: 'user',
      password: 'secret',
    );

    final content = await client.getFileContent(
      '${origin(source)}/redirect.strm',
      maxBytes: 8192,
    );

    expect(content, 'https://media.example/video.mkv');
    expect(sourceAuthorization, isNotNull);
    expect(targetAuthorization, isNull);
  });

  test('STRM 未声明长度时也在读取过程中执行字节上限', () async {
    final server = await serve((request) async {
      request.response.write(List.filled(5000, 'a').join());
      await request.response.flush();
      request.response.write(List.filled(5000, 'b').join());
      await request.response.close();
    });
    final client = WebDavClient(baseUrl: '${origin(server)}/dav');

    await expectLater(
      client.getFileContent('${origin(server)}/large.strm', maxBytes: 8192),
      throwsA(isA<ParseException>()),
    );
  });

  test('原始字节读取保留 LRC 的非 UTF-8 编码', () async {
    const bytes = <int>[0xff, 0xfe, 0x5b, 0x00, 0x30, 0x00];
    final server = await serve((request) async {
      request.response
        ..headers.contentLength = bytes.length
        ..add(bytes);
      await request.response.close();
    });
    final client = WebDavClient(baseUrl: '${origin(server)}/dav');

    expect(
      await client.getFileBytes('${origin(server)}/song.lrc', maxBytes: 64),
      bytes,
    );
  });
}
