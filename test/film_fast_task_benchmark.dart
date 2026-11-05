import 'package:flutter_test/flutter_test.dart';
import 'film_fast_task_test.dart' as fixture;

void main() {
  test(
    'three cold and warm throughput comparisons',
    fixture.runFastTaskBenchmark,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
