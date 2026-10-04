import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/global_search_index.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/state/app_state.dart';

/// 默认影视主页与文件夹搜索使用夹具目录，避免访问正式数据。
class ShellTestAppState extends AppState {
  ShellTestAppState({
    required super.configStore,
    required super.playbackHistoryStore,
    required super.progressService,
    super.directoryCache,
    super.mediaLibraryStore,
    super.navigationLocationStore,
  });

  Future<FilmCatalogController>? _catalog;
  Future<GlobalSearchIndex>? _search;
  @override
  Future<FilmCatalogStore> getFilmCatalogStore() async =>
      (await getFilmCatalog()).store;
  @override
  Future<FilmCatalogController> getFilmCatalog() => _catalog ??= () async {
    final path = p.dirname(configStore.configFilePath);
    final tmdb = TmdbMetadataService(credentials: _NoCredentials());
    return FilmCatalogController(
      store: await FilmCatalogStore.open(p.join(path, 'test_catalog.db')),
      tmdb: tmdb,
      images: FilmCatalogImageCache(
        Directory(p.join(path, 'test_images')),
        tmdb,
      ),
      sourceFor: (_) => throw const FilmCatalogException('sourceUnavailable'),
    );
  }();

  @override
  Future<GlobalSearchIndex> getGlobalSearchIndex() =>
      _search ??= GlobalSearchIndex.open(
        p.join(p.dirname(configStore.configFilePath), 'test_search.db'),
      );

  Future<void> closeTestStores() async {
    if (_catalog != null) await (await _catalog!).close();
    if (_search != null) await (await _search!).close();
  }
}

class _NoCredentials extends TmdbCredentialStore {
  @override
  Future<String?> read() async => null;
}
