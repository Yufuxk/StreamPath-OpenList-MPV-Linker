import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/domain/services/openlist_api_client.dart';

void main() {
  test('官方 envelope 同时校验 HTTP 与 JSON code', () {
    final success = OpenListEnvelope.parse(
      const OpenListHttpResponse(
        statusCode: 200,
        data: {'code': 200, 'data': <String, Object?>{}},
      ),
    );
    final apiFailure = OpenListEnvelope.parse(
      const OpenListHttpResponse(
        statusCode: 200,
        data: {'code': 500, 'message': 'internal failure'},
      ),
    );
    final html = OpenListEnvelope.parse(
      const OpenListHttpResponse(statusCode: 200, data: '<html>proxy</html>'),
    );

    expect(success.success, isTrue);
    expect(apiFailure.success, isFalse);
    expect(apiFailure.message, 'internal failure');
    expect(html.payload, isNull);
    expect(html.success, isFalse);
    expect(html.endpointUnavailable, isTrue);
  });

  test('能力矩阵按功能拆分旧 AList 与 OpenList', () {
    final old = OpenListCapabilities.fromVersion('v3.0.1');
    final searchOnly = OpenListCapabilities.fromVersion('v3.6.0');
    final current = OpenListCapabilities.fromVersion('v4.2.5');

    expect(old.indexSearch, OpenListCapabilitySupport.unsupported);
    expect(old.webDavConnection, OpenListCapabilitySupport.supported);
    expect(old.storageReload, OpenListCapabilitySupport.unsupported);
    expect(searchOnly.indexSearch, OpenListCapabilitySupport.supported);
    expect(searchOnly.indexProgress, OpenListCapabilitySupport.supported);
    expect(searchOnly.indexUpdate, OpenListCapabilitySupport.unsupported);
    expect(searchOnly.storageReload, OpenListCapabilitySupport.unsupported);
    expect(current.indexSearch, OpenListCapabilitySupport.supported);
    expect(current.indexUpdate, OpenListCapabilitySupport.supported);
    expect(current.storageReload, OpenListCapabilitySupport.supported);
    final future = OpenListCapabilities.fromVersion('v5.0.0');
    expect(future.indexSearch, OpenListCapabilitySupport.unknown);
    expect(future.webDavConnection, OpenListCapabilitySupport.supported);
    expect(future.indexUpdate, OpenListCapabilitySupport.unknown);
    expect(future.storageReload, OpenListCapabilitySupport.unknown);
  });

  test('静态能力矩阵不越过已核验版本边界', () {
    for (final version in const [
      'v4.2.6',
      'v4.99',
      'v4.99.0',
      'v3.64',
      'v3.64.0',
    ]) {
      final capabilities = OpenListCapabilities.fromVersion(version);
      expect(
        capabilities.indexSearch,
        OpenListCapabilitySupport.unknown,
        reason: '$version 尚未经过真实合同矩阵核验',
      );
      expect(capabilities.indexProgress, OpenListCapabilitySupport.unknown);
      expect(capabilities.indexUpdate, OpenListCapabilitySupport.unknown);
      expect(capabilities.storageReload, OpenListCapabilitySupport.unknown);
    }
  });

  test('静态能力矩阵只保留七个真实合同版本的已知结论', () {
    for (final version in const [
      'v4.0.0',
      'v4.1.4',
      'v4.1.4 (Commit: 2edc446c) - Frontend: v4.1.4 - Build at: 2025-10-01 12:23:50 +0000',
      'v4.2.5',
      'v3.63.0',
    ]) {
      final capabilities = OpenListCapabilities.fromVersion(version);
      expect(capabilities.indexSearch, OpenListCapabilitySupport.supported);
      expect(capabilities.indexProgress, OpenListCapabilitySupport.supported);
      expect(capabilities.indexUpdate, OpenListCapabilitySupport.supported);
      expect(capabilities.storageReload, OpenListCapabilitySupport.supported);
    }

    final alist371 = OpenListCapabilities.fromVersion('v3.7.1');
    expect(alist371.indexSearch, OpenListCapabilitySupport.supported);
    expect(alist371.indexUpdate, OpenListCapabilitySupport.supported);
    expect(alist371.storageReload, OpenListCapabilitySupport.supported);
    expect(
      OpenListCapabilities.fromVersion('v4.1.4-custom').storageReload,
      OpenListCapabilitySupport.unknown,
      reason: '非官方无空格后缀不能借已核验版本乐观通过',
    );
  });

  test('共享认证层把 code 402 解析为明确 2FA Token 指引', () async {
    final client = OpenListApiClient(
      requestSender: (uri, {required method, headers, body, timeout}) async =>
          const OpenListHttpResponse(
            statusCode: 200,
            data: {'code': 402, 'message': 'otp required'},
          ),
    );

    final result = await OpenListAuthenticator(client).login(
      Uri.parse('https://openlist.test'),
      username: 'alice',
      password: 'secret',
      role: '普通用户',
    );

    expect(result.outcome, OpenListAuthOutcome.requiresTwoFactor);
    expect(result.message, allOf(contains('2FA'), contains('普通用户 Token')));
  });

  test('重定向共享总 deadline 且每跳设置 connectTimeout', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final step = int.tryParse(request.uri.queryParameters['step'] ?? '') ?? 0;
      await Future<void>.delayed(const Duration(milliseconds: 45));
      if (step < 4) {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, '/api?step=${step + 1}');
      } else {
        request.response.write(jsonEncode({'code': 200}));
      }
      await request.response.close();
    });
    final observed = <Duration>[];
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          observed.add(options.connectTimeout!);
          handler.next(options);
        },
      ),
    );
    final client = OpenListApiClient(dio: dio);
    final stopwatch = Stopwatch()..start();

    final response = await client.request(
      Uri.parse('http://${server.address.address}:${server.port}/api?step=0'),
      method: 'GET',
      timeout: const Duration(milliseconds: 120),
    );
    stopwatch.stop();

    expect(response.transportFailure, OpenListTransportFailure.timeout);
    expect(observed, isNotEmpty);
    expect(
      observed.every((value) => value <= const Duration(milliseconds: 120)),
      isTrue,
    );
    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 350)));
  });

  test('不可连接地址在请求预算内返回传输失败', () async {
    final reserved = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = reserved.port;
    await reserved.close(force: true);
    final stopwatch = Stopwatch()..start();

    final response = await OpenListApiClient().request(
      Uri.parse('http://127.0.0.1:$port/api/public/settings'),
      method: 'GET',
      timeout: const Duration(milliseconds: 300),
    );
    stopwatch.stop();

    expect(response.failedInTransport, isTrue);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
  });
}
