import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/domain/services/session_progress_sync_coordinator.dart';

void main() {
  test('新代次同步一定在已开始的旧同步之后提交', () async {
    final coordinator = SessionProgressSyncCoordinator();
    final oldGeneration = coordinator.claim('same-session');
    final oldStarted = Completer<void>();
    final releaseOld = Completer<void>();
    final order = <String>[];
    final oldSync = coordinator.run<void>(
      sessionId: 'same-session',
      generation: oldGeneration,
      action: () async {
        oldStarted.complete();
        await releaseOld.future;
        order.add('old');
      },
    );
    await oldStarted.future;

    final newGeneration = coordinator.claim('same-session');
    final newSync = coordinator.run<void>(
      sessionId: 'same-session',
      generation: newGeneration,
      action: () async => order.add('new'),
    );
    releaseOld.complete();
    await Future.wait([oldSync, newSync]);

    expect(order, ['old', 'new']);
  });

  test('已排队但未开始的旧代次同步会被丢弃', () async {
    final coordinator = SessionProgressSyncCoordinator();
    final oldGeneration = coordinator.claim('same-session');
    final blockerStarted = Completer<void>();
    final releaseBlocker = Completer<void>();
    final executed = <String>[];
    final blocker = coordinator.run<void>(
      sessionId: 'same-session',
      generation: oldGeneration,
      action: () async {
        blockerStarted.complete();
        await releaseBlocker.future;
      },
    );
    await blockerStarted.future;
    final stale = coordinator.run<void>(
      sessionId: 'same-session',
      generation: oldGeneration,
      action: () async => executed.add('stale'),
    );
    final newGeneration = coordinator.claim('same-session');
    final current = coordinator.run<void>(
      sessionId: 'same-session',
      generation: newGeneration,
      action: () async => executed.add('current'),
    );

    releaseBlocker.complete();
    await Future.wait([blocker, stale, current]);
    expect(executed, ['current']);
  });

  test('新会话注册前排空已开始旧同步，旧写入不会落在新 live 写入之后', () async {
    final coordinator = SessionProgressSyncCoordinator();
    final oldGeneration = coordinator.claim('same-session');
    final oldStarted = Completer<void>();
    final releaseOld = Completer<void>();
    final writes = <String>[];
    final oldSync = coordinator.run<void>(
      sessionId: 'same-session',
      generation: oldGeneration,
      action: () async {
        oldStarted.complete();
        await releaseOld.future;
        writes.add('old-delete');
        await Future<void>.delayed(Duration.zero);
        writes.add('old-save');
      },
    );
    await oldStarted.future;

    var registered = false;
    final newClaim = coordinator.claimAndDrain('same-session').then((
      generation,
    ) {
      registered = true;
      writes.add('new-live-save');
      return generation;
    });
    await Future<void>.delayed(Duration.zero);
    expect(registered, isFalse);

    releaseOld.complete();
    await oldSync;
    final newGeneration = await newClaim;

    expect(writes, ['old-delete', 'old-save', 'new-live-save']);
    expect(coordinator.isCurrent('same-session', newGeneration), isTrue);
  });
}
