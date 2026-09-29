import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/data/remote/webdav_client.dart';
import 'package:streampath/domain/services/local_media_source.dart';
import 'package:streampath/domain/services/season_video_playlist_collector.dart';
import 'package:streampath/domain/services/webdav_media_source_adapter.dart';
import 'package:streampath/domain/services/webdav_service.dart';

class _SeasonWebDav extends WebDAVService {
  _SeasonWebDav()
    : super(
        client: WebDavClient(baseUrl: 'https://example.test/dav'),
        profileId: 'season-profile',
      );

  final directories = <String, List<WebDavFile>>{};
  final requested = <String>[];

  @override
  Future<List<WebDavFile>> fetchDirectory(
    String path, {
    bool forceRefresh = false,
  }) async {
    requested.add(path);
    return directories[path] ?? [];
  }
}

void main() {
  late Directory directory;
  late LocalMediaSource source;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('streampath_seasons_');
    final root = await LocalRootConfig.fromDirectory(
      path: directory.path,
      rootId: 'season-test',
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

  test('视频名确认目录季号，排除 Specials 并选择连续季', () async {
    addVideo('凉宫/1.《凉宫春日的忧郁》/凉宫春日的忧郁.2006.S01E01.mkv');
    addVideo('凉宫/0.《Specials》/凉宫春日的忧郁.S00E01.mkv');
    addVideo('凉宫/2.《凉宫春日的忧郁》/凉宫春日的忧郁.2006.S02E01.mkv');
    addVideo('凉宫/3.《别的剧》/别的剧.S03E01.mkv');
    final current = await source.fetchDirectory('凉宫/1.《凉宫春日的忧郁》');
    final next = await const SeasonVideoPlaylistCollector().findNext(
      source: source,
      rootPath: '凉宫/1.《凉宫春日的忧郁》',
      rootEntries: current,
      allowGap: false,
    );
    expect(next?.season, 2);
    expect(next?.path, '凉宫/2.《凉宫春日的忧郁》');
  });

  test('缺失第二季时默认不跳，开启后接续第三季', () async {
    addVideo('剧集/1.《寒蝉鸣泣之时》/寒蝉鸣泣之时.S01E01.mkv');
    addVideo('剧集/3.《寒蝉鸣泣之时·解》/寒蝉鸣泣之时·解.S03E01.mkv');
    final current = await source.fetchDirectory('剧集/1.《寒蝉鸣泣之时》');
    const collector = SeasonVideoPlaylistCollector();
    expect(
      await collector.findNext(
        source: source,
        rootPath: '剧集/1.《寒蝉鸣泣之时》',
        rootEntries: current,
        allowGap: false,
      ),
      isNull,
    );
    final jumped = await collector.findNext(
      source: source,
      rootPath: '剧集/1.《寒蝉鸣泣之时》',
      rootEntries: current,
      allowGap: true,
    );
    expect(jumped?.season, 3);
  });

  test('文件名与文件夹季号冲突时不切季', () async {
    addVideo('Show/1.《Show》/Show.S01E01.mkv');
    addVideo('Show/2.《Show》/Show.S03E01.mkv');
    final current = await source.fetchDirectory('Show/1.《Show》');
    final next = await const SeasonVideoPlaylistCollector().findNext(
      source: source,
      rootPath: 'Show/1.《Show》',
      rootEntries: current,
      allowGap: true,
    );
    expect(next, isNull);
  });

  test('纯数字季目录依靠视频名辨别作品', () async {
    addVideo('作品/1/作品.S01E01.mkv');
    addVideo('作品/2/作品.S02E01.mkv');
    addVideo('作品/2.《其他作品》/其他作品.S02E01.mkv');
    final current = await source.fetchDirectory('作品/1');
    final next = await const SeasonVideoPlaylistCollector().findNext(
      source: source,
      rootPath: '作品/1',
      rootEntries: current,
      allowGap: false,
    );
    expect(next?.path, '作品/2');
  });

  test('WebDAV 仅请求父目录与匹配候选的直属目录', () async {
    final dav = _SeasonWebDav();
    final first = '1.《寒蝉鸣泣之时》';
    final second = '2.《寒蝉鸣泣之时·解》';
    final special = '0.《Specials》';
    WebDavFile folder(String name) => WebDavFile(
      name: name,
      href: '/dav/${Uri.encodeComponent(name)}/',
      isDirectory: true,
    );
    WebDavFile video(String folderName, String name) => WebDavFile(
      name: name,
      href:
          '/dav/${Uri.encodeComponent(folderName)}/${Uri.encodeComponent(name)}',
      isDirectory: false,
    );
    dav.directories[''] = [folder(first), folder(second), folder(special)];
    dav.directories[first] = [video(first, '寒蝉鸣泣之时.S01E01.mkv')];
    dav.directories[second] = [video(second, '寒蝉鸣泣之时·解.S02E01.mkv')];
    final remote = WebDavMediaSourceAdapter(dav);
    final current = await remote.fetchDirectory(first);
    final next = await const SeasonVideoPlaylistCollector().findNext(
      source: remote,
      rootPath: first,
      rootEntries: current,
      allowGap: false,
    );
    expect(next?.path, second);
    expect(dav.requested, [first, '', second]);
  });
}
