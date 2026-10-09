import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_connection.dart';
import 'package:streampath/data/models/media_source.dart';
import 'helpers/shell_test_app_state.dart';

void main() {
  test(
    'closing during a stalled server scan cancels HTTP and preserves existing resources',
    () async {
      final dir = await Directory.systemTemp.createTemp('sp_server_close_');
      final progress = await PlaybackProgressService.open(
        '${dir.path}/progress.db',
      );
      final app = ShellTestAppState(
        configStore: StreamPathConfigStore.forPath('${dir.path}/config.json'),
        playbackHistoryStore: PlaybackHistoryStore.forPath(
          '${dir.path}/history.json',
        ),
        progressService: progress,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final entered = Completer<void>();
      server.listen((request) async {
        await request.drain<void>();
        if (request.uri.path.endsWith('/Items') &&
            request.uri.queryParameters['IncludeItemTypes'] == 'Movie,Series') {
          entered.complete();
          return;
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({'Items': [], 'TotalRecordCount': 0}),
        );
        await request.response.close();
      });
      final config = MediaConnection(
        id: MediaConnection.newId(MediaSourceKind.jellyfin),
        kind: MediaSourceKind.jellyfin,
        name: 'Fixture',
        url: 'http://127.0.0.1:${server.port}',
      );
      try {
        await app.saveMediaConnection(
          config,
          secrets: {
            'token': 'test-token',
            'userId': 'test-user',
            'serverId': 'test-server',
          },
        );
        await app.mountMediaConnection(config.id);
        final catalog = (await app.getFilmCatalog()).store;
        final root = (await catalog.serverRoots(config))[FilmMediaType.movie]!;
        final generation = await catalog.beginScan(root.id);
        final item = <String, dynamic>{
          'Id': 'existing',
          'Name': 'Existing',
          'MediaSources': [
            {'Id': 'version', 'Container': 'mkv'},
          ],
        };
        final work = await catalog.saveServerWork(
          config,
          'test-server',
          item,
          FilmMediaType.movie,
        );
        await catalog.saveServerResources(config, root, generation, item, work);
        await catalog.commitScan(root.id, generation, cancelled: () => false);
        final scan = app.refreshMediaServer(config.id);
        final result = expectLater(
          scan,
          throwsA(
            isA<FilmCatalogException>().having(
              (e) => e.code,
              'code',
              'cancelled',
            ),
          ),
        );
        await entered.future.timeout(const Duration(seconds: 2));
        await app.prepareForClose().timeout(const Duration(seconds: 2));
        await result;
        expect((await catalog.resources()).single.availability, 'present');
        expect((await catalog.root(root.id))!.status, 'cancelled');
        await app.prepareForClose().timeout(const Duration(seconds: 2));
      } finally {
        app.serverApi(config.id)?.close();
        await server.close(force: true);
        final connections = await app.getMediaConnections();
        await connections.remove(config.id);
        app.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await app.closeTestStores();
        await progress.close();
        await dir.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );
}
