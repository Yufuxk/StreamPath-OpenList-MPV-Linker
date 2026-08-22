import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/core/utils/file_sort.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/local/profile_credential_store.dart';
import 'package:streampath/data/models/appearance_config.dart';
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/data/models/connection_config.dart';
import 'package:streampath/data/models/media_library_config.dart';
import 'package:streampath/data/models/openlist_recovery_config.dart';
import 'package:streampath/data/models/openlist_index_config.dart';
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/data/models/server_profile.dart';
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
      expect(def.language, AppLanguage.simplifiedChinese);
      expect(
        def.mediaLibrary.maxRecentPlaybackPerLane,
        MediaLibraryConfig.defaultMaxRecentPlaybackPerLane,
      );

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
        language: AppLanguage.japanese,
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
      expect(restored.language, AppLanguage.japanese);
      expect(
        restored.mediaLibrary.maxFavoritesPerSource,
        MediaLibraryConfig.defaultMaxFavoritesPerSource,
      );
    });

    test('语言配置接受稳定代码并对未知值回退简体中文', () {
      expect(
        StreamPathConfig.fromJson(const {'language': 'zh-TW'}).language,
        AppLanguage.traditionalChinese,
      );
      expect(
        StreamPathConfig.fromJson(const {'language': 'ja'}).language,
        AppLanguage.japanese,
      );
      expect(
        StreamPathConfig.fromJson(const {'language': 'en'}).language,
        AppLanguage.english,
      );
      expect(
        StreamPathConfig.fromJson(const {'language': 'unknown'}).language,
        AppLanguage.simplifiedChinese,
      );
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

    test('媒体中心容量支持往返、字符串读取和底层硬上限', () {
      final config = StreamPathConfig.fromJson(const {
        'mediaLibrary': {
          'maxFavoritesPerSource': '120',
          'maxContinuePerLane': 99999,
          'maxRecentPlaybackPerLane': 0,
          'maxRecentDirectoriesPerSource': 80,
        },
      });

      expect(config.mediaLibrary.maxFavoritesPerSource, 120);
      expect(
        config.mediaLibrary.maxContinuePerLane,
        MediaLibraryConfig.systemMaxContinuePerLane,
      );
      expect(
        config.mediaLibrary.maxRecentPlaybackPerLane,
        MediaLibraryConfig.minItemLimit,
      );
      expect(config.mediaLibrary.maxRecentDirectoriesPerSource, 80);
      expect(
        StreamPathConfig.fromJson(
          config.toJson(),
        ).mediaLibrary.maxFavoritesPerSource,
        120,
      );
    });

    test('save 会把超出系统上限的媒体中心容量收敛后再写入', () async {
      final store = storeFor('media_limit_save.json');
      await store.save(
        const StreamPathConfig(
          mediaLibrary: MediaLibraryConfig(
            maxFavoritesPerSource: 999999,
            maxContinuePerLane: 999999,
            maxRecentPlaybackPerLane: 999999,
            maxRecentDirectoriesPerSource: 999999,
          ),
        ),
      );
      expect(
        store.current.mediaLibrary.maxFavoritesPerSource,
        MediaLibraryConfig.systemMaxFavoritesPerSource,
      );
      expect(
        (await store.load()).mediaLibrary.maxRecentPlaybackPerLane,
        MediaLibraryConfig.systemMaxRecentPlaybackPerLane,
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
        mediaLibrary: MediaLibraryConfig(
          maxFavoritesPerSource: 120,
          maxContinuePerLane: 40,
          maxRecentPlaybackPerLane: 300,
          maxRecentDirectoriesPerSource: 60,
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
      expect(loaded.mediaLibrary.maxFavoritesPerSource, 120);
      expect(loaded.mediaLibrary.maxContinuePerLane, 40);
      expect(loaded.mediaLibrary.maxRecentPlaybackPerLane, 300);
      expect(loaded.mediaLibrary.maxRecentDirectoriesPerSource, 60);
      expect(json['mediaLibrary']['maxFavoritesPerSource'], 120);
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

  group('服务器档案与版本化迁移', () {
    test('版本三配置迁移后补全简体中文语言字段', () async {
      final path = '${tempDir.path}${Platform.pathSeparator}schema-v3.json';
      await File(path).writeAsString(
        jsonEncode({
          'schemaVersion': 3,
          'credentialStorageMode': 'portablePlaintext',
          'profiles': const [],
          'activeProfileId': '',
        }),
      );

      final config = await StreamPathConfigStore.forPath(path).load();

      expect(config.language, AppLanguage.simplifiedChinese);
      final persisted = jsonDecode(await File(path).readAsString()) as Map;
      expect(persisted['schemaVersion'], StreamPathConfig.currentSchemaVersion);
      expect(persisted['language'], 'zh-CN');
      expect(
        tempDir.listSync().whereType<File>().any(
          (file) => file.path.contains('.migration-v3-'),
        ),
        isTrue,
      );
    });

    test('版本二配置迁移后补全默认关闭的索引更新配置', () async {
      final path = '${tempDir.path}${Platform.pathSeparator}schema-v2.json';
      await File(path).writeAsString(
        jsonEncode({
          'schemaVersion': 2,
          'credentialStorageMode': 'portablePlaintext',
          'profiles': [
            const ServerProfile(
              profileId: 'profile-v2',
              name: '旧档案',
              serverUrl: 'https://example.test/dav',
              username: 'alice',
            ).toJson()..remove('openListIndex'),
          ],
          'activeProfileId': 'profile-v2',
        }),
      );

      final store = StreamPathConfigStore.forPath(path);
      final config = await store.load();

      expect(config.schemaVersion, StreamPathConfig.currentSchemaVersion);
      expect(config.activeProfile?.openListIndex.autoUpdateEnabled, isFalse);
      expect(
        config.activeProfile?.openListIndex.updateIntervalMinutes,
        OpenListIndexConfig.defaultUpdateIntervalMinutes,
      );
      final persisted = jsonDecode(await File(path).readAsString()) as Map;
      expect(
        (persisted['profiles'] as List).single['openListIndex'],
        isA<Map>(),
      );
      expect(
        tempDir.listSync().whereType<File>().any(
          (file) => file.path.contains('.migration-v2-'),
        ),
        isTrue,
      );
    });

    test('旧单账号迁移为默认档案并把敏感值移入凭据管理器', () async {
      final path = '${tempDir.path}${Platform.pathSeparator}legacy-flat.json';
      await File(path).writeAsString(
        jsonEncode({
          'serverUrl': 'https://user:old@example.test/dav?sign=secret',
          'username': 'alice',
          'password': 'webdav-secret',
          'openListRecovery': {
            'enabled': true,
            'baseUrl': 'https://example.test',
            'username': 'admin',
            'password': 'admin-secret',
            'token': 'admin-token',
          },
        }),
      );
      final secrets = <String, ProfileSecrets>{};
      final store = StreamPathConfigStore.forPath(
        path,
        credentialStore: MemoryProfileCredentialStore(secrets),
      );

      final config = await store.load();

      expect(config.schemaVersion, StreamPathConfig.currentSchemaVersion);
      expect(config.profiles, hasLength(1));
      expect(config.activeProfile?.name, '默认服务器');
      expect(config.password, 'webdav-secret');
      expect(config.openListRecovery.password, 'admin-secret');
      expect(config.openListRecovery.token, 'admin-token');
      expect(secrets[config.profileId]?.webDavPassword, 'webdav-secret');
      final persisted = await File(path).readAsString();
      expect(persisted, isNot(contains('webdav-secret')));
      expect(persisted, isNot(contains('admin-secret')));
      expect(persisted, isNot(contains('admin-token')));
      expect(persisted, isNot(contains('user:old')));
      expect(
        tempDir.listSync().whereType<File>().any(
          (file) => file.path.contains('.migration-v0-'),
        ),
        isTrue,
      );
      expect(File('$path.migrations.jsonl').existsSync(), isTrue);
    });

    test('安全模式重新加载凭据且便携模式明确保存明文', () async {
      final path = '${tempDir.path}${Platform.pathSeparator}profiles.json';
      final secrets = <String, ProfileSecrets>{};
      final credentialStore = MemoryProfileCredentialStore(secrets);
      const profile = ServerProfile(
        profileId: 'profile-stable',
        name: '主服务器',
        serverUrl: 'https://example.test/dav',
        username: 'alice',
        password: 'secret-value',
        openListIndex: OpenListIndexConfig(userToken: 'least-privilege-token'),
      );
      final secureStore = StreamPathConfigStore.forPath(
        path,
        credentialStore: credentialStore,
      );
      await secureStore.save(
        StreamPathConfig.defaults().upsertProfile(profile),
      );
      expect(await File(path).readAsString(), isNot(contains('secret-value')));
      expect(
        await File(path).readAsString(),
        isNot(contains('least-privilege-token')),
      );
      final reloaded = await StreamPathConfigStore.forPath(
        path,
        credentialStore: credentialStore,
      ).load();
      expect(reloaded.password, 'secret-value');
      expect(
        reloaded.activeProfile?.openListIndex.userToken,
        'least-privilege-token',
      );

      await secureStore.save(
        secureStore.current.withCredentialStorageMode(
          CredentialStorageMode.portablePlaintext,
        ),
      );
      expect(await File(path).readAsString(), contains('secret-value'));
      expect(
        await File(path).readAsString(),
        contains('least-privilege-token'),
      );
      expect(secrets, isEmpty);
    });

    test('切换和编辑档案不会改变稳定 profileId', () {
      const first = ServerProfile(
        profileId: 'profile-a',
        name: 'A',
        serverUrl: 'https://a.test/dav',
        username: 'a',
      );
      const second = ServerProfile(
        profileId: 'profile-b',
        name: 'B',
        serverUrl: 'https://b.test/dav',
        username: 'b',
      );
      final config = StreamPathConfig.defaults()
          .upsertProfile(first)
          .upsertProfile(second, activate: false)
          .activateProfile('profile-b')
          .upsertProfile(second.copyWith(serverUrl: 'https://new-b.test/dav'));

      expect(config.profileId, 'profile-b');
      expect(config.serverUrl, 'https://new-b.test/dav');
      expect(config.profiles.map((profile) => profile.profileId), [
        'profile-a',
        'profile-b',
      ]);
    });

    test('未来配置版本拒绝被当前版本降级解析', () async {
      final path = '${tempDir.path}${Platform.pathSeparator}future.json';
      await File(path).writeAsString(
        jsonEncode({
          'schemaVersion': StreamPathConfig.currentSchemaVersion + 1,
        }),
      );
      await expectLater(
        StreamPathConfigStore.forPath(path).load(),
        throwsA(isA<AppException>()),
      );
    });

    test('启动遇到未来版本时保持主文件并禁止后续保存覆盖', () async {
      final path =
          '${tempDir.path}${Platform.pathSeparator}future-startup.json';
      final original = jsonEncode({
        'schemaVersion': StreamPathConfig.currentSchemaVersion + 1,
        'futureOnlyField': 'must-keep',
      });
      await File(path).writeAsString(original);
      final store = StreamPathConfigStore.forPath(path);

      final fallback = await store.loadForStartup();

      expect(fallback.profiles, isEmpty);
      expect(store.futureSchemaDetected, isTrue);
      await expectLater(
        store.save(StreamPathConfig.defaults()),
        throwsA(isA<AppException>()),
      );
      expect(await File(path).readAsString(), original);
    });

    test('重复 profileId 会被拒绝，避免两个档案共享隔离主键', () async {
      final path = '${tempDir.path}${Platform.pathSeparator}duplicate-id.json';
      await File(path).writeAsString(
        jsonEncode({
          'schemaVersion': StreamPathConfig.currentSchemaVersion,
          'profiles': [
            const ServerProfile(profileId: 'duplicate', name: 'A').toJson(),
            const ServerProfile(profileId: 'duplicate', name: 'B').toJson(),
          ],
          'activeProfileId': 'duplicate',
        }),
      );

      await expectLater(
        StreamPathConfigStore.forPath(path).load(),
        throwsA(isA<AppException>()),
      );
    });

    test('默认目录拒绝点路径段，不能越过配置的 WebDAV 根路径', () async {
      final path = '${tempDir.path}${Platform.pathSeparator}bad-directory.json';
      final store = StreamPathConfigStore.forPath(path);
      final config = StreamPathConfig.defaults().upsertProfile(
        const ServerProfile(
          profileId: 'profile-a',
          name: 'A',
          serverUrl: 'https://example.test/dav',
          username: 'alice',
          defaultDirectory: '../private',
        ),
      );

      await expectLater(store.save(config), throwsA(isA<AppException>()));
      expect(File(path).existsSync(), isFalse);
    });

    test('配置提交失败时回滚本次已经改写的凭据', () async {
      final path = '${tempDir.path}${Platform.pathSeparator}rollback.json';
      final secrets = <String, ProfileSecrets>{};
      const first = ServerProfile(
        profileId: 'profile-a',
        name: 'A',
        password: 'old-a',
      );
      const second = ServerProfile(
        profileId: 'profile-b',
        name: 'B',
        password: 'old-b',
      );
      final initialStore = StreamPathConfigStore.forPath(
        path,
        credentialStore: MemoryProfileCredentialStore(secrets),
      );
      await initialStore.save(
        StreamPathConfig.defaults()
            .upsertProfile(first)
            .upsertProfile(second, activate: false),
      );
      final originalFile = await File(path).readAsString();
      final failingStore = StreamPathConfigStore.forPath(
        path,
        credentialStore: _FailingCredentialStore(secrets, failAtWrite: 2),
      );
      final loaded = await failingStore.load();
      final changed = loaded
          .upsertProfile(first.copyWith(password: 'new-a'), activate: false)
          .upsertProfile(second.copyWith(password: 'new-b'), activate: false);

      await expectLater(
        failingStore.save(changed),
        throwsA(isA<AppException>()),
      );

      expect(await File(path).readAsString(), originalFile);
      expect(secrets['profile-a']?.webDavPassword, 'old-a');
      expect(secrets['profile-b']?.webDavPassword, 'old-b');
    });

    test('迁移日志单行损坏时仍保留其他有效结果', () async {
      final path = '${tempDir.path}${Platform.pathSeparator}history.json';
      final log = File('$path.migrations.jsonl');
      await log.writeAsString(
        '${jsonEncode({'timestamp': DateTime.utc(2026, 8, 22).toIso8601String(), 'fromVersion': 1, 'toVersion': 2, 'success': true, 'backupPath': 'valid.bak'})}\n'
        '{broken\n',
      );

      final history = await StreamPathConfigStore.forPath(
        path,
      ).migrationHistory();

      expect(history, hasLength(1));
      expect(history.single.backupPath, 'valid.bak');
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
      expect(
        config.profileId,
        ServerProfile.legacyId(
          serverUrl: 'http://old/dav',
          username: 'old_user',
        ),
      );
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
      final backupDirectories = tempDir
          .listSync()
          .whereType<Directory>()
          .where(
            (directory) => directory.path.contains('migration-legacy-files'),
          )
          .toList();
      expect(backupDirectories, hasLength(1));
      expect(
        File(
          '${backupDirectories.single.path}${Platform.pathSeparator}'
          'connection_config.json',
        ).existsSync(),
        isTrue,
      );
      expect(
        File(
          '${tempDir.path}${Platform.pathSeparator}migrated.json.migrations.jsonl',
        ).existsSync(),
        isTrue,
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

class _FailingCredentialStore implements ProfileCredentialStore {
  _FailingCredentialStore(this.values, {required this.failAtWrite});

  final Map<String, ProfileSecrets> values;
  final int failAtWrite;
  int _writeCount = 0;

  @override
  bool get isSupported => true;

  @override
  Future<ProfileSecrets?> read(String profileId) async => values[profileId];

  @override
  Future<void> write(String profileId, ProfileSecrets secrets) async {
    _writeCount++;
    if (_writeCount == failAtWrite) {
      throw AppException.storage('注入的凭据写入失败');
    }
    values[profileId] = secrets;
  }

  @override
  Future<void> delete(String profileId) async {
    values.remove(profileId);
  }
}
