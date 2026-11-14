import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/data/models/media_entry.dart';
import 'package:streampath/data/models/video_window_mode.dart';
import 'package:streampath/domain/services/external_player_service.dart';
import 'package:streampath/domain/services/mpv_session_controller.dart';
import 'package:streampath/domain/services/mpv_window_coordinator.dart';
import 'package:streampath/presentation/pages/embedded_mpv_player_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final directory = Directory(
    Platform.environment['STREAMPATH_EMBED_ACCEPTANCE_DIR']!,
  );
  await directory.create(recursive: true);
  final executable = Platform.environment['STREAMPATH_PATH_MPV']!;
  final coordinator = MpvWindowCoordinator(
    capabilityFile: File(p.join(directory.path, 'capability.json')),
    menuBaseDirectory: Directory(p.join(directory.path, 'menus')),
  );
  final navigation = MpvPlaybackNavigation(coordinator);
  const MethodChannel(
    'streampath/appearance',
  ).setMethodCallHandler((_) async {});
  runApp(
    MaterialApp(
      navigatorKey: navigation.navigatorKey,
      scaffoldMessengerKey: navigation.messengerKey,
      navigatorObservers: [navigation],
      home: const Scaffold(
        body: Center(child: Text('Isolated embedded MPV acceptance')),
      ),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => unawaited(_verify(directory, executable, coordinator)),
  );
}

Future<void> _verify(
  Directory directory,
  String executable,
  MpvWindowCoordinator coordinator,
) async {
  final result = <String, Object?>{};
  PlayerLaunchResult? launched;
  MpvSessionController? client;
  Future<void> waitFor(
    Future<bool> Function() check,
    String description,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      if (await check()) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw StateError('Acceptance timeout: $description');
  }

  try {
    final script = File(p.join(directory.path, 'input.lua'));
    await script.writeAsString(
      "mp.add_forced_key_binding('F23', 'probe-input', function() mp.set_property_number('speed', 1.5) end)\n",
    );
    // ignore: invalid_use_of_visible_for_testing_member
    final store = StreamPathConfigStore.forPath(
      p.join(directory.path, 'config.json'),
    );
    final userConfig =
        Platform.environment['STREAMPATH_EMBED_ACCEPTANCE_CONFIG'];
    await store.save(
      StreamPathConfig(
        playerExecutable: executable,
        videoWindowMode: VideoWindowMode.embedded,
        autoSeasonTransitionEnabled: false,
        resumeEnabled: false,
        playerArgs: [
          if (userConfig == null) ...[
            '--no-config',
            '--load-scripts=no',
          ] else
            '--config-dir=$userConfig',
          '--ao=null',
          '--pause=yes',
          '--log-file=${p.join(directory.path, 'mpv.log')}',
          '--script=${script.path}',
          '{url}',
        ],
      ),
    );
    final notices = <String>[];
    coordinator.notices.listen(notices.add);
    await coordinator.configure(store.current.toPlayerConfig());
    final service = ExternalPlayerService(
      configStore: store,
      watchLaterDir: Directory(p.join(directory.path, 'watch')),
      windowCoordinator: coordinator,
    );
    launched = await service.launchLocal(
      entries: [
        MediaEntry(
          url:
              Platform.environment['STREAMPATH_EMBED_ACCEPTANCE_MEDIA'] ??
              'av://lavfi:testsrc2=size=640x360:rate=24',
          title: 'Embedded MPV acceptance',
        ),
      ],
      sourceId: 'local:embedded-acceptance',
    );
    client = MpvSessionController(pipeName: launched.ipcPipeName!);
    result['same_pid'] = launched.process.pid;
    result['pipe'] = launched.ipcPipeName;
    if (!await client.connect(timeout: const Duration(seconds: 5))) {
      throw StateError('Missing playback IPC');
    }
    final connection = client;
    await waitFor(
      () async => coordinator.active?.ready == true && coordinator.fullscreen,
      'embedded fullscreen',
    );
    final launch = coordinator.active!;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final window = await connection.getProperty('window-id') as int;
    final root = GetAncestor(launch.host, GA_ROOT);
    final systemMenu = GetSystemMenu(root, FALSE);
    if (GetMenuState(systemMenu, 0x1f10, MF_BYCOMMAND) == 0xffffffff ||
        GetMenuState(systemMenu, 0x1f20, MF_BYCOMMAND) == 0xffffffff) {
      throw StateError('StreamPath system menu unavailable');
    }
    Future<void> waitBinding(String key, String name) => waitFor(() async {
      final bindings = await connection.getProperty('input-bindings');
      return bindings is List &&
          bindings.any(
            (entry) =>
                entry is Map &&
                '${entry['key']}'.toLowerCase() == key &&
                '${entry['cmd']}'.contains(name),
          );
    }, 'menu binding $name');
    Future<bool> isUoscMenu() async {
      try {
        return await connection.getProperty('user-data/uosc/menu/type') ==
            'streampath-window-menu';
      } on StateError {
        return false;
      }
    }

    Future<bool> openMenu() async {
      await waitFor(() async => !await isUoscMenu(), 'previous menu closed');
      await waitBinding('ctrl+alt+m', 'streampath-window-menu-toggle');
      await connection.command(['keypress', 'Ctrl+Alt+m']);
      await waitFor(() async {
        if (await isUoscMenu()) return true;
        final bindings = await connection.getProperty('input-bindings');
        return bindings is List &&
            bindings.any(
              (entry) =>
                  entry is Map &&
                  '${entry['key']}'.toLowerCase() == 'enter' &&
                  '${entry['cmd']}'.contains('streampath-menu-enter'),
            );
      }, 'window menu');
      return isUoscMenu();
    }

    if (Platform.environment['STREAMPATH_EXPECT_UOSC'] == '1') {
      await connection.command(['script-binding', 'uosc/menu']);
      Object? originalMenu;
      await waitFor(() async {
        try {
          originalMenu = await connection.getProperty(
            'user-data/uosc/menu/type',
          );
          return originalMenu != null;
        } on StateError {
          return false;
        }
      }, 'existing uosc menu');
      await connection.command(['keypress', 'Ctrl+Alt+m']);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (await connection.getProperty('user-data/uosc/menu/type') !=
          originalMenu) {
        throw StateError('Existing uosc menu was replaced');
      }
      await connection.command(['keypress', 'ESC']);
      await waitFor(() async {
        try {
          return await connection.getProperty('user-data/uosc/menu/type') ==
              null;
        } on StateError {
          return true;
        }
      }, 'existing uosc menu closed');
      result['existing_uosc_menu_preserved'] = true;
    }
    Future<void> toggleMenuFullscreen({bool mouse = false}) async {
      final uosc = await openMenu();
      result['menu_renderer'] = uosc ? 'uosc' : 'builtin';
      if (Platform.environment['STREAMPATH_EXPECT_UOSC'] == '1' && !uosc) {
        throw StateError('uosc menu handshake failed');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await connection.command([
        'screenshot-to-file',
        p.join(directory.path, 'window-menu.png'),
        'window',
      ]);
      if (mouse && !uosc) {
        final height = await connection.getProperty('osd-height') as int;
        await connection.command([
          'mouse',
          (80 * height / 720).round(),
          (107 * height / 720).round(),
          0,
        ]);
      } else {
        await connection.command(['keypress', 'ENTER']);
      }
    }

    await toggleMenuFullscreen(mouse: true);
    await waitFor(() async => !coordinator.fullscreen, 'menu exits fullscreen');
    SetWindowPos(root, 0, 100, 100, 900, 700, SWP_NOZORDER | SWP_NOACTIVATE);
    await waitFor(() async {
      final w = await connection.getProperty('osd-width');
      final h = await connection.getProperty('osd-height');
      return w is int && h is int && h > 0 && w / h < 1.5;
    }, 'non-widescreen layout');
    await toggleMenuFullscreen(mouse: true);
    await waitFor(() async => coordinator.fullscreen, 'menu enters fullscreen');
    result['menu_non_widescreen'] = true;
    PostMessage(root, WM_SYSCOMMAND, 0x1f40, 0);
    await waitFor(
      () async => !coordinator.fullscreen,
      'system menu exits fullscreen',
    );
    PostMessage(root, WM_SYSCOMMAND, 0x1f40, 0);
    await waitFor(
      () async => coordinator.fullscreen,
      'system menu enters fullscreen',
    );
    result['window_menu'] = true;
    result['args_have_wid'] = launched.args.any(
      (a) => a == '--wid=${launch.host}',
    );
    result['parent_matches'] = GetParent(window) == launch.host;
    result['input_enabled'] = IsWindowEnabled(window) != 0;
    final gui = calloc<GUITHREADINFO>();
    try {
      gui.ref.cbSize = sizeOf<GUITHREADINFO>();
      final thread = GetWindowThreadProcessId(window, nullptr);
      result['keyboard_focus'] =
          GetGUIThreadInfo(thread, gui) != 0 && gui.ref.hwndFocus == window;
      if (result['keyboard_focus'] != true) {
        throw StateError('MPV keyboard focus was not restored');
      }
    } finally {
      free(gui);
    }
    result['vo'] = await connection.getProperty('current-vo');
    result['input_default_bindings'] = await connection.getProperty(
      'input-default-bindings',
    );
    SendMessage(window, WM_KEYDOWN, VK_F23, 1);
    SendMessage(window, WM_KEYUP, VK_F23, 0xc0000001);
    await waitFor(
      () async => await connection.getProperty('speed') == 1.5,
      'native key input',
    );
    result['native_key_input'] = true;
    for (var i = 0; i < 3; i++) {
      await connection.command(['cycle', 'fullscreen']);
      await waitFor(() async => !coordinator.fullscreen, 'exit fullscreen $i');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (await connection.getProperty('fullscreen') != false) {
        throw StateError('Fullscreen echo');
      }
      await connection.command(['cycle', 'fullscreen']);
      await waitFor(() async => coordinator.fullscreen, 'enter fullscreen $i');
    }
    result['fullscreen_cycles'] = 3;
    result['fullscreen_stays_child'] = GetParent(window) == launch.host;
    final hostRect = calloc<RECT>();
    final childRect = calloc<RECT>();
    try {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      GetClientRect(launch.host, hostRect);
      GetClientRect(window, childRect);
      result['surface_size'] = [hostRect.ref.right, hostRect.ref.bottom];
      result['player_size'] = [childRect.ref.right, childRect.ref.bottom];
      if (hostRect.ref.right != childRect.ref.right ||
          hostRect.ref.bottom != childRect.ref.bottom ||
          hostRect.ref.right <= 0) {
        throw StateError('Video surface resize mismatch');
      }
    } finally {
      free(hostRect);
      free(childRect);
    }
    await connection.command(['cycle', 'fullscreen']);
    await waitFor(() async => !coordinator.fullscreen, 'windowed mode');
    await connection.setProperty('window-maximized', true);
    await waitFor(
      () async => IsZoomed(GetAncestor(launch.host, GA_ROOT)) != 0,
      'maximize',
    );
    await MpvWindowCoordinator.channel.invokeMethod<void>('maximize', {
      'host': launch.host,
      'enabled': false,
    });
    await waitFor(
      () async => IsZoomed(GetAncestor(launch.host, GA_ROOT)) == 0,
      'restore',
    );
    result['maximize_restore'] = true;
    await connection.setProperty('window-minimized', true);
    await waitFor(
      () async => IsIconic(GetAncestor(launch.host, GA_ROOT)) != 0,
      'minimize',
    );
    await MpvWindowCoordinator.channel.invokeMethod<void>('minimize', {
      'host': launch.host,
      'enabled': false,
    });
    await waitFor(
      () async => IsIconic(GetAncestor(launch.host, GA_ROOT)) == 0,
      'restore minimized window',
    );
    result['minimize_restore'] = true;
    await connection.setProperty('pause', false);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final uosc = await openMenu();
    if (uosc) {
      await connection.command([
        'script-message-to',
        'uosc',
        'select-menu-item',
        'streampath-window-menu',
        '4',
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } else {
      await waitBinding('down', 'streampath-menu-down');
      for (var i = 0; i < 3; i++) {
        await connection.command(['keypress', 'DOWN']);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    await connection.command(['keypress', 'ENTER']);
    await waitFor(() async => coordinator.active == null, 'menu detach');
    result['menu_detach'] = true;
    await coordinator.prepareForClose();
    result['system_menu_removed'] =
        GetMenuState(systemMenu, 0x1f10, MF_BYCOMMAND) == 0xffffffff &&
        GetMenuState(systemMenu, 0x1f20, MF_BYCOMMAND) == 0xffffffff;
    if (result['system_menu_removed'] != true) {
      throw StateError('StreamPath system menu not removed');
    }
    final detached = await connection.getProperty('window-id') as int;
    result['same_pid'] = launched.process.pid;
    result['pipe'] = launched.ipcPipeName;
    result['detached'] =
        GetParent(detached) != launch.host &&
        GetWindowLongPtr(detached, GWL_STYLE) & WS_CHILD == 0;
    result['notices_count'] = notices.length;
    result['passed'] = result['detached'] == true && notices.isEmpty;
  } catch (error, stack) {
    result['passed'] = false;
    result['error'] = '$error';
    await File(
      p.join(directory.path, 'error.log'),
    ).writeAsString('$error\n$stack');
  } finally {
    await client?.dispose();
    await File(
      p.join(directory.path, 'result.json'),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(result));
    if (result['passed'] == true) {
      await const MethodChannel(
        'streampath/appearance',
      ).invokeMethod<void>('close');
    } else {
      try {
        await coordinator.stop();
      } on Object {
        /* 失败现场保留在独立验收目录。 */
      }
      if (coordinator.active == null) {
        await const MethodChannel(
          'streampath/appearance',
        ).invokeMethod<void>('close');
      }
    }
  }
}
