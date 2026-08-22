import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:streampath/core/constants.dart';
import 'package:streampath/data/local/directory_cache.dart';
import 'package:streampath/features/cache_expiration/models/cache_expiration_config.dart';
import 'package:streampath/data/models/web_dav_file.dart';

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

  test('只枚举当前来源且带路径元数据的访问快照', () async {
    const entry = WebDavFile(
      name: 'A.mkv',
      href: '/dav/A.mkv',
      isDirectory: false,
    );
    cache.write(
      'source-a-movies',
      const [entry],
      sourceId: 'source-a',
      path: '电影',
    );
    cache.write(
      'source-b-movies',
      const [entry],
      sourceId: 'source-b',
      path: '电影',
    );
    cache.write('legacy', const [entry]);
    await cache.purgeExpired(now: now);

    final snapshots = cache.visitedDirectories('source-a');
    expect(snapshots, hasLength(1));
    expect(snapshots.single.path, '电影');
    expect(snapshots.single.entries.single.name, 'A.mkv');
    expect(cache.visitedDirectories('unknown'), isEmpty);
  });

  test('旧快照仍可浏览但不参与搜索，清理缓存会清空访问型索引', () async {
    const entry = WebDavFile(
      name: 'A.mkv',
      href: '/dav/A.mkv',
      isDirectory: false,
    );
    cache.write('legacy', const [entry]);
    cache.write('searchable', const [entry], sourceId: 'source-a', path: '电影');
    await cache.purgeExpired(now: now);

    expect(cache.read('legacy')?.entries.single.name, 'A.mkv');
    expect(cache.visitedDirectories('source-a'), hasLength(1));

    await cache.clear();
    expect(cache.read('legacy'), isNull);
    expect(cache.visitedDirectories('source-a'), isEmpty);
  });

  test('Hive openBox 失败时初始化降级为未命中', () async {
    await cache.close();
    cache = DirectoryCache(
      now: () => now,
      boxName: 'unavailable_box',
      boxOpener: (_) async => throw FileSystemException('模拟 Hive 打开失败'),
    );

    await expectLater(cache.init(), completes);

    expect(cache.diagnostics().initialized, isFalse);
    expect(cache.read('missing'), isNull);
    expect(cache.visitedDirectories('source-a'), isEmpty);
    expect(await cache.purgeExpired(), 0);
    expect(() => cache.write('ignored', const []), returnsNormally);
  });
}
