import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_connection.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/video_queue.dart';
import 'package:streampath/domain/services/media_server_api.dart';
import 'package:streampath/domain/services/media_server_source.dart';
import 'package:streampath/domain/services/media_server_sync.dart';

class _Api extends JellyfinApi {
  _Api()
    : super(
        const MediaConnection(
          id: 'test-server',
          kind: MediaSourceKind.jellyfin,
          name: 'Test',
          url: 'http://127.0.0.1:8096',
        ),
      );
  final events = <(String, Map<String, dynamic>)>[];
  bool offline = false;
  int startTicks = -1;
  void check() {
    if (offline) throw const FilmCatalogException('serverConnectionFailed');
  }

  @override
  Future<ServerPlaybackInfo> playback(
    String itemId, {
    String? mediaSourceId,
    int startTicks = 0,
  }) async {
    check();
    this.startTicks = startTicks;
    return ServerPlaybackInfo(
      itemId: itemId,
      mediaSourceId: mediaSourceId!,
      playSessionId: 'play-$itemId',
      url: 'http://127.0.0.1:8096/video',
      runtimeTicks: 600000000,
      size: 100,
    );
  }

  @override
  Future<void> report(String event, Map<String, dynamic> state) async {
    check();
    events.add((event, {...state}));
  }

  @override
  Future<void> played(String id, bool watched) async {
    check();
    events.add(('watched', {'ItemId': id, 'watched': watched}));
  }

  @override
  Stream<List<Map<String, dynamic>>> items({
    String? parentId,
    String types = 'Movie,Series,Season,Episode,BoxSet',
    bool recursive = true,
  }) async* {
    check();
    events.add(('pull', {}));
    yield [
      for (final id in ['one', 'two'])
        {
          'Id': id,
          'UserData': {'Played': true, 'PlaybackPositionTicks': 0},
        },
    ];
  }
}

void main() {
  test(
    'server progress coalesces, reports pause/seek/switch/stop once and keeps offline changes before pulling',
    () async {
      final dir = await Directory.systemTemp.createTemp('film_sync_');
      final store = await FilmCatalogStore.open('${dir.path}/catalog.db');
      final api = _Api();
      final root = (await store.serverRoots(api.config))[FilmMediaType.movie]!;
      final generation = await store.beginScan(root.id);
      for (final id in ['one', 'two']) {
        final item = <String, dynamic>{
          'Id': id,
          'Name': id,
          'MediaSources': [
            {'Id': 'version-$id', 'Container': 'mkv'},
          ],
        };
        final work = await store.saveServerWork(
          api.config,
          'server',
          item,
          FilmMediaType.movie,
        );
        await store.saveServerResources(
          api.config,
          root,
          generation,
          item,
          work,
        );
      }
      await store.commitScan(root.id, generation, cancelled: () => false);
      final resources = await store.resources();
      final source = await MediaServerSource.open(store, api);
      var now = DateTime(2026, 10, 7);
      final sync = MediaServerSync(store, source, now: () => now);
      Future<void> update(
        FilmResource r,
        int seconds, {
        bool paused = false,
        bool stopped = false,
      }) async {
        await source.reader.prepare(r.path);
        await sync.progress(
          VideoProgressUpdate(
            sourceId: r.sourceId,
            path: r.path,
            positionMs: seconds * 1000,
            recordedAt: now,
            paused: paused,
            stopped: stopped,
          ),
        );
      }

      try {
        final one = resources[0], two = resources[1];
        await update(one, 0);
        expect(api.events.map((e) => e.$1), ['start', 'progress']);
        now = now.add(const Duration(seconds: 1));
        await update(one, 1);
        expect(api.events, hasLength(2));
        expect(
          (await store.pendingServerStates(api.config.id)).single['state'],
          containsPair('positionMs', 1000),
        );
        now = now.add(const Duration(seconds: 9));
        await update(one, 10);
        expect(api.events, hasLength(3));
        await update(one, 10, paused: true);
        expect(api.events.last.$2['IsPaused'], true);
        await update(one, 30, paused: true);
        expect(api.events.last.$2['PositionTicks'], 300000000);
        now = now.add(const Duration(seconds: 1));
        await update(one, 31, paused: false);
        now = now.add(const Duration(seconds: 1));
        await update(one, 32);
        final beforeSwitch = api.events.length;
        await update(two, 0);
        expect(api.events.skip(beforeSwitch).map((e) => e.$1), [
          'stop',
          'start',
          'progress',
        ]);
        await update(two, 1, stopped: true);
        expect(api.events.last.$1, 'stop');
        expect(source.reader.playbackInfo(two.path), isNull);
        expect(await store.pendingServerStates(api.config.id), isEmpty);

        api.offline = true;
        await sync.watched([one], false);
        await sync.watched([one], true);
        expect(sync.error, 'serverConnectionFailed');
        expect(
          (await store.pendingServerStates(api.config.id)).single['state'],
          containsPair('watched', true),
        );
        expect(
          await store.applyServerUserData(api.config.id, 'one', {
            'Played': false,
          }),
          false,
        );
        api.offline = false;
        final beforeReconnect = api.events.length;
        await sync.refresh();
        expect(api.events.skip(beforeReconnect).map((e) => e.$1), [
          'watched',
          'stop',
          'pull',
        ]);
        expect(await store.pendingServerStates(api.config.id), isEmpty);
        expect(sync.error, isNull);
        await store.queueServerState(api.config.id, 'two', {
          'positionMs': 24000,
        });
        await source.reader.prepare(two.path);
        expect(api.startTicks, 240000000);
      } finally {
        await sync.close();
        await source.close();
        api.close();
        await store.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
