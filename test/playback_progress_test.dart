import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/playback_progress.dart';

/// PlaybackProgress 续播语义测试。
///
/// 回归背景：mpv 对网络流写的 watch_later 常无 `duration=` 行 →
/// SQLite 中 durationMs 为 null；若把「时长未知」误判为「已看完」，
/// 每次播放都会从头开始（历史缺陷）。修复后 duration 缺失必须正常续播。
void main() {
  PlaybackProgress progress({required int positionMs, int? durationMs}) =>
      PlaybackProgress(
        url: 'http://h/dav/01.mp4',
        positionMs: positionMs,
        durationMs: durationMs,
      );

  group('isFinishedNearEnd 已看完判定', () {
    test('时长缺失（null）不视为已看完，应续播', () {
      // mpv 网络流实测场景：无 duration 行。
      final p = progress(positionMs: 3 * 60 * 1000, durationMs: null);
      expect(p.isFinishedNearEnd(), isFalse);
      expect(p.resumeSeconds, 180);
    });

    test('时长为 0 或负数不视为已看完', () {
      expect(
        progress(positionMs: 1000, durationMs: 0).isFinishedNearEnd(),
        isFalse,
      );
      expect(
        progress(positionMs: 1000, durationMs: -1).isFinishedNearEnd(),
        isFalse,
      );
    });

    test('时长已知且位置接近片尾（剩余不足 60s）视为已看完', () {
      final p = progress(
        positionMs: 121 * 60 * 1000,
        durationMs: 122 * 60 * 1000,
      );
      expect(p.isFinishedNearEnd(), isTrue, reason: '剩余 60s 边界（>= 阈值）应为已看完');
    });

    test('时长已知且位置正常（剩余充足）不视为已看完', () {
      final p = progress(
        positionMs: 60 * 60 * 1000,
        durationMs: 122 * 60 * 1000,
      );
      expect(p.isFinishedNearEnd(), isFalse);
    });

    test('剩余恰好 tailGraceMs 时为已看完（边界）', () {
      // position = duration - 60000 时判定为已看完（保守）。
      final p = progress(
        positionMs: 60 * 60 * 1000,
        durationMs: 61 * 60 * 1000,
      );
      expect(p.isFinishedNearEnd(), isTrue);
    });

    test('tailGraceMs 可自定义', () {
      // 剩余 40s。
      final p = progress(positionMs: 200 * 1000, durationMs: 240 * 1000);
      expect(
        p.isFinishedNearEnd(tailGraceMs: 30000),
        isFalse,
        reason: '剩余 40s > 30s 阈值 → 未看完',
      );
      expect(
        p.isFinishedNearEnd(tailGraceMs: 45000),
        isTrue,
        reason: '剩余 40s <= 45s 阈值 → 已看完',
      );
    });
  });

  group('resumeSeconds 续播起点', () {
    test('positionMs <= 0 返回 null（从头播放）', () {
      expect(progress(positionMs: 0, durationMs: 1000).resumeSeconds, isNull);
      expect(progress(positionMs: -5, durationMs: null).resumeSeconds, isNull);
    });

    test('正常位置返回秒数', () {
      expect(
        progress(positionMs: 90 * 1000, durationMs: null).resumeSeconds,
        90,
      );
    });
  });

  group('hasReachedFraction 退出时完成比例判定', () {
    test('达到 99% 视为完成，低于 99% 保留继续播放', () {
      expect(
        progress(positionMs: 99000, durationMs: 100000).hasReachedFraction(),
        isTrue,
      );
      expect(
        progress(positionMs: 98999, durationMs: 100000).hasReachedFraction(),
        isFalse,
      );
    });

    test('时长缺失或无效时不误判完成', () {
      expect(
        progress(positionMs: 99000, durationMs: null).hasReachedFraction(),
        isFalse,
      );
      expect(
        progress(positionMs: 99000, durationMs: 0).hasReachedFraction(),
        isFalse,
      );
    });
  });

  group('hasReachedExitCompletion 退出状态回退', () {
    test('当前位置无效时使用最近一次有效位置判定 99%', () {
      expect(
        hasReachedExitCompletion(
          positionSeconds: -1,
          durationSeconds: -1,
          fallbackPositionSeconds: 99,
          fallbackDurationSeconds: 100,
        ),
        isTrue,
      );
    });

    test('退出瞬间位置回到 0 时使用最近一次有效位置判定 99%', () {
      expect(
        hasReachedExitCompletion(
          positionSeconds: 0,
          durationSeconds: 100,
          fallbackPositionSeconds: 99,
          fallbackDurationSeconds: 100,
        ),
        isTrue,
      );
    });

    test('当前值有效时优先使用当前值', () {
      expect(
        hasReachedExitCompletion(
          positionSeconds: 98,
          durationSeconds: 100,
          fallbackPositionSeconds: 99,
          fallbackDurationSeconds: 100,
        ),
        isFalse,
      );
    });

    test('两组值都无效时不判定完成', () {
      expect(
        hasReachedExitCompletion(
          positionSeconds: -1,
          durationSeconds: 0,
          fallbackPositionSeconds: null,
          fallbackDurationSeconds: null,
        ),
        isFalse,
      );
    });
  });
}
