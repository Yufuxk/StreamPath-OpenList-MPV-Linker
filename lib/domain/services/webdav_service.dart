import 'dart:async';

import '../../core/errors/app_exception.dart';
import '../../core/utils/strm_parser.dart';
import '../../core/utils/url_utils.dart' as url_utils;
import '../../data/local/directory_cache.dart';
import '../../data/models/web_dav_file.dart';
import '../../data/remote/webdav_client.dart';
import '../../data/remote/webdav_xml_parser.dart';
import '../repositories/directory_repository.dart';

/// 目录浏览业务服务：编排 缓存 → 网络 → 解析 全链路。
///
/// 性能策略（"秒开"三要素）：
///  1. **Hive 缓存**：新鲜缓存同步读直接返回，零网络等待；
///  2. **stale-while-revalidate**：缓存过期时先返回旧数据渲染，
///     同时后台拉新并写回缓存（[fetchDirectory]）；
///  3. **请求合并**：同一路径的并发请求共享同一个 Future，
///     避免列表滚动时重复 PROPFIND（[._inFlight]）。
class WebDAVService implements DirectoryRepository {
  WebDAVService({
    required this._client,
    DirectoryCache? cache,
    WebDavXmlParser? parser,
  }) : _cache = cache ?? DirectoryCache(),
       _parser = parser ?? const WebDavXmlParser();

  final WebDavClient _client;
  final DirectoryCache _cache;
  final WebDavXmlParser _parser;

  /// 正在进行的加载（key → Future），用于请求合并。
  final Map<String, Future<List<WebDavFile>>> _inFlight = {};

  /// 正在进行的用户强制刷新（key → Future）。
  ///
  /// 强制刷新与普通加载分开记录：同目录的连续刷新会合并，但若已有
  /// 普通/后台加载，则等待其结束后再真正发起一次新的网络请求。
  final Map<String, Future<List<WebDavFile>>> _refreshInFlight = {};

  /// 获取目录内容：秒开优先。
  ///
  ///  - 缓存新鲜 → 直接返回缓存；
  ///  - 缓存过期 → 先返回旧数据，后台刷新；
  ///  - 无缓存 → 发起 PROPFIND 并写缓存。
  @override
  Future<List<WebDavFile>> fetchDirectory(
    String path, {
    bool forceRefresh = false,
  }) async {
    if (forceRefresh) return refreshDirectory(path);
    final key = _key(path);
    final snapshot = _cache.read(key);

    if (snapshot != null) {
      if (_cache.isFresh(snapshot)) return snapshot.entries;
      // 过期：立即渲染旧数据 + 后台刷新（不阻塞 UI）。
      unawaited(
        _loadAndCache(key, path).then<void>((_) {}).catchError((Object e) {
          // 后台刷新失败静默处理：下次访问或手动刷新会重试。
          if (e is AppException) {
            // ignore: avoid_print
            print('后台刷新目录失败：$e');
          }
        }),
      );
      return snapshot.entries;
    }
    return _loadAndCache(key, path);
  }

  /// 强制从网络加载并刷新缓存（用户下拉/点击刷新时调用）。
  Future<List<WebDavFile>> refreshDirectory(String path) {
    final key = _key(path);
    final pending = _refreshInFlight[key];
    if (pending != null) return pending;

    final refresh = _refreshAfterCurrentLoad(key, path);
    _refreshInFlight[key] = refresh;
    return refresh;
  }

  /// 同步读取缓存内容（UI 首帧秒开用，不检查新鲜度）。
  @override
  List<WebDavFile>? cachedDirectory(String path) =>
      _cache.read(_key(path))?.entries;

  /// 将服务器返回的 href 解析为可播放的完整 URL。
  @override
  String resolveUrl(String href) => url_utils.resolveHref(baseUrl, href);

  /// 解析 .strm 流指针文件指向的媒体地址。
  ///
  /// 读取文件文本并提取首个有效 URL 行，相对地址基于 [baseUrl] 补全；
  /// 仅接受与服务器**同源**的地址（防止凭据随媒体请求泄露给第三方），
  /// 内容超过 [maxContentBytes] 视为异常。任何失败返回 null，
  /// 由调用方跳过该条目。
  Future<String?> fetchStrmUrl(WebDavFile strmFile) async {
    try {
      final content = await _client.getFileContent(strmFile.href);
      if (content.length > maxContentBytes) return null;
      final raw = parseStrmUrl(content);
      if (raw == null) return null;
      final resolved = url_utils.resolveHref(baseUrl, raw);
      if (!url_utils.isSameOrigin(baseUrl, resolved)) return null;
      return resolved;
    } catch (_) {
      // 网络/解析等任何失败均视为不可解析。
      return null;
    }
  }

  /// strm 指针文件内容读取上限（字节）。
  static const int maxContentBytes = 8192;

  /// 拼接请求路径（baseUrl + path）。
  String fullUrl(String path) => url_utils.joinUrl(baseUrl, path);

  /// 服务器根地址。
  @override
  String get baseUrl => _client.baseUrl;

  // ── 内部 ─────────────────────────────────────────────────────

  String _key(String path) =>
      url_utils.cacheKeyFor(baseUrl: baseUrl, path: path);

  /// 等待同目录旧请求收尾后再执行强制刷新。
  ///
  /// 旧实现会先把缓存写成空列表，并复用正在进行的旧请求；一旦该请求
  /// 失败或返回过时数据，空缓存会被当作新鲜结果保留，刷新也无法真正
  /// 重新请求。这里保留最后一次成功缓存，只有新请求成功后才覆盖。
  Future<List<WebDavFile>> _refreshAfterCurrentLoad(
    String key,
    String path,
  ) async {
    try {
      final current = _inFlight[key];
      if (current != null) {
        try {
          await current;
        } catch (_) {
          // 旧请求失败不影响用户主动刷新，继续发起新请求。
        }
      }
      return await _loadAndCache(key, path);
    } finally {
      _refreshInFlight.remove(key);
    }
  }

  /// 网络加载 + 写缓存；同 key 并发调用共享同一 Future。
  Future<List<WebDavFile>> _loadAndCache(String key, String path) {
    return _inFlight.putIfAbsent(key, () async {
      try {
        final xml = await _client.propfind(path);
        final files = _parser.parse(xml, requestUrl: fullUrl(path));
        _cache.write(key, files);
        return files;
      } finally {
        _inFlight.remove(key);
      }
    });
  }
}
