import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/errors/app_exception.dart';
import '../../data/models/local_root_config.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../state/app_state.dart';
import '../controllers/film_catalog_controller.dart';
import '../widgets/local_root_dialog.dart';
import '../widgets/sp_dialog.dart';
import '../widgets/sp_icons.dart';
import '../widgets/sp_notice.dart';
import '../widgets/directory_scroll_view.dart';
import 'media_connections_page.dart';
import 'global_search_page.dart';
import 'network_storage_page.dart';
import 'local_storage_page.dart';
import 'film_library_manage_page.dart';

/// 来源管理与目录浏览共用同一导航分支。
class FoldersPage extends StatefulWidget {
  const FoldersPage({super.key, required this.onOpenResult});
  static const searchRouteName = 'folder-search';
  final OpenGlobalSearchResult onOpenResult;

  @override
  State<FoldersPage> createState() => _FoldersPageState();
}

class _FoldersPageState extends State<FoldersPage> {
  final Set<String> _busy = {};
  Future<FilmCatalogController>? _filmCatalog;

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

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 48,
          title: const AppText('文件夹'),
          actions: [
            IconButton(
              key: const Key('folders-search'),
              tooltip: context.l10n.text('搜索文件和文件夹'),
              icon: const Icon(SPIcons.search),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  settings: const RouteSettings(
                    name: FoldersPage.searchRouteName,
                  ),
                  builder: (_) =>
                      GlobalSearchPage(onOpenResult: widget.onOpenResult),
                ),
              ),
            ),
          ],
          bottom: const TabBar(
            dividerColor: Colors.transparent,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelPadding: EdgeInsets.symmetric(horizontal: 20),
            tabs: [
              Tab(key: Key('folders-network-tab'), child: AppText('网络存储')),
              Tab(key: Key('folders-local-tab'), child: AppText('本地文件夹')),
              Tab(key: Key('folders-server-tab'), child: AppText('媒体服务器')),
              Tab(key: Key('folders-film-tab'), child: AppText('影视库')),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            DirectoryScrollView(
              builder: (controller) => SingleChildScrollView(
                key: PageStorageKey('folders-network'),
                controller: controller,
                padding: EdgeInsets.all(20),
                child: MediaConnectionsPage(
                  embedded: true,
                  management: true,
                  onAddWebDav: _addNetwork,
                  beforeConnections: NetworkStoragePage(
                    embedded: true,
                    onRemove: (profile) async {
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
              ),
            ),
            DirectoryScrollView(
              builder: (controller) => SingleChildScrollView(
                key: PageStorageKey('folders-local'),
                controller: controller,
                padding: EdgeInsets.all(20),
                child: LocalStoragePage(
                  embedded: true,
                  onAdd: () => _editLocal(),
                  onEdit: _editLocal,
                  onEnabled: (root, enabled) => _run(
                    root.rootId,
                    () => app.setLocalRootEnabled(root.rootId, enabled),
                  ),
                  onRemove: (root) async {
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
              ),
            ),
            const MediaConnectionsPage(servers: true, management: true),
            FutureBuilder<FilmCatalogController>(
              future: _filmCatalog ??= app.getFilmCatalog(),
              builder: (_, state) => state.hasData
                  ? FilmLibraryManagePage(
                      catalog: state.data!,
                      embedded: true,
                      directories: true,
                    )
                  : state.hasError
                  ? const Center(child: AppText('影视目录库操作失败'))
                  : const Center(child: CircularProgressIndicator()),
            ),
          ],
        ),
      ),
    );
  }
}
