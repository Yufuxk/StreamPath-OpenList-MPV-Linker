import 'dart:async';
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

    expect(result.outcome, OpenListRecoveryOutcome.ready);
    expect(result.success, isTrue);
    expect(result.storageReloaded, isFalse);
    expect(result.serverVersion, 'v4.2.4');
    expect(paths, ['/api/public/settings']);
  });

  test('第二次恢复时媒体仍可读取则停止，不强制刷新全部存储', () async {
    final paths = <String>[];
    final service = OpenListRecoveryService(
      requestSender: (uri, {required method, headers, body, timeout}) async {
        paths.add(uri.path);
        return const OpenListHttpResponse(statusCode: 200, data: {'code': 200});
      },
      mediaProbe: (uri, {username, password, timeout}) async => true,
    );

    final result = await service.prepare(
      config: const OpenListRecoveryConfig(
        enabled: true,
        baseUrl: 'http://host:5244',
        token: 'admin-token',
      ),
      mediaUrl: 'http://host:5244/dav/movie.mkv',
      forceStorageReload: true,
    );

    expect(result.outcome, OpenListRecoveryOutcome.terminalNotLinkFailure);
    expect(result.success, isFalse);
    expect(result.terminal, isTrue);
    expect(result.storageReloaded, isFalse);
    expect(result.message, contains('不属于链接失效'));
    expect(paths, ['/api/public/settings']);
  });

  test('安全重启后先等待媒体自行恢复，不立即重复刷新存储', () async {
    final paths = <String>[];
    var probes = 0;
    final service = OpenListRecoveryService(
      readinessTimeout: const Duration(seconds: 2),
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
      mediaProbe: (uri, {username, password, timeout}) async {
        probes++;
        return probes >= 2;
      },
    );

    final result = await service.prepare(
      config: const OpenListRecoveryConfig(
        enabled: true,
        baseUrl: 'http://host:5244',
        token: 'admin-token',
      ),
      mediaUrl: 'http://host:5244/dav/movie.mkv',
      serverRestarted: true,
    );

    expect(result.outcome, OpenListRecoveryOutcome.ready);
    expect(result.success, isTrue);
    expect(result.storageReloaded, isFalse);
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

    expect(result.outcome, OpenListRecoveryOutcome.ready);
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

  test('媒体未恢复时不写成功冷却，下一次仍允许 load_all', () async {
    var now = DateTime.utc(2026, 8, 23);
    var loadAllRequests = 0;
    final service = OpenListRecoveryService(
      readinessTimeout: const Duration(seconds: 30),
      refreshCooldown: const Duration(minutes: 5),
      clock: () => now,
      requestSender: (uri, {required method, headers, body, timeout}) async {
        if (uri.path == '/api/admin/storage/load_all') loadAllRequests++;
        return const OpenListHttpResponse(statusCode: 200, data: {'code': 200});
      },
      mediaProbe: (uri, {username, password, timeout}) async {
        now = now.add(const Duration(minutes: 1));
        return false;
      },
    );
    const config = OpenListRecoveryConfig(
      enabled: true,
      baseUrl: 'http://host:5244',
      token: 'admin-token',
    );

    final first = await service.prepare(
      config: config,
      mediaUrl: 'http://host:5244/dav/movie.mkv',
    );
    final second = await service.prepare(
      config: config,
      mediaUrl: 'http://host:5244/dav/movie.mkv',
    );

    expect(first.outcome, OpenListRecoveryOutcome.retryableFailure);
    expect(second.outcome, OpenListRecoveryOutcome.retryableFailure);
    expect(loadAllRequests, 2);
    expect(first.message, contains('刷新流程结束'));
  });

  test('只有目标媒体恢复后才写成功冷却并抑制重复 load_all', () async {
    var probes = 0;
    var loadAllRequests = 0;
    final service = OpenListRecoveryService(
      requestSender: (uri, {required method, headers, body, timeout}) async {
        if (uri.path == '/api/admin/storage/load_all') loadAllRequests++;
        return const OpenListHttpResponse(statusCode: 200, data: {'code': 200});
      },
      mediaProbe: (uri, {username, password, timeout}) async {
        probes++;
        return probes == 2 || probes == 4;
      },
    );
    const config = OpenListRecoveryConfig(
      enabled: true,
      baseUrl: 'http://host:5244',
      token: 'admin-token',
    );

    final first = await service.prepare(
      config: config,
      mediaUrl: 'http://host:5244/dav/movie.mkv',
    );
    final second = await service.prepare(
      config: config,
      mediaUrl: 'http://host:5244/dav/movie.mkv',
    );

    expect(first.outcome, OpenListRecoveryOutcome.ready);
    expect(second.outcome, OpenListRecoveryOutcome.ready);
    expect(loadAllRequests, 1);
  });

  test('成功冷却不在不同凭据或不同目标媒体之间共享', () async {
    var loadAllRequests = 0;
    final probeCounts = <String, int>{};
    final service = OpenListRecoveryService(
      requestSender: (uri, {required method, headers, body, timeout}) async {
        if (uri.path == '/api/admin/storage/load_all') loadAllRequests++;
        return const OpenListHttpResponse(statusCode: 200, data: {'code': 200});
      },
      mediaProbe: (uri, {username, password, timeout}) async {
        final count = (probeCounts[uri.toString()] ?? 0) + 1;
        probeCounts[uri.toString()] = count;
        return count.isEven;
      },
    );

    Future<OpenListRecoveryResult> recover(String token, String media) =>
        service.prepare(
          config: OpenListRecoveryConfig(
            enabled: true,
            baseUrl: 'http://host:5244',
            token: token,
          ),
          mediaUrl: media,
        );

    expect(
      (await recover('token-a', 'http://host:5244/dav/movie-a.mkv')).success,
      isTrue,
    );
    expect(
      (await recover('token-b', 'http://host:5244/dav/movie-a.mkv')).success,
      isTrue,
    );
    expect(
      (await recover('token-b', 'http://host:5244/dav/movie-b.mkv')).success,
      isTrue,
    );
    expect(loadAllRequests, 3);
  });

  test('load_all 的 401 重认证、重试和就绪检查共享递减预算', () async {
    final timeouts = <Duration>[];
    var probes = 0;
    var reloadCount = 0;
    final service = OpenListRecoveryService(
      readinessTimeout: const Duration(milliseconds: 500),
      requestSender: (uri, {required method, headers, body, timeout}) async {
        if (uri.path != '/api/public/settings') {
          timeouts.add(timeout!);
          await Future<void>.delayed(const Duration(milliseconds: 4));
        }
        if (uri.path == '/api/public/settings') {
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {'version': 'v4.2.5'},
            },
          );
        }
        if (uri.path == '/api/admin/storage/load_all') {
          reloadCount++;
          if (reloadCount == 1) {
            return const OpenListHttpResponse(
              statusCode: 401,
              data: {'code': 401, 'message': 'unauthorized'},
            );
          }
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {'code': 200},
          );
        }
        if (uri.path == '/api/auth/login') {
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {'token': 'fresh-admin-token'},
            },
          );
        }
        if (uri.path == '/api/admin/storage/list') {
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {'code': 200},
          );
        }
        return const OpenListHttpResponse(statusCode: 404);
      },
      mediaProbe: (uri, {username, password, timeout}) async {
        probes++;
        return probes >= 2;
      },
    );

    final result = await service.prepare(
      config: const OpenListRecoveryConfig(
        enabled: true,
        baseUrl: 'http://host:5244',
        token: 'stale-admin-token',
        username: 'admin',
        password: 'secret',
      ),
      mediaUrl: 'http://host:5244/dav/movie.mkv',
    );

    expect(result.success, isTrue);
    expect(reloadCount, 2);
    for (var i = 1; i < timeouts.length; i++) {
      expect(timeouts[i], lessThan(timeouts[i - 1]));
    }
  });

  test('load_all 逻辑入口受单一总墙钟限制', () async {
    final blocker = Completer<OpenListHttpResponse>();
    var loadAllRequests = 0;
    final service = OpenListRecoveryService(
      readinessTimeout: const Duration(milliseconds: 80),
      requestSender: (uri, {required method, headers, body, timeout}) async {
        if (uri.path == '/api/public/settings') {
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {'version': 'v4.2.5'},
            },
          );
        }
        if (uri.path == '/api/admin/storage/load_all') {
          loadAllRequests++;
          return blocker.future;
        }
        return const OpenListHttpResponse(statusCode: 404);
      },
      mediaProbe: (uri, {username, password, timeout}) async => false,
    );

    final watch = Stopwatch()..start();
    final result = await service.prepare(
      config: const OpenListRecoveryConfig(
        enabled: true,
        baseUrl: 'http://host:5244',
        token: 'admin-token',
      ),
      mediaUrl: 'http://host:5244/dav/movie.mkv',
    );
    watch.stop();

    expect(result.outcome, OpenListRecoveryOutcome.retryableFailure);
    expect(loadAllRequests, 1);
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 300)));
  });

  test('失败的在途刷新按非明文凭据指纹隔离', () async {
    final firstReloadStarted = Completer<void>();
    final firstReloadResponse = Completer<OpenListHttpResponse>();
    var now = DateTime.utc(2026, 8, 23);
    final reloadTokens = <String?>[];
    final service = OpenListRecoveryService(
      readinessTimeout: const Duration(seconds: 30),
      clock: () => now,
      requestSender: (uri, {required method, headers, body, timeout}) async {
        if (uri.path == '/api/public/settings') {
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {'code': 200},
          );
        }
        if (uri.path == '/api/admin/storage/load_all') {
          final token = headers?['authorization'];
          reloadTokens.add(token);
          if (token == 'token-a') {
            if (!firstReloadStarted.isCompleted) firstReloadStarted.complete();
            return firstReloadResponse.future;
          }
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {'code': 200},
          );
        }
        if (uri.path == '/api/admin/storage/list') {
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {'code': 200},
          );
        }
        return const OpenListHttpResponse(statusCode: 404);
      },
      mediaProbe: (uri, {username, password, timeout}) async {
        now = now.add(const Duration(minutes: 1));
        return false;
      },
    );
    Future<OpenListRecoveryResult> run(String token) => service.prepare(
      config: OpenListRecoveryConfig(
        enabled: true,
        baseUrl: 'http://host:5244',
        token: token,
      ),
      mediaUrl: 'http://host:5244/dav/movie.mkv',
    );

    final first = run('token-a');
    await firstReloadStarted.future;
    final second = run('token-b');
    firstReloadResponse.complete(
      const OpenListHttpResponse(
        statusCode: 401,
        data: {'code': 401, 'message': 'unauthorized'},
      ),
    );

    final results = await Future.wait([first, second]);

    expect(results.first.outcome, OpenListRecoveryOutcome.terminalFailure);
    expect(results.last.outcome, OpenListRecoveryOutcome.retryableFailure);
    expect(reloadTokens, containsAll(<String>['token-a', 'token-b']));
  });

  test('已知缺少存储恢复能力的版本不会调用 load_all', () async {
    final paths = <String>[];
    final service = OpenListRecoveryService(
      requestSender: (uri, {required method, headers, body, timeout}) async {
        paths.add(uri.path);
        return const OpenListHttpResponse(
          statusCode: 200,
          data: {
            'code': 200,
            'data': {'version': 'v3.6.0'},
          },
        );
      },
      mediaProbe: (uri, {username, password, timeout}) async => false,
    );

    final result = await service.prepare(
      config: const OpenListRecoveryConfig(
        enabled: true,
        baseUrl: 'http://host:5244',
        token: 'admin-token',
      ),
      mediaUrl: 'http://host:5244/dav/movie.mkv',
    );

    expect(result.outcome, OpenListRecoveryOutcome.terminalFailure);
    expect(result.message, contains('/api/admin/storage/load_all'));
    expect(paths, ['/api/public/settings']);
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

      expect(result.outcome, OpenListRecoveryOutcome.retryableFailure);
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
    expect(result.outcome, OpenListRecoveryOutcome.terminalFailure);
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

    expect(result.outcome, OpenListRecoveryOutcome.retryableFailure);
    expect(result.success, isFalse);
    expect(result.retryable, isTrue);
    expect(result.storageReloaded, isFalse);
    expect(result.message, contains('请求异常'));
  });
}
