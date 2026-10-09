import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/models/media_connection.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/domain/services/media_server_api.dart';
import 'package:streampath/domain/services/media_server_library.dart';
import 'package:streampath/domain/services/media_server_source.dart';

void main() {
  test('live Jellyfin metadata, custom collection and direct playback import into an isolated library', () async {
    final temp = await Directory.systemTemp.createTemp('sp_jellyfin_acceptance_');
    final store = await FilmCatalogStore.open(p.join(temp.path, 'catalog.db'));
    final api = JellyfinApi(MediaConnection(id: 'jellyfin:acceptance', kind: MediaSourceKind.jellyfin,
      name: 'Jellyfin acceptance', url: Platform.environment['PHASE5_JELLYFIN_URL'] ?? 'http://localhost:8096',
      username: Platform.environment['PHASE5_JELLYFIN_USER']!));
    final library = MediaServerLibrary(store, api);
    addTearDown(() async { await library.close(); api.close(); await store.close(); await temp.delete(recursive: true); });
    await api.authenticate(Platform.environment['PHASE5_JELLYFIN_PASSWORD']!);
    await library.refresh();
    final resources = await store.serverResources(api.config.id);
    expect(resources, isNotEmpty);
    final collections = (await store.collections()).where((row) => row.id.startsWith('server:')).toList();
    expect(collections, isNotEmpty);
    final testCollection = collections.singleWhere((c) => c.name == 'TEST 合集');
    expect(testCollection.count, greaterThan(0));
    expect((await store.works(type: null, collectionId: testCollection.id)).length, testCollection.count);
    final playback = await api.playback(resources.first['item_id'] as String, mediaSourceId: resources.first['media_source_id'] as String);
    expect(playback.mediaSourceId, resources.first['media_source_id']);
    expect(playback.url, isNot(contains('api_key')));
    final source = await MediaServerSource.open(store, api);
    try {
      final bytes = await source.reader.read(resources.first['relative_path'] as String, 2048, 256);
      expect(bytes, hasLength(256));
    } finally { await source.close(); }
    final firstIds = resources.map((row) => row['resource_id']).toList();
    await library.refresh();
    expect((await store.serverResources(api.config.id)).map((row) => row['resource_id']).toList(), firstIds);
    expect((await store.collections()).where((c) => c.id == testCollection.id), hasLength(1));
  }, skip: Platform.environment['PHASE5_JELLYFIN_PASSWORD'] == null);
}
