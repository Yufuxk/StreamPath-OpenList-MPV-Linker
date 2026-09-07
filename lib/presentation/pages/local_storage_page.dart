import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/errors/app_exception.dart';
import '../../data/models/local_root_config.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../state/app_state.dart';
import '../theme/glass_tokens.dart';
import '../widgets/glass_surface.dart';
import '../widgets/local_root_dialog.dart';
import 'local_browser_page.dart';
import 'settings_page.dart';

class LocalStoragePage extends StatefulWidget {
  const LocalStoragePage({super.key});

  @override
  State<LocalStoragePage> createState() => _LocalStoragePageState();
}

class _LocalStoragePageState extends State<LocalStoragePage> {
  Future<void> _saveRoot([LocalRootConfig? initial]) async {
    final draft = await showLocalRootDialog(context, initial: initial);
    if (!mounted || draft == null) return;
    try {
      await context.read<AppState>().saveLocalRoot(
        path: draft.path,
        displayName: draft.displayName,
        rootId: initial?.rootId,
        enabled: draft.enabled,
      );
    } on AppException catch (error) {
      _showError(error.message);
    } on FileSystemException {
      _showError('本地根目录不存在或不可访问');
    }
  }

  Future<void> _removeRoot(LocalRootConfig root) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const AppText('删除本地文件夹？'),
        content: const AppText('只移除挂载配置，不删除磁盘文件；媒体中心历史将保留为来源不可用。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const AppText('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const AppText('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await context.read<AppState>().removeLocalRoot(root.rootId);
    } on AppException catch (error) {
      _showError(error.message);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: AppText(message)));
  }

  Future<void> _openSettings() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final roots = context.watch<AppState>().localRoots;
    return Scaffold(
      appBar: AppBar(
        title: const AppText('本地存储'),
        actions: [
          IconButton(
            key: const Key('add-local-root-button'),
            tooltip: context.l10n.text('添加本地文件夹'),
            icon: const Icon(Icons.add),
            onPressed: _saveRoot,
          ),
          IconButton(
            tooltip: context.l10n.text('设置'),
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: roots.isEmpty
          ? const Center(child: AppText('无文件'))
          : Padding(
              padding: const EdgeInsets.all(20),
              child: GlassSurface(
                level: GlassSurfaceLevel.content,
                automaticBorder: false,
                child: ListView.separated(
                  itemCount: roots.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final root = roots[index];
                    return ListTile(
                      key: ValueKey('local-root-${root.rootId}'),
                      enabled: root.enabled,
                      leading: const Icon(Icons.folder_outlined, size: 28),
                      title: AppText(root.displayName),
                      subtitle: AppText(
                        root.enabled
                            ? root.path
                            : context.l10n.format('{path} · 已停用', {
                                'path': root.path,
                              }),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: root.enabled
                          ? () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => LocalBrowserPage(root: root),
                              ),
                            )
                          : null,
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) async {
                          switch (value) {
                            case 'edit':
                              await _saveRoot(root);
                            case 'toggle':
                              await context
                                  .read<AppState>()
                                  .setLocalRootEnabled(
                                    root.rootId,
                                    !root.enabled,
                                  );
                            case 'remove':
                              await _removeRoot(root);
                          }
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: 'edit',
                            child: AppText('编辑'),
                          ),
                          PopupMenuItem(
                            value: 'toggle',
                            child: AppText(root.enabled ? '停用' : '启用'),
                          ),
                          const PopupMenuItem(
                            value: 'remove',
                            child: AppText('删除'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
    );
  }
}
