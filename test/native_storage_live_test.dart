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

// 显式提供服务器与凭据后运行；写入测试只使用指定测试目录。
void main() {
  final env = Platform.environment;
  final enabled = env['STORAGE_LAB_HOST'] != null;
  final library =
      env['STORAGE_LAB_DLL'] ??
      p.absolute('build/windows/x64/runner/Release/streampath_storage.dll');
  MediaConnection connection(MediaSourceKind kind, {String path = ''}) =>
      MediaConnection(
        id: '${kind.name}:lab',
        kind: kind,
        name: 'Storage lab',
        url: Uri(
          scheme: kind.name,
          host: env['STORAGE_LAB_HOST'],
          path: kind == MediaSourceKind.smb
              ? '/${env['STORAGE_LAB_SHARE'] ?? 'StreamPath'}/$path'
              : '/$path',
        ).toString(),
        username: env['STORAGE_LAB_USER']!,
        domain: env['STORAGE_LAB_DOMAIN'] ?? '',
      );

  test(
    'live FTP and SMB preserve sizes, Unicode paths and range bytes',
    () async {
      final samples = <MediaSourceKind, List<List<int>>>{};
      for (final kind in [MediaSourceKind.ftp, MediaSourceKind.smb]) {
        final source = await NativeStorageSource.open(
          connection(kind),
          env['STORAGE_LAB_PASSWORD']!,
          libraryPath: library,
        );
        try {
          final rows = await source.fetchDirectory('');
          expect(
            rows.singleWhere((e) => e.name == 'range-probe.bin').size,
            4194304,
          );
          final media = rows.singleWhere((e) => e.name == 'TEST.MP4');
          expect(media.size, greaterThan(0));
          final stat = await source.reader.stat(media.logicalPath);
          expect(media.modified, isNotNull);
          expect(
            (media.modified!.millisecondsSinceEpoch - (stat['modified'] as int))
                .abs(),
            lessThanOrEqualTo(Duration.millisecondsPerDay),
          );
          expect(
            media.size,
            (await source.reader.stat(media.logicalPath))['size'],
          );
          final bridged = await source.service.fetchDirectory(
            '',
            forceRefresh: true,
          );
          expect(
            bridged.singleWhere((e) => e.name == media.name).size,
            media.size,
          );
          final directory = rows.singleWhere((e) => e.name == '目录测试');
          expect(directory.isDirectory, isTrue);
          expect(directory.size, 0);
          final nested = await source.fetchDirectory(directory.logicalPath);
          expect(nested, isNotEmpty);
          for (final file in nested.where((e) => !e.isDirectory)) {
            expect(
              file.size,
              (await source.reader.stat(file.logicalPath))['size'],
            );
            if (file.size > 0) {
              expect(
                (await source.reader.read(file.logicalPath, 0, 1)).length,
                1,
              );
            }
          }
          samples[kind] = [];
          for (final (offset, count) in [
            (0, 33),
            (1400000, 257),
            (4194285, 19),
          ]) {
            final bytes = await source.reader.read(
              'range-probe.bin',
              offset,
              count,
            );
            expect(bytes.length, count);
            samples[kind]!.add(bytes);
            final client = HttpClient();
            try {
              final request = await client.getUrl(
                Uri.parse(source.bridge.url('range-probe.bin')),
              );
              request.headers.set(
                'Range',
                'bytes=$offset-${offset + count - 1}',
              );
              final response = await request.close();
              expect(response.statusCode, 206);
              expect(response.contentLength, count);
              expect(
                await response.fold(<int>[], (a, b) => a..addAll(b)),
                bytes,
              );
            } finally {
              client.close(force: true);
            }
          }
          await expectLater(
            source.reader.stat('missing-storage-test.bin'),
            throwsA(
              isA<FilmCatalogException>().having(
                (e) => e.code,
                'code',
                'sourceFileMissing',
              ),
            ),
          );
        } finally {
          await source.close();
        }
      }
      expect(samples[MediaSourceKind.ftp], samples[MediaSourceKind.smb]);
    },
    skip: !enabled,
  );

  for (final kind in [MediaSourceKind.ftp, MediaSourceKind.smb]) {
    test('live $kind accepts an encoded Unicode subroot URL', () async {
      final source = await NativeStorageSource.open(
        connection(kind, path: '目录测试'),
        env['STORAGE_LAB_PASSWORD']!,
        libraryPath: library,
      );
      try {
        expect(await source.fetchDirectory(''), isNotEmpty);
      } finally {
        await source.close();
      }
    }, skip: !enabled);
    test(
      'live $kind MPV decodes at zero and after seeking',
      () async {
        final source = await NativeStorageSource.open(
          connection(kind),
          env['STORAGE_LAB_PASSWORD']!,
          libraryPath: library,
        );
        try {
          for (final start in [0, 60]) {
            final process = await Process.start(env['STORAGE_LAB_MPV']!, [
              '--no-config',
              '--vo=null',
              '--ao=null',
              '--cache=no',
              '--start=$start',
              '--length=1',
              source.bridge.url('TEST.MP4'),
            ]);
            final output = process.stdout.toList();
            final errors = process.stderr.toList();
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
            final text = String.fromCharCodes([
              for (final chunk in await output) ...chunk,
              for (final chunk in await errors) ...chunk,
            ]).replaceAll(source.bridge.baseUrl, 'loopback/');
            expect(code, 0, reason: text);
            expect(text, contains('VO: [null]'));
          }
        } finally {
          await source.close();
        }
      },
      skip: !enabled || env['STORAGE_LAB_MPV'] == null,
    );
  }
  test(
    'live server preserves existing metadata and safely creates only over SMB',
    () async {
      final directory = env['STORAGE_LAB_FIXTURE']!;
      for (final kind in [MediaSourceKind.ftp, MediaSourceKind.smb]) {
        final config = MediaConnection.fromJson({
          ...connection(kind).toJson(),
          'writeBack': true,
        });
        final source = await NativeStorageSource.open(
          config,
          env['STORAGE_LAB_PASSWORD']!,
          libraryPath: library,
        );
        try {
          final existing = '$directory/existing.nfo';
          final original = await source.readFile(existing, maxBytes: 1024);
          if (kind == MediaSourceKind.ftp) {
            expect(config.canWrite, isFalse);
            for (final path in [existing, '$directory/ftp-rejected.nfo']) {
              await expectLater(
                source.createMissingFile(path, Uint8List.fromList([9, 9])),
                throwsA(
                  isA<FilmCatalogException>().having(
                    (e) => e.code,
                    'code',
                    'sourceCreateUnsupported',
                  ),
                ),
              );
              await expectLater(
                source.reader.createFile(path, Uint8List.fromList([9, 9])),
                throwsA(
                  isA<FilmCatalogException>().having(
                    (e) => e.code,
                    'code',
                    'sourceCreateUnsupported',
                  ),
                ),
              );
            }
            expect(
              (await source.fetchDirectory(
                directory,
                forceRefresh: true,
              )).map((e) => e.name),
              isNot(contains('ftp-rejected.nfo')),
            );
          } else {
            await source.createMissingFile(
              existing,
              Uint8List.fromList([9, 9]),
            );
            // 原生独占创建必须拒绝已存在的文件。
            await expectLater(
              source.reader.createFile(existing, Uint8List.fromList([9, 9])),
              throwsA(isA<FilmCatalogException>()),
            );
            await source.createMissingFile(
              '$directory/new.nfo',
              Uint8List.fromList([4, 5, 6]),
            );
            expect(
              await source.readFile('$directory/new.nfo', maxBytes: 1024),
              [4, 5, 6],
            );
          }
          expect(await source.readFile(existing, maxBytes: 1024), original);
          final rows = await source.fetchDirectory(
            directory,
            forceRefresh: true,
          );
          for (final name in ['relative.strm', '${kind.name}.strm']) {
            final target = await source.service.fetchStrmUrl(
              rows.singleWhere((e) => e.name == name),
            );
            expect(target, source.bridge.url('TEST.MP4'));
          }
          expect(
            utf8.decode(
              await source.readFile('$directory/中文 01.txt', maxBytes: 1024),
            ),
            'Unicode storage audit',
          );
        } finally {
          await source.close();
        }
      }
    },
    skip: !enabled || env['STORAGE_LAB_FIXTURE'] == null,
  );
}
