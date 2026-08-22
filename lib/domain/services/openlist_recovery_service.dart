import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../data/models/openlist_recovery_config.dart';
import 'openlist_api_client.dart';

export 'openlist_api_client.dart'
    show OpenListHttpResponse, OpenListRequestSender;

typedef OpenListMediaProbe =
    Future<bool> Function(
      Uri mediaUri, {
      String? username,
      String? password,
      Duration? timeout,
    });

/// 自动恢复准备的后续处置语义。
enum OpenListRecoveryOutcome {
  ready,
  retryableFailure,
  terminalNotLinkFailure,
  terminalFailure,
}

/// 自动恢复前的后台准备结果。
class OpenListRecoveryResult {
  const OpenListRecoveryResult({
    required this.outcome,
    required this.storageReloaded,
    required this.message,
    this.serverVersion,
  });

  final OpenListRecoveryOutcome outcome;
  final bool storageReloaded;
  final String message;
  final String? serverVersion;

  bool get success => outcome == OpenListRecoveryOutcome.ready;
  bool get retryable => outcome == OpenListRecoveryOutcome.retryableFailure;
  bool get terminal => !success && !retryable;
}

/// 播放链接恢复提供者，供播放器服务注入测试替身。
abstract interface class PlaybackLinkRecoveryProvider {
  Future<OpenListRecoveryResult> prepare({
    required OpenListRecoveryConfig config,
    required String mediaUrl,
    String? webDavUsername,
    String? webDavPassword,
    bool forceStorageReload = false,
    bool serverRestarted = false,
  });
}

/// OpenList v4 / AList v3 播放链接恢复兼容层。
///
/// 兼容策略：
/// 1. 对已核验版本使用能力矩阵，对未知版本保持 unknown 并以实际端点响应收窄；
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
    OpenListApiClient? apiClient,
    OpenListMediaProbe? mediaProbe,
    DateTime Function()? clock,
    this.refreshCooldown = const Duration(minutes: 5),
    this.readinessTimeout = const Duration(seconds: 30),
  }) : _api =
           apiClient ??
           OpenListApiClient(
             dio: dio,
             requestSender: requestSender,
           ),
       _mediaProbe = mediaProbe, // ignore: prefer_initializing_formals
       _clock = clock ?? DateTime.now;

  final OpenListApiClient _api;
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
    bool serverRestarted = false,
  }) async {
    try {
      return await _prepare(
        config: config,
        mediaUrl: mediaUrl,
        webDavUsername: webDavUsername,
        webDavPassword: webDavPassword,
        forceStorageReload: forceStorageReload,
        serverRestarted: serverRestarted,
      );
    } catch (_) {
      // 后台返回了非预期内容、连接器抛出异常或系统网络栈失败时，恢复
      // 功能必须收敛为可展示的失败结果，不能让播放器退出监听链中断。
      return const OpenListRecoveryResult(
        outcome: OpenListRecoveryOutcome.retryableFailure,
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
    bool serverRestarted = false,
  }) async {
    if (!config.enabled) {
      return const OpenListRecoveryResult(
        outcome: OpenListRecoveryOutcome.terminalFailure,
        storageReloaded: false,
        message: 'OpenList/AList 自动恢复未启用',
      );
    }
    if (!config.hasCredentials) {
      return const OpenListRecoveryResult(
        outcome: OpenListRecoveryOutcome.terminalFailure,
        storageReloaded: false,
        message: '未配置 OpenList/AList 管理员账号、密码或 Token',
      );
    }

    final baseUri = normalizeBaseUri(config.baseUrl);
    final mediaUri = Uri.tryParse(mediaUrl);
    if (baseUri == null || mediaUri == null || !mediaUri.hasScheme) {
      return const OpenListRecoveryResult(
        outcome: OpenListRecoveryOutcome.terminalFailure,
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
    final credentialFingerprint = _credentialFingerprint(config);
    final inflightKey = _digestScope(<String>[
      _normalizedUriIdentity(baseUri),
      credentialFingerprint,
    ]);
    final cooldownKey = _digestScope(<String>[
      _normalizedUriIdentity(baseUri),
      credentialFingerprint,
      _normalizedUriIdentity(mediaUri),
    ]);
    if (mediaAvailable) {
      if (forceStorageReload) {
        return OpenListRecoveryResult(
          outcome: OpenListRecoveryOutcome.terminalNotLinkFailure,
          storageReloaded: false,
          serverVersion: version,
          message: '媒体地址可正常读取，当前错误不属于链接失效，停止自动恢复',
        );
      }
      return OpenListRecoveryResult(
        outcome: OpenListRecoveryOutcome.ready,
        storageReloaded: false,
        serverVersion: version,
        message: '原 WebDAV 地址已可重新取链，无需刷新全部存储',
      );
    }

    // 服务刚完成安全重启时，先给 OpenList/AList 自身的存储初始化完整
    // 等待窗口；只有仍不可用才继续走管理 API 刷新。
    if (serverRestarted) {
      final becameAvailable = await _waitForMedia(
        probe,
        mediaUri,
        username: webDavUsername,
        password: webDavPassword,
        timeout: readinessTimeout,
      );
      if (becameAvailable) {
        return OpenListRecoveryResult(
          outcome: OpenListRecoveryOutcome.ready,
          storageReloaded: false,
          serverVersion: version,
          message: 'OpenList/AList 安全重启后媒体地址已恢复',
        );
      }
      // 进程重启已使旧刷新冷却状态失效，允许最后一次管理 API 恢复。
      _lastSuccessfulReloads.remove(cooldownKey);
    }

    final lastReload = _lastSuccessfulReloads[cooldownKey];
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
        outcome: becameAvailable
            ? OpenListRecoveryOutcome.ready
            : OpenListRecoveryOutcome.terminalFailure,
        storageReloaded: false,
        serverVersion: version,
        message: becameAvailable
            ? '后台近期已刷新，媒体地址现已恢复'
            : '后台近期已刷新但媒体仍不可用，为避免频繁重载已停止自动重试',
      );
    }

    final existing = _inflightReloads[inflightKey];
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
      if (ready) _lastSuccessfulReloads[cooldownKey] = _clock();
      return OpenListRecoveryResult(
        outcome: ready
            ? OpenListRecoveryOutcome.ready
            : OpenListRecoveryOutcome.retryableFailure,
        storageReloaded: shared.storageReloaded,
        serverVersion: shared.serverVersion ?? version,
        message: ready ? '共享的后台刷新流程结束，媒体地址恢复' : '共享的后台刷新流程结束，但媒体地址仍不可用',
      );
    }

    final future = _reloadStorage(baseUri, config, version);
    _inflightReloads[inflightKey] = future;
    OpenListRecoveryResult reloaded;
    try {
      reloaded = await future;
    } finally {
      if (identical(_inflightReloads[inflightKey], future)) {
        _inflightReloads.remove(inflightKey);
      }
    }
    if (!reloaded.success) return reloaded;

    final ready = await _waitForMedia(
      probe,
      mediaUri,
      username: webDavUsername,
      password: webDavPassword,
      timeout: readinessTimeout,
    );
    if (ready) _lastSuccessfulReloads[cooldownKey] = _clock();
    return OpenListRecoveryResult(
      outcome: ready
          ? OpenListRecoveryOutcome.ready
          : OpenListRecoveryOutcome.retryableFailure,
      storageReloaded: true,
      serverVersion: reloaded.serverVersion ?? version,
      message: ready ? '后台存储刷新流程结束，媒体地址已恢复' : '后台存储刷新流程结束，但媒体地址在等待期限内仍不可用',
    );
  }

  String _credentialFingerprint(OpenListRecoveryConfig config) => sha256
      .convert(
        utf8.encode(
          '${config.username.trim()}\u0000${config.token}\u0000${config.password}',
        ),
      )
      .toString();

  String _digestScope(List<String> components) =>
      sha256.convert(utf8.encode(components.join('\u0000'))).toString();

  String _normalizedUriIdentity(Uri uri) {
    final normalized = uri.normalizePath();
    final scheme = normalized.scheme.toLowerCase();
    final host = normalized.host.toLowerCase();
    final defaultPort = scheme == 'http'
        ? 80
        : scheme == 'https'
        ? 443
        : null;
    final port = normalized.hasPort && normalized.port != defaultPort
        ? ':${normalized.port}'
        : '';
    final authorityHost = host.contains(':') ? '[$host]' : host;
    final authority = authorityHost.isEmpty ? '' : '//$authorityHost$port';
    final path = normalized.path.isEmpty ? '/' : normalized.path;
    final query = normalized.hasQuery ? '?${normalized.query}' : '';
    return '$scheme:$authority$path$query';
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
    return apiUri(base, endpoint);
  }

  Future<String?> _detectVersion(Uri baseUri) async {
    try {
      final response = await _request(
        _apiUri(baseUri, '/api/public/settings'),
        method: 'GET',
        timeout: const Duration(seconds: 5),
      );
      final envelope = OpenListEnvelope.parse(response);
      if (!envelope.success) return null;
      final version =
          envelope.dataMap?['version'] ?? envelope.payload?['version'];
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
    final deadline = _api.deadline(readinessTimeout);
    final capabilities = OpenListCapabilities.fromVersion(version);
    if (capabilities.storageReload == OpenListCapabilitySupport.unsupported) {
      return OpenListRecoveryResult(
        outcome: OpenListRecoveryOutcome.terminalFailure,
        storageReloaded: false,
        serverVersion: version,
        message: capabilities.unavailableMessage(
          '存储恢复',
          '/api/admin/storage/load_all',
        ),
      );
    }
    var token = config.token.trim();
    if (token.isEmpty) {
      final login = await _login(baseUri, config, deadline);
      if (login.token == null) {
        return OpenListRecoveryResult(
          outcome: login.retryable
              ? OpenListRecoveryOutcome.retryableFailure
              : OpenListRecoveryOutcome.terminalFailure,
          storageReloaded: false,
          serverVersion: version,
          message: login.message,
        );
      }
      token = login.token!;
    }

    var response = await _postReload(baseUri, token, deadline);
    if (_isUnauthorized(response) &&
        config.username.trim().isNotEmpty &&
        config.password.isNotEmpty) {
      final login = await _login(baseUri, config, deadline);
      if (login.token == null) {
        return OpenListRecoveryResult(
          outcome: login.retryable
              ? OpenListRecoveryOutcome.retryableFailure
              : OpenListRecoveryOutcome.terminalFailure,
          storageReloaded: false,
          serverVersion: version,
          message: login.message,
        );
      }
      token = login.token!;
      response = await _postReload(baseUri, token, deadline);
    }
    if (!_isApiSuccess(response)) {
      final envelope = OpenListEnvelope.parse(response);
      return OpenListRecoveryResult(
        outcome: _isUnauthorized(response) || envelope.endpointUnavailable
            ? OpenListRecoveryOutcome.terminalFailure
            : OpenListRecoveryOutcome.retryableFailure,
        storageReloaded: false,
        serverVersion: version,
        message: envelope.endpointUnavailable
            ? '存储恢复不可用：当前后台缺少 /api/admin/storage/load_all 端点'
            : 'OpenList/AList 存储刷新失败：${_apiMessage(response)}',
      );
    }

    // load_all 在 OpenList v4 / AList v3 中均为异步处理。管理员列表请求
    // 会经过存储加载中间件；等待它成功返回，不能把 load_all 的立即响应
    // 误认为刷新已经完成。
    final ready = await _waitForAdminReady(baseUri, token, deadline);
    return OpenListRecoveryResult(
      outcome: ready
          ? OpenListRecoveryOutcome.ready
          : OpenListRecoveryOutcome.retryableFailure,
      storageReloaded: ready,
      serverVersion: version,
      message: ready
          ? 'OpenList/AList 存储刷新流程结束，等待目标媒体恢复'
          : '后台接受了刷新请求，但刷新流程未在等待期限内结束',
    );
  }

  Future<_LoginResult> _login(
    Uri baseUri,
    OpenListRecoveryConfig config,
    OpenListRequestDeadline deadline,
  ) async {
    final result = await OpenListAuthenticator(_api).login(
      baseUri,
      username: config.username,
      password: config.password,
      role: '管理员',
      deadline: deadline,
    );
    return _LoginResult(
      token: result.token,
      message: result.message,
      retryable: result.retryable,
    );
  }

  Future<OpenListHttpResponse> _postReload(
    Uri baseUri,
    String token,
    OpenListRequestDeadline deadline,
  ) => _request(
    _apiUri(baseUri, '/api/admin/storage/load_all'),
    method: 'POST',
    headers: <String, String>{HttpHeaders.authorizationHeader: token},
    timeout: deadline.remaining,
  );

  Future<bool> _waitForAdminReady(
    Uri baseUri,
    String token,
    OpenListRequestDeadline deadline,
  ) async {
    while (!deadline.expired) {
      try {
        final remaining = deadline.remaining;
        if (remaining <= Duration.zero) break;
        final response = await _request(
          _apiUri(baseUri, '/api/admin/storage/list'),
          method: 'GET',
          headers: <String, String>{HttpHeaders.authorizationHeader: token},
          timeout: remaining,
        );
        if (_isApiSuccess(response)) return true;
        if (_isUnauthorized(response)) return false;
      } catch (_) {
        // 后台尚在卸载/重建存储时保留重试。
      }
      final remaining = deadline.remaining;
      if (remaining <= Duration.zero) break;
      await Future<void>.delayed(
        remaining < const Duration(seconds: 1)
            ? remaining
            : const Duration(seconds: 1),
      );
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
      final remaining = deadline.difference(_clock());
      if (remaining <= Duration.zero) break;
      if (await _safeProbe(
        probe,
        mediaUri,
        username: username,
        password: password,
        timeout: remaining < const Duration(seconds: 8)
            ? remaining
            : const Duration(seconds: 8),
      )) {
        return true;
      }
      final afterProbe = deadline.difference(_clock());
      if (afterProbe <= Duration.zero) break;
      await Future<void>.delayed(
        afterProbe < const Duration(seconds: 1)
            ? afterProbe
            : const Duration(seconds: 1),
      );
    }
    return false;
  }

  Future<bool> _safeProbe(
    OpenListMediaProbe probe,
    Uri mediaUri, {
    String? username,
    String? password,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      return await probe(
        mediaUri,
        username: username,
        password: password,
        timeout: timeout,
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
  }) => _api.request(
    uri,
    method: method,
    headers: headers,
    body: body,
    timeout: timeout ?? const Duration(seconds: 15),
  );

  /// 真实媒体探测手动处理重定向：Basic 凭据只发送给原 WebDAV 来源，
  /// 跳转到网盘厂商签名域名后立即移除，避免后台账号或 WebDAV 密码泄漏。
  Future<bool> _probeMediaUrl(
    Uri mediaUri, {
    String? username,
    String? password,
    Duration? timeout,
  }) async {
    final totalTimeout = timeout ?? const Duration(seconds: 8);
    final deadline = _clock().add(totalTimeout);
    final client = HttpClient();
    var current = mediaUri;
    try {
      for (var redirects = 0; redirects <= 5; redirects++) {
        final remaining = deadline.difference(_clock());
        if (remaining <= Duration.zero) return false;
        client.connectionTimeout = remaining;
        final request = await client.getUrl(current).timeout(remaining);
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
        final beforeResponse = deadline.difference(_clock());
        if (beforeResponse <= Duration.zero) return false;
        final response = await request.close().timeout(beforeResponse);
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

  bool _isApiSuccess(OpenListHttpResponse response) =>
      OpenListEnvelope.parse(response).success;

  bool _isUnauthorized(OpenListHttpResponse response) {
    return OpenListEnvelope.parse(response).unauthorized;
  }

  String _apiMessage(OpenListHttpResponse response) {
    return OpenListEnvelope.parse(response).message;
  }
}

class _LoginResult {
  const _LoginResult({
    this.token,
    required this.message,
    this.retryable = false,
  });

  final String? token;
  final String message;
  final bool retryable;
}
