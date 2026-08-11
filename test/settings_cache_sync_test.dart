import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/features/cache_control/models/cache_intelligence_config.dart';
import 'package:streampath/features/cache_control/models/cache_policy_config.dart';
import 'package:streampath/features/cache_control/store/cache_intelligence_config_store.dart';
import 'package:streampath/features/cache_control/store/cache_policy_config_store.dart';

/// 设置页依赖的两个缓存配置存储同步契约。
///
/// 页面进入/刷新调用 load，保存调用 save；此测试保证手工编辑与界面保存
/// 使用同一个持久化来源，不会被旧内存状态覆盖。
void main() {
  test('基础缓存与智能缓存配置可独立保存并重读手工修改', () async {
    final dir = Directory.systemTemp.createTempSync('settings_cache_sync_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final cacheFile = File(
      '${dir.path}${Platform.pathSeparator}cache_policy.json',
    );
    final intelligenceFile = File(
      '${dir.path}${Platform.pathSeparator}cache_intelligence.json',
    );
    final cacheStore = CachePolicyConfigStore.forPath(cacheFile.path);
    final intelligenceStore = CacheIntelligenceConfigStore.forPath(
      intelligenceFile.path,
    );

    expect(
      await cacheStore.save(
        const CachePolicyConfig(memoryBudgetRatio: 0.33, baseCacheSecs: 150),
      ),
      isTrue,
    );
    expect(
      await intelligenceStore.save(
        const CacheIntelligenceConfig(minSamples: 7, maxAdjustmentRatio: 0.15),
      ),
      isTrue,
    );
    expect((await cacheStore.load()).baseCacheSecs, 150);
    expect((await intelligenceStore.load()).minSamples, 7);

    // 模拟用户在软件外手工编辑配置文件，页面刷新时必须读到新值。
    await cacheFile.writeAsString(
      jsonEncode(
        const CachePolicyConfig(
          memoryBudgetRatio: 0.40,
          baseCacheSecs: 180,
        ).toJson(),
      ),
      flush: true,
    );
    await intelligenceFile.writeAsString(
      jsonEncode(
        const CacheIntelligenceConfig(
          applyOptimizations: true,
          minSamples: 9,
        ).toJson(),
      ),
      flush: true,
    );

    final refreshedCache = await cacheStore.load();
    final refreshedIntelligence = await intelligenceStore.load();
    expect(refreshedCache.baseCacheSecs, 180);
    expect(refreshedCache.memoryBudgetRatio, 0.40);
    expect(refreshedIntelligence.minSamples, 9);
    expect(refreshedIntelligence.applyOptimizations, isTrue);
  });
}
