import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/core/constants.dart';
import 'package:streampath/core/utils/cache_expiration.dart';
import 'package:streampath/core/utils/expiring_lru_cache.dart';

void main() {
  group('CacheExpiration', () {
    test('边界时刻仍有效，超过边界才过期', () {
      final lastUsedAt = DateTime.utc(2026, 1, 1);
      const retention = Duration(minutes: 30);

      expect(
        CacheExpiration.isExpired(
          lastUsedAt: lastUsedAt,
          retention: retention,
          now: lastUsedAt.add(retention),
        ),
        isFalse,
      );
      expect(
        CacheExpiration.isExpired(
          lastUsedAt: lastUsedAt,
          retention: retention,
          now: lastUsedAt.add(retention).add(const Duration(milliseconds: 1)),
        ),
        isTrue,
      );
    });

    test('系统时钟回拨时不误删缓存', () {
      final lastUsedAt = DateTime.utc(2026, 1, 2);
      expect(
        CacheExpiration.isExpired(
          lastUsedAt: lastUsedAt,
          retention: const Duration(minutes: 1),
          now: DateTime.utc(2026, 1, 1),
        ),
        isFalse,
      );
      expect(
        CacheExpiration.monotonicAccessTime(
          DateTime.utc(2026, 1, 1),
          lastUsedAt,
        ),
        lastUsedAt,
      );
    });

    test('学习缓存明确没有自动过期时间', () {
      expect(AppConstants.cacheLearningRetention, isNull);
    });
  });

  group('ExpiringLruCache', () {
    test('读取会刷新 LRU，容量满时淘汰最久未访问条目', () {
      var now = DateTime.utc(2026, 1, 1);
      final cache = ExpiringLruCache<String, int>(
        maxEntries: 2,
        idleTtl: const Duration(hours: 1),
        now: () => now,
      );

      cache.write('a', 1);
      now = now.add(const Duration(minutes: 1));
      cache.write('b', 2);
      now = now.add(const Duration(minutes: 1));
      expect(cache.read('a'), 1);
      cache.write('c', 3);

      expect(cache.read('b'), isNull);
      expect(cache.read('a'), 1);
      expect(cache.read('c'), 3);
      expect(cache.length, 2);
    });

    test('空闲超时后读取即清除，时钟回拨不会缩短后续寿命', () {
      var now = DateTime.utc(2026, 1, 2);
      final cache = ExpiringLruCache<String, int>(
        maxEntries: 2,
        idleTtl: const Duration(minutes: 30),
        now: () => now,
      )..write('item', 1);

      now = DateTime.utc(2026, 1, 1);
      expect(cache.read('item'), 1);
      now = DateTime.utc(2026, 1, 2, 0, 30, 0, 1);
      expect(cache.read('item'), isNull);
      expect(cache.length, 0);
    });

    test('外部配置修改后，后续读取使用新的空闲时间', () {
      var now = DateTime.utc(2026, 1, 1);
      var ttl = const Duration(hours: 1);
      final cache = ExpiringLruCache<String, int>(
        maxEntries: 2,
        idleTtl: ttl,
        idleTtlProvider: () => ttl,
        now: () => now,
      )..write('item', 1);

      now = now.add(const Duration(minutes: 20));
      ttl = const Duration(minutes: 10);
      expect(cache.read('item'), isNull);
    });
  });
}
