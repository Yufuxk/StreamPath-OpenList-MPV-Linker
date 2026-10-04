import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/film_home_section.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/playback_history.dart';
import 'package:streampath/data/models/server_profile.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/iso_playback_service.dart';
import 'package:streampath/domain/services/local_media_source.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/state/app_state.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory temp;
  late FilmCatalogStore store;
  var storeClosed = false;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('film_phase4_');
    store = await FilmCatalogStore.open(p.join(temp.path, 'catalog.db'));
    storeClosed = false;
  });
  tearDown(() async {
    if (!storeClosed) await store.close();
    await temp.delete(recursive: true);
  });

  Future<FilmCatalogRoot> root(String path) async => (await store.root(
    await store.addRoot(
      sourceId: 'local:fixture',
      kind: MediaSourceKind.local,
      path: path,
      type: FilmMediaType.movie,
      name: path,
    ),
  ))!;

  Future<FilmResource> resource(
    FilmCatalogRoot root,
    String name,
    int tmdb, {
    int year = 2024,
    List<String> genres = const ['动画'],
    List<String> countries = const ['JP'],
  }) async {
    final generation = await store.beginScan(root.id);
    await store.stage(root, generation, [
      FilmScanEntry(
        path: '${root.path}/$name',
        parentPath: root.path,
        name: name,
        mediaKind: 'video',
      ),
    ]);
    await store.commitScan(
      root.id,
      generation,
      cancelled: () => false,
      incremental: true,
    );
    final item = (await store.resources(
      rootId: root.id,
    )).singleWhere((r) => r.name == name);
    await store.bind(
      [item],
      FilmWork(
        type: FilmMediaType.movie,
        tmdbId: tmdb,
        title: 'Film $tmdb',
        originalTitle: 'Film $tmdb',
        overview: '',
        language: 'zh-CN',
        posterPath: '/$tmdb.jpg',
        year: year,
        metadata: {'genres': genres, 'origin_country': countries},
      ),
    );
    return (await store.resources(
      rootId: root.id,
    )).singleWhere((r) => r.name == name);
  }

  FilmCatalogController controller({TmdbCredentialStore? credentials}) {
    final tmdb = TmdbMetadataService(credentials: credentials ?? _NoToken());
    return FilmCatalogController(
      store: store,
      tmdb: tmdb,
      images: FilmCatalogImageCache(
        Directory(p.join(temp.path, 'images')),
        tmdb,
      ),
      sourceFor: (_) => LocalMediaSource(
        LocalRootConfig(
          rootId: 'fixture',
          displayName: 'Fixture',
          path: temp.path,
        ),
      ),
    );
  }

  test('v4 观看状态升级保留现有封面与偏好并生成备份', () async {
    final r = await root('Movies');
    final item = await resource(r, 'movie.mkv', 1);
    await store.setFavorite(item.workId!, true);
    await store.setCustomRootCover(r.id, 'fixture.png');
    await store.close();
    final db = await databaseFactoryFfi.openDatabase(store.path);
    await db.execute('DROP TABLE film_watch_state');
    await db.execute('DROP TABLE film_disc_watch_state');
    await db.insert('catalog_preferences', {
      'key': 'fixture',
      'value_json': 'true',
    });
    await db.setVersion(4);
    await db.close();
    store = await FilmCatalogStore.open(store.path);
    expect(await store.isFavorite(item.workId!), isTrue);
    final upgraded = await databaseFactoryFfi.openDatabase(store.path);
    expect(
      (await upgraded.query('root_covers')).single['custom_path'],
      'fixture.png',
    );
    expect(
      (await upgraded.query(
        'catalog_preferences',
        where: 'key=?',
        whereArgs: ['fixture'],
      )).single['value_json'],
      'true',
    );
    expect(await upgraded.query('film_watch_state'), isEmpty);
    expect(await upgraded.getVersion(), 6);
    expect(
      temp.listSync().where((f) => f.path.contains('.before-v5-')),
      hasLength(1),
    );
  });

  test('v3 迁移备份，保留人工关联、收藏、探测与来源封面', () async {
    final r = await root('Movies');
    final item = await resource(r, 'movie.mkv', 1);
    await store.setFavorite(item.workId!, true);
    await store.saveProbe(item.id, {'duration': 7200, 'state': 'complete'});
    await store.chooseRootCover(r.id);
    await store.close();
    final db = await databaseFactoryFfi.openDatabase(store.path);
    await db.execute('DROP TABLE catalog_preferences');
    await db.execute('DROP TABLE film_watch_state');
    await db.execute('DROP TABLE film_disc_watch_state');
    await db.execute('ALTER TABLE root_covers DROP COLUMN custom_path');
    await db.setVersion(3);
    await db.close();
    store = await FilmCatalogStore.open(store.path);
    final restored = (await store.resources()).single;
    expect(
      (restored.id, restored.workId, restored.bindingOrigin),
      (item.id, item.workId, 'manual'),
    );
    expect(await store.isFavorite(item.workId!), isTrue);
    expect(await store.probe(item.id), containsPair('duration', 7200));
    expect(await store.homeSections(), hasLength(8));
    expect(
      temp.listSync().where((f) => f.path.contains('.before-v4-')),
      hasLength(1),
    );
  });

  test('目录改名保留身份，改路径仅重建该根且留下完整备份', () async {
    final a = await root('A'), b = await root('B');
    final first = await resource(a, 'a.mkv', 1),
        second = await resource(b, 'b.mkv', 2);
    final current = (await store.root(a.id))!;
    await store.updateRoot(
      current,
      sourceId: current.sourceId,
      kind: current.sourceKind,
      path: current.path,
      type: current.type,
      name: 'Renamed',
    );
    expect((await store.resources(rootId: a.id)).single.id, first.id);
    expect(
      (await store.resources(rootId: a.id)).single.bindingVersion,
      first.bindingVersion,
    );
    await expectLater(
      store.updateRoot(
        (await store.root(a.id))!,
        sourceId: current.sourceId,
        kind: current.sourceKind,
        path: 'B/sub',
        type: current.type,
        name: 'Overlap',
      ),
      throwsA(isA<FilmCatalogException>()),
    );
    expect((await store.root(a.id))!.path, 'A');
    await store.updateRoot(
      (await store.root(a.id))!,
      sourceId: current.sourceId,
      kind: current.sourceKind,
      path: 'New',
      type: current.type,
      name: 'New',
    );
    expect(await store.resources(rootId: a.id), isEmpty);
    expect((await store.resources(rootId: b.id)).single.id, second.id);
    expect((await store.root(a.id))!.status, 'idle');
    final backups = temp.listSync().whereType<File>().where(
      (f) => f.path.contains('.before-root'),
    );
    expect(backups, hasLength(2));
    final backup = await FilmCatalogStore.open(backups.last.path);
    expect((await backup.resources(rootId: a.id)).single.workId, first.workId);
    await backup.close();
  });

  test('类型地区年代过滤一致，默认关闭且顺序、开关和图片跨重启持久化', () async {
    final r = await root('Movies');
    await resource(r, 'a.mkv', 1);
    await resource(
      r,
      'b.mkv',
      2,
      year: 1998,
      genres: ['科幻'],
      countries: ['US'],
    );
    expect(
      (await store.works(type: null, sectionId: 'genre:动画')).single.tmdbId,
      1,
    );
    expect(
      (await store.works(type: null, sectionId: 'country:US')).single.tmdbId,
      2,
    );
    expect(
      (await store.works(type: null, sectionId: 'decade:1990')).single.tmdbId,
      2,
    );
    final sections = await store.homeSections();
    expect(
      sections.where((s) => s.id.contains(':')).every((s) => !s.enabled),
      isTrue,
    );
    await store.setHomeSections([
      const FilmHomeSection('series', enabled: true),
      const FilmHomeSection('genre:动画', enabled: true),
      ...sections.where((s) => s.id != 'series' && s.id != 'genre:动画'),
    ]);
    await store.setCustomRootCover(r.id, 'custom.img');
    await store.setBackgroundPath('background.img');
    await store.close();
    store = await FilmCatalogStore.open(store.path);
    expect((await store.homeSections()).take(2).map((s) => s.id), [
      'series',
      'genre:动画',
    ]);
    expect((await store.homeSections())[1].enabled, isTrue);
    expect(await store.customRootCover(r.id), 'custom.img');
    expect(await store.backgroundPath(), 'background.img');
    await store.setCustomRootCover(r.id, null);
    await store.setBackgroundPath(null);
    expect(await store.customRootCover(r.id), isNull);
    expect(await store.backgroundPath(), isEmpty);
  });

  test('筛选首帧撤下旧作品，同筛选刷新保留现有作品，过期查询不覆盖最新结果', () async {
    final a = await root('A'), b = await root('B');
    await resource(a, 'a.mkv', 1);
    await resource(b, 'b.mkv', 2);
    final c = controller();
    await c.refresh();
    expect(c.works, hasLength(2));
    final refresh = c.refresh();
    expect(c.works, hasLength(2));
    await refresh;
    c.rootId = a.id;
    final first = c.refresh();
    expect(c.works, isEmpty);
    c.rootId = b.id;
    final second = c.refresh();
    expect(c.works, isEmpty);
    await Future.wait([first, second]);
    expect(c.works.single.tmdbId, 2);
    await c.close();
    storeClosed = true;
  });

  test('多个目录串行全量和增量扫描仅枚举名称，取消准备阶段不启动后续根', () async {
    final a = await root('A'), b = await root('B');
    for (final path in ['A/a.mkv', 'B/b.mkv']) {
      final file = File(p.join(temp.path, path));
      await file.parent.create(recursive: true);
      await file.writeAsBytes([]);
    }
    final token = _DelayedToken();
    final c = controller(credentials: token);
    final cancelled = c.scanRoots([a, b]);
    await token.started.future;
    c.cancel();
    token.release.complete();
    await cancelled;
    expect(await store.resources(), isEmpty);
    expect((await store.root(b.id))!.generation, 0);
    await c.scanRoots([a, b]);
    expect((await store.resources()).map((r) => r.name).toSet(), {
      'a.mkv',
      'b.mkv',
    });
    final ids = (await store.resources()).map((r) => r.id).toSet();
    await File(p.join(temp.path, 'A', 'c.mkv')).writeAsBytes([]);
    await c.scanRoots([a, b], incremental: true);
    expect(await store.resources(), hasLength(3));
    expect(
      (await store.resources()).map((r) => r.id).toSet().containsAll(ids),
      isTrue,
    );
    await c.close();
    storeClosed = true;
  });

  test('同来源影视会话可保留 50 条，51 条拒绝，旧会话仍限两条', () async {
    final browser = PlaybackHistoryStore.forPath(
      p.join(temp.path, 'history.json'),
    );
    final films = browser.forFilmLibrary();
    PlaybackHistory history(int i) => PlaybackHistory(
      sessionId: '$i',
      sourceId: 'source',
      dirCrumbs: const [],
      fileName: '$i.mkv',
      videoIndex: 0,
      updatedAt: DateTime.now(),
    );
    expect(await browser.upsert(history(1)), isTrue);
    expect(await browser.upsert(history(2)), isTrue);
    expect(await browser.upsert(history(3)), isFalse);
    for (var i = 1; i <= 50; i++) {
      expect(await films.upsert(history(i)), isTrue);
    }
    expect(await films.upsert(history(51)), isFalse);
    expect(await browser.forFilmLibrary().loadAll(), hasLength(50));
    final old = MediaLibraryStore.forPath(p.join(temp.path, 'records.json'));
    final records = old.forFilmLibrary();
    expect(records.config.maxContinuePerLane, 50);
    for (var i = 1; i <= 50; i++) {
      await records.recordPlayback(
        MediaLibraryItem(
          sourceId: 'source',
          parentPath: '',
          name: '$i.mkv',
          kind: MediaLibraryKind.video,
        ),
        playbackSessionId: '$i',
      );
    }
    expect(
      await records.playbackHistory('source', audio: false),
      hasLength(50),
    );
    expect(await old.playbackHistory('source', audio: false), isEmpty);
  });

  test('进度首次迁移仅复制影视引用，写入、清空与重启均独立', () async {
    final browser = await PlaybackProgressService.open(
      p.join(temp.path, 'streampath.db'),
    );
    for (final path in ['film', 'browser']) {
      await browser.saveProgress(
        url: path,
        profileId: 'source',
        positionMs: 5000,
        durationMs: 60000,
      );
    }
    var films = await browser.forFilmLibrary({('source', 'film')});
    expect(
      (await films.getProgress('film', profileId: 'source'))!.positionMs,
      5000,
    );
    expect(await films.getProgress('browser', profileId: 'source'), isNull);
    await films.saveProgress(
      url: 'film',
      profileId: 'source',
      positionMs: 9000,
      durationMs: 60000,
    );
    expect(
      (await browser.getProgress('film', profileId: 'source'))!.positionMs,
      5000,
    );
    await films.close();
    await browser.saveProgress(
      url: 'film',
      profileId: 'source',
      positionMs: 15000,
      durationMs: 60000,
    );
    films = await browser.forFilmLibrary({
      ('source', 'film'),
      ('source', 'browser'),
    });
    expect(
      (await films.getProgress('film', profileId: 'source'))!.positionMs,
      9000,
    );
    expect(await films.getProgress('browser', profileId: 'source'), isNull);
    await films.clearAll();
    expect(
      (await browser.getProgress('film', profileId: 'source'))!.positionMs,
      15000,
    );
    await films.close();
    await browser.close();
  });

  test('未挂载网络和停用本地来源的影视进度仍迁移，已关闭 ISO 记录保留选择', () async {
    final config = StreamPathConfigStore.forPath(
      p.join(temp.path, 'config.json'),
    );
    await config.save(
      StreamPathConfig(
        profiles: [
          const ServerProfile(
            profileId: 'remote',
            name: 'Remote',
            serverUrl: 'https://media.invalid/dav',
            username: 'fixture',
          ),
        ],
        credentialStorageMode: CredentialStorageMode.portablePlaintext,
        localRoots: [
          LocalRootConfig(
            rootId: 'disabled',
            displayName: 'Local',
            path: temp.path,
            enabled: false,
          ),
        ],
      ),
    );
    final oldProgress = await PlaybackProgressService.open(
      p.join(temp.path, 'streampath.db'),
    );
    final oldIsoRoot = await Directory(p.join(temp.path, 'iso_temp')).create();
    final iso = IsoPlaybackService(
      configStore: config,
      tempRootProvider: () async => oldIsoRoot,
    );
    final app = AppState(
      configStore: config,
      progressService: oldProgress,
      isoPlaybackService: iso,
      playbackHistoryStore: PlaybackHistoryStore.forPath(
        p.join(temp.path, 'history.json'),
      ),
      mediaLibraryStore: MediaLibraryStore.forPath(
        p.join(temp.path, 'records.json'),
      ),
    );
    const remote = MediaLibraryItem(
      sourceId: 'remote',
      parentPath: 'Films',
      name: 'film.mkv',
      kind: MediaLibraryKind.video,
    );
    const local = MediaLibraryItem(
      sourceId: 'local:disabled',
      sourceKind: MediaSourceKind.local,
      parentPath: '',
      name: 'local.mkv',
      kind: MediaLibraryKind.video,
    );
    const disc = MediaLibraryItem(
      sourceId: 'remote',
      parentPath: 'Films',
      name: 'disc.iso',
      kind: MediaLibraryKind.iso,
    );
    for (final item in [remote, local, disc]) {
      await app.filmMediaLibraryStore!.recordPlayback(item);
      await oldProgress.saveProgress(
        url: app.resolveMediaLibraryTarget(item, allowLogicalPath: true)!,
        profileId: item.sourceId,
        positionMs: 9000,
        durationMs: 60000,
      );
    }
    final key = IsoPlaybackService.libraryKey(
      profileId: 'remote',
      resolvedUrl: 'https://media.invalid/dav/Films/disc.iso',
    );
    await File(p.join(temp.path, 'iso_catalog.json')).writeAsString(
      '{"version":1,"discs":{"$key":{"order":["00001"],"selected":["00001"]}}}',
    );
    await app.initializeFilmPlayback();
    for (final item in [remote, local]) {
      final url = app.resolveMediaLibraryTarget(item, allowLogicalPath: true)!;
      expect(
        (await app.filmProgressService.getProgress(
          url,
          profileId: item.sourceId,
        ))!.positionMs,
        9000,
      );
    }
    expect(await app.filmPlaybackHistoryStore.loadAll(), isEmpty);
    expect(
      await File(p.join(temp.path, 'film_iso_catalog.json')).readAsString(),
      contains(key),
    );
    app.dispose();
    await oldProgress.close();
    await Future<void>.delayed(const Duration(milliseconds: 30));
  });

  test('ISO 资料与 watch_later 只迁移引用条目，后续更新不重播迁移', () async {
    final config = StreamPathConfigStore.forPath(
      p.join(temp.path, 'config.json'),
    );
    final oldRoot = Directory(p.join(temp.path, 'iso_temp'));
    await oldRoot.create();
    final key = 'a' * 64, other = 'b' * 64;
    final old = File(p.join(temp.path, 'iso_catalog.json'));
    await old.writeAsString(
      '{"version":1,"discs":{"$key":{"order":["00001"],"selected":["00001"]},"$other":{"order":["00002"],"selected":["00002"]}}}',
    );
    final watch = File(p.join(temp.path, 'iso_watch_later', key, 'resume'));
    await watch.parent.create(recursive: true);
    await watch.writeAsString('start=5');
    final service = IsoPlaybackService(
      configStore: config,
      tempRootProvider: () async => oldRoot,
    );
    final film = await service.forFilmLibrary(config, {key});
    expect(
      await File(p.join(temp.path, 'film_iso_catalog.json')).readAsString(),
      contains('00001'),
    );
    expect(
      await File(p.join(temp.path, 'film_iso_catalog.json')).readAsString(),
      isNot(contains(other)),
    );
    final copied = File(
      p.join(temp.path, 'film_iso_watch_later', key, 'resume'),
    );
    expect(await copied.readAsString(), 'start=5');
    await copied.writeAsString('start=9');
    expect(await watch.readAsString(), 'start=5');
    film.dispose();
    final reopened = await service.forFilmLibrary(config, {key, other});
    expect(await copied.readAsString(), 'start=9');
    expect(
      await File(p.join(temp.path, 'film_iso_catalog.json')).readAsString(),
      isNot(contains(other)),
    );
    reopened.dispose();
    service.dispose();
  });
}

class _NoToken extends TmdbCredentialStore {
  @override
  Future<String?> read() async => null;
}

class _DelayedToken extends _NoToken {
  final started = Completer<void>(), release = Completer<void>();
  @override
  Future<String?> read() async {
    if (!started.isCompleted) {
      started.complete();
      await release.future;
    }
    return null;
  }
}
