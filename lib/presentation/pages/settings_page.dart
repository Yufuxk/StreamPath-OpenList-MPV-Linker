import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/extension_filter.dart';
import '../../core/utils/file_sort.dart';
import '../../data/models/appearance_config.dart';
import '../../data/models/connection_config.dart';
import '../../data/models/openlist_recovery_config.dart';
import '../../data/models/player_config.dart';
import '../../data/models/stream_path_config.dart';
import '../../domain/services/cache_cleanup_service.dart';
import '../../domain/services/external_player_service.dart';
import '../../domain/services/openlist_recovery_service.dart';
import '../../features/cache_control/models/cache_intelligence_config.dart';
import '../../features/cache_control/models/cache_policy_config.dart';
import '../../features/cache_expiration/models/cache_expiration_config.dart';
import '../state/app_state.dart';
import '../theme/appearance_controller.dart';
import '../theme/glass_tokens.dart';
import '../widgets/clipboard_history_menu.dart';
import '../widgets/directory_wheel_scroll_region.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/glass_surface.dart';

/// 设置页中的可用分类。
///
/// 新增页面时只需补充枚举值，并在 [_SettingsPageState._buildSections]
/// 注册页面描述与内容构建器。
enum SettingsSection { server, playback, cache, appearance, general }

/// 设置页当前分类的进程内缓存。
///
/// 不写入配置文件，因此软件重启后会恢复到默认的服务器页面。
class SettingsPageMemory {
  SettingsPageMemory._();

  static SettingsSection _selectedSection = SettingsSection.server;

  static SettingsSection get selectedSection => _selectedSection;

  static void select(SettingsSection section) {
    _selectedSection = section;
  }

  @visibleForTesting
  static void reset() {
    _selectedSection = SettingsSection.server;
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

/// 分类设置页：服务器、播放、缓存、界面与基础行为。
///
/// 参数模板按行编辑（每行一个参数），支持占位符：
/// `{url}` 视频地址 · `{subfile}` 字幕地址 · `{start}` 续播秒数；
/// 无值的占位符所在的整行参数会被自动移除。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

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
  late final TextEditingController _nameController;
  late final TextEditingController _executableController;
  late final TextEditingController _argsController;
  late final TextEditingController _hiddenExtensionsController;
  late final TextEditingController _serverUrlController;
  late final TextEditingController _serverUsernameController;
  late final TextEditingController _serverPasswordController;
  late final TextEditingController _openListBaseUrlController;
  late final TextEditingController _openListUsernameController;
  late final TextEditingController _openListPasswordController;
  late final TextEditingController _openListTokenController;
  late final TextEditingController _cacheMemoryRatioController;
  late final TextEditingController _cacheBaseSecsController;
  late final TextEditingController _cacheSmallFileController;
  late final TextEditingController _cacheBandwidthController;
  late final TextEditingController _intelligenceMinSamplesController;
  late final TextEditingController _intelligenceMaxAdjustmentController;
  late final TextEditingController _directoryFreshnessController;
  late final TextEditingController _directoryRetentionController;
  late final TextEditingController _directoryScrollRetentionController;
  late final TextEditingController _playbackRetentionController;
  late final TextEditingController _mediaMetadataRetentionController;

  bool _subtitleInjectionEnabled = true;
  bool _subtitleAutoSelectEnabled = true;
  bool _resumeEnabled = true;
  bool _hiddenExtensionsEnabled = true;
  FileSortMode _defaultSortMode = FileSortMode.name;
  FileSortDirection _defaultSortDirection = FileSortDirection.ascending;
  int _playerStartupTimeoutSeconds =
      AppConstants.defaultPlayerStartupTimeoutSeconds;
  bool _openListRecoveryEnabled = false;
  bool _cacheEnabled = true;
  CachePolicyMode _cacheMode = CachePolicyMode.auto;
  bool _overrideUserCacheArgs = false;
  bool _intelligenceEnabled = true;
  bool _applyIntelligence = false;
  bool _bitratePredictionEnabled = true;
  bool _storageOptimizationEnabled = true;
  bool _habitLearningEnabled = true;
  InterfaceStyle _interfaceStyle = InterfaceStyle.classic;
  WindowMaterialPreference _windowMaterial = WindowMaterialPreference.automatic;
  double _glassOpacity = AppearanceConfig.defaultGlassOpacity;
  late SettingsSection _selectedSection;
  bool _loaded = false;
  bool _saving = false;
  bool _resettingSettings = false;
  bool _clearingCache = false;
  bool _clearingLearningData = false;

  @override
  void initState() {
    super.initState();
    _selectedSection = SettingsPageMemory.selectedSection;
    _nameController = TextEditingController();
    _executableController = TextEditingController();
    _argsController = TextEditingController();
    _hiddenExtensionsController = TextEditingController();
    _serverUrlController = TextEditingController();
    _serverUsernameController = TextEditingController();
    _serverPasswordController = TextEditingController();
    _openListBaseUrlController = TextEditingController();
    _openListUsernameController = TextEditingController();
    _openListPasswordController = TextEditingController();
    _openListTokenController = TextEditingController();
    _cacheMemoryRatioController = TextEditingController();
    _cacheBaseSecsController = TextEditingController();
    _cacheSmallFileController = TextEditingController();
    _cacheBandwidthController = TextEditingController();
    _intelligenceMinSamplesController = TextEditingController();
    _intelligenceMaxAdjustmentController = TextEditingController();
    _directoryFreshnessController = TextEditingController();
    _directoryRetentionController = TextEditingController();
    _directoryScrollRetentionController = TextEditingController();
    _playbackRetentionController = TextEditingController();
    _mediaMetadataRetentionController = TextEditingController();
    _loadConfig();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await context.read<AppearanceController>().refreshCapabilities();
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _executableController.dispose();
    _argsController.dispose();
    _hiddenExtensionsController.dispose();
    _serverUrlController.dispose();
    _serverUsernameController.dispose();
    _serverPasswordController.dispose();
    _openListBaseUrlController.dispose();
    _openListUsernameController.dispose();
    _openListPasswordController.dispose();
    _openListTokenController.dispose();
    _cacheMemoryRatioController.dispose();
    _cacheBaseSecsController.dispose();
    _cacheSmallFileController.dispose();
    _cacheBandwidthController.dispose();
    _intelligenceMinSamplesController.dispose();
    _intelligenceMaxAdjustmentController.dispose();
    _directoryFreshnessController.dispose();
    _directoryRetentionController.dispose();
    _directoryScrollRetentionController.dispose();
    _playbackRetentionController.dispose();
    _mediaMetadataRetentionController.dispose();
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
      final config = fullConfig.toPlayerConfig();
      final connection = fullConfig.toConnectionConfig();
      final cacheConfig =
          await appState.cachePolicyConfigStore?.load() ??
          CachePolicyConfig.defaults();
      final intelligenceConfig =
          await appState.cacheIntelligenceConfigStore?.load() ??
          CacheIntelligenceConfig.defaults();
      final expirationConfig =
          await appState.cacheExpirationConfigStore?.load() ??
          CacheExpirationConfig.defaults();
      if (!mounted) return false;
      setState(() {
        _nameController.text = config.name;
        _executableController.text = config.executable;
        _argsController.text = config.args.join('\n');
        _hiddenExtensionsController.text = formatHiddenExtensions(
          config.hiddenExtensions,
        );
        _serverUrlController.text = connection.baseUrl;
        _serverUsernameController.text = connection.username;
        _serverPasswordController.text = connection.password;
        _openListRecoveryEnabled = fullConfig.openListRecovery.enabled;
        _openListBaseUrlController.text = fullConfig.openListRecovery.baseUrl;
        _openListUsernameController.text = fullConfig.openListRecovery.username;
        _openListPasswordController.text = fullConfig.openListRecovery.password;
        _openListTokenController.text = fullConfig.openListRecovery.token;
        _subtitleInjectionEnabled = config.subtitleInjectionEnabled;
        _subtitleAutoSelectEnabled = config.subtitleAutoSelectEnabled;
        _resumeEnabled = config.resumeEnabled;
        _hiddenExtensionsEnabled = config.hiddenExtensionsEnabled;
        _defaultSortMode = config.defaultSortMode;
        _defaultSortDirection = config.defaultSortDirection;
        _playerStartupTimeoutSeconds = config.playerStartupTimeoutSeconds;
        _cacheEnabled = cacheConfig.enabled;
        _cacheMode = cacheConfig.mode;
        _cacheMemoryRatioController.text = (cacheConfig.memoryBudgetRatio * 100)
            .toStringAsFixed(0);
        _cacheBaseSecsController.text = cacheConfig.baseCacheSecs.toString();
        _cacheSmallFileController.text = cacheConfig.smallFileThresholdMB
            .toString();
        _cacheBandwidthController.text =
            cacheConfig.assumedBandwidthMbps?.toString() ?? '';
        _overrideUserCacheArgs = cacheConfig.overrideUserCacheArgs;
        _intelligenceEnabled = intelligenceConfig.enabled;
        _applyIntelligence = intelligenceConfig.applyOptimizations;
        _bitratePredictionEnabled = intelligenceConfig.bitratePredictionEnabled;
        _storageOptimizationEnabled =
            intelligenceConfig.storageOptimizationEnabled;
        _habitLearningEnabled = intelligenceConfig.habitLearningEnabled;
        _interfaceStyle = appearance.style;
        _windowMaterial = appearance.material;
        _glassOpacity = appearance.glassOpacity;
        _intelligenceMinSamplesController.text = intelligenceConfig.minSamples
            .toString();
        _intelligenceMaxAdjustmentController.text =
            (intelligenceConfig.maxAdjustmentRatio * 100).toStringAsFixed(0);
        _directoryFreshnessController.text = expirationConfig
            .directoryFreshnessMinutes
            .toString();
        _directoryRetentionController.text = expirationConfig
            .directoryRetentionDays
            .toString();
        _directoryScrollRetentionController.text = expirationConfig
            .directoryScrollRetentionMinutes
            .toString();
        _playbackRetentionController.text = expirationConfig
            .playbackRetentionDays
            .toString();
        _mediaMetadataRetentionController.text = expirationConfig
            .mediaMetadataRetentionDays
            .toString();
        _loaded = true;
      });
      return true;
    } on AppException catch (e) {
      if (!mounted) return false;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
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
    final config = PlayerConfig(
      name: _nameController.text.trim().isEmpty
          ? '外部播放器'
          : _nameController.text.trim(),
      executable: _executableController.text.trim(),
      args: _argsController.text
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
      subtitleInjectionEnabled: _subtitleInjectionEnabled,
      subtitleAutoSelectEnabled:
          _subtitleInjectionEnabled && _subtitleAutoSelectEnabled,
      resumeEnabled: _resumeEnabled,
      hiddenExtensionsEnabled: _hiddenExtensionsEnabled,
      hiddenExtensions: parseHiddenExtensions(_hiddenExtensionsController.text),
      defaultSortMode: _defaultSortMode,
      defaultSortDirection: _defaultSortDirection,
      playerStartupTimeoutSeconds: _playerStartupTimeoutSeconds,
    );
    final bandwidthText = _cacheBandwidthController.text.trim();
    final cacheConfig = CachePolicyConfig(
      enabled: _cacheEnabled,
      mode: _cacheMode,
      memoryBudgetRatio:
          double.parse(_cacheMemoryRatioController.text.trim()) / 100,
      baseCacheSecs: int.parse(_cacheBaseSecsController.text.trim()),
      smallFileThresholdMB: int.parse(_cacheSmallFileController.text.trim()),
      assumedBandwidthMbps: bandwidthText.isEmpty
          ? null
          : double.parse(bandwidthText),
      overrideUserCacheArgs: _overrideUserCacheArgs,
    );
    final intelligenceConfig = CacheIntelligenceConfig(
      enabled: _intelligenceEnabled,
      applyOptimizations: _applyIntelligence,
      bitratePredictionEnabled: _bitratePredictionEnabled,
      storageOptimizationEnabled: _storageOptimizationEnabled,
      habitLearningEnabled: _habitLearningEnabled,
      minSamples: int.parse(_intelligenceMinSamplesController.text.trim()),
      maxAdjustmentRatio:
          double.parse(_intelligenceMaxAdjustmentController.text.trim()) / 100,
    );
    final expirationConfig = CacheExpirationConfig(
      directoryFreshnessMinutes: int.parse(
        _directoryFreshnessController.text.trim(),
      ),
      directoryRetentionDays: int.parse(
        _directoryRetentionController.text.trim(),
      ),
      directoryScrollRetentionMinutes: int.parse(
        _directoryScrollRetentionController.text.trim(),
      ),
      playbackRetentionDays: int.parse(
        _playbackRetentionController.text.trim(),
      ),
      mediaMetadataRetentionDays: int.parse(
        _mediaMetadataRetentionController.text.trim(),
      ),
    );
    final openListRecovery = OpenListRecoveryConfig(
      enabled: _openListRecoveryEnabled,
      baseUrl: _openListBaseUrlController.text.trim(),
      username: _openListUsernameController.text.trim(),
      password: _openListPasswordController.text,
      token: _openListTokenController.text.trim(),
    );
    final appearance = AppearanceConfig(
      style: _interfaceStyle,
      material: _windowMaterial,
      glassOpacity: _glassOpacity,
    );

    setState(() => _saving = true);
    try {
      final appState = context.read<AppState>();
      final appearanceController = context.read<AppearanceController>();
      final previousAppearance = appearanceController.config;
      final appearanceChanged =
          previousAppearance.style != appearance.style ||
          previousAppearance.material != appearance.material ||
          previousAppearance.glassOpacity != appearance.glassOpacity;
      final connection = ConnectionConfig(
        baseUrl: _serverUrlController.text.trim(),
        username: _serverUsernameController.text.trim(),
        password: _serverPasswordController.text,
      );
      if (appearanceChanged && !await appearanceController.apply(appearance)) {
        throw AppException.config('无法启用所选窗口样式，已保留当前界面');
      }
      try {
        await appState.configStore.save(
          StreamPathConfig.fromParts(
            config,
            connection,
            openListRecovery: openListRecovery,
            appearance: appearance,
          ),
        );
      } on AppException {
        if (appearanceChanged) {
          await appearanceController.apply(previousAppearance);
        }
        rethrow;
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('全部配置已保存')));
    } on AppException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
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
        title: const Text('重置全部设置？'),
        content: const Text(
          '服务器、播放、缓存策略、界面和基础设置将恢复默认值。目录缓存、续播记录、学习数据和其他缓存文件不会被删除；当前连接与正在播放的会话不会被中断。',
        ),
        actions: [
          TextButton(
            key: const Key('cancel-reset-settings-button'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
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
            child: const Text('确认重置'),
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
        settingsChanged = true;
      } on AppException {
        if (appearanceChanged) {
          await appearanceController.apply(previousAppearance);
        }
        rethrow;
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
        ..showSnackBar(const SnackBar(content: Text('全部设置已恢复默认值')));
    } on AppException catch (e) {
      if (settingsChanged && mounted) await _refreshConfigFields();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.message)));
    } catch (error) {
      if (settingsChanged && mounted) await _refreshConfigFields();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('重置设置失败：$error')));
    } finally {
      if (mounted) setState(() => _resettingSettings = false);
    }
  }

  Future<void> _confirmAndClearCache() async {
    final confirmed = await showGlassDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清理缓存？'),
        content: const Text('将清除目录缓存、播放进度、继续播放记录和 MPV 临时文件。'),
        actions: [
          TextButton(
            key: const Key('cancel-clear-cache-button'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirm-clear-cache-button'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确认清理'),
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
        ..showSnackBar(const SnackBar(content: Text('缓存已清理')));
    } on CacheCleanupException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('清理缓存失败：$error')));
    } finally {
      if (mounted) setState(() => _clearingCache = false);
    }
  }

  Future<void> _confirmAndClearLearningData() async {
    final confirmed = await showGlassDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清理学习数据？'),
        content: const Text('将清除智能缓存积累的学习数据。'),
        actions: [
          TextButton(
            key: const Key('cancel-clear-learning-data-button'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirm-clear-learning-data-button'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确认清理'),
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
        ..showSnackBar(const SnackBar(content: Text('学习数据已清理')));
    } on CacheCleanupException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('清理学习数据失败：$error')));
    } finally {
      if (mounted) setState(() => _clearingLearningData = false);
    }
  }

  void _selectSection(SettingsSection section) {
    SettingsPageMemory.select(section);
    if (_selectedSection != section) {
      setState(() => _selectedSection = section);
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
    if (value == null) return '请输入有效数字';
    if (value < min || value > max) {
      return '请输入 $min～$max $unit';
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
        builder: _buildServerSettings,
      ),
      _SettingsSectionDefinition(
        section: SettingsSection.playback,
        label: '播放',
        description: '播放器、字幕与续播',
        icon: Icons.play_circle_outline,
        builder: _buildPlaybackSettings,
      ),
      _SettingsSectionDefinition(
        section: SettingsSection.cache,
        label: '缓存',
        description: '基础策略与智能优化',
        icon: Icons.memory_outlined,
        builder: _buildCachePage,
      ),
      _SettingsSectionDefinition(
        section: SettingsSection.appearance,
        label: '界面',
        description: '界面样式与窗口背景',
        icon: Icons.palette_outlined,
        builder: _buildAppearanceSettings,
      ),
      _SettingsSectionDefinition(
        section: SettingsSection.general,
        label: '基础设置',
        description: '文件显示与默认排序',
        icon: Icons.tune_outlined,
        builder: _buildGeneralSettings,
      ),
    ];
  }

  Widget _buildServerSettings() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
                decoration: const InputDecoration(
                  labelText: '服务器地址',
                  hintText: 'https://example.com/dav',
                  prefixIcon: Icon(Icons.link),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('server-username-field'),
                controller: _serverUsernameController,
                contextMenuBuilder: buildClipboardHistoryMenu,
                decoration: const InputDecoration(
                  labelText: '用户名',
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
                decoration: const InputDecoration(
                  labelText: '密码',
                  helperText: '连接信息完整时，下次启动会自动连接；服务器允许时密码可以留空。',
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
          title: 'OpenList/AList 自动恢复',
          description: '仅在 MPV 明确报告媒体加载失败时尝试恢复服务。',
          child: Column(
            children: [
              SwitchListTile(
                key: const Key('openlist-recovery-switch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('启用播放失败自动恢复'),
                subtitle: const Text('默认关闭，不会改变普通 WebDAV 播放行为'),
                value: _openListRecoveryEnabled,
                onChanged: (value) =>
                    setState(() => _openListRecoveryEnabled = value),
              ),
              const SizedBox(height: 4),
              TextFormField(
                key: const Key('openlist-recovery-base-url'),
                controller: _openListBaseUrlController,
                enabled: _openListRecoveryEnabled,
                keyboardType: TextInputType.url,
                contextMenuBuilder: buildClipboardHistoryMenu,
                decoration: const InputDecoration(
                  labelText: '后台地址',
                  hintText: 'http://192.168.2.124:5244',
                  helperText: '兼容 OpenList v4 与 AList v3，也可填写带反向代理子路径的地址。',
                  prefixIcon: Icon(Icons.dns_outlined),
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (!_openListRecoveryEnabled) return null;
                  if (OpenListRecoveryService.normalizeBaseUri(value ?? '') ==
                      null) {
                    return '请输入有效的 HTTP/HTTPS 后台地址';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('openlist-recovery-token'),
                controller: _openListTokenController,
                enabled: _openListRecoveryEnabled,
                obscureText: true,
                contextMenuBuilder: buildClipboardHistoryMenu,
                decoration: const InputDecoration(
                  labelText: '管理员 Token（推荐）',
                  helperText: '优先使用 Token；Authorization 不会添加 Bearer。',
                  prefixIcon: Icon(Icons.key_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              _buildFieldPair(
                TextFormField(
                  key: const Key('openlist-recovery-username'),
                  controller: _openListUsernameController,
                  enabled: _openListRecoveryEnabled,
                  contextMenuBuilder: buildClipboardHistoryMenu,
                  decoration: const InputDecoration(
                    labelText: '管理员用户名',
                    helperText: '填写 Token 时可留空',
                    prefixIcon: Icon(Icons.admin_panel_settings_outlined),
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if (!_openListRecoveryEnabled ||
                        _openListTokenController.text.trim().isNotEmpty) {
                      return null;
                    }
                    return (value ?? '').trim().isEmpty
                        ? '请输入管理员用户名或填写 Token'
                        : null;
                  },
                ),
                TextFormField(
                  key: const Key('openlist-recovery-password'),
                  controller: _openListPasswordController,
                  enabled: _openListRecoveryEnabled,
                  obscureText: true,
                  contextMenuBuilder: buildClipboardHistoryMenu,
                  decoration: const InputDecoration(
                    labelText: '管理员密码',
                    helperText: '启用 2FA 时请使用 Token',
                    prefixIcon: Icon(Icons.lock_outline),
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if (!_openListRecoveryEnabled ||
                        _openListTokenController.text.trim().isNotEmpty) {
                      return null;
                    }
                    return (value ?? '').isEmpty ? '请输入管理员密码或填写 Token' : null;
                  },
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '安全限制：每个会话最多自动恢复 2 次，全存储刷新至少间隔 5 分钟。凭据保存在本机配置文件中。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ],
    );
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
                decoration: const InputDecoration(
                  labelText: '播放器名称',
                  hintText: 'mpv / PotPlayer / VLC',
                  prefixIcon: Icon(Icons.movie_filter_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('player-executable-field'),
                controller: _executableController,
                contextMenuBuilder: buildClipboardHistoryMenu,
                decoration: const InputDecoration(
                  labelText: '可执行文件路径',
                  hintText: 'mpv 或 C:\\Program Files\\mpv\\mpv.exe',
                  prefixIcon: Icon(Icons.apps_outlined),
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  final executable = value?.trim() ?? '';
                  if (executable.isEmpty) return '请输入播放器路径';
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
                decoration: const InputDecoration(
                  labelText: '启动参数（每行一个）',
                  helperText:
                      '占位符：{url} 视频地址 · {subfile} 字幕地址 · {start} 续播秒数\n无值的占位符所在行会自动移除',
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
                  label: const Text('恢复默认播放器模板'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SettingsGroupCard(
          icon: Icons.subtitles_outlined,
          title: '播放行为',
          description: '控制外挂字幕与 LRC 注入、轨道选择和续播。',
          child: Column(
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('自动注入匹配的外挂字幕与 LRC'),
                subtitle: const Text('将同级目录中名称匹配的视频字幕或音频歌词加入播放器轨道'),
                value: _subtitleInjectionEnabled,
                onChanged: (value) =>
                    setState(() => _subtitleInjectionEnabled = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('自动选择已注入的外挂字幕与 LRC'),
                subtitle: const Text('关闭时保留播放器原有的内封字幕或歌词轨道选择'),
                value: _subtitleInjectionEnabled && _subtitleAutoSelectEnabled,
                onChanged: !_subtitleInjectionEnabled
                    ? null
                    : (value) =>
                          setState(() => _subtitleAutoSelectEnabled = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('自动续播'),
                subtitle: const Text('视频或音频存在播放进度时从上次位置继续'),
                value: _resumeEnabled,
                onChanged: (value) => setState(() => _resumeEnabled = value),
              ),
            ],
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
            title: const Text('启用自动缓存策略'),
            subtitle: const Text('关闭后不向播放器注入自动缓存参数'),
            value: _cacheEnabled,
            onChanged: (value) => setState(() => _cacheEnabled = value),
          ),
          DropdownButtonFormField<CachePolicyMode>(
            key: const Key('cache-mode-dropdown'),
            initialValue: _cacheMode,
            decoration: const InputDecoration(
              labelText: '策略模式',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final mode in CachePolicyMode.values)
                DropdownMenuItem(value: mode, child: Text(mode.label)),
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
              decoration: const InputDecoration(
                labelText: '内存预算比例',
                helperText: '可用内存的 5%～50%',
                suffixText: '%',
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
              decoration: const InputDecoration(
                labelText: '基准缓存时间',
                helperText: '策略目标时长',
                suffixText: '秒',
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
              decoration: const InputDecoration(
                labelText: '小文件全量缓存阈值',
                suffixText: 'MB',
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
              decoration: const InputDecoration(
                labelText: '假定下行带宽（可留空）',
                suffixText: 'Mbps',
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
            title: const Text('覆盖播放器模板中的手工缓存参数'),
            subtitle: const Text('建议保持关闭；开启后自动策略的优先级高于手工参数'),
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
              decoration: const InputDecoration(
                labelText: '目录刷新间隔',
                helperText: '超过后先显示旧快照并后台刷新',
                suffixText: '分钟',
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
              decoration: const InputDecoration(
                labelText: '滚动位置保留时间',
                helperText: '长时间未打开的目录不再恢复位置',
                suffixText: '分钟',
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
              decoration: const InputDecoration(
                labelText: '目录快照保留时间',
                helperText: '按最后访问时间清理 Hive 快照',
                suffixText: '天',
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
              decoration: const InputDecoration(
                labelText: '续播记录保留时间',
                helperText: '同时作用于进度、历史和 MPV 恢复文件',
                suffixText: '天',
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
            decoration: const InputDecoration(
              labelText: '媒体元数据保留时间',
              helperText: '适用于文件大小、时长、码率和资源验证器缓存',
              suffixText: '天',
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
            child: Text('缓存学习数据不自动过期，只能通过下方独立按钮主动清理。'),
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
            title: const Text('启用本地智能层'),
            subtitle: const Text('仅使用本机匿名聚合数据，不上传媒体地址或播放记录'),
            value: _intelligenceEnabled,
            onChanged: (value) => setState(() => _intelligenceEnabled = value),
          ),
          SwitchListTile(
            key: const Key('cache-intelligence-apply-switch'),
            contentPadding: EdgeInsets.zero,
            title: const Text('应用智能优化'),
            subtitle: Text(
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
                child: Text('智能修正不会突破内存预算；样本不足时仍使用原策略。'),
              ),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('历史码率预测'),
            value: _bitratePredictionEnabled,
            onChanged: !_intelligenceEnabled
                ? null
                : (value) => setState(() => _bitratePredictionEnabled = value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('不同存储类型优化'),
            value: _storageOptimizationEnabled,
            onChanged: !_intelligenceEnabled
                ? null
                : (value) =>
                      setState(() => _storageOptimizationEnabled = value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('用户缓存习惯学习'),
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
              decoration: const InputDecoration(
                labelText: '最小有效样本数',
                helperText: '达到数量后历史画像才影响策略',
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
              decoration: const InputDecoration(
                labelText: '最大策略修正比例',
                helperText: '相对基础缓存时间的调整上限',
                suffixText: '%',
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
          label: Text(_clearingCache ? '正在清理…' : '清理缓存'),
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
          label: Text(_clearingLearningData ? '正在清理…' : '清理学习数据'),
        ),
      ),
    );
  }

  Widget _buildAppearanceSettings() {
    final glassSelected = _interfaceStyle == InterfaceStyle.glass;
    final opacityPercent = (_glassOpacity * 100).round();
    final appearanceController = context.watch<AppearanceController>();
    final capabilities = appearanceController.capabilities;
    final result = appearanceController.lastResult;
    final capabilityError = appearanceController.capabilityError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SettingsGroupCard(
          icon: Icons.layers_outlined,
          title: '界面样式',
          description: '默认样式保持原有不透明界面；磨砂玻璃使用 Windows 窗口级材质。',
          child: Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<InterfaceStyle>(
              key: const Key('interface-style-selector'),
              segments: const [
                ButtonSegment(
                  value: InterfaceStyle.classic,
                  icon: Icon(Icons.crop_square_rounded),
                  label: Text('默认'),
                ),
                ButtonSegment(
                  value: InterfaceStyle.glass,
                  icon: Icon(Icons.blur_on_outlined),
                  label: Text('磨砂玻璃'),
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
          title: '磨砂玻璃参数',
          description: '参数仅在保存时应用，不会在拖动过程中反复刷新窗口特效。',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('窗口材质', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: SegmentedButton<WindowMaterialPreference>(
                  key: const Key('window-material-selector'),
                  segments: const [
                    ButtonSegment(
                      value: WindowMaterialPreference.automatic,
                      icon: Icon(Icons.auto_awesome_outlined),
                      label: Text('自动'),
                    ),
                    ButtonSegment(
                      value: WindowMaterialPreference.acrylic,
                      icon: Icon(Icons.blur_on_outlined),
                      label: Text('Acrylic'),
                    ),
                    ButtonSegment(
                      value: WindowMaterialPreference.mica,
                      icon: Icon(Icons.texture_outlined),
                      label: Text('Mica'),
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
              Text(
                _windowMaterialDescription(capabilities),
                key: const Key('window-material-description'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  const Expanded(child: Text('背景不透明度')),
                  Text(
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
                    ? (value) => setState(() => _glassOpacity = value)
                    : null,
              ),
              Text(
                glassSelected
                    ? '数值越低，窗口材质越明显；最低值已限制以保证文字对比度。'
                    : '选择“磨砂玻璃”后可调整。',
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
                value: capabilities.windowsVersionLabel,
              ),
              const SizedBox(height: 10),
              _AppearanceStatusRow(
                label: '辅助显示',
                value: capabilities.transparencyStatusLabel,
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
              Text(
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
                  label: Text(
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
          ? '当前系统优先使用 Mica；系统不支持时自动使用 Acrylic。'
          : '当前系统将使用 Acrylic；升级到支持的 Windows 11 后可自动使用 Mica。',
    WindowMaterialPreference.acrylic => '固定使用 Acrylic，保持更明显的桌面透视与磨砂感。',
    WindowMaterialPreference.mica =>
      capabilities.supportsMica
          ? '固定请求 Mica，适合作为长时间显示的主窗口背景。'
          : '当前系统不支持 Mica，保存后会自动回退到 Acrylic。',
  };

  Widget _buildGeneralSettings() {
    final errorColor = Theme.of(context).colorScheme.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SettingsGroupCard(
          icon: Icons.folder_copy_outlined,
          title: '文件浏览',
          description: '这些选项只改变界面显示，不影响稳定播放列表和字幕匹配。',
          child: Column(
            children: [
              SwitchListTile(
                key: const Key('hidden-extensions-enabled-switch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('启用隐藏文件后缀'),
                subtitle: const Text('关闭后停止过滤，但保留并允许编辑下方后缀内容'),
                value: _hiddenExtensionsEnabled,
                onChanged: (value) =>
                    setState(() => _hiddenExtensionsEnabled = value),
              ),
              const SizedBox(height: 4),
              TextFormField(
                key: const Key('hidden-extensions-field'),
                controller: _hiddenExtensionsController,
                contextMenuBuilder: buildClipboardHistoryMenu,
                decoration: const InputDecoration(
                  labelText: '隐藏文件后缀（仅界面隐藏）',
                  helperText: '格式：.ass, .mkv（必须使用英文逗号）；后台引用与字幕加载不受影响。',
                  prefixIcon: Icon(Icons.visibility_off_outlined),
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  try {
                    parseHiddenExtensions(value ?? '');
                    return null;
                  } on FormatException catch (error) {
                    return error.message;
                  }
                },
              ),
              const SizedBox(height: 12),
              _buildFieldPair(
                DropdownButtonFormField<FileSortMode>(
                  key: const Key('default-sort-mode-field'),
                  initialValue: _defaultSortMode,
                  decoration: const InputDecoration(
                    labelText: '默认排序方式',
                    prefixIcon: Icon(Icons.sort),
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final mode in FileSortMode.values)
                      DropdownMenuItem(value: mode, child: Text(mode.label)),
                  ],
                  onChanged: (mode) {
                    if (mode != null) setState(() => _defaultSortMode = mode);
                  },
                ),
                DropdownButtonFormField<FileSortDirection>(
                  key: const Key('default-sort-direction-field'),
                  initialValue: _defaultSortDirection,
                  decoration: const InputDecoration(
                    labelText: '默认排序顺序',
                    prefixIcon: Icon(Icons.swap_vert),
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final direction in FileSortDirection.values)
                      DropdownMenuItem(
                        value: direction,
                        child: Text(direction.label),
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
                      _clearingLearningData
                  ? null
                  : _confirmAndResetSettings,
              style: OutlinedButton.styleFrom(foregroundColor: errorColor),
              icon: _resettingSettings
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.settings_backup_restore_outlined),
              label: Text(_resettingSettings ? '正在重置…' : '重置全部设置'),
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
    return Form(
      key: _formKeys[definition.section],
      child: DirectoryWheelScrollRegion(
        controller: scrollController,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: Scrollbar(
            key: ValueKey<String>(
              'settings-scrollbar-${definition.section.name}',
            ),
            controller: scrollController,
            thumbVisibility: true,
            interactive: true,
            child: SingleChildScrollView(
              key: PageStorageKey<String>(
                'settings-page-${definition.section.name}',
              ),
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 36),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _SettingsPageHeader(definition: definition),
                      const SizedBox(height: 20),
                      definition.builder(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
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
              onPressed: !_loaded || _saving || _resettingSettings
                  ? null
                  : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: Text(_saving ? '保存中…' : '保存全部配置'),
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
        title: const Text('设置'),
        actions: [
          IconButton(
            tooltip: '从配置文件重新加载',
            onPressed: !_loaded || _saving || _resettingSettings
                ? null
                : _reloadConfig,
            icon: const Icon(Icons.refresh),
          ),
          TextButton.icon(
            onPressed: !_loaded || _saving || _resettingSettings ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('保存'),
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
                Text(
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
              Text(
                definition.label,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 2),
              Text(
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
    return GlassSurface(
      level: GlassSurfaceLevel.raised,
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
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
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
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(
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
