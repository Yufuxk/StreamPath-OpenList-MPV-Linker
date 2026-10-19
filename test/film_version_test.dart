import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/film_version.dart';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/playback_history.dart';
import 'package:streampath/domain/services/film_version_resolver.dart';

FilmResource versionResource(
  int id,
  int season,
  int episode,
  String path, {
  String source = 'local:test',
  String kind = 'local',
  String? key,
  String? label,
}) => FilmResource.fromRow({
  'id': id,
  'root_id': 1,
  'source_id': source,
  'source_kind': kind,
  'media_type': 'tv',
  'root_path': 'TV',
  'display_name': 'Fixture',
  'relative_path': path,
  'path_key': path,
  'parent_path': p.posix.dirname(path),
  'name': p.posix.basename(path),
  'media_kind': 'video',
  'availability': 'present',
  'work_id': 1,
  'binding_origin': 'manual',
  'binding_version': 1,
  'season_number': season,
  'episode_number': episode,
  'episode_mapping_origin': 'manual',
  'version_key': key,
  'version_name': label,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test('v8 目录库增量升级保留偏好并生成备份', () async {
    final dir = await Directory.systemTemp.createTemp('film_versions_upgrade_');
    try {
      final path = '${dir.path}/catalog.db';
      var store = await FilmCatalogStore.open(path);
      await store.setPreference('fixture', true);
      await store.close();
      final legacy = await databaseFactoryFfi.openDatabase(path);
      await legacy.execute('DROP TABLE film_resource_versions');
      await legacy.setVersion(8);
      await legacy.close();
      store = await FilmCatalogStore.open(path);
      expect(await store.preference('fixture'), isTrue);
      final db = await databaseFactoryFfi.openDatabase(path);
      expect(await db.getVersion(), 9);
      expect(await db.query('film_resource_versions'), isEmpty);
      expect(
        dir.listSync().where((e) => e.path.contains('.before-v9-')),
        hasLength(1),
      );
      await store.close();
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('整季分组跨季与特别篇分类保持同一版本，技术属性不拆组', () {
    final rows = [
      versionResource(1, 1, 1, 'TV/Show/Season 01/Show.S01E01.1080p.AVC.mkv'),
      versionResource(2, 2, 1, 'TV/Show/Season 02/Show.S02E01.2160p.HEVC.mkv'),
      versionResource(3, 0, 1, 'TV/Show/0.Specials/SPs/E1.mkv'),
      versionResource(4, 0, 2, 'TV/Show/0.Specials/OADs/Part/E2.mkv'),
      versionResource(5, 0, 3, 'TV/Show/0.Specials/NCOP&ED/E3.mkv'),
    ];
    final index = FilmVersionIndex(rows);
    expect(index.families, hasLength(1));
    expect(index.families.single.resources, hasLength(5));
  });

  test('同目录明确标签分组，各版本缺集不补齐且逻辑集唯一', () {
    final rows = [
      for (var i = 1; i <= 3; i++)
        versionResource(i, 1, i, 'TV/Show/S01/E$i{version-A}.mkv'),
      for (var i in [1, 3])
        versionResource(i + 10, 1, i, 'TV/Show/S01/E$i{version-B}.mkv'),
    ];
    final index = FilmVersionIndex(rows);
    final b = index.families.singleWhere((f) => f.name.endsWith('B'));
    final selected = index.selected(FilmVersionSelection(defaultKey: b.key));
    expect(selected.map((r) => r.episode), [1, 3]);
    expect(index.unresolved, isEmpty);
  });

  test('数字分类目录不抢占真实季目录，正季内特别篇沿用资源包', () {
    final index = FilmVersionIndex([
      versionResource(1, 1, 1, 'TV/1.EpisodeData/Show/1.第一季/E1.mkv'),
      versionResource(2, 2, 1, 'TV/1.EpisodeData/Show/2.第二季/E1.mkv'),
      versionResource(3, 0, 1, 'TV/1.EpisodeData/Show/S04/完结篇/E1.mkv'),
    ]);
    expect(index.resourceKeys[1], index.resourceKeys[2]);
    expect(index.resourceKeys[1], index.resourceKeys[3]);
    // 特别篇采用能够确认的资源包；数字分类本身不能被当作版本标签。
    final r = versionResource(4, 0, 2, 'TV/Show/S04/Extras/E2.mkv');
    expect(
      automaticFilmVersion(r).key,
      automaticFilmVersion(versionResource(5, 4, 1, 'TV/Show/S04/E1.mkv')).key,
    );
  });

  test('来源身份隔离，目录和显示名称相同也不能混合', () {
    final index = FilmVersionIndex([
      versionResource(1, 1, 1, 'TV/Show/S01/E1.mkv'),
      versionResource(
        2,
        1,
        1,
        'TV/Show/S01/E1.mkv',
        source: 'dav',
        kind: 'webdav',
      ),
    ]);
    expect(index.families, hasLength(2));
    expect(index.unresolved, isEmpty);
  });

  test('没有明确标签的重复项待归属，不按文件顺序猜配', () {
    final index = FilmVersionIndex([
      versionResource(1, 1, 1, 'TV/Show/S01/E1.mkv'),
      versionResource(2, 1, 1, 'TV/Show/S01/E1-copy.mkv'),
      versionResource(3, 1, 2, 'TV/Show/S01/E2.mkv'),
    ]);
    expect(index.unresolved.map((r) => r.id), [1, 2]);
    expect(index.selected(index.initial()).map((r) => r.episode), [2]);
  });

  test('服务器虚拟单集目录不拆整季，明确服务器归属可以覆盖', () {
    final index = FilmVersionIndex([
      versionResource(
        1,
        1,
        1,
        'series/one/source1/source1.mkv',
        source: 'server',
        kind: 'jellyfin',
      ),
      versionResource(
        2,
        2,
        2,
        'series/two/source2/source2.mkv',
        source: 'server',
        kind: 'jellyfin',
      ),
    ]);
    expect(index.families, hasLength(1));
    final a = automaticFilmVersion(
      index.families.single.resources[0],
      sourcePath: '/media/Show/S01/E1{edition-A}.mkv',
      sourceName: '1080p',
    );
    final b = automaticFilmVersion(
      index.families.single.resources[1],
      sourcePath: '/media/Show/S02/E2{edition-A}.mkv',
      sourceName: '2160p',
    );
    expect(a.key, b.key);
  });

  test('单季覆盖与全剧重设，暂时缺少整季不自动替换选择', () {
    final index = FilmVersionIndex([
      versionResource(1, 1, 1, 'TV/A/S01/E1.mkv'),
      versionResource(2, 2, 1, 'TV/A/S02/E1.mkv'),
      versionResource(3, 1, 1, 'TV/B/S01/E1.mkv'),
    ]);
    final a = index.resourceKeys[1]!, b = index.resourceKeys[3]!;
    final whole = FilmVersionSelection(defaultKey: b);
    expect(index.selected(whole).where((r) => r.season == 2), isEmpty);
    expect(index.selected(whole.withSeason(2, a)).map((r) => r.id), [3, 2]);
    expect(FilmVersionSelection(defaultKey: a).seasons, isEmpty);
    expect(
      index.selected(FilmVersionSelection(defaultKey: 'missing')),
      isEmpty,
    );
  });

  test('默认选择优先最近版本，其次正片覆盖数量', () {
    final index = FilmVersionIndex([
      versionResource(1, 1, 1, 'TV/A/S01/E1.mkv'),
      versionResource(2, 1, 2, 'TV/A/S01/E2.mkv'),
      versionResource(3, 1, 1, 'TV/B/S01/E1.mkv'),
      for (var i = 1; i < 5; i++)
        versionResource(i + 10, 0, i, 'TV/B/Specials/E$i.mkv'),
    ]);
    expect(index.initial().defaultKey, index.resourceKeys[1]);
    expect(
      index
          .initial(recentSource: 'local:test', recentPath: 'TV/B/S01/E1.mkv')
          .defaultKey,
      index.resourceKeys[3],
    );
  });

  test('起播快照只含所选版本，在不同来源边界结束并保留下一目标', () {
    final rows = [
      versionResource(1, 1, 1, 'TV/A/S01/E1.mkv'),
      versionResource(2, 1, 3, 'TV/A/S01/E3.mkv'),
      versionResource(3, 1, 2, 'TV/B/S01/E2.mkv'),
      versionResource(
        4,
        2,
        1,
        'TV/C/S02/E1.mkv',
        source: 'dav',
        kind: 'webdav',
      ),
      versionResource(5, 3, 1, 'TV/A/S03/E1.mkv'),
    ];
    final index = FilmVersionIndex(rows);
    final context = FilmPlaybackContext(
      workId: 1,
      identity: 'tmdb:tv:1',
      selection: FilmVersionSelection(
        defaultKey: index.resourceKeys[1]!,
        seasons: {2: index.resourceKeys[4]!},
      ),
    );
    final result = selectedFilmPlayback(
      rows,
      {},
      context,
      sourceId: 'local:test',
      targetPath: rows[0].path,
      autoSeason: true,
      allowGap: false,
      insertDecimalEpisodes: false,
    );
    expect(result.items.map((i) => i.episode), [1, 3]);
    expect(result.items.every((i) => i.versions.length == 1), isTrue);
    expect(result.next?.id, 4);
    expect(
      () => selectedFilmPlayback(
        rows,
        {},
        context,
        sourceId: 'local:test',
        targetPath: rows[2].path,
        autoSeason: true,
        allowGap: false,
        insertDecimalEpisodes: false,
      ),
      throwsA(isA<ConfigException>()),
    );
    final noAuto = selectedFilmPlayback(
      rows,
      {},
      context,
      sourceId: 'local:test',
      targetPath: rows[0].path,
      autoSeason: false,
      allowGap: false,
      insertDecimalEpisodes: false,
    );
    expect(noAuto.next, isNull);
  });

  test('上下文与待切季目标往返保存，媒体稳定身份不变', () {
    final context = FilmPlaybackContext(
      workId: 1,
      identity: 'tmdb:tv:1',
      selection: FilmVersionSelection(defaultKey: 'A', seasons: {2: 'B'}),
    );
    const original = MediaLibraryItem(
      sourceId: 'local:test',
      parentPath: 'TV',
      name: 'E1.mkv',
      kind: MediaLibraryKind.video,
    );
    final item = original.withFilmVersion(context);
    expect(item.stableKey, original.stableKey);
    final history = PlaybackHistory(
      dirCrumbs: const ['TV'],
      fileName: 'E1.mkv',
      videoIndex: 0,
      updatedAt: DateTime.now(),
      filmVersionContext: context,
      filmNextItem: item,
      filmBoundaryReady: true,
      filmBoundaryPrompted: true,
    );
    final restored = PlaybackHistory.fromJson(
      jsonDecode(jsonEncode(history.toJson())) as Map<String, dynamic>,
    );
    expect(restored.filmVersionContext!.signature, context.signature);
    expect(
      restored.filmNextItem!.filmVersionContext!.signature,
      context.signature,
    );
    expect(restored.copyWith(fileName: 'E2.mkv').filmBoundaryReady, isTrue);
    expect(restored.filmBoundaryPrompted, isTrue);
    final old = PlaybackHistory.fromJson({'fileName': 'old', 'videoIndex': 0});
    expect(old.filmVersionContext, isNull);
    expect(old.filmBoundaryReady, isFalse);
  });

  test('版本偏好和手动归属落盘，重开后恢复且来源视图隔离', () async {
    final dir = await Directory.systemTemp.createTemp('film_versions_');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/catalog.db';
    var store = await FilmCatalogStore.open(path);
    final rootId = await store.addRoot(
      sourceId: 'local:test',
      kind: MediaSourceKind.local,
      path: 'TV',
      type: FilmMediaType.tv,
      name: 'Fixture',
    );
    final root = (await store.root(rootId))!;
    final generation = await store.beginScan(rootId);
    await store.stage(root, generation, [
      for (var i = 1; i <= 2; i++)
        FilmScanEntry(
          path: 'TV/Show/S01/E$i.mkv',
          parentPath: 'TV/Show/S01',
          name: 'E$i.mkv',
          mediaKind: 'video',
        ),
    ]);
    await store.commitScan(rootId, generation, cancelled: () => false);
    await store.bind(
      await store.resources(),
      const FilmWork(
        type: FilmMediaType.tv,
        tmdbId: 1,
        title: 'Show',
        originalTitle: 'Show',
        overview: '',
        language: 'en',
      ),
    );
    final resources = await store.resources();
    await store.mapEpisodes({resources[0]: (1, 1), resources[1]: (1, 2)});
    await store.assignVersion(await store.resources(), 'My edition');
    final assigned = await store.resources();
    final selection = FilmVersionSelection(
      defaultKey: assigned.first.versionKey!,
      seasons: {2: 'other'},
    );
    var watchNotifications = 0;
    void watchChanged() => watchNotifications++;
    store.watchChanges.addListener(watchChanged);
    await store.saveVersionSelection('tmdb:tv:1', selection);
    await store.saveVersionSelection(
      'tmdb:tv:1',
      FilmVersionSelection(defaultKey: 'server'),
      sourceScope: 'server',
    );
    expect(
      watchNotifications,
      0,
      reason: 'Version preferences do not change watch state',
    );
    store.watchChanges.removeListener(watchChanged);
    await store.close();
    store = await FilmCatalogStore.open(path);
    expect(
      (await store.versionSelection('tmdb:tv:1'))!.toJson(),
      selection.toJson(),
    );
    expect(
      (await store.versionSelection(
        'tmdb:tv:1',
        sourceScope: 'server',
      ))!.defaultKey,
      'server',
    );
    expect((await store.resources()).map((r) => r.versionKey).toSet(), {
      selection.defaultKey,
    });
    await store.saveServerVersion(
      assigned.first.id,
      path: '/server/elsewhere/E1.mkv',
      name: 'different',
    );
    expect(
      (await store.resource(assigned.first.id))!.versionKey,
      selection.defaultKey,
    );
    await store.close();
  });
}
