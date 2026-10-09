import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_connection.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/domain/services/native_storage_reader.dart';
import 'package:streampath/domain/services/native_storage_source.dart';
import 'package:streampath/domain/services/storage_range_bridge.dart';

void main() {
  test(
    'range bridge validates token, subtree and ranges without preloading media',
    () async {
      final reader = _Reader();
      final bridge = await StorageRangeBridge.open(reader);
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await bridge.close();
      });
      final request = await client.getUrl(Uri.parse(bridge.url('影片.mkv')));
      request.headers.set('Range', 'bytes=1234567-1234599');
      final response = await request.close();
      expect(response.statusCode, 206);
      final bytes = await response.fold(<int>[], (a, b) => a..addAll(b));
      expect(bytes, reader.bytes.sublist(1234567, 1234600));
      expect(reader.reads, [(1234567, 33)]);
      final suffix = await client.getUrl(Uri.parse(bridge.url('影片.mkv')));
      suffix.headers.set('Range', 'bytes=-5');
      final tail = await suffix.close();
      expect(
        await tail.fold(<int>[], (a, b) => a..addAll(b)),
        reader.bytes.sublist(reader.bytes.length - 5),
      );
      final forbidden = await client.getUrl(
        Uri.parse('${bridge.baseUrl}../secret'),
      );
      expect((await forbidden.close()).statusCode, 404);
      final invalid = await client.getUrl(Uri.parse(bridge.url('影片.mkv')));
      invalid.headers.set('Range', 'bytes=9999999999-');
      expect((await invalid.close()).statusCode, 416);
      final listing = await client.openUrl(
        'PROPFIND',
        Uri.parse(bridge.baseUrl),
      );
      listing.headers.set('Depth', '1');
      final xml = await (await listing.close()).transform(utf8.decoder).join();
      expect(xml, contains('影片.mkv'));
      expect(
        xml,
        contains(
          '<d:getcontentlength>${reader.bytes.length}</d:getcontentlength>',
        ),
      );
      expect(reader.stats, 3);
      expect(reader.reads.length, 2);
    },
  );
  for (final mode in ['mlsd', 'list']) {
    test(
      'native FTP $mode preserves metadata, seeks and rejects unsafe writeback',
      () async {
        final python = Platform.environment['PHASE5_PYTHON']!;
        final root = await Directory.systemTemp.createTemp('sp_native_ftp_');
        final bytes = Uint8List.fromList(
          List.generate(2 * 1024 * 1024 + 7, (i) => i % 251),
        );
        await File(p.join(root.path, '测试影片.mkv')).writeAsBytes(bytes);
        await File(
          p.join(root.path, 'movie.nfo'),
        ).writeAsString('preserved bytes');
        final nested = await Directory(
          p.join(root.path, '目录 with spaces'),
        ).create();
        await File(
          p.join(nested.path, ' 影片 01.mkv'),
        ).writeAsBytes([11, 22, 33]);
        await File(p.join(root.path, 'empty.bin')).writeAsBytes([]);
        final process = await Process.start(python, [
          'test/support/storage_ftp_fixture.py',
          root.path,
          p.absolute('build/phase5-test-deps'),
          mode,
        ]);
        addTearDown(() async {
          process.kill();
          await process.exitCode;
          await root.delete(recursive: true);
        });
        process.stderr.drain<void>();
        final message = await process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 10));
        final port = (jsonDecode(message) as Map)['port'];
        final config = MediaConnection(
          id: 'ftp:fixture',
          kind: MediaSourceKind.ftp,
          name: 'Fixture',
          url: 'ftp://127.0.0.1:$port/',
          username: 'fixture',
        );
        final source = await NativeStorageSource.open(
          config,
          'fixture',
          libraryPath: p.absolute(
            'build/native_storage/Release/streampath_storage.dll',
          ),
        );
        addTearDown(source.close);
        final entries = await source.fetchCatalogDirectory('');
        expect(entries.map((e) => e.name), contains('测试影片.mkv'));
        expect(entries.first.sourceKind, MediaSourceKind.ftp);
        expect(
          entries.singleWhere((e) => e.name == '测试影片.mkv').size,
          bytes.length,
        );
        expect(
          entries.singleWhere((e) => e.name == '测试影片.mkv').modified,
          isNotNull,
        );
        expect(entries.singleWhere((e) => e.name == 'empty.bin').size, 0);
        expect(entries.singleWhere((e) => e.isDirectory).size, 0);
        final nestedEntries = await source.fetchDirectory('目录 with spaces');
        expect(nestedEntries.single.name, ' 影片 01.mkv');
        expect(nestedEntries.single.size, 3);
        expect(await source.reader.read('目录 with spaces/ 影片 01.mkv', 1, 2), [
          22,
          33,
        ]);
        final bridgeEntries = await source.service.fetchDirectory(
          '',
          forceRefresh: true,
        );
        expect(
          bridgeEntries.singleWhere((e) => e.name == '测试影片.mkv').size,
          bytes.length,
        );
        expect(
          bridgeEntries.singleWhere((e) => e.name == '测试影片.mkv').modified,
          isNotNull,
        );
        expect(
          await source.reader.read('测试影片.mkv', 1400000, 200),
          bytes.sublist(1400000, 1400200),
        );
        expect((await source.reader.stat('测试影片.mkv'))['version'], isNull);
        await expectLater(
          source.createMissingFile('new.nfo', Uint8List(2)),
          throwsA(isA<FilmCatalogException>()),
        );
        expect(
          await File(p.join(root.path, 'movie.nfo')).readAsString(),
          'preserved bytes',
        );
        final writable = await NativeStorageSource.open(
          MediaConnection.fromJson({...config.toJson(), 'writeBack': true}),
          'fixture',
          libraryPath: p.absolute(
            'build/native_storage/Release/streampath_storage.dll',
          ),
        );
        try {
          expect(writable.config.canWrite, isFalse);
          for (final path in ['movie.nfo', 'new.nfo']) {
            await expectLater(
              writable.createMissingFile(path, Uint8List.fromList([1, 2, 3])),
              throwsA(
                isA<FilmCatalogException>().having(
                  (e) => e.code,
                  'code',
                  'sourceCreateUnsupported',
                ),
              ),
            );
          }
          await expectLater(
            writable.reader.createFile(
              'new.nfo',
              Uint8List.fromList([4, 5, 6]),
            ),
            throwsA(
              isA<FilmCatalogException>().having(
                (e) => e.code,
                'code',
                'sourceCreateUnsupported',
              ),
            ),
          );
          expect(
            await File(p.join(root.path, 'movie.nfo')).readAsString(),
            'preserved bytes',
          );
          expect(await File(p.join(root.path, 'new.nfo')).exists(), isFalse);
        } finally {
          await writable.close();
        }
      },
      skip: Platform.environment['PHASE5_PYTHON'] == null,
    );
  }
  test(
    'FTP permission denial does not fall back to LIST',
    () async {
      final root = await Directory.systemTemp.createTemp('sp_ftp_denied_');
      final process =
          await Process.start(Platform.environment['PHASE5_PYTHON']!, [
            'test/support/storage_ftp_fixture.py',
            root.path,
            p.absolute('build/phase5-test-deps'),
            'denied',
          ]);
      addTearDown(() async {
        process.kill();
        await process.exitCode;
        await root.delete(recursive: true);
      });
      process.stderr.drain<void>();
      final message = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      final port = (jsonDecode(message) as Map)['port'];
      final source = await NativeStorageSource.open(
        MediaConnection(
          id: 'ftp:denied',
          kind: MediaSourceKind.ftp,
          name: 'Denied',
          url: 'ftp://127.0.0.1:$port/',
          username: 'fixture',
        ),
        'fixture',
        libraryPath: p.absolute(
          'build/native_storage/Release/streampath_storage.dll',
        ),
      );
      addTearDown(source.close);
      await expectLater(
        source.fetchDirectory(''),
        throwsA(
          isA<FilmCatalogException>().having(
            (e) => e.code,
            'code',
            'sourceReadFailed',
          ),
        ),
      );
    },
    skip: Platform.environment['PHASE5_PYTHON'] == null,
  );
  for (final mode in ['wrong-password', 'no-rest']) {
    test(
      'FTP $mode reports the correct connection capability error',
      () async {
        final root = await Directory.systemTemp.createTemp('sp_ftp_errors_');
        await File(
          p.join(root.path, 'probe.bin'),
        ).writeAsBytes(List.generate(1024, (i) => i % 251));
        final process =
            await Process.start(Platform.environment['PHASE5_PYTHON']!, [
              'test/support/storage_ftp_fixture.py',
              root.path,
              p.absolute('build/phase5-test-deps'),
              mode,
            ]);
        addTearDown(() async {
          process.kill();
          await process.exitCode;
          await root.delete(recursive: true);
        });
        process.stderr.drain<void>();
        final message = await process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first;
        final port = (jsonDecode(message) as Map)['port'];
        final source = await NativeStorageSource.open(
          MediaConnection(
            id: 'ftp:errors',
            kind: MediaSourceKind.ftp,
            name: 'Fixture',
            url: 'ftp://127.0.0.1:$port/',
            username: 'fixture',
          ),
          mode == 'wrong-password' ? 'incorrect' : 'fixture',
          libraryPath: p.absolute(
            'build/native_storage/Release/streampath_storage.dll',
          ),
        );
        addTearDown(source.close);
        await expectLater(
          mode == 'wrong-password'
              ? source.fetchDirectory('')
              : source.reader.read('probe.bin', 100, 10),
          throwsA(
            isA<FilmCatalogException>().having(
              (e) => e.code,
              'code',
              mode == 'wrong-password'
                  ? 'sourceConnectionFailed'
                  : 'sourceRangeUnsupported',
            ),
          ),
        );
      },
      skip: Platform.environment['PHASE5_PYTHON'] == null,
    );
  }
}

class _Reader implements StorageFileReader {
  final bytes = Uint8List.fromList(
    List.generate(2 * 1024 * 1024, (i) => i % 251),
  );
  final reads = <(int, int)>[];
  int stats = 0;
  @override
  Future<List<Map<String, dynamic>>> list(String path) async => [
    {'name': '影片.mkv', 'directory': false, 'size': bytes.length},
  ];
  @override
  Future<Map<String, dynamic>> stat(String path) async {
    stats++;
    return {'size': bytes.length, 'directory': false, 'version': 'v1'};
  }

  @override
  Future<Uint8List> read(String path, int offset, int count) async {
    reads.add((offset, count));
    return bytes.sublist(offset, offset + count);
  }

  @override
  Future<void> createFile(String path, Uint8List bytes) async =>
      throw StateError('Unexpected write');
  @override
  void cancelCurrent() {}
  @override
  Future<void> close() async {}
}
