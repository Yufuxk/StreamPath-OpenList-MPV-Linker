import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/media_library_item.dart';
import '../localization/app_text.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import 'media_library_page.dart';
import '../controllers/film_catalog_controller.dart';

/// 从侧边栏查看全部已挂载来源的媒体记录。
class GlobalMediaLibraryPage extends StatefulWidget {
  const GlobalMediaLibraryPage({
    super.key,
    required this.onOpenItem,
    this.filmCatalog,
    this.onContinueSelected,
    this.onContinueMenu,
    this.filmCenter = false,
    this.headerAction,
    this.sidebarInset = 0,
  });

  final ValueChanged<MediaLibraryItem> onOpenItem;
  final FilmCatalogController? filmCatalog;
  final ValueChanged<MediaLibraryRecord>? onContinueSelected;
  final void Function(MediaLibraryRecord, Offset)? onContinueMenu;
  final bool filmCenter;
  final Widget? headerAction;
  final double sidebarInset;

  @override
  State<GlobalMediaLibraryPage> createState() => _GlobalMediaLibraryPageState();
}

class _GlobalMediaLibraryPageState extends State<GlobalMediaLibraryPage> {
  String? _selectedSource;
  late final Future<void> _ready;
  @override
  void initState() {
    super.initState();
    _ready = widget.filmCatalog == null
        ? Future.value()
        : context.read<AppState>().initializeFilmPlayback();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.filmCatalog != null) {
      return FutureBuilder<void>(
        future: _ready,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: AppText('读取媒体资产失败'));
          }
          return snapshot.connectionState == ConnectionState.done
              ? _content(context)
              : const SizedBox.shrink();
        },
      );
    }
    return _content(context);
  }

  Widget _content(BuildContext context) {
    final app = context.watch<AppState>();
    final config = app.configStore.current;
    final store = widget.filmCatalog == null
        ? app.mediaLibraryStore
        : app.filmMediaLibraryStore;
    final names = <String, String>{
      for (final root in app.localRoots.where((root) => root.enabled))
        root.sourceId: root.displayName,
      for (final profile in config.profiles.where(
        (profile) => config.mountedProfileIds.contains(profile.profileId),
      ))
        profile.profileId: profile.name,
    };
    if (store == null ||
        (names.isEmpty && !widget.filmCenter && widget.headerAction == null)) {
      return widget.filmCatalog != null && !widget.filmCenter
          ? const SizedBox.shrink()
          : const Scaffold(body: Center(child: AppText('没有可用的媒体来源')));
    }
    final selected = names.containsKey(_selectedSource)
        ? _selectedSource
        : null;
    final sourceIds = selected == null ? names.keys.toSet() : {selected};
    final primary = sourceIds.firstOrNull ?? '';
    final filterWidth = MediaQuery.sizeOf(context).width < 680 ? 180.0 : 280.0;
    return MediaLibraryPage(
      key: ValueKey(selected ?? 'all'),
      filmCatalog: widget.filmCatalog,
      filmCenter: widget.filmCenter,
      headerAction: widget.headerAction,
      sidebarInset: widget.sidebarInset,
      onContinueSelected: widget.onContinueSelected,
      onContinueMenu: widget.onContinueMenu,
      sourceId: primary,
      sourceIds: sourceIds,
      sourceNames: names,
      store: store,
      config: widget.filmCatalog == null ? config.mediaLibrary : store.config,
      directoryCache: app.directoryCache,
      videoProgressService: widget.filmCatalog == null
          ? app.progressService
          : app.filmProgressService,
      audioProgressService: app.audioProgressService,
      isoProgressService: widget.filmCatalog == null
          ? app.isoPlaybackService
          : app.filmIsoPlaybackService,
      localIsoProgressService: widget.filmCatalog == null
          ? app.localDiscPlaybackService
          : app.filmLocalDiscPlaybackService,
      resolveUrl: (href) => href,
      resolveDirectTarget: (item) => app.resolveMediaLibraryTarget(
        item,
        allowLogicalPath: widget.filmCatalog != null,
      ),
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
