import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/features/cache_control/engine/bitrate_estimator.dart';

/// 码率估算器测试（设计文档三级策略）。
void main() {
  const estimator = BitrateEstimator();

  group('Level 1: metadata bit_rate', () {
    test('bps → Mbps 换算', () {
      expect(estimator.estimateFromBitrateBps(12000000), 12.0);
      expect(estimator.estimateFromBitrateBps(8200000), closeTo(8.2, 0.001));
    });

    test('无效值返回 null（0/负/null）', () {
      expect(estimator.estimateFromBitrateBps(null), isNull);
      expect(estimator.estimateFromBitrateBps(0), isNull);
      expect(estimator.estimateFromBitrateBps(-100), isNull);
    });
  });

  group('Level 2: 平均码率 = 大小 × 8 ÷ 时长', () {
    test('文档示例：6.9GB ÷ 7200s ≈ 8.2Mbps', () {
      // 6.9GB ≈ 7,410,000,000 字节（示例值）。
      final result = estimator.estimateFromSizeAndDuration(
        fileSizeBytes: 7410000000,
        durationSec: 7200,
      );
      expect(result, closeTo(8.23, 0.1));
    });

    test('7GB 短视频（高码率）自动放大', () {
      // 7GB ÷ 2700s（45 分钟）≈ 22.2Mbps。
      final result = estimator.estimateFromSizeAndDuration(
        fileSizeBytes: 7 * 1024 * 1024 * 1024,
        durationSec: 2700,
      );
      expect(result, closeTo(22.26, 0.1));
    });

    test('无效输入返回 null', () {
      expect(
        estimator.estimateFromSizeAndDuration(
          fileSizeBytes: null,
          durationSec: 7200,
        ),
        isNull,
      );
      expect(
        estimator.estimateFromSizeAndDuration(
          fileSizeBytes: 100,
          durationSec: 0,
        ),
        isNull,
      );
      expect(
        estimator.estimateFromSizeAndDuration(
          fileSizeBytes: -1,
          durationSec: 7200,
        ),
        isNull,
      );
    });
  });

  group('Level 3: 分辨率估算', () {
    test('文档默认模型表', () {
      expect(estimator.estimateFromResolution('854x480'), 2.0); // 480P
      expect(estimator.estimateFromResolution('1280x720'), 5.0); // 720P
      expect(estimator.estimateFromResolution('1920x1080'), 10.0); // 1080P
      expect(estimator.estimateFromResolution('2560x1440'), 20.0); // 1440P
      expect(estimator.estimateFromResolution('3840x2160'), 35.0); // 4K SDR
    });

    test('超 4K 宽度的保守取值', () {
      expect(estimator.estimateFromResolution('7680x4320'), 35.0);
    });

    test('非法分辨率返回 null', () {
      expect(estimator.estimateFromResolution(null), isNull);
      expect(estimator.estimateFromResolution('abc'), isNull);
      expect(estimator.estimateFromResolution('0x0'), isNull);
      expect(estimator.estimateFromResolution('1920'), isNull);
      expect(estimator.estimateFromResolution(''), isNull);
    });
  });
}
