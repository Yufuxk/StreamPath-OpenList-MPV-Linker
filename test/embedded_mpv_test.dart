import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/data/models/mpv_menu_shortcuts.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/data/models/video_window_mode.dart';
import 'package:streampath/domain/services/mpv_session_controller.dart';
import 'package:streampath/domain/services/mpv_window_coordinator.dart';
import 'package:streampath/domain/services/mpv_window_menu.dart';
import 'package:streampath/domain/services/player_process_controller.dart';
import 'package:streampath/presentation/pages/embedded_mpv_player_page.dart';
import 'package:win32/win32.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('旧配置和未知窗口模式默认独立窗口，序列化与配置复制保留选择', () {
    expect(
      const PlayerConfig(name: 'mpv', executable: 'mpv').videoWindowMode,
      VideoWindowMode.external,
    );
    expect(
      StreamPathConfig.fromJson({}).videoWindowMode,
      VideoWindowMode.external,
    );
    expect(
      StreamPathConfig.fromJson({'videoWindowMode': 'unknown'}).videoWindowMode,
      VideoWindowMode.external,
    );
    const player = PlayerConfig(
      name: 'mpv',
      executable: 'mpv',
      videoWindowMode: VideoWindowMode.embedded,
    );
    expect(
      PlayerConfig.fromJson(player.toJson()).videoWindowMode,
      VideoWindowMode.embedded,
    );
    final config = const StreamPathConfig().copyWithGlobalSettings(
      player: player,
      appearance: const StreamPathConfig().appearance,
      mediaLibrary: const StreamPathConfig().mediaLibrary,
    );
    expect(
      StreamPathConfig.fromJson(
        config.toJson(),
      ).toPlayerConfig().videoWindowMode,
      VideoWindowMode.embedded,
    );
    expect(
      config
          .withCredentialStorageMode(config.credentialStorageMode)
          .videoWindowMode,
      VideoWindowMode.embedded,
    );
  });

  test('菜单快捷键在播放器和全局配置的序列化及复制中保留', () {
    const shortcuts = MpvMenuShortcuts(
      open: 'Ctrl+Alt+u',
      up: 'w',
      down: 's',
      confirm: 'd',
      close: 'q',
    );
    const player = PlayerConfig(
      name: 'mpv',
      executable: 'mpv',
      mpvMenuShortcuts: shortcuts,
    );
    expect(
      PlayerConfig.fromJson(player.toJson()).mpvMenuShortcuts!.values,
      shortcuts.values,
    );
    final config = const StreamPathConfig().copyWithGlobalSettings(
      player: player,
      appearance: const StreamPathConfig().appearance,
      mediaLibrary: const StreamPathConfig().mediaLibrary,
    );
    final decoded = StreamPathConfig.fromJson(config.toJson());
    expect(decoded.toPlayerConfig().mpvMenuShortcuts!.values, shortcuts.values);
    expect(
      decoded
          .withCredentialStorageMode(decoded.credentialStorageMode)
          .mpvMenuShortcuts!
          .values,
      shortcuts.values,
    );
    expect(StreamPathConfig.fromJson({}).mpvMenuShortcuts, isNull);
  });

  test('仅嵌入模式接管 wid，保留用户配置、插件、着色器和媒体参数', () {
    final args = [
      '--config-dir=C:/mpv/user',
      '--script=C:/user/uosc.lua',
      '--glsl-shaders=C:/user/shader.glsl',
      '--wid',
      '45',
      '--wid=67',
      'movie.mkv',
    ];
    final original = List<String>.of(args);
    MpvWindowCoordinator.applyArguments(args, null);
    expect(args, original);
    MpvWindowCoordinator.applyArguments(
      args,
      EmbeddedMpvLaunch(host: 89, title: 'Movie', wasFullscreen: false),
    );
    expect(args, containsAllInOrder(original.take(3)));
    expect(args, contains('movie.mkv'));
    expect(args.where((arg) => arg.startsWith('--wid')), ['--wid=89']);
    expect(args, isNot(contains('--no-config')));
    expect(args, isNot(contains('--load-scripts=no')));
  });

  test('关闭模式不访问原生接口，不阻断普通播放', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MpvWindowCoordinator.channel, (call) async {
          calls.add(call.method);
          return null;
        });
    final coordinator = MpvWindowCoordinator(
      capabilityFile: File('unused.json'),
    );
    expect(
      await coordinator.prepare(
        const PlayerConfig(name: 'mpv', executable: 'mpv'),
        'test',
      ),
      isNull,
    );
    expect(calls, isEmpty);
    coordinator.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MpvWindowCoordinator.channel, null);
  });

  test('旧窗口协调器释放后保留新协调器的原生事件处理器', () async {
    final old = MpvWindowCoordinator(capabilityFile: File('unused-old.json'));
    final current = MpvWindowCoordinator(
      capabilityFile: File('unused-current.json'),
    );
    const config = PlayerConfig(name: 'mpv', executable: 'mpv');
    await old.configure(config);
    await current.configure(config);
    old.dispose();
    final response = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'streampath/mpv_window',
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('windowState', {'fullscreen': true}),
          ),
          (_) => response.complete(),
        );
    await response.future;
    expect(current.fullscreen, true);
    current.dispose();
  }, skip: !Platform.isWindows);

  test('有效兼容记录支持普通播放，菜单仍走独立窗口且可取消启动', () async {
    final dir = await Directory.systemTemp.createTemp('embed-capability-');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MpvWindowCoordinator.channel, (call) async {
          calls.add(call.method);
          return switch (call.method) {
            'create' => 123,
            'state' => {'fullscreen': false},
            _ => null,
          };
        });
    final file = await File(
      Platform.resolvedExecutable,
    ).copy(p.join(dir.path, 'mpv.exe'));
    final stat = await file.stat();
    final cache = File(p.join(dir.path, 'capability.json'));
    await cache.writeAsString(
      jsonEncode({
        'fingerprint': sha256
            .convert(
              utf8.encode(
                '${file.path}:${stat.size}:${stat.modified.microsecondsSinceEpoch}',
              ),
            )
            .toString(),
      }),
    );
    final coordinator = MpvWindowCoordinator(capabilityFile: cache);
    final config = PlayerConfig(
      name: 'mpv',
      executable: file.path,
      videoWindowMode: VideoWindowMode.embedded,
    );
    try {
      await coordinator.configure(config);
      expect(await coordinator.prepare(config, 'menu', discMenu: true), isNull);
      expect(calls, isEmpty);
      final launch = await coordinator.prepare(config, 'title');
      expect(launch?.host, 123);
      await coordinator.abandon(launch);
      expect(calls, ['state', 'create', 'release']);
    } finally {
      coordinator.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MpvWindowCoordinator.channel, null);
      await dir.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);

  test('IPC 不可用时拒绝释放仍属于存活播放器的容器，允许重试', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MpvWindowCoordinator.channel, (call) async {
          calls.add(call.method);
          return null;
        });
    final coordinator = MpvWindowCoordinator(
      capabilityFile: File('unused.json'),
    );
    final launch =
        EmbeddedMpvLaunch(host: 123, title: 'movie', wasFullscreen: false)
          ..identity = await PlayerProcessController().capture(pid)
          ..pipeName = r'\\.\pipe\streampath_nonexistent_embedding_test';
    coordinator.active = launch;
    try {
      await expectLater(coordinator.detach(), throwsA(isA<Exception>()));
      expect(coordinator.active, same(launch));
      expect(launch.detaching, false);
      expect(calls, isNot(contains('release')));
    } finally {
      coordinator.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MpvWindowCoordinator.channel, null);
    }
  }, skip: !Platform.isWindows);

  testWidgets('播放页随布局更新原生区域，弹窗遮挡时隐藏并在返回后恢复', (tester) async {
    tester.view.physicalSize = const Size(1919, 900);
    tester.view.devicePixelRatio = 1.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MpvWindowCoordinator.channel, (call) async {
          calls.add(call);
          return null;
        });
    final coordinator = MpvWindowCoordinator(
      capabilityFile: File('unused.json'),
    );
    final navigation = MpvPlaybackNavigation(coordinator);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigation.navigatorKey,
        scaffoldMessengerKey: navigation.messengerKey,
        navigatorObservers: [navigation],
        home: const Scaffold(body: Text('library')),
      ),
    );
    final launch = EmbeddedMpvLaunch(
      host: 123,
      title: 'movie',
      wasFullscreen: false,
    );
    unawaited(
      navigation.navigatorKey.currentState!.push(
        DialogRoute<void>(
          context: navigation.navigatorKey.currentContext!,
          builder: (_) => const AlertDialog(content: Text('preparing')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    coordinator.active = launch;
    await coordinator.onReady!(launch);
    await tester.pumpAndSettle();
    expect(find.text('movie'), findsNothing);
    navigation.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(EmbeddedMpvPlayerPage), findsOneWidget);
    expect(find.text('movie'), findsNothing);
    expect(find.text('转为独立窗口'), findsNothing);
    expect(find.text('结束播放'), findsNothing);
    expect(
      (calls.lastWhere((call) => call.method == 'bounds').arguments
          as Map)['width'],
      1919,
    );
    expect(
      calls.indexWhere((call) => call.method == 'focus'),
      greaterThan(calls.indexWhere((call) => call.method == 'bounds')),
    );
    expect(
      calls.any(
        (call) =>
            call.method == 'bounds' && (call.arguments as Map)['width'] > 0,
      ),
      true,
    );
    unawaited(
      navigation.navigatorKey.currentState!.push(
        DialogRoute<void>(
          context: navigation.navigatorKey.currentContext!,
          builder: (_) => const AlertDialog(content: Text('dialog')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls.lastWhere((call) => call.method == 'visible').arguments, {
      'host': 123,
      'enabled': false,
    });
    navigation.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(calls.lastWhere((call) => call.method == 'visible').arguments, {
      'host': 123,
      'enabled': true,
    });
    await tester.pumpWidget(const SizedBox());
    navigation.dispose();
    coordinator.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MpvWindowCoordinator.channel, null);
  });

  testWidgets('同步警告保留仍在播放的页面', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          MpvWindowCoordinator.channel,
          (_) async => null,
        );
    final coordinator =
        MpvWindowCoordinator(capabilityFile: File('unused.json'))
          ..fullscreen = true
          ..warning = '播放器窗口同步失败，可尝试转为独立窗口。';
    final launch = EmbeddedMpvLaunch(
      host: 123,
      title: 'movie',
      wasFullscreen: false,
    );
    coordinator.active = launch;
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('library')),
      ),
    );
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              EmbeddedMpvPlayerPage(coordinator: coordinator, launch: launch),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('转为独立窗口'), findsNothing);
    expect(find.text('结束播放'), findsNothing);
    expect(find.byType(EmbeddedMpvPlayerPage), findsOneWidget);
    expect(find.text('library'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    coordinator.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MpvWindowCoordinator.channel, null);
  });

  testWidgets('结束内嵌播放先让宿主返回页面，再释放原生视频表面', (tester) async {
    final events = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MpvWindowCoordinator.channel, (call) async {
          if (call.method == 'release') events.add('release');
          return null;
        });
    final identity = await tester.runAsync(() async {
      final process = await Process.start('cmd.exe', ['/c', 'exit']);
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      final captured = await PlayerProcessController().capture(process.pid);
      await process.exitCode;
      return captured;
    });
    expect(identity, isNotNull);
    final coordinator = MpvWindowCoordinator(
      capabilityFile: File('unused.json'),
    )..awaitsHostPaint = true;
    final launch =
        EmbeddedMpvLaunch(host: 321, title: 'movie', wasFullscreen: false)
          ..identity = identity
          ..pipeName = r'\\.\pipe\streampath_finish_paint_test';
    var hostNotified = false;
    coordinator
      ..active = launch
      ..addListener(() {
        if (!hostNotified && coordinator.active == null) {
          hostNotified = true;
          events.add('host');
        }
      });
    try {
      final stopping = coordinator.stop();
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await stopping;
      expect(events, ['host', 'release']);
    } finally {
      coordinator.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MpvWindowCoordinator.channel, null);
    }
  }, skip: !Platform.isWindows);

  test('未确认脱嵌时保留会话与容器，不隐藏正在播放的窗口', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MpvWindowCoordinator.channel, (call) async {
          calls.add(call.method);
          return null;
        });
    final coordinator = MpvWindowCoordinator(
      capabilityFile: File('unused.json'),
    );
    final launch = EmbeddedMpvLaunch(
      host: 123,
      title: 'movie',
      wasFullscreen: false,
    )..pipeName = r'\\.\pipe\streampath_bind_fail_test';
    try {
      await coordinator.bind(launch, null, launch.pipeName!);
      expect(coordinator.active, same(launch));
      expect(launch.detaching, isFalse);
      expect(calls, isNot(contains('visible')));
      expect(calls, isNot(contains('release')));
    } finally {
      coordinator.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MpvWindowCoordinator.channel, null);
    }
  });

  final executable = Platform.environment['STREAMPATH_PATH_MPV'];
  test('取消属性订阅不等待尚未建立的 IPC 连接超时', () async {
    final observer = MpvPropertySubscription(
      r'\\.\pipe\streampath_cancel_missing_' +
          DateTime.now().microsecondsSinceEpoch.toString(),
      const ['fullscreen'],
    );
    final events = observer.events.listen((_) {}, onError: (Object _) {});
    observer.start();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final elapsed = Stopwatch()..start();
    await observer.dispose();
    await events.cancel();
    expect(elapsed.elapsed, lessThan(const Duration(milliseconds: 500)));
  }, skip: !Platform.isWindows);

  for (final exitDelay in [100, 700]) {
    test(
      '属性连接断开后 MPV 退出不等待下一轮 IPC 连接超时：$exitDelay',
      () async {
        final pipe =
            r'\\.\pipe\streampath_close_reconnect_' +
            DateTime.now().microsecondsSinceEpoch.toString();
        final process = await Process.start(executable!, [
          '--no-config',
          '--load-scripts=no',
          '--idle=yes',
          '--vo=null',
          '--ao=null',
          '--input-ipc-server=$pipe',
        ]);
        unawaited(process.stdout.drain<void>());
        unawaited(process.stderr.drain<void>());
        final coordinator = MpvWindowCoordinator(
          capabilityFile: File('unused.json'),
        );
        final launch = EmbeddedMpvLaunch(
          host: 123,
          title: 'close',
          wasFullscreen: false,
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(MpvWindowCoordinator.channel, (
              call,
            ) async {
              return switch (call.method) {
                'bind' => true,
                'state' => {
                  'fullscreen': false,
                  'window-maximized': false,
                  'window-minimized': false,
                },
                _ => null,
              };
            });
        try {
          final identity = await PlayerProcessController().capture(process.pid);
          await coordinator.bind(launch, identity, pipe);
          await Future<void>.delayed(const Duration(milliseconds: 300));
          if (exitDelay == 700) launch.pipeName = '${pipe}_unavailable';
          await launch.observer!.dispose();
          await Future<void>.delayed(Duration(milliseconds: exitDelay));
          process.kill();
          await process.exitCode;
          final elapsed = Stopwatch()..start();
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (coordinator.active != null &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          await launch.finishing;
          expect(coordinator.active, isNull);
          expect(elapsed.elapsed, lessThan(const Duration(seconds: 1)));
        } finally {
          launch.detaching = true;
          await launch.events?.cancel();
          await launch.observer?.dispose();
          coordinator.dispose();
          process.kill();
          await process.exitCode;
          if (await launch.menuDirectory?.exists() == true) {
            await launch.menuDirectory!.delete(recursive: true);
          }
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(MpvWindowCoordinator.channel, null);
        }
      },
      skip: executable == null || !Platform.isWindows,
    );
  }
  for (final scenario in ['slow-window', 'slow-ipc', 'observer-reconnect']) {
    test(
      '存活 MPV 的启动与同步恢复：$scenario',
      () async {
        final pipe =
            r'\\.\pipe\streampath_recovery_' +
            DateTime.now().microsecondsSinceEpoch.toString();
        final process = await Process.start(executable!, [
          '--no-config',
          '--load-scripts=no',
          '--idle=yes',
          '--vo=null',
          '--ao=null',
          '--input-ipc-server=$pipe',
        ]);
        unawaited(process.stdout.drain<void>());
        unawaited(process.stderr.drain<void>());
        final client = MpvSessionController(pipeName: pipe);
        final coordinator = MpvWindowCoordinator(
          capabilityFile: File('unused.json'),
        );
        final launch = EmbeddedMpvLaunch(
          host: 123,
          title: 'recovery',
          wasFullscreen: false,
        );
        final elapsed = Stopwatch()..start();
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(MpvWindowCoordinator.channel, (
              call,
            ) async {
              calls.add(call);
              return switch (call.method) {
                'bind' =>
                  scenario != 'slow-window' || elapsed.elapsed.inSeconds >= 31,
                'state' => {
                  'fullscreen': false,
                  'window-maximized': false,
                  'window-minimized': false,
                },
                _ => null,
              };
            });
        var processHandle = 0;
        Timer? resume;
        final resumeProcess = DynamicLibrary.open('ntdll.dll')
            .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
              'NtResumeProcess',
            );
        try {
          expect(await client.connect(), isTrue);
          final identity = await PlayerProcessController().capture(process.pid);
          if (scenario == 'slow-ipc') {
            processHandle = OpenProcess(0x0800, FALSE, process.pid);
            expect(processHandle, isNot(0));
            final suspendProcess = DynamicLibrary.open('ntdll.dll')
                .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
                  'NtSuspendProcess',
                );
            expect(suspendProcess(processHandle), 0);
            resume = Timer(const Duration(seconds: 5), () {
              resumeProcess(processHandle);
            });
          }
          await coordinator.bind(launch, identity, pipe);
          expect(coordinator.active, same(launch));
          expect(launch.ready, isTrue);
          expect(coordinator.warning, isNull);
          expect(calls.where((call) => call.method == 'release'), isEmpty);
          if (scenario == 'observer-reconnect') {
            final observer = launch.observer!;
            await Future<void>.delayed(const Duration(milliseconds: 300));
            await observer.dispose();
            final deadline = DateTime.now().add(const Duration(seconds: 5));
            while (identical(observer, launch.observer) &&
                DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
            expect(launch.observer, isNot(same(observer)));
            await Future<void>.delayed(const Duration(milliseconds: 300));
            await client.setProperty('fullscreen', true);
            await Future<void>.delayed(const Duration(milliseconds: 300));
            expect(
              calls.where(
                (call) =>
                    call.method == 'fullscreen' &&
                    (call.arguments as Map)['enabled'] == true,
              ),
              isNotEmpty,
            );
            expect(coordinator.warning, isNull);
          }
        } finally {
          if (processHandle != 0) {
            resume?.cancel();
            resumeProcess(processHandle);
            CloseHandle(processHandle);
          }
          launch.detaching = true;
          await launch.events?.cancel();
          await launch.observer?.dispose();
          await client.dispose();
          coordinator.dispose();
          process.kill();
          await process.exitCode;
          if (await launch.menuDirectory?.exists() == true) {
            await launch.menuDirectory!.delete(recursive: true);
          }
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(MpvWindowCoordinator.channel, null);
        }
      },
      skip: executable == null || !Platform.isWindows,
      timeout: const Timeout(Duration(seconds: 55)),
    );
  }

  test('MPV 退出后持续事件连接报告断开并可释放', () async {
    final pipe =
        r'\\.\pipe\streampath_event_close_' +
        DateTime.now().microsecondsSinceEpoch.toString();
    final process = await Process.start(executable!, [
      '--no-config',
      '--load-scripts=no',
      '--idle=yes',
      '--vo=null',
      '--ao=null',
      '--input-ipc-server=$pipe',
    ]);
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    final observer = MpvPropertySubscription(pipe, ['pause']);
    final ready = Completer<void>();
    final disconnected = Completer<void>();
    final events = observer.events.listen(
      (event) {
        if (event.name == 'pause' && !ready.isCompleted) ready.complete();
      },
      onError: (Object _) {
        if (!disconnected.isCompleted) disconnected.complete();
      },
    );
    observer.start();
    final client = MpvSessionController(pipeName: pipe);
    try {
      expect(await client.connect(), true);
      await ready.future.timeout(const Duration(seconds: 6));
      try {
        await client.command(['quit']);
      } on StateError {
        // MPV 可以在回复前关闭连接。
      }
      await process.exitCode.timeout(const Duration(seconds: 6));
      await disconnected.future.timeout(const Duration(seconds: 3));
      await observer.dispose().timeout(const Duration(seconds: 3));
    } finally {
      await client.dispose();
      await events.cancel();
      process.kill();
    }
  }, skip: executable == null || !Platform.isWindows);

  test('窗口菜单文案覆盖四种应用语言', () {
    for (final language in ['zh-CN', 'zh-TW', 'ja', 'en']) {
      final labels = mpvWindowMenuLabels(language);
      expect(labels, hasLength(10));
      expect(labels.every((label) => label.isNotEmpty), true);
      expect(mpvWindowMenuScript('test', language), contains(labels[4]));
    }
    expect(mpvWindowMenuLabels('en')[4], 'Detach window');
  });
  Future<void> waitForMenuBinding(
    MpvSessionController client, [
    String key = 'ctrl+alt+m',
    String name = 'streampath-window-menu-toggle',
  ]) async {
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (DateTime.now().isBefore(deadline)) {
      final bindings = await client.getProperty('input-bindings');
      if (bindings is List &&
          bindings.any(
            (entry) =>
                entry is Map &&
                '${entry['key']}'.toLowerCase() == key &&
                '${entry['cmd']}'.contains(name),
          )) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw StateError('MPV menu binding unavailable');
  }

  test('窗口菜单请求只接受当前 pipe 和递增序号', () async {
    final pipe =
        r'\\.\pipe\streampath_menu_action_' +
        DateTime.now().microsecondsSinceEpoch.toString();
    final process = await Process.start(executable!, [
      '--no-config',
      '--load-scripts=no',
      '--idle=yes',
      '--vo=null',
      '--ao=null',
      '--input-ipc-server=$pipe',
    ]);
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    final calls = <MethodCall>[];
    var maximized = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MpvWindowCoordinator.channel, (call) async {
          calls.add(call);
          if (call.method == 'bind') return true;
          if (call.method == 'state') {
            return {
              'fullscreen': false,
              'window-maximized': maximized,
              'window-minimized': false,
            };
          }
          if (call.method == 'maximize') {
            maximized = (call.arguments as Map)['enabled'] == true;
          }
          return null;
        });
    final coordinator = MpvWindowCoordinator(
      capabilityFile: File('unused.json'),
    );
    final identity = await PlayerProcessController().capture(process.pid);
    final launch = EmbeddedMpvLaunch(
      host: 123,
      title: 'test',
      wasFullscreen: false,
    );
    final client = MpvSessionController(pipeName: pipe);
    try {
      await coordinator.configure(
        const PlayerConfig(name: 'mpv', executable: 'mpv'),
      );
      await coordinator.bind(launch, identity, pipe);
      expect(await client.connect(), true);
      await waitForMenuBinding(client);
      await client.command(['keypress', 'Ctrl+Alt+m']);
      await waitForMenuBinding(client, 'enter', 'streampath-menu-enter');
      await client.command(['keypress', 'ENTER']);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(calls.where((call) => call.method == 'fullscreen').length, 2);
      await client.command([
        'script-message',
        'streampath-window-menu',
        'wrong',
        '2',
        'minimize',
      ]);
      await client.command([
        'script-message',
        'streampath-window-menu',
        pipe,
        '2',
        'minimize',
      ]);
      await client.command([
        'script-message',
        'streampath-window-menu',
        pipe,
        '1',
        'minimize',
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(calls.where((call) => call.method == 'minimize').length, 1);
      await client.command([
        'script-message',
        'streampath-window-menu',
        pipe,
        '3',
        'maximize',
      ]);
      await client.command([
        'script-message',
        'streampath-window-menu',
        pipe,
        '4',
        'maximize',
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(
        calls
            .where((call) => call.method == 'maximize')
            .map((c) => (c.arguments as Map)['enabled']),
        [true, false],
      );
      final response = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'streampath/mpv_window',
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('menuAction', {
                'host': 123,
                'action': 'fullscreen',
              }),
            ),
            (_) => response.complete(),
          );
      await response.future;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(calls.where((call) => call.method == 'fullscreen').length, 3);
      await client.command([
        'script-message',
        'streampath-window-menu',
        pipe,
        '5',
        'stop',
      ]);
      await process.exitCode.timeout(const Duration(seconds: 6));
      final deadline = DateTime.now().add(const Duration(seconds: 6));
      while (coordinator.active != null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(coordinator.active, isNull);
    } finally {
      await client.dispose();
      await launch.events?.cancel();
      await launch.observer?.dispose();
      if (await launch.menuDirectory?.exists() == true) {
        await launch.menuDirectory!.delete(recursive: true);
      }
      coordinator.dispose();
      process.kill();
      await process.exitCode;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MpvWindowCoordinator.channel, null);
    }
  }, skip: executable == null || !Platform.isWindows);

  test('无 uosc 时回退内置菜单，支持自定义快捷键', () async {
    final dir = await Directory.systemTemp.createTemp('embed-menu-');
    final pipe =
        r'\\.\pipe\streampath_menu_script_' +
        DateTime.now().microsecondsSinceEpoch.toString();
    final script = File(p.join(dir.path, 'streampath_window_menu.lua'));
    final input = File(p.join(dir.path, 'input.conf'));
    await script.writeAsString(
      mpvWindowMenuScript(
        pipe,
        'zh-CN',
        const MpvMenuShortcuts(
          open: 'Ctrl+Alt+u',
          up: 'w',
          down: 's',
          confirm: 'd',
          close: 'q',
        ),
      ),
    );
    await input.writeAsString('MBTN_RIGHT script-binding uosc/menu\n');
    final process = await Process.start(executable!, [
      '--no-config',
      '--load-scripts=no',
      '--idle=yes',
      '--vo=null',
      '--ao=null',
      '--input-conf=${input.path}',
      '--input-ipc-server=$pipe',
      '--script-opts-append=streampath-window-menu-key=Ctrl+Alt+x',
      '--script=${script.path}',
    ]);
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    final observer = MpvPropertySubscription(pipe, []);
    final received = observer.events.firstWhere(
      (event) =>
          event.name == 'client-message' &&
          event.value is List &&
          (event.value as List).first == 'streampath-window-menu',
    );
    observer.start();
    final client = MpvSessionController(pipeName: pipe);
    try {
      expect(await client.connect(), true);
      await waitForMenuBinding(client, 'ctrl+alt+u');
      await client.command(['keypress', 'Ctrl+Alt+u']);
      await waitForMenuBinding(client, 'd', 'streampath-menu-enter');
      await client.command(['keypress', 'w']);
      await client.command(['keypress', 'q']);
      await client.command(['keypress', 'Ctrl+Alt+u']);
      await waitForMenuBinding(client, 's', 'streampath-menu-down');
      await client.command(['keypress', 's']);
      await client.command(['keypress', 's']);
      await client.command(['keypress', 'd']);
      final event = await received.timeout(const Duration(seconds: 5));
      expect(event.value, ['streampath-window-menu', pipe, '1', 'maximize']);
    } finally {
      await client.dispose();
      await observer.dispose();
      process.kill();
      await process.exitCode;
      await dir.delete(recursive: true);
    }
  }, skip: executable == null || !Platform.isWindows);

  test('菜单快捷键冲突时保留用户原有绑定', () async {
    final dir = await Directory.systemTemp.createTemp('embed-menu-conflict-');
    final pipe =
        r'\\.\pipe\streampath_menu_conflict_' +
        DateTime.now().microsecondsSinceEpoch.toString();
    final script = File(p.join(dir.path, 'streampath_window_menu.lua'));
    final input = File(p.join(dir.path, 'input.conf'));
    await script.writeAsString(mpvWindowMenuScript(pipe, 'zh-CN'));
    await input.writeAsString('Ctrl+Alt+m set speed 1.5\n');
    final process = await Process.start(executable!, [
      '--no-config',
      '--load-scripts=no',
      '--idle=yes',
      '--vo=null',
      '--ao=null',
      '--input-conf=${input.path}',
      '--input-ipc-server=$pipe',
      '--script=${script.path}',
    ]);
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    final client = MpvSessionController(pipeName: pipe);
    try {
      expect(await client.connect(), true);
      final deadline = DateTime.now().add(const Duration(seconds: 6));
      while (DateTime.now().isBefore(deadline)) {
        final bindings = await client.getProperty('input-bindings');
        if (bindings is List &&
            bindings.any(
              (entry) =>
                  entry is Map &&
                  '${entry['key']}'.toLowerCase() == 'ctrl+alt+m' &&
                  '${entry['cmd']}'.contains('set speed 1.5'),
            )) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await client.command(['keypress', 'Ctrl+Alt+m']);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(await client.getProperty('speed'), 1.5);
      final bindings = await client.getProperty('input-bindings') as List;
      expect(
        bindings.any(
          (entry) =>
              entry is Map &&
              '${entry['key']}'.toLowerCase() == 'ctrl+alt+m' &&
              '${entry['cmd']}'.contains('streampath-window-menu-toggle'),
        ),
        false,
      );
    } finally {
      await client.dispose();
      process.kill();
      await process.exitCode;
      await dir.delete(recursive: true);
    }
  }, skip: executable == null || !Platform.isWindows);

  test('未在设置页编辑时继续使用旧的 MPV 呼出键参数', () async {
    final dir = await Directory.systemTemp.createTemp('embed-menu-legacy-');
    final pipe =
        r'\\.\pipe\streampath_menu_legacy_' +
        DateTime.now().microsecondsSinceEpoch.toString();
    final script = File(p.join(dir.path, 'streampath_window_menu.lua'));
    await script.writeAsString(mpvWindowMenuScript(pipe, 'zh-CN'));
    final process = await Process.start(executable!, [
      '--no-config',
      '--load-scripts=no',
      '--idle=yes',
      '--vo=null',
      '--ao=null',
      '--input-ipc-server=$pipe',
      '--script-opts-append=streampath-window-menu-key=Ctrl+Alt+u',
      '--script=${script.path}',
    ]);
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    final client = MpvSessionController(pipeName: pipe);
    try {
      expect(await client.connect(), true);
      await waitForMenuBinding(client, 'ctrl+alt+u');
      await client.command(['keypress', 'Ctrl+Alt+u']);
      await waitForMenuBinding(client, 'enter', 'streampath-menu-enter');
    } finally {
      await client.dispose();
      process.kill();
      await process.exitCode;
      await dir.delete(recursive: true);
    }
  }, skip: executable == null || !Platform.isWindows);
  test(
    '持续事件连接接收 Lua client-message，无需后续命令',
    () async {
      final dir = await Directory.systemTemp.createTemp('embed-message-');
      final pipe =
          r'\\.\pipe\streampath_embed_message_' +
          DateTime.now().microsecondsSinceEpoch.toString();
      final script = File(p.join(dir.path, 'message.lua'));
      await script.writeAsString(
        "mp.add_timeout(1.5, function() mp.commandv('script-message', 'streampath-menu-test', 'minimize') end)\n",
      );
      final process = await Process.start(executable!, [
        '--no-config',
        '--load-scripts=no',
        '--idle=yes',
        '--vo=null',
        '--ao=null',
        '--input-ipc-server=$pipe',
        '--script=${script.path}',
      ]);
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      final observer = MpvPropertySubscription(pipe, []);
      final received = observer.events.firstWhere(
        (event) => event.name == 'client-message',
      );
      observer.start();
      try {
        final event = await received.timeout(const Duration(seconds: 6));
        expect(event.value, ['streampath-menu-test', 'minimize']);
      } finally {
        await observer.dispose();
        process.kill();
        await process.exitCode;
        await dir.delete(recursive: true);
      }
    },
    skip: executable == null || !Platform.isWindows,
  );

  test('持续事件连接在无后续请求时仍收到用户脚本的窗口状态变化', () async {
    final dir = await Directory.systemTemp.createTemp('embed-events-');
    final pipe =
        r'\\.\pipe\streampath_embed_events_' +
        DateTime.now().microsecondsSinceEpoch.toString();
    final script = File(p.join(dir.path, 'window.lua'));
    await script.writeAsString(
      "mp.add_timeout(1.5, function() mp.set_property_native('fullscreen', true) end)\n",
    );
    final process = await Process.start(executable!, [
      '--no-config',
      '--load-scripts=no',
      '--idle=yes',
      '--vo=null',
      '--ao=null',
      '--input-ipc-server=$pipe',
      '--script=${script.path}',
    ]);
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    final observer = MpvPropertySubscription(pipe, ['fullscreen']);
    final changed = observer.events.firstWhere(
      (event) => event.name == 'fullscreen' && event.value == true,
    );
    observer.start();
    try {
      await changed.timeout(const Duration(seconds: 6));
    } finally {
      await observer.dispose();
      process.kill();
      await process.exitCode;
      await dir.delete(recursive: true);
    }
  }, skip: executable == null || !Platform.isWindows);
}
