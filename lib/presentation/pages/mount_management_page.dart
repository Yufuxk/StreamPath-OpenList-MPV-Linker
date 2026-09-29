import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/errors/app_exception.dart';
import '../../data/models/local_root_config.dart';
import '../../data/models/server_profile.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../state/app_state.dart';
import '../widgets/local_root_dialog.dart';
import '../widgets/sp_dialog.dart';
import '../widgets/sp_icons.dart';
import '../widgets/sp_notice.dart';

/// 挂载入口只管理来源，不修改来源里的媒体文件或历史。
class MountManagementPage extends StatefulWidget {
  const MountManagementPage({super.key});

  @override
  State<MountManagementPage> createState() => _MountManagementPageState();
}

class _MountManagementPageState extends State<MountManagementPage> {
  final Set<String> _busy = {};

  void _notice(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SPNotice(content: AppText(message)));
    }
  }

  Future<void> _run(String id, Future<void> Function() action) async {
    if (!_busy.add(id)) {
      return;
    }
    setState(() {});
    try {
      await action();
    } on AppException catch (error) {
      _notice(error.message);
    } on FileSystemException {
      _notice('本地根目录不存在或不可访问');
    } finally {
      _busy.remove(id);
      if (mounted) setState(() {});
    }
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => SPDialog(
          title: AppText(title),
          content: AppText(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const AppText('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const AppText('移除挂载'),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _addNetwork() async {
    final config = context.read<AppState>().configStore.current;
    final candidates = config.profiles
        .where(
          (profile) => !config.mountedProfileIds.contains(profile.profileId),
        )
        .toList();
    final id = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SPDialog(
        title: const AppText('添加已保存的服务器'),
        content: SizedBox(
          width: 420,
          child: candidates.isEmpty
              ? const AppText('没有可添加的服务器档案')
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: candidates.length,
                  itemBuilder: (_, index) => ListTile(
                    title: AppText(candidates[index].name),
                    subtitle: AppText(candidates[index].serverUrl),
                    onTap: () => Navigator.of(
                      dialogContext,
                    ).pop(candidates[index].profileId),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const AppText('取消'),
          ),
        ],
      ),
    );
    if (id != null && mounted) {
      await _run(id, () => context.read<AppState>().mountProfile(id));
    }
  }

  Future<void> _editLocal([LocalRootConfig? root]) async {
    final draft = await showLocalRootDialog(context, initial: root);
    if (!mounted || draft == null) return;
    await _run(root?.rootId ?? draft.path, () async {
      await context.read<AppState>().saveLocalRoot(
        path: draft.path,
        displayName: draft.displayName,
        rootId: root?.rootId,
        enabled: draft.enabled,
      );
    });
  }

  Widget _networkTab(AppState app) {
    final config = app.configStore.current;
    final profiles = <ServerProfile>[
      for (final id in config.mountedProfileIds)
        if (config.profiles.where((item) => item.profileId == id).firstOrNull
            case final ServerProfile profile)
          profile,
    ];
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: _addNetwork,
              icon: const Icon(SPIcons.add),
              label: const AppText('添加 WebDAV 挂载'),
            ),
          ),
        ),
        for (final profile in profiles)
          ListTile(
            key: ValueKey('manage-network-${profile.profileId}'),
            leading: const Icon(SPIcons.cloud),
            title: AppText(profile.name),
            subtitle: AppText(
              app.mountError(profile.profileId) == null
                  ? profile.serverUrl
                  : '连接失败，点击重试',
            ),
            onTap: _busy.contains(profile.profileId)
                ? null
                : () => _run(
                    profile.profileId,
                    () => app.mountProfile(profile.profileId),
                  ),
            trailing: IconButton(
              tooltip: context.l10n.text('移除挂载'),
              icon: const Icon(SPIcons.delete),
              onPressed: _busy.contains(profile.profileId)
                  ? null
                  : () async {
                      if (await _confirm(
                        '移除服务器挂载？',
                        '只移除网络存储入口；服务器档案和媒体记录会保留。',
                      )) {
                        await _run(
                          profile.profileId,
                          () => app.unmountProfile(profile.profileId),
                        );
                      }
                    },
            ),
          ),
      ],
    );
  }

  Widget _localTab(AppState app) => ListView(
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: () => _editLocal(),
            icon: const Icon(SPIcons.add),
            label: const AppText('添加本地文件夹'),
          ),
        ),
      ),
      for (final root in app.localRoots)
        ListTile(
          key: ValueKey('manage-local-${root.rootId}'),
          leading: const Icon(SPIcons.folder),
          title: AppText(root.displayName),
          subtitle: AppText(root.path),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Switch(
                value: root.enabled,
                onChanged: (enabled) => _run(
                  root.rootId,
                  () => app.setLocalRootEnabled(root.rootId, enabled),
                ),
              ),
              IconButton(
                tooltip: context.l10n.text('编辑'),
                icon: const Icon(SPIcons.edit),
                onPressed: () => _editLocal(root),
              ),
              IconButton(
                tooltip: context.l10n.text('移除挂载'),
                icon: const Icon(SPIcons.delete),
                onPressed: () async {
                  if (await _confirm(
                    '删除本地文件夹？',
                    '只移除挂载配置，不删除磁盘文件；媒体中心历史会保留。',
                  )) {
                    await _run(
                      root.rootId,
                      () => app.removeLocalRoot(root.rootId),
                    );
                  }
                },
              ),
            ],
          ),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 48,
          title: const AppText('文件夹管理'),
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelPadding: EdgeInsets.symmetric(horizontal: 20),
            tabs: [
              Tab(child: AppText('网络文件夹')),
              Tab(child: AppText('本地文件夹')),
            ],
          ),
        ),
        body: TabBarView(children: [_networkTab(app), _localTab(app)]),
      ),
    );
  }
}
