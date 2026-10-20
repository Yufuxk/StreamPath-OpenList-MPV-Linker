// 临时实机取证入口；完成后归档，不加入常规离线测试。
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/remote/webdav_client.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/film_catalog_scanner.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/domain/services/webdav_media_source_adapter.dart';
import 'package:streampath/domain/services/webdav_service.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';

class _Metadata extends TmdbMetadataService {
  _Metadata(this.store);
  final FilmCatalogStore store;
  int simulatedRequests = 0;
  @override
  Future<bool> hasToken() async => true;
  @override
  Future<List<FilmWork>> search(
    FilmMediaType type,
    String title,
    String language, {
    int? year,
    int page = 1,
  }) async {
    simulatedRequests++;
    return [];
  }

  @override
  Future<FilmWork> details(FilmMediaType type, int id, String language) async {
    simulatedRequests++;
    return (await store.cachedWork(type, id)) ??
        (throw const FilmCatalogException('metadataNotFound'));
  }

  @override
  Future<Map<String, dynamic>> season(
    int id,
    int number,
    String language,
  ) async {
    simulatedRequests++;
    return {'season_number': number, 'episodes': []};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test(
    'bounded real PROPFIND scan and cached metadata pipeline',
    () async {
      sqfliteFfiInit();
      final evidence = p.absolute('build/scrape-ui-20261020');
      final temp = await Directory.systemTemp.createTemp('sp-real-scrape-');
      final file = p.join(temp.path, 'catalog.db');
      await File(p.join(evidence, 'source-catalog.db')).copy(file);
      final store = await FilmCatalogStore.open(file);
      final db = await databaseFactoryFfi.openDatabase(file);
      final manualBefore = await db.rawQuery(
        "SELECT id,work_id,binding_version,season_number,episode_number FROM resources WHERE binding_origin='manual' OR episode_mapping_origin='manual' ORDER BY id",
      );
      final requests = <Map<String, Object?>>[];
      final started = <RequestOptions, Stopwatch>{};
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              final uri = options.uri;
              if (options.method != 'PROPFIND' ||
                  uri.origin != 'http://192.168.2.124:5244' ||
                  !uri.path.startsWith('/dav/QuarkFilmsData_STRM/') ||
                  uri.hasQuery ||
                  requests.length >= 60 ||
                  options.headers['Depth'] != '1') {
                throw StateError('Read-only probe request rejected');
              }
              started[options] = Stopwatch()..start();
              handler.next(options);
            },
            onResponse: (response, handler) {
              requests.add({
                'method': response.requestOptions.method,
                'path': response.requestOptions.uri.path,
                'status': response.statusCode,
                'microseconds': started
                    .remove(response.requestOptions)!
                    .elapsedMicroseconds,
              });
              handler.next(response);
            },
          ),
        );
      final roots = await store.roots();
      final tmdb = _Metadata(store);
      final sources = {
        for (final root in roots.where(
          (r) => r.path.startsWith('QuarkFilmsData_STRM/'),
        ))
          root.id: WebDavMediaSourceAdapter(
            WebDAVService(
              client: WebDavClient(
                baseUrl: 'http://192.168.2.124:5244/dav',
                username: Platform.environment['STREAMPATH_PROBE_USER']!,
                password: Platform.environment['STREAMPATH_PROBE_PASSWORD']!,
                dio: dio,
              ),
              profileId: root.sourceId,
            ),
          ),
      };
      final catalog = FilmCatalogController(
        store: store,
        tmdb: tmdb,
        images: FilmCatalogImageCache(
          Directory(p.join(temp.path, 'images')),
          tmdb,
        ),
        sourceFor: (root) => sources[root.id]!,
      );
      final results = <Map<String, Object?>>[];
      try {
        for (final sample in [
          'server-listings.json',
          'tv/server-listings.json',
        ]) {
          final data =
              jsonDecode(await File(p.join(evidence, sample)).readAsString())
                  as Map;
          for (final fullPath
              in (data['fixedSample'] as List).take(3).cast<String>()) {
            final relative = fullPath.substring('/dav/'.length);
            final root = roots.singleWhere(
              (r) =>
                  sources.containsKey(r.id) && filmPathWithin(relative, r.path),
            );
            await catalog.scan(root, scope: FilmScanScope(root.id, relative));
            await catalog.waitForScraping();
            expect(catalog.error, isNull);
            expect(catalog.scrapePaused, isFalse, reason: catalog.scrapeError);
            expect(catalog.scrapeProcessed, catalog.scrapeTotal);
            final resources = (await store.resources(
              rootId: root.id,
            )).where((r) => filmPathWithin(r.path, relative)).toList();
            expect(resources, isNotEmpty);
            results.add({
              'type': root.type.name,
              'path': relative,
              'resources': resources.length,
              'matched': resources.where((r) => r.workId != null).length,
              'processed': catalog.scrapeProcessed,
              'status': (await store.root(root.id))!.status,
            });
          }
        }
        expect(requests.every((r) => r['status'] == 207), isTrue);
        final manualAfter = await db.rawQuery(
          "SELECT id,work_id,binding_version,season_number,episode_number FROM resources WHERE binding_origin='manual' OR episode_mapping_origin='manual' ORDER BY id",
        );
        expect(manualAfter, manualBefore);
        expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
        await File(p.join(evidence, 'server-pipeline.json')).writeAsString(
          jsonEncode({
            'requests': requests,
            'results': results,
            'tmdb': 'cached metadata and fixed missing responses',
            'simulatedApiRequests': tmdb.simulatedRequests,
            'serverWrites': 0,
            'mediaReads': 0,
            'manualBindingsPreserved': manualBefore.length,
          }),
        );
      } finally {
        await catalog.close();
        dio.close(force: true);
        if (!p.isWithin(
              Directory.systemTemp.absolute.path,
              temp.absolute.path,
            ) ||
            !p.basename(temp.path).startsWith('sp-real-scrape-')) {
          throw StateError('Unexpected probe cleanup directory');
        }
        await temp.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
