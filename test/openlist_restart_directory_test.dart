import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/openlist_recovery_config.dart';
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
    parentName: 'powershell.exe',
    executablePath: r"D:\Program Files\工具's\openlist\openlist.exe",
    commandLine:
        '"D:\\Program Files\\工具\'s\\openlist\\openlist.exe" server --force-bin-dir',
  );

  test('缺少目录字段的旧配置默认用户目录，安装目录模式可往返', () {
    expect(
      OpenListRecoveryConfig.fromJson({'enabled': true}).restartDirectory,
      OpenListRestartDirectory.userProfile,
    );
    const config = OpenListRecoveryConfig(
      restartDirectory: OpenListRestartDirectory.installation,
    );
    expect(
      OpenListRecoveryConfig.fromJson(
        config.toJson(includeSecrets: false),
      ).restartDirectory,
      OpenListRestartDirectory.installation,
    );
  });

  for (final mode in OpenListRestartDirectory.values) {
    test('重启在停止前验证目录并将 $mode 传给启动器', () async {
      final events = <String>[];
      final service = OpenListProcessRestartService(
        targetResolver: (_) async => target,
        snapshotLoader: (_) async => identity,
        directoryExists: (path) async {
          events.add(path);
          return true;
        },
        identityValidator: (_) async => true,
        signalSender: (_) async {
          events.add('stop');
          return true;
        },
        aliveProbe: (_) async => false,
        launcher: (value, directory) async {
          expect(value.executablePath, identity.executablePath);
          events.add(directory);
          return 456;
        },
        readyProbe: (_) async => true,
      );
      expect(await service.capture(target.normalizedOrigin), isTrue);
      expect(
        (await service.restart(
          target.normalizedOrigin,
          directory: mode,
        )).success,
        isTrue,
      );
      final expected = mode == OpenListRestartDirectory.userProfile
          ? Platform.environment['USERPROFILE']!
          : r"D:\Program Files\工具's\openlist";
      expect(events, [expected, 'stop', expected]);
    }, skip: !Platform.isWindows);
  }

  test('目录不可用时不会向运行中的服务发送停止信号', () async {
    var signalled = false;
    final service = OpenListProcessRestartService(
      targetResolver: (_) async => target,
      snapshotLoader: (_) async => identity,
      directoryExists: (_) async => false,
      signalSender: (_) async {
        signalled = true;
        return true;
      },
    );
    final result = await service.restart(target.normalizedOrigin);
    expect(result.success, isFalse);
    expect(signalled, isFalse);
    expect(result.message, contains('未停止服务'));
  }, skip: !Platform.isWindows);
}
