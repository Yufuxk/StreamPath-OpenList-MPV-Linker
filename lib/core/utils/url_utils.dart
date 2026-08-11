/// WebDAV URL 拼接、编码与缓存键工具（顶层函数）。
///
/// 关键点：PROPFIND 返回的 href 往往已含百分号编码（如 `%20`），
/// 而用户输入/拼接的路径需要编码——两类场景必须区分处理：
/// - [joinUrl]：把「服务器相对路径」拼到服务器根上（对路径段编码）；
/// - [resolveHref]：把「服务器返回的 href」解析为可请求的绝对 URL（保持原编码）；
/// - [cacheKeyFor]：生成规范化缓存键（Hive key）。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Hive 对字符串 key 的长度上限。
const int _hiveStringKeyMaxLength = 255;

/// 拼接请求 URL：`base` 为服务器根（含协议），`path` 为相对路径。
/// 路径中的每一段都会百分号编码，但保留 `/` 分隔符。
String joinUrl(String base, String path) {
  final p = path.startsWith('/') ? path.substring(1) : path;
  if (p.isEmpty) return base;
  final encoded = p.split('/').map(Uri.encodeComponent).join('/');
  return '${base.replaceAll(RegExp(r'/+$'), '')}/$encoded';
}

/// 把服务器返回的 href 解析为可访问的绝对 URL。
///
/// - 相对 href（如 `/dav/video.mp4`）基于 [baseUrl] 补全；
/// - 已编码内容原样保留，避免二次编码（`%20` → `%2520`）。
String resolveHref(String baseUrl, String href) {
  if (href.isEmpty) return baseUrl;
  final uri = Uri.tryParse(href);
  if (uri != null && uri.hasScheme) return href;
  final base = Uri.tryParse(baseUrl);
  if (base == null) return href;
  final directoryBase = base.path.endsWith('/')
      ? base
      : base.replace(path: '${base.path}/');
  return directoryBase.resolveUri(uri ?? Uri(path: href)).toString();
}

/// 生成目录缓存键：baseUrl + path 规范化（去尾部斜杠）。
///
/// 短 URL 保持原格式以兼容已有缓存；百分号编码后的长 URL 超过 Hive
/// 字符串 key 的 255 长度限制时，改用固定长度 SHA-256，避免长中文路径
/// 在缓存写入阶段抛出 `HiveError`。
String cacheKeyFor({
  required String baseUrl,
  required String path,
  String? namespace,
}) {
  final joined = joinUrl(baseUrl, path);
  final normalized = joined.replaceAll(RegExp(r'/+$'), '');
  if (namespace != null) {
    final scoped = '$namespace\n$normalized';
    return 'sha256:${sha256.convert(utf8.encode(scoped))}';
  }
  if (normalized.length <= _hiveStringKeyMaxLength) return normalized;
  return 'sha256:${sha256.convert(utf8.encode(normalized))}';
}

/// 从 URL 中剥离 userinfo 凭据（`http://user:pass@host` → `http://host`）。
///
/// 用于把「带内嵌凭据的播放 URL」还原为干净的存储键/显示 URL。
String stripUserInfo(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.userInfo.isEmpty) return url;
  return uri.replace(userInfo: '').toString();
}

/// 判断 [url] 与 [base] 是否同源（scheme + host + port 一致）。
///
/// 用于限制外部 URL 注入：strm 解析出的媒体地址只有与 WebDAV 服务器
/// 同源时才允许携带认证凭据，防止凭据泄露给第三方域名。
bool isSameOrigin(String base, String url) {
  final b = Uri.tryParse(base);
  final u = Uri.tryParse(url);
  if (b == null || u == null || !u.hasScheme) return false;
  return u.scheme.toLowerCase() == b.scheme.toLowerCase() &&
      u.host.toLowerCase() == b.host.toLowerCase() &&
      u.port == b.port;
}

/// 在 URL 中内嵌 Basic 凭据（`http://host` → `http://user:pass@host`）。
///
/// 用于不支持 `--http-header-fields` 的外部播放器（PotPlayer 等）；
/// 用户名/密码中的 `@`、`:` 等特殊字符会被正确百分号编码。
/// URL 已含凭据时原样返回。
String embedCredentials(String url, String username, String password) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) return url;
  final user = Uri.encodeComponent(username);
  final pass = Uri.encodeComponent(password);
  return uri.replace(userInfo: '$user:$pass').toString();
}
