/// 缓存过期判定的纯函数集合。
abstract final class CacheExpiration {
  /// [lastUsedAt] 距 [now] 超过 [retention] 时返回 true。
  ///
  /// 系统时钟回拨会让时间差为负，此时保守保留数据，避免误删。
  static bool isExpired({
    required DateTime lastUsedAt,
    required Duration retention,
    DateTime? now,
  }) {
    final elapsed = (now ?? DateTime.now()).difference(lastUsedAt);
    return !elapsed.isNegative && elapsed > retention;
  }

  /// 返回不会早于 [lastUsedAt] 的访问时间，避免时钟回拨缩短寿命。
  static DateTime monotonicAccessTime(DateTime now, DateTime lastUsedAt) =>
      now.isBefore(lastUsedAt) ? lastUsedAt : now;
}
