import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/extension_filter.dart';
import '../../core/utils/file_sort.dart';
import '../../data/models/connection_config.dart';
import '../../data/models/openlist_recovery_config.dart';
import '../../data/models/player_config.dart';
import '../../data/models/stream_path_config.dart';
import '../../domain/services/external_player_service.dart';
import '../../domain/services/openlist_recovery_service.dart';
import '../../features/cache_control/models/cache_intelligence_config.dart';
import '../../features/cache_control/models/cache_policy_config.dart';
import '../state/app_state.dart';
import '../widgets/clipboard_history_menu.dart';

/// 设置页中的可用分类。
///
/// 新增页面时只需补充枚举值，并在 [_SettingsPageState._buildSections]
/// 注册页面描述与内容构建器。
enum SettingsSection { server, playback, cache, general }

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

/// 分类设置页：服务器、播放、缓存与基础行为。
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

  bool _subtitleInjectionEnabled = true;
  bool _subtitleAutoSelectEnabled = true;
  bool _resumeEnabled = true;
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
  late SettingsSection _selectedSection;
  bool _loaded = false;
  bool _saving = false;

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
    _loadConfig();
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
    super.dispose();
  }

  Future<void> _loadConfig() async {
    try {
      final appState = context.read<AppState>();
      final fullConfig = await appState.configStore.load();
      final config = fullConfig.toPlayerConfig();
      final connection = fullConfig.toConnectionConfig();
      final cacheConfig =
          await appState.cachePolicyConfigStore?.load() ??
          CachePolicyConfig.defaults();
      final intelligenceConfig =
          await appState.cacheIntelligenceConfigStore?.load() ??
          CacheIntelligenceConfig.defaults();
      if (!mounted) return;
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
        _intelligenceMinSamplesController.text = intelligenceConfig.minSamples
            .toString();
        _intelligenceMaxAdjustmentController.text =
            (intelligenceConfig.maxAdjustmentRatio * 100).toStringAsFixed(0);
        _loaded = true;
      });
    } on AppException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
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
    final openListRecovery = OpenListRecoveryConfig(
      enabled: _openListRecoveryEnabled,
      baseUrl: _openListBaseUrlController.text.trim(),
      username: _openListUsernameController.text.trim(),
      password: _openListPasswordController.text,
      token: _openListTokenController.text.trim(),
    );

    setState(() => _saving = true);
    try {
      final appState = context.read<AppState>();
      final connection = ConnectionConfig(
        baseUrl: _serverUrlController.text.trim(),
        username: _serverUsernameController.text.trim(),
        password: _serverPasswordController.text,
      );
      await appState.configStore.save(
        StreamPathConfig.fromParts(
          config,
          connection,
          openListRecovery: openListRecovery,
        ),
      );
      final cacheStore = appState.cachePolicyConfigStore;
      if (cacheStore != null && !await cacheStore.save(cacheConfig)) {
        throw AppException.storage('播放器配置已保存，但基础缓存配置保存失败');
      }
      final intelligenceStore = appState.cacheIntelligenceConfigStore;
      if (intelligenceStore != null &&
          !await intelligenceStore.save(intelligenceConfig)) {
        throw AppException.storage('基础配置已保存，但智能缓存配置保存失败');
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
    setState(() => _loaded = false);
    await _loadConfig();
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
          description: '控制外挂字幕注入、字幕选择与续播。',
          child: Column(
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('自动注入匹配的外挂字幕'),
                subtitle: const Text('将同级目录中名称匹配的字幕加入播放器字幕轨道'),
                value: _subtitleInjectionEnabled,
                onChanged: (value) =>
                    setState(() => _subtitleInjectionEnabled = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('自动选择已注入的外挂字幕'),
                subtitle: const Text('关闭时保留播放器原有的内封字幕选择'),
                value: _subtitleInjectionEnabled && _subtitleAutoSelectEnabled,
                onChanged: !_subtitleInjectionEnabled
                    ? null
                    : (value) =>
                          setState(() => _subtitleAutoSelectEnabled = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('自动续播'),
                subtitle: const Text('存在播放进度时从上次位置继续'),
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
        _buildIntelligenceSettings(),
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

  Widget _buildGeneralSettings() {
    return _SettingsGroupCard(
      icon: Icons.folder_copy_outlined,
      title: '文件浏览',
      description: '这些选项只改变界面显示，不影响稳定播放列表和字幕匹配。',
      child: Column(
        children: [
          TextFormField(
            key: const Key('hidden-extensions-field'),
            controller: _hiddenExtensionsController,
            contextMenuBuilder: buildClipboardHistoryMenu,
            decoration: const InputDecoration(
              labelText: '隐藏文件后缀（仅界面隐藏）',
              helperText: '格式：{".ass", ".mp4", ".mp3"}（逗号或空格分隔）；后台引用与字幕加载不受影响。',
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
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
    return Form(
      key: _formKeys[definition.section],
      child: SingleChildScrollView(
        key: PageStorageKey<String>('settings-page-${definition.section.name}'),
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
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
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        child: SafeArea(
          top: false,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Flexible(
                child: Text(
                  '所有分页共用一次保存',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(width: 16),
              FilledButton.icon(
                key: const Key('save-settings-button'),
                onPressed: !_loaded || _saving ? null : _save,
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
            onPressed: !_loaded || _saving ? null : _reloadConfig,
            icon: const Icon(Icons.refresh),
          ),
          TextButton.icon(
            onPressed: !_loaded || _saving ? null : _save,
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
                _buildBottomBar(context),
              ],
            ),
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
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  definition.icon,
                  size: 20,
                  color: selected
                      ? scheme.onSecondaryContainer
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  definition.label,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: selected
                        ? scheme.onSecondaryContainer
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
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(14),
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
                style: Theme.of(context).textTheme.headlineSmall,
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
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(20),
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
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
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
      ),
    );
  }
}
