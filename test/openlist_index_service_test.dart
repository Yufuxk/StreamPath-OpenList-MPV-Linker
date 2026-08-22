import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/openlist_index_config.dart';
import 'package:streampath/data/models/openlist_recovery_config.dart';
import 'package:streampath/data/models/server_profile.dart';
import 'package:streampath/domain/services/openlist_index_service.dart';
import 'package:streampath/domain/services/openlist_recovery_service.dart';

void main() {
  ServerProfile profile({
    OpenListIndexConfig index = const OpenListIndexConfig(),
    OpenListRecoveryConfig recovery = const OpenListRecoveryConfig(
      baseUrl: 'https://openlist.test',
      token: 'admin-token',
    ),
  }) => ServerProfile(
    profileId: 'profile-1',
    name: '测试服务器',
    serverUrl: 'https://openlist.test/dav',
    username: 'alice',
    password: 'user-password',
    openListRecovery: recovery,
    openListIndex: index,
  );

  test('索引配置默认关闭，并在模型层钳制最短五分钟', () {
    expect(const OpenListIndexConfig().autoUpdateEnabled, isFalse);
    expect(
      OpenListIndexConfig.fromJson(const {
        'autoUpdateEnabled': true,
        'updateIntervalMinutes': 1,
      }).updateIntervalMinutes,
      OpenListIndexConfig.minUpdateIntervalMinutes,
    );
  });

  test('索引条目只提取直接父文件夹名称', () {
    const nested = OpenListIndexEntry(
      name: '电影.mkv',
      parent: '影视/电影',
      isDirectory: false,
    );
    const root = OpenListIndexEntry(
      name: '根目录文件.mkv',
      parent: '',
      isDirectory: false,
    );

    expect(nested.parentFolderName, '电影');
    expect(root.parentFolderName, '/');
  });

  test('索引搜索使用普通用户身份并剥离用户根路径', () async {
    final requests =
        <({Uri uri, Object? body, Map<String, String>? headers})>[];
    final service = OpenListIndexService(
      requestSender: (uri, {required method, headers, body, timeout}) async {
        requests.add((uri: uri, body: body, headers: headers));
        return switch (uri.path) {
          '/api/auth/login' => const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {'token': 'user-token'},
            },
          ),
          '/api/me' => const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {'base_path': '/users/alice'},
            },
          ),
          '/api/fs/search' => const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {
                'content': [
                  {
                    'name': '电影.mkv',
                    'parent': '/users/alice/影视',
                    'is_dir': false,
                    'size': 42,
                  },
                  {'name': '越权.mkv', 'parent': '/users/bob', 'is_dir': false},
                ],
              },
            },
          ),
          _ => const OpenListHttpResponse(statusCode: 404),
        };
      },
    );

    final results = await service.search(profile: profile(), query: '电影');

    expect(results, hasLength(1));
    expect(results.single.parent, '影视');
    expect(results.single.parentFolderName, '影视');
    expect(results.single.path, '影视/电影.mkv');
    expect(
      requests
          .firstWhere((request) => request.uri.path == '/api/auth/login')
          .body,
      {'username': 'alice', 'password': 'user-password'},
    );
    expect(requests.last.headers?['authorization'], 'user-token');
  });

  test('更新前检查运行状态并沿用服务端最大索引深度', () async {
    Object? updateBody;
    final service = OpenListIndexService(
      requestSender: (uri, {required method, headers, body, timeout}) async {
        if (uri.path == '/api/admin/index/progress') {
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {'is_done': true},
            },
          );
        }
        if (uri.path == '/api/admin/setting/get') {
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {'value': '33'},
            },
          );
        }
        if (uri.path == '/api/admin/index/update') {
          updateBody = body;
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {'code': 200},
          );
        }
        return const OpenListHttpResponse(statusCode: 404);
      },
    );

    final result = await service.updateIndex(profile());

    expect(result.accepted, isTrue);
    expect(updateBody, {
      'paths': ['/'],
      'max_depth': 33,
    });
  });

  for (final invalidSetting in <Object?>[
    const OpenListHttpResponse(statusCode: 404),
    const OpenListHttpResponse(
      statusCode: 200,
      data: {'code': 500, 'message': 'failed'},
    ),
    const OpenListHttpResponse(
      statusCode: 200,
      data: {
        'code': 200,
        'data': {'value': 'not-a-number'},
      },
    ),
  ]) {
    test('最大索引深度读取失败时禁止提交 update：$invalidSetting', () async {
      var updateRequests = 0;
      final service = OpenListIndexService(
        requestSender: (uri, {required method, headers, body, timeout}) async {
          if (uri.path == '/api/admin/index/progress') {
            return const OpenListHttpResponse(
              statusCode: 200,
              data: {
                'code': 200,
                'data': {'is_done': true},
              },
            );
          }
          if (uri.path == '/api/admin/setting/get') {
            return invalidSetting as OpenListHttpResponse;
          }
          if (uri.path == '/api/admin/index/update') {
            updateRequests++;
            return const OpenListHttpResponse(
              statusCode: 200,
              data: {'code': 200},
            );
          }
          return const OpenListHttpResponse(statusCode: 404);
        },
      );

      final result = await service.updateIndex(profile());

      expect(result.accepted, isFalse);
      expect(result.message, contains('最大索引深度'));
      expect(updateRequests, 0);
    });
  }

  for (final depth in const [-1, 5000]) {
    test('最大索引深度 $depth 原值提交且不做无依据截断', () async {
      Object? updateBody;
      final service = OpenListIndexService(
        requestSender: (uri, {required method, headers, body, timeout}) async {
          if (uri.path == '/api/admin/index/progress') {
            return const OpenListHttpResponse(
              statusCode: 200,
              data: {
                'code': 200,
                'data': {'is_done': true},
              },
            );
          }
          if (uri.path == '/api/admin/setting/get') {
            return OpenListHttpResponse(
              statusCode: 200,
              data: {
                'code': 200,
                'data': {'value': '$depth'},
              },
            );
          }
          if (uri.path == '/api/admin/index/update') {
            updateBody = body;
            return const OpenListHttpResponse(
              statusCode: 200,
              data: {'code': 200},
            );
          }
          return const OpenListHttpResponse(statusCode: 404);
        },
      );

      final result = await service.updateIndex(profile());

      expect(result.accepted, isTrue);
      expect(updateBody, {
        'paths': ['/'],
        'max_depth': depth,
      });
    });
  }

  test('索引搜索优先使用独立普通用户 Token，不执行密码登录', () async {
    final paths = <String>[];
    final service = OpenListIndexService(
      requestSender: (uri, {required method, headers, body, timeout}) async {
        paths.add(uri.path);
        if (uri.path == '/api/me') {
          expect(headers?['authorization'], 'least-privilege-user-token');
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {'base_path': '/'},
            },
          );
        }
        if (uri.path == '/api/fs/search') {
          expect(headers?['authorization'], 'least-privilege-user-token');
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {'content': <Object>[]},
            },
          );
        }
        return const OpenListHttpResponse(statusCode: 500);
      },
    );
    final target = profile(
      index: const OpenListIndexConfig(userToken: 'least-privilege-user-token'),
    );

    await service.search(profile: target, query: '电影');

    expect(paths, ['/api/public/settings', '/api/me', '/api/fs/search']);
    expect(paths, isNot(contains('/api/auth/login')));
  });

  test('普通用户登录返回 code 402 时给出独立 Token 与 2FA 指引', () async {
    final service = OpenListIndexService(
      requestSender: (uri, {required method, headers, body, timeout}) async {
        if (uri.path == '/api/auth/login') {
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {'code': 402, 'message': '2FA required'},
          );
        }
        return const OpenListHttpResponse(statusCode: 404);
      },
    );

    await expectLater(
      service.search(profile: profile(), query: '电影'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message.toString(),
          'message',
          allOf(contains('2FA'), contains('普通用户 Token')),
        ),
      ),
    );
  });

  test('已知缺少更新能力的版本禁用 update 且不回退全量构建', () async {
    final paths = <String>[];
    final service = OpenListIndexService(
      requestSender: (uri, {required method, headers, body, timeout}) async {
        paths.add(uri.path);
        if (uri.path == '/api/public/settings') {
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {'version': 'v3.6.0'},
            },
          );
        }
        return const OpenListHttpResponse(statusCode: 200, data: {'code': 200});
      },
    );

    final result = await service.updateIndex(profile());

    expect(result.accepted, isFalse);
    expect(
      result.message,
      allOf(contains('/api/admin/index/update'), contains('不会回退')),
    );
    expect(paths, ['/api/public/settings']);
  });

  test('已知缺少搜索能力的版本在登录前失败关闭', () async {
    final paths = <String>[];
    final service = OpenListIndexService(
      requestSender: (uri, {required method, headers, body, timeout}) async {
        paths.add(uri.path);
        return const OpenListHttpResponse(
          statusCode: 200,
          data: {
            'code': 200,
            'data': {'version': 'v3.0.1'},
          },
        );
      },
    );

    await expectLater(
      service.search(profile: profile(), query: '电影'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message.toString(),
          'message',
          contains('/api/fs/search'),
        ),
      ),
    );
    expect(paths, ['/api/public/settings']);
  });

  test('进度查询解析条目数和完成时间，并复用管理员登录 Token', () async {
    var loginCount = 0;
    var progressCount = 0;
    final service = OpenListIndexService(
      requestSender: (uri, {required method, headers, body, timeout}) async {
        if (uri.path == '/api/auth/login') {
          loginCount++;
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {'token': 'admin-session'},
            },
          );
        }
        if (uri.path == '/api/admin/index/progress') {
          progressCount++;
          expect(headers?['authorization'], 'admin-session');
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {
                'obj_count': 321,
                'is_done': false,
                'last_done_time': '2026-08-22T08:09:10Z',
                'error': '',
              },
            },
          );
        }
        return const OpenListHttpResponse(statusCode: 404);
      },
    );
    final target = profile(
      recovery: const OpenListRecoveryConfig(
        baseUrl: 'https://openlist.test',
        username: 'admin',
        password: 'secret',
      ),
    );

    final first = await service.getIndexProgress(target);
    final second = await service.getIndexProgress(target);

    expect(first.objectCount, 321);
    expect(first.isDone, isFalse);
    expect(first.lastDoneTime, DateTime.utc(2026, 8, 22, 8, 9, 10));
    expect(second.objectCount, 321);
    expect(loginCount, 1);
    expect(progressCount, 2);
  });

  test('搜索的登录、me、401 重认证与重试共享递减预算', () async {
    final timeouts = <Duration>[];
    var loginCount = 0;
    var searchCount = 0;
    final service = OpenListIndexService(
      requestSender: (uri, {required method, headers, body, timeout}) async {
        timeouts.add(timeout!);
        await Future<void>.delayed(const Duration(milliseconds: 4));
        if (uri.path == '/api/public/settings') {
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {'version': 'v4.2.5'},
            },
          );
        }
        if (uri.path == '/api/auth/login') {
          loginCount++;
          return OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {'token': 'user-token-$loginCount'},
            },
          );
        }
        if (uri.path == '/api/me') {
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {'base_path': '/'},
            },
          );
        }
        if (uri.path == '/api/fs/search') {
          searchCount++;
          if (searchCount == 1) {
            return const OpenListHttpResponse(
              statusCode: 401,
              data: {'code': 401, 'message': 'unauthorized'},
            );
          }
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {'content': <Object>[]},
            },
          );
        }
        return const OpenListHttpResponse(statusCode: 404);
      },
    );

    await service.search(profile: profile(), query: '电影');

    expect(loginCount, 2);
    expect(searchCount, 2);
    for (var i = 1; i < timeouts.length; i++) {
      expect(timeouts[i], lessThan(timeouts[i - 1]));
    }
  });

  test('进度查询的 401 重认证和重试共享递减预算', () async {
    final timeouts = <Duration>[];
    var loginCount = 0;
    var progressCount = 0;
    final service = OpenListIndexService(
      requestSender: (uri, {required method, headers, body, timeout}) async {
        timeouts.add(timeout!);
        await Future<void>.delayed(const Duration(milliseconds: 4));
        if (uri.path == '/api/public/settings') {
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {'version': 'v4.2.5'},
            },
          );
        }
        if (uri.path == '/api/auth/login') {
          loginCount++;
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {'token': 'fresh-admin-token'},
            },
          );
        }
        if (uri.path == '/api/admin/index/progress') {
          progressCount++;
          if (progressCount == 1) {
            return const OpenListHttpResponse(
              statusCode: 401,
              data: {'code': 401, 'message': 'unauthorized'},
            );
          }
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {'is_done': true},
            },
          );
        }
        return const OpenListHttpResponse(statusCode: 404);
      },
    );
    final target = profile(
      recovery: const OpenListRecoveryConfig(
        baseUrl: 'https://openlist.test',
        token: 'stale-admin-token',
        username: 'admin',
        password: 'secret',
      ),
    );

    await service.getIndexProgress(target);

    expect(loginCount, 1);
    expect(progressCount, 2);
    for (var i = 1; i < timeouts.length; i++) {
      expect(timeouts[i], lessThan(timeouts[i - 1]));
    }
  });

  test('索引更新的状态、重认证、设置与提交共享递减预算', () async {
    final timeouts = <Duration>[];
    var progressCount = 0;
    final service = OpenListIndexService(
      requestSender: (uri, {required method, headers, body, timeout}) async {
        timeouts.add(timeout!);
        await Future<void>.delayed(const Duration(milliseconds: 4));
        if (uri.path == '/api/public/settings') {
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {'version': 'v4.2.5'},
            },
          );
        }
        if (uri.path == '/api/admin/index/progress') {
          progressCount++;
          if (progressCount == 1) {
            return const OpenListHttpResponse(
              statusCode: 401,
              data: {'code': 401, 'message': 'unauthorized'},
            );
          }
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {'is_done': true},
            },
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
        if (uri.path == '/api/admin/setting/get') {
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {'value': '-1'},
            },
          );
        }
        if (uri.path == '/api/admin/index/update') {
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {'code': 200},
          );
        }
        return const OpenListHttpResponse(statusCode: 404);
      },
    );
    final target = profile(
      recovery: const OpenListRecoveryConfig(
        baseUrl: 'https://openlist.test',
        token: 'stale-admin-token',
        username: 'admin',
        password: 'secret',
      ),
    );

    final result = await service.updateIndex(target);

    expect(result.accepted, isTrue);
    expect(progressCount, 2);
    for (var i = 1; i < timeouts.length; i++) {
      expect(timeouts[i], lessThan(timeouts[i - 1]));
    }
  });

  test('三个索引逻辑入口均受单一总墙钟限制', () async {
    Future<OpenListIndexService> blockedService(
      Completer<OpenListHttpResponse> blocker,
      void Function() onRequest,
    ) async => OpenListIndexService(
      operationTimeout: const Duration(milliseconds: 80),
      requestSender: (uri, {required method, headers, body, timeout}) {
        onRequest();
        return blocker.future;
      },
    );

    final searchBlocker = Completer<OpenListHttpResponse>();
    var searchRequests = 0;
    final searchService = await blockedService(
      searchBlocker,
      () => searchRequests++,
    );
    final searchWatch = Stopwatch()..start();
    await expectLater(
      searchService.search(profile: profile(), query: '电影'),
      throwsA(isA<FormatException>()),
    );
    searchWatch.stop();
    expect(searchRequests, 1);
    expect(searchWatch.elapsed, lessThan(const Duration(milliseconds: 300)));

    final progressBlocker = Completer<OpenListHttpResponse>();
    var progressRequests = 0;
    final progressService = await blockedService(
      progressBlocker,
      () => progressRequests++,
    );
    final progressWatch = Stopwatch()..start();
    await expectLater(
      progressService.getIndexProgress(profile()),
      throwsA(isA<FormatException>()),
    );
    progressWatch.stop();
    expect(progressRequests, 1);
    expect(progressWatch.elapsed, lessThan(const Duration(milliseconds: 300)));

    final updateBlocker = Completer<OpenListHttpResponse>();
    var updateRequests = 0;
    final updateService = await blockedService(
      updateBlocker,
      () => updateRequests++,
    );
    final updateWatch = Stopwatch()..start();
    final update = await updateService.updateIndex(profile());
    updateWatch.stop();
    expect(update.accepted, isFalse);
    expect(updateRequests, 1);
    expect(updateWatch.elapsed, lessThan(const Duration(milliseconds: 300)));
  });

  test('调度器不会立即更新，且运行时仍强制最短五分钟', () {
    Duration? scheduledDuration;
    var requestCount = 0;
    final service = OpenListIndexService(
      requestSender: (uri, {required method, headers, body, timeout}) async {
        requestCount++;
        return const OpenListHttpResponse(statusCode: 500);
      },
    );
    final timers = <Timer>[];
    final scheduler = OpenListIndexUpdateScheduler(
      service: service,
      timerFactory: (duration, callback) {
        scheduledDuration = duration;
        final timer = Timer(const Duration(days: 1), callback);
        timers.add(timer);
        return timer;
      },
    );
    addTearDown(() {
      scheduler.dispose();
      for (final timer in timers) {
        timer.cancel();
      }
    });

    scheduler.configure(
      profile(
        index: const OpenListIndexConfig(
          autoUpdateEnabled: true,
          updateIntervalMinutes: 1,
        ),
      ),
    );

    expect(scheduledDuration, const Duration(minutes: 5));
    expect(requestCount, 0);
  });
}
