import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:streampath/core/constants.dart';
import 'package:streampath/data/local/directory_cache.dart';
import 'package:streampath/features/cache_expiration/models/cache_expiration_config.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/data/models/media_library_item.dart';

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

  test('单项续播按来源、规范目录、类型和最新快照读取 href，不延长寿命', () async {
    const item = MediaLibraryItem(
      sourceId: 'a',
      parentPath: 'Shows/Season',
      name: 'e1.mkv',
      kind: MediaLibraryKind.video,
    );
    cache.write(
      'old',
      const [
        WebDavFile(name: 'e1.mkv', href: '/older/e1.mkv', isDirectory: false),
      ],
      sourceId: 'a',
      path: 'Shows/Season',
    );
    await cache.purgeExpired(now: now);
    now = now.add(const Duration(hours: 1));
    cache.write(
      'new',
      const [
        WebDavFile(name: 'e1.mkv', href: '/directory', isDirectory: true),
        WebDavFile(
          name: 'e1.mkv',
          href: '/canonical/e1.mkv',
          isDirectory: false,
        ),
      ],
      sourceId: 'a',
      path: '/Shows\\Season/',
    );
    cache.write(
      'other',
      const [
        WebDavFile(name: 'e1.mkv', href: '/other-source', isDirectory: false),
      ],
      sourceId: 'b',
      path: 'Shows/Season',
    );
    await cache.purgeExpired(now: now);
    for (var i = 0; i < 20; i++) {
      final expected = cache
          .visitedDirectories('a')
          .where(
            (s) => normalizeLibraryPath(s.path) == item.normalizedParentPath,
          )
          .expand((s) => s.entries)
          .where(item.matches)
          .first;
      expect(cache.visitedFile(item)!.toCacheMap(), expected.toCacheMap());
      expect(cache.visitedFile(item)!.href, '/canonical/e1.mkv');
    }
    now = now
        .add(AppConstants.directoryCacheRetention)
        .add(const Duration(milliseconds: 1));
    expect(cache.visitedFile(item), isNull);
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

  test('批量目录快照归还事件循环，保持内容、排序、隔离与过期规则', () async {
    cache.write(
      'large',
      [
        for (var i = 0; i < 20000; i++)
          WebDavFile(name: 'e$i.mkv', href: '/e$i.mkv', isDirectory: false),
      ],
      sourceId: 'a',
      path: 'old',
    );
    await cache.purgeExpired(now: now);
    now = now.add(const Duration(hours: 1));
    cache.write('new', const [], sourceId: 'a', path: 'new');
    cache.write('other', const [], sourceId: 'b', path: 'other');
    await cache.purgeExpired(now: now);
    final expected = cache.visitedDirectories('a');
    var yielded = false;
    final timer = Timer(Duration.zero, () => yielded = true);
    final actual = await cache.visitedDirectoriesAsync('a');
    timer.cancel();
    expect(yielded, isTrue);
    expect(actual.map((s) => s.path), expected.map((s) => s.path));
    expect(
      actual.expand((s) => s.entries).map((e) => e.toCacheMap()),
      expected.expand((s) => s.entries).map((e) => e.toCacheMap()),
    );
    expect(
      actual.map((s) => s.lastAccessedAt),
      expected.map((s) => s.lastAccessedAt),
    );
    now = now
        .add(AppConstants.directoryCacheRetention)
        .add(const Duration(milliseconds: 1));
    expect(await cache.visitedDirectoriesAsync('a'), isEmpty);
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
