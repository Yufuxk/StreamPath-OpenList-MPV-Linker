import 'package:flutter/material.dart';
import '../widgets/sp_icons.dart';
import '../widgets/sp_notice.dart';
import 'package:provider/provider.dart';

import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../state/app_state.dart';
import '../theme/glass_tokens.dart';
import '../widgets/glass_surface.dart';
import 'local_storage_page.dart';
import 'network_storage_page.dart';
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
        ).showSnackBar(SPNotice(content: AppText(error)));
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
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const NetworkStoragePage()));
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final mountedProfiles =
        appState.configStore.current.mountedProfileIds.length;
    final enabledRoots = appState.localRoots
        .where((root) => root.enabled)
        .length;
    return Scaffold(
      appBar: AppBar(
        title: const AppText('存储'),
        actions: [
          IconButton(
            icon: const Icon(SPIcons.settings),
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
                  SPIcons.cloud,
                  color: Theme.of(context).colorScheme.primary,
                  size: 30,
                ),
                title: const AppText('网络存储'),
                subtitle: AppText(
                  mountedProfiles == 0
                      ? '未挂载 WebDAV'
                      : context.l10n.format('已挂载 {count} 个 WebDAV 服务器', {
                          'count': '$mountedProfiles',
                        }),
                ),
                trailing: const Icon(SPIcons.chevronRight),
                onTap: _openNetworkStorage,
              ),
              const Divider(height: 1),
              ListTile(
                key: const Key('local-storage-folder'),
                leading: Icon(
                  SPIcons.folder,
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
                trailing: const Icon(SPIcons.chevronRight),
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
