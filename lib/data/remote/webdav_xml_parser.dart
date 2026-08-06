import 'dart:io';

import 'package:xml/xml.dart';

import '../../core/errors/app_exception.dart';
import '../../core/utils/file_sort.dart';
import '../../core/utils/url_utils.dart';
import '../models/web_dav_file.dart';

/// PROPFIND `multistatus` 响应的 XML 解析器。
///
/// 只依赖 `localName`（忽略命名空间前缀），兼容多数服务器
/// （`DAV:`、`d:`、`D:` 等不同命名空间写法）。
class WebDavXmlParser {
  const WebDavXmlParser();

  /// 解析目录列表（Depth: 1 响应）。
  ///
  /// [requestUrl] 为本次请求的完整 URL：
  /// - 其 origin（scheme://host）用于把相对 href 补全为绝对 URL；
  /// - 空/空白 XML 返回空列表；
  /// - 非法 XML 抛 [AppException.parse]。
  List<WebDavFile> parse(String xml, {required String requestUrl}) {
    if (xml.trim().isEmpty) return const [];

    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xml);
    } on XmlException catch (e) {
      throw AppException.parse('服务器响应不是有效的 XML：${e.message}', e);
    }

    final origin = _originOf(requestUrl);
    final results = <WebDavFile>[];

    for (final response in doc.descendants.whereType<XmlElement>()) {
      if (response.localName != 'response') continue;

      final hrefText = _firstText(response, 'href');
      if (hrefText == null || hrefText.isEmpty) continue;

      // 目录判定：resourcetype 含 collection，或 href 以 / 结尾
      //（兼容部分服务器对 404/无 prop 条目只返回 href 的情况）。
      final isDir = _hasChild(response, 'collection') || hrefText.endsWith('/');
      final name = _resolveName(response, hrefText);
      final href = origin == null ? hrefText : resolveHref(origin, hrefText);

      results.add(
        WebDavFile(
          name: name,
          href: href,
          isDirectory: isDir,
          // 「当前目录自身」条目（href path 与请求 URL 相同）：
          // UI 将其作为「返回上级」入口，排序置顶。
          isSelfEntry: _isSelfEntry(hrefText, requestUrl),
          size: _parseSize(response),
          modified: _parseModified(response),
          contentType: _firstText(response, 'getcontenttype'),
        ),
      );
    }

    // 后台列表始终按自然名称排序，保证显示默认顺序与自动切集顺序一致。
    return sortedWebDavFiles(results);
  }

  // ── 私有辅助 ──────────────────────────────────────────────

  /// 判定条目是否为「当前目录自身」（href path 与请求 path 相同）。
  bool _isSelfEntry(String href, String requestUrl) {
    final h = Uri.tryParse(href);
    final r = Uri.tryParse(requestUrl);
    if (h == null || r == null) return false;
    String strip(String s) => s.replaceAll(RegExp(r'/+$'), '');
    final hp = strip(h.path);
    final rp = strip(r.path);
    if (hp.isEmpty || rp.isEmpty) return false;
    return hp == rp;
  }

  /// 取 response 下指定本地名元素的文本（首个非空）。
  String? _firstText(XmlElement response, String localName) {
    for (final e in response.descendants.whereType<XmlElement>()) {
      if (e.localName == localName) {
        final text = e.innerText.trim();
        if (text.isNotEmpty) return text;
      }
    }
    return null;
  }

  bool _hasChild(XmlElement response, String localName) {
    return response.descendants.whereType<XmlElement>().any(
      (e) => e.localName == localName,
    );
  }

  /// 显示名：优先 getdisplayname，否则从 href 末段解码（%20 → 空格）。
  String _resolveName(XmlElement response, String href) {
    final display = _firstText(response, 'getdisplayname');
    if (display != null) return display;
    final trimmed = href.replaceAll(RegExp(r'/+$'), '');
    final lastSegment = trimmed.split('/').last;
    try {
      return Uri.decodeComponent(lastSegment);
    } on ArgumentError {
      return lastSegment;
    }
  }

  int _parseSize(XmlElement response) {
    final raw = _firstText(response, 'getcontentlength');
    if (raw == null) return 0;
    return int.tryParse(raw) ?? 0;
  }

  DateTime? _parseModified(XmlElement response) {
    final raw = _firstText(response, 'getlastmodified');
    if (raw == null) return null;
    // 标准格式如 "Wed, 26 Jun 2024 12:00:00 GMT"。
    try {
      return HttpDate.parse(raw);
    } on FormatException {
      // 兼容 RFC3339 / ISO8601（部分服务器返回）。
      return DateTime.tryParse(raw)?.toUtc();
    } on HttpException {
      // HttpDate.parse 对非 HTTP 格式也抛 HttpException。
      return DateTime.tryParse(raw)?.toUtc();
    }
  }

  /// 提取 requestUrl 的协议+主机部分（origin）。
  String? _originOf(String requestUrl) {
    final uri = Uri.tryParse(requestUrl);
    if (uri == null || uri.host.isEmpty) return null;
    return '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
  }
}
