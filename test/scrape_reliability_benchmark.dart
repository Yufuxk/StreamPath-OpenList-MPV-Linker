import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/data/models/film_fast_task.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/domain/services/local_media_source.dart';
import 'package:streampath/domain/services/film_file_metadata.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';

void main() {
  test(
    'controller and HTTP stable/fault benchmark',
    () async {
      final results = <Map<String, Object?>>[];
      const focus5000 = bool.fromEnvironment('FOCUS_5000');
      const label = String.fromEnvironment(
        'BENCH_LABEL',
        defaultValue: 'current',
      );
      for (final size in focus5000 ? [5000] : [100, 1000, 5000]) {
        for (final fault in focus5000 ? [false] : [false, true]) {
          for (final concurrency in focus5000 ? [1] : [1, 8]) {
            for (var round = 0; round < 3; round++) {
              final temp = await Directory.systemTemp.createTemp(
                'scrape_bench_',
              );
              final store = await FilmCatalogStore.open(
                '${temp.path}/catalog.db',
              );
              final api = _Metadata(fault ? (size > 300 ? 301 : 31) : null);
              final source = LocalMediaSource(
                LocalRootConfig(
                  rootId: 'bench',
                  displayName: 'Bench',
                  path: temp.path,
                ),
              );
              final rootId = await store.addRoot(
                sourceId: source.descriptor.sourceId,
                kind: MediaSourceKind.local,
                path: 'Movies',
                type: FilmMediaType.movie,
                name: 'Bench',
              );
              final root = (await store.root(rootId))!;
              await Directory('${temp.path}/Movies').create();
              for (var i = 0; i < size; i++) {
                await File(
                  '${temp.path}/Movies/Bench$i.{tmdb-${i + 1}}.2020.mkv',
                ).create();
              }
              final images = FilmCatalogImageCache(
                Directory('${temp.path}/images'),
                api,
              );
              final controller = FilmCatalogController(
                store: store,
                tmdb: api,
                images: images,
                sourceFor: (_) => source,
                filesFor: (root) async => _Files(source, root),
                ownsResources: false,
              );
              final clock = Stopwatch()..start();
              final fast = concurrency == 8;
              await controller.scan(
                root,
                executionMode: fast
                    ? FilmTaskExecutionMode.fullSpeed
                    : FilmTaskExecutionMode.standard,
              );
              if (fast) {
                if (await store.fastTask() != null) {
                  await controller.resumeFastTask();
                }
              } else {
                while (controller.scraping && !controller.scrapePaused) {
                  await Future<void>.delayed(const Duration(milliseconds: 1));
                }
                if (controller.scrapePaused) controller.toggleScraping();
                await controller.waitForScraping();
              }
              clock.stop();
              final resources = await store.resources();
              final matched = resources.where((r) => r.workId != null).length;
              expect(resources, hasLength(size));
              if (!fault || label == 'current') expect(matched, size);
              results.add({
                'case': 'engine',
                'size': size,
                'fault': fault,
                'concurrency': concurrency,
                'round': round,
                'ms': clock.elapsedMilliseconds,
                'requests': api.calls,
                'peakConcurrency': api.peak,
                'matched': matched,
                'recoveryMs': api.recoveryMs,
                'rss': ProcessInfo.currentRss,
                'peakRss': ProcessInfo.maxRss,
              });
              await controller.close();
              images.close();
              await store.close();
              api.close();
              await temp.delete(recursive: true);
            }
          }
        }
      }
      if (!focus5000) {
        for (final size in [100, 1000, 5000]) {
          for (final fault in [false, true]) {
            for (var round = 0; round < 3; round++) {
              final adapter = _HttpAdapter(
                fault ? (size > 300 ? 301 : 31) : null,
              );
              final service = TmdbMetadataService(
                credentials: _Token(),
                dio: Dio()..httpClientAdapter = adapter,
              );
              var completed = 0;
              final clock = Stopwatch()..start();
              for (var i = 0; i < size; i++) {
                try {
                  await service.search(FilmMediaType.movie, 'item$i', 'en-US');
                  completed++;
                } on FilmCatalogException {
                  /* 测量旧实现真实失败数量。 */
                }
              }
              clock.stop();
              results.add({
                'case': 'http',
                'size': size,
                'fault': fault,
                'round': round,
                'ms': clock.elapsedMilliseconds,
                'requests': adapter.calls,
                'completed': completed,
                'recoveryMs': adapter.recoveryMs,
              });
              service.close();
            }
          }
        }
      }
      await Directory('build').create(recursive: true);
      await File(
        'build/scrape-benchmark-$label.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(results));
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

class _Files extends FilmFileMetadata {
  _Files(super.source, super.root) : super(localMode: false, canWrite: false);
  @override
  Future<FilmLocalMetadata?> load(FilmScanEntry entry, String language) async =>
      null;
}

class _Metadata extends TmdbMetadataService {
  _Metadata(this.failAt);
  final int? failAt;
  int calls = 0, active = 0, peak = 0;
  int? failedId, recoveryMs;
  DateTime? failedAt;
  @override
  Future<bool> hasToken() async => true;
  @override
  Future<FilmWork> details(
    FilmMediaType type,
    int id,
    String language, {
    LogoChooser? chooseLogo,
  }) async {
    final request = ++calls;
    active++;
    peak = max(peak, active);
    try {
      await Future<void>.delayed(Duration.zero);
      if (request == failAt) {
        failedId = id;
        failedAt = DateTime.now();
        throw const FilmCatalogException('metadataTimeout');
      }
      if (failedId == id && recoveryMs == null) {
        recoveryMs = DateTime.now().difference(failedAt!).inMilliseconds;
      }
      return FilmWork(
        type: type,
        tmdbId: id,
        title: 'Bench$id',
        originalTitle: 'Bench$id',
        overview: '',
        language: language,
        metadata: const {'belongs_to_collection': null},
      );
    } finally {
      active--;
    }
  }
}

class _Token extends TmdbCredentialStore {
  @override
  Future<String?> read() async => 'benchmark-fixture';
}

class _HttpAdapter implements HttpClientAdapter {
  _HttpAdapter(this.failAt);
  final int? failAt;
  int calls = 0;
  int? recoveryMs;
  DateTime? failedAt;
  Object? failedQuery;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    if (calls == failAt) {
      failedAt = DateTime.now();
      failedQuery = options.queryParameters['query'];
    } else if (failedAt != null &&
        recoveryMs == null &&
        options.queryParameters['query'] == failedQuery) {
      recoveryMs = DateTime.now().difference(failedAt!).inMilliseconds;
    }
    return ResponseBody.fromString(
      '{"results":[]}',
      calls == failAt ? 503 : 200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
