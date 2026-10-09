import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/video_queue.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/film_library_transfer.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';

// 独立数据库诊断；不将测试 VM 的事件循环延迟当作 Windows UI/raster 帧时间。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'three isolated rounds with 10000 works and 50000 resources',
    () async {
      sqfliteFfiInit();
      final temporary = await Directory.systemTemp.createTemp(
        'sp_phase5_scale_',
      );
      final baseline = p.join(temporary.path, 'baseline.db');
      final seed = await FilmCatalogStore.open(baseline);
      final rootId = await seed.addRoot(
        sourceId: 'fixture',
        kind: MediaSourceKind.local,
        path: 'Movies',
        type: FilmMediaType.movie,
        name: 'Fixture',
      );
      await seed.close();
      final db = await databaseFactoryFfi.openDatabase(baseline);
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (var id = 1; id <= 10000; id++) {
          batch.insert('works', {
            'id': id,
            ...FilmWork(
              type: FilmMediaType.movie,
              tmdbId: id,
              title: 'Movie $id',
              originalTitle: 'Movie $id',
              year: 2020,
              overview: 'Fixture',
              language: 'en',
            ).toRow(),
          });
          for (var version = 1; version <= 5; version++) {
            final path = 'Movies/Item$id/Movie.$id.v$version.mkv';
            batch.insert('resources', {
              'root_id': rootId,
              'relative_path': path,
              'path_key': path.toLowerCase(),
              'parent_path': 'Movies/Item$id',
              'name': 'Movie.$id.v$version.mkv',
              'media_kind': 'video',
              'last_seen_generation': 0,
              'work_id': id,
              'binding_origin': 'search',
              'created_at': 0,
            });
          }
        }
        await batch.commit(noResult: true);
      });
      await db.close();
      final results = <Map<String, Object?>>[];
      try {
        for (var round = 1; round <= 3; round++) {
          final directory = Directory(p.join(temporary.path, 'round$round'));
          await directory.create();
          final file = await File(
            baseline,
          ).copy(p.join(directory.path, 'catalog.db'));
          final store = await FilmCatalogStore.open(file.path);
          final tmdb = TmdbMetadataService();
          final images = FilmCatalogImageCache(
            Directory(p.join(directory.path, 'images')),
            tmdb,
          );
          final transfer = FilmLibraryTransfer(
            store: store,
            images: images,
            records: {},
            progress: {},
            targetFor: (_) => null,
            dataDirectory: directory,
          );
          FilmTransferPreview? preview;
          final samples = <double>[];
          var previous = DateTime.now();
          var maxLagMs = 0.0;
          var phase = 'export';
          final phaseLag = <String, double>{};
          final timer = Timer.periodic(const Duration(milliseconds: 8), (_) {
            final now = DateTime.now();
            final gap = now.difference(previous).inMicroseconds / 1000 - 8;
            if (gap > maxLagMs) maxLagMs = gap;
            if (gap > (phaseLag[phase] ?? 0)) phaseLag[phase] = gap;
            previous = now;
          });
          final clock = Stopwatch()..start();
          try {
            final root = (await store.root(rootId))!;
            Future<void> scan() async {
              final generation = await store.beginScan(rootId);
              await store.stage(root, generation, [
                for (var version = 1; version <= 5; version++)
                  FilmScanEntry(
                    path: 'Movies/Item1/Movie.1.v$version.mkv',
                    parentPath: 'Movies/Item1',
                    name: 'Movie.1.v$version.mkv',
                    mediaKind: 'video',
                  ),
              ]);
              await store.commitScan(
                rootId,
                generation,
                cancelled: () => false,
                scopePath: 'Movies/Item1',
              );
            }

            Future<void> progress() async {
              for (var i = 1; i <= 20; i++) {
                await store.recordVideoProgress(
                  VideoProgressUpdate(
                    sourceId: 'fixture',
                    path: 'Movies/Item$i/Movie.$i.v1.mkv',
                    positionMs: i * 1000,
                    durationMs: 120000,
                    recordedAt: DateTime.now(),
                  ),
                );
              }
            }

            Future<void> pages() async {
              for (var i = 0; i < 20; i++) {
                final query = Stopwatch()..start();
                final works = await store.works(type: null, offset: i * 60);
                expect(works, hasLength(60));
                expect(
                  await store.resources(workId: works.first.id),
                  hasLength(5),
                );
                samples.add(query.elapsedMicroseconds / 1000);
              }
            }

            late final File package;
            await Future.wait([
              scan(),
              progress(),
              pages(),
              transfer.export().then((file) => package = file),
            ]);
            final exportMs = clock.elapsedMilliseconds;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            phase = 'preflight';
            clock.reset();
            preview = await FilmLibraryTransfer.preflight(package);
            expect(preview.counts['metadata'], 10000);
            expect(
              (preview.data['catalog']['resources'] as List),
              hasLength(50000),
            );
            final preflightMs = clock.elapsedMilliseconds;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            phase = 'import';
            clock.reset();
            final imported = await transfer.import(
              preview,
              {'metadata'},
              {'fixture': 'fixture'},
              matches: (_) async => true,
            );
            final importMs = clock.elapsedMilliseconds;
            expect(imported['works'] ?? 0, 0);
            expect(
              (await store.works(type: null, limit: 10001)),
              hasLength(10000),
            );
            expect(await store.resources(), hasLength(50000));
            samples.sort();
            results.add({
              'round': round,
              'works': 10000,
              'resources': 50000,
              'pageCycles': 20,
              'pageAndDetailP95Ms': samples[18],
              'exportAndConcurrentTasksMs': exportMs,
              'preflightMs': preflightMs,
              'repeatImportMs': importMs,
              'maxEventLoopLagMs': maxLagMs,
              'phaseEventLoopLagMs': phaseLag,
              'rssMiB': ProcessInfo.currentRss / (1024 * 1024),
            });
          } finally {
            timer.cancel();
            await preview?.close();
            images.close();
            tmdb.close();
            await store.close();
          }
        }
        final result = {
          'mode': 'Flutter test VM database diagnostic',
          'uiRasterFrameAcceptance': 'not measured',
          'rounds': results,
        };
        await File(
          'build/phase5_scale_results.json',
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(result));
        // ignore: avoid_print
        print(jsonEncode(result));
      } finally {
        await temporary.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
