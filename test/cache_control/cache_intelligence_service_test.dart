import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/features/cache_control/intelligence/cache_intelligence_service.dart';
import 'package:streampath/features/cache_control/intelligence/storage_classifier.dart';
import 'package:streampath/features/cache_control/models/cache_intelligence_config.dart';
import 'package:streampath/features/cache_control/models/cache_learning_data.dart';
import 'package:streampath/features/cache_control/store/cache_intelligence_config_store.dart';
import 'package:streampath/features/cache_control/store/cache_intelligence_learning_store.dart';

void main() {
  group('StorageClassifier', () {
    const classifier = StorageClassifier();

    test('识别本地、局域网、签名云地址和普通远程地址', () {
      expect(classifier.classify(r'C:\video\01.mkv'), CacheStorageType.local);
      expect(
        classifier.classify('http://192.168.1.8:5244/dav/01.mkv'),
        CacheStorageType.lan,
      );
      expect(
        classifier.classify('https://cdn.example/video.mkv?X-Amz-Signature=x'),
        CacheStorageType.cloud,
      );
      expect(
        classifier.classify('https://media.example/video.mkv'),
        CacheStorageType.remote,
      );
    });

    test('来源摘要不受路径和查询参数影响', () {
      expect(
        classifier.originHash('https://media.example/a.mkv?token=1'),
        classifier.originHash('https://media.example/b.mkv?token=2'),
      );
    });
  });

  group('LocalCacheIntelligenceService', () {
    late Directory tempDir;
    late File learningFile;
    late CacheIntelligenceConfigStore configStore;
    late LocalCacheIntelligenceService service;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('cache_intelligence_');
      learningFile = File(
        '${tempDir.path}${Platform.pathSeparator}learning.json',
      );
      configStore = CacheIntelligenceConfigStore.forPath(
        '${tempDir.path}${Platform.pathSeparator}config.json',
      );
      service = LocalCacheIntelligenceService(
        configStore: configStore,
        learningStore: CacheIntelligenceLearningStore.forPath(
          learningFile.path,
        ),
      );
    });

    tearDown(() => tempDir.deleteSync(recursive: true));

    test('历史码率达到样本数后预测；影子模式不标记应用', () async {
      await configStore.save(const CacheIntelligenceConfig(minSamples: 2));
      const url = 'https://media.example/library/01.mkv';
      await service.observeBitrate(
        url: url,
        bitrateMbps: 20,
        fileSizeBytes: 4 * 1024 * 1024 * 1024,
        resolution: '1920x1080',
      );
      await service.observeBitrate(
        url: url,
        bitrateMbps: 24,
        fileSizeBytes: 4 * 1024 * 1024 * 1024,
        resolution: '1920x1080',
      );

      final advice = await service.advise(
        url: 'https://media.example/library/02.mkv',
        baseCacheSecs: 120,
        fileSizeBytes: 4 * 1024 * 1024 * 1024,
        resolution: '1920x1080',
      );
      expect(advice.applyOptimizations, isFalse);
      expect(advice.predictedBitrateMbps, closeTo(23.414, 0.01));
      expect(advice.reasonCodes, contains('shadow-mode'));
    });

    test('应用模式的修正受最大比例硬裁剪', () async {
      await configStore.save(
        const CacheIntelligenceConfig(
          applyOptimizations: true,
          storageOptimizationEnabled: true,
          habitLearningEnabled: false,
          minSamples: 2,
          maxAdjustmentRatio: 0.05,
        ),
      );
      const url = 'https://slow.example/video.mkv';
      const stalled = PlaybackSessionOutcome(
        sampleCount: 20,
        stallCount: 3,
        forwardSeekCount: 0,
        backwardSeekCount: 0,
        pausedSampleCount: 0,
        meanNetworkSpeedBps: 1000000,
        completed: false,
      );
      await service.observeSession(url: url, outcome: stalled);
      await service.observeSession(url: url, outcome: stalled);

      final advice = await service.advise(
        url: url,
        baseCacheSecs: 120,
        currentBitrateMbps: 20,
      );
      expect(advice.applyOptimizations, isTrue);
      expect(advice.suggestedBaseCacheSecs, 126);
      expect(advice.reasonCodes, contains('source-stall-rate-high'));
    });

    test('学习文件不保存原始 URL、路径或查询令牌', () async {
      await configStore.save(const CacheIntelligenceConfig(minSamples: 2));
      const secretUrl =
          'https://private.example/secret/movie.mkv?token=very-secret';
      await service.observeSession(
        url: secretUrl,
        outcome: const PlaybackSessionOutcome(
          sampleCount: 2,
          stallCount: 0,
          forwardSeekCount: 0,
          backwardSeekCount: 0,
          pausedSampleCount: 0,
          completed: true,
        ),
      );
      final raw = await learningFile.readAsString();
      expect(raw, isNot(contains('private.example')));
      expect(raw, isNot(contains('secret')));
      expect(raw, isNot(contains('movie.mkv')));
    });
  });
}
