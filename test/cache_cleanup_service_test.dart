import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/domain/services/cache_cleanup_service.dart';

void main() {
  late Directory tempRoot;
  late Directory dataDir;
  late Directory cacheDir;
  late Directory configDir;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('cache_cleanup_service_');
    dataDir = Directory(p.join(tempRoot.path, 'stream_path_data'));
    cacheDir = Directory(p.join(dataDir.path, 'cache'));
    configDir = Directory(p.join(dataDir.path, 'config'));
    await cacheDir.create(recursive: true);
    await configDir.create(recursive: true);
  });

  tearDown(() async {
    if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
  });

  test('清空新布局缓存和旧平铺残留，同时保留配置与打开的存储文件', () async {
    final configFile = File(p.join(configDir.path, 'stream_path_config.json'));
    final hiveFile = File(p.join(cacheDir.path, 'directory_cache.hive'));
    final databaseFile = File(p.join(cacheDir.path, 'streampath.db'));
    final runtimeFile = File(p.join(cacheDir.path, 'mpv-current-test.txt'));
    final runtimeDir = Directory(p.join(cacheDir.path, 'mpv-watch-later'));
    final learningFile = File(
      p.join(cacheDir.path, 'cache_intelligence_learning.json'),
    );
    final legacyFile = File(p.join(dataDir.path, 'playback_history.json'));
    final unrelatedRootFile = File(p.join(dataDir.path, '用户文件.txt'));
    await configFile.writeAsString('config');
    await hiveFile.writeAsString('hive');
    await databaseFile.writeAsString('db');
    await runtimeFile.writeAsString('runtime');
    await runtimeDir.create();
    await File(p.join(runtimeDir.path, 'record')).writeAsString('watch');
    await learningFile.writeAsString('learning');
    await legacyFile.writeAsString('legacy');
    await unrelatedRootFile.writeAsString('keep');

    var storeClearCalls = 0;
    final service = CacheCleanupService(
      dataDirectoryProvider: () async => dataDir,
      preservedCacheNames: const {'cache_intelligence_learning.json'},
      storeClearers: [
        () async {
          storeClearCalls++;
          await hiveFile.writeAsString('');
        },
        () async {
          storeClearCalls++;
          await databaseFile.writeAsString('');
        },
      ],
    );

    final result = await service.clear();

    expect(storeClearCalls, 2);
    expect(result.clearedStores, 2);
    expect(await configFile.readAsString(), 'config');
    expect(await hiveFile.exists(), isTrue);
    expect(await hiveFile.length(), 0);
    expect(await databaseFile.exists(), isTrue);
    expect(await databaseFile.length(), 0);
    expect(await runtimeFile.exists(), isFalse);
    expect(await runtimeDir.exists(), isFalse);
    expect(await learningFile.readAsString(), 'learning');
    expect(await legacyFile.exists(), isFalse);
    expect(await unrelatedRootFile.readAsString(), 'keep');
  });

  test('单独清理学习数据时不删除其他缓存文件', () async {
    final learningFile = File(
      p.join(cacheDir.path, 'cache_intelligence_learning.json'),
    );
    final otherCache = File(p.join(cacheDir.path, 'media_metadata.json'));
    await learningFile.writeAsString('learning');
    await otherCache.writeAsString('metadata');
    final service = CacheCleanupService(
      dataDirectoryProvider: () async => dataDir,
      deleteRuntimeFiles: false,
      storeClearers: [() async => learningFile.delete()],
    );

    await service.clear();

    expect(await learningFile.exists(), isFalse);
    expect(await otherCache.readAsString(), 'metadata');
  });

  test('拒绝清理名称不匹配的目录', () async {
    final invalidDir = Directory(p.join(tempRoot.path, 'other_data'));
    await invalidDir.create();
    final service = CacheCleanupService(
      dataDirectoryProvider: () async => invalidDir,
      storeClearers: const [],
    );

    await expectLater(service.clear(), throwsA(isA<CacheCleanupException>()));
  });
}
