import 'dart:async';
import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/domain/services/player_process_controller.dart';

void main() {
  const pid = 4242;
  final expected = PlayerProcessIdentity(
    pid: pid,
    executablePath: r'C:\MPV\mpv.exe',
    creationTime: 133700000000000000,
  );

  PlayerProcessController controllerFor({
    required PlayerProcessLookupResult lookup,
    int? pipeOwnerPid = pid,
    required void Function() onTerminate,
  }) => PlayerProcessController(
    snapshotLoader: (_) async => lookup,
    pipeServerPidLoader: (_) async => pipeOwnerPid,
    processTreeTerminator: (_) async {
      onTerminate();
      return true;
    },
  );

  test('PID、创建时间、exe 与 pipe 全部匹配时只终止一次', () async {
    var terminateCalls = 0;
    final controller = controllerFor(
      lookup: PlayerProcessLookupResult.found(
        PlayerProcessIdentity(
          pid: pid,
          executablePath: r'c:/mpv/mpv.exe',
          creationTime: expected.creationTime,
        ),
      ),
      onTerminate: () => terminateCalls++,
    );

    final outcome = await controller.terminateIfOwned(
      pid: pid,
      expected: expected,
      ipcPipeName: r'\\.\pipe\streampath-test',
      requirePipeOwner: true,
    );

    expect(outcome, PlayerTerminationOutcome.terminated);
    expect(terminateCalls, 1);
  });

  test('默认终止边界在租约释放前完成终止，闭合最终 PID 复用窗口', () async {
    final events = <String>[];
    var leaseOpen = true;
    final controller = PlayerProcessController(
      leaseLoader: (_) async => PlayerProcessLeaseLookupResult.found(
        PlayerProcessLease(
          identity: expected,
          recheck: () async {
            expect(leaseOpen, isTrue);
            events.add('recheck');
            return PlayerProcessLookupResult.found(expected);
          },
          terminateTree: () async {
            expect(leaseOpen, isTrue);
            events.add('terminate');
            return PlayerTerminationOutcome.terminated;
          },
          close: () {
            events.add('close');
            leaseOpen = false;
          },
        ),
      ),
      pipeServerPidLoader: (_) async {
        expect(leaseOpen, isTrue);
        events.add('pipe');
        return pid;
      },
    );

    final outcome = await controller.terminateIfOwned(
      pid: pid,
      expected: expected,
      ipcPipeName: r'\\.\pipe\streampath-test',
      requirePipeOwner: true,
    );

    expect(outcome, PlayerTerminationOutcome.terminated);
    expect(events, ['pipe', 'recheck', 'terminate', 'close']);
    expect(leaseOpen, isFalse);
  });

  test('PID 被非 MPV 进程复用时不调用终止器', () async {
    var terminateCalls = 0;
    final controller = controllerFor(
      lookup: PlayerProcessLookupResult.found(
        PlayerProcessIdentity(
          pid: pid,
          executablePath: r'C:\Windows\System32\notepad.exe',
          creationTime: expected.creationTime + 1,
        ),
      ),
      onTerminate: () => terminateCalls++,
    );

    final outcome = await controller.terminateIfOwned(
      pid: pid,
      expected: expected,
      ipcPipeName: r'\\.\pipe\streampath-test',
      requirePipeOwner: true,
    );

    expect(outcome, PlayerTerminationOutcome.refused);
    expect(terminateCalls, 0);
  });

  test('PID 被另一目录的 MPV 复用时不调用终止器', () async {
    var terminateCalls = 0;
    final controller = controllerFor(
      lookup: PlayerProcessLookupResult.found(
        PlayerProcessIdentity(
          pid: pid,
          executablePath: r'D:\OtherMPV\mpv.exe',
          creationTime: expected.creationTime,
        ),
      ),
      onTerminate: () => terminateCalls++,
    );

    final outcome = await controller.terminateIfOwned(
      pid: pid,
      expected: expected,
      ipcPipeName: r'\\.\pipe\streampath-test',
      requirePipeOwner: true,
    );

    expect(outcome, PlayerTerminationOutcome.refused);
    expect(terminateCalls, 0);
  });

  test('同一路径 MPV 的创建时间变化时不调用终止器', () async {
    var terminateCalls = 0;
    final controller = controllerFor(
      lookup: PlayerProcessLookupResult.found(
        PlayerProcessIdentity(
          pid: pid,
          executablePath: expected.executablePath,
          creationTime: expected.creationTime + 1,
        ),
      ),
      onTerminate: () => terminateCalls++,
    );

    final outcome = await controller.terminateIfOwned(
      pid: pid,
      expected: expected,
      ipcPipeName: r'\\.\pipe\streampath-test',
      requirePipeOwner: true,
    );

    expect(outcome, PlayerTerminationOutcome.refused);
    expect(terminateCalls, 0);
  });

  test('pipe 服务 PID 与历史 PID 不一致时不调用终止器', () async {
    var terminateCalls = 0;
    final controller = controllerFor(
      lookup: PlayerProcessLookupResult.found(expected),
      pipeOwnerPid: pid + 1,
      onTerminate: () => terminateCalls++,
    );

    final outcome = await controller.terminateIfOwned(
      pid: pid,
      expected: expected,
      ipcPipeName: r'\\.\pipe\streampath-test',
      requirePipeOwner: true,
    );

    expect(outcome, PlayerTerminationOutcome.refused);
    expect(terminateCalls, 0);
  });

  test('pipe 核验后的身份二次读取不匹配时不调用终止器', () async {
    var snapshotCalls = 0;
    var terminateCalls = 0;
    final controller = PlayerProcessController(
      snapshotLoader: (_) async {
        snapshotCalls++;
        return PlayerProcessLookupResult.found(
          snapshotCalls == 1
              ? expected
              : PlayerProcessIdentity(
                  pid: pid,
                  executablePath: expected.executablePath,
                  creationTime: expected.creationTime + 1,
                ),
        );
      },
      pipeServerPidLoader: (_) async => pid,
      processTreeTerminator: (_) async {
        terminateCalls++;
        return true;
      },
    );

    final outcome = await controller.terminateIfOwned(
      pid: pid,
      expected: expected,
      ipcPipeName: r'\\.\pipe\streampath-test',
      requirePipeOwner: true,
    );

    expect(outcome, PlayerTerminationOutcome.refused);
    expect(snapshotCalls, 2);
    expect(terminateCalls, 0);
  });

  test('身份查询失败或旧记录缺少身份时不调用终止器', () async {
    for (final lookup in [
      const PlayerProcessLookupResult.failed(),
      PlayerProcessLookupResult.found(expected),
    ]) {
      var terminateCalls = 0;
      final controller = controllerFor(
        lookup: lookup,
        onTerminate: () => terminateCalls++,
      );

      final outcome = await controller.terminateIfOwned(
        pid: pid,
        expected: lookup.status == PlayerProcessLookupStatus.failed
            ? expected
            : null,
        ipcPipeName: r'\\.\pipe\streampath-test',
        requirePipeOwner: true,
      );

      expect(
        outcome,
        lookup.status == PlayerProcessLookupStatus.failed
            ? PlayerTerminationOutcome.failed
            : PlayerTerminationOutcome.refused,
      );
      expect(terminateCalls, 0);
    }
  });

  test('进程已退出时允许安全收敛且不调用终止器', () async {
    var terminateCalls = 0;
    final controller = controllerFor(
      lookup: const PlayerProcessLookupResult.notFound(),
      onTerminate: () => terminateCalls++,
    );

    final outcome = await controller.terminateIfOwned(
      pid: pid,
      expected: null,
      ipcPipeName: r'\\.\pipe\streampath-test',
      requirePipeOwner: true,
    );

    expect(outcome, PlayerTerminationOutcome.alreadyExited);
    expect(terminateCalls, 0);
  });

  test('所有权探活明确区分存活、退出、身份丢失和查询未知', () async {
    for (final scenario in <(PlayerProcessLookupResult, PlayerProcessLiveness)>[
      (PlayerProcessLookupResult.found(expected), PlayerProcessLiveness.alive),
      (
        const PlayerProcessLookupResult.notFound(),
        PlayerProcessLiveness.exited,
      ),
      (const PlayerProcessLookupResult.failed(), PlayerProcessLiveness.unknown),
      (
        PlayerProcessLookupResult.found(
          PlayerProcessIdentity(
            pid: pid,
            executablePath: r'C:\Other\mpv.exe',
            creationTime: expected.creationTime + 1,
          ),
        ),
        PlayerProcessLiveness.exited,
      ),
    ]) {
      final controller = controllerFor(lookup: scenario.$1, onTerminate: () {});

      expect(await controller.probeOwned(expected), scenario.$2);
    }

    final controller = controllerFor(
      lookup: PlayerProcessLookupResult.found(expected),
      onTerminate: () {},
    );
    expect(
      await controller.probeOwned(null),
      PlayerProcessLiveness.unknown,
      reason: '缺少启动时捕获的完整身份时不得按裸 PID 宣称所有权',
    );
  });

  test('同一会话的并发探活合并为一次查询', () async {
    final lookup = Completer<PlayerProcessLookupResult>();
    var lookupCalls = 0;
    final controller = PlayerProcessController(
      snapshotLoader: (_) {
        lookupCalls++;
        return lookup.future;
      },
    );
    final tracker = PlayerProcessLivenessTracker(
      controller: controller,
      expectedIdentity: expected,
    );

    final probes = [tracker.probe(), tracker.probe(), tracker.probe()];
    expect(lookupCalls, 1);
    lookup.complete(PlayerProcessLookupResult.found(expected));

    expect(
      await Future.wait(probes),
      everyElement(PlayerProcessLiveness.alive),
    );
    expect(tracker.probeCount, 1);
    expect(tracker.nextProbeDelay, const Duration(seconds: 2));
  });

  test('sample 完成后记录调度时间并在健康间隔内复用结果', () async {
    var lookupCalls = 0;
    final controller = PlayerProcessController(
      snapshotLoader: (_) async {
        lookupCalls++;
        return PlayerProcessLookupResult.found(expected);
      },
    );
    final tracker = PlayerProcessLivenessTracker(
      controller: controller,
      expectedIdentity: expected,
      healthyProbeInterval: const Duration(hours: 1),
    );

    expect(await tracker.sample(), PlayerProcessLiveness.alive);
    expect(await tracker.sample(), PlayerProcessLiveness.alive);
    expect(lookupCalls, 1);
    expect(tracker.probeCount, 1);
  });

  test('sample 对 unknown 结果也遵守退避时间', () async {
    var lookupCalls = 0;
    final controller = PlayerProcessController(
      snapshotLoader: (_) async {
        lookupCalls++;
        return const PlayerProcessLookupResult.failed();
      },
    );
    final tracker = PlayerProcessLivenessTracker(
      controller: controller,
      expectedIdentity: expected,
      unknownInitialDelay: const Duration(hours: 1),
      unknownMaxDelay: const Duration(hours: 1),
    );

    expect(await tracker.sample(), PlayerProcessLiveness.unknown);
    expect(await tracker.sample(), PlayerProcessLiveness.unknown);
    expect(lookupCalls, 1);
    expect(tracker.nextProbeDelay, const Duration(hours: 1));
  });

  test('连续 unknown 使用有限指数退避且不改写确切所有权', () async {
    var lookupCalls = 0;
    final controller = PlayerProcessController(
      snapshotLoader: (_) async {
        lookupCalls++;
        return const PlayerProcessLookupResult.failed();
      },
    );
    final tracker = PlayerProcessLivenessTracker(
      controller: controller,
      expectedIdentity: expected,
    );
    final delays = <Duration?>[];

    for (var attempt = 0; attempt < 5; attempt++) {
      expect(await tracker.probe(), PlayerProcessLiveness.unknown);
      delays.add(tracker.nextProbeDelay);
    }

    expect(lookupCalls, 5);
    expect(tracker.probeCount, 5);
    expect(delays, const [
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 16),
      null,
    ]);
    expect(tracker.unknownRetryExhausted, isTrue);
    expect(tracker.expectedIdentity, same(expected));
    expect(tracker.isConservativelyRunning, isTrue);

    await tracker.probe();
    await tracker.probe();
    expect(lookupCalls, 5, reason: 'unknown 达到上限后不再发起查询');
  });

  test('单一 watcher 在 unknown 退避上限后停止且重复消费者共享结果', () async {
    var lookupCalls = 0;
    final controller = PlayerProcessController(
      snapshotLoader: (_) async {
        lookupCalls++;
        return const PlayerProcessLookupResult.failed();
      },
    );
    final tracker = PlayerProcessLivenessTracker(
      controller: controller,
      expectedIdentity: expected,
    );
    final delays = <Duration>[];

    final first = tracker.watch(
      delay: (duration) async => delays.add(duration),
    );
    final second = tracker.watch(
      delay: (duration) async => fail('重复 watcher 不应创建第二条延迟链'),
    );

    expect(second, same(first));
    expect(await first, PlayerProcessLiveness.unknown);
    expect(lookupCalls, 5);
    expect(delays, const [
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 16),
    ]);
  });

  test('Windows 默认快照读取当前进程的绝对路径和精确创建时间', () async {
    if (!io.Platform.isWindows) return;

    final identity = await PlayerProcessController().capture(io.pid);

    expect(identity, isNotNull);
    expect(identity!.pid, io.pid);
    expect(identity.executablePath, isNotEmpty);
    expect(identity.isComplete, isTrue);
    expect(identity.creationTime, greaterThan(0));
  });
}
