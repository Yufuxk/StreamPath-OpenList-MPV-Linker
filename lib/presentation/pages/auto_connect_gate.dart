import 'package:flutter/material.dart';

import '../localization/app_text.dart';
import 'package:provider/provider.dart';

import '../../core/errors/app_exception.dart';
import '../state/app_state.dart';
import 'browser_page.dart';
import 'home_page.dart';

/// 自动连接中转页：已保存完整登录信息时，启动直接连接服务器。
///
/// 连接成功 → 文件浏览页；失败 → 登录页（表单预填 + 错误提示）。
/// 避免「登录界面闪现」：有完整配置时根本不渲染登录页。
class AutoConnectGate extends StatefulWidget {
  const AutoConnectGate({super.key});

  @override
  State<AutoConnectGate> createState() => _AutoConnectGateState();
}

class _AutoConnectGateState extends State<AutoConnectGate> {
  @override
  void initState() {
    super.initState();
    _autoConnect();
  }

  Future<void> _autoConnect() async {
    final appState = context.read<AppState>();
    final config = await appState.configStore.load();
    try {
      await appState.connect(
        baseUrl: config.serverUrl.trim(),
        username: config.username.trim(),
        password: config.password,
        profileId: config.profileId,
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const BrowserPage()),
      );
    } on AppException catch (e) {
      _openLoginWithError(e.message);
    } catch (e) {
      _openLoginWithError('连接失败：$e');
    }
  }

  void _openLoginWithError(String message) {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => HomePage(initialError: message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            AppText('正在连接服务器…', style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}
