import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_directory_entry.dart';
import 'package:streampath/data/models/special_playlist_mode.dart';
import 'package:streampath/domain/services/local_media_source.dart';
import 'package:streampath/domain/services/special_video_playlist_collector.dart';

void main() {
  late Directory directory;
  late LocalMediaSource source;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('streampath_specials_');
    final root = await LocalRootConfig.fromDirectory(
      path: directory.path,
      rootId: 'specials-test',
    );
    source = LocalMediaSource(root);
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  void addVideo(String relativePath) {
    final file = File(p.joinAll([directory.path, ...relativePath.split('/')]));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync([1]);
  }

  test('识别模糊特典名并排除普通目录和英文误命中', () {
    expect(
      SpecialVideoPlaylistCollector.isSpecialName('作品名 [Extras] 01'),
      isTrue,
    );
    expect(SpecialVideoPlaylistCollector.isSpecialName('第1季 番外篇'), isTrue);
    expect(
      SpecialVideoPlaylistCollector.isSpecialName('Behind The Scenes'),
      isTrue,
    );
    expect(SpecialVideoPlaylistCollector.isSpecialName('Season 00'), isTrue);
    expect(SpecialVideoPlaylistCollector.isSpecialName('SPs'), isTrue);
    expect(SpecialVideoPlaylistCollector.isSpecialName('ノンクレジットOP'), isTrue);
    expect(
      SpecialVideoPlaylistCollector.isSpecialName('Extraordinary'),
      isFalse,
    );
    expect(SpecialVideoPlaylistCollector.isSpecialName('Season 01'), isFalse);
    expect(SpecialVideoPlaylistCollector.isOvaName('作品 OAD2'), isTrue);
    expect(SpecialVideoPlaylistCollector.isOvaName('OVAs'), isTrue);
    expect(SpecialVideoPlaylistCollector.isOvaName('ONA'), isFalse);
  });

  test('仅 OVA 穿过容器目录并识别 OVA 目录与文件', () async {
    addVideo('Show/E01.mkv');
    addVideo('Show/Extras/Disc1/OVA/10.mkv');
    addVideo('Show/Extras/Disc1/OVA/2.mkv');
    addVideo('Show/Extras/Disc1/OVA-note.mkv');
    addVideo('Show/Extras/Disc1/Trailer.mkv');
    addVideo('Show/Season 01/OVA03.mkv');
    addVideo('Show/Extraordinary/OVA04.mkv');
    final root = await source.fetchDirectory('Show');

    final scan = await const SpecialVideoPlaylistCollector().collect(
      source: source,
      rootPath: 'Show',
      rootEntries: root,
      mode: SpecialPlaylistMode.ovaOnly,
    );

    expect(scan.incomplete, isFalse);
    expect(scan.items.map((item) => item.entry.name), [
      '2.mkv',
      '10.mkv',
      'OVA-note.mkv',
    ]);
    expect(scan.items.first.parentPath, 'Show/Extras/Disc1/OVA');
    expect(scan.items.first.path, 'Show/Extras/Disc1/OVA/2.mkv');
    expect(
      scan.items.first.siblings.any((item) => item.name == '10.mkv'),
      isTrue,
    );
  });

  test('全部特典包含其他特典视频，关闭时不扫描', () async {
    addVideo('Show/Extras/Trailer.mkv');
    addVideo('Show/番外篇/OVA.mkv');
    addVideo('Show/Season 01/E02.mkv');
    final root = await source.fetchDirectory('Show');
    const collector = SpecialVideoPlaylistCollector();

    final all = await collector.collect(
      source: source,
      rootPath: 'Show',
      rootEntries: root,
      mode: SpecialPlaylistMode.all,
    );
    final off = await collector.collect(
      source: source,
      rootPath: 'Show',
      rootEntries: root,
      mode: SpecialPlaylistMode.off,
    );

    expect(all.items.map((item) => item.entry.name), [
      'OVA.mkv',
      'Trailer.mkv',
    ]);
    expect(off.items, isEmpty);
  });

  test('子级与同级特典可分别或同时扫描', () async {
    addVideo('Show/1.《凉宫春日的忧郁》/E01.mkv');
    addVideo('Show/1.《凉宫春日的忧郁》/Extras/OVA01.mkv');
    addVideo('Show/0.《Specials》/Disc1/OVA02.mkv');
    addVideo('Show/0.《Specials》/Disc1/Trailer.mkv');
    addVideo('Show/2.Regular/OVA03.mkv');
    const rootPath = 'Show/1.《凉宫春日的忧郁》';
    final root = await source.fetchDirectory(rootPath);
    const collector = SpecialVideoPlaylistCollector();

    Future<List<String>> scan({
      required bool child,
      required bool sibling,
    }) async {
      final result = await collector.collect(
        source: source,
        rootPath: rootPath,
        rootEntries: root,
        mode: SpecialPlaylistMode.all,
        scanChildFolders: child,
        scanSiblingFolders: sibling,
      );
      expect(result.incomplete, isFalse);
      return result.items.map((item) => item.path).toList();
    }

    expect(await scan(child: true, sibling: false), [
      '$rootPath/Extras/OVA01.mkv',
    ]);
    expect(await scan(child: false, sibling: true), [
      'Show/0.《Specials》/Disc1/OVA02.mkv',
      'Show/0.《Specials》/Disc1/Trailer.mkv',
    ]);
    expect(await scan(child: true, sibling: true), [
      '$rootPath/Extras/OVA01.mkv',
      'Show/0.《Specials》/Disc1/OVA02.mkv',
      'Show/0.《Specials》/Disc1/Trailer.mkv',
    ]);
    expect(await scan(child: false, sibling: false), isEmpty);

    final ovaOnly = await collector.collect(
      source: source,
      rootPath: rootPath,
      rootEntries: root,
      mode: SpecialPlaylistMode.ovaOnly,
      scanChildFolders: false,
      scanSiblingFolders: true,
    );
    expect(ovaOnly.items.map((item) => item.path), [
      'Show/0.《Specials》/Disc1/OVA02.mkv',
    ]);
    expect(ovaOnly.items.single.parentPath, 'Show/0.《Specials》/Disc1');

    final direct = await source.fetchDirectory('Show/0.《Specials》');
    final directlyEntered = await collector.collect(
      source: source,
      rootPath: 'Show/0.《Specials》',
      rootEntries: direct,
      mode: SpecialPlaylistMode.all,
      scanChildFolders: false,
      scanSiblingFolders: true,
    );
    expect(directlyEntered.items, isEmpty);
  });

  test('拒绝非直属条目并在深度边界标记不完整', () async {
    addVideo('Show/Extras/1/2/3/4/5/clip.mkv');
    final root = await source.fetchDirectory('Show');
    final fake = LocalMediaEntry(
      name: 'escape.mkv',
      relativePath: 'Show/Elsewhere/escape.mkv',
      absolutePath: p.join(directory.path, 'Show', 'Elsewhere', 'escape.mkv'),
      isDirectory: false,
    );
    expect(
      SpecialVideoPlaylistCollector.directChildPath(
        source,
        'Show/Extras',
        fake,
      ),
      isNull,
    );

    final scan = await const SpecialVideoPlaylistCollector().collect(
      source: source,
      rootPath: 'Show',
      rootEntries: root,
      mode: SpecialPlaylistMode.all,
    );
    expect(scan.items, isEmpty);
    expect(scan.incomplete, isTrue);
  });

  test('同名视频按相对路径排序，目录消失时保留已读条目', () async {
    addVideo('Show/Extras/Disc2/OVA.mkv');
    addVideo('Show/Extras/Disc1/OVA.mkv');
    addVideo('Show/番外篇/lost.mkv');
    final root = await source.fetchDirectory('Show');
    Directory(
      p.join(directory.path, 'Show', '番外篇'),
    ).deleteSync(recursive: true);

    final scan = await const SpecialVideoPlaylistCollector().collect(
      source: source,
      rootPath: 'Show',
      rootEntries: root,
      mode: SpecialPlaylistMode.ovaOnly,
    );

    expect(scan.items.map((item) => item.path), [
      'Show/Extras/Disc1/OVA.mkv',
      'Show/Extras/Disc2/OVA.mkv',
    ]);
    expect(scan.incomplete, isTrue);
  });

  test('目录数量达到上限时标记特典列表不完整', () async {
    for (var index = 0; index < 65; index++) {
      Directory(
        p.join(directory.path, 'Show', 'Extras', 'Disc$index'),
      ).createSync(recursive: true);
    }
    final root = await source.fetchDirectory('Show');

    final scan = await const SpecialVideoPlaylistCollector().collect(
      source: source,
      rootPath: 'Show',
      rootEntries: root,
      mode: SpecialPlaylistMode.all,
    );

    expect(scan.items, isEmpty);
    expect(scan.incomplete, isTrue);
  });
}
