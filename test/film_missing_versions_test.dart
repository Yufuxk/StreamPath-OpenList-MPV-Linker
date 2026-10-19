import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  for (final type in FilmMediaType.values) {
    for (final kind in ['video', 'iso', 'bdmv']) {
      test('缺失版本从资源、计数及分类移除并保留恢复身份 ${type.name} $kind', () async {
        final temp = await Directory.systemTemp.createTemp('missing_versions_');
        var store = await FilmCatalogStore.open('${temp.path}/catalog.db');
        try {
          final id = await store.addRoot(
            sourceId: 'fixture',
            kind: MediaSourceKind.local,
            path: 'Library',
            type: type,
            name: 'Fixture',
          );
          final root = (await store.root(id))!;
          Future<void> scan(List<String> names) async {
            final generation = await store.beginScan(id);
            await store.stage(root, generation, [
              for (final name in names)
                FilmScanEntry(
                  path: 'Library/$name',
                  parentPath: 'Library',
                  name: name,
                  mediaKind: kind,
                ),
            ]);
            await store.commitScan(id, generation, cancelled: () => false);
          }

          final work = FilmWork(
            type: type,
            tmdbId: 42,
            title: 'Fixture',
            originalTitle: 'Fixture',
            overview: '',
            language: 'en-US',
            year: 2026,
            posterPath: '/poster.png',
            metadata: const {
              'genres': ['Animation'],
              'origin_country': ['JP'],
              'certification': 'PG-13',
            },
          );
          await scan(['old', 'new']);
          await store.bind(await store.resources(rootId: id), work);
          var original = await store.resources(rootId: id);
          if (type == FilmMediaType.tv && kind == 'video') {
            await store.mapEpisodes({
              for (final resource in original) resource: (1, 1),
            });
            original = await store.resources(rootId: id);
          }
          final old = original.firstWhere((r) => r.name == 'old');
          final current = original.firstWhere((r) => r.name == 'new');
          await store.setFavorite(old.workId!, true);
          await store.markWatched(
            [old],
            true,
            observedAt: DateTime(2026, 10, 18),
          );
          await scan(['new']);
          expect((await store.resources(workId: old.workId)).map((r) => r.id), [
            current.id,
          ]);
          final visible = (await store.works(type: type)).single;
          expect(visible.resourceCount, 1);
          expect(visible.missingCount, 0);
          expect((await store.categories()).every((c) => c.count == 1), isTrue);
          expect(await store.isFavorite(old.workId!), isTrue);
          expect((await store.resourceWatchState(old))!.status.name, 'watched');
          expect((await store.resource(old.id))!.availability, 'missing');

          await store.close();
          store = await FilmCatalogStore.open('${temp.path}/catalog.db');
          expect((await store.resources(workId: old.workId)).map((r) => r.id), [
            current.id,
          ]);
          await scan(['new', 'old']);
          final restored = (await store.resource(old.id))!;
          expect(restored.availability, 'present');
          expect(restored.workId, old.workId);
          expect(restored.bindingVersion, old.bindingVersion);
          expect(
            (await store.resourceWatchState(restored))!.status.name,
            'watched',
          );

          await scan([]);
          expect(await store.resources(rootId: id), isEmpty);
          expect(await store.works(type: type), isEmpty);
          expect(await store.categories(), isEmpty);
          expect(await store.chooseRootCover(id), isNull);
          expect(await store.work(old.workId!), isNotNull);
          expect(await store.isFavorite(old.workId!), isTrue);
          expect(await store.resources(sourceId: 'other-source'), isEmpty);
        } finally {
          await store.close();
          await temp.delete(recursive: true);
        }
      });
    }
  }

  test('失败、取消和增量扫描不移除未经确认的版本，子目录只影响自身', () async {
    final temp = await Directory.systemTemp.createTemp(
      'missing_versions_scope_',
    );
    final store = await FilmCatalogStore.open('${temp.path}/catalog.db');
    try {
      final id = await store.addRoot(
        sourceId: 'fixture',
        kind: MediaSourceKind.local,
        path: 'Library',
        type: FilmMediaType.movie,
        name: 'Fixture',
      );
      final root = (await store.root(id))!;
      final generation = await store.beginScan(id);
      await store.stage(root, generation, [
        for (final name in ['A/old', 'B/keep'])
          FilmScanEntry(
            path: 'Library/$name',
            parentPath: 'Library/${name[0]}',
            name: name.split('/').last,
            mediaKind: 'video',
          ),
      ]);
      await store.commitScan(id, generation, cancelled: () => false);
      final cancelled = await store.beginScan(id);
      await expectLater(
        store.commitScan(id, cancelled, cancelled: () => true),
        throwsA(isA<FilmCatalogException>()),
      );
      expect(await store.resources(rootId: id), hasLength(2));
      await store.finishScan(id, cancelled, 'cancelled', null);
      final failed = await store.beginScan(id);
      await store.finishScan(id, failed, 'failed', 'sourceUnavailable');
      expect(await store.resources(rootId: id), hasLength(2));
      final incremental = await store.beginScan(id);
      await store.commitScan(
        id,
        incremental,
        cancelled: () => false,
        incremental: true,
      );
      expect(await store.resources(rootId: id), hasLength(2));
      final scoped = await store.beginScan(id);
      await store.commitScan(
        id,
        scoped,
        cancelled: () => false,
        scopePath: 'Library/A',
      );
      expect((await store.resources(rootId: id)).single.name, 'keep');
      expect(await store.pendingCount(rootId: id), 1);
    } finally {
      await store.close();
      await temp.delete(recursive: true);
    }
  });
}
