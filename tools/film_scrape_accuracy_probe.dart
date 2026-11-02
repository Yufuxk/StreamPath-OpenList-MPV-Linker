// 刮削准确性探针：用生产扫描与匹配链路跑指定清单，TMDB 响应可录制／离线重放。
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/remote/webdav_client.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/film_catalog_matcher.dart';
import 'package:streampath/domain/services/film_catalog_scanner.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/domain/services/webdav_media_source_adapter.dart';
import 'package:streampath/domain/services/webdav_service.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';

import 'film_scrape_vcr.dart';

const _defaultRoots = [
  {
    'path': 'QuarkFilmsData_STRM/0.MoviesData',
    'type': 'movie',
    'name': 'Movies',
  },
  {
    'path': 'QuarkFilmsData_STRM/1.EpisodeData',
    'type': 'tv',
    'name': 'Episode',
  },
];

String _env(String name, {String? fallback}) {
  final value = Platform.environment[name];
  if (value == null || value.isEmpty) {
    if (fallback != null) return fallback;
    throw StateError('Missing environment variable $name');
  }
  return value;
}

/// 使用清单构造只读的 PROPFIND 应答，不访问真实服务器。
Dio _fixtureDio(Map<String, Map<String, bool>> tree, Set<String> listed) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.method != 'PROPFIND' ||
            options.uri.host != 'fixture.invalid' ||
            options.headers['Depth'] != '1') {
          throw StateError('Unexpected fixture request ${options.uri}');
        }
        final parent = options.uri.pathSegments
            .skip(1)
            .where((part) => part.isNotEmpty)
            .join('/');
        final children = tree[parent];
        if (children == null && !listed.contains(parent)) {
          handler.reject(
            DioException(
              requestOptions: options,
              message: 'Unknown fixture directory $parent',
            ),
          );
          return;
        }
        final xml = StringBuffer('<d:multistatus xmlns:d="DAV:">');
        for (final child
            in children?.entries ?? const <MapEntry<String, bool>>[]) {
          final full = parent.isEmpty ? child.key : '$parent/${child.key}';
          final href = Uri(path: '/dav/$full${child.value ? '/' : ''}');
          xml.write(
            '<d:response><d:href>$href</d:href><d:propstat><d:prop>'
            '<d:displayname>${p.posix.basename(full)}</d:displayname>'
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
  return dio;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test(
    'scrape accuracy over a manifest',
    () async {
      sqfliteFfiInit();
      final manifestFile = File(_env('ACCURACY_MANIFEST'));
      final outputFile = File(_env('ACCURACY_OUTPUT'));
      final cacheDirectory = _env('ACCURACY_CACHE', fallback: '');
      final offline = _env('ACCURACY_OFFLINE', fallback: '0') == '1';
      final manifest =
          jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      final roots =
          jsonDecode(
                _env(
                  'ACCURACY_ROOTS',
                  fallback: manifest['roots'] == null
                      ? jsonEncode(_defaultRoots)
                      : jsonEncode(manifest['roots']),
                ),
              )
              as List;
      final entries = (manifest['entries'] as List)
          .cast<Map<String, dynamic>>();
      final tree = <String, Map<String, bool>>{};
      for (final entry in entries) {
        final parent = entry['parent'] as String;
        (tree[parent] ??= {})[entry['name'] as String] =
            entry['directory'] as bool;
      }
      // 清单里的请求记录用于区分“已枚举的空目录”和“未枚举目录”。
      final listed = <String>{
        for (final request in (manifest['requests'] as List? ?? const []))
          if ((request as Map)['path'] case final String path)
            path.substring('/dav/'.length),
      };
      final temp = await Directory.systemTemp.createTemp('sp-accuracy-');
      final store = await FilmCatalogStore.open(
        p.join(temp.path, 'catalog.db'),
      );
      final adapter = RecordingHttpAdapter(cacheDirectory, offline: offline);
      final tmdb = TmdbMetadataService(
        credentials: const TmdbCredentialStore(),
        dio: Dio()..httpClientAdapter = adapter,
      );
      final images = FilmCatalogImageCache(
        Directory(p.join(temp.path, 'artwork')),
        tmdb,
        dio: Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) => handler.reject(
                DioException(
                  requestOptions: options,
                  message: 'Probe does not download artwork',
                ),
              ),
            ),
          ),
      );
      final source = WebDavMediaSourceAdapter(
        WebDAVService(
          client: WebDavClient(
            baseUrl: 'https://fixture.invalid/dav',
            dio: _fixtureDio(tree, listed),
          ),
          profileId: 'accuracy-fixture',
        ),
      );
      final catalog = FilmCatalogController(
        store: store,
        tmdb: tmdb,
        images: images,
        sourceFor: (_) => source,
      );
      final matcher = FilmCatalogMatcher(store, tmdb);
      final fast = _env('ACCURACY_MODE', fallback: 'fast') == 'fast';
      final results = <Map<String, Object?>>[];
      final runs = <Map<String, Object?>>[];
      try {
        for (final spec in roots.cast<Map<String, dynamic>>()) {
          final id = await store.addRoot(
            sourceId: 'accuracy-fixture',
            kind: MediaSourceKind.webdav,
            path: spec['path'] as String,
            type: FilmMediaType.values.byName(spec['type'] as String),
            name: (spec['name'] as String?) ?? (spec['type'] as String),
          );
          final root = (await store.root(id))!;
          String? error;
          if (fast) {
            // 仅去掉远程目录间隔，扫描与匹配仍走生产实现。
            final scanner = FilmCatalogScanner(
              store,
              remoteInterval: Duration.zero,
            );
            final session = await matcher.scanSession(
              root,
              cancelled: () => false,
            );
            error = session.error;
            try {
              await scanner.scan(
                root,
                source,
                onEntries: (entries) async {
                  await session.prepare(entries);
                  // 传输故障会暂停 session；探针在恢复连接后重试当前批次。
                  if (session.paused) {
                    final code = session.error;
                    session.resume();
                    await session.prepare(entries);
                    if (session.paused) {
                      stdout.writeln(
                        'ACCURACY_PAUSED ${root.path} ${code ?? session.error}',
                      );
                    }
                  }
                  final matches = <String, FilmScanMatch>{};
                  for (final entry in entries) {
                    final key = filmPathKey(entry.path, root.sourceKind);
                    final match = session.matches[key];
                    if (match != null) matches[key] = match;
                  }
                  if (matches.isNotEmpty) {
                    await store.applyMetadata(root.id, matches);
                  }
                  session.releaseCommitted(
                    entries.map((e) => filmPathKey(e.path, root.sourceKind)),
                  );
                },
              );
              error ??= session.error;
            } on FilmCatalogException catch (cause) {
              error = cause.code;
              stdout.writeln('ACCURACY_SCAN_ERROR ${root.path} ${cause.code}');
            } catch (cause, stack) {
              error = 'unexpected';
              stdout.writeln('ACCURACY_SCAN_ERROR ${root.path} $cause\n$stack');
            } finally {
              await scanner.shutdown();
            }
            await matcher.resolveConflicts(root.id);
            await matcher.assignExtras(root.id);
            await store.setMatcherVersion(FilmCatalogMatcher.matchingVersion);
          } else {
            await catalog.scan(root);
            await catalog.waitForScraping();
            error = catalog.error ?? catalog.scrapeError;
          }
          runs.add({
            'rootId': id,
            'type': root.type.name,
            'path': root.path,
            'error': error,
            'scrapeError': fast ? null : catalog.scrapeError,
            'paused': fast ? false : catalog.scrapePaused,
            'processed': fast ? null : catalog.scrapeProcessed,
            'total': fast ? null : catalog.scrapeTotal,
            'status': (await store.root(id))!.status,
          });
          final works = {
            for (final work in await store.works(type: null, limit: 5000))
              work.id: work,
          };
          for (final resource in await store.resources(rootId: id)) {
            final work = resource.workId == null
                ? null
                : works[resource.workId];
            results.add({
              'rootId': id,
              'type': root.type.name,
              'path': resource.path,
              'parent': resource.parentPath,
              'name': resource.name,
              'mediaKind': resource.mediaKind,
              'workId': resource.workId,
              'tmdbId': work?.tmdbId,
              'title': work?.title,
              'origin': resource.bindingOrigin,
              'season': resource.season,
              'episode': resource.episode,
              'mappingOrigin': resource.mappingOrigin,
            });
          }
        }
        await outputFile.parent.create(recursive: true);
        await outputFile.writeAsString(
          jsonEncode({
            'manifest': manifestFile.path,
            'offline': offline,
            'tmdbRequests': {
              'recorded': adapter.recorded,
              'replayed': adapter.replayed,
            },
            'runs': runs,
            'resources': results,
          }),
        );
        // 逐条打印便于在测试日志中定位异常。
        stdout.writeln(
          'ACCURACY_RUNS ${jsonEncode(runs.map((r) => {'path': r['path'], 'processed': r['processed'], 'error': r['error'] ?? r['scrapeError']}).toList())}',
        );
        stdout.writeln(
          'ACCURACY_TMDB recorded=${adapter.recorded} replayed=${adapter.replayed}',
        );
      } finally {
        await catalog.close();
        if (!p.isWithin(
              Directory.systemTemp.absolute.path,
              temp.absolute.path,
            ) ||
            !p.basename(temp.path).startsWith('sp-accuracy-')) {
          throw StateError('Unexpected probe cleanup directory');
        }
        await temp.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 180)),
  );
}
