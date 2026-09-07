import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../state/app_state.dart';
import '../theme/glass_tokens.dart';
import '../widgets/glass_surface.dart';
import 'browser_page.dart';
import 'home_page.dart';
import 'local_storage_page.dart';
import 'settings_page.dart';

/// 软件最外层的“网络存储 / 本地存储”目录。
class StorageRootPage extends StatefulWidget {
  const StorageRootPage({super.key, this.initialError});

  final String? initialError;

  @override
  State<StorageRootPage> createState() => _StorageRootPageState();
}

class _StorageRootPageState extends State<StorageRootPage> {
  @override
  void initState() {
    super.initState();
    final error = widget.initialError;
    if (error != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: AppText(error)));
      });
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
    if (mounted) setState(() {});
  }

  void _openNetworkStorage() {
    final connected = context.read<AppState>().webDavService != null;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            connected ? const BrowserPage() : const _EmptyNetworkStoragePage(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final profile = appState.configStore.current.activeProfile;
    final enabledRoots = appState.localRoots
        .where((root) => root.enabled)
        .length;
    return Scaffold(
      appBar: AppBar(
        title: const AppText('存储'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: context.l10n.text('设置'),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: GlassSurface(
          level: GlassSurfaceLevel.content,
          automaticBorder: false,
          child: ListView(
            children: [
              ListTile(
                key: const Key('network-storage-folder'),
                leading: Icon(
                  Icons.cloud_outlined,
                  color: Theme.of(context).colorScheme.primary,
                  size: 30,
                ),
                title: const AppText('网络存储'),
                subtitle: AppText(
                  appState.webDavService == null
                      ? '未挂载 WebDAV'
                      : profile?.name ?? 'WebDAV',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: _openNetworkStorage,
              ),
              const Divider(height: 1),
              ListTile(
                key: const Key('local-storage-folder'),
                leading: Icon(
                  Icons.folder_outlined,
                  color: Theme.of(context).colorScheme.primary,
                  size: 30,
                ),
                title: const AppText('本地存储'),
                subtitle: AppText(
                  enabledRoots == 0
                      ? '未挂载本地文件夹'
                      : context.l10n.format('已挂载 {count} 个本地文件夹', {
                          'count': '$enabledRoots',
                        }),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const LocalStoragePage(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyNetworkStoragePage extends StatelessWidget {
  const _EmptyNetworkStoragePage();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const AppText('网络存储'),
      actions: [
        IconButton(
          key: const Key('add-network-storage-button'),
          tooltip: context.l10n.text('添加 WebDAV'),
          icon: const Icon(Icons.add),
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const HomePage())),
        ),
      ],
    ),
    body: const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_outlined, size: 48),
          SizedBox(height: 12),
          AppText('无文件'),
        ],
      ),
    ),
  );
}
