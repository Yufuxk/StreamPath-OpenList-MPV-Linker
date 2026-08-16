import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:streampath/core/constants.dart';
import 'package:streampath/data/local/directory_cache.dart';
import 'package:streampath/features/cache_expiration/models/cache_expiration_config.dart';

void main() {
  late Directory tempDir;
  late DateTime now;
  late DirectoryCache cache;
  late CacheExpirationConfig policy;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('directory_cache_');
    Hive.init(tempDir.path);
    now = DateTime.utc(2026, 1, 1);
    policy = CacheExpirationConfig.defaults();
    cache = DirectoryCache(
      now: () => now,
      policyProvider: () => policy,
      boxName: 'directory_cache_${DateTime.now().microsecondsSinceEpoch}',
    );
    await cache.init();
  });

  tearDown(() async {
    await cache.close();
    await Hive.close();
    tempDir.deleteSync(recursive: true);
  });

  test('目录快照超过空闲保留期后不再返回', () async {
    cache.write('old', const []);
    await cache.purgeExpired(now: now);

    now = now
        .add(AppConstants.directoryCacheRetention)
        .add(const Duration(milliseconds: 1));
    expect(cache.read('old'), isNull);
    await cache.purgeExpired(now: now);
  });

  test('读取会刷新空闲时间，但不会改变内容新鲜时间', () async {
    cache.write('active', const []);
    await cache.purgeExpired(now: now);

    now = now.add(const Duration(days: 29));
    final accessed = cache.read('active');
    expect(accessed, isNotNull);
    expect(cache.isFresh(accessed!), isFalse);
    await cache.purgeExpired(now: now);

    now = now.add(const Duration(days: 29));
    expect(cache.read('active'), isNotNull);
  });

  test('超过容量时按最后访问时间保留最近目录', () async {
    for (var i = 0; i <= AppConstants.maxDirectoryCacheEntries; i++) {
      cache.write('directory-$i', const []);
    }
    await cache.purgeExpired(now: now);

    expect(cache.read('directory-0'), isNull);
    expect(
      cache.read('directory-${AppConstants.maxDirectoryCacheEntries}'),
      isNotNull,
    );
  });

  test('运行中修改目录保留时间后，后续读取立即使用新策略', () async {
    cache.write('configurable', const []);
    await cache.purgeExpired(now: now);
    now = now.add(const Duration(days: 2));

    policy = const CacheExpirationConfig(directoryRetentionDays: 1);
    expect(cache.read('configurable'), isNull);
  });
}
