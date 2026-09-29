import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/global_search_index.dart';
import 'package:streampath/data/models/media_directory_entry.dart';
import 'package:streampath/data/models/web_dav_file.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('全目录索引包含文件夹和文件，失败刷新保留旧版', () async {
    final temp = await Directory.systemTemp.createTemp('streampath_search_');
    final index = await GlobalSearchIndex.open(p.join(temp.path, 'search.db'));
    addTearDown(() async {
      await index.close();
      await temp.delete(recursive: true);
    });
    Future<List<MediaDirectoryEntry>> list(String path) async => switch (path) {
      '' => const [
        WebDavFile(name: 'Series', href: '/Series/', isDirectory: true),
      ],
      'Series' => const [
        WebDavFile(
          name: 'Episode.mkv',
          href: '/Series/Episode.mkv',
          isDirectory: false,
        ),
      ],
      _ => const [],
    };
    await index.indexSource(sourceId: 'source-a', list: list);
    expect((await index.search('series')).single.isDirectory, isTrue);
    expect((await index.search('episode')).single.parentPath, 'Series');
    expect((await index.status('source-a'))?.entryCount, 2);

    await expectLater(
      index.indexSource(
        sourceId: 'source-a',
        list: (path) async => throw const FileSystemException('offline'),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect((await index.search('episode')).single.name, 'Episode.mkv');
    expect((await index.status('source-a'))?.entryCount, 2);
    await index.removeSource('source-a');
    expect(await index.search('episode'), isEmpty);
  });

  test('移除挂载时正在建立的索引不能重新写回', () async {
    final temp = await Directory.systemTemp.createTemp(
      'streampath_search_remove_',
    );
    final index = await GlobalSearchIndex.open(p.join(temp.path, 'search.db'));
    addTearDown(() async {
      await index.close();
      await temp.delete(recursive: true);
    });
    final pending = Completer<List<MediaDirectoryEntry>>();
    final build = index.indexSource(
      sourceId: 'removed',
      list: (_) => pending.future,
    );
    await index.removeSource('removed');
    pending.complete(const [
      WebDavFile(name: 'stale.mkv', href: '/stale.mkv', isDirectory: false),
    ]);
    await expectLater(build, throwsA(isA<StateError>()));
    expect(await index.search('stale'), isEmpty);
  });
}
