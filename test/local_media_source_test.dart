import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_directory_entry.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/domain/services/local_media_source.dart';

void main() {
  late Directory rootDirectory;
  late LocalRootConfig root;

  setUp(() async {
    rootDirectory = Directory.systemTemp.createTempSync(
      'streampath_local_source_',
    );
    root = await LocalRootConfig.fromDirectory(
      path: rootDirectory.path,
      displayName: '测试本地源',
      rootId: 'root-test',
    );
  });

  tearDown(() {
    if (rootDirectory.existsSync()) {
      rootDirectory.deleteSync(recursive: true);
    }
  });

  test('只枚举当前目录并识别本地媒体类型', () async {
    File(p.join(root.path, 'movie.MKV')).writeAsBytesSync([1, 2, 3]);
    File(p.join(root.path, 'song.flac')).writeAsBytesSync([1]);
    final nested = Directory(p.join(root.path, 'Nested'))..createSync();
    File(p.join(nested.path, 'hidden.mkv')).writeAsBytesSync([1]);
    final source = LocalMediaSource(root);

    final entries = await source.fetchDirectory('');

    expect(
      entries.map((entry) => entry.name),
      containsAll(['movie.MKV', 'song.flac', 'Nested']),
    );
    expect(entries.map((entry) => entry.name), isNot(contains('hidden.mkv')));
    expect(
      entries.singleWhere((entry) => entry.name == 'movie.MKV').isVideo,
      isTrue,
    );
    expect(
      entries.singleWhere((entry) => entry.name == 'song.flac').isAudio,
      isTrue,
    );
    expect(source.supportsRemoteSearch, isFalse);
    expect(source.descriptor.sourceId, 'local:root-test');
  });

  test('进入子目录时使用相对路径并提供返回上级条目', () async {
    final nested = Directory(p.join(root.path, 'Nested'))..createSync();
    File(p.join(nested.path, 'episode.mkv')).writeAsBytesSync([1]);
    final source = LocalMediaSource(root);

    final entries = await source.fetchDirectory('Nested');
    final parent = entries.singleWhere((entry) => entry.isSelfEntry);
    final episode = entries.singleWhere((entry) => entry.name == 'episode.mkv');

    expect(parent.relativePath, '');
    expect(episode.relativePath, 'Nested/episode.mkv');
    final target = await source.resolve(episode) as LocalMediaOpenTarget;
    expect(target.path, p.join(root.path, 'Nested', 'episode.mkv'));
  });

  test('拒绝 .. 和最终路径越过本地根目录', () async {
    final file = File(p.join(root.path, 'escape.mkv'))..writeAsBytesSync([1]);
    final outside = p.join(root.path, '..', 'outside.mkv');
    final source = LocalMediaSource(
      root,
      canonicalizer: (path) async {
        if (p.equals(path, file.path)) return p.normalize(outside);
        return p.normalize(path);
      },
    );

    await expectLater(
      source.resolve(
        LocalMediaEntry(
          name: 'bad.mkv',
          relativePath: '../bad.mkv',
          absolutePath: outside,
          isDirectory: false,
        ),
      ),
      throwsFormatException,
    );
    await expectLater(
      source.resolve(
        LocalMediaEntry(
          name: 'escape.mkv',
          relativePath: 'escape.mkv',
          absolutePath: file.path,
          isDirectory: false,
        ),
      ),
      throwsA(
        isA<StorageException>().having(
          (error) => error.message,
          'message',
          '已拒绝指向本地根目录外的路径',
        ),
      ),
    );
  });

  test('删除后的文件在最终打开时被拒绝', () async {
    final file = File(p.join(root.path, 'deleted.mkv'))..writeAsBytesSync([1]);
    final source = LocalMediaSource(root);
    final entry = (await source.fetchDirectory(
      '',
    )).singleWhere((candidate) => candidate.name == 'deleted.mkv');
    file.deleteSync();

    await expectLater(
      source.resolve(entry),
      throwsA(
        isA<StorageException>().having(
          (error) => error.message,
          'message',
          '本地文件不存在或不可访问',
        ),
      ),
    );
  });

  test('ISO 和有效 BDMV 文件夹解析为受控设备路径', () async {
    final iso = File(p.join(root.path, 'disc.iso'))..writeAsBytesSync([1]);
    final disc = Directory(p.join(root.path, 'Disc'))..createSync();
    final bdmv = Directory(p.join(disc.path, 'BDMV'))..createSync();
    File(p.join(bdmv.path, 'index.bdmv')).writeAsBytesSync([1]);
    Directory(p.join(bdmv.path, 'PLAYLIST')).createSync();
    Directory(p.join(bdmv.path, 'STREAM')).createSync();
    final source = LocalMediaSource(root);

    expect(await source.resolveDiscDevice('disc.iso'), iso.path);
    expect(await source.resolveDiscDevice('Disc'), disc.path);
    expect(await source.resolveDiscDevice('Disc/BDMV'), disc.path);
    expect(source.discRelativePath(disc.path), 'Disc');
    expect(await source.hasDiscAt('Disc'), isTrue);
  });
}
