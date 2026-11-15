import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../core/errors/app_exception.dart';
import '../../data/models/player_config.dart';
import '../../data/models/mpv_menu_shortcuts.dart';
import '../../data/models/video_window_mode.dart';
import 'mpv_session_controller.dart';
import 'mpv_window_menu.dart';
import 'player_process_controller.dart';

class EmbeddedMpvLaunch {
  EmbeddedMpvLaunch({
    required this.host,
    required this.title,
    required this.wasFullscreen,
  });

  final int host;
  final String title;
  final bool wasFullscreen;
  PlayerProcessIdentity? identity;
  String? pipeName;
  MpvPropertySubscription? observer;
  StreamSubscription<MpvPropertyEvent>? events;
  Future<void> tail = Future<void>.value();
  Future<void> menuTail = Future<void>.value();
  int menuSequence = 0;
  bool detaching = false;
  bool ready = false;
  bool binding = false;
  bool reconnecting = false;
  bool laidOut = false;
  bool visibleRequested = false;
  Future<void>? finishing;
  Directory? menuDirectory;
  final synchronizedValues = <String, List<bool>>{};
}

/// 窗口状态独立于媒体、播放列表和进度会话。
class MpvWindowCoordinator extends ChangeNotifier {
  MpvWindowCoordinator({
    required this.capabilityFile,
    this.menuLanguage,
    this.menuShortcuts,
    this.menuBaseDirectory,
  });

  static const channel = MethodChannel('streampath/mpv_window');
  static MpvWindowCoordinator? _handlerOwner;
  final File capabilityFile;
  final String Function()? menuLanguage;
  final MpvMenuShortcuts? Function()? menuShortcuts;
  final Directory? menuBaseDirectory;
  final _processes = PlayerProcessController();
  final _notices = StreamController<String>.broadcast();
  Stream<String> get notices => _notices.stream;
  EmbeddedMpvLaunch? active;
  EmbeddedMpvLaunch? _pending;
  String? _verifiedExecutable;
  File? _verifiedFile;
  FileStat? _verifiedStat;
  bool _checking = false;
  bool _preparing = false;
  String? warning;
  bool _closing = false;
  bool fullscreen = false;
  bool _maximized = false;
  bool _minimized = false;
  bool _disposed = false;
  Future<void>? _configuration;
  String? _configuredFingerprint;
  Future<void> Function(EmbeddedMpvLaunch launch)? onReady;

  /// 宿主挂载了内嵌播放页面，释放视频表面需要先等页面绘制。
  bool awaitsHostPaint = false;

  /// 宿主强制整窗重绘并等待帧结束；未提供时只请求新帧。
  Future<void> Function()? repaintHost;

  Future<T?> _native<T>(String method, [Map<String, Object?>? args]) =>
      channel.invokeMethod<T>(method, args);

  Future<void> configure(PlayerConfig config) {
    final operation = (_configuration ?? Future<void>.value()).then(
      (_) => _configure(config),
    );
    _configuration = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _configure(PlayerConfig config) async {
    if (!Platform.isWindows || _closing) return;
    _handlerOwner = this;
    channel.setMethodCallHandler(_nativeEvent);
    if (config.videoWindowMode == VideoWindowMode.external) {
      if (_pending != null || _preparing) {
        throw AppException.process('播放器仍在启动，请稍候再关闭。');
      }
      await detach();
      _verifiedExecutable = null;
      _configuredFingerprint = null;
      return;
    }
    try {
      final executable = await _resolveExecutable(config.executable);
      final name = p.basenameWithoutExtension(executable).toLowerCase();
      if (name != 'mpv' && !name.startsWith('mpv-')) {
        _verifiedExecutable = null;
        _notice('当前 MPV 未通过内嵌兼容检查，将继续使用独立窗口。');
        return;
      }
      final stat = await File(executable).stat();
      if (stat.type != FileSystemEntityType.file) {
        throw const FileSystemException('MPV executable does not exist');
      }
      final fingerprint = sha256
          .convert(
            utf8.encode(
              '$executable:${stat.size}:${stat.modified.microsecondsSinceEpoch}',
            ),
          )
          .toString();
      if (_configuredFingerprint == fingerprint) {
        _verifiedExecutable = config.executable;
        return;
      }
      _verifiedExecutable = null;
      var cached = false;
      if (await capabilityFile.exists()) {
        try {
          final decoded = jsonDecode(await capabilityFile.readAsString());
          cached = decoded is Map && decoded['fingerprint'] == fingerprint;
        } on FormatException {
          cached = false;
        }
      }
      _checking = true;
      final supported = cached || await _probe(executable);
      _checking = false;
      if (supported) {
        _verifiedExecutable = config.executable;
        _verifiedFile = File(executable);
        _verifiedStat = stat;
        _configuredFingerprint = fingerprint;
        try {
          await capabilityFile.parent.create(recursive: true);
          await capabilityFile.writeAsString(
            jsonEncode({'fingerprint': fingerprint}),
          );
        } on FileSystemException catch (error) {
          debugPrint(
            'MPV embedding capability cache write failed: ${error.osError?.errorCode}',
          );
        }
      } else {
        _notice('当前 MPV 未通过内嵌兼容检查，将继续使用独立窗口。');
      }
    } on FileSystemException catch (error) {
      _checking = false;
      debugPrint(
        'MPV embedding capability check failed: ${error.osError?.errorCode}',
      );
      _notice('当前 MPV 未通过内嵌兼容检查，将继续使用独立窗口。');
    } on ProcessException catch (error) {
      _checking = false;
      debugPrint('MPV embedding capability process failed: ${error.errorCode}');
      _notice('当前 MPV 未通过内嵌兼容检查，将继续使用独立窗口。');
    } on PlatformException catch (error) {
      _checking = false;
      debugPrint('MPV embedding native check failed: ${error.code}');
      _notice('当前 MPV 未通过内嵌兼容检查，将继续使用独立窗口。');
    } on TimeoutException {
      _checking = false;
      _notice('当前 MPV 未通过内嵌兼容检查，将继续使用独立窗口。');
    } on MissingPluginException {
      _checking = false;
    }
  }

  Future<String> _resolveExecutable(String executable) async {
    if (p.isAbsolute(executable)) return executable;
    // 与 Process.start 的默认 .exe 解析一致，避免选中 .com 包装进程。
    final command = p.extension(executable).isEmpty
        ? '$executable.exe'
        : executable;
    final result = await Process.run('where.exe', [command]);
    if (result.exitCode != 0) {
      throw const FileSystemException('MPV not found in PATH');
    }
    return (result.stdout as String).trim().split(RegExp(r'[\r\n]+')).first;
  }

  Future<bool> _probe(String executable) async {
    final host = await _native<int>('create');
    if (host == null) return false;
    final pipe =
        r'\\.\pipe\streampath_embed_check_' +
        DateTime.now().microsecondsSinceEpoch.toString();
    Process? process;
    PlayerProcessIdentity? identity;
    final client = MpvSessionController(pipeName: pipe);
    try {
      process = await Process.start(executable, [
        '--no-config',
        '--load-scripts=no',
        '--idle=yes',
        '--force-window=yes',
        '--pause=yes',
        '--ao=null',
        '--input-ipc-server=$pipe',
        '--wid=$host',
      ]);
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      identity = await _processes.capture(process.pid);
      if (identity == null ||
          !await client.connect(timeout: const Duration(seconds: 5))) {
        return false;
      }
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      var attached = false;
      while (DateTime.now().isBefore(deadline)) {
        attached =
            await _native<bool>('bind', {
              'host': host,
              'pid': identity.pid,
              'creation': identity.creationTime,
            }) ==
            true;
        if (attached) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (!attached) return false;
      await client.setProperty('window-minimized', true);
      await client.setProperty('wid', -1);
      final detached = await _waitDetached(client, host);
      if (!detached) return false;
      final version = await client.getProperty('mpv-version');
      debugPrint('MPV embedding capability verified: $version');
      return true;
    } on StateError {
      return false;
    } on TimeoutException {
      return false;
    } finally {
      if (client.isConnected) {
        try {
          await client.command(['quit']);
        } on StateError {
          /* 退出命令可能先关闭管道。 */
        } on TimeoutException {
          /* 继续按确切身份回收探测进程。 */
        }
      }
      await client.dispose();
      if (process != null) {
        try {
          await process.exitCode.timeout(const Duration(seconds: 3));
        } on TimeoutException {
          await _processes.terminateIfOwned(
            pid: process.pid,
            expected: identity,
            ipcPipeName: pipe,
            requirePipeOwner: false,
          );
          await process.exitCode.timeout(const Duration(seconds: 3));
        }
      }
      await _native<void>('release', {'host': host});
    }
  }

  Future<EmbeddedMpvLaunch?> prepare(
    PlayerConfig config,
    String title, {
    bool discMenu = false,
  }) async {
    if (config.videoWindowMode != VideoWindowMode.embedded ||
        !Platform.isWindows ||
        _closing) {
      return null;
    }
    // 菜单重新定位会影响导航状态，尚未通过实盘转换验收时保留外部模式。
    if (discMenu) {
      _notice('光盘菜单暂时使用独立窗口播放。');
      return null;
    }
    if (_checking ||
        _verifiedExecutable != config.executable ||
        _pending != null ||
        _preparing) {
      _notice('内嵌播放器尚未就绪，本次使用独立窗口播放。');
      return null;
    }
    _preparing = true;
    try {
      final current = await _verifiedFile!.stat();
      if (current.size != _verifiedStat!.size ||
          current.modified != _verifiedStat!.modified) {
        _verifiedExecutable = null;
        _configuredFingerprint = null;
        unawaited(configure(config));
        _notice('内嵌播放器尚未就绪，本次使用独立窗口播放。');
        return null;
      }
      await detach();
      if (_closing) return null;
      final state = await _native<Map<Object?, Object?>>('state');
      final host = await _native<int>('create');
      if (host == null) return null;
      final launch = EmbeddedMpvLaunch(
        host: host,
        title: title,
        wasFullscreen: state?['fullscreen'] == true,
      );
      _pending = launch;
      return launch;
    } on PlatformException catch (error) {
      debugPrint('MPV embedding preparation failed: ${error.code}');
      _notice('内嵌播放器尚未就绪，本次使用独立窗口播放。');
      return null;
    } on AppException {
      _notice('内嵌播放器尚未就绪，本次使用独立窗口播放。');
      return null;
    } on FileSystemException {
      _notice('内嵌播放器尚未就绪，本次使用独立窗口播放。');
      return null;
    } finally {
      _preparing = false;
    }
  }

  static void applyArguments(List<String> args, EmbeddedMpvLaunch? launch) {
    if (launch == null) return;
    var skip = false;
    args.removeWhere((arg) {
      if (skip) {
        skip = false;
        return true;
      }
      if (arg == '--wid') {
        skip = true;
        return true;
      }
      return arg.startsWith('--wid=');
    });
    args.addAll([
      '--wid=${launch.host}',
      '--script-opts-append=streampath-window-embedded=yes',
    ]);
  }

  Future<void> abandon(EmbeddedMpvLaunch? launch) async {
    if (launch == null) return;
    if (identical(_pending, launch)) _pending = null;
    await _native<void>('release', {'host': launch.host});
  }

  Future<void> _bindingFailed(EmbeddedMpvLaunch launch) async {
    if (!identical(active, launch) || _disposed) return;
    launch.binding = false;
    try {
      await detach();
      _notice('内嵌播放器尚未就绪，本次使用独立窗口播放。');
    } on AppException {
      if (!identical(active, launch) || launch.detaching || _disposed) return;
      // 未确认脱嵌时保留表面及会话，避免隐藏仍在播放的 MPV。
      launch.ready = true;
      if (launch.observer == null && launch.identity != null) _observe(launch);
      await onReady?.call(launch);
      _notice('无法转为独立窗口，已保留播放器。请重试或结束播放。');
    }
  }

  Future<void> bind(
    EmbeddedMpvLaunch? launch,
    PlayerProcessIdentity? identity,
    String pipeName,
  ) async {
    if (launch == null) return;
    launch.binding = true;
    warning = null;
    launch.identity = identity;
    launch.pipeName = pipeName;
    active = launch;
    if (identical(_pending, launch)) _pending = null;
    notifyListeners();
    try {
      if (identity == null) {
        throw StateError('MPV process identity unavailable');
      }
      final startup = Stopwatch()..start();
      const startupLimit = Duration(minutes: 2);
      var bound = false;
      while (startup.elapsed < startupLimit &&
          !_disposed &&
          identical(active, launch) &&
          !launch.detaching) {
        bound =
            await _native<bool>('bind', {
              'host': launch.host,
              'pid': identity.pid,
              'creation': identity.creationTime,
            }) ==
            true;
        if (bound) break;
        if (await _processes.probeOwned(identity) ==
            PlayerProcessLiveness.exited) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (_disposed || !identical(active, launch) || launch.detaching) return;
      if (!bound) throw StateError('MPV child window unavailable');
      final initial = MpvSessionController(pipeName: pipeName);
      try {
        Object? desiredFullscreen;
        var connected = false;
        // 窗口创建、管道连接与属性读取共用启动预算，单次 I/O 超时不代表播放失败。
        while (startup.elapsed < startupLimit &&
            !_disposed &&
            identical(active, launch) &&
            !launch.detaching) {
          if (await _processes.probeOwned(identity) ==
              PlayerProcessLiveness.exited) {
            await _finish(launch);
            return;
          }
          if (!initial.isConnected &&
              !await initial.connect(
                timeout: const Duration(milliseconds: 500),
              )) {
            continue;
          }
          final owner = initial.serverProcessId;
          if (owner == null) {
            await initial.disconnect();
            await Future<void>.delayed(const Duration(milliseconds: 50));
            continue;
          }
          if (owner != identity.pid) {
            throw StateError('MPV window pipe ownership mismatch');
          }
          try {
            desiredFullscreen = await initial.getProperty('fullscreen');
            connected = true;
            break;
          } on TimeoutException {
            // 请求超时会关闭该连接；下次尝试重新连接并核对归属。
          } on StateError {
            if (initial.isConnected) rethrow;
          }
        }
        if (_disposed || !identical(active, launch) || launch.detaching) return;
        if (!connected) {
          throw StateError('MPV initial window connection unavailable');
        }
        await _native<void>('fullscreen', {
          'enabled': desiredFullscreen == true,
        });
        try {
          final base = menuBaseDirectory ?? Directory.systemTemp;
          await base.create(recursive: true);
          final directory = await base.createTemp('streampath-window-menu-');
          launch.menuDirectory = directory;
          final script = File(
            p.join(directory.path, 'streampath_window_menu.lua'),
          );
          await script.writeAsString(
            mpvWindowMenuScript(
              pipeName,
              menuLanguage?.call() ?? 'zh-CN',
              menuShortcuts?.call(),
            ),
          );
          await initial.command(['load-script', script.path]);
        } on FileSystemException catch (error) {
          debugPrint(
            'MPV window menu file failed: ${error.osError?.errorCode}',
          );
        } on StateError catch (error) {
          debugPrint('MPV window menu load failed: ${error.runtimeType}');
        } on TimeoutException {
          debugPrint('MPV window menu load timed out');
        }
      } finally {
        await initial.dispose();
      }
      if (_disposed || !identical(active, launch) || launch.detaching) return;
      launch.ready = true;
      try {
        final labels = mpvWindowMenuLabels(menuLanguage?.call() ?? 'zh-CN');
        await _native<void>('menuInstall', {
          'host': launch.host,
          'fullscreen': labels[1],
          'detach': labels[4],
          'stop': labels[5],
        });
      } on PlatformException catch (error) {
        debugPrint('MPV system menu installation failed: ${error.code}');
      }
      _observe(launch);
      await onReady?.call(launch);
    } on StateError catch (error) {
      debugPrint('MPV embedding bind failed: ${error.runtimeType}');
      await _bindingFailed(launch);
    } on PlatformException catch (error) {
      debugPrint('MPV embedding bind failed: ${error.code}');
      await _bindingFailed(launch);
    } on TimeoutException {
      await _bindingFailed(launch);
    } finally {
      launch.binding = false;
    }
  }

  void _observe(EmbeddedMpvLaunch launch) {
    final observer = MpvPropertySubscription(
      launch.pipeName!,
      ['fullscreen', 'window-maximized', 'window-minimized', 'window-id'],
      keepConnecting: () async =>
          !_disposed &&
          identical(active, launch) &&
          !launch.detaching &&
          await _processes.probeOwned(launch.identity) !=
              PlayerProcessLiveness.exited,
    );
    launch.observer = observer;
    launch.events = observer.events.listen(
      (event) {
        if (event.name == 'client-message') {
          final args = event.value;
          if (args is! List ||
              args.isEmpty ||
              args.first != 'streampath-window-menu') {
            return;
          }
          launch.menuTail = launch.menuTail
              .then((_) => _menuAction(launch, event.value))
              .catchError((Object error) {
                debugPrint('MPV menu action failed: ${error.runtimeType}');
                _notice('播放器窗口同步失败，可尝试转为独立窗口。');
              });
          return;
        }
        launch.tail = launch.tail
            .then((_) => _property(launch, event))
            .catchError((Object error) {
              debugPrint(
                'MPV window synchronization failed: ${error.runtimeType}',
              );
              _notice('播放器窗口同步失败，可尝试转为独立窗口。');
            });
      },
      onError: (Object error) {
        unawaited(_connectionEnded(launch));
      },
      onDone: () => unawaited(_connectionEnded(launch)),
    );
    observer.start();
  }

  Future<void> _property(
    EmbeddedMpvLaunch launch,
    MpvPropertyEvent event,
  ) async {
    if (!identical(active, launch) || launch.detaching || _closing) return;
    final synchronized = launch.synchronizedValues[event.name];
    if (synchronized != null && event.value is bool) {
      final index = synchronized.indexOf(event.value as bool);
      if (index >= 0) {
        synchronized.removeAt(index);
        return;
      }
    }
    final state = await _native<Map<Object?, Object?>>('state');
    if (!identical(active, launch) || launch.detaching || _closing) return;
    if (event.name == 'window-id') {
      final identity = launch.identity!;
      await _native<bool>('bind', {
        'host': launch.host,
        'pid': identity.pid,
        'creation': identity.creationTime,
      });
    } else if (event.value is bool &&
        (event.name == 'window-maximized' && state?['fullscreen'] == true
                ? false
                : state?[event.name]) !=
            event.value) {
      final method = switch (event.name) {
        'fullscreen' => 'fullscreen',
        'window-maximized' => 'maximize',
        'window-minimized' => 'minimize',
        _ => null,
      };
      if (method != null) {
        await _native<void>(method, {
          'host': launch.host,
          'enabled': event.value,
        });
      }
    }
  }

  Future<void> _menuAction(
    EmbeddedMpvLaunch launch,
    Object? payload, {
    bool native = false,
  }) async {
    if (!identical(active, launch) ||
        launch.detaching ||
        _closing ||
        payload is! List ||
        payload.length != 4 ||
        payload[0] != 'streampath-window-menu' ||
        payload[1] != launch.pipeName) {
      return;
    }
    final sequence = int.tryParse('${payload[2]}');
    if (sequence == null || (!native && sequence <= launch.menuSequence)) {
      return;
    }
    final action = payload[3];
    if (action != 'fullscreen' &&
        action != 'maximize' &&
        action != 'minimize' &&
        action != 'detach' &&
        action != 'stop') {
      return;
    }
    if (!await _processes.ownsPipe(launch.identity, launch.pipeName!) ||
        !identical(active, launch) ||
        launch.detaching ||
        _closing) {
      return;
    }
    if (!native) launch.menuSequence = sequence;
    if (action == 'detach') {
      await detach();
    } else if (action == 'stop') {
      await stop();
    } else {
      final state = await _native<Map<Object?, Object?>>('state');
      if (!identical(active, launch) || launch.detaching || _closing) return;
      if (action == 'fullscreen') {
        await _native<void>('fullscreen', {
          'enabled': state?['fullscreen'] != true,
        });
      } else if (action == 'maximize') {
        await _native<void>('maximize', {
          'host': launch.host,
          'enabled': state?['window-maximized'] != true,
        });
      } else {
        await _native<void>('minimize', {'host': launch.host, 'enabled': true});
      }
    }
  }

  Future<void> _nativeEvent(MethodCall call) async {
    if (call.method == 'menuAction') {
      final launch = active;
      final args = call.arguments as Map;
      if (launch == null || args['host'] != launch.host) return;
      launch.menuTail = launch.menuTail
          .then(
            (_) => _menuAction(launch, [
              'streampath-window-menu',
              launch.pipeName,
              '0',
              args['action'],
            ], native: true),
          )
          .catchError((Object error) {
            debugPrint('MPV system menu action failed: ${error.runtimeType}');
            _notice('播放器窗口同步失败，可尝试转为独立窗口。');
          });
      return;
    }
    if (call.method != 'windowState') return;
    final state = call.arguments as Map;
    final changed = fullscreen != (state['fullscreen'] == true);
    final maximized =
        state['fullscreen'] != true && state['window-maximized'] == true;
    final minimized = state['window-minimized'] == true;
    final windowChanged = _maximized != maximized || _minimized != minimized;
    _maximized = maximized;
    _minimized = minimized;
    fullscreen = state['fullscreen'] == true;
    if (changed && !_disposed) notifyListeners();
    if (!changed && !windowChanged) return;
    final launch = active;
    if (launch == null || !launch.ready || launch.detaching || _closing) return;
    launch.tail = launch.tail
        .then((_) async {
          if (!identical(active, launch) || launch.detaching) return;
          final client = MpvSessionController(pipeName: launch.pipeName!);
          try {
            if (!await client.connect(timeout: const Duration(seconds: 1))) {
              return;
            }
            final currentState = await _native<Map<Object?, Object?>>('state');
            final values = {
              'fullscreen': currentState?['fullscreen'] == true,
              'window-maximized':
                  currentState?['fullscreen'] != true &&
                  currentState?['window-maximized'] == true,
              'window-minimized': currentState?['window-minimized'] == true,
            };
            for (final property in values.keys) {
              if (await client.getProperty(property) != values[property]) {
                launch.synchronizedValues
                    .putIfAbsent(property, () => [])
                    .add(values[property]!);
                await client.setProperty(property, values[property]!);
              }
            }
          } finally {
            await client.dispose();
          }
        })
        .catchError((Object error) {
          debugPrint(
            'MPV host state synchronization failed: ${error.runtimeType}',
          );
        });
  }

  Future<void> _connectionEnded(EmbeddedMpvLaunch launch) async {
    if (!identical(active, launch) || launch.detaching || launch.reconnecting) {
      return;
    }
    launch.reconnecting = true;
    try {
      await launch.events?.cancel();
      await launch.observer?.dispose();
      if (_disposed || !identical(active, launch) || launch.detaching) return;
      // 事件连接可独立恢复，只有确认进程退出才结束播放页。
      if (await _processes.probeOwned(launch.identity) ==
          PlayerProcessLiveness.exited) {
        await _finish(launch);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!_disposed && identical(active, launch) && !launch.detaching) {
        if (await _processes.probeOwned(launch.identity) ==
            PlayerProcessLiveness.exited) {
          await _finish(launch);
        } else {
          _observe(launch);
        }
      }
    } finally {
      launch.reconnecting = false;
    }
  }

  Future<bool> _waitDetached(MpvSessionController client, int host) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      final window = await client.getProperty('window-id');
      if (window is int &&
          await _native<bool>('detached', {'host': host, 'window': window}) ==
              true) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return false;
  }

  Future<void> detach() async {
    final launch = active;
    if (launch == null) return;
    if (launch.binding) throw AppException.process('播放器仍在启动，请稍候再关闭。');
    if (launch.detaching) {
      throw AppException.process('播放器正在转为独立窗口，请稍候。');
    }
    launch.detaching = true;
    await launch.tail;
    final client = MpvSessionController(pipeName: launch.pipeName!);
    try {
      final liveness = await _processes.probeOwned(launch.identity);
      if (liveness == PlayerProcessLiveness.exited) {
        await _finish(launch);
        return;
      }
      if (liveness != PlayerProcessLiveness.alive ||
          !await client.connect(timeout: const Duration(seconds: 2)) ||
          !await _processes.ownsPipe(launch.identity, launch.pipeName!)) {
        throw StateError('MPV detach identity or IPC unavailable');
      }
      await client.setProperty('wid', -1);
      if (!await _waitDetached(client, launch.host)) {
        throw StateError('MPV detach not confirmed');
      }
      await client.command([
        'script-message',
        'streampath-window-mode',
        'external',
      ]);
      await _finish(launch);
    } on StateError {
      launch.detaching = false;
      throw AppException.process('无法转为独立窗口，已保留播放器。请重试或结束播放。');
    } on TimeoutException {
      launch.detaching = false;
      throw AppException.process('无法转为独立窗口，已保留播放器。请重试或结束播放。');
    } on PlatformException {
      launch.detaching = false;
      throw AppException.process('无法转为独立窗口，已保留播放器。请重试或结束播放。');
    } finally {
      await client.dispose();
    }
  }

  Future<void> stop() async {
    final launch = active;
    if (launch == null) return;
    if (launch.detaching) throw AppException.process('播放器正在结束，请稍候。');
    // 结束期间忽略事件断开的探测，避免进程退出较慢时误报窗口同步失败。
    launch.detaching = true;
    final client = MpvSessionController(pipeName: launch.pipeName!);
    try {
      if (await _processes.probeOwned(launch.identity) ==
          PlayerProcessLiveness.exited) {
        await _finish(launch);
        return;
      }
      if (!await client.connect(timeout: const Duration(seconds: 2))) {
        if (await _processes.probeOwned(launch.identity) ==
            PlayerProcessLiveness.exited) {
          await _finish(launch);
          return;
        }
        throw AppException.process('无法结束播放，请在 MPV 中退出后重试。');
      }
      if (!await _processes.ownsPipe(launch.identity, launch.pipeName!)) {
        throw AppException.process('无法结束播放，请在 MPV 中退出后重试。');
      }
      try {
        await client.command(['quit']);
      } on StateError {
        /* MPV 可先关闭连接再回复。 */
      } on TimeoutException {
        /* 以确切进程退出结果确认命令是否生效。 */
      }
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline)) {
        if (await _processes.probeOwned(launch.identity) ==
            PlayerProcessLiveness.exited) {
          await _finish(launch);
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      throw AppException.process('无法结束播放，请在 MPV 中退出后重试。');
    } catch (_) {
      if (identical(active, launch)) launch.detaching = false;
      rethrow;
    } finally {
      await client.dispose();
    }
  }

  Future<void> _finish(EmbeddedMpvLaunch launch) async {
    final existing = launch.finishing;
    if (existing != null) return existing;
    final finishing = _finishLaunch(launch);
    launch.finishing = finishing;
    try {
      await finishing;
    } catch (_) {
      launch.finishing = null;
      rethrow;
    }
  }

  Future<void> _finishLaunch(EmbeddedMpvLaunch launch) async {
    launch.detaching = true;
    await launch.events?.cancel();
    await launch.observer?.dispose();
    final menuDirectory = launch.menuDirectory;
    if (menuDirectory != null) {
      try {
        await menuDirectory.delete(recursive: true);
      } on FileSystemException catch (error) {
        debugPrint(
          'MPV window menu cleanup failed: ${error.osError?.errorCode}',
        );
      }
    }
    // 先结束宿主播放页并恢复窗口状态，等返回页面绘制完成后再销毁视频表面。
    if (identical(active, launch)) active = null;
    if (!_disposed) notifyListeners();
    await _waitHostPaint();
    try {
      await _native<void>('fullscreen', {'enabled': launch.wasFullscreen});
    } on PlatformException catch (error) {
      // 全屏恢复失败不影响容器释放。
      debugPrint('MPV host fullscreen restore failed: ${error.code}');
    }
    await _waitHostPaint();
    await _native<void>('release', {'host': launch.host});
    // 表面销毁会让该区域失效，等宿主重绘完成后再结束。
    await _waitHostPaint();
    if (!_disposed) notifyListeners();
  }

  Future<void> _waitHostPaint() async {
    if (!awaitsHostPaint) return;
    final repaint = repaintHost;
    if (repaint != null) {
      await repaint().timeout(
        const Duration(milliseconds: 600),
        onTimeout: () {},
      );
      return;
    }
    final binding = SchedulerBinding.instance;
    for (var frame = 0; frame < 2; frame++) {
      if (binding.schedulerPhase == SchedulerPhase.idle) {
        binding.scheduleFrame();
      }
      await binding.endOfFrame.timeout(
        const Duration(milliseconds: 400),
        onTimeout: () {},
      );
    }
  }

  Future<void> setVisible(bool enabled) async {
    final launch = active;
    if (launch != null && !launch.detaching) {
      final changed = launch.visibleRequested != enabled;
      launch.visibleRequested = enabled;
      if (enabled && !launch.laidOut) return;
      await _native<void>('visible', {'host': launch.host, 'enabled': enabled});
      if (enabled &&
          changed &&
          launch.visibleRequested &&
          identical(active, launch) &&
          !launch.detaching) {
        await focus();
      }
    }
  }

  Future<void> setBounds(int host, int x, int y, int width, int height) async {
    if (active?.host != host || active!.detaching) return;
    try {
      await _native<void>('bounds', {
        'host': host,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
      });
      final launch = active;
      if (launch?.host == host && !launch!.detaching) {
        final firstLayout = !launch.laidOut;
        launch.laidOut = true;
        if (launch.visibleRequested) await setVisible(true);
        if (firstLayout &&
            launch.visibleRequested &&
            identical(active, launch) &&
            !launch.detaching) {
          await focus();
        }
      }
    } on PlatformException catch (error) {
      debugPrint('MPV surface layout failed: ${error.code}');
      if (active?.host == host && !active!.detaching) {
        _notice('播放器窗口同步失败，可尝试转为独立窗口。');
      }
    }
  }

  Future<void> focus() async {
    final launch = active;
    if (launch != null) {
      await _native<bool>('focus', {'host': launch.host});
    }
  }

  Future<void> prepareForClose() async {
    _closing = true;
    try {
      await _configuration;
      if (_pending != null || _preparing) {
        throw AppException.process('播放器仍在启动，请稍候再关闭。');
      }
      await setVisible(false);
      await detach();
    } on Object {
      _closing = false;
      await setVisible(true);
      rethrow;
    }
  }

  void _notice(String message) {
    if (_disposed || warning == message) return;
    warning = message;
    _notices.add(message);
    if (active != null) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (identical(_handlerOwner, this)) {
      channel.setMethodCallHandler(null);
      _handlerOwner = null;
    }
    unawaited(_notices.close());
    super.dispose();
  }
}
