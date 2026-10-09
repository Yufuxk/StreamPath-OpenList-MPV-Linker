import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/domain/services/native_storage_reader.dart';
import 'package:streampath/domain/services/storage_range_bridge.dart';

class _Reader implements StorageFileReader {
  _Reader({this.size = 512 * 1024 * 1024, this.failAt});
  final int size;
  final int? failAt;
  int reads = 0;
  final chunk = Uint8List(256 * 1024);

  @override
  Future<List<Map<String, dynamic>>> list(String path) async => [];
  @override
  Future<Map<String, dynamic>> stat(String path) async => {
    'size': size,
    'directory': false,
  };
  @override
  Future<Uint8List> read(String path, int offset, int count) async {
    reads++;
    await Future<void>.delayed(const Duration(milliseconds: 2));
    if (reads == failAt) throw const FilmCatalogException('sourceReadFailed');
    return Uint8List.sublistView(chunk, 0, count.clamp(0, chunk.length));
  }

  @override
  Future<void> createFile(String path, Uint8List bytes) =>
      throw StateError('Unexpected write');
  @override
  void cancelCurrent() {}
  @override
  Future<void> close() async {}
}

void main() {
  test('abandoned ranges release admission and stop reading', () async {
    final reader = _Reader();
    final bridge = await StorageRangeBridge.open(reader);
    addTearDown(bridge.close);
    final target = Uri.parse(bridge.url('video.mp4'));
    for (var seek = 0; seek < 16; seek++) {
      final socket = await Socket.connect(target.host, target.port);
      try {
        socket.write(
          'GET ${target.path} HTTP/1.1\r\nHost: ${target.authority}\r\n'
          'Range: bytes=${seek * 4 * 1024 * 1024}-\r\n\r\n',
        );
        await socket.flush();
        final bytes = await socket.first.timeout(const Duration(seconds: 2));
        expect(ascii.decode(bytes.take(32).toList()), contains('206'));
      } finally {
        socket.destroy();
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final reads = reader.reads;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(reader.reads, reads);
    expect(reads, lessThan(160));
  });

  test('empty GET and HEAD complete without reading', () async {
    final reader = _Reader(size: 0);
    final bridge = await StorageRangeBridge.open(reader);
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await bridge.close();
    });
    for (final method in ['GET', 'HEAD']) {
      final request = await client.openUrl(
        method,
        Uri.parse(bridge.url('empty.bin')),
      );
      final response = await request.close();
      expect(response.statusCode, 200);
      expect(response.contentLength, 0);
      expect(await response.expand((bytes) => bytes).toList(), isEmpty);
    }
    expect(reader.reads, 0);
  });

  test('first read failure returns 502 before body headers', () async {
    final reader = _Reader(failAt: 1);
    final bridge = await StorageRangeBridge.open(reader);
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await bridge.close();
    });
    final response = await (await client.getUrl(
      Uri.parse(bridge.url('bad.mp4')),
    )).close();
    expect(response.statusCode, 502);
    expect(response.contentLength, 0);
    await response.drain<void>();
  });

  test(
    'failure after body starts terminates the incomplete response',
    () async {
      final reader = _Reader(size: 1024 * 1024, failAt: 2);
      final bridge = await StorageRangeBridge.open(reader);
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await bridge.close();
      });
      final response = await (await client.getUrl(
        Uri.parse(bridge.url('interrupted.mp4')),
      )).close();
      expect(response.statusCode, 200);
      var received = 0;
      await expectLater(
        response.forEach((bytes) => received += bytes.length),
        throwsA(isA<HttpException>()),
      );
      expect(received, 256 * 1024);
      expect(reader.reads, 2);
    },
  );
}
