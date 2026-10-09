// 隔离便携副本中的 Windows Profile 诊断入口，不访问正式配置或服务器。
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' show FramePhase;

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/core/utils/app_paths.dart';
import 'package:streampath/data/local/directory_cache.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/appearance_config.dart';
import 'package:streampath/data/models/server_profile.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/main.dart' show StreamPathApp;
import 'package:streampath/presentation/pages/browser_page.dart';
import 'package:streampath/presentation/theme/appearance_controller.dart';

import '../test/helpers/shell_test_app_state.dart';

final _rootKey = GlobalKey();
final _frames = <Map<String, Object?>>[];
final _operations = <Map<String, Object?>>[];
String _phase = 'startup';
int _requests = 0;
int _responseBytes = 0;
int _enterNotifications = 0;

class _ProbeAppState extends ShellTestAppState {
  _ProbeAppState({
    required super.configStore,
    required super.playbackHistoryStore,
    required super.progressService,
    super.directoryCache,
    super.mediaLibraryStore,
    required this.suppressEnterNotifications,
  });

  final bool suppressEnterNotifications;

  @override
  void notifyListeners() {
    if (_phase.startsWith('enter-')) {
      _enterNotifications++;
      if (suppressEnterNotifications) return;
    }
    super.notifyListeners();
  }
}

Element _find(bool Function(Widget) matches) {
  Element? result;
  void visit(Element element) {
    if (result != null) return;
    if (matches(element.widget)) {
      result = element;
      return;
    }
    element.visitChildElements(visit);
  }

  visit(_rootKey.currentContext! as Element);
  return result ?? (throw StateError('Probe widget was not found'));
}

Future<void> _settle([int milliseconds = 450]) async {
  await Future<void>.delayed(Duration(milliseconds: milliseconds));
  await WidgetsBinding.instance.endOfFrame;
}

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  final executableDirectory = p.dirname(Platform.resolvedExecutable);
  if (!p.equals(AppPaths.projectRoot(), executableDirectory) ||
      !p.basename(executableDirectory).startsWith('transition-lab-')) {
    throw StateError('Run only an isolated portable transition-lab-* bundle');
  }
  final count = arguments.isEmpty ? 7 : int.parse(arguments[0]);
  final style = arguments.length > 1 && arguments[1] == 'classic'
      ? InterfaceStyle.classic
      : InterfaceStyle.glass;
  final run = arguments.length > 2 ? arguments[2] : 'baseline';
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final xml = StringBuffer(
    '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">',
  );
  for (var i = 0; i <= count; i++) {
    final name = i == 0 ? '' : 'Library_${(count - i + 1) * 7}';
    xml.write(
      '<d:response><d:href>/dav/$name/</d:href><d:propstat><d:prop>'
      '<d:displayname>$name</d:displayname><d:resourcetype><d:collection/>'
      '</d:resourcetype><d:getlastmodified>Mon, 05 Oct 2026 00:00:00 GMT'
      '</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status>'
      '</d:propstat></d:response>',
    );
  }
  xml.write('</d:multistatus>');
  final bytes = utf8.encode(xml.toString());
  server.listen((request) async {
    await request.drain<void>();
    _requests++;
    _responseBytes += bytes.length;
    request.response.statusCode = 207;
    request.response.headers.contentType = ContentType('application', 'xml');
    request.response.add(bytes);
    await request.response.close();
  });
  final configDirectory = await AppPaths.configDirectory();
  final cacheDirectory = await AppPaths.cacheDirectory();
  final config = StreamPathConfigStore.forPath(
    p.join(configDirectory.path, 'probe.json'),
  );
  final appearance = AppearanceConfig(
    style: style,
    material: WindowMaterialPreference.acrylic,
  );
  await config.save(
    StreamPathConfig(
      profiles: [
        ServerProfile(
          profileId: 'probe',
          name: 'Transition probe',
          serverUrl: 'http://127.0.0.1:${server.port}/dav',
          username: 'probe',
        ),
      ],
      mountedProfileIds: ['probe'],
      activeProfileId: 'probe',
      appearance: appearance,
    ),
  );
  Hive.init(cacheDirectory.path);
  final cache = DirectoryCache();
  await cache.init();
  sqfliteFfiInit();
  final progress = await PlaybackProgressService.open(
    p.join(cacheDirectory.path, 'probe.db'),
    factory: databaseFactoryFfi,
  );
  final library = MediaLibraryStore.forPath(
    p.join(configDirectory.path, 'library.json'),
  );
  await library.load();
  final app = _ProbeAppState(
    configStore: config,
    playbackHistoryStore: PlaybackHistoryStore.forPath(
      p.join(cacheDirectory.path, 'history.json'),
    ),
    progressService: progress,
    directoryCache: cache,
    mediaLibraryStore: library,
    suppressEnterNotifications:
        arguments.length > 3 && arguments[3] == 'no-notify',
  );
  await app.activateMountedProfile('probe');
  await app.getFilmCatalog();
  app.startupReady.value = true;
  final appearanceController = AppearanceController(initialConfig: appearance);
  await appearanceController.restoreForStartup();
  WidgetsBinding.instance.addTimingsCallback((timings) {
    for (final timing in timings) {
      _frames.add({
        'phase': _phase,
        'number': timing.frameNumber,
        'buildUs': timing.buildDuration.inMicroseconds,
        'rasterUs': timing.rasterDuration.inMicroseconds,
        'totalUs': timing.totalSpan.inMicroseconds,
        'startUs': timing.timestampInMicroseconds(FramePhase.vsyncStart),
      });
    }
  });
  runApp(
    KeyedSubtree(
      key: _rootKey,
      child: StreamPathApp(
        appState: app,
        appearanceController: appearanceController,
        autoConnect: false,
      ),
    ),
  );
  await _settle(1500);
  (_find(
            (widget) =>
                widget is InkWell && widget.key == const Key('sidebar-folders'),
          ).widget
          as InkWell)
      .onTap!();
  await _settle(1000);
  final viewport = WidgetsBinding.instance.platformDispatcher.views.first;
  for (var group = 0; group < 3; group++) {
    for (var iteration = 0; iteration < 20; iteration++) {
      _phase = 'enter-$group-$iteration';
      final requestStart = _requests;
      final start = developer.Timeline.now;
      (_find(
                (widget) =>
                    widget is ListTile &&
                    widget.key == const ValueKey('network-profile-probe'),
              ).widget
              as ListTile)
          .onTap!();
      await _settle();
      final entered = _find((widget) => widget is BrowserPage);
      _operations.add({
        'phase': _phase,
        'startUs': start,
        'endUs': developer.Timeline.now,
        'requests': _requests - requestStart,
      });
      _phase = 'pop-$group-$iteration';
      final popStart = developer.Timeline.now;
      Navigator.of(entered).pop();
      await _settle();
      _operations.add({
        'phase': _phase,
        'startUs': popStart,
        'endUs': developer.Timeline.now,
      });
    }
  }
  _phase = 'idle';
  await _settle(1500);
  final output = File(
    p.join(executableDirectory, '$run-$count-${style.name}.json'),
  );
  await output.writeAsString(
    jsonEncode({
      'pid': pid,
      'count': count,
      'mode': 'profile',
      'viewport': [viewport.physicalSize.width, viewport.physicalSize.height],
      'dpr': viewport.devicePixelRatio,
      'glassActive': appearanceController.glassActive,
      'backdrop': appearanceController.lastResult?.actualBackdrop.name,
      'requests': _requests,
      'responseBytes': _responseBytes,
      'enterNotifications': _enterNotifications,
      'frames': _frames,
      'operations': _operations,
    }),
  );
  runApp(const SizedBox.shrink());
  await _settle(300);
  await app.closeTestStores();
  app.dispose();
  appearanceController.dispose();
  await progress.close();
  await cache.close();
  await server.close(force: true);
  exit(0);
}
