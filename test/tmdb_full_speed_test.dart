import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';

void main() {
  test(
    'pausing full speed cancels active and queued image downloads without closing the cache',
    () async {
      final temp = await Directory.systemTemp.createTemp('fast_images_');
      await File('${temp.path}/configuration.json').writeAsString(
        jsonEncode({
          'secure_base_url': 'https://image.tmdb.org/t/p/',
          'poster_sizes': ['original'],
          'backdrop_sizes': ['original'],
          'logo_sizes': ['original'],
        }),
      );
      final adapter = _ImageAdapter();
      final tmdb = TmdbMetadataService();
      final images = FilmCatalogImageCache(
        temp,
        tmdb,
        dio: Dio()..httpClientAdapter = adapter,
        validateImage: (_) async {},
      );
      try {
        images.beginFullSpeed();
        final pending = Future.wait(
          List.generate(
            6,
            (i) => images
                .get('/$i.jpg', target: 'original')
                .then<Object>((file) => file, onError: (Object error) => error),
          ),
        );
        await adapter.started.future;
        images.stopFullSpeed();
        final count = adapter.requests;
        final results = await pending.timeout(const Duration(seconds: 2));
        expect(
          results.every((result) => result is FilmCatalogException),
          isTrue,
        );
        expect(adapter.requests, count);
        await expectLater(
          images.get('/blocked.jpg'),
          throwsA(isA<FilmCatalogException>()),
        );
        images.endFullSpeed();
        adapter.hold = false;
        expect(
          await (await images.get('/after.jpg', target: 'original')).length(),
          3,
        );
      } finally {
        images.close();
        tmdb.close();
        await temp.delete(recursive: true);
      }
    },
  );
  test(
    'full speed coalesces identical searches and restores standard serial execution',
    () async {
      final adapter = _Adapter();
      final service = TmdbMetadataService(
        credentials: _Credentials(),
        dio: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(service.close);
      service.beginFullSpeed();
      await Future.wait(
        List.generate(
          16,
          (_) => service.search(FilmMediaType.movie, 'same', 'en-US'),
        ),
      );
      expect(adapter.starts.length, 1);
      await Future.wait(
        List.generate(
          8,
          (i) => service.search(FilmMediaType.movie, 'fast$i', 'en-US'),
        ),
      );
      expect(adapter.peak, inInclusiveRange(2, 8));
      service.endFullSpeed();
      adapter.peak = 0;
      await Future.wait(
        List.generate(
          4,
          (i) => service.search(FilmMediaType.movie, 'normal$i', 'en-US'),
        ),
      );
      expect(adapter.peak, 1);
    },
  );

  test('full speed limits actual HTTP starts to 20 per second', () async {
    final adapter = _Adapter();
    final service = TmdbMetadataService(
      credentials: _Credentials(),
      dio: Dio()..httpClientAdapter = adapter,
    );
    addTearDown(service.close);
    service.beginFullSpeed();
    await Future.wait(
      List.generate(
        24,
        (i) => service.search(FilmMediaType.movie, 'movie$i', 'en-US'),
      ),
    );
    expect(adapter.peak, lessThanOrEqualTo(8));
    for (var i = 20; i < adapter.starts.length; i++) {
      expect(
        adapter.starts[i] - adapter.starts[i - 20],
        greaterThanOrEqualTo(990000),
      );
    }
    service.endFullSpeed();
  });

  test('429 stops queued HTTP requests without automatic retry', () async {
    final adapter = _Adapter()..limited = true;
    final service = TmdbMetadataService(
      credentials: _Credentials(),
      dio: Dio()..httpClientAdapter = adapter,
    );
    addTearDown(service.close);
    service.beginFullSpeed();
    final results = await Future.wait(
      List.generate(
        12,
        (i) => service
            .search(FilmMediaType.movie, 'limited$i', 'en-US')
            .then<Object>((_) => 'success', onError: (Object error) => error),
      ),
    );
    expect(
      results.every(
        (result) =>
            result is FilmCatalogException && result.code == 'rateLimited',
      ),
      isTrue,
    );
    expect(adapter.starts.length, 1);
    service.endFullSpeed();
  });

  test(
    'cancelling full speed drains queued requests and later normal requests work',
    () async {
      final adapter = _Adapter();
      final service = TmdbMetadataService(
        credentials: _Credentials(),
        dio: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(service.close);
      service.beginFullSpeed();
      final pending = Future.wait(
        List.generate(
          20,
          (i) => service
              .search(FilmMediaType.movie, 'cancel$i', 'en-US')
              .then<Object>((_) => 'success', onError: (Object error) => error),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 70));
      service.stopFullSpeed();
      final count = adapter.starts.length;
      await pending.timeout(const Duration(seconds: 2));
      expect(adapter.starts.length, count);
      service.endFullSpeed();
      expect(
        await service.search(FilmMediaType.movie, 'after', 'en-US'),
        isEmpty,
      );
    },
  );
}

class _ImageAdapter implements HttpClientAdapter {
  final started = Completer<void>();
  int requests = 0;
  bool hold = true;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    if (hold) {
      if (requests == 4) started.complete();
      await cancelFuture;
    }
    return ResponseBody.fromBytes([1, 2, 3], 200);
  }

  @override
  void close({bool force = false}) {}
}

class _Credentials extends TmdbCredentialStore {
  @override
  Future<String?> read() async => 'fixture-token';
}

class _Adapter implements HttpClientAdapter {
  final clock = Stopwatch()..start();
  final starts = <int>[];
  int active = 0, peak = 0;
  bool limited = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    starts.add(clock.elapsedMicroseconds);
    active++;
    peak = math.max(peak, active);
    try {
      if (!limited) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      return ResponseBody.fromString(
        jsonEncode(limited ? {} : {'results': []}),
        limited ? 429 : 200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
          if (limited) 'retry-after': ['2'],
        },
      );
    } finally {
      active--;
    }
  }

  @override
  void close({bool force = false}) {}
}
