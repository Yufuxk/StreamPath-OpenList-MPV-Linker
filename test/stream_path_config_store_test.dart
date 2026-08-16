import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/core/utils/file_sort.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/appearance_config.dart';
import 'package:streampath/data/models/connection_config.dart';
import 'package:streampath/data/models/openlist_recovery_config.dart';
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
      expect(def.openListRecovery.enabled, isFalse);
      expect(def.hiddenExtensionsEnabled, isTrue);
      expect(def.appearance.style, InterfaceStyle.classic);
      expect(def.appearance.material, WindowMaterialPreference.automatic);

      final player = PlayerConfig(
        name: 'PotPlayer',
        executable: 'C:\\PotPlayer.exe',
        args: const ['{url}'],
        subtitleInjectionEnabled: true,
        subtitleAutoSelectEnabled: false,
        resumeEnabled: true,
        hiddenExtensionsEnabled: false,
        hiddenExtensions: const ['.ass'],
        defaultSortMode: FileSortMode.size,
        defaultSortDirection: FileSortDirection.descending,
      );
      final connection = ConnectionConfig(
        baseUrl: 'http://h/dav',
        username: 'u',
        password: 'p',
      );
      final merged = StreamPathConfig.fromParts(
        player,
        connection,
        openListRecovery: const OpenListRecoveryConfig(
          enabled: true,
          baseUrl: 'http://h',
          username: 'admin',
          password: 'secret',
        ),
      );
      expect(merged.isConnectionComplete, isTrue);
      expect(merged.serverUrl, 'http://h/dav');
      expect(merged.playerExecutable, 'C:\\PotPlayer.exe');
      expect(merged.hiddenExtensions, ['.ass']);
      expect(merged.hiddenExtensionsEnabled, isFalse);
      expect(merged.defaultSortMode, FileSortMode.size);
      expect(merged.defaultSortDirection, FileSortDirection.descending);

      // 往返
      final restored = StreamPathConfig.fromJson(merged.toJson());
      expect(restored.serverUrl, 'http://h/dav');
      expect(restored.playerArgs, ['{url}']);
      expect(restored.subtitleInjectionEnabled, isTrue);
      expect(restored.subtitleAutoSelectEnabled, isFalse);
      expect(restored.hiddenExtensionsEnabled, isFalse);
      expect(restored.defaultSortMode, FileSortMode.size);
      expect(restored.defaultSortDirection, FileSortDirection.descending);
      expect(restored.openListRecovery.enabled, isTrue);
      expect(restored.openListRecovery.baseUrl, 'http://h');
      expect(restored.appearance.style, InterfaceStyle.classic);
    });

    test('fromJson 规范化 hiddenExtensions 且缺失字段回退默认', () {
      final config = StreamPathConfig.fromJson(const {
        'hiddenExtensions': ['ASS', 'mp4', 'bad/token'],
      });
      expect(config.hiddenExtensions, ['.ass', '.mp4']);
      expect(config.hiddenExtensionsEnabled, isTrue);
      expect(config.playerExecutable, '');
      expect(config.defaultSortMode, FileSortMode.name);
      expect(config.defaultSortDirection, FileSortDirection.ascending);
      expect(config.playerStartupTimeoutSeconds, 60);
      expect(config.appearance.style, InterfaceStyle.classic);
    });

    test('界面配置支持往返并限制磨砂背景不透明度', () {
      final glass = StreamPathConfig.fromJson(const {
        'appearance': {'style': 'glass', 'glassOpacity': 0.72},
      });
      expect(glass.appearance.style, InterfaceStyle.glass);
      expect(
        glass.appearance.material,
        WindowMaterialPreference.acrylic,
        reason: '旧版磨砂配置应保留原有 Acrylic 视觉',
      );
      expect(glass.appearance.glassOpacity, 0.72);
      expect(
        StreamPathConfig.fromJson(const {
          'appearance': {'style': 'glass', 'glassOpacity': 0.1},
        }).appearance.glassOpacity,
        AppearanceConfig.minGlassOpacity,
      );
      expect(
        StreamPathConfig.fromJson(const {
          'appearance': {'style': 'unknown', 'glassOpacity': 2},
        }).appearance,
        isA<AppearanceConfig>()
            .having((value) => value.style, 'style', InterfaceStyle.classic)
            .having(
              (value) => value.glassOpacity,
              'glassOpacity',
              AppearanceConfig.maxGlassOpacity,
            ),
      );
      expect(
        StreamPathConfig.fromJson(glass.toJson()).appearance.style,
        InterfaceStyle.glass,
      );
      final mica = StreamPathConfig.fromJson(const {
        'appearance': {
          'style': 'glass',
          'material': 'mica',
          'glassOpacity': 0.8,
        },
      });
      expect(mica.appearance.material, WindowMaterialPreference.mica);
      expect(
        StreamPathConfig.fromJson(mica.toJson()).appearance.material,
        WindowMaterialPreference.mica,
      );
      expect(
        StreamPathConfig.fromJson(const {
          'appearance': {'style': 'classic', 'material': 'futureMaterial'},
        }).appearance.material,
        WindowMaterialPreference.automatic,
      );
    });

    test('WebDAV 密码为空时仍可使用地址与用户名自动连接', () {
      const config = StreamPathConfig(
        serverUrl: 'http://passwordless.example/dav',
        username: 'user',
      );

      expect(config.isConnectionComplete, isTrue);
      expect(config.toConnectionConfig().password, isEmpty);
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
        hiddenExtensionsEnabled: false,
        hiddenExtensions: ['.ass', '.mp4'],
        defaultSortMode: FileSortMode.modified,
        defaultSortDirection: FileSortDirection.descending,
        appearance: AppearanceConfig(
          style: InterfaceStyle.glass,
          material: WindowMaterialPreference.mica,
          glassOpacity: 0.75,
        ),
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
      expect(loaded.hiddenExtensionsEnabled, isFalse);
      final json = jsonDecode(
        await File(
          '${tempDir.path}${Platform.pathSeparator}cfg.json',
        ).readAsString(),
      );
      expect(json['hiddenExtensionsEnabled'], isFalse);
      expect(loaded.defaultSortMode, FileSortMode.modified);
      expect(loaded.defaultSortDirection, FileSortDirection.descending);
      expect(loaded.playerStartupTimeoutSeconds, 60);
      expect(loaded.appearance.style, InterfaceStyle.glass);
      expect(loaded.appearance.material, WindowMaterialPreference.mica);
      expect(loaded.appearance.glassOpacity, 0.75);
      expect(loaded.isConnectionComplete, isTrue);
    });

    test('启动等待秒数支持持久化、字符串读取并限制范围', () async {
      final custom = StreamPathConfig.fromJson(const {
        'playerStartupTimeoutSeconds': '120',
      });
      expect(custom.playerStartupTimeoutSeconds, 120);
      expect(
        StreamPathConfig.fromJson(const {
          'playerStartupTimeoutSeconds': 2,
        }).playerStartupTimeoutSeconds,
        5,
      );
      expect(
        StreamPathConfig.fromJson(const {
          'playerStartupTimeoutSeconds': 99999,
        }).playerStartupTimeoutSeconds,
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
          hiddenExtensionsEnabled: false,
          hiddenExtensions: ['.ass'],
          openListRecovery: OpenListRecoveryConfig(
            enabled: true,
            baseUrl: 'http://h',
            token: 'token',
          ),
          appearance: AppearanceConfig(
            style: InterfaceStyle.glass,
            material: WindowMaterialPreference.mica,
            glassOpacity: 0.76,
          ),
        ),
      );
      await store.saveConnection(
        const ConnectionConfig(baseUrl: 'http://h2/dav', username: 'u2'),
      );
      final config = await store.load();
      expect(config.serverUrl, 'http://h2/dav');
      expect(config.username, 'u2');
      expect(config.playerExecutable, 'mpv', reason: '播放器部分应保持不变');
      expect(config.hiddenExtensionsEnabled, isFalse, reason: '隐藏开关应保持不变');
      expect(config.hiddenExtensions, ['.ass'], reason: '隐藏后缀应保持不变');
      expect(config.openListRecovery.enabled, isTrue, reason: '恢复配置应保持不变');
      expect(config.openListRecovery.token, 'token');
      expect(
        config.appearance.style,
        InterfaceStyle.glass,
        reason: '界面配置应保持不变',
      );
      expect(config.appearance.material, WindowMaterialPreference.mica);
      expect(config.appearance.glassOpacity, 0.76);
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

    test('启动加载在主配置损坏时回退最近一次有效备份', () async {
      final path = '${tempDir.path}${Platform.pathSeparator}recover.json';
      final store = StreamPathConfigStore.forPath(path);
      await store.save(const StreamPathConfig(serverUrl: 'http://old/dav'));
      await store.save(const StreamPathConfig(serverUrl: 'http://new/dav'));
      File(path).writeAsStringSync('{not valid');

      final recovered = await StreamPathConfigStore.forPath(
        path,
      ).loadForStartup();

      expect(recovered.serverUrl, 'http://old/dav');
      expect(File('$path.bak').existsSync(), isTrue);
    });

    test('启动加载在主配置和备份均损坏时使用默认值', () async {
      final path = '${tempDir.path}${Platform.pathSeparator}defaults.json';
      File(path).writeAsStringSync('{not valid');
      File('$path.bak').writeAsStringSync('{also invalid');

      final recovered = await StreamPathConfigStore.forPath(
        path,
      ).loadForStartup();

      expect(recovered.serverUrl, StreamPathConfig.defaults().serverUrl);
    });

    test('连续保存时保留上一次有效配置作为备份', () async {
      final path = '${tempDir.path}${Platform.pathSeparator}backup.json';
      final store = StreamPathConfigStore.forPath(path);
      await store.save(const StreamPathConfig(serverUrl: 'http://first/dav'));
      await store.save(const StreamPathConfig(serverUrl: 'http://second/dav'));
      await store.save(const StreamPathConfig(serverUrl: 'http://third/dav'));

      final backup = jsonDecode(await File('$path.bak').readAsString());
      expect(backup['serverUrl'], 'http://second/dav');
      expect(
        (await StreamPathConfigStore.forPath(path).load()).serverUrl,
        'http://third/dav',
      );
    });

    test('重置会同时覆盖主配置和恢复备份', () async {
      final path = '${tempDir.path}${Platform.pathSeparator}reset.json';
      final store = StreamPathConfigStore.forPath(path);
      await store.save(
        const StreamPathConfig(
          serverUrl: 'http://old/dav',
          username: 'old-user',
          password: 'old-password',
        ),
      );
      await store.save(
        const StreamPathConfig(
          serverUrl: 'http://new/dav',
          username: 'new-user',
          password: 'new-password',
        ),
      );

      await store.resetToDefaults();

      final defaults = StreamPathConfig.defaults().toJson();
      expect(jsonDecode(await File(path).readAsString()), defaults);
      expect(jsonDecode(await File('$path.bak').readAsString()), defaults);
      expect(store.current.toJson(), defaults);

      File(path).writeAsStringSync('{not valid');
      final recovered = await StreamPathConfigStore.forPath(
        path,
      ).loadForStartup();
      expect(recovered.toJson(), defaults);
    });

    test('字段类型错误抛 AppException.config', () async {
      final path = '${tempDir.path}${Platform.pathSeparator}wrong-type.json';
      File(path).writeAsStringSync('{"serverUrl": 42}');
      final store = StreamPathConfigStore.forPath(path);
      await expectLater(store.load(), throwsA(isA<AppException>()));
    });
  });

  group('旧配置迁移（player_config.json + connection_config.json）', () {
    test('旧配置结构错误时保留原文件且不阻塞迁移', () async {
      final legacy = Directory(
        '${tempDir.path}${Platform.pathSeparator}malformed-legacy',
      )..createSync();
      final oldPlayer = File(
        '${legacy.path}${Platform.pathSeparator}player_config.json',
      )..writeAsStringSync('{"args": "not-a-list"}');
      final store = storeFor('not-migrated.json');

      await expectLater(store.migrateLegacyFiles(legacyDir: legacy), completes);
      expect(oldPlayer.existsSync(), isTrue);
      expect(
        File(
          '${tempDir.path}${Platform.pathSeparator}not-migrated.json',
        ).existsSync(),
        isFalse,
      );
    });

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
