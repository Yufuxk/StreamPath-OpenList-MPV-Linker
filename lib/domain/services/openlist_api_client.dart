import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

const _alistLoginHashSuffix = '-https://github.com/alist-org/alist';

/// 与具体 HTTP 库解耦的 OpenList/AList 响应。
class OpenListHttpResponse {
  const OpenListHttpResponse({
    required this.statusCode,
    this.data,
    this.transportFailure,
  });

  final int? statusCode;
  final Object? data;
  final OpenListTransportFailure? transportFailure;

  bool get failedInTransport => transportFailure != null;
}

enum OpenListTransportFailure { timeout, network }

typedef OpenListRequestSender =
    Future<OpenListHttpResponse> Function(
      Uri uri, {
      required String method,
      Map<String, String>? headers,
      Object? body,
      Duration? timeout,
    });

/// 一个逻辑操作共享的绝对截止时间。
class OpenListRequestDeadline {
  OpenListRequestDeadline._(Duration timeout)
    : _timeout = timeout > Duration.zero ? timeout : Duration.zero {
    _stopwatch.start();
  }

  final Duration _timeout;
  final Stopwatch _stopwatch = Stopwatch();

  Duration get remaining {
    final value = _timeout - _stopwatch.elapsed;
    return value > Duration.zero ? value : Duration.zero;
  }

  bool get expired => remaining <= Duration.zero;
}

/// OpenList/AList 官方 JSON envelope 的统一解析结果。
class OpenListEnvelope {
  const OpenListEnvelope._({required this.response, required this.payload});

  factory OpenListEnvelope.parse(OpenListHttpResponse response) =>
      OpenListEnvelope._(
        response: response,
        payload: _decodeMap(response.data),
      );

  final OpenListHttpResponse response;
  final Map<String, dynamic>? payload;

  int? get code => int.tryParse(payload?['code']?.toString() ?? '');

  Map<String, dynamic>? get dataMap => _asMap(payload?['data']);

  Object? get data => payload?['data'];

  String get message {
    final text = payload?['message']?.toString().trim();
    if (text != null && text.isNotEmpty) return text;
    final raw = response.data;
    if (raw is String && raw.trim().isNotEmpty) return raw.trim();
    if (response.transportFailure == OpenListTransportFailure.timeout) {
      return '请求超过总时间限制';
    }
    if (response.transportFailure == OpenListTransportFailure.network) {
      return '无法连接服务器';
    }
    return response.statusCode == null
        ? '无法连接服务器'
        : 'HTTP ${response.statusCode}';
  }

  bool get success {
    final status = response.statusCode;
    if (response.failedInTransport ||
        status == null ||
        status < 200 ||
        status >= 300) {
      return false;
    }
    return payload != null && code == 200;
  }

  bool get unauthorized =>
      response.statusCode == 401 ||
      response.statusCode == 403 ||
      code == 401 ||
      code == 403;

  bool get endpointUnavailable =>
      response.statusCode == 404 ||
      response.statusCode == 405 ||
      code == 404 ||
      code == 405 ||
      (response.statusCode != null &&
          response.statusCode! >= 200 &&
          response.statusCode! < 300 &&
          code == null);

  bool get requiresTwoFactor {
    final lower = message.toLowerCase();
    return response.statusCode == 402 ||
        code == 402 ||
        lower.contains('2fa') ||
        lower.contains('otp');
  }

  String? get token {
    if (!success) return null;
    final value = dataMap?['token']?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  static Map<String, dynamic>? _decodeMap(Object? value) {
    final direct = _asMap(value);
    if (direct != null) return direct;
    if (value is String) {
      try {
        return _asMap(jsonDecode(value));
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static Map<String, dynamic>? _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }
}

/// OpenList/AList 管理与索引 API 共用的窄 HTTP 传输层。
///
/// 每次逻辑请求只有一个总 deadline；重定向后的连接、发送和接收只能使用
/// 剩余预算，避免每一跳重新获得完整超时。
class OpenListApiClient {
  OpenListApiClient({
    Dio? dio,
    OpenListRequestSender? requestSender,
    this.maxRedirects = 5,
  }) : _dio = dio ?? Dio(),
       _requestSender = requestSender; // ignore: prefer_initializing_formals

  final Dio _dio;
  final OpenListRequestSender? _requestSender;
  final int maxRedirects;

  OpenListRequestDeadline deadline(Duration timeout) =>
      OpenListRequestDeadline._(timeout);

  Future<OpenListHttpResponse> request(
    Uri uri, {
    required String method,
    Map<String, String>? headers,
    Object? body,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (timeout <= Duration.zero) {
      return const OpenListHttpResponse(
        statusCode: null,
        data: '请求超过总时间限制',
        transportFailure: OpenListTransportFailure.timeout,
      );
    }
    final sender = _requestSender;
    if (sender != null) {
      try {
        return await sender(
          uri,
          method: method,
          headers: headers,
          body: body,
          timeout: timeout,
        ).timeout(timeout);
      } on TimeoutException {
        return const OpenListHttpResponse(
          statusCode: null,
          data: '请求超过总时间限制',
          transportFailure: OpenListTransportFailure.timeout,
        );
      } catch (error) {
        return OpenListHttpResponse(
          statusCode: null,
          data: error.toString(),
          transportFailure: OpenListTransportFailure.network,
        );
      }
    }

    final requestDeadline = deadline(timeout);
    var current = uri;
    for (var redirects = 0; redirects <= maxRedirects; redirects++) {
      final remaining = requestDeadline.remaining;
      if (remaining <= Duration.zero) {
        return const OpenListHttpResponse(
          statusCode: null,
          data: '请求超过总时间限制',
          transportFailure: OpenListTransportFailure.timeout,
        );
      }
      try {
        final response = await _dio
            .request<Object?>(
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
                connectTimeout: remaining,
                sendTimeout: remaining,
                receiveTimeout: remaining,
              ),
            )
            .timeout(remaining);
        final status = response.statusCode;
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (status == null ||
            status < 300 ||
            status >= 400 ||
            location == null) {
          return OpenListHttpResponse(statusCode: status, data: response.data);
        }
        if (redirects >= maxRedirects) {
          return const OpenListHttpResponse(
            statusCode: 310,
            data: 'OpenList/AList 请求重定向次数过多',
          );
        }
        final next = current.resolve(location);
        if (!sameOrigin(next, uri)) {
          return OpenListHttpResponse(
            statusCode: status,
            data: '拒绝将 OpenList/AList 认证请求重定向到其他来源',
          );
        }
        current = next;
      } on TimeoutException {
        return const OpenListHttpResponse(
          statusCode: null,
          data: '请求超过总时间限制',
          transportFailure: OpenListTransportFailure.timeout,
        );
      } on DioException catch (error) {
        final timedOut =
            error.type == DioExceptionType.connectionTimeout ||
            error.type == DioExceptionType.sendTimeout ||
            error.type == DioExceptionType.receiveTimeout;
        return OpenListHttpResponse(
          statusCode: error.response?.statusCode,
          data: error.response?.data ?? error.message,
          transportFailure: timedOut
              ? OpenListTransportFailure.timeout
              : OpenListTransportFailure.network,
        );
      }
    }
    return const OpenListHttpResponse(
      statusCode: 310,
      data: 'OpenList/AList 请求重定向次数过多',
    );
  }

  static bool sameOrigin(Uri a, Uri b) =>
      a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
      a.host.toLowerCase() == b.host.toLowerCase() &&
      a.port == b.port;
}

enum OpenListAuthOutcome {
  authenticated,
  missingCredentials,
  requiresTwoFactor,
  rejected,
  retryableTransportFailure,
}

class OpenListAuthResult {
  const OpenListAuthResult({
    required this.outcome,
    required this.message,
    this.token,
  });

  final OpenListAuthOutcome outcome;
  final String message;
  final String? token;

  bool get success => outcome == OpenListAuthOutcome.authenticated;
  bool get retryable =>
      outcome == OpenListAuthOutcome.retryableTransportFailure;
}

/// 普通用户与管理员共用的登录回退策略。
class OpenListAuthenticator {
  const OpenListAuthenticator(this.client);

  final OpenListApiClient client;

  Future<OpenListAuthResult> login(
    Uri base, {
    required String username,
    required String password,
    required String role,
    Duration timeout = const Duration(seconds: 10),
    OpenListRequestDeadline? deadline,
  }) async {
    final normalizedUser = username.trim();
    if (normalizedUser.isEmpty || password.isEmpty) {
      return OpenListAuthResult(
        outcome: OpenListAuthOutcome.missingCredentials,
        message: '未配置$role账号密码',
      );
    }
    final requestDeadline = deadline ?? client.deadline(timeout);
    var response = await client.request(
      apiUri(base, '/api/auth/login'),
      method: 'POST',
      body: <String, Object?>{'username': normalizedUser, 'password': password},
      timeout: requestDeadline.remaining,
    );
    var envelope = OpenListEnvelope.parse(response);
    final token = envelope.token;
    if (token != null) {
      return OpenListAuthResult(
        outcome: OpenListAuthOutcome.authenticated,
        token: token,
        message: '登录成功',
      );
    }
    if (response.failedInTransport) {
      return OpenListAuthResult(
        outcome: OpenListAuthOutcome.retryableTransportFailure,
        message: '$role登录请求异常：${envelope.message}',
      );
    }
    if (envelope.requiresTwoFactor) {
      return OpenListAuthResult(
        outcome: OpenListAuthOutcome.requiresTwoFactor,
        message: '$role账号启用了 2FA，请填写独立的$role Token',
      );
    }
    if (envelope.endpointUnavailable) {
      if (requestDeadline.expired) {
        return OpenListAuthResult(
          outcome: OpenListAuthOutcome.retryableTransportFailure,
          message: '$role登录请求超过总时间限制',
        );
      }
      response = await client.request(
        apiUri(base, '/api/auth/login/hash'),
        method: 'POST',
        body: <String, Object?>{
          'username': normalizedUser,
          'password': sha256
              .convert(utf8.encode('$password$_alistLoginHashSuffix'))
              .toString(),
        },
        timeout: requestDeadline.remaining,
      );
      envelope = OpenListEnvelope.parse(response);
      final hashToken = envelope.token;
      if (hashToken != null) {
        return OpenListAuthResult(
          outcome: OpenListAuthOutcome.authenticated,
          token: hashToken,
          message: '登录成功',
        );
      }
      if (response.failedInTransport) {
        return OpenListAuthResult(
          outcome: OpenListAuthOutcome.retryableTransportFailure,
          message: '$role登录请求异常：${envelope.message}',
        );
      }
      if (envelope.requiresTwoFactor) {
        return OpenListAuthResult(
          outcome: OpenListAuthOutcome.requiresTwoFactor,
          message: '$role账号启用了 2FA，请填写独立的$role Token',
        );
      }
    }
    return OpenListAuthResult(
      outcome: OpenListAuthOutcome.rejected,
      message: '$role登录失败：${envelope.message}',
    );
  }
}

enum OpenListCapabilitySupport { supported, unsupported, unknown }

/// 后台增强功能按端点拆分，禁止再用一个“兼容”布尔值概括全部能力。
class OpenListCapabilities {
  const OpenListCapabilities({
    required this.version,
    required this.webDavConnection,
    required this.plainLogin,
    required this.hashLogin,
    required this.indexSearch,
    required this.indexProgress,
    required this.indexUpdate,
    required this.storageReload,
  });

  factory OpenListCapabilities.unknown({String? version}) =>
      OpenListCapabilities(
        version: version,
        webDavConnection: OpenListCapabilitySupport.supported,
        plainLogin: OpenListCapabilitySupport.unknown,
        hashLogin: OpenListCapabilitySupport.unknown,
        indexSearch: OpenListCapabilitySupport.unknown,
        indexProgress: OpenListCapabilitySupport.unknown,
        indexUpdate: OpenListCapabilitySupport.unknown,
        storageReload: OpenListCapabilitySupport.unknown,
      );

  /// 官方 tag 静态矩阵只用于预先关闭已确认不存在的端点；未知版本保持
  /// unknown，并由真实端点响应继续收窄，不能乐观宣称支持。
  factory OpenListCapabilities.fromVersion(String? rawVersion) {
    final version = rawVersion?.trim();
    final match = RegExp(
      r'^[vV]?(\d+)\.(\d+)\.(\d+)(?:\s.*)?$',
    ).firstMatch(version ?? '');
    if (match == null) return OpenListCapabilities.unknown(version: version);
    final major = int.parse(match.group(1)!);
    final minor = int.parse(match.group(2)!);
    final patch = int.parse(match.group(3)!);
    final verifiedOpenList =
        major == 4 &&
        ((minor == 0 && patch == 0) ||
            (minor == 1 && patch == 4) ||
            (minor == 2 && patch == 5));
    if (verifiedOpenList) {
      return OpenListCapabilities(
        version: version,
        webDavConnection: OpenListCapabilitySupport.supported,
        plainLogin: OpenListCapabilitySupport.supported,
        hashLogin: OpenListCapabilitySupport.supported,
        indexSearch: OpenListCapabilitySupport.supported,
        indexProgress: OpenListCapabilitySupport.supported,
        indexUpdate: OpenListCapabilitySupport.supported,
        storageReload: OpenListCapabilitySupport.supported,
      );
    }
    if (major != 3) return OpenListCapabilities.unknown(version: version);
    if (minor == 0 && patch == 1) {
      return OpenListCapabilities(
        version: version,
        webDavConnection: OpenListCapabilitySupport.supported,
        plainLogin: OpenListCapabilitySupport.supported,
        hashLogin: OpenListCapabilitySupport.unsupported,
        indexSearch: OpenListCapabilitySupport.unsupported,
        indexProgress: OpenListCapabilitySupport.unsupported,
        indexUpdate: OpenListCapabilitySupport.unsupported,
        storageReload: OpenListCapabilitySupport.unsupported,
      );
    }
    if (minor == 6 && patch == 0) {
      return OpenListCapabilities(
        version: version,
        webDavConnection: OpenListCapabilitySupport.supported,
        plainLogin: OpenListCapabilitySupport.supported,
        hashLogin: OpenListCapabilitySupport.unsupported,
        indexSearch: OpenListCapabilitySupport.supported,
        indexProgress: OpenListCapabilitySupport.supported,
        indexUpdate: OpenListCapabilitySupport.unsupported,
        storageReload: OpenListCapabilitySupport.unsupported,
      );
    }
    if (minor == 7 && patch == 1) {
      return OpenListCapabilities(
        version: version,
        webDavConnection: OpenListCapabilitySupport.supported,
        plainLogin: OpenListCapabilitySupport.supported,
        hashLogin: OpenListCapabilitySupport.unsupported,
        indexSearch: OpenListCapabilitySupport.supported,
        indexProgress: OpenListCapabilitySupport.supported,
        indexUpdate: OpenListCapabilitySupport.supported,
        storageReload: OpenListCapabilitySupport.supported,
      );
    }
    if (minor != 63 || patch != 0) {
      return OpenListCapabilities.unknown(version: version);
    }
    return OpenListCapabilities(
      version: version,
      webDavConnection: OpenListCapabilitySupport.supported,
      plainLogin: OpenListCapabilitySupport.supported,
      hashLogin: OpenListCapabilitySupport.supported,
      indexSearch: OpenListCapabilitySupport.supported,
      indexProgress: OpenListCapabilitySupport.supported,
      indexUpdate: OpenListCapabilitySupport.supported,
      storageReload: OpenListCapabilitySupport.supported,
    );
  }

  final String? version;
  final OpenListCapabilitySupport webDavConnection;
  final OpenListCapabilitySupport plainLogin;
  final OpenListCapabilitySupport hashLogin;
  final OpenListCapabilitySupport indexSearch;
  final OpenListCapabilitySupport indexProgress;
  final OpenListCapabilitySupport indexUpdate;
  final OpenListCapabilitySupport storageReload;

  String unavailableMessage(String featureName, String endpoint) =>
      '$featureName不可用：当前后台缺少 $endpoint 端点'
      '${version == null || version!.isEmpty ? '' : '（版本 $version）'}';
}

Uri apiUri(Uri base, String endpoint) {
  final prefix = base.path.endsWith('/')
      ? base.path.substring(0, base.path.length - 1)
      : base.path;
  return base.replace(path: '$prefix$endpoint', query: null, fragment: null);
}
