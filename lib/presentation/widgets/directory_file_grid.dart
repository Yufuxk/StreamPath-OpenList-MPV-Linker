import 'package:flutter/material.dart';

import '../../data/models/media_directory_entry.dart';
import '../localization/app_text.dart';
import 'directory_scroll_view.dart';
import 'file_tile.dart';
import 'sp_controls.dart';
import 'sp_icons.dart';

typedef DirectoryGridItemBuilder =
    Widget Function(BuildContext context, MediaDirectoryEntry entry, int index);

/// 文件平铺视图沿用列表的虚拟构建、滚轮和刷新链路。
class DirectoryFileGrid extends StatelessWidget {
  const DirectoryFileGrid({
    super.key,
    required this.entries,
    required this.controller,
    required this.scrollKey,
    required this.onRefresh,
    required this.itemBuilder,
    required this.emptyLabel,
    required this.onParentTap,
    required this.refreshing,
  });

  final List<MediaDirectoryEntry> entries;
  final ScrollController controller;
  final Key scrollKey;
  final RefreshCallback onRefresh;
  final DirectoryGridItemBuilder itemBuilder;
  final String emptyLabel;
  final ValueChanged<MediaDirectoryEntry> onParentTap;
  final bool refreshing;

  @override
  Widget build(BuildContext context) {
    final parentIndex = entries.indexWhere((entry) => entry.isSelfEntry);
    final files = [
      for (var index = 0; index < entries.length; index++)
        if (index != parentIndex) (entry: entries[index], index: index),
    ];
    return FileListSurface(
      child: DirectoryScrollView(
        controller: controller,
        thumbVisibility: true,
        builder: (_) => RefreshIndicator(
          onRefresh: onRefresh,
          child: entries.isEmpty
              ? ListView(
                  key: scrollKey,
                  controller: controller,
                  children: [
                    const SizedBox(height: 200),
                    Center(child: AppText(emptyLabel)),
                  ],
                )
              : CustomScrollView(
                  key: scrollKey,
                  controller: controller,
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    if (parentIndex >= 0)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                          child: SPTile(
                            onTap: () => onParentTap(entries[parentIndex]),
                            borderRadius: BorderRadius.circular(8),
                            child: SizedBox(
                              height: 48,
                              child: Row(
                                children: [
                                  const SizedBox(width: 12),
                                  Icon(
                                    SPIcons.up,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    size: 24,
                                  ),
                                  const SizedBox(width: 12),
                                  const Expanded(child: AppText('返回上级目录')),
                                  if (refreshing)
                                    const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  const SizedBox(width: 12),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    SliverPadding(
                      padding: const EdgeInsets.all(12),
                      sliver: SliverGrid(
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 280,
                              mainAxisExtent: 104,
                              mainAxisSpacing: 10,
                              crossAxisSpacing: 10,
                            ),
                        delegate: SliverChildBuilderDelegate(
                          (context, index) => itemBuilder(
                            context,
                            files[index].entry,
                            files[index].index,
                          ),
                          childCount: files.length,
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

class FileGridTile extends StatelessWidget {
  const FileGridTile({
    super.key,
    required this.file,
    this.onTap,
    this.trailing,
    this.folderSize,
    this.revealed = false,
  });

  final MediaDirectoryEntry file;
  final VoidCallback? onTap;
  final Widget? trailing;
  final Future<int>? folderSize;
  final bool revealed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: revealed ? scheme.primaryContainer : scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SPTile(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    file.isSelfEntry ? SPIcons.up : FileTile.iconFor(file),
                    color: file.isSelfEntry
                        ? scheme.primary
                        : FileTile.colorFor(file, scheme),
                    size: 32,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: AppText(
                      file.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  ?trailing,
                ],
              ),
              const Spacer(),
              if (!file.isSelfEntry)
                FutureBuilder<int>(
                  future: folderSize,
                  builder: (context, snapshot) {
                    final parts = <String>[
                      if (!file.isDirectory) file.sizeLabel,
                      if (folderSize != null)
                        snapshot.hasError
                            ? '—'
                            : snapshot.hasData
                            ? FileTile.formatBytes(snapshot.data!)
                            : '…',
                      if (file.modified != null)
                        FileTile.formatDate(file.modified!),
                    ];
                    return AppText(
                      parts.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}
