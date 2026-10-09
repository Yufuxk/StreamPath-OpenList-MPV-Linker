import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_connection.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/domain/services/media_server_api.dart';
import 'package:streampath/domain/services/media_server_library.dart';

void main() {
  for (final kind in [MediaSourceKind.jellyfin, MediaSourceKind.emby]) {
    test(
      '$kind playlist paging, access failures and transactional mirror replacement',
      () async {
        final temp = await Directory.systemTemp.createTemp('playlist_server_');
        final store = await FilmCatalogStore.open('${temp.path}/catalog.db');
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var status = 200;
        var secondPageFails = false;
        var enumerateFails = false;
        var emptySecondPage = false;
        var incompleteEnumeration = false;
        var enumerateStatus = 200;
        var remoteDeleted = false;
        final offsets = <int>[];
        server.listen((request) async {
          await request.drain<void>();
          request.response.headers.contentType = ContentType.json;
          Object body = {};
          if (request.uri.path.endsWith('/Playlists/list/Items')) {
            final offset = int.parse(
              request.uri.queryParameters['StartIndex']!,
            );
            offsets.add(offset);
            expect(request.uri.queryParameters['UserId'], 'user');
            expect(request.uri.queryParameters['Limit'], '100');
            request.response.statusCode = secondPageFails && offset > 0
                ? 500
                : status;
            body = {
              'Items': [
                for (
                  var i = offset;
                  !(emptySecondPage && offset > 0) &&
                      i < 137 &&
                      i < offset + 100;
                  i++
                )
                  {'Id': i == 136 ? '0' : '$i', 'Name': 'Item $i'},
              ],
              'TotalRecordCount': 137,
            };
          } else if (request.uri.path.endsWith('/Items')) {
            final playlists =
                request.uri.queryParameters['IncludeItemTypes'] == 'Playlist';
            if (playlists && enumerateFails) request.response.statusCode = 500;
            if (playlists && enumerateStatus != 200) {
              request.response.statusCode = enumerateStatus;
            }
            final items = playlists && !remoteDeleted
                ? [
                    {
                      'Id': 'list',
                      'Name': 'Remote',
                      'Type': 'Playlist',
                      'MediaType': 'Video',
                    },
                    {
                      'Id': 'music',
                      'Name': 'Music',
                      'Type': 'Playlist',
                      'MediaType': 'Audio',
                    },
                  ]
                : [];
            body = {
              'Items': playlists && incompleteEnumeration ? [] : items,
              'TotalRecordCount': items.length,
            };
          }
          request.response.write(jsonEncode(body));
          await request.response.close();
        });
        final api = mediaServerApi(
          MediaConnection(
            id: 'server',
            kind: kind,
            name: 'Fixture',
            url: 'http://127.0.0.1:${server.port}',
          ),
          credentials: {
            'serverId': 'host',
            'userId': 'user',
            'token': 'fixture',
          },
        );
        final library = MediaServerLibrary(store, api);
        try {
          await library.refresh();
          expect(offsets, [0, 100]);
          final list = (await store.playlists()).single;
          final first = await store.playlistSnapshot(list.id);
          expect(first.entries.length, 137);
          expect(
            first.entries.last.serverItemId,
            first.entries.first.serverItemId,
          );
          expect(first.entries.last.id, isNot(first.entries.first.id));
          final copy = await store.copyPlaylist(list.id, 'Copy');
          secondPageFails = true;
          await expectLater(
            library.refresh(),
            throwsA(
              isA<FilmCatalogException>().having(
                (e) => e.code,
                'code',
                'serverConnectionFailed',
              ),
            ),
          );
          expect(
            (await store.playlistSnapshot(list.id)).entries.map((e) => e.id),
            first.entries.map((e) => e.id),
          );
          secondPageFails = false;
          emptySecondPage = true;
          await expectLater(
            library.refresh(),
            throwsA(isA<FilmCatalogException>()),
          );
          expect((await store.playlistSnapshot(list.id)).entries.length, 137);
          emptySecondPage = false;
          for (final denied in [403, 404]) {
            status = denied;
            await library.refresh();
            expect(api.authenticationFailed, isFalse);
            expect((await store.playlistSnapshot(list.id)).entries.length, 137);
            expect(
              (await store.playlist(list.id)).error,
              'serverPlaylistUnavailable',
            );
          }
          status = 200;
          await library.refresh();
          expect((await store.playlist(list.id)).error, isNull);
          enumerateFails = true;
          await expectLater(
            library.refresh(),
            throwsA(isA<FilmCatalogException>()),
          );
          expect((await store.playlists()).length, 2);
          enumerateFails = false;
          for (final denied in [403, 404]) {
            enumerateStatus = denied;
            await expectLater(
              library.refresh(),
              throwsA(isA<FilmCatalogException>()),
            );
            expect(api.authenticationFailed, isFalse);
            expect((await store.playlists()).length, 2);
          }
          enumerateStatus = 200;
          incompleteEnumeration = true;
          await expectLater(
            library.refresh(),
            throwsA(isA<FilmCatalogException>()),
          );
          expect((await store.playlists()).length, 2);
          incompleteEnumeration = false;
          remoteDeleted = true;
          await library.refresh();
          expect((await store.playlists()).single.id, copy);
          status = 401;
          await expectLater(
            api.playlistItems('list').toList(),
            throwsA(
              isA<FilmCatalogException>().having(
                (e) => e.code,
                'code',
                'serverAuthenticationFailed',
              ),
            ),
          );
          expect(api.authenticationFailed, isTrue);
        } finally {
          api.close();
          await server.close(force: true);
          await store.close();
          await temp.delete(recursive: true);
        }
      },
    );
  }
  test(
    'cancellation during playlist paging retains the previous complete mirror',
    () async {
      final temp = await Directory.systemTemp.createTemp('playlist_cancel_');
      final store = await FilmCatalogStore.open('${temp.path}/catalog.db');
      final entered = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await request.drain<void>();
        if (request.uri.path.endsWith('/Playlists/list/Items')) {
          entered.complete();
          return;
        }
        request.response.headers.contentType = ContentType.json;
        final playlists =
            request.uri.queryParameters['IncludeItemTypes'] == 'Playlist';
        request.response.write(
          jsonEncode(
            request.uri.path.endsWith('/Items')
                ? {
                    'Items': playlists
                        ? [
                            {
                              'Id': 'list',
                              'Name': 'Remote',
                              'MediaType': 'Video',
                            },
                          ]
                        : [],
                    'TotalRecordCount': playlists ? 1 : 0,
                  }
                : {},
          ),
        );
        await request.response.close();
      });
      final api = JellyfinApi(
        MediaConnection(
          id: 'server',
          kind: MediaSourceKind.jellyfin,
          name: 'Fixture',
          url: 'http://127.0.0.1:${server.port}',
        ),
        credentials: {'serverId': 'host', 'userId': 'user', 'token': 'fixture'},
      );
      final library = MediaServerLibrary(store, api);
      try {
        await store.rememberServerIdentity('server', 'host:user');
        await store.saveServerPlaylist(
          api.config,
          'host:user',
          {'Id': 'list', 'Name': 'Old'},
          [
            {'Id': 'a', 'Name': 'A'},
          ],
        );
        final pending = library.refresh();
        final rejection = expectLater(
          pending,
          throwsA(isA<FilmCatalogException>()),
        );
        await entered.future;
        final closing = library.close();
        api.close();
        await rejection;
        await closing;
        expect(
          (await store.playlistSnapshot(
            (await store.playlists()).single.id,
          )).entries.single.title,
          'A',
        );
      } finally {
        api.close();
        await server.close(force: true);
        await store.close();
        await temp.delete(recursive: true);
      }
    },
  );
}
