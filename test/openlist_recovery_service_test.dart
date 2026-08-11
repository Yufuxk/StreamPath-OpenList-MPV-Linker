import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/openlist_recovery_config.dart';
import 'package:streampath/domain/services/openlist_recovery_service.dart';

void main() {
  test('后台地址规范化兼容站点根路径、/dav 与 /api', () {
    expect(
      OpenListRecoveryService.normalizeBaseUri(
        'http://host:5244/dav',
      ).toString(),
      'http://host:5244',
    );
    expect(
      OpenListRecoveryService.normalizeBaseUri(
        'https://host.example/openlist/dav/',
      ).toString(),
      'https://host.example/openlist',
    );
    expect(OpenListRecoveryService.normalizeBaseUri('ftp://host/dav'), isNull);
  });

  test('原 WebDAV 地址已恢复时不登录、不刷新全部存储', () async {
    final paths = <String>[];
    final service = OpenListRecoveryService(
      requestSender: (uri, {required method, headers, body, timeout}) async {
        paths.add(uri.path);
        return const OpenListHttpResponse(
          statusCode: 200,
          data: {
            'code': 200,
            'data': {'version': 'v4.2.4'},
          },
        );
      },
      mediaProbe: (uri, {username, password, timeout}) async => true,
    );

    final result = await service.prepare(
      config: const OpenListRecoveryConfig(
        enabled: true,
        baseUrl: 'http://host:5244',
        username: 'admin',
        password: 'pass',
      ),
      mediaUrl: 'http://host:5244/dav/movie.mkv',
      webDavUsername: 'viewer',
      webDavPassword: 'viewer-pass',
    );

    expect(result.success, isTrue);
    expect(result.storageReloaded, isFalse);
    expect(result.serverVersion, 'v4.2.4');
    expect(paths, ['/api/public/settings']);
  });

  test('OpenList v4 / AList v3 通用登录后刷新并等待媒体恢复', () async {
    final calls =
        <({String method, String path, Object? body, String? token})>[];
    var probes = 0;
    final service = OpenListRecoveryService(
      readinessTimeout: const Duration(seconds: 2),
      requestSender: (uri, {required method, headers, body, timeout}) async {
        calls.add((
          method: method,
          path: uri.path,
          body: body,
          token: headers?['authorization'],
        ));
        return switch (uri.path) {
          '/api/public/settings' => const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {'version': 'v3.45.0'},
            },
          ),
          '/api/auth/login' => const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'message': 'success',
              'data': {'token': 'admin-token'},
            },
          ),
          '/api/admin/storage/load_all' => const OpenListHttpResponse(
            statusCode: 200,
            data: {'code': 200, 'message': 'success'},
          ),
          '/api/admin/storage/list' => const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {'content': <Object>[]},
            },
          ),
          _ => const OpenListHttpResponse(statusCode: 404),
        };
      },
      mediaProbe: (uri, {username, password, timeout}) async {
        probes++;
        return probes >= 2;
      },
    );

    final result = await service.prepare(
      config: const OpenListRecoveryConfig(
        enabled: true,
        baseUrl: 'http://host:5244/dav',
        username: 'admin',
        password: 'pass',
      ),
      mediaUrl: 'http://host:5244/dav/movie.mkv',
      webDavUsername: 'viewer',
      webDavPassword: 'viewer-pass',
    );

    expect(result.success, isTrue);
    expect(result.storageReloaded, isTrue);
    expect(result.serverVersion, 'v3.45.0');
    expect(
      calls.map((call) => call.path),
      containsAllInOrder([
        '/api/public/settings',
        '/api/auth/login',
        '/api/admin/storage/load_all',
        '/api/admin/storage/list',
      ]),
    );
    final login = calls.firstWhere((call) => call.path == '/api/auth/login');
    expect(login.body, {'username': 'admin', 'password': 'pass'});
    expect(
      calls
          .firstWhere((call) => call.path == '/api/admin/storage/load_all')
          .token,
      'admin-token',
      reason: 'Authorization 必须直接使用 Token，不添加 Bearer',
    );
  });

  test('明文登录返回兼容层 404 时使用 AList 规定的加盐哈希', () async {
    Object? hashBody;
    var probes = 0;
    final service = OpenListRecoveryService(
      requestSender: (uri, {required method, headers, body, timeout}) async {
        if (uri.path == '/api/auth/login') {
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {'code': 404, 'message': 'not found'},
          );
        }
        if (uri.path == '/api/auth/login/hash') {
          hashBody = body;
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {'token': 'hash-token'},
            },
          );
        }
        return const OpenListHttpResponse(statusCode: 200, data: {'code': 200});
      },
      mediaProbe: (uri, {username, password, timeout}) async {
        probes++;
        return probes >= 2;
      },
    );

    final result = await service.prepare(
      config: const OpenListRecoveryConfig(
        enabled: true,
        baseUrl: 'http://host',
        username: 'admin',
        password: 'pass',
      ),
      mediaUrl: 'http://host/dav/movie.mkv',
    );

    expect(result.success, isTrue);
    expect(hashBody, {
      'username': 'admin',
      'password': sha256
          .convert(utf8.encode('pass-https://github.com/alist-org/alist'))
          .toString(),
    });
  });

  test('管理员 Token 不会随跨来源重定向外发', () async {
    var destinationReached = false;
    final destination = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    destination.listen((request) async {
      destinationReached = true;
      await request.drain<void>();
      request.response
        ..statusCode = HttpStatus.ok
        ..write(jsonEncode({'code': 200}));
      await request.response.close();
    });

    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
      await request.drain<void>();
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/api/public/settings') {
        request.response.write(jsonEncode({'code': 200}));
      } else if (request.uri.path == '/api/admin/storage/load_all') {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(
            HttpHeaders.locationHeader,
            'http://${destination.address.address}:${destination.port}/stolen',
          );
      } else {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write(jsonEncode({'code': 404}));
      }
      await request.response.close();
    });

    try {
      final service = OpenListRecoveryService(
        mediaProbe: (uri, {username, password, timeout}) async => false,
      );
      final result = await service.prepare(
        config: OpenListRecoveryConfig(
          enabled: true,
          baseUrl: 'http://${origin.address.address}:${origin.port}',
          token: 'sensitive-admin-token',
        ),
        mediaUrl:
            'http://${origin.address.address}:${origin.port}/dav/movie.mkv',
      );

      expect(result.success, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(destinationReached, isFalse);
    } finally {
      await origin.close(force: true);
      await destination.close(force: true);
    }
  });

  test('关闭功能时完全不访问媒体或后台', () async {
    var requestCount = 0;
    var probeCount = 0;
    final service = OpenListRecoveryService(
      requestSender: (uri, {required method, headers, body, timeout}) async {
        requestCount++;
        return const OpenListHttpResponse(statusCode: 500);
      },
      mediaProbe: (uri, {username, password, timeout}) async {
        probeCount++;
        return false;
      },
    );

    final result = await service.prepare(
      config: const OpenListRecoveryConfig(),
      mediaUrl: 'http://host/dav/movie.mkv',
    );
    expect(result.success, isFalse);
    expect(requestCount, 0);
    expect(probeCount, 0);
  });

  test('后台连接器抛出异常时返回失败结果而不是中断播放器监听', () async {
    final service = OpenListRecoveryService(
      requestSender: (uri, {required method, headers, body, timeout}) async =>
          throw StateError('unexpected transport failure'),
      mediaProbe: (uri, {username, password, timeout}) async => false,
    );

    final result = await service.prepare(
      config: const OpenListRecoveryConfig(
        enabled: true,
        baseUrl: 'http://127.0.0.1:5244',
        username: 'admin',
        password: 'secret',
      ),
      mediaUrl: 'http://127.0.0.1:5244/dav/movie.mkv',
    );

    expect(result.success, isFalse);
    expect(result.storageReloaded, isFalse);
    expect(result.message, contains('请求异常'));
  });
}
