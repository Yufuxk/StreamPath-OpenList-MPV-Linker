import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/film_playlist.dart';
import 'package:streampath/data/models/media_connection.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/playback_history.dart';
import 'package:streampath/data/models/video_playlist_mode.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late Directory temp;
  late FilmCatalogStore store;
  late FilmCatalogRoot root;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('film_playlist_');
    store = await FilmCatalogStore.open('${temp.path}/catalog.db');
    root = (await store.root(
      await store.addRoot(
        sourceId: 'local:test',
        kind: MediaSourceKind.local,
        path: 'Shows',
        type: FilmMediaType.tv,
        name: 'Shows',
      ),
    ))!;
  });
  tearDown(() async {
    await store.close();
    await temp.delete(recursive: true);
  });
  Future<List<FilmResource>> seed(List<String> names, {int tmdb = 1}) async {
    final generation = await store.beginScan(root.id);
    await store.stage(root, generation, [
      for (final name in names)
        FilmScanEntry(
          path: 'Shows/$name',
          parentPath: 'Shows',
          name: name,
          mediaKind: name.endsWith('.strm') ? 'strm' : 'video',
        ),
    ]);
    await store.commitScan(root.id, generation, cancelled: () => false);
    final rows = await store.resources(rootId: root.id);
    await store.bind(
      rows,
      FilmWork(
        type: FilmMediaType.tv,
        tmdbId: tmdb,
        title: 'Show $tmdb',
        originalTitle: 'Show $tmdb',
        overview: '',
        language: 'zh-CN',
        year: 2024,
      ),
    );
    final current = await store.resources(rootId: root.id);
    await store.mapEpisodes({
      for (final r in current.where((r) => r.name.startsWith('S')))
        r: (
          int.parse(r.name.substring(1, 3)),
          int.parse(r.name.substring(4, 6)),
        ),
    });
    return store.resources(rootId: root.id);
  }

  Future<String> create(List<FilmResource> rows, {int? season}) =>
      store.createPlaylist(
        'Watch',
        root.sourceId,
        root.sourceKind,
        root.displayName,
        FilmPlaylistScope.work(rows.first.workId!, season: season),
      );

  test(
    'list cover follows member order, skips missing metadata and updates after removal',
    () async {
      final rows = await seed(['S01E01.mkv', 'S01E02.mkv', 'S01E03.mkv']);
      await store.saveSeason(rows.first.workId!, 1, 'zh-CN', {
        'episodes': [
          {'episode_number': 1},
          {'episode_number': 2, 'still_path': '/second.png'},
          {'episode_number': 3, 'still_path': '/third.png'},
        ],
      });
      final id = await create(rows);
      expect((await store.playlists()).single.artwork, '/second.png');
      expect((await store.playlists()).single.artworkTarget, 'w300');
      expect((await store.playlists()).single.artworkSensitive, isTrue);
      expect((await store.playlists()).single.artworkWorkId, rows.first.workId);
      expect(
        (await store.playlists()).single.artworkPath,
        rows.firstWhere((r) => r.episode == 2).path,
      );
      final entries = (await store.playlistSnapshot(id)).entries;
      await store.reorderPlaylist(id, [
        entries[2].id,
        entries[0].id,
        entries[1].id,
      ]);
      expect((await store.playlists()).single.artwork, '/third.png');
      await store.removePlaylistEntry(id, entries[2].id);
      expect((await store.playlists()).single.artwork, '/second.png');
      await store.removePlaylistEntry(id, entries[1].id);
      expect((await store.playlists()).single.artwork, isNull);
      await store.removePlaylistEntry(id, entries[0].id);
      final empty = (await store.playlists()).single;
      expect(empty.count, 0);
      expect(empty.artwork, isNull);
    },
  );

  test(
    'whole work includes specials and gaps; season is strict; versions grouped and pinned',
    () async {
      final rows = await seed([
        'S01E01-a.mkv',
        'S01E01-b.strm',
        'S01E02.mkv',
        'S00E01.mkv',
        'S03E01.mkv',
        'unmapped.mkv',
      ]);
      final work = rows.first.workId!;
      await store.saveSeason(work, 1, 'zh-CN', {
        'episodes': [
          {'episode_number': 1, 'air_date': '2024-01-01'},
          {'episode_number': 2, 'air_date': '2024-01-03'},
        ],
      });
      await store.saveSeason(work, 0, 'zh-CN', {
        'episodes': [
          {'episode_number': 1, 'air_date': '2024-01-02'},
        ],
      });
      final id = await create(rows);
      final snapshot = await store.playlistSnapshot(id);
      expect(snapshot.entries.map((e) => (e.season, e.episode)), [
        (1, 1),
        (0, 1),
        (1, 2),
        (3, 1),
      ]);
      expect(snapshot.entries.first.queueItem.versions.length, 2);
      final season = await store.playlistSnapshot(
        await create(rows, season: 1),
      );
      expect(season.entries.map((e) => e.season), [1, 1]);
      final pinned = rows.firstWhere((r) => r.name == 'S01E01-b.strm');
      final single = await store.createPlaylist(
        'Pinned',
        root.sourceId,
        root.sourceKind,
        root.displayName,
        FilmPlaylistScope.resource(pinned),
      );
      expect(
        (await store.playlistSnapshot(
          single,
        )).entries.single.queueItem.versions.single.path,
        pinned.path,
      );
      await store.addPlaylistScope(
        single,
        root.sourceId,
        FilmPlaylistScope.work(work),
      );
      expect(
        (await store.playlistSnapshot(single)).entries.first.pinnedPath,
        pinned.path,
      );
    },
  );
  test(
    'reordering survives reopen and missing resources retain their IDs and positions',
    () async {
      final rows = await seed(['S01E01.mkv', 'S01E02.mkv']);
      final id = await create(rows);
      final original = (await store.playlistSnapshot(id)).entries;
      await store.reorderPlaylist(
        id,
        original.reversed.map((e) => e.id).toList(),
      );
      await store.close();
      store = await FilmCatalogStore.open('${temp.path}/catalog.db');
      expect(
        (await store.playlistSnapshot(id)).entries.map((e) => e.id),
        original.reversed.map((e) => e.id),
      );
      final generation = await store.beginScan(root.id);
      await store.commitScan(root.id, generation, cancelled: () => false);
      final missing = await store.playlistSnapshot(id);
      expect(
        missing.entries.map((e) => e.id),
        original.reversed.map((e) => e.id),
      );
      expect(missing.entries.every((e) => !e.available), isTrue);
      expect(missing.entries.first.title, 'Show 1');
    },
  );
  test(
    'new entries append after user order; stale reorder cannot erase additions; exclusions stay excluded',
    () async {
      final rows = await seed(['S01E01.mkv', 'S01E02.mkv']);
      final id = await create(rows);
      final old = (await store.playlistSnapshot(id)).entries;
      await store.reorderPlaylist(id, old.reversed.map((e) => e.id).toList());
      await store.removePlaylistEntry(id, old.first.id);
      final next = await seed(['S01E01.mkv', 'S01E02.mkv', 'S01E03.mkv']);
      await store.reconcilePlaylists();
      expect((await store.playlistSnapshot(id)).entries.map((e) => e.episode), [
        2,
        3,
      ]);
      await store.reorderPlaylist(id, [old.last.id]);
      expect((await store.playlistSnapshot(id)).entries.map((e) => e.episode), [
        2,
        3,
      ]);
      await store.addPlaylistScope(
        id,
        root.sourceId,
        FilmPlaylistScope.resource(next.firstWhere((r) => r.episode == 1)),
      );
      final restored = await store.playlistSnapshot(id);
      expect(restored.entries.map((e) => e.episode), [2, 3, 1]);
      expect(restored.entries.last.id, old.first.id);
      await expectLater(
        store.addPlaylistScope(
          id,
          'other',
          FilmPlaylistScope.work(next.first.workId!),
        ),
        throwsA(isA<FilmCatalogException>()),
      );
    },
  );
  test(
    'unmapped fixed resource obtains episode identity without duplication or changing ID',
    () async {
      final rows = await seed(['unmapped.mkv']);
      final r = rows.single;
      final id = await store.createPlaylist(
        'Fixed',
        root.sourceId,
        root.sourceKind,
        root.displayName,
        FilmPlaylistScope.resource(r),
      );
      final entry = (await store.playlistSnapshot(id)).entries.single;
      await store.mapEpisodes({r: (1, 1)});
      await store.addPlaylistScope(
        id,
        root.sourceId,
        FilmPlaylistScope.work(r.workId!),
      );
      final updated = (await store.playlistSnapshot(id)).entries.single;
      expect(updated.id, entry.id);
      expect(updated.pinnedPath, r.path);
      expect(updated.episode, 1);
    },
  );
  test(
    'server mirrors preserve repeats and copies survive remote refresh and account changes',
    () async {
      const config = MediaConnection(
        id: 'server',
        kind: MediaSourceKind.jellyfin,
        name: 'Server',
        url: 'http://localhost:8096',
      );
      await store.rememberServerIdentity(config.id, 'host:user');
      await store.saveServerPlaylist(
        config,
        'host:user',
        {'Id': 'p', 'Name': 'Remote'},
        [
          {'Id': 'a', 'Name': 'A'},
          {'Id': 'b', 'Name': 'B'},
          {'Id': 'a', 'Name': 'A'},
        ],
      );
      final list = (await store.playlists(sourceId: config.id)).single;
      final initial = await store.playlistSnapshot(list.id);
      expect(initial.entries.map((e) => e.title), ['A', 'B', 'A']);
      expect(initial.entries.map((e) => e.id).toSet().length, 3);
      expect(initial.entries.every((e) => !e.available), isTrue);
      await expectLater(
        store.reorderPlaylist(
          list.id,
          initial.entries.map((e) => e.id).toList(),
        ),
        throwsA(isA<FilmCatalogException>()),
      );
      final copy = await store.copyPlaylist(list.id, 'Copy');
      await store.saveServerPlaylist(
        config,
        'host:user',
        {'Id': 'p', 'Name': 'Remote'},
        [
          {'Id': 'c', 'Name': 'C'},
        ],
      );
      expect((await store.playlistSnapshot(copy)).entries.map((e) => e.title), [
        'A',
        'B',
        'A',
      ]);
      await store.finishServerPlaylists(config.id, {});
      expect((await store.playlists(sourceId: config.id)).single.id, copy);
      await store.rememberServerIdentity(config.id, 'host:another');
      await store.saveServerPlaylist(
        config,
        'host:another',
        {'Id': 'p', 'Name': 'Remote'},
        [
          {'Id': 'a', 'Name': 'Other'},
        ],
      );
      await store.finishServerPlaylists(config.id, {'p'});
      expect((await store.playlists(sourceId: config.id)).length, 2);
      expect(
        (await store.playlistSnapshot(copy)).entries.every((e) => !e.available),
        isTrue,
      );
      await store.removeServerData(config.id);
      expect((await store.playlists(sourceId: config.id)).single.id, copy);
    },
  );
  test(
    'history retains its original ordered versions after list edits and deletion',
    () async {
      final rows = await seed(['S01E01.mkv', 'S01E02.mkv']);
      final id = await create(rows);
      final snapshot = await store.playlistSnapshot(id);
      final history = PlaybackHistory.fromJson({}).copyWith(
        filmPlaylistId: id,
        filmPlaylistEntryIds: snapshot.entries.map((e) => e.id).toList(),
        queueItems: snapshot.queueItems,
        videoPlaylistMode: VideoPlaylistMode.implicit,
      );
      await store.reorderPlaylist(
        id,
        snapshot.entries.reversed.map((e) => e.id).toList(),
      );
      await store.deletePlaylist(id);
      final saved = PlaybackHistory.fromJson(history.toJson());
      expect(saved.filmPlaylistId, id);
      expect(saved.queueItems.map((e) => e.episode), [1, 2]);
      expect(saved.filmPlaylistEntryIds, snapshot.entries.map((e) => e.id));
      expect(PlaybackHistory.fromJson({}).filmPlaylistId, isNull);
    },
  );
  test(
    'list selections preserve order and version policy without inheriting follow scopes',
    () async {
      final rows = await seed([
        'S00E01.mkv',
        'S01E01-a.mkv',
        'S01E01-b.mkv',
        'S02E01.mkv',
      ]);
      final original = await create(rows);
      final initial = await store.playlistSnapshot(original);
      expect(initial.entries.map((e) => e.season), [1, 2, 0]);
      await store.reorderPlaylist(
        original,
        initial.entries.reversed.map((e) => e.id).toList(),
      );
      final ordered = await store.playlistSnapshot(original);
      Future<String> from(FilmPlaylistScope selection) => store.createPlaylist(
        'Selection',
        root.sourceId,
        root.sourceKind,
        root.displayName,
        selection,
      );
      final scope = FilmPlaylistScope.playlist(ordered.playlist);
      expect(await store.playlistScopeCount(root.sourceId, scope), 3);
      final copy = await from(scope);
      expect(
        (await store.playlistSnapshot(copy)).entries.map((e) => e.season),
        [0, 2, 1],
      );
      final logical = ordered.entries.last;
      final single = await from(
        FilmPlaylistScope.playlist(ordered.playlist, entryId: logical.id),
      );
      final entry = (await store.playlistSnapshot(single)).entries.single;
      expect(entry.versions.length, 2);
      expect(entry.pinnedPath, isNull);
      final pinned = await from(
        FilmPlaylistScope.resource(
          rows.firstWhere((r) => r.name == 'S01E01-b.mkv'),
        ),
      );
      final fixedSnapshot = await store.playlistSnapshot(pinned);
      final fixedCopy = await from(
        FilmPlaylistScope.playlist(
          fixedSnapshot.playlist,
          entryId: fixedSnapshot.entries.single.id,
        ),
      );
      expect(
        (await store.playlistSnapshot(fixedCopy)).entries.single.pinnedPath,
        endsWith('S01E01-b.mkv'),
      );
      await store.addPlaylistScope(pinned, root.sourceId, scope);
      final added = await store.playlistSnapshot(pinned);
      expect(added.entries.map((e) => e.season), [1, 0, 2]);
      expect(added.entries.first.id, fixedSnapshot.entries.single.id);
      expect(added.entries.first.pinnedPath, endsWith('S01E01-b.mkv'));
      await store.removePlaylistEntry(pinned, added.entries[1].id);
      await store.addPlaylistScope(
        pinned,
        root.sourceId,
        FilmPlaylistScope.playlist(
          ordered.playlist,
          entryId: ordered.entries.first.id,
        ),
      );
      expect(
        (await store.playlistSnapshot(pinned)).entries.map((e) => e.season),
        [1, 2, 0],
      );
      expect(
        (await store.playlistSnapshot(pinned)).entries.last.id,
        added.entries[1].id,
      );
      await expectLater(
        store.addPlaylistScope(pinned, 'other', scope),
        throwsA(isA<FilmCatalogException>()),
      );
      await seed([
        'S00E01.mkv',
        'S01E01-a.mkv',
        'S01E01-b.mkv',
        'S02E01.mkv',
        'S03E01.mkv',
      ]);
      expect((await store.playlistSnapshot(original)).entries.length, 4);
      expect((await store.playlistSnapshot(copy)).entries.length, 3);
      expect((await store.playlistSnapshot(single)).entries.length, 1);
      expect((await store.playlistSnapshot(pinned)).entries.length, 3);
    },
  );
  test(
    'mirror selections copy repeats and missing items; additions deduplicate and respect accounts',
    () async {
      const config = MediaConnection(
        id: 'server',
        kind: MediaSourceKind.jellyfin,
        name: 'Server',
        url: 'http://localhost:8096',
      );
      await store.rememberServerIdentity(config.id, 'host:user');
      await store.saveServerPlaylist(
        config,
        'host:user',
        {'Id': 'p', 'Name': 'Remote'},
        [
          {'Id': 'a', 'Name': 'A'},
          {'Id': 'b', 'Name': 'B'},
          {'Id': 'a', 'Name': 'A'},
        ],
      );
      final mirror = (await store.playlists(sourceId: config.id)).single;
      final scope = FilmPlaylistScope.playlist(mirror);
      final copy = await store.createPlaylist(
        'Copy',
        config.id,
        config.kind,
        config.name,
        scope,
      );
      expect((await store.playlistSnapshot(copy)).entries.map((e) => e.title), [
        'A',
        'B',
        'A',
      ]);
      final entries = (await store.playlistSnapshot(copy)).entries;
      final target = await store.copyPlaylist(
        copy,
        'Target',
        entryId: entries[1].id,
      );
      await store.addPlaylistScope(target, config.id, scope);
      expect(
        (await store.playlistSnapshot(target)).entries.map((e) => e.title),
        ['B', 'A'],
      );
      await expectLater(
        store.addPlaylistScope(mirror.id, config.id, scope),
        throwsA(isA<FilmCatalogException>()),
      );
      await store.rememberServerIdentity(config.id, 'host:other');
      await expectLater(
        store.addPlaylistScope(target, config.id, scope),
        throwsA(isA<FilmCatalogException>()),
      );
      expect(
        (await store.playlistSnapshot(target)).entries.map((e) => e.title),
        ['B', 'A'],
      );
    },
  );
  test(
    'list additions keep distinct unmapped resources from the same TV work',
    () async {
      final rows = await seed(['unmapped-a.mkv', 'unmapped-b.mkv']);
      Future<String> single(FilmResource r) => store.createPlaylist(
        r.name,
        root.sourceId,
        root.sourceKind,
        root.displayName,
        FilmPlaylistScope.resource(r),
      );
      final a = await single(rows.first);
      final b = await single(rows.last);
      await store.addPlaylistScope(
        b,
        root.sourceId,
        FilmPlaylistScope.playlist(await store.playlist(a)),
      );
      expect(
        (await store.playlistSnapshot(b)).entries.map((e) => e.pinnedPath),
        [rows.last.path, rows.first.path],
      );
    },
  );
  test(
    'schema 7 migration backs up the database and adds empty playlist tables',
    () async {
      final original = await seed(['S01E01.mkv']);
      await store.close();
      final db = await databaseFactoryFfi.openDatabase(
        '${temp.path}/catalog.db',
      );
      await db.execute('DROP TABLE film_playlist_scopes');
      await db.execute('DROP TABLE film_playlist_items');
      await db.execute('DROP TABLE film_playlists');
      await db.setVersion(7);
      await db.close();
      store = await FilmCatalogStore.open('${temp.path}/catalog.db');
      expect(
        (await store.resources(rootId: root.id)).single.id,
        original.single.id,
      );
      expect(await store.playlists(), isEmpty);
      expect(await create(original), startsWith('custom:'));
      expect(
        temp.listSync().whereType<File>().any((f) => f.path.endsWith('.bak')),
        isTrue,
      );
    },
  );
  test(
    'full database recovery restores playlist order, exclusions and followed ranges',
    () async {
      final rows = await seed(['S01E01.mkv', 'S01E02.mkv']);
      final id = await create(rows);
      final before = (await store.playlistSnapshot(id)).entries;
      await store.reorderPlaylist(
        id,
        before.reversed.map((e) => e.id).toList(),
      );
      await store.removePlaylistEntry(id, before.first.id);
      await store.backupTo('${temp.path}/saved.db');
      await store.deletePlaylist(id);
      await store.restoreBackup('${temp.path}/saved.db');
      expect(
        (await store.playlistSnapshot(id)).entries.single.id,
        before.last.id,
      );
      await seed(['S01E01.mkv', 'S01E02.mkv', 'S01E03.mkv']);
      expect((await store.playlistSnapshot(id)).entries.map((e) => e.episode), [
        2,
        3,
      ]);
    },
  );
  test(
    'local work promotion keeps playlist entry identity and followed scope',
    () async {
      final rows = await seed(['S01E01.mkv']);
      await store.bind(
        rows,
        const FilmWork(
          type: FilmMediaType.tv,
          identityKey: 'local:promotion',
          title: 'Local',
          originalTitle: 'Local',
          overview: '',
          language: 'en',
          metadataOrigin: 'local',
        ),
      );
      final local = (await store.resources()).single;
      await store.mapEpisodes({local: (1, 1)});
      final mapped = (await store.resources()).single;
      final id = await create([mapped]);
      final before = (await store.playlistSnapshot(id)).entries.single;
      await store.bind(
        [mapped],
        const FilmWork(
          type: FilmMediaType.tv,
          tmdbId: 2,
          title: 'Network',
          originalTitle: 'Network',
          overview: '',
          language: 'en',
        ),
      );
      final promoted = (await store.resources()).single;
      await store.mapEpisodes({promoted: (1, 1)});
      final after = (await store.playlistSnapshot(id)).entries.single;
      expect(after.id, before.id);
      expect(after.workId, promoted.workId);
      expect(after.title, 'Network');
    },
  );
}
