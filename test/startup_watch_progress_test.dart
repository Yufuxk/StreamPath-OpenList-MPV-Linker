import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/directory_cache.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/film_watch_state.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/server_profile.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/presentation/state/app_state.dart';

class _CountingCache extends DirectoryCache {
  final calls = <String, int>{};
  final snapshots = <String, List<VisitedDirectorySnapshot>>{};

  @override
  List<VisitedDirectorySnapshot> visitedDirectories(String sourceId) {
    calls.update(sourceId, (count) => count + 1, ifAbsent: () => 1);
    return snapshots[sourceId] ?? const [];
  }

  @override
  Future<List<VisitedDirectorySnapshot>> visitedDirectoriesAsync(
    String sourceId,
  ) async => visitedDirectories(sourceId);

  @override
  WebDavFile? visitedFile(MediaLibraryItem item) =>
      (snapshots[item.sourceId] ?? [])
          .where(
            (s) => normalizeLibraryPath(s.path) == item.normalizedParentPath,
          )
          .expand((s) => s.entries)
          .where(item.matches)
          .firstOrNull;
}

void main() {
  setUpAll(sqfliteFfiInit);

  test('启动导入按来源异步复用目录快照，保留最新 href、路径回退和观看进度', () async {
    final temp = await Directory.systemTemp.createTemp('startup_watch_');
    final store = await FilmCatalogStore.open(p.join(temp.path, 'catalog.db'));
    final progress = await PlaybackProgressService.open(
      p.join(temp.path, 'progress.db'),
    );
    final config = StreamPathConfigStore.forPath(
      p.join(temp.path, 'config.json'),
    );
    await config.save(
      StreamPathConfig(
        profiles: [
          for (final source in ['a', 'b'])
            ServerProfile(
              profileId: source,
              name: source,
              serverUrl: 'https://$source.invalid/dav/',
              username: '',
              password: '',
            ),
        ],
      ),
    );
    final cache = _CountingCache();
    final app = AppState(
      configStore: config,
      progressService: progress,
      playbackHistoryStore: PlaybackHistoryStore.forPath(
        p.join(temp.path, 'history.json'),
      ),
      directoryCache: cache,
    );
    try {
      for (final source in ['a', 'b']) {
        final id = await store.addRoot(
          sourceId: source,
          kind: MediaSourceKind.webdav,
          path: 'Shows',
          type: FilmMediaType.tv,
          name: source,
        );
        final root = (await store.root(id))!;
        final generation = await store.beginScan(id);
        await store.stage(root, generation, [
          for (var i = 1; i <= 140; i++)
            FilmScanEntry(
              path: 'Shows/Season/e$i.mkv',
              parentPath: 'Shows/Season',
              name: 'e$i.mkv',
              mediaKind: 'video',
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
        await store.mapEpisodes({
          for (final r in await store.resources(rootId: id))
            r: (1, int.parse(r.name.substring(1, r.name.indexOf('.')))),
        });
        cache.snapshots[source] = [
          VisitedDirectorySnapshot(
            path: '/Shows\\Season/',
            lastAccessedAt: DateTime.utc(2026, 1, 2),
            entries: [
              for (var i = 1; i <= 139; i++)
                WebDavFile(
                  name: 'e$i.mkv',
                  href: '/canonical/e$i.mkv',
                  isDirectory: false,
                ),
            ],
          ),
          VisitedDirectorySnapshot(
            path: 'Shows/Season',
            lastAccessedAt: DateTime.utc(2026, 1, 1),
            entries: const [
              WebDavFile(
                name: 'e1.mkv',
                href: '/older/e1.mkv',
                isDirectory: false,
              ),
            ],
          ),
        ];
        for (var i = 1; i <= 140; i++) {
          await progress.saveProgress(
            url: i == 140
                ? 'https://$source.invalid/dav/Shows/Season/e140.mkv'
                : 'https://$source.invalid/canonical/e$i.mkv',
            profileId: source,
            positionMs: (source == 'a' ? 100 : 200) * i,
            durationMs: 60000,
          );
        }
      }
      await app.importFilmWatchProgress(store);
      expect(cache.calls, {'a': 1, 'b': 1});
      for (final r in await store.resources()) {
        final state = (await store.resourceWatchState(r))!;
        expect(state.status, FilmWatchStatus.inProgress);
        expect(
          state.fraction,
          (r.sourceId == 'a' ? 100 : 200) * r.episode! / 60000,
        );
      }
      // 下一次导入使用新快照，单条解析也读取当前缓存。
      cache.snapshots['a']!.first.entries[0] = const WebDavFile(
        name: 'e1.mkv',
        href: '/updated/e1.mkv',
        isDirectory: false,
      );
      await progress.saveProgress(
        url: 'https://a.invalid/updated/e1.mkv',
        profileId: 'a',
        positionMs: 30000,
        durationMs: 60000,
      );
      await app.importFilmWatchProgress(store);
      expect(cache.calls, {'a': 2, 'b': 2});
      final first = (await store.resourceAt('a', 'Shows/Season/e1.mkv'))!;
      expect((await store.resourceWatchState(first))!.fraction, 0.5);
      expect(
        app.resolveMediaLibraryTarget(first.playbackItem),
        'https://a.invalid/updated/e1.mkv',
      );
    } finally {
      app.dispose();
      await progress.close();
      await store.close();
      await temp.delete(recursive: true);
    }
  });
}
