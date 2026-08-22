import 'dart:async';

import 'package:hive/hive.dart';
import 'package:meta/meta.dart';

import '../../core/cache/cache_retention_policy.dart';
import '../../core/constants.dart';
import '../../core/utils/cache_expiration.dart';
import '../models/web_dav_file.dart';

typedef DirectoryCacheBoxOpener = Future<Box<Map>> Function(String boxName);

/// 目录元数据快照（缓存读取结果）。
class CacheSnapshot {
  const CacheSnapshot({
    required this.entries,
    required this.cachedAt,
    DateTime? lastAccessedAt,
    this.sourceId,
    this.path,
  }) : lastAccessedAt = lastAccessedAt ?? cachedAt;

  final List<WebDavFile> entries;
  final DateTime cachedAt;
  final DateTime lastAccessedAt;

  /// 匿名连接来源标识；旧版快照可能缺失。
  final String? sourceId;

  /// 相对 WebDAV 根目录的路径；旧版快照可能缺失。
  final String? path;
}

/// 可供访问型全局搜索使用的目录快照。
class VisitedDirectorySnapshot {
  const VisitedDirectorySnapshot({
    required this.path,
    required this.entries,
    required this.lastAccessedAt,
  });

  final String path;
  final List<WebDavFile> entries;
  final DateTime lastAccessedAt;
}

class DirectoryCacheDiagnostics {
  const DirectoryCacheDiagnostics({
    required this.initialized,
    required this.entryCount,
  });

  final bool initialized;
  final int entryCount;
}

/// Hive 目录元数据缓存。
///
/// 以服务器档案隔离的规范化 URL 为 key，存储 PROPFIND 解析结果 + 缓存时间戳，
/// 配合 [isFresh] 实现 TTL 失效与 stale-while-revalidate：
///  - 未过期 → 直接返回，目录"秒开"；
///  - 已过期 → 先返回旧数据渲染，后台拉新后覆盖。
///
/// 读接口为同步（Hive 内存映射读取极快），UI 首帧即可拿到数据。
class DirectoryCache {
  static const _boxName = 'directory_cache';

  DirectoryCache({
    DateTime Function()? now,
    String boxName = _boxName,
    CacheRetentionPolicyProvider? policyProvider,
    DirectoryCacheBoxOpener? boxOpener,
  }) : _now = now ?? DateTime.now,
       _policyProvider = policyProvider ?? _defaultPolicyProvider,
       _boxOpener = boxOpener ?? _openBox,
       _resolvedBoxName = boxName;

  Box<Map>? _box;
  final DateTime Function() _now;
  final CacheRetentionPolicyProvider _policyProvider;
  final DirectoryCacheBoxOpener _boxOpener;
  final String _resolvedBoxName;
  Future<void> _pending = Future<void>.value();

  /// 打开缓存箱（应用启动时调用一次）。
  Future<void> init() async {
    try {
      _box = await _boxOpener(_resolvedBoxName);
    } catch (_) {
      // Hive 文件不可用时降级为无缓存，基础浏览仍可启动。
      _box = null;
      return;
    }
    try {
      await purgeExpired();
    } catch (_) {
      // 自动维护失败只会降低缓存命中率，不能阻止应用启动。
    }
  }

  /// 同步读取缓存；无缓存或数据损坏时返回 null。
  CacheSnapshot? read(String key) {
    final box = _box;
    if (box == null) return null;
    final raw = box.get(key);
    if (raw is! Map) return null;

    final entriesRaw = raw['entries'];
    if (entriesRaw is! List) return null;

    try {
      final entries = entriesRaw
          .whereType<Map>()
          .map(WebDavFile.fromCacheMap)
          .toList();
      final cachedAtMs = raw['cachedAt'];
      if (cachedAtMs is! int) return null;
      final cachedAt = DateTime.fromMillisecondsSinceEpoch(cachedAtMs);
      final lastAccessedAtMs = raw['lastAccessedAt'];
      final lastAccessedAt = lastAccessedAtMs is int
          ? DateTime.fromMillisecondsSinceEpoch(lastAccessedAtMs)
          : cachedAt;
      final now = _now();
      if (CacheExpiration.isExpired(
        lastUsedAt: lastAccessedAt,
        retention: _policyProvider().directoryRetention,
        now: now,
      )) {
        final observedAccessMs = lastAccessedAtMs is int
            ? lastAccessedAtMs
            : cachedAtMs;
        _scheduleDeleteIfStillExpired(key, observedAccessMs, now);
        return null;
      }
      _scheduleTouch(key, lastAccessedAt, now);
      return CacheSnapshot(
        entries: entries,
        cachedAt: cachedAt,
        lastAccessedAt: CacheExpiration.monotonicAccessTime(
          now,
          lastAccessedAt,
        ),
        sourceId: raw['sourceId'] as String?,
        path: raw['path'] as String?,
      );
    } catch (_) {
      // 单条缓存损坏不应影响浏览，忽略并视为未命中。
      return null;
    }
  }

  /// 写入缓存（同步，Hive 内部异步落盘）。
  void write(
    String key,
    List<WebDavFile> entries, {
    String? sourceId,
    String? path,
  }) {
    final box = _box;
    if (box == null) return;
    final nowMs = _now().millisecondsSinceEpoch;
    final serializedEntries = entries.map((e) => e.toCacheMap()).toList();
    _scheduleMutation(() async {
      await box.put(key, <String, dynamic>{
        'entries': serializedEntries,
        'cachedAt': nowMs,
        'lastAccessedAt': nowMs,
        'sourceId': ?sourceId,
        'path': ?path,
      });
      if (box.length > AppConstants.maxDirectoryCacheEntries) {
        await _prune(box, _now());
      }
    });
  }

  /// 枚举当前连接已访问的未过期目录快照。
  ///
  /// 该读取不刷新访问时间，全局搜索不会因枚举行为延长缓存寿命。
  List<VisitedDirectorySnapshot> visitedDirectories(String sourceId) {
    final box = _box;
    if (box == null || sourceId.isEmpty) return const [];
    final now = _now();
    final snapshots = <VisitedDirectorySnapshot>[];
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw is! Map || raw['sourceId'] != sourceId) continue;
      final path = raw['path'];
      final entriesRaw = raw['entries'];
      final cachedAtMs = raw['cachedAt'];
      final accessMs = raw['lastAccessedAt'] ?? cachedAtMs;
      if (path is! String ||
          entriesRaw is! List ||
          cachedAtMs is! int ||
          accessMs is! int) {
        continue;
      }
      try {
        final lastAccessedAt = DateTime.fromMillisecondsSinceEpoch(accessMs);
        if (CacheExpiration.isExpired(
          lastUsedAt: lastAccessedAt,
          retention: _policyProvider().directoryRetention,
          now: now,
        )) {
          continue;
        }
        snapshots.add(
          VisitedDirectorySnapshot(
            path: path,
            entries: entriesRaw
                .whereType<Map>()
                .map(WebDavFile.fromCacheMap)
                .toList(growable: false),
            lastAccessedAt: lastAccessedAt,
          ),
        );
      } catch (_) {
        // 单个快照损坏时跳过，不影响其他搜索结果。
      }
    }
    snapshots.sort(
      (left, right) => right.lastAccessedAt.compareTo(left.lastAccessedAt),
    );
    return snapshots;
  }

  /// 清空全部目录快照，并保持 Hive 箱可继续使用。
  Future<void> clear() async {
    final box = _box;
    if (box == null) throw StateError('目录缓存尚未初始化');
    await _enqueue(() async {
      await box.clear();
      await box.flush();
    });
  }

  /// 删除空闲超时、损坏和超过容量上限的目录快照。
  Future<int> purgeExpired({DateTime? now}) {
    final box = _box;
    if (box == null) return Future<int>.value(0);
    return _enqueue(() => _prune(box, now ?? _now()));
  }

  DirectoryCacheDiagnostics diagnostics() => DirectoryCacheDiagnostics(
    initialized: _box != null,
    entryCount: _box?.length ?? 0,
  );

  /// TTL 内是否视为新鲜。
  bool isFresh(CacheSnapshot snapshot) => !CacheExpiration.isExpired(
    lastUsedAt: snapshot.cachedAt,
    retention: _policyProvider().directoryFreshness,
    now: _now(),
  );

  @visibleForTesting
  Future<void> close() async {
    await _pending;
    await _box?.close();
    _box = null;
  }

  void _scheduleTouch(String key, DateTime lastAccessedAt, DateTime now) {
    if (now.difference(lastAccessedAt) <
        AppConstants.directoryCacheTouchInterval) {
      return;
    }
    _scheduleMutation(() async {
      final box = _box;
      final current = box?.get(key);
      if (box == null || current is! Map) return;
      final currentAccessMs = current['lastAccessedAt'] ?? current['cachedAt'];
      if (currentAccessMs is! int) return;
      final currentAccess = DateTime.fromMillisecondsSinceEpoch(
        currentAccessMs,
      );
      final touchedAt = CacheExpiration.monotonicAccessTime(now, currentAccess);
      if (touchedAt == currentAccess) return;
      await box.put(key, <String, dynamic>{
        ...Map<dynamic, dynamic>.from(current),
        'lastAccessedAt': touchedAt.millisecondsSinceEpoch,
      });
    });
  }

  void _scheduleDeleteIfStillExpired(
    String key,
    int observedAccessMs,
    DateTime now,
  ) {
    _scheduleMutation(() async {
      final box = _box;
      final current = box?.get(key);
      if (box == null || current is! Map) return;
      final currentAccessMs = current['lastAccessedAt'] ?? current['cachedAt'];
      if (currentAccessMs != observedAccessMs) return;
      final currentAccess = DateTime.fromMillisecondsSinceEpoch(
        observedAccessMs,
      );
      if (CacheExpiration.isExpired(
        lastUsedAt: currentAccess,
        retention: _policyProvider().directoryRetention,
        now: now,
      )) {
        await box.delete(key);
      }
    });
  }

  Future<int> _prune(Box<Map> box, DateTime now) async {
    final retention = _policyProvider().directoryRetention;
    final retained = <(dynamic, DateTime, int)>[];
    final deleteKeys = <dynamic>[];
    var scanOrder = 0;
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw is! Map || raw['entries'] is! List || raw['cachedAt'] is! int) {
        deleteKeys.add(key);
        continue;
      }
      final accessMs = raw['lastAccessedAt'] ?? raw['cachedAt'];
      if (accessMs is! int) {
        deleteKeys.add(key);
        continue;
      }
      final lastAccessedAt = DateTime.fromMillisecondsSinceEpoch(accessMs);
      if (CacheExpiration.isExpired(
        lastUsedAt: lastAccessedAt,
        retention: retention,
        now: now,
      )) {
        deleteKeys.add(key);
      } else {
        retained.add((key, lastAccessedAt, scanOrder));
      }
      scanOrder++;
    }

    retained.sort((a, b) {
      final byAccess = b.$2.compareTo(a.$2);
      return byAccess != 0 ? byAccess : b.$3.compareTo(a.$3);
    });
    if (retained.length > AppConstants.maxDirectoryCacheEntries) {
      deleteKeys.addAll(
        retained
            .skip(AppConstants.maxDirectoryCacheEntries)
            .map((entry) => entry.$1),
      );
    }
    if (deleteKeys.isNotEmpty) {
      await box.deleteAll(deleteKeys);
      await box.flush();
    }
    return deleteKeys.length;
  }

  void _scheduleMutation(Future<void> Function() action) {
    final pending = _enqueue(action);
    // 缓存落盘失败不能形成未处理异常或阻断浏览。
    unawaited(pending.catchError((Object _) {}));
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final task = _pending.then((_) => action());
    _pending = task.then<void>((_) {}, onError: (_) {});
    return task;
  }

  static CacheRetentionPolicy _defaultPolicyProvider() =>
      const DefaultCacheRetentionPolicy();

  static Future<Box<Map>> _openBox(String boxName) =>
      Hive.openBox<Map>(boxName);
}
