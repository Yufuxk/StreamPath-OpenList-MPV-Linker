import '../../data/local/film_catalog_store.dart';
import '../../data/models/film_catalog_item.dart';
import 'media_server_api.dart';

/// 分页导入服务器已有资料，完整成功后才判定缺失资源。
class MediaServerLibrary {
  MediaServerLibrary(this.store, this.api);
  final FilmCatalogStore store;
  final MediaServerApi api;
  Future<void>? _running;
  bool _closed = false;
  Future<void> waitForIdle() async => await _running;
  Future<void> refresh() =>
      _running ??= _refresh().whenComplete(() => _running = null);
  Future<void> _refresh() async {
    await api.verify();
    await store.rememberServerIdentity(
      api.config.id,
      '${api.serverId!}:${api.userId ?? ''}',
    );
    final roots = await store.serverRoots(api.config);
    final generations = <FilmMediaType, int>{};
    final workIds = <String, int>{};
    final collections = <String>{};
    try {
      for (final root in roots.values) {
        generations[root.type] = await store.beginScan(root.id);
      }
      await for (final page in api.items(types: 'Movie,Series')) {
        await _applyPage(page, (item) async {
          if (_closed) throw const FilmCatalogException('cancelled');
          final type = item['Type'] == 'Movie'
              ? FilmMediaType.movie
              : FilmMediaType.tv;
          final id = await store.saveServerWork(
            api.config,
            api.serverId!,
            item,
            type,
          );
          workIds[item['Id'] as String] = id;
          if (type == FilmMediaType.movie) {
            await store.saveServerResources(
              api.config,
              roots[type]!,
              generations[type]!,
              item,
              id,
            );
          }
        });
      }
      await for (final page in api.items(types: 'Season')) {
        await _applyPage(page, (item) async {
          if (_closed) throw const FilmCatalogException('cancelled');
          final work = workIds[item['SeriesId'] ?? item['ParentId']];
          if (work != null) {
            await store.saveServerSeason(api.config, item, work);
          }
        });
      }
      await for (final page in api.items(types: 'Episode')) {
        await _applyPage(page, (item) async {
          if (_closed) throw const FilmCatalogException('cancelled');
          final seriesId = item['SeriesId'] as String?;
          if (seriesId == null) return;
          var work = workIds[seriesId];
          if (work == null) {
            final series = await api.item(seriesId);
            work = await store.saveServerWork(
              api.config,
              api.serverId!,
              series,
              FilmMediaType.tv,
            );
            workIds[seriesId] = work;
          }
          await store.saveServerResources(
            api.config,
            roots[FilmMediaType.tv]!,
            generations[FilmMediaType.tv]!,
            item,
            work,
          );
        });
      }
      await for (final page in api.items(types: 'BoxSet')) {
        await _applyPage(page, (item) async {
          collections.add(item['Id'] as String);
          if (_closed) throw const FilmCatalogException('cancelled');
          final members = <int>[];
          await for (final page in api.items(
            parentId: item['Id'] as String,
            types: 'Movie,Series,Episode',
            recursive: false,
          )) {
            for (final member in page) {
              final work =
                  workIds[member['Type'] == 'Episode'
                      ? member['SeriesId']
                      : member['Id']];
              if (work != null) members.add(work);
            }
          }
          await store.saveServerCollection(api.config, item, members);
        });
      }
      for (final root in roots.values) {
        await store.commitScan(
          root.id,
          generations[root.type]!,
          cancelled: () => _closed,
        );
      }
      await store.finishServerCollections(api.config.id, collections);
    } catch (error) {
      for (final root in roots.values) {
        if (generations[root.type] case final generation?) {
          await store.finishScan(
            root.id,
            generation,
            error is FilmCatalogException && error.code == 'cancelled'
                ? 'cancelled'
                : 'failed',
            error is FilmCatalogException
                ? error.code
                : 'serverConnectionFailed',
          );
        }
      }
      rethrow;
    }
    await store.reconcilePlaylists(sourceId: api.config.id);
    await _refreshPlaylists();
  }

  Future<void> _refreshPlaylists() async {
    final ids = <String>{};
    await for (final page in api.items(types: 'Playlist')) {
      for (final list in page) {
        if (_closed) throw const FilmCatalogException('cancelled');
        if (list['MediaType'] != 'Video') continue;
        ids.add(list['Id'] as String);
        final members = <Map<String, dynamic>>[];
        try {
          await for (final page in api.playlistItems(list['Id'] as String)) {
            if (_closed) throw const FilmCatalogException('cancelled');
            members.addAll(page);
          }
          if (_closed) throw const FilmCatalogException('cancelled');
          await store.saveServerPlaylist(
            api.config,
            '${api.serverId!}:${api.userId!}',
            list,
            members,
          );
        } on FilmCatalogException catch (error) {
          if (error.code != 'serverPlaylistUnavailable') rethrow;
          await store.markServerPlaylistUnavailable(
            api.config.id,
            list['Id'] as String,
          );
        }
      }
    }
    if (_closed) throw const FilmCatalogException('cancelled');
    await store.finishServerPlaylists(api.config.id, ids);
  }

  Future<void> _applyPage(
    List<Map<String, dynamic>> page,
    Future<void> Function(Map<String, dynamic>) apply,
  ) async {
    for (var offset = 0; offset < page.length; offset += 20) {
      await store.withBatchedChanges(() async {
        for (final item in page.skip(offset).take(20)) {
          if (_closed) throw const FilmCatalogException('cancelled');
          await apply(item);
        }
      });
    }
  }

  Future<void> close() async {
    _closed = true;
    try {
      await _running;
    } on FilmCatalogException catch (error) {
      if (error.code != 'cancelled') rethrow;
    }
  }
}
