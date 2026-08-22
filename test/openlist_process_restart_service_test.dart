import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/domain/services/openlist_process_restart_service.dart';

void main() {
  const target = OpenListProcessTargetKey(
    normalizedOrigin: 'http://127.0.0.1:5244',
    resolvedLocalAddress: '127.0.0.1',
    port: 5244,
  );
  const identity = OpenListProcessIdentity(
    target: target,
    pid: 123,
    parentPid: 122,
    parentName: 'cmd.exe',
    executablePath: r'D:\OpenList\openlist.exe',
    commandLine: r'"D:\OpenList\openlist.exe" server --force-bin-dir',
  );

  test('身份确认、优雅退出、重新启动与服务就绪形成完整安全重启', () async {
    if (!Platform.isWindows) return;
    var alive = true;
    var launchCount = 0;
    final service = OpenListProcessRestartService(
      snapshotLoader: (uri) async => identity,
      identityValidator: (value) async => value == identity,
      signalSender: (value) async {
        alive = false;
        return true;
      },
      aliveProbe: (pid) async => alive,
      launcher: (value) async {
        launchCount++;
        return 456;
      },
      readyProbe: (uri) async => true,
      pollInterval: Duration.zero,
    );

    expect(await service.capture('http://127.0.0.1:5244'), isTrue);
    final result = await service.restart('http://127.0.0.1:5244');

    expect(result.success, isTrue);
    expect(result.pid, 456);
    expect(launchCount, 1);
  });

  test('优雅关闭信号失败时不启动新进程且不尝试强杀', () async {
    if (!Platform.isWindows) return;
    var launchCount = 0;
    final service = OpenListProcessRestartService(
      snapshotLoader: (uri) async => identity,
      identityValidator: (value) async => true,
      signalSender: (value) async => false,
      aliveProbe: (pid) async => true,
      launcher: (value) async {
        launchCount++;
        return 456;
      },
      readyProbe: (uri) async => true,
      pollInterval: Duration.zero,
    );

    final result = await service.restart('http://127.0.0.1:5244');

    expect(result.success, isFalse);
    expect(result.message, contains('未强制结束'));
    expect(launchCount, 0);
  });

  test('缺少 force-bin-dir 的进程不会被记录或重启', () async {
    if (!Platform.isWindows) return;
    const unsupported = OpenListProcessIdentity(
      target: target,
      pid: 123,
      parentPid: 122,
      parentName: 'cmd.exe',
      executablePath: r'D:\OpenList\openlist.exe',
      commandLine: r'"D:\OpenList\openlist.exe" server',
    );
    var signalCount = 0;
    final service = OpenListProcessRestartService(
      snapshotLoader: (uri) async => unsupported,
      identityValidator: (value) async => true,
      signalSender: (value) async {
        signalCount++;
        return true;
      },
      aliveProbe: (pid) async => false,
      launcher: (value) async => 456,
      readyProbe: (uri) async => true,
      pollInterval: Duration.zero,
    );

    expect(await service.capture('http://127.0.0.1:5244'), isFalse);
    final result = await service.restart('http://127.0.0.1:5244');

    expect(result.success, isFalse);
    expect(signalCount, 0);
  });

  test('目标 B 没有本机监听器时不得回退目标 A 的旧身份', () async {
    if (!Platform.isWindows) return;
    var signalCount = 0;
    var launchCount = 0;
    var alive = true;
    final service = OpenListProcessRestartService(
      snapshotLoader: (uri) async => uri.port == 5244 ? identity : null,
      identityValidator: (value) async => true,
      signalSender: (value) async {
        signalCount++;
        alive = false;
        return true;
      },
      aliveProbe: (pid) async => alive,
      launcher: (value) async {
        launchCount++;
        return 456;
      },
      readyProbe: (uri) async => true,
      pollInterval: Duration.zero,
    );

    expect(await service.capture('http://127.0.0.1:5244'), isTrue);
    final result = await service.restart('http://127.0.0.1:6244');

    expect(result.success, isFalse);
    expect(signalCount, 0);
    expect(launchCount, 0);
  });

  test('同一 origin 解析到新的本机地址时不得回退旧地址身份', () async {
    if (!Platform.isWindows) return;
    const originalTarget = OpenListProcessTargetKey(
      normalizedOrigin: 'http://node.local:5244',
      resolvedLocalAddress: '192.168.1.10',
      port: 5244,
    );
    const changedTarget = OpenListProcessTargetKey(
      normalizedOrigin: 'http://node.local:5244',
      resolvedLocalAddress: '192.168.1.11',
      port: 5244,
    );
    const originalIdentity = OpenListProcessIdentity(
      target: originalTarget,
      pid: 123,
      parentPid: 122,
      parentName: 'cmd.exe',
      executablePath: r'D:\OpenList\openlist.exe',
      commandLine: r'"D:\OpenList\openlist.exe" server --force-bin-dir',
    );
    var currentTarget = originalTarget;
    var capturePhase = true;
    var signalCount = 0;
    final service = OpenListProcessRestartService(
      targetResolver: (uri) async => currentTarget,
      snapshotLoader: (uri) async => capturePhase ? originalIdentity : null,
      identityValidator: (value) async => true,
      signalSender: (value) async {
        signalCount++;
        return true;
      },
      aliveProbe: (pid) async => false,
      launcher: (value) async => 456,
      readyProbe: (uri) async => true,
      pollInterval: Duration.zero,
    );

    expect(await service.capture('http://node.local:5244'), isTrue);
    capturePhase = false;
    currentTarget = changedTarget;
    final result = await service.restart('http://node.local:5244');

    expect(result.success, isFalse);
    expect(signalCount, 0);
  });

  test('目标地址歧义时失败关闭且不发送信号', () async {
    if (!Platform.isWindows) return;
    var snapshotCount = 0;
    var signalCount = 0;
    final service = OpenListProcessRestartService(
      targetResolver: (uri) async => null,
      snapshotLoader: (uri) async {
        snapshotCount++;
        return identity;
      },
      identityValidator: (value) async => true,
      signalSender: (value) async {
        signalCount++;
        return true;
      },
      aliveProbe: (pid) async => false,
      launcher: (value) async => 456,
      readyProbe: (uri) async => true,
      pollInterval: Duration.zero,
    );

    final result = await service.restart('http://localhost:5244');

    expect(result.success, isFalse);
    expect(snapshotCount, 0);
    expect(signalCount, 0);
  });

  test('发送信号前监听 OwningProcess 不再匹配时取消重启', () async {
    if (!Platform.isWindows) return;
    var validationCount = 0;
    var signalCount = 0;
    var launchCount = 0;
    final service = OpenListProcessRestartService(
      snapshotLoader: (uri) async => identity,
      identityValidator: (value) async {
        validationCount++;
        return false;
      },
      signalSender: (value) async {
        signalCount++;
        return true;
      },
      aliveProbe: (pid) async => false,
      launcher: (value) async {
        launchCount++;
        return 456;
      },
      readyProbe: (uri) async => true,
      pollInterval: Duration.zero,
    );

    final result = await service.restart('http://127.0.0.1:5244');

    expect(result.success, isFalse);
    expect(validationCount, 1);
    expect(signalCount, 0);
    expect(launchCount, 0);
  });

  test('并发捕获 A 和 B 不会让较晚完成的 A 覆盖 B', () async {
    if (!Platform.isWindows) return;
    const targetB = OpenListProcessTargetKey(
      normalizedOrigin: 'http://127.0.0.1:6244',
      resolvedLocalAddress: '127.0.0.1',
      port: 6244,
    );
    const identityB = OpenListProcessIdentity(
      target: targetB,
      pid: 223,
      parentPid: 222,
      parentName: 'cmd.exe',
      executablePath: r'D:\OpenListB\openlist.exe',
      commandLine: r'"D:\OpenListB\openlist.exe" server --force-bin-dir',
    );
    final captureA = Completer<OpenListProcessIdentity?>();
    final captureB = Completer<OpenListProcessIdentity?>();
    var capturePhase = true;
    int? signaledPid;
    var alive = true;
    final service = OpenListProcessRestartService(
      targetResolver: (uri) async => uri.port == 5244 ? target : targetB,
      snapshotLoader: (uri) async {
        if (!capturePhase) return null;
        return uri.port == 5244 ? captureA.future : captureB.future;
      },
      identityValidator: (value) async => true,
      signalSender: (value) async {
        signaledPid = value.pid;
        alive = false;
        return true;
      },
      aliveProbe: (pid) async => alive,
      launcher: (value) async => 456,
      readyProbe: (uri) async => true,
      pollInterval: Duration.zero,
    );

    final pendingA = service.capture('http://127.0.0.1:5244');
    final pendingB = service.capture('http://127.0.0.1:6244');
    captureB.complete(identityB);
    expect(await pendingB, isTrue);
    captureA.complete(identity);
    expect(await pendingA, isTrue);
    capturePhase = false;

    final result = await service.restart('http://127.0.0.1:6244');

    expect(result.success, isTrue);
    expect(signaledPid, identityB.pid);
  });

  test('同一 normalized origin 的旧捕获晚完成时不覆盖较新身份', () async {
    if (!Platform.isWindows) return;
    final newerIdentity = identity.copyWith(pid: 223);
    final olderCapture = Completer<OpenListProcessIdentity?>();
    final newerCapture = Completer<OpenListProcessIdentity?>();
    var captureCall = 0;
    var capturePhase = true;
    int? signaledPid;
    var alive = true;
    final service = OpenListProcessRestartService(
      targetResolver: (uri) async => target,
      snapshotLoader: (uri) async {
        if (!capturePhase) return null;
        captureCall++;
        return captureCall == 1 ? olderCapture.future : newerCapture.future;
      },
      identityValidator: (value) async => true,
      signalSender: (value) async {
        signaledPid = value.pid;
        alive = false;
        return true;
      },
      aliveProbe: (pid) async => alive,
      launcher: (value) async => 456,
      readyProbe: (uri) async => true,
      pollInterval: Duration.zero,
    );

    final pendingOlder = service.capture('http://127.0.0.1:5244/dav');
    final pendingNewer = service.capture('HTTP://127.0.0.1:5244/api');
    newerCapture.complete(newerIdentity);
    expect(await pendingNewer, isTrue);
    olderCapture.complete(identity);
    expect(await pendingOlder, isFalse);
    capturePhase = false;

    final result = await service.restart('http://127.0.0.1:5244');

    expect(result.success, isTrue);
    expect(signaledPid, newerIdentity.pid);
  });

  test('同一物理目标的并发重启只发送一次信号并启动一次', () async {
    if (!Platform.isWindows) return;
    final releaseSignal = Completer<void>();
    var signalCount = 0;
    var launchCount = 0;
    final service = OpenListProcessRestartService(
      targetResolver: (uri) async => target,
      snapshotLoader: (uri) async => identity,
      identityValidator: (value) async => true,
      signalSender: (value) async {
        signalCount++;
        await releaseSignal.future;
        return true;
      },
      aliveProbe: (pid) async => false,
      launcher: (value) async {
        launchCount++;
        return 456;
      },
      readyProbe: (uri) async => true,
      pollInterval: Duration.zero,
    );

    final first = service.restart('http://127.0.0.1:5244');
    while (signalCount == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    final second = service.restart('http://127.0.0.1:5244');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final signalsBeforeRelease = signalCount;
    releaseSignal.complete();
    final results = await Future.wait([first, second]);

    expect(results.every((result) => result.success), isTrue);
    expect(signalsBeforeRelease, 1);
    expect(signalCount, 1);
    expect(launchCount, 1);
  });
}
