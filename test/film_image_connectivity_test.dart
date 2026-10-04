import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late _Metadata metadata;
  late Uint8List bytes;
  final caches = <FilmCatalogImageCache>[];
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('film_image_connectivity_');
    metadata = _Metadata();
    bytes = await File('assets/tmdb_logo.png').readAsBytes();
  });
  tearDown(() async {
    for (final cache in caches) {
      cache.close();
    }
    caches.clear();
    metadata.close();
    await temp.delete(recursive: true);
  });

  FilmCatalogImageCache cacheFor(_Adapter adapter, {int? maxBytes}) {
    final cache = FilmCatalogImageCache(
      temp,
      metadata,
      dio: Dio(BaseOptions(headers: {'Authorization': 'Bearer fixture'}))
        ..httpClientAdapter = adapter,
      maxImageBytes: maxBytes ?? 10 * 1024 * 1024,
    );
    caches.add(cache);
    return cache;
  }

  ResponseBody image() => ResponseBody(Stream.value(bytes), 200);
  Matcher code(String value) =>
      isA<FilmCatalogException>().having((e) => e.code, 'code', value);

  for (final type in [
    DioExceptionType.connectionError,
    DioExceptionType.connectionTimeout,
    DioExceptionType.sendTimeout,
    DioExceptionType.receiveTimeout,
    DioExceptionType.unknown,
  ]) {
    test('图片网络故障切换固定 CDN，真实解码后复用入口与缓存 $type', () async {
      final adapter = _Adapter((options) async {
        if (options.uri.host == 'image.tmdb.org') {
          throw DioException(
            requestOptions: options,
            type: type,
            error: type == DioExceptionType.unknown
                ? const HandshakeException('fixture reset')
                : null,
          );
        }
        return image();
      });
      final cache = cacheFor(adapter);
      final first = await cache.get('/a.png');
      expect(await first.readAsBytes(), bytes);
      expect(
        p.basename(first.path),
        '${FilmCatalogImageCache.cacheKey('/a.png', 'w342')}.img',
      );
      await cache.get('/b.png');
      expect((await cache.get('/a.png')).path, first.path);
      expect(adapter.requests.map((r) => r.uri.host), [
        'image.tmdb.org',
        'tmdb-image-prod.b-cdn.net',
        'tmdb-image-prod.b-cdn.net',
      ]);
      for (final request in adapter.requests) {
        expect(request.uri.scheme, 'https');
        expect(request.uri.path, startsWith('/t/p/w342/'));
        expect(request.headers['Authorization'], isNull);
        expect(request.followRedirects, isFalse);
        expect(request.maxRedirects, 0);
        expect(request.connectTimeout, const Duration(seconds: 5));
      }
    });
  }

  test('CDN 网络失败可切回主入口，两入口均失败只请求两次', () async {
    var failing = 'image.tmdb.org';
    var failAll = false;
    final adapter = _Adapter((options) async {
      if (failAll || options.uri.host == failing) {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      }
      return image();
    });
    final cache = cacheFor(adapter);
    await cache.get('/a.png');
    failing = 'tmdb-image-prod.b-cdn.net';
    await cache.get('/b.png');
    await cache.get('/c.png');
    expect(adapter.requests.map((r) => r.uri.host), [
      'image.tmdb.org',
      'tmdb-image-prod.b-cdn.net',
      'tmdb-image-prod.b-cdn.net',
      'image.tmdb.org',
      'image.tmdb.org',
    ]);
    failAll = true;
    await expectLater(cache.get('/d.png'), throwsA(code('imageFailed')));
    expect(adapter.requests.length, 7);
    expect(await cache.cached('/d.png', 'w342'), isNull);
    expect(temp.listSync().where((f) => f.path.endsWith('.partial')), isEmpty);
  });

  for (final status in [302, 403, 404, 429, 500]) {
    test('图片 HTTP $status 保留错误且不跟随重定向或切换', () async {
      final adapter = _Adapter(
        (_) async => ResponseBody(
          Stream.value(bytes),
          status,
          headers: {
            'location': ['https://untrusted.invalid/image.png'],
          },
        ),
      );
      final cache = cacheFor(adapter);
      await expectLater(cache.get('/a.png'), throwsA(code('imageFailed')));
      expect(adapter.requests.length, 1);
      expect(await cache.cached('/a.png', 'w342'), isNull);
    });
  }

  for (final error in [
    const SocketException('fixture stream reset'),
    const HttpException('fixture truncated body'),
  ]) {
    test('传输中断后备用下载覆盖半文件并通过真实解码 ${error.runtimeType}', () async {
      final adapter = _Adapter((options) async {
        if (options.uri.host != 'image.tmdb.org') return image();
        Stream<Uint8List> interrupted() async* {
          yield Uint8List.fromList([9, 9, 9]);
          throw error;
        }

        return ResponseBody(interrupted(), 200);
      });
      final cache = cacheFor(adapter);
      final file = await cache.get('/a.png');
      expect(await file.readAsBytes(), bytes);
      expect(adapter.requests.length, 2);
      expect(
        temp.listSync().where((f) => f.path.endsWith('.partial')),
        isEmpty,
      );
    });
  }

  test('备用返回损坏图片不提升缓存也不记为可用入口', () async {
    var corrupt = true;
    final adapter = _Adapter((options) async {
      if (options.uri.host == 'image.tmdb.org') {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      }
      return corrupt
          ? ResponseBody(Stream.value(Uint8List.fromList([1, 2, 3])), 200)
          : image();
    });
    final cache = cacheFor(adapter);
    await expectLater(cache.get('/a.png'), throwsA(code('invalidImage')));
    expect(await cache.cached('/a.png', 'w342'), isNull);
    expect(temp.listSync().where((f) => f.path.endsWith('.partial')), isEmpty);
    corrupt = false;
    await cache.get('/a.png');
    expect(adapter.requests.map((r) => r.uri.host), [
      'image.tmdb.org',
      'tmdb-image-prod.b-cdn.net',
      'image.tmdb.org',
      'tmdb-image-prod.b-cdn.net',
    ]);
  });

  for (final declared in [false, true]) {
    test('备用图片${declared ? '声明' : '流式'}超出上限仍拒绝并保留原缓存', () async {
      final valid = File(
        p.join(
          temp.path,
          '${FilmCatalogImageCache.cacheKey('/keep.png', 'w342')}.img',
        ),
      );
      await valid.writeAsBytes(bytes);
      final adapter = _Adapter((options) async {
        if (options.uri.host == 'image.tmdb.org') {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
          );
        }
        return ResponseBody(
          Stream.value(Uint8List.fromList([1, 2, 3])),
          200,
          headers: {
            if (declared) 'content-length': ['3'],
          },
        );
      });
      final cache = cacheFor(adapter, maxBytes: 2);
      await expectLater(
        cache.get('/large.png'),
        throwsA(code('imageTooLarge')),
      );
      expect(adapter.requests.length, 2);
      expect(await valid.readAsBytes(), bytes);
      expect(await cache.cached('/large.png', 'w342'), isNull);
      expect(
        temp.listSync().where((f) => f.path.endsWith('.partial')),
        isEmpty,
      );
    });
  }

  for (final type in [
    DioExceptionType.badCertificate,
    DioExceptionType.unknown,
  ]) {
    test('证书拒绝和其他程序错误不切换图片入口 $type', () async {
      final adapter = _Adapter((options) async {
        throw DioException(
          requestOptions: options,
          type: type,
          error: StateError('fixture'),
        );
      });
      final cache = cacheFor(adapter);
      await expectLater(cache.get('/a.png'), throwsA(code('imageFailed')));
      expect(adapter.requests.length, 1);
    });
  }

  test('关闭时取消当前图片请求，不发起备用请求', () async {
    late FilmCatalogImageCache cache;
    final adapter = _Adapter((options) async {
      cache.close();
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
      );
    });
    cache = cacheFor(adapter);
    await expectLater(cache.get('/a.png'), throwsA(code('imageFailed')));
    expect(adapter.requests.length, 1);
  });

  test('同一图片并发请求共享包含入口切换的下载', () async {
    final adapter = _Adapter((options) async {
      if (options.uri.host == 'image.tmdb.org') {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      }
      return image();
    });
    final cache = cacheFor(adapter);
    final files = await Future.wait([cache.get('/a.png'), cache.get('/a.png')]);
    expect(files.first.path, files.last.path);
    expect(adapter.requests.length, 2);
  });
}

class _Metadata extends TmdbMetadataService {
  @override
  Future<Map<String, dynamic>> configuration({bool refresh = false}) async => {
    'images': {
      'secure_base_url': 'https://image.tmdb.org/t/p/',
      'poster_sizes': ['w342', 'w500', 'original'],
      'backdrop_sizes': ['w780', 'original'],
      'still_sizes': ['w300', 'original'],
    },
  };
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final Future<ResponseBody> Function(RequestOptions) respond;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}
