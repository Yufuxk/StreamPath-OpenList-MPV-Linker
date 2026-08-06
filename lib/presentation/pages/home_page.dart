import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/errors/app_exception.dart';
import '../../data/models/connection_config.dart';
import '../state/app_state.dart';
import 'browser_page.dart';
import 'settings_page.dart';
import '../widgets/clipboard_history_menu.dart';

/// 连接配置页：服务器地址 / 账号 / 密码。
///
/// 连接成功 → 进入文件浏览页；失败 → SnackBar 展示统一异常提示。
/// 已保存的连接信息自动填入表单；信息完整时启动即自动连接
/// （无需再点登录）。
class HomePage extends StatefulWidget {
  const HomePage({super.key, this.initialError});

  /// 自动连接失败时的错误信息（进入本页时显示）。
  final String? initialError;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _formKey = GlobalKey<FormState>();
  final _baseUrlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _connecting = false;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _loadSavedConnection();
    final error = widget.initialError;
    if (error != null) {
      // 等首帧完成后再提示（ScaffoldMessenger 就绪）。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showError(error);
      });
    }
  }

  /// 载入上次保存的连接信息：填入表单；信息完整时自动连接。
  Future<void> _loadSavedConnection() async {
    final ConnectionConfig saved;
    try {
      saved = await context.read<AppState>().configStore.loadConnection();
    } on AppException {
      return; // 配置损坏时显示空表单。
    }
    if (!mounted) return;
    _baseUrlController.text = saved.baseUrl;
    _usernameController.text = saved.username;
    _passwordController.text = saved.password;
    // 自动连接由 AutoConnectGate 负责（本页仅预填 + 手动登录）。
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
      await appState.configStore.saveConnection(ConnectionConfig(
        baseUrl: _baseUrlController.text.trim(),
        username: _usernameController.text.trim(),
        password: _passwordController.text,
      ));
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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('StreamPath — WebDAV 浏览器'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '播放器设置',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
              );
            },
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(
                        Icons.folder_shared_outlined,
                        size: 56,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '连接 WebDAV 服务器',
                        style: Theme.of(context).textTheme.titleLarge,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      TextFormField(
                        controller: _baseUrlController,
                        decoration: const InputDecoration(
                          labelText: '服务器地址',
                          hintText: 'https://example.com/dav',
                          prefixIcon: Icon(Icons.link),
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.url,
                        contextMenuBuilder: buildClipboardHistoryMenu,
                        validator: (v) {
                          final s = v?.trim() ?? '';
                          if (s.isEmpty) return '请输入服务器地址';
                          if (!s.startsWith('http://') &&
                              !s.startsWith('https://')) {
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
                          prefixIcon: const Icon(Icons.lock_outline),
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            icon: Icon(_obscurePassword
                                ? Icons.visibility_off
                                : Icons.visibility),
                            onPressed: () => setState(
                                () => _obscurePassword = !_obscurePassword),
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
              ),
            ),
          ),
        ),
      ),
    );
  }
}
