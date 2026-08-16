import 'dart:collection';

import 'cache_expiration.dart';

/// 按空闲时间过期、按最近访问顺序淘汰的有界内存缓存。
class ExpiringLruCache<K, V> {
  ExpiringLruCache({
    required this.maxEntries,
    required this.idleTtl,
    this.idleTtlProvider,
    DateTime Function()? now,
  }) : assert(maxEntries > 0),
       assert(!idleTtl.isNegative),
       _now = now ?? DateTime.now;

  final int maxEntries;
  final Duration idleTtl;
  final Duration Function()? idleTtlProvider;
  final DateTime Function() _now;
  final LinkedHashMap<K, _ExpiringLruEntry<V>> _entries = LinkedHashMap();

  int get length => _entries.length;

  /// 读取并刷新最近访问顺序；未命中或过期返回 null。
  V? read(K key) {
    final entry = _entries.remove(key);
    if (entry == null) return null;
    final now = _now();
    if (CacheExpiration.isExpired(
      lastUsedAt: entry.lastAccessedAt,
      retention: _currentIdleTtl,
      now: now,
    )) {
      return null;
    }
    entry.lastAccessedAt = CacheExpiration.monotonicAccessTime(
      now,
      entry.lastAccessedAt,
    );
    _entries[key] = entry;
    return entry.value;
  }

  /// 写入或覆盖条目，并同步执行 O(1) 的容量淘汰。
  void write(K key, V value) {
    _entries.remove(key);
    _entries[key] = _ExpiringLruEntry(value, _now());
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// 清除当前已经过期的条目，返回清除数量。
  int purgeExpired() {
    final now = _now();
    final retention = _currentIdleTtl;
    final expiredKeys = <K>[];
    for (final entry in _entries.entries) {
      if (CacheExpiration.isExpired(
        lastUsedAt: entry.value.lastAccessedAt,
        retention: retention,
        now: now,
      )) {
        expiredKeys.add(entry.key);
      }
    }
    for (final key in expiredKeys) {
      _entries.remove(key);
    }
    return expiredKeys.length;
  }

  void clear() => _entries.clear();

  Duration get _currentIdleTtl => idleTtlProvider?.call() ?? idleTtl;
}

class _ExpiringLruEntry<V> {
  _ExpiringLruEntry(this.value, this.lastAccessedAt);

  final V value;
  DateTime lastAccessedAt;
}
