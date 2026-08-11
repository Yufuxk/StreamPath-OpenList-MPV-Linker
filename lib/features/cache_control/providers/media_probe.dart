import 'dart:async';
import 'dart:io';

/// 媒体探测结果。
class MediaProbeResult {
  const MediaProbeResult({
    this.contentLengthBytes,
    this.etag,
    this.lastModified,
    this.error,
  });

  final int? contentLengthBytes;
  final String? etag;
  final String? lastModified;
  final String? error;

  bool get ok => contentLengthBytes != null && contentLengthBytes! > 0;

  @override
  String toString() => ok
      ? 'contentLength=${contentLengthBytes!}'
      : 'failed: ${error ?? 'unknown'}';
}

abstract class MediaProbe {
  Future<MediaProbeResult> probeContentLength({
    required String url,
    String? authHeader,
  });
}

/// 不阻断播放的 HTTP 媒体大小探测。
///
/// 使用 [HttpClient] 让系统网络栈处理 DNS 多地址重试和 TLS 主机名；
/// 最多跟随 5 次重定向，Authorization 只在同源跳转中保留。HEAD 不被
/// 支持或缺少长度时，以 1 字节 Range GET 获取 Content-Range 总大小。
class HttpMediaProbe implements MediaProbe {
  HttpMediaProbe({
    this.timeout = const Duration(milliseconds: 1500),
    this.maxRedirects = 5,
  });

  final Duration timeout;
  final int maxRedirects;

  @override
  Future<MediaProbeResult> probeContentLength({
    required String url,
    String? authHeader,
  }) async {
    Uri uri;
    try {
      uri = Uri.parse(url);
    } catch (e) {
      return MediaProbeResult(error: 'URL 非法: $e');
    }
    if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      return MediaProbeResult(error: '不支持的 URL: ${uri.scheme}');
    }
    if (_hasControl(url) || _hasControl(uri.path) || _hasControl(uri.query)) {
      return const MediaProbeResult(error: 'URL 含控制字符');
    }

    final deadline = DateTime.now().add(timeout);
    Duration remaining() {
      final value = deadline.difference(DateTime.now());
      return value.isNegative ? Duration.zero : value;
    }

    final client = HttpClient()
      ..connectionTimeout = timeout
      ..autoUncompress = false
      ..findProxy = HttpClient.findProxyFromEnvironment;
    final original = uri;
    var authorization = authHeader;
    try {
      for (var redirect = 0; redirect <= maxRedirects; redirect++) {
        final head = await _request(
          client,
          uri,
          method: 'HEAD',
          authorization: authorization,
          timeout: remaining(),
        );
        final redirected = _redirectTarget(head, uri);
        if (redirected != null) {
          await _cancelBody(head);
          if (redirect == maxRedirects) {
            return const MediaProbeResult(error: '重定向次数过多');
          }
          if (!_sameOrigin(original, redirected)) authorization = null;
          uri = redirected;
          continue;
        }

        final validators = _validators(head);
        if (head.statusCode >= 200 && head.statusCode < 300) {
          final length = head.contentLength;
          await _cancelBody(head);
          if (length > 0) {
            return MediaProbeResult(
              contentLengthBytes: length,
              etag: validators.$1,
              lastModified: validators.$2,
            );
          }
          return await _probeWithRange(client, uri, authorization, remaining());
        }
        final status = head.statusCode;
        await _cancelBody(head);
        if (status == HttpStatus.methodNotAllowed ||
            status == HttpStatus.notImplemented) {
          return await _probeWithRange(client, uri, authorization, remaining());
        }
        return MediaProbeResult(error: 'HTTP $status');
      }
      return const MediaProbeResult(error: '重定向次数过多');
    } on TimeoutException {
      return const MediaProbeResult(error: '探测超时');
    } catch (e) {
      return MediaProbeResult(error: '$e');
    } finally {
      client.close(force: true);
    }
  }

  Future<MediaProbeResult> _probeWithRange(
    HttpClient client,
    Uri uri,
    String? authorization,
    Duration timeout,
  ) async {
    final response = await _request(
      client,
      uri,
      method: 'GET',
      authorization: authorization,
      range: 'bytes=0-0',
      timeout: timeout,
    );
    final validators = _validators(response);
    final contentRange = response.headers.value(HttpHeaders.contentRangeHeader);
    int? total;
    if (contentRange != null) {
      final match = RegExp(r'/([0-9]+)$').firstMatch(contentRange.trim());
      total = match == null ? null : int.tryParse(match.group(1)!);
    }
    if ((total == null || total <= 0) &&
        response.statusCode == HttpStatus.ok &&
        response.contentLength > 0) {
      total = response.contentLength;
    }
    final status = response.statusCode;
    await _cancelBody(response);
    if (total != null && total > 0) {
      return MediaProbeResult(
        contentLengthBytes: total,
        etag: validators.$1,
        lastModified: validators.$2,
      );
    }
    return MediaProbeResult(error: 'Range GET HTTP $status 无总大小');
  }

  static Future<HttpClientResponse> _request(
    HttpClient client,
    Uri uri, {
    required String method,
    required String? authorization,
    required Duration timeout,
    String? range,
  }) async {
    if (timeout <= Duration.zero) throw TimeoutException('探测超时');
    final deadline = DateTime.now().add(timeout);
    final request = await client.openUrl(method, uri).timeout(timeout)
      ..followRedirects = false
      ..persistentConnection = false;
    if (authorization != null && authorization.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, authorization);
    }
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) throw TimeoutException('探测超时');
    return request.close().timeout(remaining);
  }

  static Uri? _redirectTarget(HttpClientResponse response, Uri current) {
    if (response.statusCode != HttpStatus.movedPermanently &&
        response.statusCode != HttpStatus.found &&
        response.statusCode != HttpStatus.seeOther &&
        response.statusCode != HttpStatus.temporaryRedirect &&
        response.statusCode != HttpStatus.permanentRedirect) {
      return null;
    }
    final location = response.headers.value(HttpHeaders.locationHeader);
    if (location == null || location.isEmpty) return null;
    return current.resolve(location);
  }

  static (String?, String?) _validators(HttpClientResponse response) => (
    response.headers.value(HttpHeaders.etagHeader),
    response.headers.value(HttpHeaders.lastModifiedHeader),
  );

  static Future<void> _cancelBody(HttpClientResponse response) async {
    final subscription = response.listen((_) {});
    await subscription.cancel();
  }

  static bool _sameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host == b.host && a.port == b.port;

  static bool _hasControl(String value) =>
      value.codeUnits.any((code) => code < 0x20 || code == 0x7f);
}
