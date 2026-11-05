import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart' as win32;
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/film_fast_task.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/remote/webdav_client.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/domain/services/webdav_media_source_adapter.dart';
import 'package:streampath/domain/services/webdav_service.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';

/// AOT 核心流水对照；来源为本地 HTTP，元数据为固定延迟响应。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: CircularProgressIndicator())),
    ),
  );
  final output = Directory('build/full-speed-validation');
  await output.create(recursive: true);
  try {
    final name = 'StreamPath.MainWindow'.toNativeUtf16();
    final window = win32.FindWindow(name, nullptr);
    calloc.free(name);
    final owner = calloc<Uint32>();
    win32.GetWindowThreadProcessId(window, owner);
    final owned = window != 0 && owner.value == win32.GetCurrentProcessId();
    calloc.free(owner);
    if (!owned) throw StateError('Benchmark window ownership mismatch');
    win32.ShowWindow(window, win32.SW_HIDE);
    await _benchmark(output);
  } catch (error, stack) {
    await File(
      '${output.path}/release-benchmark-failure.txt',
    ).writeAsString('$error\n$stack');
  } finally {
    const channel = MethodChannel('streampath/appearance');
    channel.setMethodCallHandler((call) async => null);
    await channel.invokeMethod<void>('close');
  }
}

Future<void> _benchmark(Directory output) async {
  final results = <Map<String, Object>>[];
  String? reference;
  for (var trial = 0; trial < 3; trial++) {
    for (final mode in FilmTaskExecutionMode.values) {
      final fixture = await _Fixture.open();
      try {
        for (final cache in ['cold', 'warm']) {
          fixture.reads = fixture.active = fixture.peak = 0;
          fixture.api.requests = fixture.api.active = fixture.api.peak = 0;
          var peakRss = ProcessInfo.currentRss;
          final sampler = Timer.periodic(const Duration(milliseconds: 20), (_) {
            peakRss = math.max(peakRss, ProcessInfo.currentRss);
          });
          final cpu = _cpuMicros();
          final clock = Stopwatch()..start();
          try {
            await fixture.catalog.scan(fixture.root, executionMode: mode);
            await fixture.catalog.waitForScraping();
          } finally {
            sampler.cancel();
          }
          clock.stop();
          final resources = await fixture.catalog.store.resources();
          if (resources.length != 16 ||
              resources.any((r) => r.workId == null) ||
              await fixture.catalog.store.fastTask() != null) {
            throw StateError('Benchmark inventory or task completion mismatch');
          }
          final bindings = <String>[];
          for (final resource in resources) {
            final work = (await fixture.catalog.store.work(resource.workId!))!;
            bindings.add(
              '${resource.path}:${work.tmdbId}:${resource.bindingOrigin}',
            );
          }
          bindings.sort();
          final snapshot = jsonEncode(bindings);
          reference ??= snapshot;
          if (reference != snapshot) {
            throw StateError('Benchmark results differ between modes');
          }
          results.add({
            'trial': trial,
            'mode': mode.name,
            'cache': cache,
            'elapsedMs': clock.elapsedMilliseconds,
            'cpuMicros': _cpuMicros() - cpu,
            'peakRssBytes': peakRss,
            'directoryRequests': fixture.reads,
            'directoryConcurrency': fixture.peak,
            'metadataRequests': fixture.api.requests,
            'metadataConcurrency': fixture.api.peak,
            'resources': resources.length,
          });
        }
        final close = Stopwatch()..start();
        await fixture.closeController();
        close.stop();
        results.last['closeMs'] = close.elapsedMilliseconds;
      } finally {
        await fixture.close();
      }
    }
  }
  for (var trial = 0; trial < 3; trial++) {
    for (final cache in ['cold', 'warm']) {
      final standard = results.singleWhere(
        (r) =>
            r['trial'] == trial &&
            r['cache'] == cache &&
            r['mode'] == 'standard',
      );
      final fast = results.singleWhere(
        (r) =>
            r['trial'] == trial &&
            r['cache'] == cache &&
            r['mode'] == 'fullSpeed',
      );
      if ((standard['elapsedMs'] as int) < 2 * (fast['elapsedMs'] as int)) {
        throw StateError('Benchmark throughput target was not met');
      }
    }
  }
  await File(
    '${output.path}/release-benchmark.json',
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(results));
}

class _Fixture {
  _Fixture(this.temp, this.server);
  final Directory temp;
  final HttpServer server;
  final api = _Api();
  late final FilmCatalogController catalog;
  late final FilmCatalogRoot root;
  int reads = 0, active = 0, peak = 0;
  bool closed = false;
  static Future<_Fixture> open() async {
    final fixture = _Fixture(
      await Directory.systemTemp.createTemp('sp_fast_aot_'),
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    fixture.server.listen(fixture.directory);
    final store = await FilmCatalogStore.open(
      '${fixture.temp.path}/catalog.db',
    );
    final id = await store.addRoot(
      sourceId: 'dav',
      kind: MediaSourceKind.webdav,
      path: 'Movies',
      type: FilmMediaType.movie,
      name: 'Movies',
    );
    fixture.root = (await store.root(id))!;
    final source = WebDavMediaSourceAdapter(
      WebDAVService(
        client: WebDavClient(
          baseUrl: 'http://127.0.0.1:${fixture.server.port}/dav/',
        ),
        profileId: 'dav',
      ),
    );
    final tmdb = TmdbMetadataService(
      credentials: _Credentials(),
      dio: Dio()..httpClientAdapter = fixture.api,
    );
    fixture.catalog = FilmCatalogController(
      store: store,
      tmdb: tmdb,
      images: FilmCatalogImageCache(
        Directory('${fixture.temp.path}/images'),
        tmdb,
      ),
      sourceFor: (_) => source,
    );
    return fixture;
  }

  Future<void> directory(HttpRequest request) async {
    reads++;
    active++;
    peak = math.max(peak, active);
    try {
      await request.drain<void>();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final path = request.uri.path
          .replaceFirst('/dav/', '')
          .replaceFirst(RegExp(r'/$'), '');
      final index = int.tryParse(path.split('/').last.replaceFirst('D', ''));
      final entries = path == 'Movies'
          ? List.generate(8, (i) => 'D$i/')
          : index == null
          ? <String>[]
          : ['Bench${index * 2}.2020.mkv', 'Bench${index * 2 + 1}.2020.mkv'];
      request.response.statusCode = 207;
      request.response.headers.contentType = ContentType(
        'application',
        'xml',
        charset: 'utf-8',
      );
      request.response.write(
        '<d:multistatus xmlns:d="DAV:">${entries.map((name) => '<d:response><d:href>/dav/$path/$name</d:href><d:propstat><d:prop><d:displayname>${name.replaceAll('/', '')}</d:displayname><d:resourcetype>${name.endsWith('/') ? '<d:collection/>' : ''}</d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>').join()}</d:multistatus>',
      );
      await request.response.close();
    } finally {
      active--;
    }
  }

  Future<void> closeController() async {
    if (closed) return;
    closed = true;
    await catalog.close();
  }

  Future<void> close() async {
    await closeController();
    await server.close(force: true);
    await temp.delete(recursive: true);
  }
}

class _Credentials extends TmdbCredentialStore {
  @override
  Future<String?> read() async => 'fixture-token';
}

class _Api implements HttpClientAdapter {
  int requests = 0, active = 0, peak = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    active++;
    peak = math.max(peak, active);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final search = options.path.contains('/search/');
      final id = search
          ? int.parse(
                  RegExp(r'\d+')
                      .firstMatch(options.queryParameters['query'] as String)!
                      .group(0)!,
                ) +
                1
          : int.parse(
              options.path.split('/').where((part) => part != 'images').last,
            );
      final work = <String, dynamic>{
        'id': id,
        'title': 'Bench${id - 1}',
        'original_title': 'Bench${id - 1}',
        'release_date': '2020-01-01',
        'overview': '',
        'genres': [],
        'backdrops': [],
        'belongs_to_collection': null,
      };
      return ResponseBody.fromString(
        jsonEncode(
          search
              ? {
                  'results': [work],
                }
              : work,
        ),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    } finally {
      active--;
    }
  }

  @override
  void close({bool force = false}) {}
}

int _cpuMicros() {
  final creation = calloc<win32.FILETIME>(), exit = calloc<win32.FILETIME>();
  final kernel = calloc<win32.FILETIME>(), user = calloc<win32.FILETIME>();
  try {
    if (win32.GetProcessTimes(
          win32.GetCurrentProcess(),
          creation,
          exit,
          kernel,
          user,
        ) ==
        0) {
      throw StateError('Cannot read process CPU time');
    }
    int ticks(win32.FILETIME value) =>
        (value.dwHighDateTime << 32) | value.dwLowDateTime;
    return (ticks(kernel.ref) + ticks(user.ref)) ~/ 10;
  } finally {
    calloc.free(creation);
    calloc.free(exit);
    calloc.free(kernel);
    calloc.free(user);
  }
}
