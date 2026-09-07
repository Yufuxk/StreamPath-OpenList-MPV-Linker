import '../../core/utils/extension_filter.dart';
import '../../core/utils/file_sort.dart';
import '../../core/constants.dart';
import 'app_language.dart';
import 'appearance_config.dart';
import 'connection_config.dart';
import 'local_root_config.dart';
import 'media_library_config.dart';
import 'openlist_recovery_config.dart';
import 'player_config.dart';
import 'server_profile.dart';

/// StreamPath 统一用户配置（平铺结构，集中存放，用户可自行编辑）。
///
/// 存储于数据目录 `stream_path_config.json`：
/// ```json
/// {
///   "serverUrl": "http://192.168.2.124:5244/dav",
///   "username": "user",
///   "password": "pass",
///   "playerName": "mpv",
///   "playerExecutable": "mpv",
///   "playerArgs": ["--sub-file={subfile}", "{url}", "--start={start}"],
///   "subtitleInjectionEnabled": true,
///   "subtitleAutoSelectEnabled": true,
///   "resumeEnabled": true,
///   "hiddenExtensionsEnabled": true,
///   "hiddenExtensions": [".ass"],
///   "defaultSortMode": "name",
///   "defaultSortDirection": "ascending",
///   "appearance": {
///     "style": "classic",
///     "material": "automatic",
///     "glassOpacity": 0.82
///   },
///   "playerStartupTimeoutSeconds": 60,
///   "mediaLibrary": {
///     "maxFavoritesPerSource": 2000,
///     "maxContinuePerLane": 500,
///     "maxRecentPlaybackPerLane": 500,
///     "maxRecentDirectoriesPerSource": 100
///   },
///   "openListRecovery": {"enabled": false}
/// }
/// ```
/// 由 [StreamPathConfigStore] 读写；兼容旧的 player_config.json 与
/// connection_config.json（首次启动自动迁移合并）。
class StreamPathConfig {
  static const int currentSchemaVersion = 5;

  const StreamPathConfig({
    this.schemaVersion = currentSchemaVersion,
    this.profiles = const [],
    this.localRoots = const [],
    this.activeProfileId = '',
    this.credentialStorageMode = CredentialStorageMode.windowsCredential,
    this.language = AppLanguage.simplifiedChinese,
    this.serverUrl = '',
    this.username = '',
    this.password = '',
    this.playerName = 'mpv',
    this.playerExecutable = 'mpv',
    this.playerArgs = const [
      '--sub-file={subfile}',
      '{url}',
      '--start={start}',
    ],
    bool subtitleInjectionEnabled = true,
    bool subtitleAutoSelectEnabled = true,
    bool? subtitleEnabled,
    this.resumeEnabled = true,
    this.menuProgressSharingEnabled = false,
    this.hiddenExtensionsEnabled = true,
    this.hiddenExtensions = const [],
    this.defaultSortMode = FileSortMode.name,
    this.defaultSortDirection = FileSortDirection.ascending,
    this.appearance = const AppearanceConfig(),
    this.playerStartupTimeoutSeconds =
        AppConstants.defaultPlayerStartupTimeoutSeconds,
    this.mediaLibrary = const MediaLibraryConfig(),
    this.openListRecovery = const OpenListRecoveryConfig(),
  }) : subtitleInjectionEnabled = subtitleEnabled ?? subtitleInjectionEnabled,
       subtitleAutoSelectEnabled =
           (subtitleEnabled ?? subtitleInjectionEnabled) &&
           (subtitleEnabled ?? subtitleAutoSelectEnabled);

  // ── 连接信息 ─────────────────────────────────────────────────
  final int schemaVersion;
  final List<ServerProfile> profiles;
  final List<LocalRootConfig> localRoots;
  final String activeProfileId;
  final CredentialStorageMode credentialStorageMode;
  final AppLanguage language;
  final String serverUrl;
  final String username;
  final String password;

  // ── 播放器配置 ───────────────────────────────────────────────
  final String playerName;
  final String playerExecutable;
  final List<String> playerArgs;

  /// 自动匹配并注入同级目录外挂字幕。
  final bool subtitleInjectionEnabled;

  /// 注入后自动选择外挂字幕；依赖 [subtitleInjectionEnabled]。
  final bool subtitleAutoSelectEnabled;

  /// 旧代码兼容访问器；旧总开关语义等于“注入并自动选择”。
  @Deprecated('请分别使用 subtitleInjectionEnabled 与 subtitleAutoSelectEnabled')
  bool get subtitleEnabled =>
      subtitleInjectionEnabled && subtitleAutoSelectEnabled;
  final bool resumeEnabled;

  /// 菜单播放记录正片进度，供 WebDAV Title/MPLS 模式使用。
  final bool menuProgressSharingEnabled;

  // ── 文件浏览 ─────────────────────────────────────────────────
  final bool hiddenExtensionsEnabled;
  final List<String> hiddenExtensions;

  /// 文件浏览页启动时使用的默认排序方式。
  final FileSortMode defaultSortMode;

  /// 文件浏览页启动时使用的默认排序顺序。
  final FileSortDirection defaultSortDirection;

  // ── 界面外观 ─────────────────────────────────────────────────
  final AppearanceConfig appearance;

  /// 新启动的 MPV 等待首个有效播放状态的最长时间（秒）。
  final int playerStartupTimeoutSeconds;

  /// 媒体中心容量与显示数量配置。
  final MediaLibraryConfig mediaLibrary;

  /// MPV 网络播放失败后的 OpenList / AList 自动恢复配置。
  final OpenListRecoveryConfig openListRecovery;

  ServerProfile? get activeProfile {
    if (profiles.isEmpty) return null;
    for (final profile in profiles) {
      if (profile.profileId == activeProfileId) return profile;
    }
    return profiles.first;
  }

  String get profileId => activeProfile?.profileId ?? '';

  /// 是否具备自动连接所需的地址与用户名；密码允许为空。
  bool get isConnectionComplete =>
      serverUrl.trim().isNotEmpty && username.trim().isNotEmpty;

  /// 转 [ConnectionConfig]（供连接逻辑使用）。
  ConnectionConfig toConnectionConfig() => ConnectionConfig(
    baseUrl: serverUrl,
    username: username,
    password: password,
  );

  /// 转 [PlayerConfig]（供播放器服务使用）。
  PlayerConfig toPlayerConfig() => PlayerConfig(
    name: playerName,
    executable: playerExecutable,
    args: playerArgs,
    subtitleInjectionEnabled: subtitleInjectionEnabled,
    subtitleAutoSelectEnabled: subtitleAutoSelectEnabled,
    resumeEnabled: resumeEnabled,
    menuProgressSharingEnabled: menuProgressSharingEnabled,
    hiddenExtensionsEnabled: hiddenExtensionsEnabled,
    hiddenExtensions: hiddenExtensions,
    defaultSortMode: defaultSortMode,
    defaultSortDirection: defaultSortDirection,
    playerStartupTimeoutSeconds: playerStartupTimeoutSeconds,
  );

  /// 由 [PlayerConfig] + [ConnectionConfig] 组合（兼容旧代码路径）。
  factory StreamPathConfig.fromParts(
    PlayerConfig player,
    ConnectionConfig connection, {
    OpenListRecoveryConfig openListRecovery = const OpenListRecoveryConfig(),
    AppearanceConfig appearance = const AppearanceConfig(),
    MediaLibraryConfig mediaLibrary = const MediaLibraryConfig(),
    List<ServerProfile> profiles = const [],
    List<LocalRootConfig> localRoots = const [],
    String activeProfileId = '',
    CredentialStorageMode credentialStorageMode =
        CredentialStorageMode.windowsCredential,
    AppLanguage language = AppLanguage.simplifiedChinese,
  }) {
    return StreamPathConfig(
      serverUrl: connection.baseUrl,
      username: connection.username,
      password: connection.password,
      playerName: player.name,
      playerExecutable: player.executable,
      playerArgs: player.args,
      subtitleInjectionEnabled: player.subtitleInjectionEnabled,
      subtitleAutoSelectEnabled: player.subtitleAutoSelectEnabled,
      resumeEnabled: player.resumeEnabled,
      menuProgressSharingEnabled: player.menuProgressSharingEnabled,
      hiddenExtensionsEnabled: player.hiddenExtensionsEnabled,
      hiddenExtensions: player.hiddenExtensions,
      defaultSortMode: player.defaultSortMode,
      defaultSortDirection: player.defaultSortDirection,
      playerStartupTimeoutSeconds: player.playerStartupTimeoutSeconds,
      mediaLibrary: mediaLibrary,
      openListRecovery: openListRecovery,
      appearance: appearance,
      profiles: profiles,
      localRoots: localRoots,
      activeProfileId: activeProfileId,
      credentialStorageMode: credentialStorageMode,
      language: language,
    );
  }

  /// 替换播放器或连接部分，同时保留其余统一配置。
  StreamPathConfig copyWithParts({
    PlayerConfig? player,
    ConnectionConfig? connection,
    OpenListRecoveryConfig? recovery,
  }) {
    final nextConnection = connection ?? toConnectionConfig();
    final nextRecovery = recovery ?? openListRecovery;
    final nextProfiles = [...profiles];
    if (nextProfiles.isNotEmpty) {
      final index = nextProfiles.indexWhere(
        (profile) => profile.profileId == profileId,
      );
      if (index >= 0) {
        nextProfiles[index] = nextProfiles[index].copyWith(
          serverUrl: nextConnection.baseUrl,
          username: nextConnection.username,
          password: nextConnection.password,
          openListRecovery: nextRecovery,
        );
      }
    }
    return StreamPathConfig.fromParts(
      player ?? toPlayerConfig(),
      nextConnection,
      openListRecovery: nextRecovery,
      appearance: appearance,
      mediaLibrary: mediaLibrary,
      profiles: nextProfiles,
      localRoots: localRoots,
      activeProfileId: activeProfileId,
      credentialStorageMode: credentialStorageMode,
      language: language,
    );
  }

  /// 切换活动档案，同时刷新旧调用链读取的顶层连接兼容视图。
  StreamPathConfig activateProfile(String id) {
    final profile = profiles.where((item) => item.profileId == id).firstOrNull;
    if (profile == null) throw ArgumentError.value(id, 'id', '服务器档案不存在');
    return _copyWithProfileState(profiles, profile.profileId, profile);
  }

  /// 新增或更新档案；档案 ID 是唯一且稳定的数据隔离主键。
  StreamPathConfig upsertProfile(
    ServerProfile profile, {
    bool activate = true,
  }) {
    final next = [...profiles];
    final index = next.indexWhere(
      (item) => item.profileId == profile.profileId,
    );
    if (index < 0) {
      next.add(profile);
    } else {
      next[index] = profile;
    }
    final activeId = activate ? profile.profileId : activeProfileId;
    final active = next.firstWhere(
      (item) => item.profileId == activeId,
      orElse: () => next.first,
    );
    return _copyWithProfileState(next, active.profileId, active);
  }

  StreamPathConfig removeProfile(String id) {
    final next = profiles.where((item) => item.profileId != id).toList();
    if (next.isEmpty) return _copyWithProfileState(const [], '', null);
    final active = next.firstWhere(
      (item) => item.profileId == activeProfileId,
      orElse: () => next.first,
    );
    return _copyWithProfileState(next, active.profileId, active);
  }

  StreamPathConfig withCredentialStorageMode(CredentialStorageMode mode) =>
      _copyWithProfileState(
        profiles,
        activeProfileId,
        activeProfile,
        credentialStorageMode: mode,
      );

  StreamPathConfig copyWithGlobalSettings({
    required PlayerConfig player,
    required AppearanceConfig appearance,
    required MediaLibraryConfig mediaLibrary,
    AppLanguage? language,
  }) => StreamPathConfig(
    schemaVersion: currentSchemaVersion,
    profiles: profiles,
    localRoots: localRoots,
    activeProfileId: activeProfileId,
    credentialStorageMode: credentialStorageMode,
    language: language ?? this.language,
    serverUrl: serverUrl,
    username: username,
    password: password,
    playerName: player.name,
    playerExecutable: player.executable,
    playerArgs: player.args,
    subtitleInjectionEnabled: player.subtitleInjectionEnabled,
    subtitleAutoSelectEnabled: player.subtitleAutoSelectEnabled,
    resumeEnabled: player.resumeEnabled,
    menuProgressSharingEnabled: player.menuProgressSharingEnabled,
    hiddenExtensionsEnabled: player.hiddenExtensionsEnabled,
    hiddenExtensions: player.hiddenExtensions,
    defaultSortMode: player.defaultSortMode,
    defaultSortDirection: player.defaultSortDirection,
    appearance: appearance,
    playerStartupTimeoutSeconds: player.playerStartupTimeoutSeconds,
    mediaLibrary: mediaLibrary,
    openListRecovery: openListRecovery,
  );

  StreamPathConfig _copyWithProfileState(
    List<ServerProfile> nextProfiles,
    String nextActiveId,
    ServerProfile? nextActive, {
    CredentialStorageMode? credentialStorageMode,
  }) => StreamPathConfig(
    schemaVersion: currentSchemaVersion,
    profiles: List.unmodifiable(nextProfiles),
    localRoots: localRoots,
    activeProfileId: nextActiveId,
    credentialStorageMode: credentialStorageMode ?? this.credentialStorageMode,
    language: language,
    serverUrl: nextActive?.serverUrl ?? '',
    username: nextActive?.username ?? '',
    password: nextActive?.password ?? '',
    playerName: playerName,
    playerExecutable: playerExecutable,
    playerArgs: playerArgs,
    subtitleInjectionEnabled: subtitleInjectionEnabled,
    subtitleAutoSelectEnabled: subtitleAutoSelectEnabled,
    resumeEnabled: resumeEnabled,
    menuProgressSharingEnabled: menuProgressSharingEnabled,
    hiddenExtensionsEnabled: hiddenExtensionsEnabled,
    hiddenExtensions: hiddenExtensions,
    defaultSortMode: defaultSortMode,
    defaultSortDirection: defaultSortDirection,
    appearance: appearance,
    playerStartupTimeoutSeconds: playerStartupTimeoutSeconds,
    mediaLibrary: mediaLibrary,
    openListRecovery:
        nextActive?.openListRecovery ?? const OpenListRecoveryConfig(),
  );

  /// 内置默认配置（mpv）。
  static StreamPathConfig defaults() => const StreamPathConfig();

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schemaVersion': currentSchemaVersion,
    'profiles': profiles.map((profile) => profile.toJson()).toList(),
    'localRoots': localRoots.map((root) => root.toJson()).toList(),
    'activeProfileId': activeProfileId,
    'credentialStorageMode': credentialStorageMode.jsonValue,
    'language': language.configValue,
    'serverUrl': serverUrl,
    'username': username,
    'password': password,
    'playerName': playerName,
    'playerExecutable': playerExecutable,
    'playerArgs': playerArgs,
    'subtitleInjectionEnabled': subtitleInjectionEnabled,
    'subtitleAutoSelectEnabled': subtitleAutoSelectEnabled,
    'resumeEnabled': resumeEnabled,
    'menuProgressSharingEnabled': menuProgressSharingEnabled,
    'hiddenExtensionsEnabled': hiddenExtensionsEnabled,
    'hiddenExtensions': hiddenExtensions,
    'defaultSortMode': defaultSortMode.jsonValue,
    'defaultSortDirection': defaultSortDirection.jsonValue,
    'appearance': appearance.toJson(),
    'playerStartupTimeoutSeconds': playerStartupTimeoutSeconds,
    'mediaLibrary': mediaLibrary.toJson(),
    'openListRecovery': openListRecovery.toJson(),
  };

  factory StreamPathConfig.fromJson(Map<String, dynamic> json) {
    final rawSchemaVersion = json['schemaVersion'];
    final schemaVersion = rawSchemaVersion is num
        ? rawSchemaVersion.toInt()
        : rawSchemaVersion is String
        ? int.tryParse(rawSchemaVersion) ?? 0
        : 0;
    if (schemaVersion > currentSchemaVersion) {
      throw FormatException('配置版本 $schemaVersion 高于当前支持版本');
    }
    final profiles =
        (json['profiles'] as List?)
            ?.whereType<Map>()
            .map(
              (item) => ServerProfile.fromJson(Map<String, dynamic>.from(item)),
            )
            .toList(growable: false) ??
        const <ServerProfile>[];
    final localRoots = _parseLocalRoots(json['localRoots']);
    final profileIds = profiles.map((profile) => profile.profileId).toSet();
    if (profileIds.length != profiles.length) {
      throw const FormatException('服务器档案 profileId 必须唯一');
    }
    final requestedActiveId = (json['activeProfileId'] as String?) ?? '';
    final selectedProfile = profiles.isEmpty
        ? null
        : profiles.firstWhere(
            (profile) => profile.profileId == requestedActiveId,
            orElse: () => profiles.first,
          );
    final legacyEnabled = json['subtitleEnabled'] as bool?;
    final injectionEnabled =
        (json['subtitleInjectionEnabled'] as bool?) ?? legacyEnabled ?? true;
    final autoSelectEnabled =
        injectionEnabled &&
        ((json['subtitleAutoSelectEnabled'] as bool?) ?? legacyEnabled ?? true);
    return StreamPathConfig(
      schemaVersion: schemaVersion == 0 ? currentSchemaVersion : schemaVersion,
      profiles: profiles,
      localRoots: localRoots,
      activeProfileId: selectedProfile?.profileId ?? '',
      credentialStorageMode: CredentialStorageModeJson.fromJson(
        json['credentialStorageMode'],
      ),
      language: AppLanguage.fromJson(json['language']),
      serverUrl:
          selectedProfile?.serverUrl ?? (json['serverUrl'] as String?) ?? '',
      username:
          selectedProfile?.username ?? (json['username'] as String?) ?? '',
      password:
          selectedProfile?.password ?? (json['password'] as String?) ?? '',
      playerName: (json['playerName'] as String?) ?? '播放器',
      playerExecutable: (json['playerExecutable'] as String?) ?? '',
      playerArgs:
          (json['playerArgs'] as List?)?.whereType<String>().toList() ??
          const [],
      subtitleInjectionEnabled: injectionEnabled,
      subtitleAutoSelectEnabled: autoSelectEnabled,
      resumeEnabled: (json['resumeEnabled'] as bool?) ?? true,
      menuProgressSharingEnabled: (json['menuProgressSharingEnabled'] as bool?) ?? false,
      hiddenExtensionsEnabled:
          (json['hiddenExtensionsEnabled'] as bool?) ?? true,
      hiddenExtensions:
          (json['hiddenExtensions'] as List?)
              ?.whereType<String>()
              .map(normalizeExtension)
              .whereType<String>()
              .toList() ??
          const [],
      defaultSortMode: fileSortModeFromJson(json['defaultSortMode']),
      defaultSortDirection: fileSortDirectionFromJson(
        json['defaultSortDirection'],
      ),
      appearance: AppearanceConfig.fromJson(
        json['appearance'] is Map
            ? Map<String, dynamic>.from(json['appearance'] as Map)
            : null,
      ),
      playerStartupTimeoutSeconds: playerStartupTimeoutSecondsFromJson(
        json['playerStartupTimeoutSeconds'],
      ),
      mediaLibrary: MediaLibraryConfig.fromJson(
        json['mediaLibrary'] is Map
            ? Map<String, dynamic>.from(json['mediaLibrary'] as Map)
            : null,
      ),
      openListRecovery:
          selectedProfile?.openListRecovery ??
          OpenListRecoveryConfig.fromJson(
            json['openListRecovery'] is Map
                ? Map<String, dynamic>.from(json['openListRecovery'] as Map)
                : null,
          ),
    );
  }

  StreamPathConfig withLocalRoots(List<LocalRootConfig> roots) =>
      StreamPathConfig(
        schemaVersion: currentSchemaVersion,
        profiles: profiles,
        localRoots: List.unmodifiable(roots),
        activeProfileId: activeProfileId,
        credentialStorageMode: credentialStorageMode,
        language: language,
        serverUrl: serverUrl,
        username: username,
        password: password,
        playerName: playerName,
        playerExecutable: playerExecutable,
        playerArgs: playerArgs,
        subtitleInjectionEnabled: subtitleInjectionEnabled,
        subtitleAutoSelectEnabled: subtitleAutoSelectEnabled,
        resumeEnabled: resumeEnabled,
        menuProgressSharingEnabled: menuProgressSharingEnabled,
        hiddenExtensionsEnabled: hiddenExtensionsEnabled,
        hiddenExtensions: hiddenExtensions,
        defaultSortMode: defaultSortMode,
        defaultSortDirection: defaultSortDirection,
        appearance: appearance,
        playerStartupTimeoutSeconds: playerStartupTimeoutSeconds,
        mediaLibrary: mediaLibrary,
        openListRecovery: openListRecovery,
      );

  StreamPathConfig upsertLocalRoot(LocalRootConfig root) {
    final next = [...localRoots];
    final index = next.indexWhere((item) => item.rootId == root.rootId);
    if (index < 0) {
      next.add(root);
    } else {
      next[index] = root;
    }
    return withLocalRoots(next);
  }

  StreamPathConfig removeLocalRoot(String rootId) => withLocalRoots(
    localRoots.where((root) => root.rootId != rootId).toList(growable: false),
  );

  static List<LocalRootConfig> _parseLocalRoots(Object? value) {
    if (value is! List) return const [];
    final roots = <LocalRootConfig>[];
    final ids = <String>{};
    final paths = <String>{};
    for (final item in value.whereType<Map>()) {
      try {
        final root = LocalRootConfig.fromJson(Map<String, dynamic>.from(item));
        if (!ids.add(root.rootId) || !paths.add(root.path.toLowerCase())) {
          continue;
        }
        roots.add(root);
      } on FormatException {
        // 单个本地根损坏不阻断 WebDAV 配置读取。
      } on TypeError {
        // 单个本地根损坏不阻断 WebDAV 配置读取。
      }
    }
    return List.unmodifiable(roots);
  }
}
