import 'dart:io';
import 'support/legacy_film_catalog.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/film_watch_state.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/video_queue.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  Future<List<FilmResource>> seed(FilmCatalogStore store, String source) async {
    final id = await store.addRoot(
      sourceId: source,
      kind: MediaSourceKind.webdav,
      path: 'TV',
      type: FilmMediaType.tv,
      name: source,
    );
    final root = (await store.root(id))!;
    final generation = await store.beginScan(id);
    await store.stage(root, generation, [
      for (final (name, kind) in [
        ('disc.iso', 'iso'),
        ('disc2', 'bdmv'),
        ('e1.mkv', 'video'),
      ])
        FilmScanEntry(
          path: 'TV/$name',
          parentPath: 'TV',
          name: name,
          mediaKind: kind,
        ),
    ]);
    await store.commitScan(id, generation, cancelled: () => false);
    await store.bind(
      await store.resources(rootId: id),
      const FilmWork(
        type: FilmMediaType.tv,
        tmdbId: 1,
        title: 'Show',
        originalTitle: 'Show',
        overview: '',
        language: 'zh-CN',
      ),
    );
    final rows = await store.resources(rootId: id);
    await store.mapEpisodes({
      for (final r in rows) r: (1, r.mediaKind == 'bdmv' ? 2 : 1),
    });
    return store.resources(rootId: id);
  }

  test('光盘手动按整片、来源独立，自动进度不推断光盘或同集视频已看', () async {
    final store = await FilmCatalogStore.open(inMemoryDatabasePath);
    try {
      final a = await seed(store, 'a');
      final b = await seed(store, 'b');
      final iso = a.firstWhere((r) => r.mediaKind == 'iso');
      final bdmv = a.firstWhere((r) => r.mediaKind == 'bdmv');
      final video = a.firstWhere((r) => !r.isDisc);
      for (final r in [iso, bdmv]) {
        await store.recordVideoProgress(
          VideoProgressUpdate(
            sourceId: r.sourceId,
            path: r.path,
            positionMs: 100,
            durationMs: 100,
            recordedAt: DateTime.now(),
            completed: true,
          ),
        );
        expect(
          (await store.resourceWatchState(r))!.status,
          FilmWatchStatus.unwatched,
        );
      }
      await store.markWatched([iso], true);
      expect(
        (await store.resourceWatchState(iso))!.status,
        FilmWatchStatus.watched,
      );
      for (final r in [bdmv, video, ...b]) {
        expect(
          (await store.resourceWatchState(r))!.status,
          FilmWatchStatus.unwatched,
        );
      }
      expect(
        (await store.seasonWatchState(iso.workId!, 1, sourceId: 'a'))!.fraction,
        closeTo(1 / 3, .001),
      );
      await store.markWatched(a, true);
      expect(
        (await store.workWatchStates(
          [iso.workId!],
          sourceIds: {'a'},
        ))[iso.workId]!.status,
        FilmWatchStatus.watched,
      );
      await store.markWatched([iso], false);
      expect(
        (await store.resourceWatchState(iso))!.status,
        FilmWatchStatus.unwatched,
      );
      expect(
        (await store.resourceWatchState(bdmv))!.status,
        FilmWatchStatus.watched,
      );
      await store.bind([bdmv], (await store.work(iso.workId!))!);
      final unmapped = (await store.resourceAt('a', bdmv.path))!;
      expect(unmapped.canMarkWatched, true);
      expect(
        (await store.resourceWatchState(unmapped))!.status,
        FilmWatchStatus.watched,
      );
      await store.refreshWork((await store.work(iso.workId!))!);
      expect(
        (await store.resourceWatchState(unmapped))!.status,
        FilmWatchStatus.watched,
      );
      await store.bind(
        [unmapped],
        const FilmWork(
          type: FilmMediaType.tv,
          tmdbId: 2,
          title: 'Other',
          originalTitle: 'Other',
          overview: '',
          language: 'zh-CN',
        ),
      );
      expect(
        (await store.resourceWatchState(
          (await store.resourceAt('a', bdmv.path))!,
        ))!.status,
        FilmWatchStatus.unwatched,
      );
    } finally {
      await store.close();
    }
  });

  test('v5 升级先备份且保留视频状态，光盘标记重开后仍保留', () async {
    final temp = await Directory.systemTemp.createTemp('disc_watch_');
    final path = p.join(temp.path, 'catalog.db');
    var store = await FilmCatalogStore.open(path);
    try {
      final rows = await seed(store, 'a');
      final video = rows.firstWhere((r) => !r.isDisc);
      final iso = rows.firstWhere((r) => r.mediaKind == 'iso');
      await store.markWatched([video], true);
      await store.close();
      final old = await databaseFactoryFfi.openDatabase(path);
      await restoreVersion6Fixture(old);
      await old.execute('DROP TABLE film_disc_watch_state');
      await old.setVersion(5);
      await old.close();
      store = await FilmCatalogStore.open(path);
      expect(
        temp.listSync().where((f) => f.path.contains('.before-v6-')),
        hasLength(1),
      );
      expect(
        (await store.resourceWatchState(video))!.status,
        FilmWatchStatus.watched,
      );
      expect(
        (await store.resourceWatchState(iso))!.status,
        FilmWatchStatus.unwatched,
      );
      await store.markWatched([iso], true);
      await store.close();
      store = await FilmCatalogStore.open(path);
      expect(
        (await store.resourceWatchState(iso))!.status,
        FilmWatchStatus.watched,
      );
    } finally {
      await store.close();
      await temp.delete(recursive: true);
    }
  });
}
