// 隔离便携目录中的详情页合成基准；不读写正式媒体库。
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/core/utils/app_paths.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/pages/film_detail_page.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import '../test/helpers/shell_test_app_state.dart';

final _root = GlobalKey();
String _phase = 'setup';
final _frames = <Map<String, Object>>[];
final _operations = <Map<String, Object>>[];

class _App extends ShellTestAppState {
  _App({
    required super.configStore,
    required super.playbackHistoryStore,
    required super.progressService,
    required this.catalog,
  });
  final FilmCatalogController catalog;
  @override
  Future<FilmCatalogController> getFilmCatalog() async => catalog;
  @override
  Future<FilmCatalogStore> getFilmCatalogStore() async => catalog.store;
}

List<Element> _find(bool Function(Widget) matches) {
  final results = <Element>[];
  void visit(Element e) {
    if (matches(e.widget)) results.add(e);
    e.visitChildElements(visit);
  }

  visit(WidgetsBinding.instance.rootElement!);
  return results;
}

Future<void> _wait([int ms = 350]) =>
    Future<void>.delayed(Duration(milliseconds: ms));
Future<void> _operation(String name, Future<void> Function() action) async {
  _phase = name;
  final trace = TimelineTask()..start(name);
  final timer = Stopwatch()..start();
  final startUs = Timeline.now;
  await action();
  await _wait();
  trace.finish();
  _operations.add({
    'name': name,
    'elapsedMs': timer.elapsedMilliseconds,
    'startUs': startUs,
    'endUs': Timeline.now,
    'liveCards': _find((w) => w is FilmEpisodeCard).length,
    'imageCacheBytes': PaintingBinding.instance.imageCache.currentSizeBytes,
    'liveImages': PaintingBinding.instance.imageCache.liveImageCount,
  });
  _phase = 'idle';
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final root = p.dirname(Platform.resolvedExecutable);
  if (!p.basename(root).startsWith('detail-profile-lab-') ||
      !p.equals(root, AppPaths.projectRoot())) {
    throw StateError(
      'Run only in an isolated detail-profile-lab-* portable bundle',
    );
  }
  try {
    await _run(root, args);
    exit(0);
  } catch (error, stack) {
    await File(p.join(root, 'error.log')).writeAsString('$error\n$stack');
    final boundary = _root.currentContext?.findRenderObject();
    if (boundary is RenderRepaintBoundary && boundary.hasSize) {
      final capture = await boundary.toImage();
      final png = await capture.toByteData(format: ui.ImageByteFormat.png);
      capture.dispose();
      await File(
        p.join(root, 'failure.png'),
      ).writeAsBytes(png!.buffer.asUint8List());
    }
    await File(p.join(root, 'failure.json')).writeAsString(
      jsonEncode({
        'phase': _phase,
        'operations': _operations,
        'cards': _find((w) => w is FilmEpisodeCard).map((e) {
          final card = e.widget as FilmEpisodeCard;
          final box = e.findRenderObject()! as RenderBox;
          final origin = box.localToGlobal(Offset.zero);
          return {
            'resourceId': card.resource.id,
            'x': origin.dx,
            'y': origin.dy,
            'width': box.size.width,
            'height': box.size.height,
          };
        }).toList(),
      }),
    );
    exit(1);
  }
}

Future<void> _run(String root, List<String> args) async {
  final count = int.parse(args[0]);
  final run = args[1];
  final folder = await Directory(p.join(root, 'fixture-$count-$run')).create();
  sqfliteFfiInit();
  final store = await FilmCatalogStore.open(p.join(folder.path, 'catalog.db'));
  await store.waitForExtraBackfill();
  final rootId = await store.addRoot(
    sourceId: 'local:fixture',
    kind: MediaSourceKind.local,
    path: 'TV',
    type: FilmMediaType.tv,
    name: 'Fixture',
  );
  final catalogRoot = (await store.root(rootId))!;
  final gen = await store.beginScan(rootId);
  await store.stage(catalogRoot, gen, [
    for (var i = 1; i <= count; i++)
      FilmScanEntry(
        path: 'TV/E$i.mkv',
        parentPath: 'TV',
        name: 'E$i.mkv',
        mediaKind: 'video',
      ),
  ]);
  await store.commitScan(rootId, gen, cancelled: () => false);
  await store.bind(
    await store.resources(),
    const FilmWork(
      type: FilmMediaType.tv,
      tmdbId: 1,
      title: 'Performance fixture',
      originalTitle: 'Performance fixture',
      overview: 'Synthetic fixture',
      language: 'zh-CN',
      posterPath: '/poster.png',
      backdropPath: '/backdrop.png',
      metadata: {'presentation_version': 5, 'certification_version': 1},
    ),
  );
  var resources = await store.resources();
  await store.mapEpisodes({
    for (var i = 0; i < resources.length; i++) resources[i]: (1, i + 1),
  });
  resources = await store.resources();
  final work = (await store.work(resources.first.workId!))!;
  await store.saveSeason(work.id, 1, 'zh-CN', {
    'episodes': [
      for (var i = 1; i <= count; i++)
        {
          'episode_number': i,
          'name': 'Episode $i',
          'overview': 'A fixed overview for the episode. ' * 8,
          'still_path': '/still$i.png',
          'runtime': 24,
        },
    ],
  });
  final tmdb = TmdbMetadataService();
  final images = FilmCatalogImageCache(
    Directory(p.join(folder.path, 'images')),
    tmdb,
  );
  await images.directory.create();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 960, 540),
    Paint()
      ..shader = const LinearGradient(
        colors: [Colors.indigo, Colors.orange],
      ).createShader(const Rect.fromLTWH(0, 0, 960, 540)),
  );
  final picture = recorder.endRecording();
  final img = await picture.toImage(960, 540);
  final bytes = (await img.toByteData(
    format: ui.ImageByteFormat.png,
  ))!.buffer.asUint8List();
  img.dispose();
  picture.dispose();
  for (final path in ['/poster.png', '/backdrop.png', '/still.png']) {
    for (final size in ['w300', 'w342', 'w500', 'w780', 'original']) {
      await File(
        p.join(
          images.directory.path,
          '${FilmCatalogImageCache.cacheKey(path, size)}.img',
        ),
      ).writeAsBytes(bytes);
    }
  }
  for (var i = 1; i <= count; i++) {
    await File(
      p.join(
        images.directory.path,
        '${FilmCatalogImageCache.cacheKey('/still$i.png', 'w300')}.img',
      ),
    ).writeAsBytes(bytes);
  }
  store.spoilerProtection = true;
  final catalog = FilmCatalogController(
    store: store,
    tmdb: tmdb,
    images: images,
    sourceFor: (_) => throw const FilmCatalogException('sourceUnavailable'),
  );
  final progress = await PlaybackProgressService.open(
    p.join(folder.path, 'progress.db'),
  );
  final app = _App(
    configStore: StreamPathConfigStore.forPath(
      p.join(folder.path, 'config.json'),
    ),
    playbackHistoryStore: PlaybackHistoryStore.forPath(
      p.join(folder.path, 'history.json'),
    ),
    progressService: progress,
    catalog: catalog,
  );
  WidgetsBinding.instance.addTimingsCallback((timings) {
    for (final f in timings) {
      _frames.add({
        'phase': _phase,
        'startUs': f.timestampInMicroseconds(ui.FramePhase.buildStart),
        'uiUs': f.buildDuration.inMicroseconds,
        'rasterUs': f.rasterDuration.inMicroseconds,
        'totalUs': f.totalSpan.inMicroseconds,
      });
    }
  });
  await _operation('enter', () async {
    runApp(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: RepaintBoundary(
            key: _root,
            child: FilmDetailPage(
              catalog: catalog,
              workId: work.id,
              initialWork: work,
              onOpenItem: (_) async {},
            ),
          ),
        ),
      ),
    );
    await _wait(5000);
    var stable = 0;
    for (var i = 0; i < 3000 && stable < 25; i++) {
      await _wait(20);
      stable =
          _find((w) => w is FilmEpisodeCard).isNotEmpty &&
              PaintingBinding.instance.imageCache.pendingImageCount == 0
          ? stable + 1
          : 0;
    }
    if (stable < 25) throw StateError('Detail fixture did not become ready');
    await store.resourceWatchState(resources.last);
  });
  final scroll = _find((w) => w is Scrollable)
      .map((e) => (e as StatefulElement).state)
      .whereType<ScrollableState>()
      .firstWhere((s) => s.position.axis == Axis.vertical)
      .position;
  await _operation('position', () async {
    scroll.jumpTo(450);
    await _wait(500);
  });
  var pointer = const Offset(20, 20);
  GestureBinding.instance.handlePointerEvent(
    PointerAddedEvent(
      pointer: 10001,
      kind: PointerDeviceKind.mouse,
      device: 90001,
      position: pointer,
    ),
  );
  await _operation('hover20', () async {
    for (var i = 0; i < 20; i++) {
      final cards = _find((w) => w is FilmEpisodeCard);
      final box = cards[i % 2].findRenderObject()! as RenderBox;
      final target = box.localToGlobal(Offset(box.size.width / 2, 60));
      GestureBinding.instance.handlePointerEvent(
        PointerHoverEvent(
          pointer: 10001,
          kind: PointerDeviceKind.mouse,
          device: 90001,
          position: target,
          delta: target - pointer,
        ),
      );
      pointer = target;
      await _wait(240);
    }
  });
  for (final watched in [true, false]) {
    await _operation(watched ? 'mark20' : 'unmark20', () async {
      for (var i = 0; i < 20; i++) {
        await store.markWatched([resources.first], watched);
        await _wait(150);
      }
    });
  }
  await _operation('menu-mark', () async {
    final card =
        _find((w) => w is FilmEpisodeCard).first.findRenderObject()!
            as RenderBox;
    final point = card.localToGlobal(
      Offset(card.size.width / 2, card.size.height / 2),
    );
    GestureBinding.instance.handlePointerEvent(
      PointerDownEvent(
        pointer: 10002,
        kind: PointerDeviceKind.mouse,
        device: 90001,
        buttons: kSecondaryMouseButton,
        position: point,
      ),
    );
    GestureBinding.instance.handlePointerEvent(
      PointerUpEvent(
        pointer: 10002,
        kind: PointerDeviceKind.mouse,
        device: 90001,
        position: point,
      ),
    );
    await _wait();
    final menus = _find((w) => w is Text && w.data == '标记已看完');
    if (menus.length != 1) {
      throw StateError(
        'Expected one context menu item, found ${menus.length}; click=$point',
      );
    }
    final menu = menus.single.findRenderObject()! as RenderBox;
    final target = menu.localToGlobal(menu.size.center(Offset.zero));
    GestureBinding.instance.handlePointerEvent(
      PointerDownEvent(
        pointer: 10003,
        kind: PointerDeviceKind.mouse,
        device: 90001,
        buttons: kPrimaryMouseButton,
        position: target,
      ),
    );
    GestureBinding.instance.handlePointerEvent(
      PointerUpEvent(
        pointer: 10003,
        kind: PointerDeviceKind.mouse,
        device: 90001,
        position: target,
      ),
    );
  });
  await _operation('batch', () => store.markWatched(resources, true));
  await _operation('scroll20', () async {
    final far = (450 + 1800.0).clamp(0.0, scroll.maxScrollExtent);
    for (var i = 0; i < 20; i++) {
      await scroll.animateTo(
        i.isEven ? far : 450,
        duration: const Duration(milliseconds: 220),
        curve: Curves.linear,
      );
    }
  });
  await _operation('span-scroll20', () async {
    for (var i = 0; i < 20; i++) {
      await scroll.animateTo(
        i.isEven ? scroll.maxScrollExtent : 450,
        duration: const Duration(milliseconds: 220),
        curve: Curves.linear,
      );
    }
  });
  scroll.jumpTo(450);
  await _wait(500);
  await _operation('expand-collapse', () async {
    final card =
        _find((w) => w is FilmEpisodeCard).first.findRenderObject()!
            as RenderBox;
    final target = card.localToGlobal(Offset(60, card.size.height - 70));
    for (var i = 0; i < 2; i++) {
      GestureBinding.instance.handlePointerEvent(
        PointerDownEvent(
          pointer: 10004,
          kind: PointerDeviceKind.mouse,
          device: 90001,
          buttons: kPrimaryMouseButton,
          position: target,
        ),
      );
      GestureBinding.instance.handlePointerEvent(
        PointerUpEvent(
          pointer: 10004,
          kind: PointerDeviceKind.mouse,
          device: 90001,
          position: target,
        ),
      );
      await _wait(300);
    }
  });
  GestureBinding.instance.handlePointerEvent(
    const PointerHoverEvent(
      pointer: 10001,
      kind: PointerDeviceKind.mouse,
      device: 90001,
      position: Offset.zero,
    ),
  );
  await _wait(350);
  final capture =
      await (_root.currentContext!.findRenderObject()! as RenderRepaintBoundary)
          .toImage();
  final png = await capture.toByteData(format: ui.ImageByteFormat.png);
  capture.dispose();
  await File(
    p.join(root, '$count-$run.png'),
  ).writeAsBytes(png!.buffer.asUint8List());
  await _wait(1200);
  for (final frame in _frames) {
    final timestamp = frame['startUs'] as int;
    frame['phase'] =
        _operations
            .where(
              (op) =>
                  timestamp >= (op['startUs'] as int) &&
                  timestamp <= (op['endUs'] as int),
            )
            .map((op) => op['name']!)
            .firstOrNull ??
        'idle';
  }
  await File(p.join(root, '$count-$run.json')).writeAsString(
    jsonEncode({
      'count': count,
      'run': run,
      'mode': 'profile',
      'windowWidth':
          ui.PlatformDispatcher.instance.views.first.physicalSize.width,
      'windowHeight':
          ui.PlatformDispatcher.instance.views.first.physicalSize.height,
      'dpr': ui.PlatformDispatcher.instance.views.first.devicePixelRatio,
      'refreshRate':
          ui.PlatformDispatcher.instance.views.first.display.refreshRate,
      'frames': _frames,
      'operations': _operations,
    }),
  );
  if (args.contains('hold')) await _wait(60000);
  runApp(const SizedBox.shrink());
  await _wait();
  await catalog.close();
  await app.closeTestStores();
  app.dispose();
  await progress.close();
}
