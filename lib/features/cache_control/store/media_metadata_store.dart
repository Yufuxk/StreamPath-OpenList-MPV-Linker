import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../../core/cache/cache_retention_policy.dart';
import '../../../core/constants.dart';
import '../../../core/utils/cache_expiration.dart';
import '../models/media_metadata.dart';

/// 媒体元数据缓存管理（JSON 文件读写，模块内自包含）。
///
/// 持久化于数据目录 `media_metadata.json`（由集成方传入路径），
/// 结构为 `{ "<url_hash>": <MediaMetadata> }`。
///
/// 容错原则（增强层）：文件缺失/损坏/IO 失败一律视为空缓存，
/// 写失败静默丢弃，绝不抛出、绝不阻断播放链路。
class MediaMetadataStore {
  MediaMetadataStore._(this._file, this._now, this._policyProvider);

  final File _file;
  final DateTime Function() _now;
  final CacheRetentionPolicyProvider _policyProvider;

  /// 缓存文件名（位于数据目录下）。
  static const String fileName = 'media_metadata.json';

  /// 以指定文件路径创建（集成方传入完整路径）。
  static MediaMetadataStore forPath(
    String path, {
    DateTime Function()? now,
    CacheRetentionPolicyProvider? policyProvider,
  }) => MediaMetadataStore._(
    File(path),
    now ?? DateTime.now,
    policyProvider ?? _defaultPolicyProvider,
  );

  Map<String, dynamic>? _cached;
  Future<Map<String, dynamic>>? _loadingFuture;

  static const int maxEntries = 1000;
  static const Duration maxAge = AppConstants.mediaMetadataCacheRetention;

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
        if (CacheExpiration.isExpired(
          lastUsedAt: meta.updatedAt,
          retention: _policyProvider().mediaMetadataRetention,
          now: _now(),
        )) {
          all.remove(urlHash);
          await _persistAll(all);
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

  /// 清空持久化媒体元数据和内存副本。
  Future<bool> clear() => _enqueue(() async {
    try {
      for (final file in [_file, File('${_file.path}.tmp')]) {
        if (await file.exists()) await file.delete();
      }
      _cached = <String, dynamic>{};
      _loadingFuture = null;
      return true;
    } catch (_) {
      return false;
    }
  });

  /// 清除过期、损坏及超出容量上限的元数据，返回移除数量。
  Future<int> purgeExpired({DateTime? now}) => _enqueue(() async {
    try {
      final all = await _loadAll();
      final before = all.length;
      _trim(all, now ?? _now());
      final removed = before - all.length;
      if (removed > 0) await _persistAll(all);
      return removed;
    } catch (_) {
      return 0;
    }
  });

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
      _trim(all, _now());
      await _persistAll(all);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _trim(Map<String, dynamic> all, DateTime now) {
    final retention = _policyProvider().mediaMetadataRetention;
    final entries = <(String, DateTime)>[];
    final removeKeys = <String>[];
    for (final entry in all.entries) {
      final value = entry.value;
      if (value is! Map<String, dynamic>) {
        removeKeys.add(entry.key);
        continue;
      }
      final MediaMetadata meta;
      try {
        meta = MediaMetadata.fromJson(value);
      } catch (_) {
        removeKeys.add(entry.key);
        continue;
      }
      if (meta.urlHash != entry.key ||
          CacheExpiration.isExpired(
            lastUsedAt: meta.updatedAt,
            retention: retention,
            now: now,
          )) {
        removeKeys.add(entry.key);
      } else {
        entries.add((entry.key, meta.updatedAt));
      }
    }
    for (final key in removeKeys) {
      all.remove(key);
    }
    entries.sort((a, b) => a.$2.compareTo(b.$2));
    final overflow = all.length - maxEntries;
    if (overflow > 0) {
      for (final entry in entries.take(overflow)) {
        all.remove(entry.$1);
      }
    }
  }

  Future<void> _persistAll(Map<String, dynamic> all) async {
    await _file.parent.create(recursive: true);
    final body = const JsonEncoder.withIndent('  ').convert(all);
    final temp = File('${_file.path}.tmp');
    await temp.writeAsString(body, flush: true);
    await temp.rename(_file.path);
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

  static CacheRetentionPolicy _defaultPolicyProvider() =>
      const DefaultCacheRetentionPolicy();
}
