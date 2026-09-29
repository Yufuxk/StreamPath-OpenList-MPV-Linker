import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/server_profile.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/presentation/state/app_state.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('旧配置将原活动服务器加入挂载列表', () async {
    final temporary = Directory.systemTemp.createTempSync('network_migration_');
    try {
      final path = '${temporary.path}${Platform.pathSeparator}config.json';
      await File(path).writeAsString(
        jsonEncode({
          'schemaVersion': 5,
          'activeProfileId': 'legacy-profile',
          'profiles': [
            {
              'profileId': 'legacy-profile',
              'name': '原服务器',
              'serverUrl': 'https://example.test/dav',
              'username': 'user',
            },
          ],
        }),
      );
      final store = StreamPathConfigStore.forPath(path);
      final config = await store.load();
      expect(config.mountedProfileIds, ['legacy-profile']);
      expect(config.profiles.single.profileId, 'legacy-profile');
    } finally {
      if (temporary.existsSync()) temporary.deleteSync(recursive: true);
    }
  });

  test('两个已保存 WebDAV 独立挂载、切换、移除并在重启后恢复', () async {
    final temporary = Directory.systemTemp.createTempSync('network_mount_');
    final servers = <HttpServer>[];
    final requestCounts = <String, int>{'a': 0, 'b': 0};
    Future<HttpServer> serverFor(String id) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      servers.add(server);
      server.listen((request) async {
        requestCounts[id] = requestCounts[id]! + 1;
        request.response
          ..statusCode = 207
          ..headers.contentType = ContentType(
            'application',
            'xml',
            charset: 'utf-8',
          )
          ..write('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"/>');
        await request.response.close();
      });
      return server;
    }

    final firstServer = await serverFor('a');
    final secondServer = await serverFor('b');
    final configPath = '${temporary.path}${Platform.pathSeparator}config.json';
    final store = StreamPathConfigStore.forPath(configPath);
    final first = ServerProfile(
      profileId: 'server-a',
      name: '服务器 A',
      serverUrl:
          'http://${firstServer.address.address}:${firstServer.port}/dav',
      username: 'a',
    );
    final second = ServerProfile(
      profileId: 'server-b',
      name: '服务器 B',
      serverUrl:
          'http://${secondServer.address.address}:${secondServer.port}/dav',
      username: 'b',
    );
    await store.save(
      StreamPathConfig.defaults()
          .upsertProfile(first)
          .upsertProfile(second, activate: false),
    );
    final progress = await PlaybackProgressService.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfi,
      legacyProfileId: first.profileId,
    );
    final state = AppState(
      configStore: store,
      playbackHistoryStore: PlaybackHistoryStore.forPath(
        '${temporary.path}${Platform.pathSeparator}history.json',
      ),
      progressService: progress,
    );
    addTearDown(() async {
      state.dispose();
      await progress.close();
      for (final server in servers) {
        await server.close(force: true);
      }
      if (temporary.existsSync()) temporary.deleteSync(recursive: true);
    });

    await state.mountProfile(first.profileId);
    await state.mountProfile(second.profileId);
    expect(store.current.mountedProfileIds, [
      first.profileId,
      second.profileId,
    ]);
    expect(state.mountedService(first.profileId)?.sourceId, first.profileId);
    expect(state.mountedService(second.profileId)?.sourceId, second.profileId);
    expect(requestCounts, {'a': 1, 'b': 1});

    await state.activateMountedProfile(second.profileId);
    await state.activateMountedProfile(first.profileId);
    expect(state.mediaSourceId, first.profileId);
    expect(requestCounts, {'a': 1, 'b': 1});

    await state.unmountProfile(first.profileId);
    expect(store.current.mountedProfileIds, [second.profileId]);
    expect(state.mountedService(second.profileId), isNotNull);
    expect(store.current.profiles, hasLength(2));

    final reloaded = StreamPathConfigStore.forPath(configPath);
    await reloaded.load();
    expect(reloaded.current.mountedProfileIds, [second.profileId]);
  });
}
