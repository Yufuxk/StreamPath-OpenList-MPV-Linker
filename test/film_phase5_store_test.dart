import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late Directory temp;
  late FilmCatalogStore store;
  late FilmCatalogRoot root;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('film_phase5_');
    store = await FilmCatalogStore.open('${temp.path}/catalog.db');
    final id = await store.addRoot(
      sourceId: 'test',
      kind: MediaSourceKind.local,
      path: 'Movies',
      type: FilmMediaType.movie,
      name: 'Movies',
    );
    root = (await store.root(id))!;
  });
  tearDown(() async {
    await store.close();
    await temp.delete(recursive: true);
  });
  Future<void> stage(
    List<String> paths, {
    String? scope,
    bool cancel = false,
  }) async {
    final generation = await store.beginScan(root.id);
    await store.stage(root, generation, [
      for (final path in paths)
        FilmScanEntry(
          path: path,
          parentPath: path.substring(0, path.lastIndexOf('/')),
          name: path.split('/').last,
          mediaKind: 'video',
        ),
    ]);
    await store.commitScan(
      root.id,
      generation,
      cancelled: () => cancel,
      scopePath: scope,
    );
  }

  FilmWork work(int number, {int id = 0, bool local = false}) => FilmWork(
    id: id,
    type: FilmMediaType.movie,
    tmdbId: local ? 0 : number,
    identityKey: 'local:test:$number',
    title: 'Movie $number',
    originalTitle: 'Movie $number',
    overview: '',
    language: 'zh-CN',
    metadata: {
      'belongs_to_collection': {'id': 123, 'name': 'Series'},
      'credits': {
        'cast': [
          {'id': 456, 'name': 'Person'},
        ],
      },
    },
  );
  test(
    'subtree missing never changes siblings and cancellation preserves previous availability',
    () async {
      await stage(['Movies/A/1.mkv', 'Movies/B/2.mkv']);
      await stage([], scope: 'Movies/A');
      final rows = await store.resources(rootId: root.id);
      expect(rows.firstWhere((r) => r.name == '1.mkv').availability, 'missing');
      expect(rows.firstWhere((r) => r.name == '2.mkv').availability, 'present');
      await expectLater(
        stage([], scope: 'Movies/B', cancel: true),
        throwsA(isA<FilmCatalogException>()),
      );
      expect(
        (await store.resources(
          rootId: root.id,
        )).firstWhere((r) => r.name == '2.mkv').availability,
        'present',
      );
    },
  );
  test(
    'local identity merges into existing TMDB work without losing favorite, watch or collection',
    () async {
      await stage(['Movies/1.mkv', 'Movies/2.mkv']);
      var resources = await store.resources(rootId: root.id);
      await store.bind([resources[0]], work(1, local: true));
      await store.bind([resources[1]], work(1));
      resources = await store.resources(rootId: root.id);
      final local = resources[0];
      final canonical = resources[1].workId;
      await store.setFavorite(local.workId!, true);
      await store.markWatched(
        [resources[1]],
        false,
        observedAt: DateTime(2026, 10, 7, 1),
      );
      await store.markWatched(
        [local],
        true,
        observedAt: DateTime(2026, 10, 7, 2),
      );
      final daily = await store.dailySelection();
      expect(daily, contains(local.workId));
      final collection = await store.createCollection('Favorites');
      await store.addCollectionMember(collection, local.workId!);
      await store.refreshWork(work(1, id: local.workId!));
      expect(await store.dailySelection(), [canonical]);
      expect(
        (await store.resources(rootId: root.id)).map((r) => r.workId).toSet(),
        {canonical},
      );
      expect(await store.isFavorite(canonical!), true);
      expect(
        await store.works(type: null, collectionId: collection),
        hasLength(1),
      );
      expect(await store.works(type: null, personId: 'tmdb:456'), hasLength(1));
      expect(
        (await store.resourceWatchState(
          (await store.resources()).first,
        ))!.fraction,
        1,
      );
    },
  );
  test(
    'daily selection survives restart, is bounded and does not refill missing works',
    () async {
      await stage([for (var i = 1; i <= 12; i++) 'Movies/$i.mkv']);
      var resources = await store.resources(rootId: root.id);
      for (var i = 0; i < resources.length; i++) {
        await store.bind([resources[i]], work(i + 1));
      }
      final day = DateTime(2026, 10, 7);
      final first = await store.dailySelection(now: day);
      expect(first, hasLength(10));
      await store.close();
      store = await FilmCatalogStore.open('${temp.path}/catalog.db');
      expect(await store.dailySelection(now: day), first);
      await stage([]);
      expect(await store.dailySelection(now: day), first);
      expect(
        await store.dailySelection(now: day.add(const Duration(days: 1))),
        isEmpty,
      );
    },
  );
  test(
    'automatic movie series requires two available works; custom collection import is idempotent',
    () async {
      await stage(['Movies/1.mkv', 'Movies/2.mkv']);
      final resources = await store.resources();
      await store.bind([resources[0]], work(1));
      expect(await store.collections(), isEmpty);
      await store.bind([resources[1]], work(2));
      expect((await store.collections()).single.tmdbId, 123);
      await store.createCollection('Custom', id: 'custom:stable');
      await store.createCollection('Conflicting name', id: 'custom:stable');
      expect((await store.collections(customOnly: true)).single.name, 'Custom');
      await store.removeCollection('custom:stable');
      expect(await store.resources(), hasLength(2));
    },
  );
}
