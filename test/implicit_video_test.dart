import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/models/server_profile.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/data/local/directory_cache.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'dart:io';
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/data/models/media_entry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/film_watch_state.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/playback_history.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/data/models/video_playlist_mode.dart';
import 'package:streampath/data/models/video_queue.dart';
import 'package:streampath/domain/services/film_video_timeline.dart';

FilmResource resource(int season, int episode, {String? path}) =>
    FilmResource.fromRow({
      'id': episode,
      'root_id': 1,
      'source_id': 'dav',
      'source_kind': 'webdav',
      'media_type': 'tv',
      'root_path': 'Show',
      'display_name': 'Show',
      'relative_path': path ?? 'Show/S${season}E$episode.mkv',
      'path_key': path ?? 'Show/S${season}E$episode.mkv',
      'parent_path': 'Show',
      'name': path ?? 'S${season}E$episode.mkv',
      'media_kind': 'video',
      'availability': 'present',
      'work_id': 1,
      'binding_origin': 'manual',
      'binding_version': 1,
      'season_number': season,
      'episode_number': episode,
      'episode_mapping_origin': 'manual',
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  test('自动版本选择优先同根及同目录分支，旧快照仍可读取', () {
    const previous = VideoQueueVersion(
      path: 'B/Show/Season1/E1.mkv',
      name: 'E1.mkv',
      rootId: 2,
    );
    const same = VideoQueueVersion(
      path: 'B/Show/Season2/E2.mkv',
      name: 'E2.mkv',
      rootId: 2,
    );
    const item = VideoQueueItem(
      versions: [
        VideoQueueVersion(
          path: 'A/Show/Season2/E2.mkv',
          name: 'E2.mkv',
          rootId: 1,
        ),
        VideoQueueVersion(
          path: 'B/Other/Season2/E2.mkv',
          name: 'E2.mkv',
          rootId: 2,
        ),
        same,
      ],
    );
    expect(item.orderedVersions(previous).first, same);
    expect(VideoQueueItem.fromJson(item.toJson()).versions.last.rootId, 2);
    final old = VideoQueueItem.fromJson({
      'versions': [
        {'path': 'B/Show/Season1/E1.mkv', 'name': 'E1.mkv'},
      ],
    });
    expect(old.versions.single.rootId, isNull);
    expect(item.orderedVersions(old.versions.single).first, same);
  });
  test('自动选源仅在准备失败后尝试下一版本，并保留最后失败', () async {
    const first = VideoQueueVersion(
      path: 'A/E2.mkv',
      name: 'E2.mkv',
      rootId: 1,
    );
    const second = VideoQueueVersion(
      path: 'B/E2.mkv',
      name: 'E2.mkv',
      rootId: 2,
    );
    const item = VideoQueueItem(versions: [first, second]);
    final calls = <String>[];
    Future<PreparedVideoItem> good(VideoQueueVersion v) async {
      calls.add(v.path);
      return PreparedVideoItem(entry: MediaEntry(url: v.path));
    }

    expect((await item.prepareVersion(good, preferred: second)).$1, second);
    expect(calls, ['B/E2.mkv']);
    calls.clear();
    expect(
      (await item.prepareVersion((v) async {
        calls.add(v.path);
        if (v == second) throw AppException.network('Connection failed');
        return PreparedVideoItem(entry: MediaEntry(url: v.path));
      }, preferred: second)).$1,
      first,
    );
    expect(calls, ['B/E2.mkv', 'A/E2.mkv']);
    await expectLater(
      item.prepareVersion((v) async => throw AppException.network(v.path)),
      throwsA(
        isA<NetworkException>().having(
          (e) => e.message,
          'last failure',
          'B/E2.mkv',
        ),
      ),
    );
    calls.clear();
    await expectLater(
      item.prepareVersion((v) async {
        calls.add(v.path);
        throw StateError('Broken invariant');
      }),
      throwsStateError,
    );
    expect(calls, ['A/E2.mkv']);
  });
  test('缓存准备结果不能绕过停用来源检查，全部不可用明确失败', () async {
    const first = VideoQueueVersion(
      path: 'A/E2.mkv',
      name: 'E2.mkv',
      rootId: 1,
    );
    const second = VideoQueueVersion(
      path: 'B/E2.mkv',
      name: 'E2.mkv',
      rootId: 2,
    );
    const item = VideoQueueItem(versions: [first, second]);
    final cached = {
      'A/E2.mkv': const PreparedVideoItem(entry: MediaEntry(url: 'cached')),
    };
    final calls = <String>[];
    Future<PreparedVideoItem> prepare(VideoQueueVersion v) async {
      calls.add(v.path);
      return PreparedVideoItem(entry: MediaEntry(url: v.path));
    }

    expect(
      (await item.prepareVersion(
        prepare,
        preferred: first,
        cached: cached,
        isAvailable: (v) async => v.rootId == 2,
      )).$1,
      second,
    );
    expect(calls, ['B/E2.mkv']);
    calls.clear();
    await expectLater(
      item.prepareVersion(
        prepare,
        cached: cached,
        isAvailable: (_) async => false,
      ),
      throwsA(isA<ConfigException>()),
    );
    expect(calls, isEmpty);
    expect(
      (await item.prepareVersion(prepare, excluded: {'A/E2.mkv'})).$1,
      second,
    );
  });
  test('新配置默认隐式，旧会话保持传统；队列快照与待播目标往返', () {
    expect(
      StreamPathConfig.fromJson({}).videoPlaylistMode,
      VideoPlaylistMode.implicit,
    );
    final old = PlaybackHistory.fromJson({});
    expect(old.videoPlaylistMode, VideoPlaylistMode.legacy);
    final history = old.copyWith(
      videoPlaylistMode: VideoPlaylistMode.implicit,
      pendingVideoIndex: 1,
      queueItems: [
        const VideoQueueItem(
          versions: [VideoQueueVersion(path: 'a', name: 'a')],
          season: 0,
          episode: 1,
        ),
      ],
    );
    final read = PlaybackHistory.fromJson(history.toJson());
    expect(read.queueItems.single.season, 0);
    expect(read.pendingVideoIndex, 1);
  });
  test('按每集日期插入 S00；同日季集排序，缺日期尾排，版本归组', () {
    final resources = [
      resource(1, 4),
      resource(1, 5),
      resource(0, 1),
      resource(1, 6),
      resource(0, 2),
      resource(1, 5, path: 'Show/alternate.mkv'),
    ];
    final items = buildFilmVideoTimeline(
      resources,
      {
        1: {
          'episodes': [
            {'episode_number': 4, 'air_date': '2024-01-04'},
            {'episode_number': 5, 'air_date': '2024-01-06'},
            {'episode_number': 6, 'air_date': '2024-01-06'},
          ],
        },
        0: {
          'episodes': [
            {'episode_number': 1, 'air_date': '2024-01-05'},
          ],
        },
      },
      selectedPath: resources.first.path,
      autoSeason: true,
      allowGap: false,
    );
    expect(items.map((i) => (i.season, i.episode)), [
      (1, 4),
      (0, 1),
      (1, 5),
      (1, 6),
      (0, 2),
    ]);
    expect(items[2].versions.length, 2);
    expect(parseAirDate('2024-02-31'), isNull);
  });
  test('关闭切季和禁止缺季限制正季段，S00 按开播季归属', () {
    final resources = [
      resource(1, 1),
      resource(2, 1),
      resource(4, 1),
      resource(0, 1),
      resource(0, 2),
    ];
    final seasons = {
      1: {'air_date': '2024-01-01'},
      2: {'air_date': '2024-02-01'},
      4: {'air_date': '2024-04-01'},
      0: {
        'episodes': [
          {'episode_number': 1, 'air_date': '2024-02-02'},
          {'episode_number': 2, 'air_date': '2024-04-02'},
        ],
      },
    };
    List<VideoQueueItem> build(bool auto, bool gap, String path) =>
        buildFilmVideoTimeline(
          resources,
          seasons,
          selectedPath: path,
          autoSeason: auto,
          allowGap: gap,
        );
    expect(
      build(false, false, resources[3].path).map((i) => i.season).toSet(),
      {0, 2},
    );
    expect(
      build(true, false, resources.first.path).map((i) => i.season).toSet(),
      {0, 1, 2},
    );
    expect(
      build(true, true, resources.first.path).map((i) => i.season).toSet(),
      {0, 1, 2, 4},
    );
  });
  test(
    'undated seasons keep episode order and place S00 after all regular seasons',
    () {
      final resources = [
        resource(0, 2),
        resource(4, 1),
        resource(2, 1),
        resource(1, 2),
        resource(0, 1),
        resource(3, 1),
        resource(1, 1),
      ];
      final expected = [(1, 1), (1, 2), (2, 1), (3, 1), (4, 1), (0, 1), (0, 2)];
      expect(
        buildFilmVideoOrder(resources, {}).map((i) => (i.season, i.episode)),
        expected,
      );
      expect(
        buildFilmVideoTimeline(
          resources,
          {},
          selectedPath: resources[3].path,
          autoSeason: true,
          allowGap: true,
        ).map((i) => (i.season, i.episode)),
        expected,
      );
      final dated = buildFilmVideoOrder(resources, {
        0: {
          'episodes': [
            {'episode_number': 1, 'air_date': '2024-01-01'},
          ],
        },
        1: {
          'episodes': [
            {'episode_number': 1, 'air_date': '2024-01-01'},
          ],
        },
      });
      expect(dated.map((i) => (i.season, i.episode)), [
        (0, 1),
        (1, 1),
        (1, 2),
        (2, 1),
        (3, 1),
        (4, 1),
        (0, 2),
      ]);
    },
  );
  test('人工季标记清理两媒体中心的全部版本续播，推进目标且新加入剧集默认未看', () async {
    final dir = await Directory.systemTemp.createTemp('implicit_manual_');
    final store = await FilmCatalogStore.open(p.join(dir.path, 'catalog.db'));
    final config = StreamPathConfigStore.forPath(
      p.join(dir.path, 'config.json'),
    );
    await config.save(
      StreamPathConfig(
        profiles: const [
          ServerProfile(
            profileId: 'a',
            name: 'fixture',
            serverUrl: 'http://fixture/dav',
          ),
        ],
      ),
    );
    final progress = await PlaybackProgressService.open(
      p.join(dir.path, 'progress.db'),
      factory: databaseFactoryFfi,
    );
    final cache = _WatchCache();
    final app = _WatchApp(
      store,
      configStore: config,
      playbackHistoryStore: PlaybackHistoryStore.forPath(
        p.join(dir.path, 'history.json'),
      ),
      mediaLibraryStore: MediaLibraryStore.forPath(
        p.join(dir.path, 'library.json'),
      ),
      progressService: progress,
      directoryCache: cache,
    );
    try {
      await app.initializeFilmPlayback();
      final root = (await store.root(
        await store.addRoot(
          sourceId: 'a',
          kind: MediaSourceKind.webdav,
          path: 'Show',
          type: FilmMediaType.tv,
          name: 'Show',
        ),
      ))!;
      final generation = await store.beginScan(root.id);
      await store.stage(root, generation, [
        for (final name in ['one.mkv', 'version.mkv', 'two.mkv', 'three.mkv'])
          FilmScanEntry(
            path: 'Show/$name',
            parentPath: 'Show',
            name: name,
            mediaKind: 'video',
          ),
      ]);
      await store.commitScan(root.id, generation, cancelled: () => false);
      final rows = await store.resources();
      await store.bind(
        rows,
        const FilmWork(
          type: FilmMediaType.tv,
          tmdbId: 101,
          title: 'Show',
          originalTitle: 'Show',
          overview: '',
          language: 'zh-CN',
          metadata: {},
        ),
      );
      await store.mapEpisodes({
        for (final row in await store.resources())
          row: (row.name == 'three.mkv' ? 2 : 1, row.name == 'two.mkv' ? 2 : 1),
      });
      final resources = await store.resources();
      final first = resources.firstWhere((r) => r.name == 'one.mkv');
      final second = resources.firstWhere((r) => r.name == 'two.mkv');
      final third = resources.firstWhere((r) => r.name == 'three.mkv');
      for (final history in [
        app.playbackHistoryStore,
        app.filmPlaybackHistoryStore,
      ]) {
        await history.upsert(
          PlaybackHistory(
            sessionId: 'queue',
            sourceId: 'a',
            dirCrumbs: const ['Show'],
            fileName: first.name,
            videoIndex: 0,
            updatedAt: DateTime.now(),
            playlistRelativePaths: [first.path, second.path, third.path],
            playlistFileNames: [first.name, second.name, third.name],
            videoPlaylistMode: VideoPlaylistMode.implicit,
          ),
        );
      }
      for (final progressStore in [progress, app.filmProgressService]) {
        for (final row in resources) {
          final url = 'http://fixture/dav/${row.path}';
          await progressStore.saveProgress(
            url: url,
            profileId: 'a',
            positionMs: 50,
            durationMs: 100,
          );
          await progressStore.saveTemporaryProgress(
            url: url,
            profileId: 'a',
            positionMs: 55,
            durationMs: 100,
          );
        }
      }
      final season = resources.where((r) => r.season == 1).toList();
      await app.markFilmWatched(season, true);
      expect(cache.calls, 1);
      for (final row in season) {
        expect(
          (await store.resourceWatchState(row))!.status,
          FilmWatchStatus.watched,
        );
        for (final progressStore in [progress, app.filmProgressService]) {
          expect(
            await progressStore.getResumeProgress(
              'http://fixture/dav/${row.path}',
              profileId: 'a',
            ),
            isNull,
          );
        }
      }
      for (final histories in [
        app.playbackHistoryStore,
        app.filmPlaybackHistoryStore,
      ]) {
        expect((await histories.loadAll()).single.videoIndex, 2);
      }
      expect(
        (await store.resourceWatchState(third))!.status,
        FilmWatchStatus.unwatched,
      );
      final reset = (await store.manualWatchResetAt('a', first.path))!;
      await store.recordVideoProgress(
        VideoProgressUpdate(
          sourceId: 'a',
          path: first.path,
          positionMs: 80,
          durationMs: 100,
          recordedAt: reset.subtract(const Duration(seconds: 1)),
        ),
      );
      expect(
        (await store.resourceWatchState(first))!.status,
        FilmWatchStatus.watched,
      );
      cache.rows.first['href'] = '/updated/one.mkv';
      for (final progressStore in [progress, app.filmProgressService]) {
        await progressStore.saveProgress(
          url: 'http://fixture/updated/one.mkv',
          profileId: 'a',
          positionMs: 50,
          durationMs: 100,
        );
      }
      await app.markFilmWatched([first], false);
      expect(cache.calls, 2);
      for (final progressStore in [progress, app.filmProgressService]) {
        expect(
          await progressStore.getResumeProgress(
            'http://fixture/updated/one.mkv',
            profileId: 'a',
          ),
          isNull,
        );
      }
      expect(
        (await store.resourceWatchState(
          resources.firstWhere((r) => r.name == 'version.mkv'),
        ))!.status,
        FilmWatchStatus.unwatched,
      );
      expect(
        (await store.resourceWatchState(second))!.status,
        FilmWatchStatus.watched,
      );
    } finally {
      await app.filmProgressService.close();
      app.dispose();
      await progress.close();
      await store.close();
      await dir.delete(recursive: true);
    }
  });

  test('观看状态按集跨版本共享、来源隔离、人工时间边界和重新刮削保持', () async {
    final dir = await Directory.systemTemp.createTemp('implicit_watch_');
    final store = await FilmCatalogStore.open(p.join(dir.path, 'catalog.db'));
    try {
      final work = FilmWork(
        id: 0,
        type: FilmMediaType.tv,
        tmdbId: 12,
        title: 'Show',
        originalTitle: 'Show',
        overview: '',
        language: 'zh-CN',
        metadata: const {},
        fetchedAt: 1,
      );
      for (final source in ['a', 'b']) {
        final root = (await store.root(
          await store.addRoot(
            sourceId: source,
            kind: MediaSourceKind.webdav,
            path: 'Show',
            type: FilmMediaType.tv,
            name: source,
          ),
        ))!;
        final generation = await store.beginScan(root.id);
        await store.stage(root, generation, [
          for (final name in [
            'one.mkv',
            'two.mkv',
            'version.mkv',
            'special.mkv',
          ])
            FilmScanEntry(
              path: 'Show/$name',
              parentPath: 'Show',
              name: name,
              mediaKind: 'video',
            ),
        ]);
        await store.commitScan(root.id, generation, cancelled: () => false);
        await store.bind(await store.resources(rootId: root.id), work);
        final rows = await store.resources(rootId: root.id);
        await store.mapEpisodes({
          for (final row in rows)
            row: row.name == 'special.mkv'
                ? (0, 1)
                : (1, row.name == 'two.mkv' ? 2 : 1),
        });
      }
      final a = (await store.resourceAt('a', 'Show/one.mkv'))!;
      final version = (await store.resourceAt('a', 'Show/version.mkv'))!;
      final b = (await store.resourceAt('b', 'Show/one.mkv'))!;
      final time = DateTime.now();
      await store.recordVideoProgress(
        VideoProgressUpdate(
          sourceId: 'a',
          path: a.path,
          positionMs: 500,
          durationMs: 1000,
          recordedAt: time,
        ),
      );
      expect((await store.resourceWatchState(version))!.fraction, .5);
      expect(
        (await store.resourceWatchState(b))!.status,
        FilmWatchStatus.unwatched,
      );
      expect(
        (await store.workWatchStates([a.workId!]))[a.workId]!.fraction,
        .25,
      );
      await store.markWatched([a], true);
      await store.recordVideoProgress(
        VideoProgressUpdate(
          sourceId: 'a',
          path: a.path,
          positionMs: 100,
          durationMs: 1000,
          recordedAt: time,
        ),
      );
      expect(
        (await store.resourceWatchState(version))!.status,
        FilmWatchStatus.watched,
      );
      await store.refreshWork(work);
      expect(
        (await store.resourceWatchState(version))!.status,
        FilmWatchStatus.watched,
      );
      await store.recordVideoProgress(
        VideoProgressUpdate(
          sourceId: 'a',
          path: a.path,
          positionMs: 10,
          durationMs: 1000,
          recordedAt: DateTime.now().add(const Duration(seconds: 1)),
        ),
      );
      expect(
        (await store.resourceWatchState(a))!.status,
        FilmWatchStatus.watched,
      );
      await store.markWatched([a], false);
      expect(
        (await store.resourceWatchState(a))!.status,
        FilmWatchStatus.unwatched,
      );
    } finally {
      await store.close();
      await dir.delete(recursive: true);
    }
  });
}

class _WatchApp extends AppState {
  _WatchApp(
    this.store, {
    required super.configStore,
    required super.playbackHistoryStore,
    required super.progressService,
    super.mediaLibraryStore,
    super.directoryCache,
  });
  final FilmCatalogStore store;
  @override
  Future<FilmCatalogStore> getFilmCatalogStore() async => store;
}

class _WatchCache extends DirectoryCache {
  var calls = 0;
  final rows = [
    for (final name in [
      'one.mkv',
      'version.mkv',
      'two.mkv',
      'three.mkv',
      for (var i = 0; i < 1910; i++) 'unrelated$i.mkv',
    ])
      WebDavFile(
        name: name,
        href: '/dav/Show/$name',
        isDirectory: false,
        modified: DateTime.utc(2026, 1, 1),
      ).toCacheMap(),
  ];

  @override
  List<VisitedDirectorySnapshot> visitedDirectories(String sourceId) {
    calls++;
    final result = [
      VisitedDirectorySnapshot(
        path: 'Show',
        entries: rows.map(WebDavFile.fromCacheMap).toList(),
        lastAccessedAt: DateTime.utc(2026, 1, 2),
      ),
    ];
    return result;
  }
}
