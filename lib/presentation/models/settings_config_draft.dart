import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/utils/extension_filter.dart';
import '../../core/utils/file_sort.dart';
import '../../data/models/appearance_config.dart';
import '../../data/models/app_language.dart';
import '../../data/models/media_library_config.dart';
import '../../data/models/openlist_index_config.dart';
import '../../data/models/openlist_recovery_config.dart';
import '../../data/models/player_config.dart';
import '../../data/models/server_profile.dart';
import '../../data/models/stream_path_config.dart';
import '../../features/cache_control/models/cache_intelligence_config.dart';
import '../../features/cache_control/models/cache_policy_config.dart';
import '../../features/cache_expiration/models/cache_expiration_config.dart';

/// 设置页尚未保存的编辑草稿。
///
/// 草稿只负责表单值与配置模型之间的转换；持久化顺序、凭据回滚和窗口外观回退
/// 仍由设置页原有提交流程控制。
class SettingsConfigDraft {
  final nameController = TextEditingController();
  final executableController = TextEditingController();
  final argsController = TextEditingController();
  final hiddenExtensionsController = TextEditingController();
  final serverUrlController = TextEditingController();
  final serverUsernameController = TextEditingController();
  final serverPasswordController = TextEditingController();
  final profileNameController = TextEditingController();
  final defaultDirectoryController = TextEditingController();
  final openListBaseUrlController = TextEditingController();
  final openListUsernameController = TextEditingController();
  final openListPasswordController = TextEditingController();
  final openListTokenController = TextEditingController();
  final openListIndexUserTokenController = TextEditingController();
  final openListIndexIntervalController = TextEditingController();
  final cacheMemoryRatioController = TextEditingController();
  final cacheBaseSecsController = TextEditingController();
  final cacheSmallFileController = TextEditingController();
  final cacheBandwidthController = TextEditingController();
  final intelligenceMinSamplesController = TextEditingController();
  final intelligenceMaxAdjustmentController = TextEditingController();
  final directoryFreshnessController = TextEditingController();
  final directoryRetentionController = TextEditingController();
  final directoryScrollRetentionController = TextEditingController();
  final playbackRetentionController = TextEditingController();
  final mediaMetadataRetentionController = TextEditingController();
  final mediaLibraryFavoritesController = TextEditingController();
  final mediaLibraryContinueController = TextEditingController();
  final mediaLibraryRecentPlaybackController = TextEditingController();
  final mediaLibraryRecentDirectoriesController = TextEditingController();

  bool subtitleInjectionEnabled = true;
  bool subtitleAutoSelectEnabled = true;
  bool resumeEnabled = true;
  bool menuProgressSharingEnabled = false;
  MediaLibrarySharingMode mediaLibrarySharingMode =
      MediaLibrarySharingMode.independent;
  bool hiddenExtensionsEnabled = true;
  FileSortMode defaultSortMode = FileSortMode.name;
  FileSortDirection defaultSortDirection = FileSortDirection.ascending;
  int playerStartupTimeoutSeconds =
      AppConstants.defaultPlayerStartupTimeoutSeconds;
  bool openListRecoveryEnabled = false;
  bool openListIndexAutoUpdateEnabled = false;
  List<ServerProfile> profiles = const [];
  String? selectedProfileId;
  CredentialStorageMode credentialStorageMode =
      CredentialStorageMode.windowsCredential;
  bool cacheEnabled = true;
  CachePolicyMode cacheMode = CachePolicyMode.auto;
  bool overrideUserCacheArgs = false;
  bool intelligenceEnabled = true;
  bool applyIntelligence = false;
  bool bitratePredictionEnabled = true;
  bool storageOptimizationEnabled = true;
  bool habitLearningEnabled = true;
  InterfaceStyle interfaceStyle = InterfaceStyle.classic;
  WindowMaterialPreference windowMaterial = WindowMaterialPreference.automatic;
  double glassOpacity = AppearanceConfig.defaultGlassOpacity;
  AppLanguage language = AppLanguage.simplifiedChinese;

  void loadFrom({
    required StreamPathConfig fullConfig,
    required AppearanceConfig appearance,
    required CachePolicyConfig cacheConfig,
    required CacheIntelligenceConfig intelligenceConfig,
    required CacheExpirationConfig expirationConfig,
  }) {
    final player = fullConfig.toPlayerConfig();
    mediaLibrarySharingMode = fullConfig.mediaLibrary.sharingMode;
    final connection = fullConfig.toConnectionConfig();
    nameController.text = player.name;
    executableController.text = player.executable;
    argsController.text = player.args.join('\n');
    hiddenExtensionsController.text = formatHiddenExtensions(
      player.hiddenExtensions,
    );
    serverUrlController.text = connection.baseUrl;
    serverUsernameController.text = connection.username;
    serverPasswordController.text = connection.password;
    profiles = [...fullConfig.profiles];
    selectedProfileId = fullConfig.profileId.isEmpty
        ? null
        : fullConfig.profileId;
    profileNameController.text = fullConfig.activeProfile?.name ?? '默认服务器';
    defaultDirectoryController.text =
        fullConfig.activeProfile?.defaultDirectory ?? '';
    credentialStorageMode = fullConfig.credentialStorageMode;
    openListRecoveryEnabled = fullConfig.openListRecovery.enabled;
    openListBaseUrlController.text = fullConfig.openListRecovery.baseUrl;
    openListUsernameController.text = fullConfig.openListRecovery.username;
    openListPasswordController.text = fullConfig.openListRecovery.password;
    openListTokenController.text = fullConfig.openListRecovery.token;
    final indexConfig =
        fullConfig.activeProfile?.openListIndex ?? const OpenListIndexConfig();
    openListIndexAutoUpdateEnabled = indexConfig.autoUpdateEnabled;
    openListIndexUserTokenController.text = indexConfig.userToken;
    openListIndexIntervalController.text = indexConfig.updateIntervalMinutes
        .toString();
    subtitleInjectionEnabled = player.subtitleInjectionEnabled;
    subtitleAutoSelectEnabled = player.subtitleAutoSelectEnabled;
    resumeEnabled = player.resumeEnabled;
    menuProgressSharingEnabled = player.menuProgressSharingEnabled;
    hiddenExtensionsEnabled = player.hiddenExtensionsEnabled;
    defaultSortMode = player.defaultSortMode;
    defaultSortDirection = player.defaultSortDirection;
    playerStartupTimeoutSeconds = player.playerStartupTimeoutSeconds;
    mediaLibraryFavoritesController.text = fullConfig
        .mediaLibrary
        .maxFavoritesPerSource
        .toString();
    mediaLibraryContinueController.text = fullConfig
        .mediaLibrary
        .maxContinuePerLane
        .toString();
    mediaLibraryRecentPlaybackController.text = fullConfig
        .mediaLibrary
        .maxRecentPlaybackPerLane
        .toString();
    mediaLibraryRecentDirectoriesController.text = fullConfig
        .mediaLibrary
        .maxRecentDirectoriesPerSource
        .toString();
    cacheEnabled = cacheConfig.enabled;
    cacheMode = cacheConfig.mode;
    cacheMemoryRatioController.text = (cacheConfig.memoryBudgetRatio * 100)
        .toStringAsFixed(0);
    cacheBaseSecsController.text = cacheConfig.baseCacheSecs.toString();
    cacheSmallFileController.text = cacheConfig.smallFileThresholdMB.toString();
    cacheBandwidthController.text =
        cacheConfig.assumedBandwidthMbps?.toString() ?? '';
    overrideUserCacheArgs = cacheConfig.overrideUserCacheArgs;
    intelligenceEnabled = intelligenceConfig.enabled;
    applyIntelligence = intelligenceConfig.applyOptimizations;
    bitratePredictionEnabled = intelligenceConfig.bitratePredictionEnabled;
    storageOptimizationEnabled = intelligenceConfig.storageOptimizationEnabled;
    habitLearningEnabled = intelligenceConfig.habitLearningEnabled;
    intelligenceMinSamplesController.text = intelligenceConfig.minSamples
        .toString();
    intelligenceMaxAdjustmentController.text =
        (intelligenceConfig.maxAdjustmentRatio * 100).toStringAsFixed(0);
    interfaceStyle = appearance.style;
    windowMaterial = appearance.material;
    glassOpacity = appearance.glassOpacity;
    language = fullConfig.language;
    directoryFreshnessController.text = expirationConfig
        .directoryFreshnessMinutes
        .toString();
    directoryRetentionController.text = expirationConfig.directoryRetentionDays
        .toString();
    directoryScrollRetentionController.text = expirationConfig
        .directoryScrollRetentionMinutes
        .toString();
    playbackRetentionController.text = expirationConfig.playbackRetentionDays
        .toString();
    mediaMetadataRetentionController.text = expirationConfig
        .mediaMetadataRetentionDays
        .toString();
  }

  PlayerConfig buildPlayerConfig() => PlayerConfig(
    name: nameController.text.trim().isEmpty
        ? '外部播放器'
        : nameController.text.trim(),
    executable: executableController.text.trim(),
    args: argsController.text
        .split('\n')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(),
    subtitleInjectionEnabled: subtitleInjectionEnabled,
    subtitleAutoSelectEnabled:
        subtitleInjectionEnabled && subtitleAutoSelectEnabled,
    resumeEnabled: resumeEnabled,
    menuProgressSharingEnabled: menuProgressSharingEnabled,
    hiddenExtensionsEnabled: hiddenExtensionsEnabled,
    hiddenExtensions: parseHiddenExtensions(hiddenExtensionsController.text),
    defaultSortMode: defaultSortMode,
    defaultSortDirection: defaultSortDirection,
    playerStartupTimeoutSeconds: playerStartupTimeoutSeconds,
  );

  CachePolicyConfig buildCachePolicyConfig() {
    final bandwidth = cacheBandwidthController.text.trim();
    return CachePolicyConfig(
      enabled: cacheEnabled,
      mode: cacheMode,
      memoryBudgetRatio:
          double.parse(cacheMemoryRatioController.text.trim()) / 100,
      baseCacheSecs: int.parse(cacheBaseSecsController.text.trim()),
      smallFileThresholdMB: int.parse(cacheSmallFileController.text.trim()),
      assumedBandwidthMbps: bandwidth.isEmpty ? null : double.parse(bandwidth),
      overrideUserCacheArgs: overrideUserCacheArgs,
    );
  }

  CacheIntelligenceConfig buildIntelligenceConfig() => CacheIntelligenceConfig(
    enabled: intelligenceEnabled,
    applyOptimizations: applyIntelligence,
    bitratePredictionEnabled: bitratePredictionEnabled,
    storageOptimizationEnabled: storageOptimizationEnabled,
    habitLearningEnabled: habitLearningEnabled,
    minSamples: int.parse(intelligenceMinSamplesController.text.trim()),
    maxAdjustmentRatio:
        double.parse(intelligenceMaxAdjustmentController.text.trim()) / 100,
  );

  CacheExpirationConfig buildExpirationConfig() => CacheExpirationConfig(
    directoryFreshnessMinutes: int.parse(
      directoryFreshnessController.text.trim(),
    ),
    directoryRetentionDays: int.parse(directoryRetentionController.text.trim()),
    directoryScrollRetentionMinutes: int.parse(
      directoryScrollRetentionController.text.trim(),
    ),
    playbackRetentionDays: int.parse(playbackRetentionController.text.trim()),
    mediaMetadataRetentionDays: int.parse(
      mediaMetadataRetentionController.text.trim(),
    ),
  );

  OpenListRecoveryConfig buildOpenListRecoveryConfig() =>
      OpenListRecoveryConfig(
        enabled: openListRecoveryEnabled,
        baseUrl: openListBaseUrlController.text.trim(),
        username: openListUsernameController.text.trim(),
        password: openListPasswordController.text,
        token: openListTokenController.text.trim(),
      );

  OpenListIndexConfig buildOpenListIndexConfig() => OpenListIndexConfig(
    autoUpdateEnabled: openListIndexAutoUpdateEnabled,
    updateIntervalMinutes:
        int.tryParse(openListIndexIntervalController.text.trim()) ??
        OpenListIndexConfig.defaultUpdateIntervalMinutes,
    userToken: openListIndexUserTokenController.text.trim(),
  ).normalized;

  AppearanceConfig buildAppearanceConfig() => AppearanceConfig(
    style: interfaceStyle,
    material: windowMaterial,
    glassOpacity: glassOpacity,
  );

  MediaLibraryConfig buildMediaLibraryConfig() => MediaLibraryConfig(
    sharingMode: mediaLibrarySharingMode,
    maxFavoritesPerSource: int.parse(
      mediaLibraryFavoritesController.text.trim(),
    ),
    maxContinuePerLane: int.parse(mediaLibraryContinueController.text.trim()),
    maxRecentPlaybackPerLane: int.parse(
      mediaLibraryRecentPlaybackController.text.trim(),
    ),
    maxRecentDirectoriesPerSource: int.parse(
      mediaLibraryRecentDirectoriesController.text.trim(),
    ),
  ).normalized;

  ServerProfile buildProfile({required String profileId}) => ServerProfile(
    profileId: profileId,
    name: profileNameController.text.trim(),
    serverUrl: serverUrlController.text.trim(),
    username: serverUsernameController.text.trim(),
    password: serverPasswordController.text,
    defaultDirectory: defaultDirectoryController.text.trim(),
    openListRecovery: buildOpenListRecoveryConfig(),
    openListIndex: buildOpenListIndexConfig(),
  );

  void dispose() {
    for (final controller in <TextEditingController>[
      nameController,
      executableController,
      argsController,
      hiddenExtensionsController,
      serverUrlController,
      serverUsernameController,
      serverPasswordController,
      profileNameController,
      defaultDirectoryController,
      openListBaseUrlController,
      openListUsernameController,
      openListPasswordController,
      openListTokenController,
      openListIndexUserTokenController,
      openListIndexIntervalController,
      cacheMemoryRatioController,
      cacheBaseSecsController,
      cacheSmallFileController,
      cacheBandwidthController,
      intelligenceMinSamplesController,
      intelligenceMaxAdjustmentController,
      directoryFreshnessController,
      directoryRetentionController,
      directoryScrollRetentionController,
      playbackRetentionController,
      mediaMetadataRetentionController,
      mediaLibraryFavoritesController,
      mediaLibraryContinueController,
      mediaLibraryRecentPlaybackController,
      mediaLibraryRecentDirectoriesController,
    ]) {
      controller.dispose();
    }
  }
}
