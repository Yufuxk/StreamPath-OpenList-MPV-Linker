// 隔离便携目录中的合成刮削基准；正式入口不引用此文件。
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show FrameTiming;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/core/utils/app_paths.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';

class _Credentials extends TmdbCredentialStore {
  @override
  Future<String?> read() async => 'isolated-fixture';
}

class _Metadata extends TmdbMetadataService {
  _Metadata() : super(credentials: _Credentials());
  int requests = 0;
  @override
  Future<Map<String, dynamic>> season(
    int id,
    int number,
    String language,
  ) async {
    requests++;
    return {'season_number': number, 'episodes': []};
  }
}

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  final directory = p.dirname(Platform.resolvedExecutable);
  if (!p.equals(AppPaths.projectRoot(), directory) ||
      !p.basename(directory).startsWith('film-memory-lab-')) {
    throw StateError('Run only in an isolated film-memory-lab-* bundle');
  }
  try {
    await _run(directory, arguments);
    exit(0);
  } catch (error, stack) {
    await File(
      p.join(directory, 'probe-error.log'),
    ).writeAsString('$error\n$stack');
    exit(1);
  }
}

Future<void> _run(String directory, List<String> arguments) async {
  final label = arguments.first;
  final size = int.parse(arguments[1]);
  final diagnosticGc = !arguments.contains('natural');
  sqfliteFfiInit();
  final file = p.join(directory, '$label-$size.db');
  final store = await FilmCatalogStore.open(file);
  final db = await databaseFactoryFfi.openDatabase(file);
  final rootId = await store.addRoot(
    sourceId: 'fixture',
    kind: MediaSourceKind.webdav,
    path: 'TV',
    type: FilmMediaType.tv,
    name: 'TV',
  );
  final root = (await store.root(rootId))!;
  final work = FilmWork(
    type: FilmMediaType.tv,
    tmdbId: 1,
    title: 'Show',
    originalTitle: 'Show',
    overview: 'Fixed metadata fixture',
    language: 'zh-CN',
    fetchedAt: 42,
    metadata: {
      'credits': {
        'cast': [
          for (var i = 0; i < 40; i++)
            {
              'id': i,
              'name': 'Person $i',
              'character': 'Character $i',
              'profile_path': '/person$i.jpg',
              'order': i,
            },
        ],
      },
      'genres': [
        {'id': 18, 'name': 'Drama'},
      ],
      'origin_country': ['JP'],
    },
  );
  final workId = await db.insert('works', work.toRow());
  await db.transaction((txn) async {
    final batch = txn.batch();
    for (var i = 0; i < size; i++) {
      final season = i ~/ 500 + 1;
      final episode = i % 500 + 1;
      final name =
          'Show.S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(3, '0')}.strm';
      batch.insert('resources', {
        'root_id': rootId,
        'relative_path': 'TV/$name',
        'path_key': 'TV/$name',
        'parent_path': 'TV',
        'name': name,
        'media_kind': 'strm',
        'work_id': workId,
        'binding_origin': 'explicit',
        'binding_version': 0,
        'season_number': season,
        'episode_number': episode,
        'episode_mapping_origin': 'filename',
        'last_seen_generation': 1,
        'availability': 'present',
        'created_at': 42,
      });
    }
    await batch.commit(noResult: true);
  });
  for (var season = 1; season <= (size / 500).ceil(); season++) {
    await store.saveSeason(workId, season, 'zh-CN', {
      'season_number': season,
      'episodes': [],
    });
  }
  final metadata = _Metadata();
  final controller = FilmCatalogController(
    store: store,
    tmdb: metadata,
    images: FilmCatalogImageCache(
      Directory(p.join(directory, 'images')),
      metadata,
    ),
    sourceFor: (_) => throw StateError('No media access in memory fixture'),
  );
  final samples = <Map<String, Object?>>[];
  final frames = <Map<String, int>>[];
  void timings(List<FrameTiming> timings) {
    for (final timing in timings) {
      frames.add({
        'buildUs': timing.buildDuration.inMicroseconds,
        'rasterUs': timing.rasterDuration.inMicroseconds,
      });
    }
  }

  WidgetsBinding.instance.addTimingsCallback(timings);
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: AnimatedBuilder(
            animation: controller.taskChanges,
            builder: (_, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                Text('${controller.scrapeProcessed}/$size'),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await Future<void>.delayed(const Duration(seconds: 2));
  final service = await developer.Service.controlWebServer(
    enable: true,
    silenceOutput: true,
  );
  final isolateId = developer.Service.getIsolateId(Isolate.current)!;
  final client = HttpClient();
  Future<void> sample(String phase, {bool gc = false}) async {
    final result = <String, Object?>{
      'phase': phase,
      'diagnosticGc': gc,
      'rss': ProcessInfo.currentRss,
      'maxRss': ProcessInfo.maxRss,
      'processed': controller.scrapeProcessed,
      'retainedMatches': await controller.retainedScrapeMatchCount(),
      'retainedEntries': controller.retainedScrapeEntryCount,
      'imageBytes': PaintingBinding.instance.imageCache.currentSizeBytes,
      'imageCount': PaintingBinding.instance.imageCache.currentSize,
      'liveImages': PaintingBinding.instance.imageCache.liveImageCount,
      'pendingImages': PaintingBinding.instance.imageCache.pendingImageCount,
    };
    if (service.serverUri != null) {
      final method = gc ? 'getAllocationProfile' : 'getMemoryUsage';
      final uri = service.serverUri!
          .resolve(method)
          .replace(
            queryParameters: {'isolateId': isolateId, if (gc) 'gc': 'true'},
          );
      final response = await (await client.getUrl(uri)).close();
      final rpc = jsonDecode(await utf8.decoder.bind(response).join()) as Map;
      if (rpc['error'] != null) {
        throw StateError('VM metric failed: ${rpc['error']}');
      }
      final data = rpc['result'] as Map;
      result['dart'] = gc ? data['memoryUsage'] : data;
      if (gc) {
        result['objects'] = [
          for (final member in data['members'] as List)
            if ([
              'FilmScanMatch',
              'FilmWork',
              'FilmResource',
              'FilmScanMetadataSession',
            ].contains((member['class'] as Map)['name']))
              {
                'class': member['class']['name'],
                'instances': member['instancesCurrent'],
                'bytes': member['bytesCurrent'],
              },
        ];
      }
    }
    samples.add(result);
    await File(
      p.join(directory, 'phase.json'),
    ).writeAsString(jsonEncode(result));
  }

  await sample('idle');
  final rounds = <Map<String, int>>[];
  for (var round = 0; round < 3; round++) {
    final stopwatch = Stopwatch()..start();
    final enqueue = controller.scrape(root);
    await enqueue;
    await sample('queued-$round');
    while (controller.scraping && controller.scrapeProcessed < size * .90) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    controller.toggleScraping();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await sample('ninety-percent-$round');
    if (diagnosticGc) await sample('ninety-percent-gc-$round', gc: true);
    controller.toggleScraping();
    await controller.waitForScraping();
    rounds.add({
      'elapsedMs': stopwatch.elapsedMilliseconds,
      'processed': controller.scrapeProcessed,
      'matched': controller.scrapedCount,
    });
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await sample('finished-$round');
  }
  if (diagnosticGc) await sample('finished-gc', gc: true);
  await File(p.join(directory, '$label-$size.json')).writeAsString(
    jsonEncode({
      'pid': pid,
      'mode': 'profile',
      'diagnosticGc': diagnosticGc,
      'size': size,
      'actualNetworkRequests': 0,
      'metadataRequests': metadata.requests,
      'samples': samples,
      'rounds': rounds,
      'frames': frames,
      'viewport': [
        WidgetsBinding
            .instance
            .platformDispatcher
            .views
            .first
            .physicalSize
            .width,
        WidgetsBinding
            .instance
            .platformDispatcher
            .views
            .first
            .physicalSize
            .height,
      ],
      'dpr': WidgetsBinding
          .instance
          .platformDispatcher
          .views
          .first
          .devicePixelRatio,
    }),
  );
  client.close();
  WidgetsBinding.instance.removeTimingsCallback(timings);
  runApp(const SizedBox.shrink());
  await controller.close();
}
