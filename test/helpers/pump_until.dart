import 'package:flutter_test/flutter_test.dart';

/// 推进帧及真实 I/O，直到被测异步操作发布预期状态。
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
  Duration timeout = const Duration(seconds: 10),
  Duration frameDuration = const Duration(milliseconds: 50),
}) async {
  final elapsed = Stopwatch()..start();
  while (!condition() && elapsed.elapsed < timeout) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(frameDuration);
  }
  expect(condition(), isTrue, reason: reason);
}
