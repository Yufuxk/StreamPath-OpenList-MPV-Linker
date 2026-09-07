import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../localization/app_text.dart';
import 'package:provider/provider.dart';

import '../../core/errors/app_exception.dart';
import '../../core/utils/extension_filter.dart';
import '../../core/utils/file_sort.dart';
import '../../data/models/appearance_config.dart';
import '../../data/models/app_language.dart';
import '../../data/models/media_library_config.dart';
import '../../data/models/local_root_config.dart';
import '../../data/models/media_library_item.dart';
import '../../data/models/openlist_index_config.dart';
import '../../data/models/player_config.dart';
import '../../data/models/server_profile.dart';
import '../../data/models/stream_path_config.dart';
import '../../domain/services/cache_cleanup_service.dart';
import '../../domain/services/diagnostic_service.dart';
import '../../domain/services/external_player_service.dart';
import '../../domain/services/openlist_index_service.dart';
import '../../domain/services/openlist_api_client.dart';
import '../../domain/services/openlist_recovery_service.dart';
import '../../features/cache_control/models/cache_intelligence_config.dart';
import '../../features/cache_control/models/cache_policy_config.dart';
import '../../features/cache_expiration/models/cache_expiration_config.dart';
import '../state/app_state.dart';
import '../models/settings_config_draft.dart';
import '../localization/app_localizations.dart';
import '../theme/appearance_controller.dart';
import '../theme/glass_tokens.dart';
import '../widgets/clipboard_history_menu.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/glass_surface.dart';
import '../widgets/settings_category_forms.dart';
import '../widgets/local_root_dialog.dart';

/// 设置页中的可用分类。
///
/// 新增页面时只需补充枚举值，并在 [_SettingsPageState._buildSections]
/// 注册页面描述与内容构建器。
enum SettingsSection {
  server,
  localStorage,
  playback,
  mediaLibrary,
  cache,
  diagnostics,
  appearance,
  general,
}

enum _MediaLibraryCleanupTarget {
  favorites,
  continuePlayback,
  recentPlayback,
  recentDirectories,
}

/// 设置页当前分类与最近编辑档案的进程内缓存。
///
/// 不写入配置文件，因此软件重启后会恢复到默认的服务器页面。
class SettingsPageMemory {
  SettingsPageMemory._();

  static SettingsSection _selectedSection = SettingsSection.server;
  static String? _selectedProfileId;

  static SettingsSection get selectedSection => _selectedSection;
  static String? get selectedProfileId => _selectedProfileId;

  static void select(SettingsSection section) {
    _selectedSection = section;
  }

  static void selectProfile(String? profileId) {
    _selectedProfileId = profileId;
  }

  @visibleForTesting
  static void reset() {
    _selectedSection = SettingsSection.server;
    _selectedProfileId = null;
  }
}

class _SettingsSectionDefinition {
  const _SettingsSectionDefinition({
    required this.section,
    required this.label,
    required this.description,
    required this.icon,
    required this.builder,
  });

  final SettingsSection section;
  final String label;
  final String description;
  final IconData icon;
  final Widget Function() builder;
}

/// 分类设置页：服务器、播放、媒体中心、缓存、界面与基础行为。
///
/// 参数模板按行编辑（每行一个参数），支持占位符：
/// `{url}` 视频地址 · `{subfile}` 字幕地址 · `{start}` 续播秒数；
/// 无值的占位符所在的整行参数会被自动移除。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.onSectionBuilt});

  @visibleForTesting
  final ValueChanged<SettingsSection>? onSectionBuilt;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final Map<SettingsSection, GlobalKey<FormState>> _formKeys = {
    for (final section in SettingsSection.values)
      section: GlobalKey<FormState>(),
  };
  final Map<SettingsSection, ScrollController> _pageScrollControllers = {
    for (final section in SettingsSection.values) section: ScrollController(),
  };
  final ValueNotifier<int> _serverSectionRevision = ValueNotifier<int>(0);
  final ValueNotifier<int> _appearanceSectionRevision = ValueNotifier<int>(0);
  late final SettingsConfigDraft _draft;
  List<LocalRootConfig> _localRoots = const [];

  TextEditingController get _nameController => _draft.nameController;
  TextEditingController get _executableController =>
      _draft.executableController;
  TextEditingController get _argsController => _draft.argsController;
  TextEditingController get _hiddenExtensionsController =>
      _draft.hiddenExtensionsController;
  TextEditingController get _serverUrlController => _draft.serverUrlController;
  TextEditingController get _serverUsernameController =>
      _draft.serverUsernameController;
  TextEditingController get _serverPasswordController =>
      _draft.serverPasswordController;
  TextEditingController get _profileNameController =>
      _draft.profileNameController;
  TextEditingController get _defaultDirectoryController =>
      _draft.defaultDirectoryController;
  TextEditingController get _openListBaseUrlController =>
      _draft.openListBaseUrlController;
  TextEditingController get _openListUsernameController =>
      _draft.openListUsernameController;
  TextEditingController get _openListPasswordController =>
      _draft.openListPasswordController;
  TextEditingController get _openListTokenController =>
      _draft.openListTokenController;
  TextEditingController get _openListIndexUserTokenController =>
      _draft.openListIndexUserTokenController;
  TextEditingController get _openListIndexIntervalController =>
      _draft.openListIndexIntervalController;
  TextEditingController get _cacheMemoryRatioController =>
      _draft.cacheMemoryRatioController;
  TextEditingController get _cacheBaseSecsController =>
      _draft.cacheBaseSecsController;
  TextEditingController get _cacheSmallFileController =>
      _draft.cacheSmallFileController;
  TextEditingController get _cacheBandwidthController =>
      _draft.cacheBandwidthController;
  TextEditingController get _intelligenceMinSamplesController =>
      _draft.intelligenceMinSamplesController;
  TextEditingController get _intelligenceMaxAdjustmentController =>
      _draft.intelligenceMaxAdjustmentController;
  TextEditingController get _directoryFreshnessController =>
      _draft.directoryFreshnessController;
  TextEditingController get _directoryRetentionController =>
      _draft.directoryRetentionController;
  TextEditingController get _directoryScrollRetentionController =>
      _draft.directoryScrollRetentionController;
  TextEditingController get _playbackRetentionController =>
      _draft.playbackRetentionController;
  TextEditingController get _mediaMetadataRetentionController =>
      _draft.mediaMetadataRetentionController;
  TextEditingController get _mediaLibraryFavoritesController =>
      _draft.mediaLibraryFavoritesController;
  TextEditingController get _mediaLibraryContinueController =>
      _draft.mediaLibraryContinueController;
  TextEditingController get _mediaLibraryRecentPlaybackController =>
      _draft.mediaLibraryRecentPlaybackController;
  TextEditingController get _mediaLibraryRecentDirectoriesController =>
      _draft.mediaLibraryRecentDirectoriesController;

  bool get _subtitleInjectionEnabled => _draft.subtitleInjectionEnabled;
  set _subtitleInjectionEnabled(bool value) =>
      _draft.subtitleInjectionEnabled = value;
  bool get _subtitleAutoSelectEnabled => _draft.subtitleAutoSelectEnabled;
  set _subtitleAutoSelectEnabled(bool value) =>
      _draft.subtitleAutoSelectEnabled = value;
  bool get _resumeEnabled => _draft.resumeEnabled;
  set _resumeEnabled(bool value) => _draft.resumeEnabled = value;
  bool get _hiddenExtensionsEnabled => _draft.hiddenExtensionsEnabled;
  set _hiddenExtensionsEnabled(bool value) =>
      _draft.hiddenExtensionsEnabled = value;
  FileSortMode get _defaultSortMode => _draft.defaultSortMode;
  set _defaultSortMode(FileSortMode value) => _draft.defaultSortMode = value;
  FileSortDirection get _defaultSortDirection => _draft.defaultSortDirection;
  set _defaultSortDirection(FileSortDirection value) =>
      _draft.defaultSortDirection = value;
  bool get _openListRecoveryEnabled => _draft.openListRecoveryEnabled;
  set _openListRecoveryEnabled(bool value) =>
      _draft.openListRecoveryEnabled = value;
  bool get _openListIndexAutoUpdateEnabled =>
      _draft.openListIndexAutoUpdateEnabled;
  set _openListIndexAutoUpdateEnabled(bool value) =>
      _draft.openListIndexAutoUpdateEnabled = value;
  bool get _requiresOpenListAdminConfig =>
      _openListRecoveryEnabled || _openListIndexAutoUpdateEnabled;
  List<ServerProfile> get _profiles => _draft.profiles;
  set _profiles(List<ServerProfile> value) => _draft.profiles = value;
  String? get _selectedProfileId => _draft.selectedProfileId;
  set _selectedProfileId(String? value) => _draft.selectedProfileId = value;
  CredentialStorageMode get _credentialStorageMode =>
      _draft.credentialStorageMode;
  set _credentialStorageMode(CredentialStorageMode value) =>
      _draft.credentialStorageMode = value;
  bool get _cacheEnabled => _draft.cacheEnabled;
  set _cacheEnabled(bool value) => _draft.cacheEnabled = value;
  CachePolicyMode get _cacheMode => _draft.cacheMode;
  set _cacheMode(CachePolicyMode value) => _draft.cacheMode = value;
  bool get _overrideUserCacheArgs => _draft.overrideUserCacheArgs;
  set _overrideUserCacheArgs(bool value) =>
      _draft.overrideUserCacheArgs = value;
  bool get _intelligenceEnabled => _draft.intelligenceEnabled;
  set _intelligenceEnabled(bool value) => _draft.intelligenceEnabled = value;
  bool get _applyIntelligence => _draft.applyIntelligence;
  set _applyIntelligence(bool value) => _draft.applyIntelligence = value;
  bool get _bitratePredictionEnabled => _draft.bitratePredictionEnabled;
  set _bitratePredictionEnabled(bool value) =>
      _draft.bitratePredictionEnabled = value;
  bool get _storageOptimizationEnabled => _draft.storageOptimizationEnabled;
  set _storageOptimizationEnabled(bool value) =>
      _draft.storageOptimizationEnabled = value;
  bool get _habitLearningEnabled => _draft.habitLearningEnabled;
  set _habitLearningEnabled(bool value) => _draft.habitLearningEnabled = value;
  InterfaceStyle get _interfaceStyle => _draft.interfaceStyle;
  set _interfaceStyle(InterfaceStyle value) => _draft.interfaceStyle = value;
  WindowMaterialPreference get _windowMaterial => _draft.windowMaterial;
  set _windowMaterial(WindowMaterialPreference value) =>
      _draft.windowMaterial = value;
  double get _glassOpacity => _draft.glassOpacity;
  set _glassOpacity(double value) => _draft.glassOpacity = value;
  AppLanguage get _language => _draft.language;
  set _language(AppLanguage value) => _draft.language = value;
  late SettingsSection _selectedSection;
  bool _loaded = false;
  bool _saving = false;
  bool _resettingSettings = false;
  bool _clearingCache = false;
  bool _clearingLearningData = false;
  bool _clearingMediaLibrary = false;
  bool _runningDiagnostics = false;
  bool _exportingDiagnostics = false;
  bool _repairingDatabases = false;
  bool _updatingOpenListIndex = false;
  bool _loadingOpenListIndexProgress = false;
  bool _openListIndexUpdateUnavailable = false;
  OpenListCapabilities? _openListCapabilities;
  OpenListIndexProgress? _openListIndexProgress;
  String? _openListIndexProgressError;
  Timer? _openListIndexProgressTimer;
  DateTime? _openListIndexPollGraceDeadline;
  int _openListIndexProgressGeneration = 0;
  DiagnosticSnapshot? _diagnosticSnapshot;

  @override
  void initState() {
    super.initState();
    _selectedSection = SettingsPageMemory.selectedSection;
    _draft = SettingsConfigDraft();
    _loadConfig();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await context.read<AppearanceController>().refreshCapabilities();
    });
  }

  @override
  void dispose() {
    _openListIndexProgressTimer?.cancel();
    _openListIndexProgressGeneration++;
    _serverSectionRevision.dispose();
    _appearanceSectionRevision.dispose();
    _draft.dispose();
    for (final controller in _pageScrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<bool> _loadConfig() async {
    try {
      final appState = context.read<AppState>();
      final appearanceController = context.read<AppearanceController>();
      final fullConfig = await appState.configStore.load();
      final appearance = appearanceController.config;
      final cacheConfig =
          await appState.cachePolicyConfigStore?.load() ??
          CachePolicyConfig.defaults();
      final intelligenceConfig =
          await appState.cacheIntelligenceConfigStore?.load() ??
          CacheIntelligenceConfig.defaults();
      final expirationConfig =
          await appState.cacheExpirationConfigStore?.load() ??
          CacheExpirationConfig.defaults();
      final rememberedProfile = fullConfig.profiles
          .where(
            (profile) =>
                profile.profileId == SettingsPageMemory.selectedProfileId,
          )
          .firstOrNull;
      if (!mounted) return false;
      setState(() {
        _draft.loadFrom(
          fullConfig: fullConfig,
          appearance: appearance,
          cacheConfig: cacheConfig,
          intelligenceConfig: intelligenceConfig,
          expirationConfig: expirationConfig,
        );
        _localRoots = [...fullConfig.localRoots];
        if (rememberedProfile != null) {
          _loadProfileFields(rememberedProfile);
        }
        _loaded = true;
      });
      if (_selectedSection == SettingsSection.server) {
        unawaited(_refreshOpenListIndexProgress());
      }
      return true;
    } on AppException catch (e) {
      if (!mounted) return false;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: AppText(e.message)));
      return false;
    }
  }

  Future<void> _save() async {
    for (final section in SettingsSection.values) {
      if (!(_formKeys[section]?.currentState?.validate() ?? false)) {
        _selectSection(section);
        return;
      }
    }
    final config = _draft.buildPlayerConfig();
    final cacheConfig = _draft.buildCachePolicyConfig();
    final intelligenceConfig = _draft.buildIntelligenceConfig();
    final expirationConfig = _draft.buildExpirationConfig();
    final appearance = _draft.buildAppearanceConfig();
    final mediaLibraryConfig = _draft.buildMediaLibraryConfig();

    setState(() => _saving = true);
    try {
      final appState = context.read<AppState>();
      final appearanceController = context.read<AppearanceController>();
      final previousAppearance = appearanceController.config;
      final appearanceChanged =
          previousAppearance.style != appearance.style ||
          previousAppearance.material != appearance.material ||
          previousAppearance.glassOpacity != appearance.glassOpacity;
      final currentConfig = appState.configStore.current;
      final profileId = _selectedProfileId ?? ServerProfile.newId();
      final profile = _draft.buildProfile(profileId: profileId);
      final shouldActivate =
          currentConfig.profiles.isEmpty ||
          currentConfig.profileId == profileId;
      final nextConfig = currentConfig
          .upsertProfile(profile, activate: shouldActivate)
          .withCredentialStorageMode(_credentialStorageMode)
          .copyWithGlobalSettings(
            player: config,
            appearance: appearance,
            mediaLibrary: mediaLibraryConfig,
            language: _language,
          )
          .withLocalRoots(_localRoots);
      final hasCompleteConnection =
          profile.serverUrl.trim().isNotEmpty &&
          profile.username.trim().isNotEmpty;
      final switchingProfile =
          currentConfig.profileId != profileId && hasCompleteConnection;
      var savedConfig = nextConfig;
      if (appearanceChanged && !await appearanceController.apply(appearance)) {
        throw AppException.config('无法启用所选窗口样式，已保留当前界面');
      }
      try {
        if (switchingProfile) {
          savedConfig = await appState.connectAndActivateProfile(
            profile: profile,
            config: nextConfig,
          );
        } else {
          await appState.configStore.save(nextConfig);
        }
        SettingsPageMemory.selectProfile(profileId);
        appState.applyLanguage(savedConfig.language);
      } on NetworkException {
        if (appearanceChanged) {
          await appearanceController.apply(previousAppearance);
        }
        _restoreProfileFields(currentConfig);
        rethrow;
      } on AppException {
        if (appearanceChanged) {
          await appearanceController.apply(previousAppearance);
        }
        rethrow;
      }
      appState.refreshOpenListIndexSchedule();
      final mediaLibraryStore = appState.mediaLibraryStore;
      if (mediaLibraryStore != null) {
        try {
          await mediaLibraryStore.applyConfig(mediaLibraryConfig);
        } catch (error) {
          throw AppException.storage('配置已保存，但媒体中心容量应用失败', error);
        }
      }
      final cacheStore = appState.cachePolicyConfigStore;
      if (cacheStore != null && !await cacheStore.save(cacheConfig)) {
        throw AppException.storage('播放器配置已保存，但基础缓存配置保存失败');
      }
      final intelligenceStore = appState.cacheIntelligenceConfigStore;
      if (intelligenceStore != null &&
          !await intelligenceStore.save(intelligenceConfig)) {
        throw AppException.storage('基础配置已保存，但智能缓存配置保存失败');
      }
      final expirationStore = appState.cacheExpirationConfigStore;
      if (expirationStore != null &&
          !await expirationStore.save(expirationConfig)) {
        throw AppException.storage('基础配置已保存，但缓存过期配置保存失败');
      }
      if (!mounted) return;
      setState(() {
        _profiles = [...savedConfig.profiles];
        _selectedProfileId = profileId;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: AppText('全部配置已保存')));
    } on AppException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: AppText(e.message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _resetToDefault() {
    final def = PlayerConfig.defaultMpv();
    setState(() {
      _nameController.text = def.name;
      _executableController.text = def.executable;
      _argsController.text = def.args.join('\n');
    });
  }

  Future<void> _reloadConfig() async {
    await _refreshConfigFields();
  }

  Future<bool> _refreshConfigFields() async {
    setState(() => _loaded = false);
    return _loadConfig();
  }

  Future<void> _confirmAndResetSettings() async {
    final colorScheme = Theme.of(context).colorScheme;
    await showGlassDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const AppText('重置全部设置？'),
        content: const AppText(
          '服务器、播放、媒体中心容量、缓存策略、界面和基础设置将恢复默认值。媒体中心个人资产、目录缓存、续播记录、学习数据和其他缓存文件不会被删除；当前连接与正在播放的会话不会被中断。',
        ),
        actions: [
          TextButton(
            key: const Key('cancel-reset-settings-button'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const AppText('取消'),
          ),
          FilledButton(
            key: const Key('confirm-reset-settings-button'),
            style: FilledButton.styleFrom(
              backgroundColor: colorScheme.error,
              foregroundColor: colorScheme.onError,
            ),
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              await _resetAllSettings();
            },
            child: const AppText('确认重置'),
          ),
        ],
      ),
    );
  }

  Future<void> _resetAllSettings() async {
    setState(() => _resettingSettings = true);
    var settingsChanged = false;
    try {
      final appState = context.read<AppState>();
      final appearanceController = context.read<AppearanceController>();
      final defaultConfig = StreamPathConfig.defaults();
      final defaultAppearance = defaultConfig.appearance;
      final previousAppearance = appearanceController.config;
      final appearanceChanged =
          previousAppearance.style != defaultAppearance.style ||
          previousAppearance.material != defaultAppearance.material ||
          previousAppearance.glassOpacity != defaultAppearance.glassOpacity;

      if (appearanceChanged &&
          !await appearanceController.apply(defaultAppearance)) {
        throw AppException.config('无法恢复默认窗口样式，设置未重置');
      }
      try {
        await appState.configStore.resetToDefaults();
        appState.applyLanguage(defaultConfig.language);
        appState.refreshOpenListIndexSchedule();
        settingsChanged = true;
      } on AppException {
        if (appearanceChanged) {
          await appearanceController.apply(previousAppearance);
        }
        rethrow;
      }
      final mediaLibraryStore = appState.mediaLibraryStore;
      if (mediaLibraryStore != null) {
        try {
          await mediaLibraryStore.applyConfig(defaultConfig.mediaLibrary);
        } catch (error) {
          throw AppException.storage('主配置已重置，但媒体中心容量恢复失败', error);
        }
      }

      final cacheStore = appState.cachePolicyConfigStore;
      if (cacheStore != null &&
          !await cacheStore.save(CachePolicyConfig.defaults())) {
        throw AppException.storage('主配置已重置，但基础缓存设置重置失败');
      }
      final intelligenceStore = appState.cacheIntelligenceConfigStore;
      if (intelligenceStore != null &&
          !await intelligenceStore.save(CacheIntelligenceConfig.defaults())) {
        throw AppException.storage('部分配置已重置，但智能缓存设置重置失败');
      }
      final expirationStore = appState.cacheExpirationConfigStore;
      if (expirationStore != null &&
          !await expirationStore.save(CacheExpirationConfig.defaults())) {
        throw AppException.storage('部分配置已重置，但缓存过期设置重置失败');
      }

      if (!await _refreshConfigFields() || !mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: AppText('全部设置已恢复默认值')));
    } on AppException catch (e) {
      if (settingsChanged && mounted) await _refreshConfigFields();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: AppText(e.message)));
    } catch (error) {
      if (settingsChanged && mounted) await _refreshConfigFields();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: AppText('重置设置失败：$error')));
    } finally {
      if (mounted) setState(() => _resettingSettings = false);
    }
  }

  Future<void> _confirmAndClearCache() async {
    final confirmed = await showGlassDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const AppText('清理缓存？'),
        content: const AppText('将清除目录缓存、播放进度、继续播放记录和 MPV 临时文件。'),
        actions: [
          TextButton(
            key: const Key('cancel-clear-cache-button'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const AppText('取消'),
          ),
          FilledButton(
            key: const Key('confirm-clear-cache-button'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const AppText('确认清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _clearingCache = true);
    try {
      await context.read<AppState>().clearCache();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: AppText('缓存已清理')));
    } on CacheCleanupException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: AppText(error.message)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: AppText('清理缓存失败：$error')));
    } finally {
      if (mounted) setState(() => _clearingCache = false);
    }
  }

  Future<void> _confirmAndClearLearningData() async {
    final confirmed = await showGlassDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const AppText('清理学习数据？'),
        content: const AppText('将清除智能缓存积累的学习数据。'),
        actions: [
          TextButton(
            key: const Key('cancel-clear-learning-data-button'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const AppText('取消'),
          ),
          FilledButton(
            key: const Key('confirm-clear-learning-data-button'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const AppText('确认清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _clearingLearningData = true);
    try {
      await context.read<AppState>().clearLearningData();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: AppText('学习数据已清理')));
    } on CacheCleanupException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: AppText(error.message)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: AppText('清理学习数据失败：$error')));
    } finally {
      if (mounted) setState(() => _clearingLearningData = false);
    }
  }

  String? _currentMediaLibrarySourceId(AppState appState) {
    final active = appState.mediaSourceId;
    if (active != null) return active;
    final config = appState.configStore.current;
    if (!config.isConnectionComplete) return null;
    return mediaSourceId(baseUrl: config.serverUrl, username: config.username);
  }

  Future<void> _confirmAndClearMediaLibrary(
    _MediaLibraryCleanupTarget target,
  ) async {
    final appState = context.read<AppState>();
    final store = appState.mediaLibraryStore;
    final sourceId = _currentMediaLibrarySourceId(appState);
    if (store == null || sourceId == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: AppText('请先保存完整服务器信息，再清理媒体中心记录')),
        );
      return;
    }

    final (title, description, successMessage) = switch (target) {
      _MediaLibraryCleanupTarget.favorites => (
        '清空收藏列表？',
        '将清除当前来源的目录、视频、STRM、音频和 ISO 收藏。',
        '收藏列表已清空',
      ),
      _MediaLibraryCleanupTarget.continuePlayback => (
        '清空继续播放列表？',
        '只隐藏当前来源已有的媒体中心继续播放项；不会删除 SQLite、watch_later、正式或临时续播点，也不会清除最近播放。再次播放后对应会话可重新出现。',
        '继续播放列表已清空',
      ),
      _MediaLibraryCleanupTarget.recentPlayback => (
        '清空最近播放列表？',
        '将清除当前来源的视频、音频和 ISO 最近播放记录，并同步移除这些记录在媒体中心的继续播放入口；不会删除底层播放进度。',
        '最近播放列表已清空',
      ),
      _MediaLibraryCleanupTarget.recentDirectories => (
        '清空最近目录列表？',
        '将清除当前来源的最近访问目录，不删除目录缓存或收藏。',
        '最近目录列表已清空',
      ),
    };
    final confirmed = await showGlassDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: AppText(title),
        content: AppText(description),
        actions: [
          TextButton(
            key: const Key('cancel-clear-media-library-button'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const AppText('取消'),
          ),
          FilledButton(
            key: const Key('confirm-clear-media-library-button'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const AppText('确认清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _clearingMediaLibrary = true);
    try {
      await switch (target) {
        _MediaLibraryCleanupTarget.favorites => store.clearFavorites(sourceId),
        _MediaLibraryCleanupTarget.continuePlayback =>
          store.clearContinuePlayback(sourceId),
        _MediaLibraryCleanupTarget.recentPlayback =>
          store.clearAllPlaybackHistory(sourceId),
        _MediaLibraryCleanupTarget.recentDirectories =>
          store.clearRecentDirectories(sourceId),
      };
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: AppText(successMessage)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: AppText('清理媒体中心记录失败：$error')));
    } finally {
      if (mounted) setState(() => _clearingMediaLibrary = false);
    }
  }

  void _selectSection(SettingsSection section) {
    SettingsPageMemory.select(section);
    if (_selectedSection != section) {
      _stopOpenListIndexProgressPolling(clear: false);
      setState(() => _selectedSection = section);
      if (section == SettingsSection.server) {
        unawaited(_refreshOpenListIndexProgress());
      }
    }
  }

  void _selectProfileForEditing(String? profileId) {
    if (profileId == null) return;
    final profile = _profiles
        .where((item) => item.profileId == profileId)
        .firstOrNull;
    if (profile == null) return;
    _stopOpenListIndexProgressPolling(clear: true);
    setState(() {
      _openListIndexUpdateUnavailable = false;
      _loadProfileFields(profile);
    });
    unawaited(_refreshOpenListIndexProgress());
  }

  void _loadProfileFields(ServerProfile profile) {
    _selectedProfileId = profile.profileId;
    _profileNameController.text = profile.name;
    _serverUrlController.text = profile.serverUrl;
    _serverUsernameController.text = profile.username;
    _serverPasswordController.text = profile.password;
    _defaultDirectoryController.text = profile.defaultDirectory;
    _openListRecoveryEnabled = profile.openListRecovery.enabled;
    _openListBaseUrlController.text = profile.openListRecovery.baseUrl;
    _openListUsernameController.text = profile.openListRecovery.username;
    _openListPasswordController.text = profile.openListRecovery.password;
    _openListTokenController.text = profile.openListRecovery.token;
    _openListIndexUserTokenController.text = profile.openListIndex.userToken;
    _openListIndexAutoUpdateEnabled = profile.openListIndex.autoUpdateEnabled;
    _openListIndexIntervalController.text = profile
        .openListIndex
        .updateIntervalMinutes
        .toString();
  }

  void _restoreProfileFields(StreamPathConfig config) {
    final activeProfile = config.activeProfile;
    SettingsPageMemory.selectProfile(activeProfile?.profileId);
    if (!mounted) return;
    setState(() {
      _profiles = [...config.profiles];
      _openListIndexUpdateUnavailable = false;
      if (activeProfile == null) {
        _clearProfileFields(name: '默认服务器');
      } else {
        _loadProfileFields(activeProfile);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _formKeys[SettingsSection.server]?.currentState?.reset();
    });
  }

  void _clearProfileFields({required String name}) {
    _selectedProfileId = null;
    _profileNameController.text = name;
    _serverUrlController.clear();
    _serverUsernameController.clear();
    _serverPasswordController.clear();
    _defaultDirectoryController.clear();
    _openListRecoveryEnabled = false;
    _openListBaseUrlController.clear();
    _openListUsernameController.clear();
    _openListPasswordController.clear();
    _openListTokenController.clear();
    _openListIndexUserTokenController.clear();
    _openListIndexAutoUpdateEnabled = false;
    _openListIndexIntervalController.text = OpenListIndexConfig
        .defaultUpdateIntervalMinutes
        .toString();
  }

  void _newProfileForEditing() {
    _stopOpenListIndexProgressPolling(clear: true);
    setState(() {
      _openListIndexUpdateUnavailable = false;
      _clearProfileFields(name: '新服务器');
    });
  }

  Future<void> _confirmDeleteSelectedProfile() async {
    final profileId = _selectedProfileId;
    if (profileId == null) return;
    final appState = context.read<AppState>();
    if (appState.mediaSourceId == profileId) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: AppText('当前已连接档案不能删除，请先退出登录')));
      return;
    }
    final confirmed = await showGlassDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const AppText('删除服务器档案？'),
        content: const AppText('只删除该档案及其凭据，不删除缓存、收藏和播放进度。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const AppText('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const AppText('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await appState.configStore.save(
        appState.configStore.current.removeProfile(profileId),
      );
      if (SettingsPageMemory.selectedProfileId == profileId) {
        SettingsPageMemory.selectProfile(null);
      }
      appState.refreshOpenListIndexSchedule();
      if (!mounted) return;
      await _refreshConfigFields();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: AppText('服务器档案已删除')));
    } on AppException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: AppText(error.message)));
    }
  }

  Future<void> _updateOpenListIndexNow() async {
    final base = OpenListRecoveryService.normalizeBaseUri(
      _openListBaseUrlController.text,
    );
    if (base == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: AppText('请先填写有效的 OpenList/AList 后台地址')),
      );
      return;
    }
    if (_openListTokenController.text.trim().isEmpty &&
        (_openListUsernameController.text.trim().isEmpty ||
            _openListPasswordController.text.isEmpty)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: AppText('请填写管理员 Token 或管理员账号密码')));
      return;
    }
    setState(() => _updatingOpenListIndex = true);
    try {
      final profile = _buildOpenListDraftProfile();
      final result = await context.read<AppState>().updateOpenListIndex(
        profile: profile,
      );
      if (!mounted) return;
      if (result.message.contains('/api/admin/index/update') ||
          result.message.contains('/api/admin/index/progress')) {
        setState(() => _openListIndexUpdateUnavailable = true);
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: AppText(result.message)));
      if (result.accepted || result.alreadyRunning) {
        _openListIndexPollGraceDeadline = DateTime.now().add(
          const Duration(seconds: 5),
        );
        _openListIndexProgressTimer?.cancel();
        _openListIndexProgressTimer = Timer(
          const Duration(milliseconds: 500),
          () => _refreshOpenListIndexProgress(showLoading: false),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: AppText('索引更新失败：$error')));
    } finally {
      if (mounted) setState(() => _updatingOpenListIndex = false);
    }
  }

  ServerProfile _buildOpenListDraftProfile() =>
      _draft.buildProfile(profileId: _selectedProfileId ?? 'settings-draft');

  bool get _canReadOpenListIndexProgress {
    if (OpenListRecoveryService.normalizeBaseUri(
          _openListBaseUrlController.text,
        ) ==
        null) {
      return false;
    }
    return _openListTokenController.text.trim().isNotEmpty ||
        (_openListUsernameController.text.trim().isNotEmpty &&
            _openListPasswordController.text.isNotEmpty);
  }

  bool get _openListStorageRecoveryUnavailable =>
      _openListCapabilities?.storageReload ==
      OpenListCapabilitySupport.unsupported;

  bool get _openListSearchUnavailable =>
      _openListCapabilities?.indexSearch ==
      OpenListCapabilitySupport.unsupported;

  String? get _openListCapabilitySummary {
    final capabilities = _openListCapabilities;
    if (capabilities == null) return null;
    String label(OpenListCapabilitySupport support) => switch (support) {
      OpenListCapabilitySupport.supported => '可用',
      OpenListCapabilitySupport.unsupported => '不可用',
      OpenListCapabilitySupport.unknown => '尚不可证明',
    };
    final version = capabilities.version?.trim();
    final template = version == null || version.isEmpty
        ? '增强能力探测：基础 WebDAV {webDav}；索引搜索 {indexSearch}；索引更新 {indexUpdate}；存储恢复 {storageRecovery}。尚不可证明的功能会按端点响应失败关闭。'
        : '后台 {version} 能力：基础 WebDAV {webDav}；索引搜索 {indexSearch}；索引更新 {indexUpdate}；存储恢复 {storageRecovery}。尚不可证明的功能会按端点响应失败关闭。';
    final l10n = context.l10n;
    return l10n.format(template, <String, Object?>{
      'version': version,
      'webDav': l10n.text(label(capabilities.webDavConnection)),
      'indexSearch': l10n.text(label(capabilities.indexSearch)),
      'indexUpdate': l10n.text(label(capabilities.indexUpdate)),
      'storageRecovery': l10n.text(label(capabilities.storageReload)),
    });
  }

  Future<void> _refreshOpenListIndexProgress({bool showLoading = true}) async {
    _openListIndexProgressTimer?.cancel();
    _openListIndexProgressTimer = null;
    final generation = ++_openListIndexProgressGeneration;
    if (_selectedSection != SettingsSection.server) {
      if (mounted) {
        _mutateServerSection(() {
          _loadingOpenListIndexProgress = false;
          _openListIndexProgress = null;
          _openListIndexProgressError = null;
        });
      }
      return;
    }
    // 未配置后台地址时没有可探测的 OpenList 端点，避免无意义的
    // deadline 请求在页面销毁后留下异步定时器。
    if (OpenListRecoveryService.normalizeBaseUri(
          _openListBaseUrlController.text,
        ) ==
        null) {
      if (mounted) {
        _mutateServerSection(() {
          _loadingOpenListIndexProgress = false;
          _openListCapabilities = null;
          _openListIndexProgress = null;
          _openListIndexProgressError = null;
        });
      }
      return;
    }
    if (mounted && showLoading) {
      _mutateServerSection(() => _loadingOpenListIndexProgress = true);
    }
    try {
      final profile = _buildOpenListDraftProfile();
      final capabilities = await context
          .read<AppState>()
          .getOpenListCapabilities(profile: profile);
      if (!mounted || generation != _openListIndexProgressGeneration) return;
      _mutateServerSection(() {
        _openListCapabilities = capabilities;
        if (capabilities.indexProgress ==
                OpenListCapabilitySupport.unsupported ||
            capabilities.indexUpdate == OpenListCapabilitySupport.unsupported) {
          _openListIndexUpdateUnavailable = true;
        }
      });
      if (!_canReadOpenListIndexProgress ||
          capabilities.indexProgress == OpenListCapabilitySupport.unsupported) {
        _mutateServerSection(() {
          _loadingOpenListIndexProgress = false;
          _openListIndexProgress = null;
          _openListIndexProgressError =
              capabilities.indexProgress ==
                  OpenListCapabilitySupport.unsupported
              ? capabilities.unavailableMessage(
                  '索引状态',
                  '/api/admin/index/progress',
                )
              : null;
        });
        return;
      }
      final progress = await context.read<AppState>().getOpenListIndexProgress(
        profile: profile,
      );
      if (!mounted || generation != _openListIndexProgressGeneration) return;
      _mutateServerSection(() {
        _loadingOpenListIndexProgress = false;
        _openListIndexProgress = progress;
        _openListIndexProgressError = null;
        if (capabilities.indexUpdate == OpenListCapabilitySupport.unsupported) {
          _openListIndexUpdateUnavailable = true;
        }
      });
      final withinGrace =
          _openListIndexPollGraceDeadline?.isAfter(DateTime.now()) == true;
      if (!progress.isDone || withinGrace) {
        _openListIndexProgressTimer = Timer(
          const Duration(seconds: 2),
          () => _refreshOpenListIndexProgress(showLoading: false),
        );
      } else {
        _openListIndexPollGraceDeadline = null;
      }
    } catch (error) {
      if (!mounted || generation != _openListIndexProgressGeneration) return;
      _mutateServerSection(() {
        _loadingOpenListIndexProgress = false;
        _openListIndexProgressError = error is FormatException
            ? error.message.toString()
            : '读取索引状态失败，请检查后台连接';
        if (_openListIndexProgressError?.contains(
              '/api/admin/index/progress',
            ) ==
            true) {
          _openListIndexUpdateUnavailable = true;
        }
      });
      _openListIndexPollGraceDeadline = null;
    }
  }

  void _mutateServerSection(VoidCallback mutation) {
    mutation();
    _serverSectionRevision.value++;
  }

  void _mutateAppearanceSection(VoidCallback mutation) {
    mutation();
    _appearanceSectionRevision.value++;
  }

  void _stopOpenListIndexProgressPolling({required bool clear}) {
    _openListIndexProgressTimer?.cancel();
    _openListIndexProgressTimer = null;
    _openListIndexPollGraceDeadline = null;
    _openListIndexProgressGeneration++;
    if (clear) {
      _loadingOpenListIndexProgress = false;
      _openListIndexProgress = null;
      _openListIndexProgressError = null;
      _openListCapabilities = null;
    }
  }

  void _handleOpenListAdminConfigChanged(String _) {
    _stopOpenListIndexProgressPolling(clear: true);
    _openListIndexUpdateUnavailable = false;
    setState(() {});
  }

  Future<void> _runDiagnostics() async {
    setState(() => _runningDiagnostics = true);
    try {
      final snapshot = await context
          .read<AppState>()
          .createDiagnosticService()
          .run();
      if (!mounted) return;
      setState(() => _diagnosticSnapshot = snapshot);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: AppText('诊断执行失败：${redactDiagnosticText(error.toString())}'),
        ),
      );
    } finally {
      if (mounted) setState(() => _runningDiagnostics = false);
    }
  }

  Future<void> _exportDiagnostics() async {
    setState(() => _exportingDiagnostics = true);
    try {
      final service = context.read<AppState>().createDiagnosticService();
      final snapshot = _diagnosticSnapshot ?? await service.run();
      final file = await service.export(snapshot);
      if (!mounted) return;
      setState(() => _diagnosticSnapshot = snapshot);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: AppText('脱敏诊断包已导出：${file.path}')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: AppText('导出诊断包失败：${redactDiagnosticText(error.toString())}'),
        ),
      );
    } finally {
      if (mounted) setState(() => _exportingDiagnostics = false);
    }
  }

  Future<void> _repairDatabases() async {
    final confirmed = await showGlassDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const AppText('执行非破坏性数据库维护？'),
        content: const AppText(
          '系统会先为每个 SQLite 数据库创建一致性备份，再重建索引和统计信息；不会删除播放进度。完整性检查已报告损坏时会停止，不尝试强行修复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const AppText('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const AppText('创建备份并维护'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _repairingDatabases = true);
    try {
      final results = await context
          .read<AppState>()
          .repairDatabasesNonDestructive();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: AppText('数据库维护完成，已创建 ${results.length} 个备份')),
      );
      await _runDiagnostics();
    } on CacheCleanupException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: AppText(error.message)));
    } on AppException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: AppText(error.message)));
    } finally {
      if (mounted) setState(() => _repairingDatabases = false);
    }
  }

  String? _validateNumber(
    String? raw, {
    required double min,
    required double max,
    required String unit,
    bool integer = false,
    bool allowEmpty = false,
  }) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty && allowEmpty) return null;
    final value = integer
        ? int.tryParse(text)?.toDouble()
        : double.tryParse(text);
    if (value == null) return context.l10n.text('请输入有效数字');
    if (value < min || value > max) {
      return context.l10n.format('请输入 {min}～{max} {unit}', {
        'min': min,
        'max': max,
        'unit': context.l10n.text(unit),
      });
    }
    return null;
  }

  List<_SettingsSectionDefinition> _buildSections() {
    return [
      _SettingsSectionDefinition(
        section: SettingsSection.server,
        label: '服务器',
        description: 'WebDAV 连接与服务恢复',
        icon: Icons.dns_outlined,
        builder: () => ValueListenableBuilder<int>(
          valueListenable: _serverSectionRevision,
          builder: (context, revision, child) => _observeSectionBuild(
            SettingsSection.server,
            _buildServerSettings(),
          ),
        ),
      ),
      _SettingsSectionDefinition(
        section: SettingsSection.localStorage,
        label: '本地存储',
        description: '本地文件夹挂载与管理',
        icon: Icons.folder_copy_outlined,
        builder: () => _observeSectionBuild(
          SettingsSection.localStorage,
          _buildLocalStorageSettings(),
        ),
      ),
      _SettingsSectionDefinition(
        section: SettingsSection.playback,
        label: '播放',
        description: '播放器、字幕与续播',
        icon: Icons.play_circle_outline,
        builder: () => _observeSectionBuild(
          SettingsSection.playback,
          _buildPlaybackSettings(),
        ),
      ),
      _SettingsSectionDefinition(
        section: SettingsSection.mediaLibrary,
        label: '媒体中心',
        description: '容量限制与个人资产清理',
        icon: Icons.video_library_outlined,
        builder: () => _observeSectionBuild(
          SettingsSection.mediaLibrary,
          _buildMediaLibrarySettings(),
        ),
      ),
      _SettingsSectionDefinition(
        section: SettingsSection.cache,
        label: '缓存',
        description: '基础策略与智能优化',
        icon: Icons.memory_outlined,
        builder: () =>
            _observeSectionBuild(SettingsSection.cache, _buildCachePage()),
      ),
      _SettingsSectionDefinition(
        section: SettingsSection.diagnostics,
        label: '诊断',
        description: '连接、存储与数据可靠性',
        icon: Icons.monitor_heart_outlined,
        builder: () => _observeSectionBuild(
          SettingsSection.diagnostics,
          _buildDiagnosticsSettings(),
        ),
      ),
      _SettingsSectionDefinition(
        section: SettingsSection.appearance,
        label: '界面',
        description: '界面样式与窗口背景',
        icon: Icons.palette_outlined,
        builder: () => ValueListenableBuilder<int>(
          valueListenable: _appearanceSectionRevision,
          builder: (context, revision, child) => _buildAppearanceSettings(),
        ),
      ),
      _SettingsSectionDefinition(
        section: SettingsSection.general,
        label: '基础设置',
        description: '文件显示与默认排序',
        icon: Icons.tune_outlined,
        builder: () => _observeSectionBuild(
          SettingsSection.general,
          _buildGeneralSettings(),
        ),
      ),
    ];
  }

  Widget _observeSectionBuild(SettingsSection section, Widget child) {
    return _SettingsSectionBuildProbe(
      section: section,
      onBuild: widget.onSectionBuilt,
      child: child,
    );
  }

  Future<void> _editLocalRoot([LocalRootConfig? initial]) async {
    final draft = await showLocalRootDialog(context, initial: initial);
    if (!mounted || draft == null) return;
    try {
      final candidate = await LocalRootConfig.fromDirectory(
        path: draft.path,
        displayName: draft.displayName,
        rootId: initial?.rootId,
        enabled: draft.enabled,
      );
      if (!mounted) return;
      setState(() {
        final next = [..._localRoots];
        final duplicateIndex = next.indexWhere(
          (root) =>
              root.rootId != initial?.rootId &&
              root.path.toLowerCase() == candidate.path.toLowerCase(),
        );
        final index = initial == null
            ? duplicateIndex
            : next.indexWhere((root) => root.rootId == initial.rootId);
        final resolved = duplicateIndex >= 0 && initial == null
            ? LocalRootConfig(
                rootId: next[duplicateIndex].rootId,
                displayName: candidate.displayName,
                path: candidate.path,
                enabled: candidate.enabled,
              )
            : candidate;
        if (index < 0) {
          next.add(resolved);
        } else {
          next[index] = resolved;
        }
        _localRoots = next;
      });
    } on FileSystemException {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: AppText('本地根目录不存在或不可访问')));
    }
  }

  Widget _buildLocalStorageSettings() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _SettingsGroupCard(
        key: const Key('local-storage-settings-section'),
        icon: Icons.folder_copy_outlined,
        title: '本地文件夹',
        description: '可直接输入绝对路径，或使用 Windows 原生目录选择器。删除挂载不会删除磁盘文件。',
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                key: const Key('settings-add-local-root-button'),
                onPressed: _saving ? null : _editLocalRoot,
                icon: const Icon(Icons.add),
                label: const AppText('添加本地文件夹'),
              ),
            ),
            if (_localRoots.isEmpty) ...[
              const SizedBox(height: 20),
              const AppText('尚未添加本地文件夹'),
            ] else ...[
              const SizedBox(height: 12),
              for (final root in _localRoots)
                ListTile(
                  key: ValueKey('settings-local-root-${root.rootId}'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.folder_outlined),
                  title: AppText(root.displayName),
                  subtitle: AppText(
                    root.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch(
                        value: root.enabled,
                        onChanged: _saving
                            ? null
                            : (enabled) => setState(() {
                                _localRoots = _localRoots
                                    .map(
                                      (item) => item.rootId == root.rootId
                                          ? item.copyWith(enabled: enabled)
                                          : item,
                                    )
                                    .toList();
                              }),
                      ),
                      IconButton(
                        tooltip: context.l10n.text('编辑'),
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: _saving ? null : () => _editLocalRoot(root),
                      ),
                      IconButton(
                        tooltip: context.l10n.text('删除'),
                        icon: const Icon(Icons.delete_outline),
                        onPressed: _saving
                            ? null
                            : () => setState(() {
                                _localRoots = _localRoots
                                    .where((item) => item.rootId != root.rootId)
                                    .toList();
                              }),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    ],
  );

  Widget _buildServerSettings() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SettingsGroupCard(
          icon: Icons.dns_outlined,
          title: '服务器档案',
          description: '每个档案使用稳定 profileId 隔离缓存、媒体资产与播放进度。',
          child: Column(
            children: [
              if (_profiles.isNotEmpty)
                DropdownButtonFormField<String>(
                  key: const Key('settings-profile-selector'),
                  initialValue: _selectedProfileId,
                  decoration: InputDecoration(
                    labelText: context.l10n.text('编辑档案'),
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final profile in _profiles)
                      DropdownMenuItem(
                        value: profile.profileId,
                        child: AppText(profile.name),
                      ),
                  ],
                  onChanged: _selectProfileForEditing,
                ),
              if (_profiles.isNotEmpty) const SizedBox(height: 12),
              TextFormField(
                key: const Key('profile-name-field'),
                controller: _profileNameController,
                decoration: InputDecoration(
                  labelText: context.l10n.text('档案名称'),
                  prefixIcon: Icon(Icons.label_outline),
                  border: OutlineInputBorder(),
                ),
                validator: (value) => value == null || value.trim().isEmpty
                    ? context.l10n.text('请输入档案名称')
                    : null,
              ),
              const SizedBox(height: 12),
              SegmentedButton<CredentialStorageMode>(
                key: const Key('credential-storage-mode'),
                segments: const [
                  ButtonSegment(
                    value: CredentialStorageMode.windowsCredential,
                    label: AppText('Windows 凭据'),
                    icon: Icon(Icons.security_outlined),
                  ),
                  ButtonSegment(
                    value: CredentialStorageMode.portablePlaintext,
                    label: AppText('便携明文'),
                    icon: Icon(Icons.folder_copy_outlined),
                  ),
                ],
                selected: {_credentialStorageMode},
                onSelectionChanged: (values) =>
                    setState(() => _credentialStorageMode = values.single),
              ),
              const SizedBox(height: 6),
              AppText(
                _credentialStorageMode ==
                        CredentialStorageMode.windowsCredential
                    ? '密码与 Token 保存在当前 Windows 用户的凭据管理器中，配置 JSON 不含敏感值。'
                    : '密码与 Token 以明文写入便携配置；复制数据目录即可迁移，但需自行保护文件。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: _newProfileForEditing,
                    icon: const Icon(Icons.add),
                    label: const AppText('新建档案'),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: _selectedProfileId == null
                        ? null
                        : _confirmDeleteSelectedProfile,
                    icon: const Icon(Icons.delete_outline),
                    label: const AppText('删除档案'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SettingsGroupCard(
          icon: Icons.cloud_outlined,
          title: 'WebDAV 服务器',
          description: '用于登录、浏览目录和访问媒体文件。',
          child: Column(
            children: [
              TextFormField(
                key: const Key('server-url-field'),
                controller: _serverUrlController,
                keyboardType: TextInputType.url,
                contextMenuBuilder: buildClipboardHistoryMenu,
                decoration: InputDecoration(
                  labelText: context.l10n.text('服务器地址'),
                  hintText: context.l10n.text('https://example.com/dav'),
                  prefixIcon: Icon(Icons.link),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('profile-default-directory-field'),
                controller: _defaultDirectoryController,
                contextMenuBuilder: buildClipboardHistoryMenu,
                decoration: InputDecoration(
                  labelText: context.l10n.text('默认目录'),
                  hintText: context.l10n.text('媒体/电影'),
                  helperText: context.l10n.text('相对于 WebDAV 根目录；留空则进入根目录。'),
                  prefixIcon: Icon(Icons.folder_open_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('server-username-field'),
                controller: _serverUsernameController,
                contextMenuBuilder: buildClipboardHistoryMenu,
                decoration: InputDecoration(
                  labelText: context.l10n.text('用户名'),
                  prefixIcon: Icon(Icons.person_outline),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('server-password-field'),
                controller: _serverPasswordController,
                obscureText: true,
                contextMenuBuilder: buildClipboardHistoryMenu,
                decoration: InputDecoration(
                  labelText: context.l10n.text('密码'),
                  helperText: context.l10n.text(
                    '连接信息完整时，下次启动会自动连接；服务器允许时密码可以留空。',
                  ),
                  prefixIcon: Icon(Icons.lock_outline),
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SettingsGroupCard(
          icon: Icons.health_and_safety_outlined,
          title: 'OpenList/AList 后台与自动恢复',
          description: '管理员凭据供播放恢复和索引更新共用。',
          child: Column(
            children: [
              SwitchListTile(
                key: const Key('openlist-recovery-switch'),
                contentPadding: EdgeInsets.zero,
                title: const AppText('启用播放失败自动恢复'),
                subtitle: AppText(
                  _openListStorageRecoveryUnavailable
                      ? '当前后台缺少存储恢复端点，自动恢复已禁用'
                      : '默认关闭，不会改变普通 WebDAV 播放行为',
                ),
                value: _openListRecoveryEnabled,
                onChanged: _openListStorageRecoveryUnavailable
                    ? null
                    : (value) =>
                          setState(() => _openListRecoveryEnabled = value),
              ),
              const SizedBox(height: 4),
              TextFormField(
                key: const Key('openlist-recovery-base-url'),
                controller: _openListBaseUrlController,
                onChanged: _handleOpenListAdminConfigChanged,
                keyboardType: TextInputType.url,
                contextMenuBuilder: buildClipboardHistoryMenu,
                decoration: InputDecoration(
                  labelText: context.l10n.text('后台地址'),
                  hintText: context.l10n.text('http://192.168.2.124:5244'),
                  helperText: context.l10n.text(
                    '基础 WebDAV 可独立连接；搜索、索引更新和存储恢复按实际端点能力分别判断。',
                  ),
                  prefixIcon: Icon(Icons.dns_outlined),
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (!_requiresOpenListAdminConfig) return null;
                  if (OpenListRecoveryService.normalizeBaseUri(value ?? '') ==
                      null) {
                    return context.l10n.text('请输入有效的 HTTP/HTTPS 后台地址');
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('openlist-recovery-token'),
                controller: _openListTokenController,
                onChanged: _handleOpenListAdminConfigChanged,
                obscureText: true,
                contextMenuBuilder: buildClipboardHistoryMenu,
                decoration: InputDecoration(
                  labelText: context.l10n.text('管理员 Token（推荐）'),
                  helperText: context.l10n.text(
                    '优先使用 Token；Authorization 不会添加 Bearer。',
                  ),
                  prefixIcon: Icon(Icons.key_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              _buildFieldPair(
                TextFormField(
                  key: const Key('openlist-recovery-username'),
                  controller: _openListUsernameController,
                  onChanged: _handleOpenListAdminConfigChanged,
                  contextMenuBuilder: buildClipboardHistoryMenu,
                  decoration: InputDecoration(
                    labelText: context.l10n.text('管理员用户名'),
                    helperText: context.l10n.text('填写 Token 时可留空'),
                    prefixIcon: Icon(Icons.admin_panel_settings_outlined),
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if (!_requiresOpenListAdminConfig ||
                        _openListTokenController.text.trim().isNotEmpty) {
                      return null;
                    }
                    return (value ?? '').trim().isEmpty
                        ? context.l10n.text('请输入管理员用户名或填写 Token')
                        : null;
                  },
                ),
                TextFormField(
                  key: const Key('openlist-recovery-password'),
                  controller: _openListPasswordController,
                  onChanged: _handleOpenListAdminConfigChanged,
                  obscureText: true,
                  contextMenuBuilder: buildClipboardHistoryMenu,
                  decoration: InputDecoration(
                    labelText: context.l10n.text('管理员密码'),
                    helperText: context.l10n.text('启用 2FA 时请使用 Token'),
                    prefixIcon: Icon(Icons.lock_outline),
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if (!_requiresOpenListAdminConfig ||
                        _openListTokenController.text.trim().isNotEmpty) {
                      return null;
                    }
                    return (value ?? '').isEmpty
                        ? context.l10n.text('请输入管理员密码或填写 Token')
                        : null;
                  },
                ),
              ),
              const SizedBox(height: 12),
              if (_openListCapabilitySummary != null) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: AppText(
                    _openListCapabilitySummary!,
                    key: const Key('openlist-capability-summary'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Align(
                alignment: Alignment.centerLeft,
                child: AppText(
                  '安全限制：每个会话最多自动恢复 3 次；第三次仅对身份已确认的本机进程执行优雅关闭和重启，绝不强制结束。全存储刷新至少间隔 5 分钟。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SettingsGroupCard(
          icon: Icons.manage_search_outlined,
          title: 'OpenList/AList 索引',
          description: '搜索只读取服务端本地索引；更新索引时才可能访问挂载源。',
          child: Column(
            children: [
              TextFormField(
                key: const Key('openlist-index-user-token'),
                controller: _openListIndexUserTokenController,
                enabled: !_openListSearchUnavailable,
                obscureText: true,
                contextMenuBuilder: buildClipboardHistoryMenu,
                decoration: InputDecoration(
                  labelText: context.l10n.text('普通用户 Token（推荐用于 2FA）'),
                  helperText: context.l10n.text(
                    '只用于索引搜索，请使用最小权限普通用户 Token；不会复用管理员 Token。',
                  ),
                  prefixIcon: const Icon(Icons.person_outline),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                key: const Key('openlist-index-auto-update-switch'),
                contentPadding: EdgeInsets.zero,
                title: const AppText('定时更新全部索引'),
                subtitle: const AppText('默认关闭；启动后先等待完整间隔，不会立即更新'),
                value: _openListIndexAutoUpdateEnabled,
                onChanged: _openListIndexUpdateUnavailable
                    ? null
                    : (value) => setState(
                        () => _openListIndexAutoUpdateEnabled = value,
                      ),
              ),
              const SizedBox(height: 4),
              TextFormField(
                key: const Key('openlist-index-update-interval'),
                controller: _openListIndexIntervalController,
                enabled:
                    _openListIndexAutoUpdateEnabled &&
                    !_openListIndexUpdateUnavailable,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: context.l10n.text('更新间隔（分钟）'),
                  helperText: context.l10n.text(
                    '最短 5 分钟，最长 7 天；低于最短值的外部配置会自动按 5 分钟执行。',
                  ),
                  prefixIcon: Icon(Icons.schedule_outlined),
                  border: OutlineInputBorder(),
                ),
                validator: (value) => !_openListIndexAutoUpdateEnabled
                    ? null
                    : _validateNumber(
                        value,
                        min: OpenListIndexConfig.minUpdateIntervalMinutes
                            .toDouble(),
                        max: OpenListIndexConfig.maxUpdateIntervalMinutes
                            .toDouble(),
                        unit: '分钟',
                        integer: true,
                      ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  key: const Key('openlist-index-update-now'),
                  onPressed:
                      _updatingOpenListIndex || _openListIndexUpdateUnavailable
                      ? null
                      : _updateOpenListIndexNow,
                  icon: _updatingOpenListIndex
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  label: AppText(_updatingOpenListIndex ? '正在提交…' : '立即更新索引'),
                ),
              ),
              const SizedBox(height: 12),
              _buildOpenListIndexProgressPanel(),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: AppText(
                  _openListIndexUpdateUnavailable
                      ? '当前后台缺少索引更新所需端点，手动与定时更新已禁用；不会回退为全量构建。'
                      : '保护规则：手动与定时请求互斥；若服务端正在构建索引则直接跳过；StreamPath 不会递归扫描 WebDAV。需先在 OpenList/AList 启用数据库索引与自动更新能力。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildOpenListIndexProgressPanel() {
    final scheme = Theme.of(context).colorScheme;
    final progress = _openListIndexProgress;
    final error = _openListIndexProgressError;
    final statusText = progress == null
        ? '尚未读取'
        : progress.isDone
        ? '空闲'
        : '正在更新';
    final statusColor = progress?.isDone == false
        ? scheme.primary
        : scheme.onSurfaceVariant;
    return Container(
      key: const Key('openlist-index-progress-panel'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.query_stats_outlined, size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: AppText(
                  '索引更新进度',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                key: const Key('refresh-openlist-index-progress'),
                tooltip: context.l10n.text('刷新索引状态'),
                visualDensity: VisualDensity.compact,
                onPressed:
                    !_canReadOpenListIndexProgress ||
                        _loadingOpenListIndexProgress
                    ? null
                    : _refreshOpenListIndexProgress,
                icon: _loadingOpenListIndexProgress
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!_canReadOpenListIndexProgress)
            AppText(
              '配置后台地址和管理员凭据后可读取索引状态。',
              style: Theme.of(context).textTheme.bodySmall,
            )
          else if (error != null)
            AppText(
              error,
              key: const Key('openlist-index-progress-error'),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.error),
            )
          else if (progress == null)
            AppText(
              _loadingOpenListIndexProgress ? '正在读取索引状态…' : '尚未读取索引状态，可点击右侧刷新。',
              style: Theme.of(context).textTheme.bodySmall,
            )
          else ...[
            LinearProgressIndicator(
              key: const Key('openlist-index-progress-indicator'),
              value: progress.isDone ? 1 : null,
              minHeight: 5,
              borderRadius: BorderRadius.circular(99),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 18,
              runSpacing: 6,
              children: [
                AppText(
                  context.l10n.format('状态：{status}', {
                    'status': context.l10n.text(statusText),
                  }),
                  key: const Key('openlist-index-progress-status'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: statusColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                AppText(
                  context.l10n.format('已处理条目：{count}', {
                    'count': progress.objectCount,
                  }),
                  key: const Key('openlist-index-progress-count'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                AppText(
                  context.l10n.format('上次更新时间：{time}', {
                    'time': _formatOpenListIndexTime(progress.lastDoneTime),
                  }),
                  key: const Key('openlist-index-last-update-time'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            if (progress.error.isNotEmpty) ...[
              const SizedBox(height: 8),
              AppText(
                context.l10n.format('上次错误：{error}', {
                  'error': context.l10n.text(progress.error),
                }),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
          ],
        ],
      ),
    );
  }

  String _formatOpenListIndexTime(DateTime? value) {
    if (value == null) return '暂无记录';
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  Widget _buildPlaybackSettings() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SettingsGroupCard(
          icon: Icons.video_settings_outlined,
          title: '外部播放器',
          description: '配置播放器程序及每行一个的启动参数。',
          child: Column(
            children: [
              TextFormField(
                key: const Key('player-name-field'),
                controller: _nameController,
                contextMenuBuilder: buildClipboardHistoryMenu,
                decoration: InputDecoration(
                  labelText: context.l10n.text('播放器名称'),
                  hintText: context.l10n.text('mpv / PotPlayer / VLC'),
                  prefixIcon: Icon(Icons.movie_filter_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('player-executable-field'),
                controller: _executableController,
                contextMenuBuilder: buildClipboardHistoryMenu,
                decoration: InputDecoration(
                  labelText: context.l10n.text('可执行文件路径'),
                  hintText: context.l10n.text(
                    'mpv 或 C:\\Program Files\\mpv\\mpv.exe',
                  ),
                  prefixIcon: Icon(Icons.apps_outlined),
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  final executable = value?.trim() ?? '';
                  if (executable.isEmpty) {
                    return context.l10n.text('请输入播放器路径');
                  }
                  return ExternalPlayerService(
                    configStore: context.read<AppState>().configStore,
                  ).validateExecutable(
                    PlayerConfig(
                      name: _nameController.text,
                      executable: executable,
                      args: const [],
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('player-args-field'),
                controller: _argsController,
                minLines: 5,
                maxLines: 8,
                contextMenuBuilder: buildClipboardHistoryMenu,
                decoration: InputDecoration(
                  labelText: context.l10n.text('启动参数（每行一个）'),
                  helperText: context.l10n.text(
                    '占位符：{url} 视频地址 · {subfile} 字幕地址 · {start} 续播秒数\n无值的占位符所在行会自动移除',
                  ),
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _resetToDefault,
                  icon: const Icon(Icons.restore, size: 18),
                  label: const AppText('恢复默认播放器模板'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SettingsGroupCard(
          icon: Icons.subtitles_outlined,
          title: '播放行为',
          description: '控制外挂字幕、外挂字体与 LRC 注入、轨道选择和续播。',
          child: Column(
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const AppText('自动注入匹配的外挂字幕、外挂字体与 LRC'),
                subtitle: const AppText('匹配同级字幕和歌词，并加载同级已识别字体目录中的直属字体'),
                value: _subtitleInjectionEnabled,
                onChanged: (value) =>
                    setState(() => _subtitleInjectionEnabled = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const AppText('自动选择已注入的外挂字幕与 LRC'),
                subtitle: const AppText('关闭时保留播放器原有的内封字幕或歌词轨道选择'),
                value: _subtitleInjectionEnabled && _subtitleAutoSelectEnabled,
                onChanged: !_subtitleInjectionEnabled
                    ? null
                    : (value) =>
                          setState(() => _subtitleAutoSelectEnabled = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const AppText('自动续播'),
                subtitle: const AppText('视频或音频存在播放进度时从上次位置继续'),
                value: _resumeEnabled,
                onChanged: (value) => setState(() => _resumeEnabled = value),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<bool>(
                key: const Key('menu-progress-sharing'),
                isExpanded: true,
                initialValue: _draft.menuProgressSharingEnabled,
                decoration: InputDecoration(
                  labelText: context.l10n.text('WebDAV 蓝光菜单进度'),
                ),
                items: const [
                  DropdownMenuItem(value: false, child: AppText('独立（不记录进度）')),
                  DropdownMenuItem(value: true, child: AppText('共享（供标题模式续播）')),
                ],
                onChanged: (value) => setState(() =>
                    _draft.menuProgressSharingEnabled = value!),
              ),
              const SizedBox(height: 8),
              const AppText('菜单始终从头启动；共享时记录正片进度供标题模式使用。更改对新会话生效。'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMediaLibraryLimitField({
    required Key key,
    required TextEditingController controller,
    required String label,
    required String helperText,
    required int maximum,
  }) => TextFormField(
    key: key,
    controller: controller,
    keyboardType: TextInputType.number,
    contextMenuBuilder: buildClipboardHistoryMenu,
    decoration: InputDecoration(
      labelText: label,
      helperText: helperText,
      suffixText: context.l10n.text('条'),
      border: const OutlineInputBorder(),
    ),
    validator: (value) => _validateNumber(
      value,
      min: MediaLibraryConfig.minItemLimit.toDouble(),
      max: maximum.toDouble(),
      unit: '条',
      integer: true,
    ),
  );

  Widget _buildMediaLibrarySettings() {
    final clearDisabled =
        _clearingMediaLibrary ||
        !_loaded ||
        _saving ||
        _resettingSettings ||
        _clearingCache ||
        _clearingLearningData;
    Widget cleanupButton({
      required Key key,
      required IconData icon,
      required String label,
      required _MediaLibraryCleanupTarget target,
    }) => OutlinedButton.icon(
      key: key,
      onPressed: clearDisabled
          ? null
          : () => _confirmAndClearMediaLibrary(target),
      icon: Icon(icon),
      label: AppText(label),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SettingsGroupCard(
          key: const Key('media-library-capacity-section'),
          icon: Icons.inventory_2_outlined,
          title: '容量限制',
          description: '数量按当前来源隔离；超过限制时优先淘汰最旧记录。',
          child: Column(
            children: [
              DropdownButtonFormField<MediaLibrarySharingMode>(
                key: ValueKey(
                  'media-library-sharing-${_draft.mediaLibrarySharingMode.name}',
                ),
                initialValue: _draft.mediaLibrarySharingMode,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: context.l10n.text('数据展示模式'),
                ),
                items: [
                  for (final mode in MediaLibrarySharingMode.values)
                    DropdownMenuItem(
                      value: mode,
                      child: AppText(switch (mode) {
                        MediaLibrarySharingMode.independent => '各来源独立',
                        MediaLibrarySharingMode.localShared => '本地挂载文件夹共享',
                        MediaLibrarySharingMode.allShared => '本地与网络存储共享',
                      }),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(
                            () => _draft.mediaLibrarySharingMode = value,
                          );
                        }
                      },
              ),
              const SizedBox(height: 16),
              _buildFieldPair(
                _buildMediaLibraryLimitField(
                  key: const Key('media-library-favorites-limit-field'),
                  controller: _mediaLibraryFavoritesController,
                  label: '收藏保存上限',
                  helperText: context.l10n.format(
                    '目录、视频、STRM、音频和 ISO 合计；系统最高 {max} 条',
                    {'max': MediaLibraryConfig.systemMaxFavoritesPerSource},
                  ),
                  maximum: MediaLibraryConfig.systemMaxFavoritesPerSource,
                ),
                _buildMediaLibraryLimitField(
                  key: const Key('media-library-continue-limit-field'),
                  controller: _mediaLibraryContinueController,
                  label: '继续播放显示上限',
                  helperText: context.l10n.format(
                    '视频、音频、ISO 各自计算；系统最高 {max} 条',
                    {'max': MediaLibraryConfig.systemMaxContinuePerLane},
                  ),
                  maximum: MediaLibraryConfig.systemMaxContinuePerLane,
                ),
              ),
              const SizedBox(height: 12),
              _buildFieldPair(
                _buildMediaLibraryLimitField(
                  key: const Key('media-library-recent-playback-limit-field'),
                  controller: _mediaLibraryRecentPlaybackController,
                  label: '最近播放保存上限',
                  helperText: context.l10n.format(
                    '视频、音频、ISO 各自计算；系统最高 {max} 条',
                    {'max': MediaLibraryConfig.systemMaxRecentPlaybackPerLane},
                  ),
                  maximum: MediaLibraryConfig.systemMaxRecentPlaybackPerLane,
                ),
                _buildMediaLibraryLimitField(
                  key: const Key(
                    'media-library-recent-directories-limit-field',
                  ),
                  controller: _mediaLibraryRecentDirectoriesController,
                  label: '最近目录保存上限',
                  helperText: context.l10n.format('当前来源单独计算；系统最高 {max} 条', {
                    'max':
                        MediaLibraryConfig.systemMaxRecentDirectoriesPerSource,
                  }),
                  maximum:
                      MediaLibraryConfig.systemMaxRecentDirectoriesPerSource,
                ),
              ),
              const SizedBox(height: 10),
              const Align(
                alignment: Alignment.centerLeft,
                child: AppText(
                  '降低上限并保存后会立即裁剪超出的旧记录；继续播放仅限制媒体中心显示数量，不改变底层播放进度。',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SettingsGroupCard(
          key: const Key('media-library-cleanup-section'),
          icon: Icons.cleaning_services_outlined,
          title: '记录清理',
          description: '只处理当前已连接或已保存服务器来源的媒体中心个人资产。',
          child: Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                cleanupButton(
                  key: const Key('clear-media-library-favorites-button'),
                  icon: Icons.star_outline,
                  label: '清空收藏',
                  target: _MediaLibraryCleanupTarget.favorites,
                ),
                cleanupButton(
                  key: const Key('clear-media-library-continue-button'),
                  icon: Icons.play_circle_outline,
                  label: '清空继续播放',
                  target: _MediaLibraryCleanupTarget.continuePlayback,
                ),
                cleanupButton(
                  key: const Key('clear-media-library-recent-button'),
                  icon: Icons.history,
                  label: '清空最近播放',
                  target: _MediaLibraryCleanupTarget.recentPlayback,
                ),
                cleanupButton(
                  key: const Key('clear-media-library-directories-button'),
                  icon: Icons.folder_delete_outlined,
                  label: '清空最近目录',
                  target: _MediaLibraryCleanupTarget.recentDirectories,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCachePage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildCacheSettings(),
        const SizedBox(height: 16),
        _buildCacheExpirationSettings(),
        const SizedBox(height: 16),
        _buildIntelligenceSettings(),
        const SizedBox(height: 16),
        _buildCacheCleanupSettings(),
        const SizedBox(height: 16),
        _buildLearningDataCleanupSettings(),
      ],
    );
  }

  Widget _buildDiagnosticsSettings() {
    final snapshot = _diagnosticSnapshot;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SettingsGroupCard(
          icon: Icons.fact_check_outlined,
          title: '诊断中心',
          description: '逐项检查外部连接、播放器、数据目录、SQLite 和缓存。',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    key: const Key('run-diagnostics-button'),
                    onPressed:
                        _runningDiagnostics ||
                            _exportingDiagnostics ||
                            _repairingDatabases
                        ? null
                        : _runDiagnostics,
                    icon: _runningDiagnostics
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow_outlined),
                    label: AppText(_runningDiagnostics ? '检查中…' : '运行全部检查'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('export-diagnostics-button'),
                    onPressed:
                        _exportingDiagnostics ||
                            _runningDiagnostics ||
                            _repairingDatabases
                        ? null
                        : _exportDiagnostics,
                    icon: const Icon(Icons.file_download_outlined),
                    label: AppText(_exportingDiagnostics ? '导出中…' : '导出脱敏诊断包'),
                  ),
                ],
              ),
              if (snapshot == null) ...[
                const SizedBox(height: 14),
                const AppText('尚未运行检查。导出时会自动执行一次。'),
              ] else ...[
                const SizedBox(height: 16),
                for (final item in snapshot.items) ...[
                  _DiagnosticResultRow(item: item),
                  if (item != snapshot.items.last) const Divider(height: 18),
                ],
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SettingsGroupCard(
          icon: Icons.storage_outlined,
          title: 'SQLite 非破坏性维护',
          description: '只在完整性检查通过后创建一致性备份并重建索引。',
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('repair-databases-button'),
              onPressed:
                  _repairingDatabases ||
                      _runningDiagnostics ||
                      _exportingDiagnostics
                  ? null
                  : _repairDatabases,
              icon: const Icon(Icons.build_outlined),
              label: AppText(_repairingDatabases ? '维护中…' : '创建备份并维护'),
            ),
          ),
        ),
        const SizedBox(height: 16),
        _SettingsGroupCard(
          icon: Icons.shield_outlined,
          title: '脱敏边界',
          description: '诊断包用于排障，不复制原始配置和运行数据。',
          child: const AppText(
            '服务器 URL 仅导出来源和路径 SHA-256；密码、Token、Authorization、URL userinfo、查询参数与签名参数不会写入诊断包。迁移记录只保留版本、结果和备份文件名。',
          ),
        ),
      ],
    );
  }

  Widget _buildCacheSettings() {
    return _SettingsGroupCard(
      key: const Key('cache-settings-section'),
      icon: Icons.storage_outlined,
      title: '基础缓存策略',
      description: '根据媒体、内存和网络条件生成播放器缓存参数。',
      child: Column(
        children: [
          SwitchListTile(
            key: const Key('cache-enabled-switch'),
            contentPadding: EdgeInsets.zero,
            title: const AppText('启用自动缓存策略'),
            subtitle: const AppText('关闭后不向播放器注入自动缓存参数'),
            value: _cacheEnabled,
            onChanged: (value) => setState(() => _cacheEnabled = value),
          ),
          DropdownButtonFormField<CachePolicyMode>(
            key: const Key('cache-mode-dropdown'),
            initialValue: _cacheMode,
            decoration: InputDecoration(
              labelText: context.l10n.text('策略模式'),
              border: OutlineInputBorder(),
            ),
            items: [
              for (final mode in CachePolicyMode.values)
                DropdownMenuItem(value: mode, child: AppText(mode.label)),
            ],
            onChanged: !_cacheEnabled
                ? null
                : (mode) {
                    if (mode != null) setState(() => _cacheMode = mode);
                  },
          ),
          const SizedBox(height: 12),
          _buildFieldPair(
            TextFormField(
              key: const Key('cache-memory-ratio-field'),
              controller: _cacheMemoryRatioController,
              enabled: _cacheEnabled,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: context.l10n.text('内存预算比例'),
                helperText: context.l10n.text('可用内存的 5%～50%'),
                suffixText: context.l10n.text('%'),
                border: OutlineInputBorder(),
              ),
              validator: (value) =>
                  _validateNumber(value, min: 5, max: 50, unit: '%'),
            ),
            TextFormField(
              key: const Key('cache-base-secs-field'),
              controller: _cacheBaseSecsController,
              enabled: _cacheEnabled,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: context.l10n.text('基准缓存时间'),
                helperText: context.l10n.text('策略目标时长'),
                suffixText: context.l10n.text('秒'),
                border: OutlineInputBorder(),
              ),
              validator: (value) => _validateNumber(
                value,
                min: CachePolicyConfig.minBaseCacheSecs.toDouble(),
                max: CachePolicyConfig.maxBaseCacheSecs.toDouble(),
                unit: '秒',
                integer: true,
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildFieldPair(
            TextFormField(
              key: const Key('cache-small-file-field'),
              controller: _cacheSmallFileController,
              enabled: _cacheEnabled,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: context.l10n.text('小文件全量缓存阈值'),
                suffixText: context.l10n.text('MB'),
                border: OutlineInputBorder(),
              ),
              validator: (value) => _validateNumber(
                value,
                min: CachePolicyConfig.minSmallFileThresholdMB.toDouble(),
                max: CachePolicyConfig.maxSmallFileThresholdMB.toDouble(),
                unit: 'MB',
                integer: true,
              ),
            ),
            TextFormField(
              key: const Key('cache-bandwidth-field'),
              controller: _cacheBandwidthController,
              enabled: _cacheEnabled,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: context.l10n.text('假定下行带宽（可留空）'),
                suffixText: context.l10n.text('Mbps'),
                border: OutlineInputBorder(),
              ),
              validator: (value) => _validateNumber(
                value,
                min: 0.1,
                max: 100000,
                unit: 'Mbps',
                allowEmpty: true,
              ),
            ),
          ),
          SwitchListTile(
            key: const Key('cache-override-user-args-switch'),
            contentPadding: EdgeInsets.zero,
            title: const AppText('覆盖播放器模板中的手工缓存参数'),
            subtitle: const AppText('建议保持关闭；开启后自动策略的优先级高于手工参数'),
            value: _overrideUserCacheArgs,
            onChanged: !_cacheEnabled
                ? null
                : (value) => setState(() => _overrideUserCacheArgs = value),
          ),
        ],
      ),
    );
  }

  Widget _buildCacheExpirationSettings() {
    return _SettingsGroupCard(
      key: const Key('cache-expiration-settings-section'),
      icon: Icons.timer_outlined,
      title: '缓存过期时间',
      description: '按最后访问或最后更新时间自动淘汰可重建缓存。',
      child: Column(
        children: [
          _buildFieldPair(
            TextFormField(
              key: const Key('directory-freshness-minutes-field'),
              controller: _directoryFreshnessController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: context.l10n.text('目录刷新间隔'),
                helperText: context.l10n.text('超过后先显示旧快照并后台刷新'),
                suffixText: context.l10n.text('分钟'),
                border: OutlineInputBorder(),
              ),
              validator: (value) => _validateNumber(
                value,
                min: CacheExpirationConfig.minMinutes.toDouble(),
                max: CacheExpirationConfig.maxMinutes.toDouble(),
                unit: '分钟',
                integer: true,
              ),
            ),
            TextFormField(
              key: const Key('directory-scroll-retention-minutes-field'),
              controller: _directoryScrollRetentionController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: context.l10n.text('滚动位置保留时间'),
                helperText: context.l10n.text('长时间未打开的目录不再恢复位置'),
                suffixText: context.l10n.text('分钟'),
                border: OutlineInputBorder(),
              ),
              validator: (value) => _validateNumber(
                value,
                min: CacheExpirationConfig.minMinutes.toDouble(),
                max: CacheExpirationConfig.maxMinutes.toDouble(),
                unit: '分钟',
                integer: true,
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildFieldPair(
            TextFormField(
              key: const Key('directory-retention-days-field'),
              controller: _directoryRetentionController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: context.l10n.text('目录快照保留时间'),
                helperText: context.l10n.text('按最后访问时间清理 Hive 快照'),
                suffixText: context.l10n.text('天'),
                border: OutlineInputBorder(),
              ),
              validator: (value) => _validateNumber(
                value,
                min: CacheExpirationConfig.minDays.toDouble(),
                max: CacheExpirationConfig.maxDays.toDouble(),
                unit: '天',
                integer: true,
              ),
            ),
            TextFormField(
              key: const Key('playback-retention-days-field'),
              controller: _playbackRetentionController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: context.l10n.text('续播记录保留时间'),
                helperText: context.l10n.text('同时作用于进度、历史和 MPV 恢复文件'),
                suffixText: context.l10n.text('天'),
                border: OutlineInputBorder(),
              ),
              validator: (value) => _validateNumber(
                value,
                min: CacheExpirationConfig.minDays.toDouble(),
                max: CacheExpirationConfig.maxDays.toDouble(),
                unit: '天',
                integer: true,
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const Key('media-metadata-retention-days-field'),
            controller: _mediaMetadataRetentionController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: context.l10n.text('媒体元数据保留时间'),
              helperText: context.l10n.text('适用于文件大小、时长、码率和资源验证器缓存'),
              suffixText: context.l10n.text('天'),
              border: OutlineInputBorder(),
            ),
            validator: (value) => _validateNumber(
              value,
              min: CacheExpirationConfig.minDays.toDouble(),
              max: CacheExpirationConfig.maxDays.toDouble(),
              unit: '天',
              integer: true,
            ),
          ),
          const SizedBox(height: 8),
          const Align(
            alignment: Alignment.centerLeft,
            child: AppText('缓存学习数据不自动过期，只能通过下方独立按钮主动清理。'),
          ),
        ],
      ),
    );
  }

  Widget _buildIntelligenceSettings() {
    return _SettingsGroupCard(
      key: const Key('cache-intelligence-settings-section'),
      icon: Icons.auto_awesome_outlined,
      title: '智能缓存优化',
      description: '使用本机匿名聚合数据，在安全边界内修正缓存目标。',
      child: Column(
        children: [
          SwitchListTile(
            key: const Key('cache-intelligence-enabled-switch'),
            contentPadding: EdgeInsets.zero,
            title: const AppText('启用本地智能层'),
            subtitle: const AppText('仅使用本机匿名聚合数据，不上传媒体地址或播放记录'),
            value: _intelligenceEnabled,
            onChanged: (value) => setState(() => _intelligenceEnabled = value),
          ),
          SwitchListTile(
            key: const Key('cache-intelligence-apply-switch'),
            contentPadding: EdgeInsets.zero,
            title: const AppText('应用智能优化'),
            subtitle: AppText(
              _applyIntelligence ? '建议会在安全边界内修正缓存目标' : '影子模式：只学习和记录建议，不改变原策略',
            ),
            value: _applyIntelligence,
            onChanged: !_intelligenceEnabled
                ? null
                : (value) => setState(() => _applyIntelligence = value),
          ),
          if (_intelligenceEnabled && _applyIntelligence)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: AppText('智能修正不会突破内存预算；样本不足时仍使用原策略。'),
              ),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const AppText('历史码率预测'),
            value: _bitratePredictionEnabled,
            onChanged: !_intelligenceEnabled
                ? null
                : (value) => setState(() => _bitratePredictionEnabled = value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const AppText('不同存储类型优化'),
            value: _storageOptimizationEnabled,
            onChanged: !_intelligenceEnabled
                ? null
                : (value) =>
                      setState(() => _storageOptimizationEnabled = value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const AppText('用户缓存习惯学习'),
            value: _habitLearningEnabled,
            onChanged: !_intelligenceEnabled
                ? null
                : (value) => setState(() => _habitLearningEnabled = value),
          ),
          const SizedBox(height: 8),
          _buildFieldPair(
            TextFormField(
              key: const Key('cache-intelligence-min-samples-field'),
              controller: _intelligenceMinSamplesController,
              enabled: _intelligenceEnabled,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: context.l10n.text('最小有效样本数'),
                helperText: context.l10n.text('达到数量后历史画像才影响策略'),
                border: OutlineInputBorder(),
              ),
              validator: (value) => _validateNumber(
                value,
                min: CacheIntelligenceConfig.minMinSamples.toDouble(),
                max: CacheIntelligenceConfig.maxMinSamples.toDouble(),
                unit: '个',
                integer: true,
              ),
            ),
            TextFormField(
              key: const Key('cache-intelligence-max-adjustment-field'),
              controller: _intelligenceMaxAdjustmentController,
              enabled: _intelligenceEnabled,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: context.l10n.text('最大策略修正比例'),
                helperText: context.l10n.text('相对基础缓存时间的调整上限'),
                suffixText: context.l10n.text('%'),
                border: OutlineInputBorder(),
              ),
              validator: (value) => _validateNumber(
                value,
                min: CacheIntelligenceConfig.minMaxAdjustmentRatio * 100,
                max: CacheIntelligenceConfig.maxMaxAdjustmentRatio * 100,
                unit: '%',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCacheCleanupSettings() {
    final errorColor = Theme.of(context).colorScheme.error;
    final appState = context.read<AppState>();
    return _SettingsGroupCard(
      key: const Key('cache-cleanup-settings-section'),
      icon: Icons.delete_sweep_outlined,
      title: '缓存文件清理',
      description: '清除目录缓存、播放进度和临时文件。',
      child: Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          key: const Key('clear-cache-button'),
          onPressed:
              !_loaded ||
                  _saving ||
                  _resettingSettings ||
                  _clearingCache ||
                  _clearingLearningData ||
                  _clearingMediaLibrary ||
                  !appState.canClearCache
              ? null
              : _confirmAndClearCache,
          style: OutlinedButton.styleFrom(foregroundColor: errorColor),
          icon: _clearingCache
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.delete_sweep_outlined),
          label: AppText(_clearingCache ? '正在清理…' : '清理缓存'),
        ),
      ),
    );
  }

  Widget _buildLearningDataCleanupSettings() {
    final errorColor = Theme.of(context).colorScheme.error;
    final appState = context.read<AppState>();
    return _SettingsGroupCard(
      key: const Key('learning-data-cleanup-settings-section'),
      icon: Icons.psychology_alt_outlined,
      title: '学习数据清理',
      description: '清除智能缓存积累的学习数据。',
      child: Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          key: const Key('clear-learning-data-button'),
          onPressed:
              !_loaded ||
                  _saving ||
                  _resettingSettings ||
                  _clearingCache ||
                  _clearingLearningData ||
                  _clearingMediaLibrary ||
                  !appState.canClearLearningData
              ? null
              : _confirmAndClearLearningData,
          style: OutlinedButton.styleFrom(foregroundColor: errorColor),
          icon: _clearingLearningData
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.psychology_alt_outlined),
          label: AppText(_clearingLearningData ? '正在清理…' : '清理学习数据'),
        ),
      ),
    );
  }

  Widget _buildAppearanceSettings() {
    return Consumer<AppearanceController>(
      builder: (context, appearanceController, child) => _observeSectionBuild(
        SettingsSection.appearance,
        _buildAppearanceSettingsContent(context, appearanceController),
      ),
    );
  }

  Widget _buildAppearanceSettingsContent(
    BuildContext context,
    AppearanceController appearanceController,
  ) {
    final glassSelected = _interfaceStyle == InterfaceStyle.glass;
    final opacityPercent = (_glassOpacity * 100).round();
    final capabilities = appearanceController.capabilities;
    final result = appearanceController.lastResult;
    final capabilityError = appearanceController.capabilityError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SettingsGroupCard(
          icon: Icons.layers_outlined,
          title: '界面样式',
          description: '默认样式保持原有不透明界面；Windows 材质使用 Acrylic 或 Mica 系统背景。',
          child: Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<InterfaceStyle>(
              key: const Key('interface-style-selector'),
              segments: const [
                ButtonSegment(
                  value: InterfaceStyle.classic,
                  icon: Icon(Icons.crop_square_rounded),
                  label: AppText('默认'),
                ),
                ButtonSegment(
                  value: InterfaceStyle.glass,
                  icon: Icon(Icons.blur_on_outlined),
                  label: AppText('Windows 材质'),
                ),
              ],
              selected: {_interfaceStyle},
              onSelectionChanged: (selection) {
                if (selection.isNotEmpty) {
                  setState(() => _interfaceStyle = selection.first);
                }
              },
            ),
          ),
        ),
        const SizedBox(height: 16),
        _SettingsGroupCard(
          icon: Icons.opacity_outlined,
          title: 'Windows 系统材质',
          description: '参数仅在保存时应用，不会在拖动过程中反复刷新窗口特效。',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppText('材质模式', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: SegmentedButton<WindowMaterialPreference>(
                  key: const Key('window-material-selector'),
                  segments: const [
                    ButtonSegment(
                      value: WindowMaterialPreference.automatic,
                      icon: Icon(Icons.auto_awesome_outlined),
                      label: AppText('自动'),
                    ),
                    ButtonSegment(
                      value: WindowMaterialPreference.acrylic,
                      icon: Icon(Icons.blur_on_outlined),
                      label: AppText('Acrylic'),
                    ),
                    ButtonSegment(
                      value: WindowMaterialPreference.mica,
                      icon: Icon(Icons.texture_outlined),
                      label: AppText('Mica'),
                    ),
                  ],
                  selected: {_windowMaterial},
                  onSelectionChanged: glassSelected
                      ? (selection) {
                          if (selection.isNotEmpty) {
                            setState(() => _windowMaterial = selection.first);
                          }
                        }
                      : null,
                ),
              ),
              const SizedBox(height: 8),
              AppText(
                _windowMaterialDescription(capabilities),
                key: const Key('window-material-description'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  const Expanded(child: AppText('界面背景密度')),
                  AppText(
                    '$opacityPercent%',
                    key: const Key('glass-opacity-value'),
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ],
              ),
              Slider(
                key: const Key('glass-opacity-slider'),
                min: AppearanceConfig.minGlassOpacity,
                max: AppearanceConfig.maxGlassOpacity,
                divisions: 35,
                label: '$opacityPercent%',
                value: _glassOpacity,
                onChanged: glassSelected
                    ? (value) =>
                          _mutateAppearanceSection(() => _glassOpacity = value)
                    : null,
              ),
              AppText(
                glassSelected
                    ? '数值越低，系统材质越明显；最低值已限制以保证文字对比度。'
                    : '选择“Windows 材质”后可调整。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SettingsGroupCard(
          key: const Key('windows-appearance-capabilities-section'),
          icon: Icons.monitor_heart_outlined,
          title: 'Windows 外观兼容性',
          description: '只读取系统能力与窗口实际材质，用于说明磨砂效果是否生效。',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _AppearanceStatusRow(
                label: '系统版本',
                value: capabilities.isDetected && capabilities.platformSupported
                    ? context.l10n
                          .format('Windows {major}.{minor}（内部版本 {build}）', {
                            'major': capabilities.versionMajor,
                            'minor': capabilities.versionMinor,
                            'build': capabilities.buildNumber,
                          })
                    : capabilities.windowsVersionLabel,
              ),
              const SizedBox(height: 10),
              _AppearanceStatusRow(
                label: '辅助显示',
                value: capabilities.isDetected && capabilities.platformSupported
                    ? context.l10n
                          .format('透明效果：{transparency} · 高对比度：{contrast}', {
                            'transparency': context.l10n.text(
                              capabilities.transparencyEnabled ? '已开启' : '已关闭',
                            ),
                            'contrast': context.l10n.text(
                              capabilities.highContrast ? '已开启' : '未开启',
                            ),
                          })
                    : capabilities.transparencyStatusLabel,
              ),
              const SizedBox(height: 10),
              _AppearanceStatusRow(
                label: '支持材质',
                value: capabilities.supportedMaterialsLabel,
              ),
              const SizedBox(height: 10),
              _AppearanceStatusRow(
                label: '实际材质',
                value: result?.actualEffectLabel ?? '尚未应用',
                valueKey: const Key('actual-window-backdrop-value'),
              ),
              const SizedBox(height: 12),
              AppText(
                capabilityError ??
                    (result?.isDegraded == true
                        ? result!.degradation.message
                        : capabilities.availabilityLabel),
                key: const Key('window-appearance-capability-summary'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: capabilityError != null || result?.isDegraded == true
                      ? Theme.of(context).colorScheme.tertiary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const Key('refresh-window-capabilities-button'),
                  onPressed: appearanceController.checkingCapabilities
                      ? null
                      : appearanceController.refreshCapabilities,
                  icon: appearanceController.checkingCapabilities
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 18),
                  label: AppText(
                    appearanceController.checkingCapabilities
                        ? '正在检测…'
                        : '重新检测',
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _windowMaterialDescription(
    WindowAppearanceCapabilities capabilities,
  ) => switch (_windowMaterial) {
    WindowMaterialPreference.automatic =>
      capabilities.supportsMica
          ? '由 Windows 自动选择，当前系统优先使用低透视的 Mica。'
          : '由 Windows 自动选择，当前系统将使用带背景模糊的 Acrylic。',
    WindowMaterialPreference.acrylic => 'Acrylic 是带背景模糊与透视的半透明材质，呈现更明显的磨砂效果。',
    WindowMaterialPreference.mica =>
      capabilities.supportsMica
          ? 'Mica 从桌面背景取色形成低透视表面，不等同于 Acrylic 磨砂玻璃。'
          : '当前系统不支持 Mica，保存后会自动回退到 Acrylic。',
  };

  Widget _buildGeneralSettings() {
    final errorColor = Theme.of(context).colorScheme.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SettingsGroupCard(
          key: const Key('language-settings-section'),
          icon: Icons.language_outlined,
          title: '语言',
          description: '选择软件使用的显示语言；保存全部配置后立即切换。',
          child: DropdownButtonFormField<AppLanguage>(
            key: const Key('app-language-field'),
            initialValue: _language,
            decoration: InputDecoration(
              labelText: context.l10n.text('界面语言'),
              prefixIcon: const Icon(Icons.translate_outlined),
              border: const OutlineInputBorder(),
            ),
            items: [
              for (final language in AppLanguage.values)
                DropdownMenuItem(
                  value: language,
                  child: AppText(language.nativeLabel),
                ),
            ],
            onChanged: (language) {
              if (language != null) setState(() => _language = language);
            },
          ),
        ),
        const SizedBox(height: 16),
        _SettingsGroupCard(
          icon: Icons.folder_copy_outlined,
          title: '文件浏览',
          description: '这些选项只改变界面显示，不影响稳定播放列表和字幕匹配。',
          child: Column(
            children: [
              SwitchListTile(
                key: const Key('hidden-extensions-enabled-switch'),
                contentPadding: EdgeInsets.zero,
                title: const AppText('启用隐藏文件后缀'),
                subtitle: const AppText('关闭后停止过滤，但保留并允许编辑下方后缀内容'),
                value: _hiddenExtensionsEnabled,
                onChanged: (value) =>
                    setState(() => _hiddenExtensionsEnabled = value),
              ),
              const SizedBox(height: 4),
              TextFormField(
                key: const Key('hidden-extensions-field'),
                controller: _hiddenExtensionsController,
                contextMenuBuilder: buildClipboardHistoryMenu,
                decoration: InputDecoration(
                  labelText: context.l10n.text('隐藏文件后缀（仅界面隐藏）'),
                  helperText: context.l10n.text(
                    '格式：.ass, .mkv（必须使用英文逗号）；后台引用与字幕加载不受影响。',
                  ),
                  prefixIcon: Icon(Icons.visibility_off_outlined),
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  try {
                    parseHiddenExtensions(value ?? '');
                    return null;
                  } on FormatException catch (error) {
                    return context.l10n.text(error.message);
                  }
                },
              ),
              const SizedBox(height: 12),
              _buildFieldPair(
                DropdownButtonFormField<FileSortMode>(
                  key: const Key('default-sort-mode-field'),
                  initialValue: _defaultSortMode,
                  decoration: InputDecoration(
                    labelText: context.l10n.text('默认排序方式'),
                    prefixIcon: Icon(Icons.sort),
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final mode in FileSortMode.values)
                      DropdownMenuItem(value: mode, child: AppText(mode.label)),
                  ],
                  onChanged: (mode) {
                    if (mode != null) setState(() => _defaultSortMode = mode);
                  },
                ),
                DropdownButtonFormField<FileSortDirection>(
                  key: const Key('default-sort-direction-field'),
                  initialValue: _defaultSortDirection,
                  decoration: InputDecoration(
                    labelText: context.l10n.text('默认排序顺序'),
                    prefixIcon: Icon(Icons.swap_vert),
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final direction in FileSortDirection.values)
                      DropdownMenuItem(
                        value: direction,
                        child: AppText(direction.label),
                      ),
                  ],
                  onChanged: (direction) {
                    if (direction != null) {
                      setState(() => _defaultSortDirection = direction);
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SettingsGroupCard(
          key: const Key('settings-maintenance-section'),
          icon: Icons.settings_backup_restore_outlined,
          title: '配置维护',
          description: '仅重置用户设置，不清理缓存或中断当前会话。',
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('reset-settings-button'),
              onPressed:
                  !_loaded ||
                      _saving ||
                      _resettingSettings ||
                      _clearingCache ||
                      _clearingLearningData ||
                      _clearingMediaLibrary
                  ? null
                  : _confirmAndResetSettings,
              style: OutlinedButton.styleFrom(foregroundColor: errorColor),
              icon: _resettingSettings
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.settings_backup_restore_outlined),
              label: AppText(_resettingSettings ? '正在重置…' : '重置全部设置'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFieldPair(Widget first, Widget second) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 620) {
          return Column(children: [first, const SizedBox(height: 12), second]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: first),
            const SizedBox(width: 12),
            Expanded(child: second),
          ],
        );
      },
    );
  }

  Widget _buildNavigationBar(
    BuildContext context,
    List<_SettingsSectionDefinition> sections,
  ) {
    final tokens = Theme.of(context).glass;
    return GlassSurface(
      level: GlassSurfaceLevel.chrome,
      automaticBorder: false,
      border: Border(bottom: BorderSide(color: tokens.dividerColor)),
      child: SizedBox(
        width: double.infinity,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(
                children: [
                  for (var index = 0; index < sections.length; index++) ...[
                    _SettingsNavigationButton(
                      key: Key(
                        'settings-section-${sections[index].section.name}',
                      ),
                      definition: sections[index],
                      selected: sections[index].section == _selectedSection,
                      onTap: () => _selectSection(sections[index].section),
                    ),
                    if (index != sections.length - 1) const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPageShell(_SettingsSectionDefinition definition) {
    final scrollController = _pageScrollControllers[definition.section]!;
    final formKey = _formKeys[definition.section]!;
    final header = _SettingsPageHeader(definition: definition);
    final content = definition.builder();
    return SettingsCategoryForm(
      sectionName: definition.section.name,
      formKey: formKey,
      scrollController: scrollController,
      header: header,
      content: content,
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    final tokens = Theme.of(context).glass;
    return GlassSurface(
      level: GlassSurfaceLevel.chrome,
      automaticBorder: false,
      border: Border(top: BorderSide(color: tokens.dividerColor)),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            FilledButton.icon(
              key: const Key('save-settings-button'),
              onPressed:
                  !_loaded ||
                      _saving ||
                      _resettingSettings ||
                      _clearingMediaLibrary
                  ? null
                  : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: AppText(_saving ? '保存中…' : '保存全部配置'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sections = _buildSections();
    final selectedIndex = sections.indexWhere(
      (definition) => definition.section == _selectedSection,
    );
    return Scaffold(
      appBar: AppBar(
        title: const AppText('设置'),
        actions: [
          IconButton(
            tooltip: context.l10n.text('从配置文件重新加载'),
            onPressed:
                !_loaded ||
                    _saving ||
                    _resettingSettings ||
                    _clearingMediaLibrary
                ? null
                : _reloadConfig,
            icon: const Icon(Icons.refresh),
          ),
          TextButton.icon(
            onPressed:
                !_loaded ||
                    _saving ||
                    _resettingSettings ||
                    _clearingMediaLibrary
                ? null
                : _save,
            icon: const Icon(Icons.save_outlined),
            label: const AppText('保存'),
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _buildNavigationBar(context, sections),
                Expanded(
                  child: IndexedStack(
                    index: selectedIndex < 0 ? 0 : selectedIndex,
                    children: [
                      for (final definition in sections)
                        _buildPageShell(definition),
                    ],
                  ),
                ),
              ],
            ),
      bottomNavigationBar: _loaded ? _buildBottomBar(context) : null,
    );
  }
}

class _DiagnosticResultRow extends StatelessWidget {
  const _DiagnosticResultRow({required this.item});

  final DiagnosticItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (item.status) {
      DiagnosticStatus.passed => (Icons.check_circle_outline, scheme.primary),
      DiagnosticStatus.warning => (
        Icons.warning_amber_outlined,
        scheme.tertiary,
      ),
      DiagnosticStatus.failed => (Icons.error_outline, scheme.error),
      DiagnosticStatus.skipped => (Icons.remove_circle_outline, scheme.outline),
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText(
                item.label,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              AppText(
                item.summary,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SettingsSectionBuildProbe extends StatelessWidget {
  const _SettingsSectionBuildProbe({
    required this.section,
    required this.onBuild,
    required this.child,
  });

  final SettingsSection section;
  final ValueChanged<SettingsSection>? onBuild;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    onBuild?.call(section);
    return child;
  }
}

class _SettingsNavigationButton extends StatelessWidget {
  const _SettingsNavigationButton({
    super.key,
    required this.definition,
    required this.selected,
    required this.onTap,
  });

  final _SettingsSectionDefinition definition;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? scheme.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  definition.icon,
                  size: 20,
                  color: selected
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                AppText(
                  definition.label,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: selected
                        ? scheme.onPrimaryContainer
                        : scheme.onSurfaceVariant,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsPageHeader extends StatelessWidget {
  const _SettingsPageHeader({required this.definition});

  final _SettingsSectionDefinition definition;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(definition.icon, color: scheme.onPrimaryContainer),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText(
                definition.label,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 2),
              AppText(
                definition.description,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SettingsGroupCard extends StatelessWidget {
  const _SettingsGroupCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String description;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = Theme.of(context).glass;
    return GlassSurface(
      level: tokens.enabled
          ? GlassSurfaceLevel.content
          : GlassSurfaceLevel.raised,
      border: Border.all(color: tokens.borderColor),
      showShadow: false,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 22, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(
                      title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    AppText(
                      description,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }
}

class _AppearanceStatusRow extends StatelessWidget {
  const _AppearanceStatusRow({
    required this.label,
    required this.value,
    this.valueKey,
  });

  final String label;
  final String value;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 88,
          child: AppText(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: AppText(
            value,
            key: valueKey,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
