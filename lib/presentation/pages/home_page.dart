import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/errors/app_exception.dart';
import '../../data/models/connection_config.dart';
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
  bool _connecting = false;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    final saved =
        widget.initialConnection ??
        context.read<AppState>().configStore.current.toConnectionConfig();
    _baseUrlController = TextEditingController(text: saved.baseUrl);
    _usernameController = TextEditingController(text: saved.username);
    _passwordController = TextEditingController(text: saved.password);
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
    super.dispose();
  }

  Future<void> _connect() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _connecting = true);
    try {
      final appState = context.read<AppState>();
      await appState.connect(
        baseUrl: _baseUrlController.text.trim(),
        username: _usernameController.text.trim(),
        password: _passwordController.text,
      );
      // 连接成功：保存连接信息（下次启动自动填入/自动连接）。
      await appState.configStore.saveConnection(
        ConnectionConfig(
          baseUrl: _baseUrlController.text.trim(),
          username: _usernameController.text.trim(),
          password: _passwordController.text,
        ),
      );
      if (!mounted) return;
      // 连接成功：进入浏览页（替换本页，避免返回后残留表单）。
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const BrowserPage()),
      );
    } on AppException catch (e) {
      if (!mounted) return;
      _showError(e.message);
    } catch (e) {
      if (!mounted) return;
      _showError('连接失败：$e');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
            Text('StreamPath'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: _buildConnectionCard(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConnectionCard(BuildContext context) {
    return GlassSurface(
      level: GlassSurfaceLevel.raised,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.all(28),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '连接服务器',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '输入已配置的 WebDAV 服务信息',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            TextFormField(
              controller: _baseUrlController,
              decoration: const InputDecoration(
                labelText: '服务器地址',
                hintText: 'https://example.com/dav',
                floatingLabelBehavior: FloatingLabelBehavior.always,
                prefixIcon: Icon(Icons.link),
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              contextMenuBuilder: buildClipboardHistoryMenu,
              validator: (v) {
                final s = v?.trim() ?? '';
                if (s.isEmpty) return '请输入服务器地址';
                if (!s.startsWith('http://') && !s.startsWith('https://')) {
                  return '地址需以 http:// 或 https:// 开头';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _usernameController,
              contextMenuBuilder: buildClipboardHistoryMenu,
              decoration: const InputDecoration(
                labelText: '用户名',
                floatingLabelBehavior: FloatingLabelBehavior.always,
                prefixIcon: Icon(Icons.person_outline),
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '请输入用户名' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _passwordController,
              obscureText: _obscurePassword,
              contextMenuBuilder: buildClipboardHistoryMenu,
              decoration: InputDecoration(
                labelText: '密码',
                helperText: '服务器未设置密码时可留空',
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
              label: Text(_connecting ? '连接中…' : '连接'),
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
