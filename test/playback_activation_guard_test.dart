import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/domain/services/playback_activation_guard.dart';

void main() {
  test('启动等待期间每 1 秒最多探测一次', () {
    final guard = PlaybackActivationGuard();
    final start = DateTime.utc(2026, 1, 1);
    guard.start(now: start, timeout: const Duration(seconds: 60));

    expect(guard.shouldProbe(start), isTrue);
    guard.recordProbe(now: start, running: false);
    expect(
      guard.shouldProbe(start.add(const Duration(milliseconds: 999))),
      isFalse,
    );
    expect(guard.shouldProbe(start.add(const Duration(seconds: 1))), isTrue);
    expect(guard.lastKnownRunning, isFalse);
  });

  test('60 秒内保持等待，达到期限后超时', () {
    final guard = PlaybackActivationGuard();
    final start = DateTime.utc(2026, 1, 1);
    guard.start(now: start, timeout: const Duration(seconds: 60));

    expect(guard.isWaiting, isTrue);
    expect(guard.hasTimedOut(start.add(const Duration(seconds: 59))), isFalse);
    expect(guard.hasTimedOut(start.add(const Duration(seconds: 60))), isTrue);
  });

  test('收到有效播放状态后取消启动超时', () {
    final guard = PlaybackActivationGuard();
    final start = DateTime.utc(2026, 1, 1);
    guard.start(now: start, timeout: const Duration(seconds: 60));
    guard.confirmActivation();

    expect(guard.isActivated, isTrue);
    expect(guard.isWaiting, isFalse);
    expect(guard.hasTimedOut(start.add(const Duration(minutes: 2))), isFalse);
  });
}
