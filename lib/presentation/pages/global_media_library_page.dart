import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/url_utils.dart';
import '../../data/models/media_library_item.dart';
import '../../data/models/media_source.dart';
import '../localization/app_text.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import 'media_library_page.dart';

/// 从侧边栏查看全部已挂载来源的媒体记录。
class GlobalMediaLibraryPage extends StatefulWidget {
  const GlobalMediaLibraryPage({super.key, required this.onOpenItem});

  final ValueChanged<MediaLibraryItem> onOpenItem;

  @override
  State<GlobalMediaLibraryPage> createState() => _GlobalMediaLibraryPageState();
}

class _GlobalMediaLibraryPageState extends State<GlobalMediaLibraryPage> {
  String? _selectedSource;

  String? _directTarget(AppState app, MediaLibraryItem item) {
    if (item.kind == MediaLibraryKind.directory ||
        item.kind == MediaLibraryKind.strm) {
      return null;
    }
    if (item.sourceKind == MediaSourceKind.local) {
      final root = app.localRoots
          .where((root) => root.sourceId == item.sourceId && root.enabled)
          .firstOrNull;
      if (root == null) return null;
      final source = app.localMediaSource(root);
      final path =
          item.kind == MediaLibraryKind.iso &&
              item.parentPath.isEmpty &&
              item.name == root.displayName
          ? ''
          : item.targetPath;
      return source.lexicalPath(path);
    }
    final profile = app.configStore.current.profiles
        .where((profile) => profile.profileId == item.sourceId)
        .firstOrNull;
    if (profile == null) return null;
    if (item.discRootPath != null) {
      return '${joinUrl(profile.serverUrl, item.discRootPath!).replaceAll(RegExp(r'/+$'), '')}/';
    }
    for (final snapshot in app.directoryCache.visitedDirectories(
      item.sourceId,
    )) {
      if (normalizeLibraryPath(snapshot.path) != item.normalizedParentPath) {
        continue;
      }
      final file = snapshot.entries.where(item.matches).firstOrNull;
      if (file != null) {
        return stripUserInfo(resolveHref(profile.serverUrl, file.href));
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final config = app.configStore.current;
    final names = <String, String>{
      for (final root in app.localRoots.where((root) => root.enabled))
        root.sourceId: root.displayName,
      for (final profile in config.profiles.where(
        (profile) => config.mountedProfileIds.contains(profile.profileId),
      ))
        profile.profileId: profile.name,
    };
    if (names.isEmpty || app.mediaLibraryStore == null) {
      return const Scaffold(body: Center(child: AppText('没有可用的媒体来源')));
    }
    final selected = names.containsKey(_selectedSource)
        ? _selectedSource
        : null;
    final sourceIds = selected == null ? names.keys.toSet() : {selected};
    final primary = sourceIds.first;
    final filterWidth = MediaQuery.sizeOf(context).width < 680 ? 180.0 : 280.0;
    return MediaLibraryPage(
      key: ValueKey(selected ?? 'all'),
      sourceId: primary,
      sourceIds: sourceIds,
      sourceNames: names,
      store: app.mediaLibraryStore!,
      config: config.mediaLibrary,
      directoryCache: app.directoryCache,
      videoProgressService: app.progressService,
      audioProgressService: app.audioProgressService,
      isoProgressService: app.isoPlaybackService,
      localIsoProgressService: app.localDiscPlaybackService,
      resolveUrl: (href) => href,
      resolveDirectTarget: (item) => _directTarget(app, item),
      onVideoPlaybackRecordsChanged: app.scheduleWebDavFontCachePrune,
      onItemSelected: widget.onOpenItem,
      sourceFilter: SizedBox(
        key: const Key('media-library-source-filter'),
        width: filterWidth,
        child: DropdownButtonFormField<String>(
          key: ValueKey('source-$selected-${names.keys.join('|')}'),
          initialValue: selected ?? '',
          isExpanded: true,
          dropdownColor: AppTheme.dropdownMenuColor(Theme.of(context)),
          borderRadius: AppTheme.dropdownBorderRadius,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          items: [
            const DropdownMenuItem(
              value: '',
              child: AppText(
                '全部已挂载来源',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            for (final entry in names.entries)
              DropdownMenuItem(
                value: entry.key,
                child: AppText(
                  entry.value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (value) => setState(() {
            _selectedSource = value == '' ? null : value;
          }),
        ),
      ),
    );
  }
}
