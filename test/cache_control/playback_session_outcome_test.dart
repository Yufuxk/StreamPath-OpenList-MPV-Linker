import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/features/cache_control/monitor/playback_monitor.dart';
import 'package:streampath/features/cache_control/providers/system_memory_provider.dart';

void main() {
  test('监控器以 O(1) 聚合卡顿、拖动、暂停、速度和完成状态', () async {
    final dir = Directory.systemTemp.createTempSync('cache_outcome_');
    final file = File('${dir.path}${Platform.pathSeparator}status.txt');
    final monitor =
        PlaybackMonitor(
          memoryProvider: const _Memory(),
          interval: const Duration(seconds: 5),
          logger: (_) {},
        )..start(
          statusFilePath: file.path,
          initialDemuxerMaxBytes: 512 * 1024 * 1024,
          initialCacheSecs: 120,
          bitrateMbps: 20,
        );

    Future<void> sample({
      required double position,
      String paused = '0',
      String pausedForCache = '0',
      double speedBps = 2000000,
    }) async {
      await file.writeAsString(
        '0\nhttp://host/video.mkv\n$paused\n$position\n100\n100\n'
        '$speedBps\n0\ndiag\n$pausedForCache\n0\n0\n1920x1080\n',
        flush: true,
      );
      await monitor.sampleOnce();
    }

    await sample(position: 10);
    await sample(position: 50, pausedForCache: '1');
    await sample(position: 20);
    await sample(position: 98, paused: '1');

    final outcome = monitor.snapshotOutcome();
    expect(outcome.sampleCount, 4);
    expect(outcome.stallCount, 1);
    expect(outcome.forwardSeekCount, 2);
    expect(outcome.backwardSeekCount, 1);
    expect(outcome.pausedSampleCount, 1);
    expect(outcome.meanNetworkSpeedBps, 2000000);
    expect(outcome.completed, isTrue);
    expect(outcome.durationSec, 100);

    monitor.stop();
    dir.deleteSync(recursive: true);
  });
}

class _Memory extends SystemMemoryProvider {
  const _Memory();

  @override
  Future<int?> availableMemoryBytes() async => 8 * 1024 * 1024 * 1024;
}
