import '../../data/models/episode_network_failure_mode.dart';
import '../../data/models/video_playlist_mode.dart';
import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/utils/extension_filter.dart';
import '../../core/utils/file_sort.dart';
import '../../data/models/appearance_config.dart';
import '../../data/models/accent_color_preset.dart';
import '../../data/models/app_language.dart';
import '../../data/models/media_library_config.dart';
import '../../data/models/openlist_index_config.dart';
import '../../data/models/openlist_recovery_config.dart';
import '../../data/models/disc_title_selection_policy.dart';
import '../../data/models/film_directory_exclusions.dart';
import '../../data/models/player_config.dart';
import '../../data/models/mpv_menu_shortcuts.dart';
import '../../data/models/video_window_mode.dart';
import '../../data/models/special_playlist_mode.dart';
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
  final videoCacheDirectoryController = TextEditingController();
  final excludedFoldersController = TextEditingController();
  final exactFolderExclusions = ValueNotifier(false);
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
  final implicitPlaylistWindowController = TextEditingController();
  final audioLyricsFontFamilyController = TextEditingController();

  final menuShortcutControllers = List.generate(
    5,
    (_) => TextEditingController(),
  );
  MpvMenuShortcuts? menuShortcuts;
  bool menuShortcutsChanged = false;

  VideoWindowMode videoWindowMode = VideoWindowMode.external;
  bool subtitleInjectionEnabled = true;
  bool subtitleAutoSelectEnabled = true;
  bool argInjectionAllEnabled = true;
  bool argInjectionAnimeEnabled = false;
  bool argInjectionMovieEnabled = false;
  bool argInjectionSeriesEnabled = false;
  bool audioDynamicLyricsEnabled = true;
  double audioLyricsOutlineWidth = PlayerConfig.defaultAudioLyricsOutlineWidth;
  double audioLyricsTransparency = PlayerConfig.defaultAudioLyricsTransparency;
  bool resumeEnabled = true;
  bool menuProgressSharingEnabled = false;
  SpecialPlaylistMode specialPlaylistMode = SpecialPlaylistMode.ovaOnly;
  bool scanSpecialChildFolders = true;
  bool scanSpecialSiblingFolders = false;
  bool sharePlaylistFonts = false;
  bool webDavFontCacheEnabled = true;
  bool externalAudioInjectionEnabled = true;
  VideoPlaylistMode videoPlaylistMode = VideoPlaylistMode.implicit;
  EpisodeNetworkFailureMode episodeNetworkFailureMode =
      EpisodeNetworkFailureMode.stop;
  bool videoPlaylistSimpleNaming = true;
  DiscTitleSelectionPolicy discTitleSelectionPolicy =
      DiscTitleSelectionPolicy.full;
  bool videoPlaylistInsertDecimalEpisodes = false;
  bool autoSeasonTransitionEnabled = true;
  bool allowSeasonGap = false;
  MediaLibrarySharingMode mediaLibrarySharingMode =
      MediaLibrarySharingMode.networkAndLocalShared;
  bool hiddenExtensionsEnabled = true;
  FileSortMode defaultSortMode = FileSortMode.name;
  FileSortDirection defaultSortDirection = FileSortDirection.ascending;
  int playerStartupTimeoutSeconds =
      AppConstants.defaultPlayerStartupTimeoutSeconds;
  bool openListRecoveryEnabled = false;
  OpenListRestartDirectory openListRestartDirectory =
      OpenListRestartDirectory.userProfile;
  bool openListIndexAutoUpdateEnabled = false;
  List<ServerProfile> profiles = const [];
  String? selectedProfileId;
  CredentialStorageMode credentialStorageMode =
      CredentialStorageMode.windowsCredential;
  bool cacheEnabled = true;
  CachePolicyMode cacheMode = CachePolicyMode.auto;
  bool overrideUserCacheArgs = false;
  bool intelligenceEnabled = true;
  bool applyIntelligence = true;
  bool bitratePredictionEnabled = true;
  bool storageOptimizationEnabled = true;
  bool habitLearningEnabled = true;
  InterfaceStyle interfaceStyle = InterfaceStyle.classic;
  WindowMaterialPreference windowMaterial = WindowMaterialPreference.automatic;
  double glassOpacity = AppearanceConfig.defaultGlassOpacity;
  String? interfaceFontFamily;
  int interfaceFontWeightOffset = 0;
  int accentColor = AccentColorPreset.blue.argb;
  DirectoryMemoryMode directoryMemoryMode = DirectoryMemoryMode.temporary;
  AppLanguage language = AppLanguage.simplifiedChinese;

  void loadFrom({
    required StreamPathConfig fullConfig,
    required AppearanceConfig appearance,
    required CachePolicyConfig cacheConfig,
    required CacheIntelligenceConfig intelligenceConfig,
    required CacheExpirationConfig expirationConfig,
  }) {
    final player = fullConfig.toPlayerConfig();
    videoWindowMode = player.videoWindowMode;
    menuShortcuts = player.mpvMenuShortcuts;
    menuShortcutsChanged = false;
    final shortcuts = (menuShortcuts ?? const MpvMenuShortcuts()).values;
    for (var i = 0; i < shortcuts.length; i++) {
      menuShortcutControllers[i].text = shortcuts[i];
    }
    mediaLibrarySharingMode = fullConfig.mediaLibrary.sharingMode;
    final connection = fullConfig.toConnectionConfig();
    nameController.text = player.name;
    executableController.text = player.executable;
    argsController.text = player.args.join('\n');
    argInjectionAllEnabled = player.argInjectionAllEnabled;
    argInjectionAnimeEnabled = player.argInjectionAnimeEnabled;
    argInjectionMovieEnabled = player.argInjectionMovieEnabled;
    argInjectionSeriesEnabled = player.argInjectionSeriesEnabled;
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
    openListRestartDirectory = fullConfig.openListRecovery.restartDirectory;
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
    audioDynamicLyricsEnabled = player.audioDynamicLyricsEnabled;
    audioLyricsFontFamilyController.text = player.audioLyricsFontFamily;
    audioLyricsOutlineWidth = player.audioLyricsOutlineWidth;
    audioLyricsTransparency = player.audioLyricsTransparency;
    resumeEnabled = player.resumeEnabled;
    menuProgressSharingEnabled = player.menuProgressSharingEnabled;
    specialPlaylistMode = player.specialPlaylistMode;
    scanSpecialChildFolders = player.scanSpecialChildFolders;
    scanSpecialSiblingFolders = player.scanSpecialSiblingFolders;
    sharePlaylistFonts = player.sharePlaylistFonts;
    webDavFontCacheEnabled = player.webDavFontCacheEnabled;
    externalAudioInjectionEnabled = player.externalAudioInjectionEnabled;
    videoPlaylistMode = player.videoPlaylistMode;
    episodeNetworkFailureMode = player.episodeNetworkFailureMode;
    videoPlaylistSimpleNaming = player.videoPlaylistSimpleNaming;
    discTitleSelectionPolicy = player.discTitleSelectionPolicy;
    videoPlaylistInsertDecimalEpisodes =
        player.videoPlaylistInsertDecimalEpisodes;
    implicitPlaylistWindowController.text = player.implicitPlaylistWindowSize
        .toString();
    autoSeasonTransitionEnabled = player.autoSeasonTransitionEnabled;
    allowSeasonGap = player.allowSeasonGap;
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
    cacheMemoryRatioController.text = _formatPercentage(
      cacheConfig.memoryBudgetRatio,
    );
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
    intelligenceMaxAdjustmentController.text = _formatPercentage(
      intelligenceConfig.maxAdjustmentRatio,
    );
    interfaceStyle = appearance.style;
    windowMaterial = appearance.material;
    glassOpacity = appearance.glassOpacity;
    interfaceFontFamily = appearance.fontFamily;
    interfaceFontWeightOffset = appearance.fontWeightOffset;
    accentColor = appearance.accentColor;
    directoryMemoryMode = fullConfig.appearance.directoryMemoryMode;
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
    videoWindowMode: videoWindowMode,
    mpvMenuShortcuts: menuShortcutsChanged
        ? MpvMenuShortcuts(
            open: menuShortcutControllers[0].text.trim(),
            up: menuShortcutControllers[1].text.trim(),
            down: menuShortcutControllers[2].text.trim(),
            confirm: menuShortcutControllers[3].text.trim(),
            close: menuShortcutControllers[4].text.trim(),
          )
        : menuShortcuts,
    argInjectionAllEnabled: argInjectionAllEnabled,
    argInjectionAnimeEnabled: argInjectionAnimeEnabled,
    argInjectionMovieEnabled: argInjectionMovieEnabled,
    argInjectionSeriesEnabled: argInjectionSeriesEnabled,
    subtitleInjectionEnabled: subtitleInjectionEnabled,
    subtitleAutoSelectEnabled:
        subtitleInjectionEnabled && subtitleAutoSelectEnabled,
    audioDynamicLyricsEnabled: audioDynamicLyricsEnabled,
    audioLyricsFontFamily: audioLyricsFontFamilyController.text.trim().isEmpty
        ? PlayerConfig.defaultAudioLyricsFontFamily
        : audioLyricsFontFamilyController.text.trim(),
    audioLyricsOutlineWidth: audioLyricsOutlineWidth,
    audioLyricsTransparency: audioLyricsTransparency,
    resumeEnabled: resumeEnabled,
    menuProgressSharingEnabled: menuProgressSharingEnabled,
    specialPlaylistMode: specialPlaylistMode,
    scanSpecialChildFolders: scanSpecialChildFolders,
    scanSpecialSiblingFolders: scanSpecialSiblingFolders,
    sharePlaylistFonts: sharePlaylistFonts,
    webDavFontCacheEnabled: webDavFontCacheEnabled,
    externalAudioInjectionEnabled: externalAudioInjectionEnabled,
    videoPlaylistMode: videoPlaylistMode,
    episodeNetworkFailureMode: episodeNetworkFailureMode,
    videoPlaylistSimpleNaming: videoPlaylistSimpleNaming,
    discTitleSelectionPolicy: discTitleSelectionPolicy,
    videoPlaylistInsertDecimalEpisodes: videoPlaylistInsertDecimalEpisodes,
    implicitPlaylistWindowSize: int.parse(
      implicitPlaylistWindowController.text.trim(),
    ),
    autoSeasonTransitionEnabled: autoSeasonTransitionEnabled,
    allowSeasonGap: allowSeasonGap,
    hiddenExtensionsEnabled: hiddenExtensionsEnabled,
    hiddenExtensions: parseHiddenExtensions(hiddenExtensionsController.text),
    defaultSortMode: defaultSortMode,
    defaultSortDirection: defaultSortDirection,
    playerStartupTimeoutSeconds: playerStartupTimeoutSeconds,
  );

  static String _formatPercentage(double ratio) {
    final percentage = ratio * 100;
    final rounded = double.parse(percentage.toStringAsPrecision(15));
    final value = rounded / 100 == ratio ? rounded : percentage;
    return value.toString().replaceFirst(RegExp(r'\.0$'), '');
  }

  FilmDirectoryExclusions buildFilmDirectoryExclusions() =>
      FilmDirectoryExclusions(
        names: FilmDirectoryExclusions.parseNames(
          excludedFoldersController.text,
        ),
        exact: exactFolderExclusions.value,
      );

  void loadFilmDirectoryExclusions(FilmDirectoryExclusions exclusions) {
    excludedFoldersController.text = exclusions.names.join(', ');
    exactFolderExclusions.value = exclusions.exact;
  }

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
        restartDirectory: openListRestartDirectory,
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
    fontFamily: interfaceFontFamily,
    fontWeightOffset: interfaceFontWeightOffset,
    accentColor: accentColor,
    directoryMemoryMode: directoryMemoryMode,
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
    exactFolderExclusions.dispose();
    for (final controller in <TextEditingController>[
      ...menuShortcutControllers,
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
      videoCacheDirectoryController,
      excludedFoldersController,
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
      implicitPlaylistWindowController,
      audioLyricsFontFamilyController,
    ]) {
      controller.dispose();
    }
  }
}
