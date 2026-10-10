// 隔离便携副本的 Profile 诊断入口；只使用预先复制的库与图片。
// Profile 诊断使用测试构造器隔离用户数据。
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' show FramePhase;

import 'package:dio/dio.dart';
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
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/data/models/appearance_config.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/main.dart' show StreamPathApp;
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/pages/film_library_page.dart';
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
  final label = arguments.isEmpty ? 'baseline' : arguments.first;
  sqfliteFfiInit();
  final store = await FilmCatalogStore.open(p.join(root, 'catalog.db'));
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
  final catalog = FilmCatalogController(
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
  app.startupReady.value = true;
  final material = AppearanceController(initialConfig: appearance);
  await material.restoreForStartup();
  final frames = <Map<String, Object?>>[];
  final operations = <Map<String, Object?>>[];
  var phase = 'startup';
  var notifications = 0;
  var storeNotifications = 0;
  var processed = 0;
  catalog.addListener(() => notifications++);
  store.addListener(() => storeNotifications++);
  WidgetsBinding.instance.addTimingsCallback((timings) {
    for (final t in timings) {
      frames.add({
        'phase': phase,
        'number': t.frameNumber,
        'buildUs': t.buildDuration.inMicroseconds,
        'rasterUs': t.rasterDuration.inMicroseconds,
        'totalUs': t.totalSpan.inMicroseconds,
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
  await _settle(2500);
  var running = true;
  final tvRoots = (await store.roots())
      .where((r) => r.type == FilmMediaType.tv)
      .toList();
  final scrapeTask = () async {
    while (running) {
      for (final r in tvRoots) {
        if (!running) break;
        await catalog.scrape(r);
        await catalog.waitForScraping();
        processed += catalog.scrapeProcessed;
        if (catalog.scrapePaused) {
          throw StateError('Probe scraping paused: ${catalog.scrapeError}');
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }();
  for (var group = 0; group < 3; group++) {
    for (var i = 0; i < 20; i++) {
      phase = 'scroll-$group-$i';
      if (catalog.scrapePaused) {
        throw StateError('Probe scraping paused: ${catalog.scrapeError}');
      }
      stdout.writeln(
        'PROBE_OPERATION $phase processed=${catalog.scrapeProcessed} paused=${catalog.scrapePaused}',
      );
      final start = developer.Timeline.now;
      final page = _find((w) => w is FilmLibraryPage);
      final scrolls = <ScrollableState>[];
      void visit(Element e) {
        if (e is StatefulElement && e.state is ScrollableState) {
          final s = e.state as ScrollableState;
          if (s.position.axis == Axis.vertical &&
              s.position.hasContentDimensions) {
            scrolls.add(s);
          }
        }
        e.visitChildElements(visit);
      }

      page.visitChildElements(visit);
      final s = scrolls.firstWhere((s) => s.position.maxScrollExtent > 0);
      await s.position.animateTo(
        i.isEven ? s.position.maxScrollExtent : 0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
      await _settle(80);
      operations.add({
        'phase': phase,
        'startUs': start,
        'endUs': developer.Timeline.now,
      });
      phase = 'switch-$group-$i';
      final switchStart = developer.Timeline.now;
      (_find(
                (w) => w is InkWell && w.key == const Key('sidebar-folders'),
              ).widget
              as InkWell)
          .onTap!();
      await _settle(150);
      (_find((w) => w is InkWell && w.key == const Key('sidebar-films')).widget
              as InkWell)
          .onTap!();
      await _settle(150);
      operations.add({
        'phase': phase,
        'startUs': switchStart,
        'endUs': developer.Timeline.now,
      });
    }
  }
  running = false;
  phase = 'idle';
  await _settle(1200);
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  runApp(const SizedBox.shrink());
  await _settle(300);
  await catalog.close();
  await scrapeTask;
  await File(p.join(root, '$label.json')).writeAsString(
    jsonEncode({
      'pid': pid,
      'mode': 'profile',
      'viewport': [view.physicalSize.width, view.physicalSize.height],
      'dpr': view.devicePixelRatio,
      'backdrop': material.lastResult?.actualBackdrop.name,
      'simulatedApiRequests': requests,
      'actualNetworkRequests': 0,
      'processed': processed,
      'controllerNotifications': notifications,
      'storeNotifications': storeNotifications,
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
