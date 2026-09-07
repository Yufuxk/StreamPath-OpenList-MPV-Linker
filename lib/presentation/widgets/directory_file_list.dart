import 'package:flutter/material.dart';

import '../../data/models/media_directory_entry.dart';
import '../localization/app_text.dart';
import 'directory_wheel_scroll_region.dart';
import 'file_tile.dart';

typedef DirectoryFileItemBuilder =
    Widget Function(BuildContext context, MediaDirectoryEntry entry, int index);

/// WebDAV 与本地浏览页共用的文件虚拟列表、滚动条和滚轮路由。
class DirectoryFileList extends StatelessWidget {
  const DirectoryFileList({
    super.key,
    required this.entries,
    required this.controller,
    required this.scrollKey,
    required this.onRefresh,
    required this.itemBuilder,
    this.emptyLabel = '空目录',
  });

  final List<MediaDirectoryEntry> entries;
  final ScrollController controller;
  final Key scrollKey;
  final RefreshCallback onRefresh;
  final DirectoryFileItemBuilder itemBuilder;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    final listView = entries.isEmpty
        ? ListView(
            key: scrollKey,
            controller: controller,
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              const SizedBox(height: 200),
              Center(child: AppText(emptyLabel)),
            ],
          )
        : ListView.builder(
            key: scrollKey,
            controller: controller,
            prototypeItem: itemBuilder(context, entries.first, 0),
            itemCount: entries.length,
            itemBuilder: (context, index) =>
                itemBuilder(context, entries[index], index),
          );
    return FileListSurface(
      child: Column(
        children: [
          const FileListHeader(),
          Expanded(
            child: DirectoryWheelScrollRegion(
              controller: controller,
              child: RefreshIndicator(
                onRefresh: onRefresh,
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(
                    context,
                  ).copyWith(scrollbars: false),
                  child: Scrollbar(
                    key: const ValueKey<String>('directory-scrollbar'),
                    controller: controller,
                    thumbVisibility: true,
                    interactive: true,
                    child: listView,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
