// 隔离便携目录中的 Release 下载及共享界面诊断，正式入口不引用此文件。
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FramePhase;
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/core/utils/app_paths.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/appearance_config.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/features/video_cache/video_cache_models.dart';
import 'package:streampath/features/video_cache/video_cache_service.dart';
import 'package:streampath/main.dart' show StreamPathApp;
import 'package:streampath/presentation/theme/appearance_controller.dart';
import 'package:streampath/presentation/widgets/film_shelf.dart';
import '../test/helpers/shell_test_app_state.dart';

final _key = GlobalKey();
final _frames = <Map<String, Object?>>[];
String _phase = 'startup';
final _phaseChanges = <Map<String, Object>>[];

void _setPhase(String phase) {
  _phase = phase;
  _phaseChanges.add({
    'phase': phase,
    'wallUs': DateTime.now().microsecondsSinceEpoch,
  });
}

Element _find(bool Function(Widget) predicate, {Element? root}) {
  Element? result;
  void visit(Element element) {
    if (result != null) return;
    if (predicate(element.widget)) {
      result = element;
      return;
    }
    element.visitChildElements(visit);
  }

  visit(root ?? _key.currentContext! as Element);
  return result ?? (throw StateError('Probe widget was not found'));
}

Future<void> _wait(int milliseconds) async {
  await Future<void>.delayed(Duration(milliseconds: milliseconds));
  WidgetsBinding.instance.scheduleFrame();
  await WidgetsBinding.instance.endOfFrame;
}

Future<double> _direct(List<String> arguments) async {
  final client = HttpClient()..autoUncompress = false;
  final file = await File(arguments[1]).open(mode: FileMode.write);
  final clock = Stopwatch()..start();
  var flush = Stopwatch()..start();
  try {
    final request = await client.getUrl(Uri.parse(arguments[0]));
    request.headers.set('Range', 'bytes=0-1073741823');
    request.headers.set('Accept-Encoding', 'identity');
    final response = await request.close();
    if (response.statusCode != 206) throw StateError('Fixture range failed');
    await for (final bytes in response) {
      await file.writeFrom(bytes);
      if (flush.elapsedMilliseconds >= 2000) {
        await file.flush();
        flush.reset();
      }
    }
    await file.flush();
    return 1024 * 1000000 / clock.elapsedMicroseconds;
  } finally {
    await file.close();
    client.close(force: true);
  }
}

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  final root = p.dirname(Platform.resolvedExecutable);
  if (!p.basename(root).startsWith('video-cache-lab-') ||
      !p.equals(AppPaths.projectRoot(), root)) {
    throw StateError(
      'Run only in an isolated video-cache-lab-* portable bundle',
    );
  }
  try {
    await _run(root, arguments);
  } catch (error, stack) {
    await File(p.join(root, 'probe-error.log')).writeAsString('$error\n$stack');
    exit(1);
  }
}

Future<void> _run(String root, List<String> arguments) async {
  _setPhase('startup');
  final origin = 'http://127.0.0.1:${int.parse(arguments.first)}/';
  final data = await AppPaths.dataDirectory();
  final configDirectory = await AppPaths.configDirectory();
  final config = StreamPathConfigStore.forPath(
    p.join(configDirectory.path, 'probe.json'),
  );
  const appearance = AppearanceConfig(
    style: InterfaceStyle.glass,
    material: WindowMaterialPreference.acrylic,
  );
  await config.save(const StreamPathConfig(appearance: appearance));
  final cache = await VideoCacheService.open(
    dataDirectory: data,
    resolveTransfer: (source, path, strm) async => {
      'kind': 'http',
      'url': '$origin$path',
      'origin': origin,
      'headers': <String, String>{},
      'identity': 'fixture',
      'progress': 'https://fixture.invalid/$path',
    },
  );
  final progress = await PlaybackProgressService.open(
    p.join(data.path, 'progress.db'),
  );
  final app = ShellTestAppState(
    configStore: config,
    playbackHistoryStore: PlaybackHistoryStore.forPath(
      p.join(data.path, 'history.json'),
    ),
    progressService: progress,
    videoCacheService: cache,
  );
  final catalog = await app.getFilmCatalog();
  final store = catalog.store;
  final db = await databaseFactoryFfi.openDatabase(store.path);
  final rootId = await store.addRoot(
    sourceId: 'fixture',
    kind: MediaSourceKind.webdav,
    path: 'Library',
    type: FilmMediaType.movie,
    name: 'Offline cache fixture',
  );
  await db.transaction((txn) async {
    for (var i = 1; i <= 80; i++) {
      final id = await txn.insert(
        'works',
        FilmWork(
          type: FilmMediaType.movie,
          tmdbId: i,
          title: 'Fixture movie $i',
          originalTitle: 'Fixture $i',
          overview: 'Synthetic performance library',
          language: 'en',
          year: 2026,
        ).toRow(),
      );
      await txn.insert('resources', {
        'root_id': rootId,
        'relative_path': 'Library/Movie$i.mkv',
        'path_key': 'Library/Movie$i.mkv',
        'parent_path': 'Library',
        'name': 'Movie$i.mkv',
        'media_kind': 'video',
        'work_id': id,
        'binding_origin': 'explicit',
        'binding_version': 0,
        'last_seen_generation': 1,
        'availability': 'present',
        'created_at': 42,
      });
    }
  });
  await catalog.refresh();
  app.startupReady.value = true;
  final appearanceController = AppearanceController(initialConfig: appearance);
  await appearanceController.restoreForStartup();
  WidgetsBinding.instance.addTimingsCallback((timings) {
    for (final t in timings) {
      final finished = t.timestampInMicroseconds(
        FramePhase.rasterFinishWallTime,
      );
      final started =
          finished +
          t.timestampInMicroseconds(FramePhase.buildStart) -
          t.timestampInMicroseconds(FramePhase.rasterFinish);
      if ((DateTime.now().microsecondsSinceEpoch - finished).abs() > 5000000) {
        throw StateError('Frame timing clock could not be correlated');
      }
      _frames.add({
        'phase': _phaseChanges
            .where((event) => (event['wallUs'] as int) <= started)
            .last['phase'],
        'observedPhase': _phase,
        'uiUs': t.buildDuration.inMicroseconds,
        'rasterUs': t.rasterDuration.inMicroseconds,
        'startUs': t.timestampInMicroseconds(FramePhase.vsyncStart),
        'buildWallUs': started,
      });
    }
  });
  runApp(
    KeyedSubtree(
      key: _key,
      child: StreamPathApp(
        appState: app,
        appearanceController: appearanceController,
        autoConnect: false,
      ),
    ),
  );
  await _wait(2000);
  app.downloadsPlaybackRestored();
  final throughput = <Map<String, Object>>[];
  Future<VideoCachePlan> plan(String name, String id) async {
    final info = await cache.probe('fixture', name);
    final f = VideoCacheFile({
      'id': id,
      'source': 'fixture',
      'path': name,
      'identity': 'fixture',
      'root': cache.targetDirectory,
      'destination': p.join(cache.targetDirectory, 'StreamPathCache', name),
      ...info,
    });
    return VideoCachePlan(
      files: [f],
      bundle: {
        'id': id,
        'source': 'fixture',
        'path': name,
        'identity': 'fixture',
        'name': name,
        'root': cache.targetDirectory,
        'main': id,
        'files': [id],
        'kind': 'video',
        'progress': 'https://fixture.invalid/$name',
        'fonts': [],
        'audio': [],
        'subtitle': null,
        'directories': {},
      },
    );
  }

  for (var i = 0; i < 4; i++) {
    _setPhase('throughput-direct-$i');
    await Future<void>.delayed(const Duration(seconds: 2));
    final directPath = p.join(data.path, 'direct.partial');
    final direct = await compute(_direct, ['${origin}perf.bin', directPath]);
    await File(directPath).delete();
    _setPhase('throughput-cache-$i');
    await Future<void>.delayed(const Duration(seconds: 2));
    final selected = await plan('perf.bin', 'perf');
    final clock = Stopwatch()..start();
    await cache.enqueue([selected]);
    await cache.setPlaybackSuspended(false);
    while (!cache.files['perf']!.complete) {
      if (cache.files['perf']!.state == 'failed') {
        throw StateError(cache.files['perf']!.error!);
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final rate = 1024 * 1000000 / clock.elapsedMicroseconds;
    throughput.add({
      'sample': i == 0 ? 'cold' : 'steady',
      'directMiBs': direct,
      'cacheMiBs': rate,
      'ratio': rate / direct,
    });
    await cache.delete('perf');
  }
  final background = await plan('background.mkv', 'background');
  final groups = <Map<String, Object?>>[];
  void navigate(String name) {
    final icon = _find((w) => w is Icon && w.key == Key('sidebar-$name'));
    TextButton? button;
    icon.visitAncestorElements((element) {
      if (element.widget is TextButton) {
        button = element.widget as TextButton;
        return false;
      }
      return true;
    });
    button!.onPressed!();
  }

  _setPhase('warmup');
  navigate('folders');
  await _wait(600);
  navigate('films');
  await _wait(600);
  for (final mode
      in arguments.contains('throughput-only')
          ? <String>[]
          : ['idle', 'collapsed', 'expanded']) {
    if (mode == 'collapsed') {
      _setPhase('start-download');
      await cache.enqueue([background]);
      await cache.setPlaybackSuspended(false);
      await _wait(1200);
    }
    if (mode == 'expanded') {
      _setPhase('toggle-expanded');
      (_find(
                (w) =>
                    w is IconButton &&
                    w.key == const Key('video-cache-floating-button'),
              ).widget
              as IconButton)
          .onPressed!();
      await _wait(400);
    }
    for (var group = 0; group < 3; group++) {
      _setPhase('$mode-$group');
      final started = DateTime.now().toUtc().toIso8601String();
      final rss = ProcessInfo.currentRss;
      for (var i = 0; i < 20; i++) {
        navigate('folders');
        await _wait(400);
        navigate('films');
        await _wait(400);
        final card = _find((w) => w is FilmWorkCard);
        final region =
            _find(
                  (w) => w is MouseRegion && w.onEnter != null,
                  root: card,
                ).widget
                as MouseRegion;
        region.onEnter!(const PointerEnterEvent());
        await _wait(110);
        region.onExit?.call(const PointerExitEvent());
        await _wait(110);
        final scroll =
            _find(
                  (w) =>
                      w is Scrollable && w.axisDirection == AxisDirection.down,
                ).widget
                as Scrollable;
        final controller = scroll.controller;
        if (controller != null && controller.hasClients) {
          await controller.animateTo(
            i.isEven ? controller.position.maxScrollExtent : 0,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
          );
        }
        await _wait(100);
      }
      groups.add({
        'phase': _phase,
        'started': started,
        'ended': DateTime.now().toUtc().toIso8601String(),
        'rssStart': rss,
        'rssEnd': ProcessInfo.currentRss,
        'maxRss': ProcessInfo.maxRss,
        'cacheBytes': cache.files['background']?.received ?? 0,
      });
    }
  }
  _setPhase('drain');
  await cache.setPlaybackSuspended(true);
  await _wait(1200);
  final viewport = WidgetsBinding.instance.platformDispatcher.views.first;
  await File(p.join(root, 'results.json')).writeAsString(
    jsonEncode({
      'pid': pid,
      'mode': 'release',
      'viewport': [viewport.physicalSize.width, viewport.physicalSize.height],
      'dpr': viewport.devicePixelRatio,
      'refreshHz': viewport.display.refreshRate,
      'input': 'fixture widget callbacks, not physical input',
      'glass': appearanceController.glassActive,
      'backdrop': appearanceController.lastResult?.actualBackdrop.name,
      'throughput': throughput,
      'groups': groups,
      'frames': _frames,
      'phaseChanges': _phaseChanges,
    }),
  );
  _setPhase('inspect');
  if (arguments.contains('hold')) {
    while (!await File(p.join(root, 'close.flag')).exists()) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }
  await cache.delete('background');
  runApp(const SizedBox.shrink());
  await _wait(100);
  await app.prepareForClose();
  await app.closeTestStores();
  app.dispose();
  appearanceController.dispose();
  await progress.close();
  exit(0);
}
