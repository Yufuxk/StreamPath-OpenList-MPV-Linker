import 'dart:async';

import 'package:hive/hive.dart';

import '../../core/constants.dart';
import '../models/web_dav_file.dart';

/// 目录元数据快照（缓存读取结果）。
class CacheSnapshot {
  const CacheSnapshot({required this.entries, required this.cachedAt});

  final List<WebDavFile> entries;
  final DateTime cachedAt;
}

/// Hive 目录元数据缓存。
///
/// 以规范化 URL 为 key，存储 PROPFIND 解析结果 + 缓存时间戳，
/// 配合 [isFresh] 实现 TTL 失效与 stale-while-revalidate：
///  - 未过期 → 直接返回，目录"秒开"；
///  - 已过期 → 先返回旧数据渲染，后台拉新后覆盖。
///
/// 读接口为同步（Hive 内存映射读取极快），UI 首帧即可拿到数据。
class DirectoryCache {
  static const _boxName = 'directory_cache';

  Box<Map>? _box;

  /// 打开缓存箱（应用启动时调用一次）。
  Future<void> init() async {
    _box = await Hive.openBox<Map>(_boxName);
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
      return CacheSnapshot(
        entries: entries,
        cachedAt: DateTime.fromMillisecondsSinceEpoch(cachedAtMs),
      );
    } catch (_) {
      // 单条缓存损坏不应影响浏览，忽略并视为未命中。
      return null;
    }
  }

  /// 写入缓存（同步，Hive 内部异步落盘）。
  void write(String key, List<WebDavFile> entries) {
    final box = _box;
    if (box == null) return;
    try {
      final pending = box.put(key, <String, dynamic>{
        'entries': entries.map((e) => e.toCacheMap()).toList(),
        'cachedAt': DateTime.now().millisecondsSinceEpoch,
      });
      // 缓存只是目录浏览优化，异步落盘失败不能形成未处理异常。
      unawaited(pending.catchError((Object _) {}));
    } catch (_) {
      // Hive key/存储异常不能阻断已经成功取得的网络目录结果。
    }
  }

  /// TTL 内是否视为新鲜。
  bool isFresh(CacheSnapshot snapshot) =>
      DateTime.now().difference(snapshot.cachedAt) <=
      AppConstants.directoryCacheTtl;
}
