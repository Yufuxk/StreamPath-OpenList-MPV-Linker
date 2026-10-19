import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/domain/services/media_info_probe.dart';

void main() {
  final dll =
      [
        p.absolute('build/windows/x64/mediainfo-26.05/MediaInfo.dll'),
        p.absolute('build/mediainfo-26.05/MediaInfo.dll'),
      ].firstWhere(
        (path) => File(path).existsSync(),
        orElse: () => 'MediaInfo.dll',
      );
  final nativeAvailable = Platform.isWindows && File(dll).existsSync();
  final fixture = File('test/fixtures/film_probe.mp4');
  final missingRuntime = nativeAvailable
      ? false
      : 'Run the Windows build to download the fixed MediaInfo SDK';
  test('真实 DLL Buffer API 解析自生成 MP4 的视频、音轨、体积和时长', () async {
    final result = await MediaInfoProbe(
      libraryPath: dll,
    ).probe(fixture.absolute.path);
    expect(result['fileSize'], await fixture.length());
    expect(result['duration'], closeTo(1, .1));
    expect((result['video'] as List).single, containsPair('width', 160));
    expect((result['video'] as List).single, containsPair('height', 90));
    expect((result['audio'] as List).single, containsPair('sampleRate', 48000));
    expect(result['readBytes'] as int, lessThanOrEqualTo(8 * 1024 * 1024));
  }, skip: missingRuntime);

  test('远程只读取严格 Range；字节上限和请求上限生效', () async {
    final bytes = await fixture.readAsBytes();
    final ranges = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final header = request.headers.value(HttpHeaders.rangeHeader)!;
      ranges.add(header);
      final parts = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(header)!;
      final start = int.parse(parts[1]!);
      final end = int.parse(parts[2]!).clamp(0, bytes.length - 1);
      request.response.statusCode = 206;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${bytes.length}',
      );
      request.response.add(bytes.sublist(start, end + 1));
      await request.response.close();
    });
    final result = await MediaInfoProbe(
      libraryPath: dll,
      maxBytes: 16,
      maxRequests: 1,
    ).probe('http://127.0.0.1:${server.port}/fixture');
    expect(ranges, ['bytes=0-15']);
    expect(result['readBytes'], 16);
    expect(result['requests'], 1);
    expect(result['state'], 'partial');
  }, skip: missingRuntime);

  for (final status in [200, 302, 206, 429]) {
    test('拒绝完整响应、重定向和错误 Content-Range $status', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.statusCode = status;
        request.response.headers.set(HttpHeaders.locationHeader, '/other');
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 1-2/3',
        );
        await request.response.close();
      });
      await expectLater(
        MediaInfoProbe(
          libraryPath: dll,
        ).probe('http://127.0.0.1:${server.port}/fixture'),
        throwsA(
          isA<FilmCatalogException>().having(
            (e) => e.code,
            'code',
            'probeRangeUnsupported',
          ),
        ),
      );
      expect(requests, 1);
    }, skip: missingRuntime);
  }

  for (final failure in ['validator', 'size', 'oversized', 'truncated']) {
    test('Range 拒绝来源变化或异常响应体 $failure', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final free = Uint8List(256 * 1024);
      ByteData.sublistView(free).setUint32(0, 1024 * 1024, Endian.big);
      free.setAll(4, 'free'.codeUnits);
      var requests = 0;
      server.listen((request) async {
        requests++;
        final start = int.parse(
          RegExp(
            r'bytes=(\d+)-',
          ).firstMatch(request.headers.value(HttpHeaders.rangeHeader)!)![1]!,
        );
        final size =
            4 * 1024 * 1024 + (failure == 'size' && requests > 1 ? 1 : 0);
        request.response.statusCode = 206;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${start + free.length - 1}/$size',
        );
        request.response.headers.set(
          HttpHeaders.etagHeader,
          failure == 'validator' && requests > 1 ? '"changed"' : '"original"',
        );
        if (requests > 1) {
          expect(
            request.headers.value(HttpHeaders.ifRangeHeader),
            '"original"',
          );
        }
        request.response.add(
          failure == 'truncated' ? free.sublist(0, free.length - 1) : free,
        );
        if (failure == 'oversized') request.response.add([0]);
        await request.response.close();
      });
      await expectLater(
        MediaInfoProbe(
          libraryPath: dll,
        ).probe('http://127.0.0.1:${server.port}/fixture'),
        throwsA(
          isA<FilmCatalogException>().having(
            (e) => e.code,
            'code',
            failure == 'validator' || failure == 'size'
                ? 'probeSourceChanged'
                : failure == 'oversized'
                ? 'probeRangeUnsupported'
                : 'probeFailed',
          ),
        ),
      );
      expect(requests, failure == 'validator' || failure == 'size' ? 2 : 1);
    }, skip: missingRuntime);
  }

  test('默认连续 Range 无固定等待且保持串行、请求和字节预算', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final times = <DateTime>[];
    var active = 0, peak = 0;
    final free = Uint8List(256 * 1024);
    ByteData.sublistView(free).setUint32(0, 1024 * 1024, Endian.big);
    free.setAll(4, 'free'.codeUnits);
    server.listen((request) async {
      active++;
      if (active > peak) peak = active;
      times.add(DateTime.now());
      final start = int.parse(
        RegExp(
          r'bytes=(\d+)-',
        ).firstMatch(request.headers.value(HttpHeaders.rangeHeader)!)![1]!,
      );
      request.response.statusCode = 206;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${start + free.length - 1}/${4 * 1024 * 1024}',
      );
      request.response.add(free);
      await request.response.close();
      active--;
    });
    final result = await MediaInfoProbe(
      libraryPath: dll,
      maxRequests: 3,
      maxBytes: 8 * 1024 * 1024,
    ).probe('http://127.0.0.1:${server.port}/fixture');
    expect(times, hasLength(3));
    expect(
      times.last.difference(times.first),
      lessThan(const Duration(seconds: 1)),
    );
    expect(peak, 1);
    expect(result['requests'], 3);
    expect(result['readBytes'], 3 * free.length);
    expect(result['state'], 'partial');
  }, skip: missingRuntime);

  test('整体超时中断等待响应的 Range', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final entered = Completer<void>();
    server.listen((request) => entered.complete());
    final watch = Stopwatch()..start();
    await expectLater(
      MediaInfoProbe(
        libraryPath: dll,
        timeout: const Duration(milliseconds: 150),
      ).probe('http://127.0.0.1:${server.port}/fixture'),
      throwsA(
        isA<FilmCatalogException>().having(
          (e) => e.code,
          'code',
          'probeTimeout',
        ),
      ),
    );
    expect(entered.isCompleted, isTrue);
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  }, skip: missingRuntime);

  test('取消中断正在等待响应的 Range', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final entered = Completer<void>();
    server.listen((request) => entered.complete());
    final probe = MediaInfoProbe(libraryPath: dll);
    final pending = expectLater(
      probe.probe('http://127.0.0.1:${server.port}/fixture'),
      throwsA(
        isA<FilmCatalogException>().having((e) => e.code, 'code', 'cancelled'),
      ),
    );
    await entered.future;
    await probe.cancel();
    await pending;
  }, skip: missingRuntime);

  test('跨请求间隔受限，取消会立即中断等待', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final times = <DateTime>[];
    final read = Completer<void>();
    final free = Uint8List(256 * 1024);
    ByteData.sublistView(free).setUint32(0, 1024 * 1024, Endian.big);
    free.setAll(4, 'free'.codeUnits);
    server.listen((request) async {
      times.add(DateTime.now());
      final start = int.parse(
        RegExp(
          r'bytes=(\d+)-',
        ).firstMatch(request.headers.value(HttpHeaders.rangeHeader)!)![1]!,
      );
      request.response.statusCode = 206;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${start + free.length - 1}/${4 * 1024 * 1024}',
      );
      request.response.add(free);
      await request.response.close();
      if (!read.isCompleted) read.complete();
    });
    final probe = MediaInfoProbe(
      libraryPath: dll,
      remoteInterval: const Duration(seconds: 30),
    );
    final pending = probe.probe('http://127.0.0.1:${server.port}/fixture');
    final cancelled = expectLater(
      pending,
      throwsA(
        isA<FilmCatalogException>().having((e) => e.code, 'code', 'cancelled'),
      ),
    );
    await read.future;
    await Future<void>.delayed(const Duration(milliseconds: 40));
    final stopwatch = Stopwatch()..start();
    await probe.cancel();
    await cancelled;
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    expect(times, hasLength(1));
  }, skip: missingRuntime);

  test('播放器参数保留物理分辨率，PQ 不冒充 HDR10，外部音轨不写入文件参数', () {
    final info = technicalInfoFromMpv({
      'video': {'w': 1920, 'h': 1080, 'gamma': 'pq'},
      'tracks': [
        {'type': 'video', 'codec': 'hevc', 'demux-w': 3840, 'demux-h': 2160},
        {'type': 'audio', 'codec': 'flac', 'external': true},
        {'type': 'audio', 'codec': 'aac', 'demux-channel-count': 2},
      ],
    });
    expect((info['video'] as List).single, containsPair('width', 3840));
    expect((info['video'] as List).single, containsPair('hdr', 'HDR (PQ)'));
    expect(info['audio'], hasLength(1));
  });

  test('MediaInfo 缺少有效 OverallBitRate 时仅补充整体平均码率', () {
    for (final bitrate in [null, '0', '-1', 'NaN', 'Infinity', 'invalid']) {
      final info = technicalInfoFromMediaInfo({
        'media': {
          'track': [
            {'@type': 'General', 'Duration': '100', 'OverallBitRate': bitrate},
            {'@type': 'Video', 'BitRate': '8000000'},
          ],
        },
      }, fileSizeBytes: 125000000);
      expect(info['bitrate'], 10000000, reason: '$bitrate');
      expect((info['video'] as List).single['bitrate'], 8000000);
    }
    final info = technicalInfoFromMediaInfo({
      'media': {
        'track': [
          {'@type': 'General', 'Duration': '100', 'OverallBitRate': '9000000'},
        ],
      },
    }, fileSizeBytes: 125000000);
    expect(info['bitrate'], 9000000);
  });

  test('缺失、异常数据、分辨率、官方片长与光盘不生成整体码率', () {
    for (final duration in [null, 0, -1, double.nan, double.infinity, 1e-320]) {
      expect(
        technicalOverallBitrate({
          'fileSize': 125000000,
          'duration': duration,
          'runtime': 100,
          'video': [
            {'width': 3840, 'height': 2160},
          ],
        }),
        isNull,
        reason: '$duration',
      );
    }
    for (final size in [null, 0, -1]) {
      expect(
        technicalOverallBitrate({'fileSize': size, 'duration': 100}),
        isNull,
      );
    }
    expect(
      technicalOverallBitrate({
        'fileSize': 125000000,
        'duration': 100,
      }, isDisc: true),
      isNull,
    );
    expect(
      technicalOverallBitrate({
        'fileSize': 125000000,
        'duration': 100,
        'bitrate': 9000000,
      }, isDisc: true),
      9000000,
    );
    final info = technicalInfoFromMediaInfo({
      'media': {
        'track': [
          {'@type': 'General', 'Duration': 'invalid'},
          {'@type': 'Video', 'Width': '3840', 'Height': '2160'},
        ],
      },
    }, fileSizeBytes: 125000000);
    expect(info['bitrate'], isNull);
  });
}
