import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';

void main() {
  for (final fast in [false, true]) {
    for (final status in [429, 500, 502, 503, 504]) {
      test('temporary HTTP $status recovers ($fast)', () async {
        final adapter = _Adapter((i, _) => i == 1 ? status : 200);
        final delays = <Duration>[];
        final service = TmdbMetadataService(
          credentials: _Token(),
          dio: Dio()..httpClientAdapter = adapter,
          retryDelay: (delay) async {
            delays.add(delay);
          },
        );
        addTearDown(service.close);
        if (fast) service.beginFullSpeed();
        expect(
          await service.search(FilmMediaType.movie, 'test', 'en-US'),
          isEmpty,
        );
        expect(adapter.calls, 2);
        if (status != 429) expect(delays, isNotEmpty);
      });
    }
    test('rate limit wait cancels immediately ($fast)', () async {
      final adapter = _Adapter((_, _) => 429)..retryAfter = '10';
      final service = TmdbMetadataService(
        credentials: _Token(),
        dio: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(service.close);
      if (fast) service.beginFullSpeed();
      final waiting = Completer<void>();
      service.retryUntil.addListener(() {
        if (service.retryUntil.value != null && !waiting.isCompleted) {
          waiting.complete();
        }
      });
      final request = service.search(FilmMediaType.movie, 'cancel', 'en-US');
      final checked = expectLater(request, throwsA(_code('cancelled')));
      await waiting.future;
      if (fast) {
        service.stopFullSpeed();
      } else {
        service.pauseStandardRequests();
      }
      await checked.timeout(const Duration(seconds: 1));
      expect(adapter.calls, 1);
    });
  }
  for (final status in [401, 403, 404]) {
    test('HTTP $status is never retried', () async {
      final adapter = _Adapter((_, _) => status);
      final service = TmdbMetadataService(
        credentials: _Token(),
        dio: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(service.close);
      await expectLater(
        service.search(FilmMediaType.movie, 'test', 'en-US'),
        throwsA(_code(status == 404 ? 'metadataNotFound' : 'invalidToken')),
      );
      expect(adapter.calls, 1);
    });
  }
  for (final date in [false, true]) {
    test('shared Retry-After beyond budget blocks new calls ($date)', () async {
      final adapter = _Adapter((_, _) => 429)
        ..retryAfter = date
            ? HttpDate.format(DateTime.now().add(const Duration(minutes: 2)))
            : '120';
      final service = TmdbMetadataService(
        credentials: _Token(),
        dio: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(service.close);
      for (var i = 0; i < 3; i++) {
        await expectLater(
          service.search(FilmMediaType.movie, 'item$i', 'en-US'),
          throwsA(_code('rateLimited')),
        );
      }
      expect(adapter.calls, 1);
    });
  }
  for (final date in [false, true]) {
    test('429 cooldown is shared and automatically resumes ($date)', () async {
      final adapter = _Adapter((i, _) => i == 1 ? 429 : 200)
        ..retryAfter = date
            ? HttpDate.format(DateTime.now().add(const Duration(seconds: 2)))
            : '1';
      final service = TmdbMetadataService(
        credentials: _Token(),
        dio: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(service.close);
      service.beginFullSpeed();
      final results = await Future.wait(
        List.generate(
          8,
          (i) => service.search(FilmMediaType.movie, 'cooldown$i', 'en-US'),
        ),
      );
      expect(results.every((r) => r.isEmpty), isTrue);
      expect(adapter.calls, 9);
      expect(
        adapter.starts[1].difference(adapter.starts[0]),
        greaterThanOrEqualTo(const Duration(milliseconds: 900)),
      );
    });
  }
  test(
    'concurrent shared request retries once and failed futures are evicted',
    () async {
      var failed = true;
      final adapter = _Adapter((_, _) => failed ? 503 : 200);
      final service = TmdbMetadataService(
        credentials: _Token(),
        dio: Dio()..httpClientAdapter = adapter,
        retryDelay: (_) async {},
      );
      addTearDown(service.close);
      service.beginFullSpeed();
      final results = await Future.wait(
        List.generate(
          8,
          (_) => service
              .search(FilmMediaType.movie, 'same', 'en-US')
              .then<Object>((value) => value, onError: (Object error) => error),
        ),
      );
      expect(adapter.calls, 3);
      expect(results.every((v) => v is FilmCatalogException), isTrue);
      failed = false;
      expect(
        await service.search(FilmMediaType.movie, 'same', 'en-US'),
        isEmpty,
      );
      expect(adapter.calls, 4);
    },
  );
}

Matcher _code(String value) =>
    isA<FilmCatalogException>().having((e) => e.code, 'code', value);

class _Token extends TmdbCredentialStore {
  @override
  Future<String?> read() async => 'fixture-token';
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.status);
  final int Function(int, RequestOptions) status;
  int calls = 0;
  final starts = <DateTime>[];
  String retryAfter = '0';
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    starts.add(DateTime.now());
    final code = status(++calls, options);
    return ResponseBody.fromString(
      jsonEncode({'results': []}),
      code,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        'retry-after': [retryAfter],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
