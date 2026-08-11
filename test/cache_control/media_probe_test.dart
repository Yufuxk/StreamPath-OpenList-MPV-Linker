import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/features/cache_control/providers/media_probe.dart';

void main() {
  late HttpServer server;
  late Uri baseUri;
  String? lastAuthHeader;
  String? lastHost;
  String? lastRange;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUri = Uri.parse('http://127.0.0.1:${server.port}');
    lastAuthHeader = null;
    server.listen((request) async {
      lastAuthHeader = request.headers.value(HttpHeaders.authorizationHeader);
      lastHost = request.headers.value(HttpHeaders.hostHeader);
      lastRange = request.headers.value(HttpHeaders.rangeHeader);
      if (request.uri.path == '/hang') {
        // 挂起不响应（超时测试用）。
        return;
      }
      if (request.uri.path == '/missing') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      if (request.uri.path == '/redirect') {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, '/final');
        await request.response.close();
        return;
      }
      if (request.uri.path == '/head405' && request.method == 'HEAD') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
        return;
      }
      if (request.uri.path == '/head405') {
        request.response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-0/654321')
          ..headers.contentLength = 1
          ..write('x');
        await request.response.close();
        return;
      }
      if (request.uri.path == '/validators') {
        request.response.headers
          ..set(HttpHeaders.etagHeader, '"v1"')
          ..set(
            HttpHeaders.lastModifiedHeader,
            'Sun, 09 Aug 2026 00:00:00 GMT',
          );
      }
      request.response.headers.set('Content-Length', '123456');
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('HEAD 成功返回 Content-Length', () async {
    final result = await HttpMediaProbe().probeContentLength(
      url: baseUri.toString(),
    );
    expect(result.ok, isTrue);
    expect(result.contentLengthBytes, 123456);
  });

  test('传递 Authorization 头', () async {
    await HttpMediaProbe().probeContentLength(
      url: baseUri.toString(),
      authHeader: 'Basic dXNlcjpwYXNz',
    );
    expect(lastAuthHeader, 'Basic dXNlcjpwYXNz');
  });

  test('同源重定向继续探测并保留 Authorization', () async {
    final result = await HttpMediaProbe().probeContentLength(
      url: baseUri.resolve('/redirect').toString(),
      authHeader: 'Basic dXNlcjpwYXNz',
    );
    expect(result.contentLengthBytes, 123456);
    expect(lastAuthHeader, 'Basic dXNlcjpwYXNz');
  });

  test('HEAD 405 时用 1 字节 Range GET 获取总大小', () async {
    final result = await HttpMediaProbe().probeContentLength(
      url: baseUri.resolve('/head405').toString(),
    );
    expect(result.contentLengthBytes, 654321);
    expect(lastRange, 'bytes=0-0');
  });

  test('返回 ETag 与 Last-Modified 供元数据失效校验', () async {
    final result = await HttpMediaProbe().probeContentLength(
      url: baseUri.resolve('/validators').toString(),
    );
    expect(result.etag, '"v1"');
    expect(result.lastModified, 'Sun, 09 Aug 2026 00:00:00 GMT');
  });

  test('不传认证头时请求无 Authorization', () async {
    await HttpMediaProbe().probeContentLength(url: baseUri.toString());
    expect(lastAuthHeader, isNull);
  });

  test('Host 头包含非默认端口（虚拟主机不错配）', () async {
    await HttpMediaProbe().probeContentLength(url: baseUri.toString());
    expect(lastHost, '127.0.0.1:${server.port}');
  });

  test('总 deadline：服务端挂起时总耗时不超过超时上限', () async {
    final probe = HttpMediaProbe(timeout: const Duration(milliseconds: 500));
    final sw = Stopwatch()..start();
    final result = await probe.probeContentLength(
      url: baseUri.resolve('/hang').toString(),
    );
    sw.stop();
    expect(result.ok, isFalse);
    expect(result.error, contains('超时'));
    // 总 deadline 模型：单阶段超时即返回，不因多阶段叠加而翻倍。
    expect(sw.elapsedMilliseconds, lessThan(1500));
  });

  test('404 降级不抛出', () async {
    final result = await HttpMediaProbe().probeContentLength(
      url: baseUri.resolve('/missing').toString(),
    );
    expect(result.ok, isFalse);
    expect(result.error, contains('404'));
  });

  test('超时降级不抛出', () async {
    final result = await HttpMediaProbe(
      timeout: const Duration(milliseconds: 200),
    ).probeContentLength(url: baseUri.resolve('/hang').toString());
    expect(result.ok, isFalse);
    expect(result.error, contains('超时'));
  });

  test('非法 URL 降级不抛出', () async {
    final result = await HttpMediaProbe().probeContentLength(url: 'not a url');
    expect(result.ok, isFalse);
  });

  test('含控制字符的 URL 被拒绝（防请求行注入）', () async {
    final result = await HttpMediaProbe().probeContentLength(
      url: 'http://127.0.0.1:${server.port}/dav/x\r\nInjected: y',
    );
    expect(result.ok, isFalse);
    expect(result.error, contains('控制字符'));
  });

  test('连接被拒绝降级不抛出', () async {
    // 127.0.0.1:1 几乎必然无服务。
    final result = await HttpMediaProbe().probeContentLength(
      url: 'http://127.0.0.1:1/x',
    );
    expect(result.ok, isFalse);
  });
}
