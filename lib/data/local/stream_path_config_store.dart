import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/app_paths.dart';
import '../models/connection_config.dart';
import '../models/openlist_recovery_config.dart';
import '../models/openlist_index_config.dart';
import '../models/player_config.dart';
import '../models/server_profile.dart';
import '../models/stream_path_config.dart';
import 'profile_credential_store.dart';

class ConfigMigrationRecord {
  const ConfigMigrationRecord({
    required this.timestamp,
    required this.fromVersion,
    required this.toVersion,
    required this.success,
    required this.backupPath,
    this.message,
  });

  final DateTime timestamp;
  final int fromVersion;
  final int toVersion;
  final bool success;
  final String backupPath;
  final String? message;

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toUtc().toIso8601String(),
    'fromVersion': fromVersion,
    'toVersion': toVersion,
    'success': success,
    'backupPath': backupPath,
    if (message != null) 'message': message,
  };
}

/// StreamPath 统一配置管理。
///
/// 配置采用版本化 JSON、原子替换和最近有效备份。服务器档案默认只在
/// JSON 中保存非敏感字段，密码与 Token 写入 Windows 凭据管理器。
class StreamPathConfigStore {
  StreamPathConfigStore._(this._configFile, this._credentialStore);

  final File _configFile;
  final ProfileCredentialStore _credentialStore;
  StreamPathConfig? _cached;
  ConfigMigrationRecord? _lastMigration;
  String? _lastLoadIssue;
  bool _futureSchemaDetected = false;
  final Set<String> _missingCredentialProfileIds = {};

  static final Map<String, ProfileSecrets> _testSecrets = {};

  static Future<StreamPathConfigStore> create() async {
    final dir = await AppPaths.configDirectory();
    return StreamPathConfigStore._(
      File(p.join(dir.path, AppConstants.configFileName)),
      const WindowsProfileCredentialStore(),
    );
  }

  @visibleForTesting
  static StreamPathConfigStore forPath(
    String configFilePath, {
    ProfileCredentialStore? credentialStore,
  }) => StreamPathConfigStore._(
    File(configFilePath),
    credentialStore ?? MemoryProfileCredentialStore(_testSecrets),
  );

  StreamPathConfig get current => _cached ?? StreamPathConfig.defaults();
  String get configFilePath => _configFile.path;
  ConfigMigrationRecord? get lastMigration => _lastMigration;
  String? get lastLoadIssue => _lastLoadIssue;
  Set<String> get missingCredentialProfileIds =>
      Set.unmodifiable(_missingCredentialProfileIds);
  bool get futureSchemaDetected => _futureSchemaDetected;

  File get _backupFile => File('${_configFile.path}.bak');
  File get _migrationLogFile => File('${_configFile.path}.migrations.jsonl');

  Future<StreamPathConfig> load() async {
    if (_cached != null) return _cached!;
    if (!_configFile.existsSync()) {
      await migrateLegacyFiles();
      if (!_configFile.existsSync()) {
        _cached = StreamPathConfig.defaults();
        return _cached!;
      }
    }
    _cached = await _readConfigFile(_configFile, migrate: true);
    _futureSchemaDetected = false;
    return _cached!;
  }

  Future<StreamPathConfig> loadForStartup() async {
    _lastLoadIssue = null;
    try {
      return await load();
    } on AppException catch (error) {
      _lastLoadIssue = error.message;
      if (_futureSchemaDetected) {
        _cached = StreamPathConfig.defaults();
        return _cached!;
      }
      try {
        if (_backupFile.existsSync()) {
          _cached = await _readConfigFile(_backupFile, migrate: false);
          _futureSchemaDetected = false;
          return _cached!;
        }
      } on AppException catch (backupError) {
        _lastLoadIssue = '${error.message}；恢复备份也不可用：${backupError.message}';
      }
      _cached = StreamPathConfig.defaults();
      return _cached!;
    }
  }

  Future<StreamPathConfig> _readConfigFile(
    File file, {
    required bool migrate,
  }) async {
    try {
      final raw = await _readJsonMap(file);
      final version = _schemaVersion(raw['schemaVersion']);
      if (version > StreamPathConfig.currentSchemaVersion) {
        _futureSchemaDetected = true;
        throw AppException.config(
          '配置版本 $version 高于当前支持版本 '
          '${StreamPathConfig.currentSchemaVersion}',
        );
      }
      final migrated = migrate ? await _migrateIfNeeded(raw) : raw;
      return _hydrateConfig(migrated);
    } on FormatException catch (error) {
      throw AppException.config('配置文件损坏：${error.message}', error);
    } on TypeError catch (error) {
      throw AppException.config('配置文件字段类型错误', error);
    } on ArgumentError catch (error) {
      throw AppException.config('配置文件字段值无效', error);
    }
  }

  Future<Map<String, dynamic>> _readJsonMap(File file) async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('配置根节点必须是 JSON 对象');
      }
      return decoded;
    } on FormatException catch (error) {
      throw AppException.config('配置文件损坏：${error.message}', error);
    } on FileSystemException catch (error) {
      throw AppException.storage('读取配置文件失败：${error.message}', error);
    } on TypeError catch (error) {
      throw AppException.config('配置文件字段类型错误', error);
    }
  }

  Future<Map<String, dynamic>> _migrateIfNeeded(
    Map<String, dynamic> raw,
  ) async {
    final fromVersion = _schemaVersion(raw['schemaVersion']);
    if (fromVersion > StreamPathConfig.currentSchemaVersion) {
      throw AppException.config(
        '配置版本 $fromVersion 高于当前支持版本 '
        '${StreamPathConfig.currentSchemaVersion}',
      );
    }
    if (fromVersion == StreamPathConfig.currentSchemaVersion) return raw;

    final timestamp = DateTime.now();
    final stamp = timestamp
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[^0-9]'), '')
        .substring(0, 14);
    final backup = File(
      '${_configFile.path}.migration-v$fromVersion-$stamp.bak',
    );
    try {
      await _configFile.copy(backup.path);
    } on FileSystemException catch (error) {
      final record = ConfigMigrationRecord(
        timestamp: timestamp,
        fromVersion: fromVersion,
        toVersion: StreamPathConfig.currentSchemaVersion,
        success: false,
        backupPath: backup.path,
        message: 'backup_failed',
      );
      await _appendMigrationRecord(record);
      _lastMigration = record;
      throw AppException.storage('配置迁移前备份失败，已停止迁移', error);
    }
    try {
      final migrated = _migrateJson(raw, fromVersion);
      // 含旧明文时直接解析并搬入凭据管理器；已经使用凭据管理器的
      // 中间版本则先补回敏感值，避免迁移覆盖现有凭据。
      final config = _hasInlineProfileSecrets(migrated)
          ? StreamPathConfig.fromJson(migrated)
          : await _hydrateConfig(migrated);
      await _persist(config, createRegularBackup: false);
      final record = ConfigMigrationRecord(
        timestamp: timestamp,
        fromVersion: fromVersion,
        toVersion: StreamPathConfig.currentSchemaVersion,
        success: true,
        backupPath: backup.path,
      );
      await _appendMigrationRecord(record);
      _lastMigration = record;
      return await _readJsonMap(_configFile);
    } catch (error) {
      final record = ConfigMigrationRecord(
        timestamp: timestamp,
        fromVersion: fromVersion,
        toVersion: StreamPathConfig.currentSchemaVersion,
        success: false,
        backupPath: backup.path,
        message: error.runtimeType.toString(),
      );
      await _appendMigrationRecord(record);
      _lastMigration = record;
      rethrow;
    }
  }

  Map<String, dynamic> _migrateJson(Map<String, dynamic> source, int version) {
    final migrated = Map<String, dynamic>.from(source);
    if (version < 1 || source['profiles'] is! List) {
      final serverUrl = (source['serverUrl'] as String?) ?? '';
      final username = (source['username'] as String?) ?? '';
      final password = (source['password'] as String?) ?? '';
      final recovery = OpenListRecoveryConfig.fromJson(
        source['openListRecovery'] is Map
            ? Map<String, dynamic>.from(source['openListRecovery'] as Map)
            : null,
      );
      final hasProfileData =
          serverUrl.trim().isNotEmpty ||
          username.trim().isNotEmpty ||
          password.isNotEmpty ||
          recovery.enabled ||
          recovery.baseUrl.trim().isNotEmpty ||
          recovery.username.trim().isNotEmpty ||
          recovery.password.isNotEmpty ||
          recovery.token.isNotEmpty;
      if (hasProfileData) {
        final id = ServerProfile.legacyId(
          serverUrl: serverUrl,
          username: username,
        );
        final profile = ServerProfile(
          profileId: id,
          name: '默认服务器',
          serverUrl: serverUrl,
          username: username,
          password: password,
          openListRecovery: recovery,
        );
        migrated['profiles'] = [profile.toJson()];
        migrated['activeProfileId'] = id;
      } else {
        migrated['profiles'] = const [];
        migrated['activeProfileId'] = '';
      }
      migrated['credentialStorageMode'] = _credentialStore.isSupported
          ? CredentialStorageMode.windowsCredential.jsonValue
          : CredentialStorageMode.portablePlaintext.jsonValue;
    }
    if (version < 2) {
      migrated.putIfAbsent(
        'credentialStorageMode',
        () => _credentialStore.isSupported
            ? CredentialStorageMode.windowsCredential.jsonValue
            : CredentialStorageMode.portablePlaintext.jsonValue,
      );
    }
    if (version < 3 && migrated['profiles'] is List) {
      migrated['profiles'] = (migrated['profiles'] as List).map((item) {
        if (item is! Map) return item;
        final profile = Map<String, dynamic>.from(item);
        profile.putIfAbsent(
          'openListIndex',
          () => const OpenListIndexConfig().toJson(),
        );
        return profile;
      }).toList();
    }
    if (version < 4) {
      migrated.putIfAbsent('language', () => 'zh-CN');
    }
    if (version < 5) {
      migrated.putIfAbsent('localRoots', () => const []);
    }
    migrated['schemaVersion'] = StreamPathConfig.currentSchemaVersion;
    return migrated;
  }

  Future<StreamPathConfig> _hydrateConfig(Map<String, dynamic> raw) async {
    try {
      final parsed = StreamPathConfig.fromJson(raw);
      if (parsed.credentialStorageMode !=
          CredentialStorageMode.windowsCredential) {
        return parsed;
      }
      if (!_credentialStore.isSupported) {
        throw AppException.storage('当前平台无法读取 Windows 凭据，请使用便携明文模式');
      }
      _missingCredentialProfileIds.clear();
      final profiles = <ServerProfile>[];
      for (final profile in parsed.profiles) {
        final secrets = await _credentialStore.read(profile.profileId);
        if (secrets == null) {
          _missingCredentialProfileIds.add(profile.profileId);
          profiles.add(profile);
          continue;
        }
        profiles.add(
          profile.copyWith(
            password: secrets.webDavPassword,
            openListRecovery: OpenListRecoveryConfig(
              enabled: profile.openListRecovery.enabled,
              baseUrl: profile.openListRecovery.baseUrl,
              username: profile.openListRecovery.username,
              password: secrets.openListPassword,
              token: secrets.openListToken,
            ),
            openListIndex: OpenListIndexConfig(
              autoUpdateEnabled: profile.openListIndex.autoUpdateEnabled,
              updateIntervalMinutes:
                  profile.openListIndex.updateIntervalMinutes,
              userToken: secrets.openListUserToken,
            ),
          ),
        );
      }
      if (profiles.isEmpty) return parsed;
      var hydrated = parsed;
      for (final profile in profiles) {
        hydrated = hydrated.upsertProfile(
          profile,
          activate: profile.profileId == parsed.profileId,
        );
      }
      return hydrated.activateProfile(parsed.profileId);
    } on FormatException catch (error) {
      throw AppException.config('配置文件损坏：${error.message}', error);
    } on TypeError catch (error) {
      throw AppException.config('配置文件字段类型错误', error);
    } on ArgumentError catch (error) {
      throw AppException.config('配置文件字段值无效', error);
    }
  }

  Future<void> save(StreamPathConfig config) async {
    if (_futureSchemaDetected) {
      throw AppException.config('检测到更高版本配置；为避免降级覆盖，当前版本禁止保存');
    }
    final StreamPathConfig safeConfig;
    try {
      safeConfig = _normalizeProfiles(
        StreamPathConfig.fromJson(config.toJson()),
      );
    } on FormatException catch (error) {
      throw AppException.config('配置字段值无效：${error.message}', error);
    } on TypeError catch (error) {
      throw AppException.config('配置字段类型无效', error);
    } on ArgumentError catch (error) {
      throw AppException.config('配置字段值无效', error);
    }
    await _persist(safeConfig, createRegularBackup: true);
    _cached = safeConfig;
  }

  StreamPathConfig _normalizeProfiles(StreamPathConfig config) {
    if (config.profiles.isNotEmpty ||
        (config.serverUrl.trim().isEmpty && config.username.trim().isEmpty)) {
      return config;
    }
    final profile = ServerProfile(
      profileId: ServerProfile.legacyId(
        serverUrl: config.serverUrl,
        username: config.username,
      ),
      name: '默认服务器',
      serverUrl: config.serverUrl,
      username: config.username,
      password: config.password,
      openListRecovery: config.openListRecovery,
    );
    return config.upsertProfile(profile);
  }

  Future<void> _persist(
    StreamPathConfig config, {
    required bool createRegularBackup,
  }) async {
    final previousSecrets = <String, ProfileSecrets?>{};
    final writtenCredentialIds = <String>[];
    var configCommitted = false;
    File? temp;
    try {
      await _configFile.parent.create(recursive: true);
      final previousProfileIds =
          _cached?.profiles.map((profile) => profile.profileId).toSet() ??
          const <String>{};
      final storageJson = config.toJson();
      if (config.credentialStorageMode ==
          CredentialStorageMode.windowsCredential) {
        if (!_credentialStore.isSupported) {
          throw AppException.storage('当前平台不支持 Windows 凭据管理器');
        }
        for (final profile in config.profiles) {
          previousSecrets[profile.profileId] = await _credentialStore.read(
            profile.profileId,
          );
        }
        for (final profile in config.profiles) {
          await _credentialStore.write(
            profile.profileId,
            ProfileSecrets(
              webDavPassword: profile.password,
              openListPassword: profile.openListRecovery.password,
              openListToken: profile.openListRecovery.token,
              openListUserToken: profile.openListIndex.userToken,
            ),
          );
          writtenCredentialIds.add(profile.profileId);
        }
        storageJson['password'] = '';
        storageJson['openListRecovery'] = config.openListRecovery.toJson(
          includeSecrets: false,
        );
        storageJson['profiles'] = config.profiles
            .map((profile) => profile.toJson(includeSecrets: false))
            .toList();
      }
      final body = const JsonEncoder.withIndent('  ').convert(storageJson);
      temp = File('${_configFile.path}.tmp');
      await temp.writeAsString(body, flush: true);

      if (createRegularBackup && _configFile.existsSync()) {
        try {
          await _readJsonMap(_configFile);
          final backupTemp = File('${_backupFile.path}.tmp');
          await _configFile.copy(backupTemp.path);
          await backupTemp.rename(_backupFile.path);
        } catch (_) {
          // 损坏文件不能覆盖最近一次有效备份。
        }
      }
      await temp.rename(_configFile.path);
      configCommitted = true;

      final currentProfileIds = config.profiles
          .map((profile) => profile.profileId)
          .toSet();
      for (final removed in previousProfileIds.difference(currentProfileIds)) {
        try {
          await _credentialStore.delete(removed);
        } catch (_) {
          // 配置已原子提交；残留的不可达凭据不影响档案隔离。
        }
      }
      if (config.credentialStorageMode ==
          CredentialStorageMode.portablePlaintext) {
        for (final profileId in currentProfileIds) {
          try {
            await _credentialStore.delete(profileId);
          } catch (_) {
            // 便携配置已经完整落盘，清理旧凭据失败不影响使用。
          }
        }
      }
    } catch (error) {
      var credentialRollbackFailed = false;
      if (!configCommitted) {
        for (final profileId in writtenCredentialIds.reversed) {
          try {
            final previous = previousSecrets[profileId];
            if (previous == null) {
              await _credentialStore.delete(profileId);
            } else {
              await _credentialStore.write(profileId, previous);
            }
          } catch (_) {
            credentialRollbackFailed = true;
          }
        }
        try {
          if (temp != null && await temp.exists()) await temp.delete();
        } catch (_) {}
      }
      if (credentialRollbackFailed) {
        throw AppException.storage('配置保存失败，且凭据回滚未完整完成', error);
      }
      if (error is FileSystemException) {
        throw AppException.storage('保存配置文件失败：${error.message}', error);
      }
      rethrow;
    }
  }

  Future<void> resetToDefaults() async {
    final oldProfiles = current.profiles
        .map((profile) => profile.profileId)
        .toList();
    final defaults = StreamPathConfig.defaults();
    try {
      await _configFile.parent.create(recursive: true);
      final body = const JsonEncoder.withIndent(
        '  ',
      ).convert(defaults.toJson());
      for (final file in [_backupFile, _configFile]) {
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(body, flush: true);
        await temp.rename(file.path);
      }
      for (final profileId in oldProfiles) {
        try {
          await _credentialStore.delete(profileId);
        } catch (_) {}
      }
      _cached = defaults;
      _futureSchemaDetected = false;
    } on FileSystemException catch (error) {
      throw AppException.storage('重置配置文件失败：${error.message}', error);
    }
  }

  Future<PlayerConfig> loadPlayer() async => (await load()).toPlayerConfig();

  Future<ConnectionConfig> loadConnection() async =>
      (await load()).toConnectionConfig();

  Future<void> saveConnection(ConnectionConfig connection) async {
    final config = await load();
    await save(config.copyWithParts(connection: connection));
  }

  Future<void> activateProfile(String profileId) async {
    await save((await load()).activateProfile(profileId));
  }

  Future<List<ConfigMigrationRecord>> migrationHistory() async {
    if (!await _migrationLogFile.exists()) return const [];
    final records = <ConfigMigrationRecord>[];
    final List<String> lines;
    try {
      lines = await _migrationLogFile.readAsLines();
    } catch (_) {
      return const [];
    }
    for (final line in lines) {
      try {
        if (line.trim().isEmpty) continue;
        final json = jsonDecode(line);
        if (json is! Map) continue;
        final map = Map<String, dynamic>.from(json);
        records.add(
          ConfigMigrationRecord(
            timestamp: DateTime.parse(map['timestamp'] as String),
            fromVersion: (map['fromVersion'] as num).toInt(),
            toVersion: (map['toVersion'] as num).toInt(),
            success: map['success'] as bool,
            backupPath: map['backupPath'] as String,
            message: map['message'] as String?,
          ),
        );
      } catch (_) {
        // 单行损坏时保留其余可解析迁移结果。
      }
    }
    return records;
  }

  Future<void> _appendMigrationRecord(ConfigMigrationRecord record) async {
    try {
      await _migrationLogFile.parent.create(recursive: true);
      await _migrationLogFile.writeAsString(
        '${jsonEncode(record.toJson())}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // 结果日志失败不能覆盖迁移本身的成败。
    }
  }

  @visibleForTesting
  Future<void> migrateLegacyFiles({Directory? legacyDir}) async {
    final Directory supportDir;
    try {
      supportDir = legacyDir ?? await getApplicationSupportDirectory();
    } catch (_) {
      return;
    }
    final oldPlayer = File(
      p.join(supportDir.path, AppConstants.playerConfigFileName),
    );
    final oldConnection = File(
      p.join(supportDir.path, AppConstants.connectionConfigFileName),
    );
    if (!oldPlayer.existsSync() && !oldConnection.existsSync()) return;

    final timestamp = DateTime.now();
    final stamp = timestamp
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[^0-9]'), '')
        .substring(0, 14);
    final backupDirectory = Directory(
      '${_configFile.path}.migration-legacy-files-$stamp.bak',
    );
    late final ConfigMigrationRecord record;
    try {
      await backupDirectory.create(recursive: true);
      for (final file in [oldPlayer, oldConnection]) {
        if (file.existsSync()) {
          await file.copy(p.join(backupDirectory.path, p.basename(file.path)));
        }
      }
      StreamPathConfig merged = StreamPathConfig.defaults();
      if (oldPlayer.existsSync()) {
        final player = PlayerConfig.fromJson(
          jsonDecode(await oldPlayer.readAsString()) as Map<String, dynamic>,
        );
        merged = StreamPathConfig.fromParts(
          player,
          merged.toConnectionConfig(),
        );
      }
      if (oldConnection.existsSync()) {
        final connection = ConnectionConfig.fromJson(
          jsonDecode(await oldConnection.readAsString())
              as Map<String, dynamic>,
        );
        merged = StreamPathConfig.fromParts(
          merged.toPlayerConfig(),
          connection,
        );
      }
      await save(merged);
      for (final file in [oldPlayer, oldConnection]) {
        if (file.existsSync()) {
          try {
            file.deleteSync();
          } catch (_) {}
        }
      }
      record = ConfigMigrationRecord(
        timestamp: timestamp,
        fromVersion: 0,
        toVersion: StreamPathConfig.currentSchemaVersion,
        success: true,
        backupPath: backupDirectory.path,
        message: 'legacy_split_files',
      );
    } catch (error) {
      // 无法解析或保存时保留旧文件，稍后仍可人工恢复。
      record = ConfigMigrationRecord(
        timestamp: timestamp,
        fromVersion: 0,
        toVersion: StreamPathConfig.currentSchemaVersion,
        success: false,
        backupPath: backupDirectory.path,
        message: error.runtimeType.toString(),
      );
    }
    await _appendMigrationRecord(record);
    _lastMigration = record;
  }

  static int _schemaVersion(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  static bool _hasInlineProfileSecrets(Map<String, dynamic> json) {
    final profiles = json['profiles'];
    if (profiles is! List) {
      return (json['password'] as String?)?.isNotEmpty == true;
    }
    for (final value in profiles.whereType<Map>()) {
      if ((value['password'] as String?)?.isNotEmpty == true) return true;
      final recovery = value['openListRecovery'];
      if (recovery is Map &&
          ((recovery['password'] as String?)?.isNotEmpty == true ||
              (recovery['token'] as String?)?.isNotEmpty == true)) {
        return true;
      }
      final index = value['openListIndex'];
      if (index is Map && (index['userToken'] as String?)?.isNotEmpty == true) {
        return true;
      }
    }
    return false;
  }
}
