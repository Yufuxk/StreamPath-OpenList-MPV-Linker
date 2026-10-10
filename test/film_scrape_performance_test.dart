import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/film_home_section.dart';
import 'package:streampath/data/models/media_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late Directory temp;
  late FilmCatalogStore store;
  late Database db;
  late FilmCatalogRoot root;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('film_scrape_regression_');
    final file = p.join(temp.path, 'catalog.db');
    store = await FilmCatalogStore.open(file);
    db = await databaseFactoryFfi.openDatabase(file);
    final id = await store.addRoot(
      sourceId: 'test',
      kind: MediaSourceKind.webdav,
      path: 'TV',
      type: FilmMediaType.tv,
      name: 'TV',
    );
    root = (await store.root(id))!;
    final generation = await store.beginScan(id);
    await store.stage(root, generation, [
      for (var i = 1; i <= 24; i++)
        FilmScanEntry(
          path: 'TV/S01E$i.strm',
          parentPath: 'TV',
          name: 'S01E$i.strm',
          mediaKind: 'strm',
        ),
    ]);
    await store.commitScan(id, generation, cancelled: () => false);
  });
  tearDown(() async {
    await store.close();
    await temp.delete(recursive: true);
  });

  FilmWork work({int id = 0, String title = 'Show'}) => FilmWork(
    id: id,
    type: FilmMediaType.tv,
    tmdbId: 1,
    title: title,
    originalTitle: 'Show',
    overview: '',
    language: 'zh-CN',
    year: 2020,
    fetchedAt: 42,
    metadata: {
      'genres': ['Drama'],
      'origin_country': ['JP'],
      'credits': {
        'cast': [
          for (var i = 0; i < 100; i++) {'id': i, 'name': 'Person $i'},
        ],
      },
    },
  );
  Map<String, dynamic> season(int episode) => {
    'episodes': [
      {'episode_number': episode, 'name': 'Episode $episode'},
    ],
  };

  test(
    'unchanged metadata does not rewrite indexes, seasons or notify the library',
    () async {
      final resources = await store.resources(rootId: root.id);
      await store.applyMetadata(root.id, {
        for (var i = 0; i < resources.length; i++)
          resources[i].pathKey: FilmScanMatch(
            work: work(),
            origin: 'explicit',
            bindingVersion: 0,
            episode: (1, i + 1),
            seasonNumber: 1,
            seasonMetadata: season(1),
          ),
      });
      final mapped = await store.resources(rootId: root.id);
      final saved = (await store.work(mapped.first.workId!))!;
      await db.execute('CREATE TABLE write_audit (kind TEXT NOT NULL)');
      for (final table in ['works', 'work_people', 'season_metadata']) {
        for (final operation in ['INSERT', 'UPDATE', 'DELETE']) {
          await db.execute(
            'CREATE TRIGGER audit_${table}_$operation AFTER $operation ON $table '
            "BEGIN INSERT INTO write_audit VALUES ('$table'); END",
          );
        }
      }
      var libraryChanges = 0, watchChanges = 0;
      store.addListener(() => libraryChanges++);
      store.watchChanges.addListener(() => watchChanges++);
      for (final resource in mapped) {
        await store.applyMetadata(root.id, {
          resource.pathKey: FilmScanMatch(
            work: saved,
            origin: resource.bindingOrigin,
            bindingVersion: resource.bindingVersion,
            episode: (resource.season!, resource.episode!),
            seasonNumber: 1,
            seasonMetadata: await store.season(saved.id, 1),
          ),
        });
      }
      expect(await db.query('write_audit'), isEmpty);
      expect(libraryChanges, 0);
      expect(watchChanges, 0);
      final after = await store.resources(rootId: root.id);
      expect(
        after.map(
          (r) => (r.id, r.workId, r.season, r.episode, r.bindingVersion),
        ),
        mapped.map(
          (r) => (r.id, r.workId, r.season, r.episode, r.bindingVersion),
        ),
      );
    },
  );

  test(
    'equal timestamps with different metadata still save without reloading watch state',
    () async {
      final resource = (await store.resources()).first;
      await store.applyMetadata(root.id, {
        resource.pathKey: FilmScanMatch(
          work: work(),
          origin: 'explicit',
          bindingVersion: 0,
          episode: (1, 1),
        ),
      });
      final bound = (await store.resource(resource.id))!;
      var libraryChanges = 0, watchChanges = 0;
      store.addListener(() => libraryChanges++);
      store.watchChanges.addListener(() => watchChanges++);
      await store.applyMetadata(root.id, {
        resource.pathKey: FilmScanMatch(
          work: work(id: bound.workId!, title: 'Updated'),
          origin: 'nfo',
          bindingVersion: bound.bindingVersion,
          episode: (1, 1),
          seasonNumber: 1,
          seasonMetadata: season(1),
        ),
      });
      expect((await store.work(bound.workId!))!.title, 'Updated');
      expect((await store.work(bound.workId!))!.fetchedAt, 42);
      expect(libraryChanges, 1);
      expect(watchChanges, 0);
      await store.applyMetadata(root.id, {
        resource.pathKey: FilmScanMatch(
          work: work(id: bound.workId!, title: 'Updated'),
          origin: 'nfo',
          bindingVersion: bound.bindingVersion,
          episode: (1, 1),
          seasonNumber: 1,
          seasonMetadata: season(2),
        ),
      });
      expect((await store.season(bound.workId!, 1))!['episodes'], hasLength(2));
      expect(libraryChanges, 2);
      expect(watchChanges, 0);
    },
  );

  test(
    'binding changes notify watch state and stale metadata cannot overwrite manual mapping',
    () async {
      final resource = (await store.resources()).first;
      var watchChanges = 0;
      store.watchChanges.addListener(() => watchChanges++);
      await store.applyMetadata(root.id, {
        resource.pathKey: FilmScanMatch(
          work: work(),
          origin: 'explicit',
          bindingVersion: 0,
          episode: (1, 1),
        ),
      });
      expect(watchChanges, 1);
      final bound = (await store.resource(resource.id))!;
      await store.mapEpisodes({bound: (0, 2)});
      expect(watchChanges, 2);
      await store.applyMetadata(root.id, {
        resource.pathKey: FilmScanMatch(
          work: work(title: 'Late'),
          origin: 'explicit',
          bindingVersion: bound.bindingVersion,
          episode: (1, 1),
        ),
      });
      expect(watchChanges, 2);
      final after = (await store.resource(resource.id))!;
      expect(
        (after.season, after.episode, after.mappingOrigin),
        (0, 2, 'manual'),
      );
      expect((await store.work(after.workId!))!.title, 'Show');
      await store.withBatchedChanges(() async {
        await store.markWatched([after], true);
        await store.markWatched([after], false);
      });
      expect(watchChanges, 3);
    },
  );

  test(
    'section projection preserves preference order, disabled roots and unreferenced works',
    () async {
      final resource = (await store.resources()).first;
      await store.applyMetadata(root.id, {
        resource.pathKey: FilmScanMatch(
          work: work(),
          origin: 'explicit',
          bindingVersion: 0,
        ),
      });
      await store.refreshWork(
        const FilmWork(
          type: FilmMediaType.movie,
          tmdbId: 2,
          title: 'Unreferenced',
          originalTitle: 'Unreferenced',
          overview: '',
          language: 'en',
          year: 1980,
          metadata: {
            'genres': ['Unreferenced'],
            'origin_country': ['XX'],
          },
        ),
      );
      await store.setRootEnabled(root.id, false);
      const saved = [
        FilmHomeSection('country:JP', enabled: false),
        FilmHomeSection('continue', enabled: false),
        FilmHomeSection('genre:Retained', enabled: true),
      ];
      await store.setHomeSections(saved);
      final sections = await store.homeSections();
      expect(sections.take(4).map((s) => (s.id, s.enabled)), [
        ('country:JP', false),
        ('continue', false),
        ('daily', true),
        ('genre:Retained', true),
      ]);
      expect(
        sections.map((s) => s.id),
        containsAll(['genre:Drama', 'decade:2020']),
      );
      expect(sections.map((s) => s.id), isNot(contains('country:XX')));
      expect(sections.map((s) => s.id), isNot(contains('genre:Unreferenced')));
      expect(
        sections.singleWhere((s) => s.id == 'genre:Drama').enabled,
        isFalse,
      );
    },
  );
}
