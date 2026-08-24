import 'package:flutter/material.dart';

import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import 'package:provider/provider.dart';

import '../../core/errors/app_exception.dart';
import '../../data/models/connection_config.dart';
import '../../data/models/openlist_index_config.dart';
import '../../data/models/openlist_recovery_config.dart';
import '../../data/models/server_profile.dart';
import '../../data/models/stream_path_config.dart';
import '../state/app_state.dart';
import '../theme/glass_tokens.dart';
import '../widgets/glass_surface.dart';
import 'browser_page.dart';
import 'settings_page.dart';
import '../widgets/clipboard_history_menu.dart';

/// 连接配置页：服务器地址 / 账号 / 密码。
///
/// 连接成功 → 进入文件浏览页；失败 → SnackBar 展示统一异常提示。
/// 已保存的连接信息自动填入表单；信息完整时启动即自动连接
/// （无需再点登录）。
class HomePage extends StatefulWidget {
  const HomePage({super.key, this.initialError, this.initialConnection});

  /// 自动连接失败时的错误信息（进入本页时显示）。
  final String? initialError;

  /// 首帧表单值；为空时读取已加载的统一配置。
  final ConnectionConfig? initialConnection;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _baseUrlController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final TextEditingController _profileNameController;
  late List<ServerProfile> _profiles;
  String? _selectedProfileId;
  bool _connecting = false;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    StreamPathConfig config;
    try {
      config = context.read<AppState>().configStore.current;
    } catch (_) {
      config = StreamPathConfig.defaults();
    }
    _profiles = [...config.profiles];
    _selectedProfileId = config.profileId.isEmpty ? null : config.profileId;
    final saved = widget.initialConnection ?? config.toConnectionConfig();
    _baseUrlController = TextEditingController(text: saved.baseUrl);
    _usernameController = TextEditingController(text: saved.username);
    _passwordController = TextEditingController(text: saved.password);
    _profileNameController = TextEditingController(
      text: config.activeProfile?.name ?? '默认服务器',
    );
    final error = widget.initialError;
    if (error != null) {
      // 等首帧完成后再提示（ScaffoldMessenger 就绪）。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showError(error);
      });
    }
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _profileNameController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _connecting = true);
    final appState = context.read<AppState>();
    var connected = false;
    try {
      final profileId = _selectedProfileId ?? ServerProfile.newId();
      await appState.connect(
        baseUrl: _baseUrlController.text.trim(),
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        profileId: profileId,
      );
      connected = true;
      final existing = _profiles
          .where((profile) => profile.profileId == profileId)
          .firstOrNull;
      final profile = ServerProfile(
        profileId: profileId,
        name: _profileNameController.text.trim().isEmpty
            ? '未命名服务器'
            : _profileNameController.text.trim(),
        serverUrl: _baseUrlController.text.trim(),
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        defaultDirectory: existing?.defaultDirectory ?? '',
        openListRecovery:
            existing?.openListRecovery ?? const OpenListRecoveryConfig(),
        openListIndex: existing?.openListIndex ?? const OpenListIndexConfig(),
      );
      await appState.configStore.save(
        appState.configStore.current.upsertProfile(profile),
      );
      appState.refreshOpenListIndexSchedule();
      if (!mounted) return;
      // 连接成功：进入浏览页（替换本页，避免返回后残留表单）。
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const BrowserPage()),
      );
    } on AppException catch (e) {
      if (connected) appState.disconnect();
      if (!mounted) return;
      _showError(e.message);
    } catch (e) {
      if (connected) appState.disconnect();
      if (!mounted) return;
      _showError('连接失败：$e');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: AppText(message)));
  }

  void _selectProfile(String? profileId) {
    if (profileId == null) return;
    final profile = _profiles
        .where((item) => item.profileId == profileId)
        .firstOrNull;
    if (profile == null) return;
    setState(() {
      _selectedProfileId = profile.profileId;
      _profileNameController.text = profile.name;
      _baseUrlController.text = profile.serverUrl;
      _usernameController.text = profile.username;
      _passwordController.text = profile.password;
    });
  }

  void _newProfile() {
    setState(() {
      _selectedProfileId = null;
      _profileNameController.text = '新服务器';
      _baseUrlController.clear();
      _usernameController.clear();
      _passwordController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _StreamPathMark(),
            SizedBox(width: 10),
            AppText('StreamPath'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: context.l10n.text('设置'),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            const padding = EdgeInsets.symmetric(horizontal: 20, vertical: 6);
            final minContentHeight = constraints.maxHeight > padding.vertical
                ? constraints.maxHeight - padding.vertical
                : 0.0;
            return SingleChildScrollView(
              padding: padding,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: minContentHeight),
                child: Align(
                  alignment: Alignment.center,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: _buildConnectionCard(context),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildConnectionCard(BuildContext context) {
    final tokens = Theme.of(context).glass;
    return GlassSurface(
      level: tokens.enabled
          ? GlassSurfaceLevel.content
          : GlassSurfaceLevel.raised,
      border: Border.all(color: tokens.borderColor),
      showShadow: false,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.all(28),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppText(
              '连接服务器',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 6),
            AppText(
              '输入已配置的 WebDAV 服务信息',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            if (_profiles.isNotEmpty) ...[
              DropdownButtonFormField<String>(
                key: const Key('server-profile-selector'),
                initialValue: _selectedProfileId,
                decoration: InputDecoration(
                  labelText: context.l10n.text('服务器档案'),
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                  prefixIcon: Icon(Icons.dns_outlined),
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final profile in _profiles)
                    DropdownMenuItem(
                      value: profile.profileId,
                      child: AppText(profile.name),
                    ),
                ],
                onChanged: _connecting ? null : _selectProfile,
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _connecting ? null : _newProfile,
                  icon: const Icon(Icons.add),
                  label: const AppText('新建档案'),
                ),
              ),
              const SizedBox(height: 8),
            ],
            TextFormField(
              controller: _profileNameController,
              decoration: InputDecoration(
                labelText: context.l10n.text('档案名称'),
                floatingLabelBehavior: FloatingLabelBehavior.always,
                prefixIcon: Icon(Icons.label_outline),
                border: OutlineInputBorder(),
              ),
              validator: (value) => value == null || value.trim().isEmpty
                  ? context.l10n.text('请输入档案名称')
                  : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _baseUrlController,
              decoration: InputDecoration(
                labelText: context.l10n.text('服务器地址'),
                hintText: context.l10n.text('https://example.com/dav'),
                floatingLabelBehavior: FloatingLabelBehavior.always,
                prefixIcon: Icon(Icons.link),
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              contextMenuBuilder: buildClipboardHistoryMenu,
              validator: (v) {
                final s = v?.trim() ?? '';
                if (s.isEmpty) return context.l10n.text('请输入服务器地址');
                if (!s.startsWith('http://') && !s.startsWith('https://')) {
                  return context.l10n.text('地址需以 http:// 或 https:// 开头');
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _usernameController,
              contextMenuBuilder: buildClipboardHistoryMenu,
              decoration: InputDecoration(
                labelText: context.l10n.text('用户名'),
                floatingLabelBehavior: FloatingLabelBehavior.always,
                prefixIcon: Icon(Icons.person_outline),
                border: OutlineInputBorder(),
              ),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? context.l10n.text('请输入用户名')
                  : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _passwordController,
              obscureText: _obscurePassword,
              contextMenuBuilder: buildClipboardHistoryMenu,
              decoration: InputDecoration(
                labelText: context.l10n.text('密码'),
                helperText: context.l10n.text('服务器未设置密码时可留空'),
                floatingLabelBehavior: FloatingLabelBehavior.always,
                prefixIcon: const Icon(Icons.lock_outline),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassword ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _connecting ? null : _connect,
              icon: _connecting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.login),
              label: AppText(_connecting ? '连接中…' : '连接'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 复用应用图标的“文件夹 + 播放”构图，适配标题栏小尺寸显示。
class _StreamPathMark extends StatelessWidget {
  const _StreamPathMark();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: SizedBox(
        width: 28,
        height: 28,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(
              Icons.folder_rounded,
              size: 28,
              color: scheme.surfaceContainerHighest,
            ),
            Icon(Icons.folder_outlined, size: 28, color: scheme.primary),
            Icon(Icons.play_arrow_rounded, size: 15, color: scheme.primary),
          ],
        ),
      ),
    );
  }
}
