import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../models/media_metadata.dart';

/// 媒体元数据缓存管理（JSON 文件读写，模块内自包含）。
///
/// 持久化于数据目录 `media_metadata.json`（由集成方传入路径），
/// 结构为 `{ "<url_hash>": <MediaMetadata> }`。
///
/// 容错原则（增强层）：文件缺失/损坏/IO 失败一律视为空缓存，
/// 写失败静默丢弃，绝不抛出、绝不阻断播放链路。
class MediaMetadataStore {
  MediaMetadataStore._(this._file);

  final File _file;

  /// 缓存文件名（位于数据目录下）。
  static const String fileName = 'media_metadata.json';

  /// 以指定文件路径创建（集成方传入完整路径）。
  static MediaMetadataStore forPath(String path) =>
      MediaMetadataStore._(File(path));

  Map<String, dynamic>? _cached;
  Future<Map<String, dynamic>>? _loadingFuture;

  static const int maxEntries = 1000;
  static const Duration maxAge = Duration(days: 180);

  Future<Map<String, dynamic>> _loadAll() async {
    if (_cached != null) return _cached!;
    final loading = _loadingFuture;
    if (loading != null) return loading;
    final future = _loadAllUncached();
    _loadingFuture = future;
    try {
      return await future;
    } finally {
      if (identical(_loadingFuture, future)) _loadingFuture = null;
    }
  }

  Future<Map<String, dynamic>> _loadAllUncached() async {
    if (!_file.existsSync()) {
      _cached = <String, dynamic>{};
      return _cached!;
    }
    try {
      final raw = await _file.readAsString();
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) {
        _cached = json;
        return _cached!;
      }
    } catch (_) {
      // 损坏/IO 失败：视为空缓存。
    }
    _cached = <String, dynamic>{};
    return _cached!;
  }

  /// 按 URL 哈希读取元数据；未命中或损坏返回 null。
  Future<MediaMetadata?> read(String urlHash) async {
    return _enqueue(() async {
      try {
        final all = await _loadAll();
        final raw = all[urlHash];
        if (raw is! Map<String, dynamic>) return null;
        final meta = MediaMetadata.fromJson(raw);
        if (meta.urlHash.isEmpty || meta.urlHash != urlHash) return null;
        if (DateTime.now().difference(meta.updatedAt) > maxAge) {
          all.remove(urlHash);
          return null;
        }
        return meta;
      } catch (_) {
        return null;
      }
    });
  }

  /// 写入元数据（读-改-写）。
  ///
  /// 通过内部任务队列串行化，避免多播放会话并发写同一 JSON 文件
  /// 造成丢失更新；失败返回 false（不抛出）。
  Future<bool> write(MediaMetadata meta) {
    return _enqueue(() => _writeOne(meta));
  }

  Future<void> _pending = Future<void>.value();

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final task = _pending.then((_) => action());
    _pending = task.then<void>((_) {}, onError: (_) {});
    return task;
  }

  Future<bool> _writeOne(MediaMetadata meta) async {
    try {
      final all = await _loadAll();
      all[meta.urlHash] = meta.toJson();
      if (all.length > maxEntries) {
        final entries = all.entries.toList()
          ..sort((a, b) {
            DateTime updated(MapEntry<String, dynamic> entry) {
              final value = entry.value;
              if (value is Map<String, dynamic>) {
                return MediaMetadata.fromJson(value).updatedAt;
              }
              return DateTime.fromMillisecondsSinceEpoch(0);
            }

            return updated(a).compareTo(updated(b));
          });
        for (final entry in entries.take(all.length - maxEntries)) {
          all.remove(entry.key);
        }
      }
      await _file.parent.create(recursive: true);
      final body = const JsonEncoder.withIndent('  ').convert(all);
      final temp = File('${_file.path}.tmp');
      await temp.writeAsString(body, flush: true);
      await temp.rename(_file.path);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 生成 URL 缓存键：SHA-256 摘要（与存储键一致）。
  static String urlHashOf(String url) {
    var stable = url;
    try {
      final uri = Uri.parse(url);
      const volatileNames = <String>{
        'token',
        'signature',
        'sig',
        'expires',
        'auth',
        'authorization',
      };
      final query = <String, List<String>>{};
      uri.queryParametersAll.forEach((key, value) {
        final lower = key.toLowerCase();
        if (volatileNames.contains(lower) ||
            lower.startsWith('x-amz-') ||
            lower.startsWith('x-oss-')) {
          return;
        }
        query[key] = value;
      });
      stable = uri
          .replace(
            userInfo: '',
            fragment: '',
            queryParameters: query.isEmpty ? null : query,
          )
          .toString();
    } catch (_) {}
    return sha256.convert(utf8.encode(stable)).toString();
  }
}
