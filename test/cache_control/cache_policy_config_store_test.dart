import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/features/cache_control/models/cache_policy_config.dart';
import 'package:streampath/features/cache_control/store/cache_policy_config_store.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('sp_cache_cfg_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  CachePolicyConfigStore storeFor(String name) =>
      CachePolicyConfigStore.forPath(
        '${tempDir.path}${Platform.pathSeparator}$name',
      );

  group('CachePolicyConfig 默认值', () {
    test('默认配置：启用、auto 模式、标准预算与档位', () {
      final def = CachePolicyConfig.defaults();
      expect(def.enabled, isTrue);
      expect(def.mode, CachePolicyMode.auto);
      expect(def.memoryBudgetRatio, 0.25);
      expect(def.baseCacheSecs, 120);
      expect(def.smallFileThresholdMB, 500);
      expect(def.assumedBandwidthMbps, isNull);
      expect(def.overrideUserCacheArgs, isFalse);
    });

    test('JSON 往返保持全部字段', () {
      const config = CachePolicyConfig(
        enabled: false,
        mode: CachePolicyMode.remux,
        memoryBudgetRatio: 0.3,
        baseCacheSecs: 180,
        smallFileThresholdMB: 1024,
        assumedBandwidthMbps: 200.5,
        overrideUserCacheArgs: true,
      );
      final restored = CachePolicyConfig.fromJson(config.toJson());
      expect(restored.enabled, isFalse);
      expect(restored.mode, CachePolicyMode.remux);
      expect(restored.memoryBudgetRatio, 0.3);
      expect(restored.baseCacheSecs, 180);
      expect(restored.smallFileThresholdMB, 1024);
      expect(restored.assumedBandwidthMbps, 200.5);
      expect(restored.overrideUserCacheArgs, isTrue);
    });

    test('未知 mode 回退 auto', () {
      final config = CachePolicyConfig.fromJson(const {'mode': 'turbo'});
      expect(config.mode, CachePolicyMode.auto);
    });
  });

  group('CachePolicyConfig 非法值收敛', () {
    test('越界数值收敛到边界而非默认', () {
      final config = CachePolicyConfig.fromJson(const {
        'memoryBudgetRatio': 0.99,
        'baseCacheSecs': 3,
        'smallFileThresholdMB': -5,
      });
      expect(config.memoryBudgetRatio, CachePolicyConfig.maxMemoryBudgetRatio);
      expect(config.baseCacheSecs, CachePolicyConfig.minBaseCacheSecs);
      expect(
        config.smallFileThresholdMB,
        CachePolicyConfig.minSmallFileThresholdMB,
      );
    });

    test('下限越界也收敛到边界', () {
      final config = CachePolicyConfig.fromJson(const {
        'memoryBudgetRatio': 0.01,
        'baseCacheSecs': 99999,
        'smallFileThresholdMB': 99999,
      });
      expect(config.memoryBudgetRatio, CachePolicyConfig.minMemoryBudgetRatio);
      expect(config.baseCacheSecs, CachePolicyConfig.maxBaseCacheSecs);
      expect(
        config.smallFileThresholdMB,
        CachePolicyConfig.maxSmallFileThresholdMB,
      );
    });

    test('非数值字段回退默认', () {
      final config = CachePolicyConfig.fromJson(const {
        'enabled': 'yes',
        'memoryBudgetRatio': 'big',
        'baseCacheSecs': null,
        'smallFileThresholdMB': {},
        'assumedBandwidthMbps': -1,
        'overrideUserCacheArgs': 'yes',
      });
      expect(config.enabled, isTrue);
      expect(config.memoryBudgetRatio, 0.25);
      expect(config.baseCacheSecs, 120);
      expect(config.smallFileThresholdMB, 500);
      expect(config.assumedBandwidthMbps, isNull);
      expect(config.overrideUserCacheArgs, isFalse);
    });

    test('assumedBandwidthMbps 仅接受正数', () {
      final zero = CachePolicyConfig.fromJson(const {
        'assumedBandwidthMbps': 0,
      });
      expect(zero.assumedBandwidthMbps, isNull);

      final ok = CachePolicyConfig.fromJson(const {'assumedBandwidthMbps': 50});
      expect(ok.assumedBandwidthMbps, 50.0);
    });
  });

  group('CachePolicyConfigStore 读写', () {
    test('文件不存在时回退默认配置', () async {
      final store = storeFor('missing.json');
      final config = await store.load();
      expect(config, isA<CachePolicyConfig>());
      expect(config.enabled, isTrue);
      expect(config, same(store.current));
    });

    test('ensureDefault：不存在时创建默认配置文件', () async {
      final path =
          '${tempDir.path}${Platform.pathSeparator}ensure_default.json';
      expect(File(path).existsSync(), isFalse);
      final store = CachePolicyConfigStore.forPath(path);
      await store.ensureDefault();
      expect(File(path).existsSync(), isTrue, reason: '应创建默认配置');
      final loaded = CachePolicyConfigStore.forPath(path);
      final config = await loaded.load();
      expect(config.enabled, isTrue);
      expect(config.mode, CachePolicyMode.auto);
    });

    test('ensureDefault：已存在（含用户修改）不覆盖', () async {
      final path = '${tempDir.path}${Platform.pathSeparator}ensure_keep.json';
      const custom = CachePolicyConfig(mode: CachePolicyMode.performance);
      await CachePolicyConfigStore.forPath(path).save(custom);
      await CachePolicyConfigStore.forPath(path).ensureDefault();
      final loaded = CachePolicyConfigStore.forPath(path);
      final config = await loaded.load();
      expect(config.mode, CachePolicyMode.performance, reason: '用户修改不应被默认值覆盖');
    });

    test('保存后重新加载一致', () async {
      final store = storeFor('cache_policy.json');
      const config = CachePolicyConfig(
        enabled: true,
        mode: CachePolicyMode.economy,
        memoryBudgetRatio: 0.2,
        baseCacheSecs: 60,
        smallFileThresholdMB: 200,
        assumedBandwidthMbps: 100,
        overrideUserCacheArgs: false,
      );
      expect(await store.save(config), isTrue);

      final fresh = CachePolicyConfigStore.forPath(
        '${tempDir.path}${Platform.pathSeparator}cache_policy.json',
      );
      final loaded = await fresh.load();
      expect(loaded.enabled, isTrue);
      expect(loaded.mode, CachePolicyMode.economy);
      expect(loaded.memoryBudgetRatio, 0.2);
      expect(loaded.baseCacheSecs, 60);
      expect(loaded.smallFileThresholdMB, 200);
      expect(loaded.assumedBandwidthMbps, 100);
    });

    test('同一 Store 实例每次 load 重读用户编辑，重新播放即可生效', () async {
      final path = '${tempDir.path}${Platform.pathSeparator}hot_edit.json';
      final store = CachePolicyConfigStore.forPath(path);
      await store.save(CachePolicyConfig.defaults());
      expect((await store.load()).enabled, isTrue);

      File(path).writeAsStringSync('{"enabled": false, "baseCacheSecs": 60}');
      final edited = await store.load();
      expect(edited.enabled, isFalse);
      expect(edited.baseCacheSecs, 60);
    });

    test('损坏 JSON 回退默认且不抛出', () async {
      final path = '${tempDir.path}${Platform.pathSeparator}broken.json';
      File(path).writeAsStringSync('{not json!!!');
      final store = CachePolicyConfigStore.forPath(path);
      final config = await store.load();
      expect(config.enabled, isTrue);
      expect(config.mode, CachePolicyMode.auto);
    });

    test('根节点非对象回退默认', () async {
      final path = '${tempDir.path}${Platform.pathSeparator}list.json';
      File(path).writeAsStringSync('[1, 2, 3]');
      final store = CachePolicyConfigStore.forPath(path);
      final config = await store.load();
      expect(config.mode, CachePolicyMode.auto);
    });

    test('保存到非法路径返回 false 且不抛出', () async {
      final store = CachePolicyConfigStore.forPath(
        '${tempDir.path}${Platform.pathSeparator}sub${Platform.pathSeparator}dir${Platform.pathSeparator}x.json',
      );
      // 用一个文件占用父路径，使 create(recursive) 失败。
      final blocker = File('${tempDir.path}${Platform.pathSeparator}sub')
        ..writeAsStringSync('occupied');
      expect(await store.save(CachePolicyConfig.defaults()), isFalse);
      expect(blocker.existsSync(), isTrue);
    });

    test('配置内容可被用户编辑的部分字段忽略未知键', () async {
      final path = '${tempDir.path}${Platform.pathSeparator}extra.json';
      File(path).writeAsStringSync(
        '{"enabled": false, "mode": "remux", "futureField": 42}',
      );
      final store = CachePolicyConfigStore.forPath(path);
      final config = await store.load();
      expect(config.enabled, isFalse);
      expect(config.mode, CachePolicyMode.remux);
    });
  });
}
