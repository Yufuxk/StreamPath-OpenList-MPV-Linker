import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_connection.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/domain/services/film_catalog_matcher.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';

class _Credentials extends TmdbCredentialStore {
  @override
  Future<String?> read() async => 'synthetic-test-token';
}

class _SlowImages extends FilmCatalogImageCache {
  _SlowImages(super.directory, super.tmdb);
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<File?> cached(String path, String target) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late FilmCatalogStore store;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('film_library_regressions_');
    store = await FilmCatalogStore.open('${temp.path}/catalog.db');
  });
  tearDown(() async {
    await store.close();
    await temp.delete(recursive: true);
  });

  test(
    'TMDB details retain official series and create an automatic collection',
    () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (o, h) {
              final id = int.parse(o.uri.path.split('/')[3]);
              h.resolve(
                Response(
                  requestOptions: o,
                  statusCode: 200,
                  data: o.path.endsWith('/images')
                      ? {'id': id, 'backdrops': [], 'logos': []}
                      : {
                          'id': id,
                          'title': 'Movie $id',
                          'original_title': 'Movie $id',
                          'genres': [],
                          'belongs_to_collection': {
                            'id': 42,
                            'name': 'Official series',
                          },
                        },
                ),
              );
            },
          ),
        );
      final tmdb = TmdbMetadataService(credentials: _Credentials(), dio: dio);
      addTearDown(tmdb.close);
      final rootId = await store.addRoot(
        sourceId: 'local:test',
        kind: MediaSourceKind.local,
        path: '',
        type: FilmMediaType.movie,
        name: 'Test',
      );
      final root = (await store.root(rootId))!;
      final generation = await store.beginScan(rootId);
      await store.stage(root, generation, [
        for (var i = 1; i <= 2; i++)
          FilmScanEntry(
            path: '$i.mkv',
            parentPath: '',
            name: '$i.mkv',
            mediaKind: 'video',
          ),
      ]);
      await store.commitScan(rootId, generation, cancelled: () => false);
      final resources = await store.resources();
      for (var i = 0; i < resources.length; i++) {
        await store.bind(
          [resources[i]],
          FilmWork(
            type: FilmMediaType.movie,
            tmdbId: i + 1,
            title: 'Movie ${i + 1}',
            originalTitle: 'Movie ${i + 1}',
            overview: '',
            language: 'zh-CN',
          ),
        );
        final session = await FilmCatalogMatcher(
          store,
          tmdb,
        ).scanSession(root, cancelled: () => false);
        await session.prepare([
          FilmScanEntry(
            path: resources[i].path,
            parentPath: '',
            name: resources[i].name,
            mediaKind: 'video',
          ),
        ]);
        final work = session.matches.values.single.work;
        expect(work.metadata['belongs_to_collection'], isNotNull);
        await store.applyMetadata(root.id, session.matches);
      }
      expect((await store.collections()).single.id, 'tmdb:42');
      expect((await store.collections()).single.count, 2);
    },
  );

  test(
    'duplicate mounts share one server collection on the main library',
    () async {
      for (final source in ['mount-one', 'mount-two']) {
        final config = MediaConnection(
          id: source,
          kind: MediaSourceKind.jellyfin,
          name: source,
          url: 'http://localhost:8096',
        );
        await store.setPreference('server_identity:$source', 'same-server');
        final root = (await store.serverRoots(config))[FilmMediaType.movie]!;
        final generation = await store.beginScan(root.id);
        final item = <String, dynamic>{'Id': 'movie', 'Name': 'Movie'};
        final work = await store.saveServerWork(
          config,
          'same-server',
          item,
          FilmMediaType.movie,
        );
        await store.saveServerResources(config, root, generation, item, work);
        await store.commitScan(root.id, generation, cancelled: () => false);
        await store.saveServerCollection(
          config,
          {'Id': 'box', 'Name': 'Box'},
          [work],
        );
      }
      expect(await store.collections(), hasLength(1));
      expect(await store.collections(sourceId: 'mount-one'), hasLength(1));
      expect(await store.collections(sourceId: 'mount-two'), hasLength(1));
      final custom = await store.createCollection('Keep custom');
      await store.removeServerData('mount-one');
      expect(await store.preference('server_identity:mount-one'), isNull);
      expect(await store.serverResources('mount-one'), isEmpty);
      expect(
        (await store.collections()).where((c) => c.id.startsWith('server:')),
        hasLength(1),
      );
      expect(
        (await store.portableSnapshot(
          collections: true,
        ))['collections'].toString(),
        isNot(contains('server:mount-one:')),
      );
      await store.reconcileServerSources({});
      expect((await store.collections()).map((c) => c.id), [custom]);
      expect(await store.roots(), isEmpty);
    },
  );

  test(
    'catalog notifications publish each import batch and pending changes on failure',
    () async {
      var notifications = 0;
      store.addListener(() => notifications++);
      await store.withBatchedChanges(() async {
        for (var i = 0; i < 20; i++) {
          await store.setPreference('test:$i', i);
        }
      });
      expect(notifications, 1);
      await expectLater(
        store.withBatchedChanges(() async {
          await store.setPreference('test:failure', true);
          throw StateError('Failed operation');
        }),
        throwsStateError,
      );
      expect(notifications, 2);
      expect(await store.preference('test:failure'), true);
    },
  );

  test(
    'parallel server batches publish before the other source finishes',
    () async {
      var notifications = 0;
      store.addListener(() => notifications++);
      final entered = Completer<void>();
      final release = Completer<void>();
      final first = store.withBatchedChanges(() async {
        await store.setPreference('parallel-one', true);
        entered.complete();
        await release.future;
      });
      await entered.future;
      await store.withBatchedChanges(
        () => store.setPreference('parallel-two', true),
      );
      expect(notifications, 1);
      await store.setPreference('parallel-three', true);
      release.complete();
      await first;
      expect(notifications, 2);
    },
  );

  test(
    'poster-wall results become visible before unrelated source covers finish',
    () async {
      final rootId = await store.addRoot(
        sourceId: 'local:test',
        kind: MediaSourceKind.local,
        path: '',
        type: FilmMediaType.movie,
        name: 'Test',
      );
      final root = (await store.root(rootId))!;
      final generation = await store.beginScan(rootId);
      await store.stage(root, generation, [
        const FilmScanEntry(
          path: '1.mkv',
          parentPath: '',
          name: '1.mkv',
          mediaKind: 'video',
        ),
      ]);
      await store.commitScan(rootId, generation, cancelled: () => false);
      await store.bind(
        await store.resources(),
        const FilmWork(
          type: FilmMediaType.movie,
          tmdbId: 1,
          title: 'Movie',
          originalTitle: 'Movie',
          overview: '',
          language: 'en',
          posterPath: '/poster.jpg',
        ),
      );
      final tmdb = TmdbMetadataService(credentials: _Credentials());
      final images = _SlowImages(Directory('${temp.path}/images'), tmdb);
      final c = FilmCatalogController(
        store: store,
        tmdb: tmdb,
        images: images,
        ownsResources: false,
        sourceFor: (_) => throw StateError('No source access'),
      );
      final refresh = c.refresh();
      await images.started.future;
      final visible = c.works.length;
      images.release.complete();
      await refresh;
      await c.close();
      images.close();
      tmdb.close();
      expect(visible, 1);
    },
  );
}
