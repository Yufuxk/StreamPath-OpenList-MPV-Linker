import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_connection.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/domain/services/native_storage_source.dart';

// 只有显式提供 NFS 测试地址时访问服务器，创建只使用指定的隔离目录。
void main() {
  final env = Platform.environment;
  final library =
      env['NFS_LAB_DLL'] ??
      p.absolute('build/windows/x64/runner/Release/streampath_storage.dll');
  MediaConnection connection(
    int version, {
    String path = '',
    bool write = false,
  }) {
    final root = env['NFS_LAB_V${version}_URL']!;
    return MediaConnection(
      id: 'nfs:lab-v$version',
      kind: MediaSourceKind.nfs,
      name: 'NFS lab',
      url: path.isEmpty
          ? root
          : '${root.replaceFirst(RegExp(r'/$'), '')}/${path.split('/').map(Uri.encodeComponent).join('/')}',
      nfsVersion: version,
      uid: int.parse(env['NFS_LAB_UID']!),
      gid: int.parse(env['NFS_LAB_GID']!),
      writeBack: write,
    );
  }

  Future<NativeStorageSource> open(
    int version, {
    String path = '',
    bool write = false,
  }) => NativeStorageSource.open(
    connection(version, path: path, write: write),
    '',
    libraryPath: library,
  );

  Matcher failure(String code) =>
      throwsA(isA<FilmCatalogException>().having((e) => e.code, 'code', code));

  for (final version in [3, 4]) {
    final enabled = env['NFS_LAB_V${version}_URL'] != null;
    test('live NFS v$version lists, stats and reads exact ranges', () async {
      final source = await open(version);
      final client = HttpClient();
      try {
        final rows = await source.fetchDirectory('');
        final probe = rows.singleWhere((e) => e.name == 'range-probe.bin');
        expect(probe.size, 4194304);
        expect(probe.modified, isNotNull);
        expect(rows.singleWhere((e) => e.name == '目录测试').isDirectory, isTrue);
        expect(await source.fetchDirectory('目录测试'), isNotEmpty);
        final stat = await source.reader.stat('range-probe.bin');
        expect(stat['size'], probe.size);
        expect(stat['version'], isNotEmpty);
        expect((await source.reader.stat(''))['directory'], isTrue);
        for (final (offset, count) in [
          (0, 33),
          (1400000, 257),
          (4194285, 64),
        ]) {
          final expected = List.generate(
            count.clamp(0, 4194304 - offset),
            (i) => (offset + i) % 256,
          );
          expect(
            await source.reader.read('range-probe.bin', offset, count),
            expected,
          );
          final request = await client.getUrl(
            Uri.parse(source.bridge.url('range-probe.bin')),
          );
          request.headers.set('Range', 'bytes=$offset-${offset + count - 1}');
          final response = await request.close();
          expect(response.statusCode, 206);
          expect(response.contentLength, expected.length);
          expect(
            await response.fold(<int>[], (a, b) => a..addAll(b)),
            expected,
          );
        }
        expect(
          await source.reader.read('range-probe.bin', 4194304, 7),
          isEmpty,
        );
        await expectLater(
          source.reader.stat('missing-nfs-audit.bin'),
          failure('sourceFileMissing'),
        );
        await expectLater(
          source.reader.read('missing-nfs-audit.bin', 0, 7),
          failure('sourceFileMissing'),
        );
        await expectLater(
          source.fetchDirectory('missing-nfs-audit-directory'),
          failure('sourceFileMissing'),
        );
      } finally {
        client.close(force: true);
        await source.close();
      }
    }, skip: !enabled);

    test(
      'live NFS v$version isolates simultaneous contexts and quick reopen',
      () async {
        final sources = <NativeStorageSource>[];
        try {
          sources.addAll(await Future.wait([open(version), open(version)]));
          for (var round = 0; round < 5; round++) {
            final results = await Future.wait([
              for (final source in sources)
                source.reader.read('range-probe.bin', round * 4096, 257),
            ]);
            expect(results[0], results[1]);
            expect(
              results[0],
              List.generate(257, (i) => (round * 4096 + i) % 256),
            );
          }
          await sources.removeLast().close();
          sources.add(await open(version));
          for (final source in sources) {
            expect(
              (await source.reader.read('TEST.MP4', 0, 4096)).length,
              4096,
            );
          }
        } finally {
          for (final source in sources) {
            await source.close();
          }
        }
      },
      skip: !enabled,
    );

    test('live NFS v$version accepts encoded Unicode subroots', () async {
      final source = await open(version, path: '目录测试');
      try {
        expect(await source.fetchDirectory(''), isNotEmpty);
      } finally {
        await source.close();
      }
    }, skip: !enabled);

    test(
      'live NFS v$version preserves files and creates negotiated write chunks',
      () async {
        final directory = env['NFS_LAB_FIXTURE']!;
        final source = await open(version, write: true);
        final observer = await open(version);
        try {
          final original = await source.readFile(
            '$directory/existing.nfo',
            maxBytes: 1024,
          );
          await source.createMissingFile(
            '$directory/existing.nfo',
            Uint8List.fromList([9, 9]),
          );
          await expectLater(
            source.reader.createFile(
              '$directory/existing.nfo',
              Uint8List.fromList([9, 9]),
            ),
            throwsA(isA<FilmCatalogException>()),
          );
          expect(
            await source.readFile('$directory/existing.nfo', maxBytes: 1024),
            original,
          );
          await source.createMissingFile(
            '$directory/new-v$version.nfo',
            Uint8List.fromList([4, 5, 6]),
          );
          expect(
            await source.readFile(
              '$directory/new-v$version.nfo',
              maxBytes: 1024,
            ),
            [4, 5, 6],
          );
          final large = Uint8List.fromList(
            List.generate(2 * 1024 * 1024 + 17, (i) => i % 251),
          );
          await source.createMissingFile(
            '$directory/large-v$version.bin',
            large,
          );
          expect(
            await source.readFile(
              '$directory/large-v$version.bin',
              maxBytes: large.length,
            ),
            large,
          );
          expect(
            await source.readFile('$directory/empty.bin', maxBytes: 1024),
            isEmpty,
          );
          expect(
            utf8.decode(
              await source.readFile(
                '$directory/子目录 with spaces/中文 01.txt',
                maxBytes: 1024,
              ),
            ),
            'NFS Unicode audit',
          );
          final rows = await source.fetchDirectory(
            directory,
            forceRefresh: true,
          );
          for (final name in ['relative.strm', 'nfs$version.strm']) {
            expect(
              await source.service.fetchStrmUrl(
                rows.singleWhere((e) => e.name == name),
              ),
              source.bridge.url('TEST.MP4'),
            );
          }
          await observer.fetchDirectory(directory);
          await source.reader.createFile(
            '$directory/refresh-v$version.bin',
            Uint8List.fromList([7]),
          );
          expect(
            (await observer.fetchDirectory(
              directory,
              forceRefresh: true,
            )).map((e) => e.name),
            contains('refresh-v$version.bin'),
          );
          await expectLater(
            observer.createMissingFile(
              '$directory/readonly.nfo',
              Uint8List.fromList([1]),
            ),
            failure('sourceReadOnly'),
          );
        } finally {
          await observer.close();
          await source.close();
        }
      },
      skip: !enabled || env['NFS_LAB_FIXTURE'] == null,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'live NFS v$version MPV decodes from zero and after seeking',
      () async {
        final source = await open(version);
        try {
          for (final start in [0, 60]) {
            final process = await Process.start(env['NFS_LAB_MPV']!, [
              '--no-config',
              '--vo=null',
              '--ao=null',
              '--cache=no',
              '--start=$start',
              '--length=1',
              source.bridge.url('TEST.MP4'),
            ]);
            final output = process.stdout.transform(utf8.decoder).join();
            final errors = process.stderr.transform(utf8.decoder).join();
            int code;
            try {
              code = await process.exitCode.timeout(
                const Duration(seconds: 30),
              );
            } on TimeoutException {
              process.kill();
              await process.exitCode;
              rethrow;
            }
            final log = '${await output}${await errors}'.replaceAll(
              source.bridge.baseUrl,
              'loopback/',
            );
            expect(code, 0, reason: log);
            expect(log, contains('VO: [null]'));
          }
        } finally {
          await source.close();
        }
      },
      skip: !enabled || env['NFS_LAB_MPV'] == null,
    );

    test(
      'live NFS v$version survives 120 rapid absolute and relative seeks',
      () async {
        final source = await open(version);
        try {
          final process = await Process.start(env['NFS_LAB_MPV']!, [
            '--no-config',
            '--vo=null',
            '--ao=null',
            '--cache=no',
            '--idle=no',
            '--keep-open=no',
            '--msg-level=all=warn',
            '--script=${p.absolute('test/support/storage_seek_stress.lua')}',
            source.bridge.url('TEST.MP4'),
          ]);
          final output = process.stdout.transform(utf8.decoder).join();
          final errors = process.stderr.transform(utf8.decoder).join();
          int code;
          try {
            code = await process.exitCode.timeout(const Duration(seconds: 40));
          } on TimeoutException {
            process.kill();
            await process.exitCode;
            rethrow;
          }
          final log = '${await output}${await errors}'.replaceAll(
            source.bridge.baseUrl,
            'loopback/',
          );
          expect(code, 0, reason: log);
          expect(log, contains('SEEK_STRESS_COMPLETE count=120'));
        } finally {
          await source.close();
        }
      },
      skip: !enabled || env['NFS_LAB_MPV'] == null,
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }

  for (final operation in ['list', 'stat', 'read', 'create']) {
    test(
      'live NFS cancels held $operation and closes promptly',
      () async {
        final root = Uri.parse(env['NFS_LAB_V4_URL']!);
        final proxy = await Process.start(env['NFS_LAB_PYTHON']!, [
          'test/support/nfs_proxy_fixture.py',
          root.host,
          '${root.hasPort ? root.port : 2049}',
        ]);
        final events = StreamIterator(
          proxy.stdout.transform(utf8.decoder).transform(const LineSplitter()),
        );
        final errors = proxy.stderr.transform(utf8.decoder).join();
        NativeStorageSource? source;
        try {
          expect(await events.moveNext(), isTrue);
          final port = (jsonDecode(events.current) as Map)['port'] as int;
          source = await NativeStorageSource.open(
            MediaConnection.fromJson({
              ...connection(4, write: true).toJson(),
              'url': root.replace(host: '127.0.0.1', port: port).toString(),
            }),
            '',
            libraryPath: library,
          );
          proxy.stdin.writeln('hold');
          expect(await events.moveNext(), isTrue);
          expect((jsonDecode(events.current) as Map)['event'], 'armed');
          final Future<Object?> pending = switch (operation) {
            'list' => source.reader.list(''),
            'stat' => source.reader.stat('TEST.MP4'),
            'read' => source.reader.read('TEST.MP4', 0, 4096),
            _ =>
              source.reader
                  .createFile(
                    '${env['NFS_LAB_FIXTURE']}/cancel-create.nfo',
                    Uint8List.fromList([1, 2, 3]),
                  )
                  .then<Object?>((_) => null),
          };
          final outcome = pending.then<Object?>(
            (result) => result,
            onError: (Object error) => error,
          );
          expect(await events.moveNext(), isTrue);
          expect((jsonDecode(events.current) as Map)['event'], 'held');
          await source.close().timeout(const Duration(seconds: 2));
          expect(
            await outcome,
            isA<FilmCatalogException>().having(
              (e) => e.code,
              'code',
              'cancelled',
            ),
          );
        } finally {
          proxy.stdin.writeln('release');
          await proxy.stdin.flush();
          await source?.close();
          proxy.stdin.writeln('quit');
          await proxy.stdin.close();
          await events.cancel();
          await proxy.exitCode;
          expect(await errors, isEmpty);
        }
      },
      skip:
          env['NFS_LAB_V4_URL'] == null ||
          env['NFS_LAB_PYTHON'] == null ||
          env['NFS_LAB_FIXTURE'] == null,
    );
  }
}
