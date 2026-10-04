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

  test('建库 PROPFIND 只请求名称和目录类型，重定向保留 XML 请求体', () async {
    final bodies = <String>[];
    late HttpServer server;
    server = await serve((request) async {
      expect(request.method, 'PROPFIND');
      expect(request.headers.value('Depth'), '1');
      bodies.add(await utf8.decoder.bind(request).join());
      if (request.uri.path != '/final/') {
        request.response.statusCode = HttpStatus.temporaryRedirect;
        request.response.headers.set(HttpHeaders.locationHeader, '/final/');
      } else {
        request.response.statusCode = HttpStatus.multiStatus;
        request.response.write('<multistatus/>');
      }
      await request.response.close();
    });
    await WebDavClient(
      baseUrl: '${origin(server)}/dav',
    ).propfind('', namesOnly: true);
    expect(bodies, hasLength(2));
    expect(bodies[0], bodies[1]);
    expect(bodies[0], contains('<d:displayname/>'));
    expect(bodies[0], contains('<d:resourcetype/>'));
    expect(bodies[0], isNot(contains('allprop')));
    expect(bodies[0], isNot(contains('getcontentlength')));
    expect(bodies[0], isNot(contains('getlastmodified')));
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

  test('PROPFIND 遇到跨来源重定向时拒绝且目标服务器零请求', () async {
    var targetRequests = 0;
    final target = await serve((request) async {
      targetRequests++;
      request.response
        ..statusCode = HttpStatus.multiStatus
        ..write('<multistatus/>');
      await request.response.close();
    });
    final source = await serve((request) async {
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(
          HttpHeaders.locationHeader,
          '${origin(target)}/unexpected/',
        );
      await request.response.close();
    });
    final client = WebDavClient(
      baseUrl: '${origin(source)}/dav',
      username: 'user',
      password: 'secret',
    );

    await expectLater(
      client.propfind(''),
      throwsA(
        isA<NetworkException>().having(
          (error) => error.message,
          'message',
          contains('跨来源'),
        ),
      ),
    );

    expect(targetRequests, 0);
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

  test('流式下载保持 GET 认证与文件原始字节', () async {
    const bytes = <int>[0, 1, 2, 255, 4, 5];
    String? authorization;
    final server = await serve((request) async {
      authorization = request.headers.value(HttpHeaders.authorizationHeader);
      request.response
        ..headers.contentLength = bytes.length
        ..add(bytes.sublist(0, 3));
      await request.response.flush();
      request.response.add(bytes.sublist(3));
      await request.response.close();
    });
    final client = WebDavClient(
      baseUrl: '${origin(server)}/dav',
      username: 'user',
      password: 'secret',
    );
    final directory = await Directory.systemTemp.createTemp('font_download_');
    addTearDown(() => directory.delete(recursive: true));
    final destination = File('${directory.path}/font.ttf');
    final reports = <int>[];

    final received = await client.downloadFile(
      '${origin(server)}/font.ttf',
      destination,
      maxBytes: 64,
      timeout: const Duration(seconds: 2),
      onProgress: reports.add,
    );

    expect(received, bytes.length);
    expect(reports, isNotEmpty);
    expect(reports.last, bytes.length);
    expect(await destination.readAsBytes(), bytes);
    expect(authorization, 'Basic ${base64Encode(utf8.encode('user:secret'))}');
  });

  test('流式下载在无长度响应中仍执行字节上限', () async {
    final server = await serve((request) async {
      request.response.write(List.filled(5000, 'a').join());
      await request.response.flush();
      request.response.write(List.filled(5000, 'b').join());
      await request.response.close();
    });
    final client = WebDavClient(baseUrl: '${origin(server)}/dav');
    final directory = await Directory.systemTemp.createTemp('font_limit_');
    addTearDown(() => directory.delete(recursive: true));
    final destination = File('${directory.path}/oversize.ttf');

    await expectLater(
      client.downloadFile(
        '${origin(server)}/oversize.ttf',
        destination,
        maxBytes: 8192,
        timeout: const Duration(seconds: 2),
      ),
      throwsA(isA<ParseException>()),
    );
  });
}
