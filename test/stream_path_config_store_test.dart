import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/core/utils/file_sort.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/connection_config.dart';
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/data/models/stream_path_config.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('sp_cfg_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  StreamPathConfigStore storeFor(String name) => StreamPathConfigStore.forPath(
    '${tempDir.path}${Platform.pathSeparator}$name',
  );

  group('StreamPathConfig 模型', () {
    test('默认配置与组合转换', () {
      final def = StreamPathConfig.defaults();
      expect(def.playerExecutable, 'mpv');
      expect(def.isConnectionComplete, isFalse);

      final player = PlayerConfig(
        name: 'PotPlayer',
        executable: 'C:\\PotPlayer.exe',
        args: const ['{url}'],
        subtitleInjectionEnabled: true,
        subtitleAutoSelectEnabled: false,
        resumeEnabled: true,
        hiddenExtensions: const ['.ass'],
        defaultSortMode: FileSortMode.size,
        defaultSortDirection: FileSortDirection.descending,
      );
      final connection = ConnectionConfig(
        baseUrl: 'http://h/dav',
        username: 'u',
        password: 'p',
      );
      final merged = StreamPathConfig.fromParts(player, connection);
      expect(merged.isConnectionComplete, isTrue);
      expect(merged.serverUrl, 'http://h/dav');
      expect(merged.playerExecutable, 'C:\\PotPlayer.exe');
      expect(merged.hiddenExtensions, ['.ass']);
      expect(merged.defaultSortMode, FileSortMode.size);
      expect(merged.defaultSortDirection, FileSortDirection.descending);

      // 往返
      final restored = StreamPathConfig.fromJson(merged.toJson());
      expect(restored.serverUrl, 'http://h/dav');
      expect(restored.playerArgs, ['{url}']);
      expect(restored.subtitleInjectionEnabled, isTrue);
      expect(restored.subtitleAutoSelectEnabled, isFalse);
      expect(restored.defaultSortMode, FileSortMode.size);
      expect(restored.defaultSortDirection, FileSortDirection.descending);
    });

    test('fromJson 规范化 hiddenExtensions 且缺失字段回退默认', () {
      final config = StreamPathConfig.fromJson(const {
        'hiddenExtensions': ['ASS', 'mp4', 'bad/token'],
      });
      expect(config.hiddenExtensions, ['.ass', '.mp4']);
      expect(config.playerExecutable, '');
      expect(config.defaultSortMode, FileSortMode.name);
      expect(config.defaultSortDirection, FileSortDirection.ascending);
      expect(config.playerStartupTimeoutSeconds, 60);
    });
  });

  group('StreamPathConfigStore 读写', () {
    test('文件不存在返回默认配置（无迁移时）', () async {
      final store = storeFor('no_such.json');
      final config = await store.load();
      expect(config.playerExecutable, 'mpv');
      expect(config.isConnectionComplete, isFalse);
    });

    test('保存后读取一致（含全部字段）', () async {
      final store = storeFor('cfg.json');
      const config = StreamPathConfig(
        serverUrl: 'http://h/dav',
        username: 'user',
        password: 'pass',
        playerName: 'mpv',
        playerExecutable: 'mpv',
        playerArgs: ['{url}', '--sub-file={subfile}'],
        subtitleInjectionEnabled: true,
        subtitleAutoSelectEnabled: false,
        resumeEnabled: true,
        hiddenExtensions: ['.ass', '.mp4'],
        defaultSortMode: FileSortMode.modified,
        defaultSortDirection: FileSortDirection.descending,
      );
      await store.save(config);
      final loaded = await store.load();
      expect(loaded.serverUrl, 'http://h/dav');
      expect(loaded.username, 'user');
      expect(loaded.password, 'pass');
      expect(loaded.playerArgs, ['{url}', '--sub-file={subfile}']);
      expect(loaded.subtitleInjectionEnabled, isTrue);
      expect(loaded.subtitleAutoSelectEnabled, isFalse);
      expect(loaded.hiddenExtensions, ['.ass', '.mp4']);
      expect(loaded.defaultSortMode, FileSortMode.modified);
      expect(loaded.defaultSortDirection, FileSortDirection.descending);
      expect(loaded.playerStartupTimeoutSeconds, 60);
      expect(loaded.isConnectionComplete, isTrue);
    });

    test('启动等待秒数支持持久化、字符串读取并限制范围', () async {
      final custom = StreamPathConfig.fromJson(const {
        'playerStartupTimeoutSeconds': '120',
      });
      expect(custom.playerStartupTimeoutSeconds, 120);
      expect(
        StreamPathConfig.fromJson(const {'playerStartupTimeoutSeconds': 2})
            .playerStartupTimeoutSeconds,
        5,
      );
      expect(
        StreamPathConfig.fromJson(const {'playerStartupTimeoutSeconds': 99999})
            .playerStartupTimeoutSeconds,
        3600,
      );

      final store = storeFor('startup_timeout.json');
      await store.save(custom);
      expect((await store.load()).playerStartupTimeoutSeconds, 120);
      expect((await store.loadPlayer()).playerStartupTimeoutSeconds, 120);
    });

    test('saveConnection 只更新连接部分（播放器部分保持不变）', () async {
      final store = storeFor('partial.json');
      await store.save(
        const StreamPathConfig(
          serverUrl: 'http://h/dav',
          username: 'u',
          password: 'p',
          playerExecutable: 'mpv',
        ),
      );
      await store.saveConnection(
        const ConnectionConfig(baseUrl: 'http://h2/dav', username: 'u2'),
      );
      final config = await store.load();
      expect(config.serverUrl, 'http://h2/dav');
      expect(config.username, 'u2');
      expect(config.playerExecutable, 'mpv', reason: '播放器部分应保持不变');
    });

    test('旧 subtitleEnabled 配置会同时迁移为注入与自动选择开关', () {
      final enabled = StreamPathConfig.fromJson(const {
        'subtitleEnabled': true,
      });
      expect(enabled.subtitleInjectionEnabled, isTrue);
      expect(enabled.subtitleAutoSelectEnabled, isTrue);

      final disabled = StreamPathConfig.fromJson(const {
        'subtitleEnabled': false,
      });
      expect(disabled.subtitleInjectionEnabled, isFalse);
      expect(disabled.subtitleAutoSelectEnabled, isFalse);
    });

    test('自动注入关闭时忽略配置中的自动选择开启值', () {
      final config = StreamPathConfig.fromJson(const {
        'subtitleInjectionEnabled': false,
        'subtitleAutoSelectEnabled': true,
      });
      expect(config.subtitleInjectionEnabled, isFalse);
      expect(config.subtitleAutoSelectEnabled, isFalse);
    });

    test('重复 load 命中内存缓存', () async {
      final store = storeFor('cache.json');
      await store.save(const StreamPathConfig(serverUrl: 'http://h/dav'));
      await store.load();
      File('${tempDir.path}${Platform.pathSeparator}cache.json').deleteSync();
      final config = await store.load();
      expect(config.serverUrl, 'http://h/dav');
    });

    test('损坏 JSON 抛 AppException.config', () async {
      final path = '${tempDir.path}${Platform.pathSeparator}broken.json';
      File(path).writeAsStringSync('{not valid');
      final store = StreamPathConfigStore.forPath(path);
      await expectLater(store.load(), throwsA(isA<AppException>()));
    });
  });

  group('旧配置迁移（player_config.json + connection_config.json）', () {
    test('旧文件合并写入新文件并删除旧文件', () async {
      final legacy = Directory('${tempDir.path}${Platform.pathSeparator}legacy')
        ..createSync();
      File(
        '${legacy.path}${Platform.pathSeparator}player_config.json',
      ).writeAsStringSync(
        jsonEncode({
          'name': 'mpv',
          'executable': 'mpv',
          'args': ['{url}', '--sub-file={subfile}'],
          'subtitleEnabled': true,
          'resumeEnabled': true,
          'hiddenExtensions': ['.ass'],
        }),
      );
      File(
        '${legacy.path}${Platform.pathSeparator}connection_config.json',
      ).writeAsStringSync(
        jsonEncode({
          'baseUrl': 'http://old/dav',
          'username': 'old_user',
          'password': 'old_pass',
        }),
      );

      final store = storeFor('migrated.json');
      await store.migrateLegacyFiles(legacyDir: legacy);
      final config = await store.load();
      // 连接信息 + 播放器信息 + 隐藏后缀全部合并。
      expect(config.serverUrl, 'http://old/dav');
      expect(config.username, 'old_user');
      expect(config.password, 'old_pass');
      expect(config.playerExecutable, 'mpv');
      expect(config.playerArgs, ['{url}', '--sub-file={subfile}']);
      expect(config.hiddenExtensions, ['.ass']);
      expect(config.isConnectionComplete, isTrue);
      // 旧文件已删除。
      expect(
        File(
          '${legacy.path}${Platform.pathSeparator}player_config.json',
        ).existsSync(),
        isFalse,
      );
      expect(
        File(
          '${legacy.path}${Platform.pathSeparator}connection_config.json',
        ).existsSync(),
        isFalse,
      );
    });

    test('无旧文件时迁移无操作（返回默认）', () async {
      final legacy = Directory('${tempDir.path}${Platform.pathSeparator}empty')
        ..createSync();
      final store = storeFor('none.json');
      await store.migrateLegacyFiles(legacyDir: legacy);
      final config = await store.load();
      expect(config.playerExecutable, 'mpv');
      expect(config.isConnectionComplete, isFalse);
    });
  });
}
