import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/features/cache_control/models/cache_intelligence_config.dart';
import 'package:streampath/features/cache_control/store/cache_intelligence_config_store.dart';

void main() {
  late Directory tempDir;
  late File file;
  late CacheIntelligenceConfigStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('cache_int_cfg_');
    file = File('${tempDir.path}${Platform.pathSeparator}intelligence.json');
    store = CacheIntelligenceConfigStore.forPath(file.path);
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  test('默认配置为影子模式', () {
    final config = CacheIntelligenceConfig.defaults();
    expect(config.enabled, isTrue);
    expect(config.applyOptimizations, isFalse);
    expect(config.minSamples, 5);
    expect(config.maxAdjustmentRatio, 0.20);
  });

  test('非法数值收敛到安全边界', () {
    final config = CacheIntelligenceConfig.fromJson(const {
      'minSamples': 1,
      'maxAdjustmentRatio': 0.9,
    });
    expect(config.minSamples, CacheIntelligenceConfig.minMinSamples);
    expect(
      config.maxAdjustmentRatio,
      CacheIntelligenceConfig.maxMaxAdjustmentRatio,
    );
  });

  test('保存、手工编辑后同一实例 load 会重读文件', () async {
    expect(
      await store.save(
        const CacheIntelligenceConfig(applyOptimizations: true, minSamples: 8),
      ),
      isTrue,
    );
    expect((await store.load()).minSamples, 8);

    await file.writeAsString(
      jsonEncode(<String, dynamic>{
        ...CacheIntelligenceConfig.defaults().toJson(),
        'applyOptimizations': false,
        'minSamples': 12,
      }),
      flush: true,
    );
    final reloaded = await store.load();
    expect(reloaded.applyOptimizations, isFalse);
    expect(reloaded.minSamples, 12);
  });

  test('损坏文件回退默认且不抛异常', () async {
    await file.writeAsString('{broken');
    final config = await store.load();
    expect(config.applyOptimizations, isFalse);
    expect(config.enabled, isTrue);
  });
}
