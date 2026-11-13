import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/film_metadata_edit.dart';
import 'package:streampath/data/models/film_playlist.dart';
import 'package:streampath/data/models/media_source.dart';

FilmWork source({
  String title = 'Source',
  String overview = 'Source plot',
  int id = 1,
}) => FilmWork(
  type: FilmMediaType.tv,
  tmdbId: id,
  title: title,
  originalTitle: 'Original',
  overview: overview,
  language: 'zh-CN',
  year: 2020,
  metadata: const {
    'genres': ['Drama'],
    'vote_average': 7.0,
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late Directory temp;
  late FilmCatalogStore store;
  late FilmWork work;
  late List<FilmResource> resources;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('metadata-edit-');
    store = await FilmCatalogStore.open(p.join(temp.path, 'catalog.db'));
    final id = await store.addRoot(
      sourceId: 'dav',
      kind: MediaSourceKind.webdav,
      path: 'TV',
      type: FilmMediaType.tv,
      name: 'TV',
    );
    final root = (await store.root(id))!;
    final generation = await store.beginScan(id);
    await store.stage(root, generation, [
      for (final name in ['A.mkv', 'B.mkv'])
        FilmScanEntry(
          path: 'TV/$name',
          parentPath: 'TV',
          name: name,
          mediaKind: 'video',
        ),
    ]);
    await store.commitScan(id, generation, cancelled: () => false);
    resources = await store.resources();
    await store.bind(resources, source());
    work = (await store.works(type: null)).single;
    resources = await store.resources();
    await store.mapEpisodes({for (final r in resources) r: (1, 1)});
    resources = await store.resources();
    await store.saveSeason(work.id, 1, 'zh-CN', {
      'season_number': 1,
      'name': 'Season 1',
      'episodes': [
        {
          'episode_number': 1,
          'season_number': 1,
          'name': 'Episode 1',
          'overview': 'Episode plot',
          'air_date': '2020-01-01',
        },
      ],
    });
  });
  tearDown(() async {
    await store.close();
    await temp.delete(recursive: true);
  });

  test('人工字段保护、来源更新及逐项恢复', () async {
    final target = FilmMetadataTarget.work(work.id);
    await store.saveMetadata(await store.metadataSnapshot(target), {
      'title': 'Custom',
      'overview': '',
      'logo_path': '',
    });
    await store.refreshWork(source(title: 'New source', overview: 'New plot'));
    expect((await store.work(work.id))!.title, 'Custom');
    expect((await store.work(work.id))!.overview, '');
    final latest = await store.metadataSnapshot(target);
    expect(latest.source['title'], 'New source');
    expect(latest.overrides['logo_path'], '');
    await store.saveMetadata(latest, {}, restore: {'title', 'overview'});
    expect((await store.work(work.id))!.title, 'New source');
    expect((await store.work(work.id))!.overview, 'New plot');
    expect((await store.logoOverride(work.id)), '');
  });

  test('旧弹窗只提交改动字段，保留同时发生的修改', () async {
    final target = FilmMetadataTarget.work(work.id);
    final a = await store.metadataSnapshot(target),
        b = await store.metadataSnapshot(target);
    await store.saveMetadata(a, {'title': 'First'});
    await store.saveMetadata(b, {'overview': 'Second'});
    expect((await store.work(work.id))!.title, 'First');
    expect((await store.work(work.id))!.overview, 'Second');
  });

  test('季与单集覆盖在来源刷新后保留，恢复使用最新来源', () async {
    final target = FilmMetadataTarget.episode(work.id, 1, 1);
    await store.saveMetadata(await store.metadataSnapshot(target), {
      'title': 'Custom episode',
      'overview': '',
    });
    await store.saveMetadata(
      await store.metadataSnapshot(FilmMetadataTarget.season(work.id, 1)),
      {'title': 'Custom season'},
    );
    await store.saveSeason(work.id, 1, 'en-US', {
      'name': 'Fresh season',
      'episodes': [
        {
          'episode_number': 1,
          'name': 'Fresh episode',
          'overview': 'Fresh plot',
        },
      ],
    });
    final season = (await store.season(work.id, 1))!;
    expect(season['name'], 'Custom season');
    expect((season['episodes'] as List).single['name'], 'Custom episode');
    await store.saveMetadata(
      await store.metadataSnapshot(target),
      {},
      restore: {'title', 'overview'},
    );
    expect(
      (await store.metadataSnapshot(target)).values['title'],
      'Fresh episode',
    );
  });

  test('资源覆盖隔离版本并继续继承共享单集', () async {
    final target = FilmMetadataTarget.resource(resources.first.id);
    await store.saveMetadata(await store.metadataSnapshot(target), {
      'title': 'Version A',
      'overview': '',
    });
    await store.saveMetadata(
      await store.metadataSnapshot(FilmMetadataTarget.episode(work.id, 1, 1)),
      {'title': 'Shared', 'overview': 'Shared plot'},
    );
    expect((await store.metadataSnapshot(target)).values['title'], 'Version A');
    expect((await store.metadataSnapshot(target)).values['overview'], '');
    expect(
      (await store.metadataSnapshot(
        FilmMetadataTarget.resource(resources.last.id),
      )).values['title'],
      'Shared',
    );
    await store.saveMetadata(
      await store.metadataSnapshot(target),
      {},
      restore: {'title'},
    );
    expect((await store.metadataSnapshot(target)).values['title'], 'Shared');
  });

  test('资源重新映射后拒绝旧编辑快照', () async {
    final snapshot = await store.metadataSnapshot(
      FilmMetadataTarget.resource(resources.first.id),
    );
    await store.mapEpisodes({resources.first: (1, 2)});
    await expectLater(
      store.saveMetadata(snapshot, {'title': 'Wrong'}),
      throwsA(isA<FilmCatalogException>()),
    );
  });

  test('人工排序名和分类立即参与查询', () async {
    await store.saveMetadata(
      await store.metadataSnapshot(FilmMetadataTarget.work(work.id)),
      {
        'title': 'Zebra',
        'sort_title': 'A',
        'genres': ['Custom'],
        'vote_average': 9.5,
      },
    );
    expect(
      (await store.works(type: null, query: 'Zebra')).single.title,
      'Zebra',
    );
    expect(
      (await store.works(type: null, sectionId: 'genre:Custom')).single.id,
      work.id,
    );
  });

  test('演职员本地身份可用于人员索引', () async {
    await store.saveMetadata(
      await store.metadataSnapshot(FilmMetadataTarget.work(work.id)),
      {
        'credits': {
          'cast': [
            {
              'identity': 'local:person',
              'name': 'Custom Actor',
              'character': 'Hero',
            },
          ],
        },
      },
    );
    expect(
      (await store.works(type: null, personId: 'local:person')).single.id,
      work.id,
    );
  });

  test('日期、数字、标题校验不写入错误资料', () async {
    final snapshot = await store.metadataSnapshot(
      FilmMetadataTarget.work(work.id),
    );
    for (final patch in [
      {'title': ''},
      {'vote_average': 11},
      {'year': 2021, 'release_date': '2020-01-01'},
      {'release_date': '2020-02-30'},
      {'runtime': -1},
    ]) {
      await expectLater(
        store.saveMetadata(snapshot, patch),
        throwsA(isA<FilmCatalogException>()),
      );
    }
    expect((await store.work(work.id))!.title, 'Source');
  });

  test('重启保留覆盖和来源快照', () async {
    final target = FilmMetadataTarget.work(work.id);
    await store.saveMetadata(await store.metadataSnapshot(target), {
      'title': 'Persistent',
    });
    await store.close();
    store = await FilmCatalogStore.open(p.join(temp.path, 'catalog.db'));
    expect(
      (await store.metadataSnapshot(target)).values['title'],
      'Persistent',
    );
    expect((await store.metadataSnapshot(target)).source['title'], 'Source');
  });

  test('旧 Logo 偏好离线迁移且不会重复覆盖新选择', () async {
    await store.setPreference('logo_override:${work.id}', '/legacy.png');
    await store.close();
    store = await FilmCatalogStore.open(p.join(temp.path, 'catalog.db'));
    expect(await store.logoOverride(work.id), '/legacy.png');
    expect(await store.preference('logo_override:${work.id}'), isNull);
    await store.setLogoOverride(work.id, '/new.png');
    await store.close();
    store = await FilmCatalogStore.open(p.join(temp.path, 'catalog.db'));
    expect(await store.logoOverride(work.id), '/new.png');
  });

  test('导入重映射作品资源并保留目标库已有人工字段', () async {
    await store.saveMetadata(
      await store.metadataSnapshot(FilmMetadataTarget.work(work.id)),
      {'title': 'Imported title', 'tagline': 'Imported tagline'},
    );
    await store.saveMetadata(
      await store.metadataSnapshot(FilmMetadataTarget.episode(work.id, 1, 1)),
      {'overview': 'Imported episode'},
    );
    await store.saveMetadata(
      await store.metadataSnapshot(
        FilmMetadataTarget.resource(resources.first.id),
      ),
      {'title': 'Imported resource'},
    );
    final data = await store.portableSnapshot();
    final other = await FilmCatalogStore.open(p.join(temp.path, 'other.db'));
    try {
      await other.refreshWork(source(id: 22));
      await other.refreshWork(source());
      final destination = (await other.cachedWork(FilmMediaType.tv, 1))!;
      expect(destination.id, isNot(work.id));
      final rootId = await other.addRoot(
        sourceId: 'new-dav',
        kind: MediaSourceKind.webdav,
        path: 'TV',
        type: FilmMediaType.tv,
        name: 'TV',
      );
      final root = (await other.root(rootId))!;
      final generation = await other.beginScan(rootId);
      await other.stage(root, generation, [
        for (final r in resources)
          FilmScanEntry(
            path: r.path,
            parentPath: r.parentPath,
            name: r.name,
            mediaKind: 'video',
          ),
      ]);
      await other.commitScan(rootId, generation, cancelled: () => false);
      await other.bind(await other.resources(), source());
      await other.saveMetadata(
        await other.metadataSnapshot(FilmMetadataTarget.work(destination.id)),
        {'title': 'Own title'},
      );
      await other.importPortable(data, {'metadata'}, {'dav': 'new-dav'});
      final target = await other.metadataSnapshot(
        FilmMetadataTarget.work(destination.id),
      );
      expect(target.values['title'], 'Own title');
      expect(target.values['tagline'], 'Imported tagline');
      expect(
        (await other.metadataSnapshot(
          FilmMetadataTarget.episode(destination.id, 1, 1),
        )).values['overview'],
        'Imported episode',
      );
      final importedResource = (await other.resources()).firstWhere(
        (r) => r.name == resources.first.name,
      );
      expect(importedResource.metadataOverrides['title'], 'Imported resource');
    } finally {
      await other.close();
    }
  });

  test('无来源单集可编辑，候选补取不覆盖草稿字段', () async {
    final target = FilmMetadataTarget.episode(work.id, 2, 3);
    await store.saveMetadata(await store.metadataSnapshot(target), {
      'title': 'Manual episode',
      'overview': 'Manual plot',
    });
    final snapshot = await store.metadataSnapshot(target);
    await store.saveMetadataCandidates(snapshot, {
      'poster_path': [
        {'path': '/still.jpg', 'width': 1280, 'height': 720},
      ],
    });
    final value = await store.metadataSnapshot(target);
    expect(value.values['title'], 'Manual episode');
    expect(
      (value.values['poster_candidates'] as List).single['path'],
      '/still.jpg',
    );
    await store.saveSeason(work.id, 2, 'zh-CN', {
      'name': 'Season 2',
      'episodes': [],
    });
    expect(
      (await store.metadataSnapshot(target)).values['title'],
      'Manual episode',
    );
  });

  test('恢复或隐藏图片同步移除旧候选选中状态', () async {
    final target = FilmMetadataTarget.work(work.id);
    await store.saveMetadata(await store.metadataSnapshot(target), {
      'poster_path': '/custom.jpg',
      'image_sources': {'poster_path': '/provider.jpg'},
    });
    await store.saveMetadata(
      await store.metadataSnapshot(target),
      {},
      restore: {'poster_path'},
    );
    expect(
      (await store.metadataSnapshot(
        target,
      )).overrides.containsKey('image_sources'),
      false,
    );
    await store.saveMetadata(await store.metadataSnapshot(target), {
      'poster_path': '/custom.jpg',
      'image_sources': {'poster_path': '/provider.jpg'},
    });
    await store.saveMetadata(await store.metadataSnapshot(target), {
      'poster_path': '',
    });
    expect(
      (await store.metadataSnapshot(
        target,
      )).overrides.containsKey('image_sources'),
      false,
    );
  });

  test('单集资源人工封面在播放列表继续遵守防剧透及显式隐藏', () async {
    final target = FilmMetadataTarget.resource(resources.first.id);
    await store.saveMetadata(await store.metadataSnapshot(target), {
      'poster_path': '/custom-still.jpg',
    });
    final r = (await store.resource(resources.first.id))!;
    final list = await store.createPlaylist(
      'Manual cover',
      r.sourceId,
      r.sourceKind,
      'TV',
      FilmPlaylistScope.resource(r),
    );
    final entry = (await store.playlistSnapshot(list)).entries.single;
    expect(entry.artwork, '/custom-still.jpg');
    expect(entry.display['episodeArtwork'], true);
    await store.saveMetadata(await store.metadataSnapshot(target), {
      'poster_path': '',
    });
    expect((await store.playlistSnapshot(list)).entries.single.artwork, '');
  });

  test('作品合并保留人工字段与季集覆盖，目标已有字段优先', () async {
    await store.saveMetadata(
      await store.metadataSnapshot(FilmMetadataTarget.work(work.id)),
      {'title': 'Target title'},
    );
    const local = FilmWork(
      type: FilmMediaType.tv,
      identityKey: 'file:local',
      title: 'Local',
      originalTitle: 'Local',
      overview: '',
      language: 'zh-CN',
    );
    await store.bind([resources.first], local);
    final r = (await store.resource(resources.first.id))!;
    final localWork = (await store.work(r.workId!))!;
    await store.saveMetadata(
      await store.metadataSnapshot(FilmMetadataTarget.work(localWork.id)),
      {'overview': 'Local overview', 'title': 'Local title'},
    );
    await store.saveMetadata(
      await store.metadataSnapshot(
        FilmMetadataTarget.episode(localWork.id, 1, 1),
      ),
      {'overview': 'Local episode'},
    );
    await store.saveMetadata(
      await store.metadataSnapshot(FilmMetadataTarget.episode(work.id, 1, 1)),
      {'title': 'Target episode'},
    );
    await store.refreshWork(
      FilmWork(
        id: localWork.id,
        type: FilmMediaType.tv,
        tmdbId: 1,
        title: 'Refreshed',
        originalTitle: 'Original',
        overview: 'New overview',
        language: 'zh-CN',
      ),
    );
    final merged = await store.metadataSnapshot(
      FilmMetadataTarget.work(work.id),
    );
    expect(merged.values['title'], 'Target title');
    expect(merged.values['overview'], 'Local overview');
    final episode = await store.metadataSnapshot(
      FilmMetadataTarget.episode(work.id, 1, 1),
    );
    expect(episode.values['title'], 'Target episode');
    expect(episode.values['overview'], 'Local episode');
    expect((await store.resource(r.id))!.workId, work.id);
    expect(await store.work(localWork.id), isNull);
  });
}
