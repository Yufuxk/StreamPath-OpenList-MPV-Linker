// 隔离便携副本的 Profile 诊断入口；只使用预先复制的库与图片。
// Profile 诊断使用测试构造器隔离用户数据。
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show FramePhase, PointerDeviceKind;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/core/utils/app_paths.dart';
import 'package:streampath/data/local/directory_cache.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/data/models/appearance_config.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/data/remote/webdav_client.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/film_catalog_scanner.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/domain/services/webdav_media_source_adapter.dart';
import 'package:streampath/domain/services/webdav_service.dart';
import 'package:streampath/main.dart' show StreamPathApp;
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/theme/appearance_controller.dart';

import '../test/helpers/shell_test_app_state.dart';

class _Credentials extends TmdbCredentialStore {
  @override
  Future<String?> read() async => 'isolated-probe';
}

class _App extends ShellTestAppState {
  _App({
    required super.configStore,
    required super.playbackHistoryStore,
    required super.progressService,
    required super.directoryCache,
    required super.mediaLibraryStore,
    required this.catalog,
  });
  final FilmCatalogController catalog;
  @override
  Future<FilmCatalogController> getFilmCatalog() async => catalog;
  @override
  Future<FilmCatalogStore> getFilmCatalogStore() async => catalog.store;
}

class _Catalog extends FilmCatalogController {
  _Catalog({
    required super.store,
    required super.tmdb,
    required super.images,
    required super.sourceFor,
  });

  String phase = 'startup';
  final refreshes = <Map<String, Object?>>[];

  @override
  Future<void> refresh({bool more = false, bool home = true}) async {
    final start = developer.Timeline.now;
    final currentPhase = phase;
    try {
      await super.refresh(more: more, home: home);
    } finally {
      refreshes.add({
        'phase': currentPhase,
        'startUs': start,
        'durationUs': developer.Timeline.now - start,
        'more': more,
        'home': home,
      });
    }
  }
}

final _rootKey = GlobalKey();
Element _find(bool Function(Widget) matches) {
  Element? found;
  void visit(Element element) {
    if (found != null) return;
    if (matches(element.widget)) {
      found = element;
      return;
    }
    element.visitChildElements(visit);
  }

  visit(_rootKey.currentContext! as Element);
  return found ?? (throw StateError('Probe widget not found'));
}

Future<void> _settle(int ms) async {
  await Future<void>.delayed(Duration(milliseconds: ms));
  await WidgetsBinding.instance.endOfFrame;
}

var _pointer = 0;
void _tapSidebar(String section) {
  final icon = _find((w) => w is Icon && w.key == Key('sidebar-$section'));
  final box = icon.findRenderObject()! as RenderBox;
  final position = box.localToGlobal(box.size.center(Offset.zero));
  final viewId = WidgetsBinding.instance.platformDispatcher.views.first.viewId;
  final pointer = ++_pointer;
  GestureBinding.instance.handlePointerEvent(
    PointerDownEvent(
      pointer: pointer,
      viewId: viewId,
      kind: PointerDeviceKind.mouse,
      position: position,
    ),
  );
  GestureBinding.instance.handlePointerEvent(
    PointerUpEvent(
      pointer: pointer,
      viewId: viewId,
      kind: PointerDeviceKind.mouse,
      position: position,
    ),
  );
}

Future<Map<String, Object?>> _verifyTree(String directory, String label) async {
  final fixture =
      jsonDecode(await File(p.join(directory, 'fixture.json')).readAsString())
          as Map;
  final files = (fixture['files'] as List).cast<Map>();
  final tree = <String, Map<String, bool>>{};
  for (final file in files) {
    final parts = (file['path'] as String).split('/');
    for (var i = 0; i < parts.length; i++) {
      final parent = parts.take(i).join('/');
      final child = parts.take(i + 1).join('/');
      (tree[parent] ??= {})[child] = i < parts.length - 1;
    }
  }
  var requests = 0;
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method != 'PROPFIND' ||
              options.uri.host != 'fixture.invalid' ||
              options.headers['Depth'] != '1') {
            throw StateError('Unexpected synthetic scan request');
          }
          final parent = options.uri.pathSegments
              .skip(1)
              .where((part) => part.isNotEmpty)
              .join('/');
          requests++;
          final children = tree[parent] ?? const <String, bool>{};
          final xml = StringBuffer('<d:multistatus xmlns:d="DAV:">');
          for (final child in children.entries) {
            final href = Uri(
              path: '/dav/${child.key}${child.value ? '/' : ''}',
            );
            xml.write(
              '<d:response><d:href>$href</d:href><d:propstat><d:prop>'
              '<d:displayname>${p.posix.basename(child.key)}</d:displayname>'
              '<d:resourcetype>${child.value ? '<d:collection/>' : ''}</d:resourcetype>'
              '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>',
            );
          }
          xml.write('</d:multistatus>');
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 207,
              data: xml.toString(),
            ),
          );
        },
      ),
    );
  final store = await FilmCatalogStore.open(
    p.join(directory, '$label-tree.db'),
  );
  final scanner = FilmCatalogScanner(store, remoteInterval: Duration.zero);
  final source = WebDavMediaSourceAdapter(
    WebDAVService(
      client: WebDavClient(baseUrl: 'https://fixture.invalid/dav', dio: dio),
      profileId: 'fixture-tree',
    ),
  );
  try {
    for (final type in FilmMediaType.values) {
      final rootPath = type == FilmMediaType.tv
          ? 'Library/Series'
          : 'Library/Movies';
      final id = await store.addRoot(
        sourceId: 'fixture-tree',
        kind: MediaSourceKind.webdav,
        path: rootPath,
        type: type,
        name: type.name,
      );
      await scanner.scan((await store.root(id))!, source);
    }
    final actual = (await store.resources()).map((r) => r.path).toSet();
    final expected = files.map((f) => f['path'] as String).toSet();
    if (!setEquals(actual, expected)) {
      throw StateError('Nested scan paths differ');
    }
    if ((await store.roots()).any((r) => r.status != 'completed')) {
      throw StateError('Nested scan did not complete');
    }
    return {
      'resources': actual.length,
      'directoryRequests': requests,
      'allPathsEqual': true,
      'remoteInterval': 'zero for in-process fixture only',
    };
  } finally {
    await scanner.shutdown();
    await store.close();
    dio.close(force: true);
  }
}

Future<void> main(List<String> arguments) async {
  try {
    await _runProbe(arguments);
  } catch (error, stack) {
    await File(
      p.join(p.dirname(Platform.resolvedExecutable), 'probe-error.log'),
    ).writeAsString('$error\n$stack');
    exit(1);
  }
}

Future<void> _runProbe(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  final root = p.dirname(Platform.resolvedExecutable);
  if (!p.equals(AppPaths.projectRoot(), root) ||
      !p.basename(root).startsWith('film-scrape-lab-')) {
    throw StateError('Run only an isolated film-scrape-lab-* bundle');
  }
  sqfliteFfiInit();
  if (arguments.isNotEmpty && arguments.first == 'verify-tree') {
    final result = await _verifyTree(
      root,
      'tree-${DateTime.now().microsecondsSinceEpoch}',
    );
    await File(
      p.join(root, 'tree-verification.json'),
    ).writeAsString(jsonEncode(result));
    exit(0);
  }
  final label = arguments.isEmpty ? 'baseline' : arguments.first;
  final pages = arguments.length > 1 ? int.parse(arguments[1]) : 1;
  final file = p.join(root, '$label.db');
  await File(p.join(root, 'seed.db')).copy(file);
  final store = await FilmCatalogStore.open(file);
  final cachedWorks = {
    for (final work in await store.works(type: null, limit: 1000))
      work.tmdbId: work,
  };
  var requests = 0;
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) {
          requests++;
          final segments = o.uri.path.split('/');
          if (o.uri.path.contains('/search/')) {
            h.resolve(
              Response(
                requestOptions: o,
                statusCode: 200,
                data: {'results': []},
              ),
            );
          } else if (segments.contains('season')) {
            h.resolve(Response(requestOptions: o, statusCode: 404, data: {}));
          } else if (o.uri.path.endsWith('/images')) {
            h.resolve(
              Response(
                requestOptions: o,
                statusCode: 200,
                data: {
                  'id': int.parse(segments[3]),
                  'backdrops': [],
                  'logos': [],
                },
              ),
            );
          } else if (segments.length >= 4 &&
              cachedWorks.containsKey(int.tryParse(segments[3]))) {
            final work = cachedWorks[int.parse(segments[3])]!;
            h.resolve(
              Response(
                requestOptions: o,
                statusCode: 200,
                data: {
                  ...work.metadata,
                  'id': work.tmdbId,
                  'title': work.title,
                  'name': work.title,
                  'original_title': work.originalTitle,
                  'original_name': work.originalTitle,
                  'overview': work.overview,
                  'poster_path': work.posterPath,
                  'backdrop_path': work.backdropPath,
                  'release_date': '${work.year ?? 2020}-01-01',
                  'first_air_date': '${work.year ?? 2020}-01-01',
                  'genres': [
                    for (final genre in work.metadata['genres'] as List? ?? [])
                      {'name': genre},
                  ],
                },
              ),
            );
          } else {
            h.reject(
              DioException(requestOptions: o, message: 'Unexpected probe API'),
            );
          }
        },
      ),
    );
  final tmdb = TmdbMetadataService(credentials: _Credentials(), dio: dio);
  final images = FilmCatalogImageCache(
    Directory(p.join(root, 'artwork')),
    tmdb,
    dio: Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            h.reject(
              DioException(requestOptions: o, message: 'Uncached probe image'),
            );
          },
        ),
      ),
  );
  final catalog = _Catalog(
    store: store,
    tmdb: tmdb,
    images: images,
    sourceFor: (_) => throw StateError('No source access in UI probe'),
  );
  final configDir = await AppPaths.configDirectory();
  final cacheDir = await AppPaths.cacheDirectory();
  final config = StreamPathConfigStore.forPath(
    p.join(configDir.path, 'probe.json'),
  );
  const appearance = AppearanceConfig(
    style: InterfaceStyle.glass,
    material: WindowMaterialPreference.acrylic,
  );
  await config.save(const StreamPathConfig(appearance: appearance));
  Hive.init(cacheDir.path);
  final cache = DirectoryCache();
  await cache.init();
  final progress = await PlaybackProgressService.open(
    p.join(cacheDir.path, 'probe.db'),
    factory: databaseFactoryFfi,
  );
  final library = MediaLibraryStore.forPath(
    p.join(configDir.path, 'library.json'),
  );
  await library.load();
  final app = _App(
    configStore: config,
    playbackHistoryStore: PlaybackHistoryStore.forPath(
      p.join(cacheDir.path, 'history.json'),
    ),
    progressService: progress,
    directoryCache: cache,
    mediaLibraryStore: library,
    catalog: catalog,
  );
  final material = AppearanceController(initialConfig: appearance);
  await material.restoreForStartup();
  final frames = <Map<String, Object?>>[];
  final operations = <Map<String, Object?>>[];
  var phase = 'startup';
  var notifications = 0;
  var storeNotifications = 0;
  var taskNotifications = 0;
  var completedResources = 0;
  var previousProgress = 0;
  var processed = 0;
  catalog.addListener(() => notifications++);
  store.addListener(() => storeNotifications++);
  catalog.taskChanges.addListener(() {
    taskNotifications++;
    final current = catalog.scrapeProcessed;
    completedResources += current < previousProgress
        ? current
        : current - previousProgress;
    previousProgress = current;
  });
  WidgetsBinding.instance.addTimingsCallback((timings) {
    for (final t in timings) {
      frames.add({
        'phase': phase,
        'number': t.frameNumber,
        'buildUs': t.buildDuration.inMicroseconds,
        'rasterUs': t.rasterDuration.inMicroseconds,
        'totalUs': t.totalSpan.inMicroseconds,
        'vsyncOverheadUs': t.vsyncOverhead.inMicroseconds,
        'startUs': t.timestampInMicroseconds(FramePhase.vsyncStart),
      });
    }
  });
  runApp(
    KeyedSubtree(
      key: _rootKey,
      child: StreamPathApp(
        appState: app,
        appearanceController: material,
        autoConnect: false,
      ),
    ),
  );
  await WidgetsBinding.instance.endOfFrame;
  app.startupReady.value = true;
  await _settle(2500);
  // 先挂载文件夹分支，再比较同一组完整滑动与中途反向切换。
  _tapSidebar('folders');
  await _settle(800);
  _tapSidebar('films');
  await _settle(1200);
  for (var i = 1; i < pages; i++) {
    await catalog.refresh(more: true);
  }
  await _settle(500);
  final loadedWorks = catalog.works.length;
  final service = await developer.Service.controlWebServer(
    enable: true,
    silenceOutput: true,
  );
  final isolate = developer.Service.getIsolateId(Isolate.current)!;
  final client = HttpClient();
  var cpuStart = 0;
  var cpuEnd = 0;
  Future<Map<String, dynamic>> rpc(String method) async {
    final uri = service.serverUri!
        .resolve(method)
        .replace(
          queryParameters: {
            'isolateId': isolate,
            if (method == 'getCpuSamples') ...{
              'timeOriginMicros': '$cpuStart',
              'timeExtentMicros': '${cpuEnd - cpuStart}',
            },
          },
        );
    final response = await (await client.getUrl(uri)).close();
    final value = jsonDecode(await utf8.decoder.bind(response).join()) as Map;
    if (value['error'] != null) {
      if (method == 'getCpuSamples') {
        return {'unavailable': value['error']};
      }
      throw StateError('Probe VM RPC failed: $method');
    }
    return Map<String, dynamic>.from(value['result'] as Map);
  }

  final samples = <String, Map<String, Object?>>{};
  Future<void> switches(String name) async {
    phase = catalog.phase = name;
    final before = (notifications, storeNotifications, taskNotifications);
    final initialProcessed = completedResources;
    if (name == 'scraping') {
      await rpc('clearCpuSamples');
      cpuStart = developer.Timeline.now;
    }
    for (var i = 0; i < 40; i++) {
      if (catalog.scrapePaused) {
        throw StateError('Probe scraping paused: ${catalog.scrapeError}');
      }
      final start = developer.Timeline.now;
      _tapSidebar(i.isEven ? 'folders' : 'films');
      await _settle(i < 20 ? 420 : 180);
      final icon = _find(
        (w) =>
            w is Icon &&
            w.key == Key('sidebar-${i.isEven ? 'folders' : 'films'}'),
      );
      var selected = false;
      icon.visitAncestorElements((element) {
        final widget = element.widget;
        if (widget is Semantics && widget.properties.selected != null) {
          selected = widget.properties.selected!;
          return false;
        }
        return true;
      });
      if (!selected) {
        throw StateError(
          'Segment pointer selection failed: phase=$name index=$i',
        );
      }
      operations.add({
        'phase': name,
        'kind': i < 20 ? 'complete' : 'reverse',
        'startUs': start,
        'endUs': developer.Timeline.now,
      });
    }
    if (name == 'scraping') cpuEnd = developer.Timeline.now;
    samples[name] = {
      'controllerNotifications': notifications - before.$1,
      'storeNotifications': storeNotifications - before.$2,
      'taskNotifications': taskNotifications - before.$3,
      'processedDuringOperations': completedResources - initialProcessed,
      'rss': ProcessInfo.currentRss,
      'imageCache': {
        'bytes': PaintingBinding.instance.imageCache.currentSizeBytes,
        'count': PaintingBinding.instance.imageCache.currentSize,
        'live': PaintingBinding.instance.imageCache.liveImageCount,
        'pending': PaintingBinding.instance.imageCache.pendingImageCount,
      },
      'memory': await rpc('getMemoryUsage'),
    };
    stdout.writeln('PROBE_PHASE $name processed=${catalog.scrapeProcessed}');
    phase = catalog.phase = '$name-scroll';
    await _settle(400);
    final scroll =
        _find(
              (w) =>
                  w is CustomScrollView &&
                  w.key == const Key('film-home-scroll'),
            ).widget
            as CustomScrollView;
    final controller = scroll.controller!;
    for (var i = 0; i < 10; i++) {
      final start = developer.Timeline.now;
      await controller.animateTo(
        i.isEven ? controller.position.maxScrollExtent : 0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
      operations.add({
        'phase': phase,
        'kind': 'scroll',
        'startUs': start,
        'endUs': developer.Timeline.now,
      });
    }
    await _settle(400);
  }

  await switches('before');
  final scrapeStart = developer.Timeline.now;
  var scrapeEnd = 0;
  final scrapeTask = () async {
    for (final r in await store.roots()) {
      await catalog.scrape(r);
      await catalog.waitForScraping();
      processed += catalog.scrapeProcessed;
      if (catalog.scrapePaused) {
        throw StateError('Probe scraping paused: ${catalog.scrapeError}');
      }
    }
    scrapeEnd = developer.Timeline.now;
  }();
  await switches('scraping');
  phase = catalog.phase = 'drain';
  await scrapeTask;
  await _settle(1200);
  await switches('after');
  // 原 works() 的同步映射独立计时，不把异步 SQL 总时长当 UI 阻塞。
  final db = await databaseFactoryFfi.openDatabase(file);
  final decodeCases = <Map<String, Object?>>[];
  final queryCases = <Map<String, Object?>>[];
  for (final limit in [60, 180]) {
    final rows = await db.rawQuery('SELECT * FROM works ORDER BY id LIMIT ?', [
      limit,
    ]);
    for (var i = 0; i < 5; i++) {
      final watch = Stopwatch()..start();
      final decoded = rows.map(FilmWork.fromRow).toList();
      decodeCases.add({
        'rows': decoded.length,
        'syncUs': watch.elapsedMicroseconds,
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    for (var i = 0; i < 5; i++) {
      var lastTick = developer.Timeline.now;
      var maxGap = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
        final now = developer.Timeline.now;
        final gap = now - lastTick;
        if (gap > maxGap) maxGap = gap;
        lastTick = now;
      });
      final watch = Stopwatch()..start();
      final result = await store.works(type: null, limit: limit);
      final elapsed = watch.elapsedMicroseconds;
      await Future<void>.delayed(const Duration(milliseconds: 2));
      timer.cancel();
      queryCases.add({
        'rows': result.length,
        'totalUs': elapsed,
        'maxEventLoopGapUs': maxGap,
      });
    }
  }
  // CPU 导出体积较大，放在全部交互及查询测量结束后。
  await File(
    p.join(root, '$label-cpu.json'),
  ).writeAsString(jsonEncode(await rpc('getCpuSamples')));
  client.close();
  phase = 'idle';
  await _settle(1200);
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  runApp(const SizedBox.shrink());
  await _settle(300);
  await catalog.close();
  await File(p.join(root, '$label.json')).writeAsString(
    jsonEncode({
      'pid': pid,
      'mode': 'profile',
      'viewport': [view.physicalSize.width, view.physicalSize.height],
      'dpr': view.devicePixelRatio,
      'refreshRate': view.display.refreshRate,
      'loadedWorks': loadedWorks,
      'backdrop': material.lastResult?.actualBackdrop.name,
      'simulatedApiRequests': requests,
      'actualNetworkRequests': 0,
      'processed': processed,
      'controllerNotifications': notifications,
      'storeNotifications': storeNotifications,
      'taskNotifications': taskNotifications,
      'scrapeStartUs': scrapeStart,
      'scrapeEndUs': scrapeEnd,
      'cpuStartUs': cpuStart,
      'cpuEndUs': cpuEnd,
      'samples': samples,
      'refreshes': catalog.refreshes,
      'decodeCases': decodeCases,
      'queryCases': queryCases,
      'frames': frames,
      'operations': operations,
    }),
  );
  await app.closeTestStores();
  app.dispose();
  material.dispose();
  await progress.close();
  await cache.close();
  exit(0);
}
