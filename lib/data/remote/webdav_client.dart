import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../../core/errors/app_exception.dart';
import '../../core/utils/url_utils.dart';

/// WebDAV 协议客户端（dio 封装）。
///
/// 只负责协议细节：
/// - 以 [baseUrl] 为根，对相对路径发起 `PROPFIND`（`Depth: 1`）；
/// - 注入 Basic 认证；
/// - 把 dio 的底层异常翻译为 [AppException.network]。
/// 不包含任何业务逻辑（缓存、并发限制、请求合并由上层负责）。
class WebDavClient {
  WebDavClient({
    required this.baseUrl,
    this.username,
    this.password,
    Dio? dio,
    this.connectTimeout = const Duration(seconds: 30),
  }) : _dio = dio ?? Dio() {
    _dio.options
      ..connectTimeout = connectTimeout
      ..receiveTimeout = connectTimeout;
    _applyAuth();
  }

  /// 服务器根地址（含协议，如 `https://nas.example.com/dav`）。
  final String baseUrl;

  /// 认证用户名（可为 null，表示匿名访问）。
  final String? username;

  /// 认证密码。
  final String? password;

  final Dio _dio;
  final Duration connectTimeout;
  String? _authorizationHeader;

  void _applyAuth() {
    if (username != null && username!.isNotEmpty) {
      final token = base64Encode(utf8.encode('$username:${password ?? ''}'));
      _authorizationHeader = 'Basic $token';
    } else {
      _authorizationHeader = null;
    }
  }

  /// 执行 PROPFIND（Depth: 1），返回原始 XML 文本。
  ///
  /// [path] 为相对路径（如 `电影/动作`、`''` 表示根目录）。
  Future<String> propfind(String path) async {
    final url = joinUrl(baseUrl, path);
    try {
      final response = await _requestFollowingRedirects<String>(
        url: url,
        method: 'PROPFIND',
        headers: const {'Depth': '1'},
        responseType: ResponseType.plain,
      );
      final data = response.data;
      if (data == null || data.isEmpty) {
        throw AppException.parse('PROPFIND 返回空响应');
      }
      return data;
    } on DioException catch (e) {
      throw _translateDioError(e);
    }
  }

  /// 获取文件文本内容（GET，注入认证），用于读取 .strm 等文本指针文件。
  ///
  /// [href] 为服务器返回的 href（绝对或相对，保持原编码，不二次编码）。
  Future<String> getFileContent(String href, {int? maxBytes}) async {
    final bytes = await getFileBytes(href, maxBytes: maxBytes);
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// 获取文件原始字节，供需要保留源编码的小型伴随文件使用。
  Future<List<int>> getFileBytes(
    String href, {
    int? maxBytes,
    Duration? timeout,
  }) async {
    final url = resolveHref(baseUrl, href);
    try {
      final response = await _requestFollowingRedirects<ResponseBody>(
        url: url,
        method: 'GET',
        responseType: ResponseType.stream,
        requestTimeout: timeout,
      );
      final body = response.data;
      if (body == null) return const [];
      if (maxBytes != null && body.contentLength > maxBytes) {
        throw AppException.parse('文件内容超过 $maxBytes 字节限制');
      }

      final bytes = <int>[];
      await for (final chunk in body.stream) {
        bytes.addAll(chunk);
        if (maxBytes != null && bytes.length > maxBytes) {
          throw AppException.parse('文件内容超过 $maxBytes 字节限制');
        }
      }
      return bytes;
    } on DioException catch (e) {
      throw _translateDioError(e);
    }
  }

  static const int _maxRedirects = 5;

  Future<Response<T>> _requestFollowingRedirects<T>({
    required String url,
    required String method,
    required ResponseType responseType,
    Map<String, Object?> headers = const {},
    Duration? requestTimeout,
  }) async {
    final original = Uri.parse(url);
    var current = original;
    for (var redirectCount = 0; ; redirectCount++) {
      if (current.scheme != 'http' && current.scheme != 'https') {
        throw AppException.parse('不支持的网络协议：${current.scheme}');
      }

      final requestHeaders = <String, Object?>{...headers};
      final authorization = _authorizationHeader;
      if (authorization != null && isSameOrigin(baseUrl, current.toString())) {
        requestHeaders[HttpHeaders.authorizationHeader] = authorization;
      }
      final response = await _dio.request<T>(
        current.toString(),
        options: Options(
          method: method,
          headers: requestHeaders,
          responseType: responseType,
          connectTimeout: requestTimeout,
          receiveTimeout: requestTimeout,
          followRedirects: false,
          validateStatus: (status) =>
              status != null && status >= 200 && status < 400,
        ),
      );

      if (!_isRedirect(response.statusCode)) return response;
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (location == null || location.trim().isEmpty) {
        throw AppException.network('服务器重定向缺少 Location');
      }
      if (redirectCount >= _maxRedirects) {
        throw AppException.network('服务器重定向次数超过 $_maxRedirects 次');
      }
      final next = current.resolve(location);
      if (method.toUpperCase() != 'GET' &&
          !isSameOrigin(original.toString(), next.toString())) {
        throw AppException.network('非 GET 请求拒绝跨来源重定向');
      }
      await _cancelStreamBody(response.data);
      current = next;
    }
  }

  static bool _isRedirect(int? status) =>
      status == HttpStatus.movedPermanently ||
      status == HttpStatus.found ||
      status == HttpStatus.seeOther ||
      status == HttpStatus.temporaryRedirect ||
      status == HttpStatus.permanentRedirect;

  static Future<void> _cancelStreamBody(Object? data) async {
    if (data is! ResponseBody) return;
    final subscription = data.stream.listen(null);
    await subscription.cancel();
  }

  NetworkException _translateDioError(DioException e) {
    final status = e.response?.statusCode;
    final msg = switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout => '连接服务器超时（$connectTimeout）',
      DioExceptionType.connectionError => '无法连接到服务器：${e.message ?? ''}',
      DioExceptionType.badCertificate => '服务器证书不受信任',
      _ when status == 401 || status == 403 => '认证失败：请检查账号与密码（HTTP $status）',
      _ when status != null => '服务器返回错误（HTTP $status）',
      _ => '网络请求失败：${e.message ?? e.type.name}',
    };
    return NetworkException(msg, cause: e);
  }
}
