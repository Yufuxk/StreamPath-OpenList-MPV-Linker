import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/stream_path_config.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() {
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'streampath_local_root_',
    );
  });

  tearDown(() {
    if (temporaryDirectory.existsSync()) {
      temporaryDirectory.deleteSync(recursive: true);
    }
  });

  test('本地根目录保存规范绝对路径并保持 rootId 稳定', () async {
    final mediaDirectory = Directory(p.join(temporaryDirectory.path, 'Media'))
      ..createSync();

    final root = await LocalRootConfig.fromDirectory(
      path: mediaDirectory.path,
      displayName: '本地影视',
      rootId: 'root-1',
    );
    final restored = LocalRootConfig.fromJson(root.toJson());

    expect(root.path, await mediaDirectory.resolveSymbolicLinks());
    expect(restored.rootId, 'root-1');
    expect(restored.sourceId, 'local:root-1');
    expect(restored.displayName, '本地影视');
  });

  test('schema 4 迁移到 5 时先备份并补充空 localRoots', () async {
    final path = p.join(temporaryDirectory.path, 'config.json');
    await File(path).writeAsString(
      jsonEncode(<String, Object?>{
        'schemaVersion': 4,
        'profiles': const [],
        'activeProfileId': '',
      }),
    );
    final store = StreamPathConfigStore.forPath(path);

    final config = await store.load();
    final persisted = jsonDecode(await File(path).readAsString()) as Map;
    final migrationBackups = temporaryDirectory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.contains('.migration-v4-'));

    expect(config.schemaVersion, StreamPathConfig.currentSchemaVersion);
    expect(config.localRoots, isEmpty);
    expect(persisted['schemaVersion'], 5);
    expect(persisted['localRoots'], isEmpty);
    expect(migrationBackups, hasLength(1));
  });

  test('损坏的单个本地根不会阻断 WebDAV 配置读取', () {
    final config = StreamPathConfig.fromJson(const {
      'schemaVersion': 5,
      'serverUrl': 'https://example.test/dav',
      'username': 'user',
      'localRoots': [
        {'rootId': 'bad', 'path': 42},
      ],
    });

    expect(config.serverUrl, 'https://example.test/dav');
    expect(config.localRoots, isEmpty);
  });

  test('本地来源与 WebDAV 来源以及菜单模式使用不同稳定键', () {
    const local = MediaLibraryItem(
      sourceId: 'local:root-1',
      sourceKind: MediaSourceKind.local,
      playbackMode: PlaybackMode.localFile,
      parentPath: 'Movies',
      name: 'disc.iso',
      kind: MediaLibraryKind.iso,
    );
    const remote = MediaLibraryItem(
      sourceId: 'webdav-profile',
      parentPath: 'Movies',
      name: 'disc.iso',
      kind: MediaLibraryKind.iso,
    );
    const menu = MediaLibraryItem(
      sourceId: 'local:root-1',
      sourceKind: MediaSourceKind.local,
      playbackMode: PlaybackMode.localHdmvMenu,
      parentPath: 'Movies',
      name: 'disc.iso',
      kind: MediaLibraryKind.iso,
    );

    expect(local.stableKey, isNot(remote.stableKey));
    expect(local.stableKey, isNot(menu.stableKey));
    expect(
      MediaLibraryItem.fromJson(const {
        'sourceId': 'old',
        'parentPath': '',
        'name': 'movie.mkv',
        'kind': 'video',
      }),
      isA<MediaLibraryItem>()
          .having(
            (item) => item.sourceKind,
            'sourceKind',
            MediaSourceKind.webdav,
          )
          .having(
            (item) => item.playbackMode,
            'playbackMode',
            PlaybackMode.legacyTitle,
          ),
    );
    expect(
      () => MediaLibraryItem.fromJson(const {
        'sourceId': 'future',
        'parentPath': '',
        'name': 'movie.mkv',
        'kind': 'video',
        'sourceKind': 'future',
      }),
      throwsFormatException,
    );
  });
}
