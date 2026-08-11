import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../data/models/openlist_recovery_config.dart';

const _alistLoginHashSuffix = '-https://github.com/alist-org/alist';
const _maxRedirects = 5;

/// OpenList / AList 后台请求结果。独立于 Dio，便于覆盖不同版本返回格式
/// 并在测试中注入协议桩。
class OpenListHttpResponse {
  const OpenListHttpResponse({required this.statusCode, this.data});

  final int? statusCode;
  final Object? data;
}

typedef OpenListRequestSender =
    Future<OpenListHttpResponse> Function(
      Uri uri, {
      required String method,
      Map<String, String>? headers,
      Object? body,
      Duration? timeout,
    });

typedef OpenListMediaProbe =
    Future<bool> Function(
      Uri mediaUri, {
      String? username,
      String? password,
      Duration? timeout,
    });

/// 自动恢复前的后台准备结果。
class OpenListRecoveryResult {
  const OpenListRecoveryResult({
    required this.success,
    required this.storageReloaded,
    required this.message,
    this.serverVersion,
  });

  final bool success;
  final bool storageReloaded;
  final String message;
  final String? serverVersion;
}

/// 播放链接恢复提供者，供播放器服务注入测试替身。
abstract interface class PlaybackLinkRecoveryProvider {
  Future<OpenListRecoveryResult> prepare({
    required OpenListRecoveryConfig config,
    required String mediaUrl,
    String? webDavUsername,
    String? webDavPassword,
    bool forceStorageReload = false,
  });
}

/// OpenList v4 / AList v3 播放链接恢复兼容层。
///
/// 兼容策略：
/// 1. 不按版本号硬编码功能，而是探测公开设置和实际 API 能力；
/// 2. 优先使用通用 `/api/auth/login`，端点不存在时回退
///    `/api/auth/login/hash`；
/// 3. 存储刷新使用两个项目共同支持的
///    `/api/admin/storage/load_all`；
/// 4. 刷新接口异步返回，随后等待管理员存储列表和真实媒体 Range 探测；
/// 5. 同一后台的并发刷新合并，成功刷新后进入冷却期，避免双会话反复
///    卸载全部存储。
class OpenListRecoveryService implements PlaybackLinkRecoveryProvider {
  OpenListRecoveryService({
    Dio? dio,
    OpenListRequestSender? requestSender,
    OpenListMediaProbe? mediaProbe,
    DateTime Function()? clock,
    this.refreshCooldown = const Duration(minutes: 5),
    this.readinessTimeout = const Duration(seconds: 30),
  }) : _dio = dio ?? Dio(),
       _requestSender = requestSender, // ignore: prefer_initializing_formals
       _mediaProbe = mediaProbe, // ignore: prefer_initializing_formals
       _clock = clock ?? DateTime.now;

  final Dio _dio;
  final OpenListRequestSender? _requestSender;
  final OpenListMediaProbe? _mediaProbe;
  final DateTime Function() _clock;
  final Duration refreshCooldown;
  final Duration readinessTimeout;

  final Map<String, Future<OpenListRecoveryResult>> _inflightReloads = {};
  final Map<String, DateTime> _lastSuccessfulReloads = {};

  @override
  Future<OpenListRecoveryResult> prepare({
    required OpenListRecoveryConfig config,
    required String mediaUrl,
    String? webDavUsername,
    String? webDavPassword,
    bool forceStorageReload = false,
  }) async {
    try {
      return await _prepare(
        config: config,
        mediaUrl: mediaUrl,
        webDavUsername: webDavUsername,
        webDavPassword: webDavPassword,
        forceStorageReload: forceStorageReload,
      );
    } catch (_) {
      // 后台返回了非预期内容、连接器抛出异常或系统网络栈失败时，恢复
      // 功能必须收敛为可展示的失败结果，不能让播放器退出监听链中断。
      return const OpenListRecoveryResult(
        success: false,
        storageReloaded: false,
        message: 'OpenList/AList 自动恢复请求异常，请检查后台地址和网络连接',
      );
    }
  }

  Future<OpenListRecoveryResult> _prepare({
    required OpenListRecoveryConfig config,
    required String mediaUrl,
    String? webDavUsername,
    String? webDavPassword,
    bool forceStorageReload = false,
  }) async {
    if (!config.enabled) {
      return const OpenListRecoveryResult(
        success: false,
        storageReloaded: false,
        message: 'OpenList/AList 自动恢复未启用',
      );
    }
    if (!config.hasCredentials) {
      return const OpenListRecoveryResult(
        success: false,
        storageReloaded: false,
        message: '未配置 OpenList/AList 管理员账号、密码或 Token',
      );
    }

    final baseUri = normalizeBaseUri(config.baseUrl);
    final mediaUri = Uri.tryParse(mediaUrl);
    if (baseUri == null || mediaUri == null || !mediaUri.hasScheme) {
      return const OpenListRecoveryResult(
        success: false,
        storageReloaded: false,
        message: 'OpenList/AList 后台地址或媒体地址无效',
      );
    }

    final version = await _detectVersion(baseUri);
    final probe = _mediaProbe ?? _probeMediaUrl;
    final mediaAvailable = await _safeProbe(
      probe,
      mediaUri,
      username: webDavUsername,
      password: webDavPassword,
    );
    if (mediaAvailable && !forceStorageReload) {
      return OpenListRecoveryResult(
        success: true,
        storageReloaded: false,
        serverVersion: version,
        message: '原 WebDAV 地址已可重新取链，无需刷新全部存储',
      );
    }

    final key = baseUri.toString();
    final lastReload = _lastSuccessfulReloads[key];
    if (lastReload != null &&
        _clock().difference(lastReload) < refreshCooldown) {
      final becameAvailable = await _waitForMedia(
        probe,
        mediaUri,
        username: webDavUsername,
        password: webDavPassword,
        timeout: const Duration(seconds: 8),
      );
      return OpenListRecoveryResult(
        success: becameAvailable,
        storageReloaded: false,
        serverVersion: version,
        message: becameAvailable
            ? '后台近期已刷新，媒体地址现已恢复'
            : '后台近期已刷新但媒体仍不可用，为避免频繁重载已停止自动重试',
      );
    }

    final existing = _inflightReloads[key];
    if (existing != null) {
      final shared = await existing;
      if (!shared.success) return shared;
      final ready = await _waitForMedia(
        probe,
        mediaUri,
        username: webDavUsername,
        password: webDavPassword,
        timeout: readinessTimeout,
      );
      return OpenListRecoveryResult(
        success: ready,
        storageReloaded: shared.storageReloaded,
        serverVersion: shared.serverVersion ?? version,
        message: ready ? '共享的后台刷新已完成，媒体地址恢复' : '后台刷新完成，但媒体地址仍不可用',
      );
    }

    final future = _reloadStorage(baseUri, config, version);
    _inflightReloads[key] = future;
    OpenListRecoveryResult reloaded;
    try {
      reloaded = await future;
    } finally {
      if (identical(_inflightReloads[key], future)) {
        _inflightReloads.remove(key);
      }
    }
    if (!reloaded.success) return reloaded;
    _lastSuccessfulReloads[key] = _clock();

    final ready = await _waitForMedia(
      probe,
      mediaUri,
      username: webDavUsername,
      password: webDavPassword,
      timeout: readinessTimeout,
    );
    return OpenListRecoveryResult(
      success: ready,
      storageReloaded: true,
      serverVersion: reloaded.serverVersion ?? version,
      message: ready ? '后台存储刷新完成，媒体地址已恢复' : '后台存储已刷新，但媒体地址在等待期限内仍不可用',
    );
  }

  /// 规范化用户输入，兼容站点根地址、反向代理子路径以及误填的 `/dav`。
  static Uri? normalizeBaseUri(String value) {
    final raw = value.trim();
    if (raw.isEmpty) return null;
    final parsed = Uri.tryParse(raw);
    if (parsed == null ||
        (parsed.scheme != 'http' && parsed.scheme != 'https') ||
        parsed.host.isEmpty) {
      return null;
    }
    final segments = parsed.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isNotEmpty &&
        (segments.last.toLowerCase() == 'dav' ||
            segments.last.toLowerCase() == 'api')) {
      segments.removeLast();
    }
    final path = segments.isEmpty ? '' : '/${segments.join('/')}';
    return parsed.replace(path: path, query: null, fragment: null);
  }

  Uri _apiUri(Uri base, String endpoint) {
    final prefix = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(path: '$prefix$endpoint', query: null, fragment: null);
  }

  Future<String?> _detectVersion(Uri baseUri) async {
    try {
      final response = await _request(
        _apiUri(baseUri, '/api/public/settings'),
        method: 'GET',
        timeout: const Duration(seconds: 5),
      );
      final envelope = _asMap(response.data);
      final data = _asMap(envelope?['data']);
      final version = data?['version'] ?? envelope?['version'];
      final text = version?.toString().trim();
      return text == null || text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  Future<OpenListRecoveryResult> _reloadStorage(
    Uri baseUri,
    OpenListRecoveryConfig config,
    String? version,
  ) async {
    var token = config.token.trim();
    if (token.isEmpty) {
      final login = await _login(baseUri, config);
      if (login.token == null) {
        return OpenListRecoveryResult(
          success: false,
          storageReloaded: false,
          serverVersion: version,
          message: login.message,
        );
      }
      token = login.token!;
    }

    var response = await _postReload(baseUri, token);
    if (_isUnauthorized(response) &&
        config.username.trim().isNotEmpty &&
        config.password.isNotEmpty) {
      final login = await _login(baseUri, config);
      if (login.token == null) {
        return OpenListRecoveryResult(
          success: false,
          storageReloaded: false,
          serverVersion: version,
          message: login.message,
        );
      }
      token = login.token!;
      response = await _postReload(baseUri, token);
    }
    if (!_isApiSuccess(response)) {
      return OpenListRecoveryResult(
        success: false,
        storageReloaded: false,
        serverVersion: version,
        message: 'OpenList/AList 存储刷新失败：${_apiMessage(response)}',
      );
    }

    // load_all 在 OpenList v4 / AList v3 中均为异步处理。管理员列表请求
    // 会经过存储加载中间件；等待它成功返回，不能把 load_all 的立即响应
    // 误认为刷新已经完成。
    final ready = await _waitForAdminReady(baseUri, token);
    return OpenListRecoveryResult(
      success: ready,
      storageReloaded: ready,
      serverVersion: version,
      message: ready ? 'OpenList/AList 全部启用存储已重新加载' : '后台接受了刷新请求，但存储未在等待期限内恢复',
    );
  }

  Future<_LoginResult> _login(
    Uri baseUri,
    OpenListRecoveryConfig config,
  ) async {
    final username = config.username.trim();
    if (username.isEmpty || config.password.isEmpty) {
      return const _LoginResult(message: '管理员 Token 无效，且未提供可回退登录的账号密码');
    }

    final plain = await _request(
      _apiUri(baseUri, '/api/auth/login'),
      method: 'POST',
      body: <String, Object?>{
        'username': username,
        'password': config.password,
      },
      timeout: const Duration(seconds: 10),
    );
    var token = _tokenFrom(plain);
    if (token != null) return _LoginResult(token: token, message: '登录成功');

    // 部分版本仅保留 login/hash；兼容 HTTP 状态和 JSON code 两种返回。
    final plainCode = _apiCode(plain);
    if (plain.statusCode == 404 ||
        plain.statusCode == 405 ||
        plainCode == 404 ||
        plainCode == 405) {
      final hashed = await _request(
        _apiUri(baseUri, '/api/auth/login/hash'),
        method: 'POST',
        body: <String, Object?>{
          'username': username,
          'password': sha256
              .convert(utf8.encode('${config.password}$_alistLoginHashSuffix'))
              .toString(),
        },
        timeout: const Duration(seconds: 10),
      );
      token = _tokenFrom(hashed);
      if (token != null) return _LoginResult(token: token, message: '登录成功');
      return _LoginResult(message: '管理员登录失败：${_apiMessage(hashed)}');
    }

    final message = _apiMessage(plain);
    final twoFactor =
        plain.statusCode == 402 || message.toLowerCase().contains('2fa');
    return _LoginResult(
      message: twoFactor ? '管理员账号启用了 2FA，请在设置中填写管理员 Token' : '管理员登录失败：$message',
    );
  }

  Future<OpenListHttpResponse> _postReload(Uri baseUri, String token) =>
      _request(
        _apiUri(baseUri, '/api/admin/storage/load_all'),
        method: 'POST',
        headers: <String, String>{HttpHeaders.authorizationHeader: token},
        timeout: const Duration(seconds: 15),
      );

  Future<bool> _waitForAdminReady(Uri baseUri, String token) async {
    final deadline = _clock().add(readinessTimeout);
    while (_clock().isBefore(deadline)) {
      try {
        final response = await _request(
          _apiUri(baseUri, '/api/admin/storage/list'),
          method: 'GET',
          headers: <String, String>{HttpHeaders.authorizationHeader: token},
          timeout: const Duration(seconds: 8),
        );
        if (_isApiSuccess(response)) return true;
        if (_isUnauthorized(response)) return false;
      } catch (_) {
        // 后台尚在卸载/重建存储时保留重试。
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    return false;
  }

  Future<bool> _waitForMedia(
    OpenListMediaProbe probe,
    Uri mediaUri, {
    String? username,
    String? password,
    required Duration timeout,
  }) async {
    final deadline = _clock().add(timeout);
    while (_clock().isBefore(deadline)) {
      if (await _safeProbe(
        probe,
        mediaUri,
        username: username,
        password: password,
      )) {
        return true;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    return false;
  }

  Future<bool> _safeProbe(
    OpenListMediaProbe probe,
    Uri mediaUri, {
    String? username,
    String? password,
  }) async {
    try {
      return await probe(
        mediaUri,
        username: username,
        password: password,
        timeout: const Duration(seconds: 8),
      );
    } catch (_) {
      return false;
    }
  }

  Future<OpenListHttpResponse> _request(
    Uri uri, {
    required String method,
    Map<String, String>? headers,
    Object? body,
    Duration? timeout,
  }) async {
    final sender = _requestSender;
    if (sender != null) {
      return sender(
        uri,
        method: method,
        headers: headers,
        body: body,
        timeout: timeout,
      );
    }
    try {
      var current = uri;
      for (var redirects = 0; redirects <= _maxRedirects; redirects++) {
        final response = await _dio.request<Object?>(
          current.toString(),
          data: body,
          options: Options(
            method: method,
            headers: <String, Object?>{
              HttpHeaders.contentTypeHeader: 'application/json',
              ...?headers,
            },
            responseType: ResponseType.plain,
            followRedirects: false,
            validateStatus: (_) => true,
            sendTimeout: timeout,
            receiveTimeout: timeout,
          ),
        );
        final status = response.statusCode;
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (status == null ||
            status < 300 ||
            status >= 400 ||
            location == null) {
          return OpenListHttpResponse(statusCode: status, data: response.data);
        }

        final next = current.resolve(location);
        if (!_sameOrigin(next, uri)) {
          return OpenListHttpResponse(
            statusCode: status,
            data: '拒绝将 OpenList/AList 管理员请求重定向到其他来源',
          );
        }
        current = next;
      }
      return const OpenListHttpResponse(
        statusCode: 310,
        data: 'OpenList/AList 管理员请求重定向次数过多',
      );
    } on DioException catch (error) {
      return OpenListHttpResponse(
        statusCode: error.response?.statusCode,
        data: error.response?.data ?? error.message,
      );
    }
  }

  /// 真实媒体探测手动处理重定向：Basic 凭据只发送给原 WebDAV 来源，
  /// 跳转到网盘厂商签名域名后立即移除，避免后台账号或 WebDAV 密码泄漏。
  Future<bool> _probeMediaUrl(
    Uri mediaUri, {
    String? username,
    String? password,
    Duration? timeout,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    var current = mediaUri;
    try {
      for (var redirects = 0; redirects <= 5; redirects++) {
        final request = await client
            .getUrl(current)
            .timeout(timeout ?? const Duration(seconds: 8));
        request.followRedirects = false;
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
        if (_sameOrigin(current, mediaUri) &&
            username != null &&
            username.isNotEmpty) {
          final basic = base64Encode(
            utf8.encode('$username:${password ?? ''}'),
          );
          request.headers.set(HttpHeaders.authorizationHeader, 'Basic $basic');
        }
        final response = await request.close().timeout(
          timeout ?? const Duration(seconds: 8),
        );
        final status = response.statusCode;
        final location = response.headers.value(HttpHeaders.locationHeader);
        await _abortResponse(response);
        if (status >= 200 && status < 300) return true;
        if (status >= 300 && status < 400 && location != null) {
          current = current.resolve(location);
          continue;
        }
        return false;
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _abortResponse(HttpClientResponse response) async {
    try {
      final socket = await response.detachSocket();
      socket.destroy();
    } catch (_) {
      final subscription = response.listen((_) {});
      await subscription.cancel();
    }
  }

  bool _sameOrigin(Uri a, Uri b) =>
      a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
      a.host.toLowerCase() == b.host.toLowerCase() &&
      a.port == b.port;

  Map<String, dynamic>? _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    if (value is String) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return null;
  }

  bool _isApiSuccess(OpenListHttpResponse response) {
    final httpOk =
        response.statusCode != null &&
        response.statusCode! >= 200 &&
        response.statusCode! < 300;
    if (!httpOk) return false;
    final map = _asMap(response.data);
    if (map == null || !map.containsKey('code')) return true;
    final code = int.tryParse(map['code'].toString());
    return code == 200;
  }

  bool _isUnauthorized(OpenListHttpResponse response) {
    if (response.statusCode == 401 || response.statusCode == 403) return true;
    final code = _apiCode(response);
    return code == 401 || code == 403;
  }

  int? _apiCode(OpenListHttpResponse response) =>
      int.tryParse(_asMap(response.data)?['code']?.toString() ?? '');

  String? _tokenFrom(OpenListHttpResponse response) {
    if (!_isApiSuccess(response)) return null;
    final data = _asMap(_asMap(response.data)?['data']);
    final token = data?['token']?.toString().trim();
    return token == null || token.isEmpty ? null : token;
  }

  String _apiMessage(OpenListHttpResponse response) {
    final map = _asMap(response.data);
    final message = map?['message']?.toString().trim();
    if (message != null && message.isNotEmpty) return message;
    if (response.data is String &&
        (response.data as String).trim().isNotEmpty) {
      return (response.data as String).trim();
    }
    return response.statusCode == null
        ? '无法连接服务器'
        : 'HTTP ${response.statusCode}';
  }
}

class _LoginResult {
  const _LoginResult({this.token, required this.message});

  final String? token;
  final String message;
}
