import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/local_root_config.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../state/app_state.dart';
import '../widgets/mounted_playback_bars.dart';
import '../widgets/sp_icons.dart';
import '../widgets/file_tile.dart';
import 'local_browser_page.dart';

class LocalStoragePage extends StatefulWidget {
  const LocalStoragePage({
    super.key,
    this.embedded = false,
    this.onAdd,
    this.onEdit,
    this.onEnabled,
    this.onRemove,
  });
  final bool embedded;
  final VoidCallback? onAdd;
  final ValueChanged<LocalRootConfig>? onEdit;
  final void Function(LocalRootConfig root, bool enabled)? onEnabled;
  final ValueChanged<LocalRootConfig>? onRemove;

  @override
  State<LocalStoragePage> createState() => _LocalStoragePageState();
}

class _LocalStoragePageState extends State<LocalStoragePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  int _barsRevision = 0;
  final Map<String, Future<int>> _sizes = {};

  Future<int> _recursiveSize(String path) async {
    var total = 0;
    await for (final child in Directory(
      path,
    ).list(recursive: true, followLinks: false)) {
      if (await FileSystemEntity.type(child.path, followLinks: false) ==
          FileSystemEntityType.file) {
        total += await File(child.path).length();
      }
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final roots = context.watch<AppState>().localRoots;
    final content = roots.isEmpty
        ? const Center(child: AppText('添加本地文件夹以开始浏览'))
        : ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: roots.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final root = roots[index];
              return ListTile(
                key: ValueKey('local-root-${root.rootId}'),
                enabled: root.enabled,
                leading: const Icon(SPIcons.folder, size: 32),
                title: AppText(root.displayName),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      root.enabled
                          ? root.path
                          : context.l10n.format('{path} · 已停用', {
                              'path': root.path,
                            }),
                    ),
                    if (root.enabled)
                      FutureBuilder<int>(
                        future: _sizes.putIfAbsent(
                          root.path,
                          () => _recursiveSize(root.path),
                        ),
                        builder: (context, snapshot) => AppText(
                          snapshot.hasError
                              ? '—'
                              : snapshot.hasData
                              ? FileTile.formatBytes(snapshot.data!)
                              : '…',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
                onTap: root.enabled
                    ? () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => LocalBrowserPage(root: root),
                          ),
                        );
                        if (mounted) setState(() => _barsRevision++);
                      }
                    : null,
                trailing: widget.onEdit == null
                    ? null
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Switch(
                            value: root.enabled,
                            onChanged: (enabled) =>
                                widget.onEnabled!(root, enabled),
                          ),
                          IconButton(
                            tooltip: context.l10n.text('编辑'),
                            icon: const Icon(SPIcons.edit),
                            onPressed: () => widget.onEdit!(root),
                          ),
                          IconButton(
                            tooltip: context.l10n.text('移除挂载'),
                            icon: const Icon(SPIcons.delete),
                            onPressed: () => widget.onRemove!(root),
                          ),
                        ],
                      ),
              );
            },
          );
    final bars = MountedPlaybackBars(
      key: ValueKey(
        '$_barsRevision-'
        '${roots.where((root) => root.enabled).map((root) => root.rootId).join('|')}',
      ),
      network: false,
    );
    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.onAdd != null) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                key: const Key('add-local-root-button'),
                onPressed: widget.onAdd,
                icon: const Icon(SPIcons.add),
                label: const AppText('添加本地文件夹'),
              ),
            ),
            const SizedBox(height: 12),
          ],
          content,
          bars,
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(toolbarHeight: 48, title: const AppText('本地文件夹')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: content,
      ),
      bottomNavigationBar: bars,
    );
  }
}
