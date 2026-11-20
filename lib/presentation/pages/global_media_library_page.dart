import '../widgets/sp_menu.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/media_library_config.dart';
import '../../data/models/media_library_item.dart';
import '../localization/app_text.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import 'media_library_page.dart';
import '../controllers/film_catalog_controller.dart';

enum _SourceScope { all, local, network }

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
    this.onReadyChanged,
  });

  final ValueChanged<MediaLibraryItem> onOpenItem;
  final FilmCatalogController? filmCatalog;
  final ValueChanged<MediaLibraryRecord>? onContinueSelected;
  final void Function(MediaLibraryRecord, Offset)? onContinueMenu;
  final bool filmCenter;
  final Widget? headerAction;
  final double sidebarInset;
  final ValueChanged<bool>? onReadyChanged;

  @override
  State<GlobalMediaLibraryPage> createState() => _GlobalMediaLibraryPageState();
}

class _GlobalMediaLibraryPageState extends State<GlobalMediaLibraryPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => widget.filmCatalog != null && !widget.filmCenter;
  Object _selectedSource = _SourceScope.all;
  late final Future<void> _ready;
  @override
  void initState() {
    super.initState();
    widget.onReadyChanged?.call(false);
    _ready = widget.filmCatalog == null
        ? Future.value()
        : context.read<AppState>().initializeFilmPlayback();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (widget.filmCatalog != null) {
      return FutureBuilder<void>(
        future: _ready,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            widget.onReadyChanged?.call(true);
            return const Center(child: AppText('读取媒体资产失败'));
          }
          return snapshot.connectionState == ConnectionState.done
              ? _content(context)
              : widget.filmCenter
              ? const Scaffold()
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
      for (final connection in app.mediaConnections.where((row) => row.enabled))
        connection.id: connection.name,
      for (final root in app.localRoots.where((root) => root.enabled))
        root.sourceId: root.displayName,
      for (final profile in config.profiles.where(
        (profile) => config.mountedProfileIds.contains(profile.profileId),
      ))
        profile.profileId: profile.name,
    };
    if (widget.filmCatalog?.sourceId case final String source) {
      names.removeWhere((id, _) => id != source);
    }
    if (store == null ||
        (names.isEmpty && !widget.filmCenter && widget.headerAction == null)) {
      widget.onReadyChanged?.call(true);
      return widget.filmCatalog != null && !widget.filmCenter
          ? const SizedBox.shrink()
          : const Scaffold(body: Center(child: AppText('没有可用的媒体来源')));
    }
    final local = names.keys.where((id) => id.startsWith('local:')).toSet();
    final network = names.keys.where((id) => !local.contains(id)).toSet();
    final mode = config.mediaLibrary.sharingMode;
    final scopes = <Object, Set<String>>{
      _SourceScope.all: names.keys.toSet(),
      if (local.length > 1 &&
          (mode == MediaLibrarySharingMode.localShared ||
              mode == MediaLibrarySharingMode.networkAndLocalShared))
        _SourceScope.local: local,
      if (network.length > 1 &&
          (mode == MediaLibrarySharingMode.networkShared ||
              mode == MediaLibrarySharingMode.networkAndLocalShared))
        _SourceScope.network: network,
      for (final id in names.keys) id: {id},
    };
    final selected = scopes.containsKey(_selectedSource)
        ? _selectedSource
        : _SourceScope.all;
    final sourceIds = scopes[selected]!;
    final primary = sourceIds.firstOrNull ?? '';
    final filterWidth = MediaQuery.sizeOf(context).width < 680 ? 180.0 : 220.0;
    return MediaLibraryPage(
      key: ValueKey(selected),
      filmCatalog: widget.filmCatalog,
      onReadyChanged: widget.onReadyChanged,
      filmCenter: widget.filmCenter,
      headerAction: widget.headerAction,
      sidebarInset: widget.sidebarInset,
      onContinueSelected: widget.onContinueSelected,
      onContinueMenu: widget.onContinueMenu,
      sourceId: primary,
      sourceIds: sourceIds,
      sourceNames: names,
      store: store,
      config: config.mediaLibrary,
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
      onVideoPlaybackRecordsChanged: app.schedulePlaybackArtifactPrune,
      onItemSelected: widget.onOpenItem,
      sourceFilter: SizedBox(
        key: const Key('media-library-source-filter'),
        width: filterWidth,
        child: SPDropdownButtonFormField<Object>(
          key: ValueKey((selected, scopes.keys.join('|'))),
          initialValue: selected,
          isExpanded: true,
          dropdownColor: AppTheme.dropdownMenuColor(Theme.of(context)),
          borderRadius: AppTheme.dropdownBorderRadius,
          decoration: const InputDecoration(),
          items: [
            for (final scope in scopes.keys)
              DropdownMenuItem(
                value: scope,
                child: AppText(
                  switch (scope) {
                    _SourceScope.all => '全部已挂载来源',
                    _SourceScope.local => '本地挂载文件夹共享',
                    _SourceScope.network => '网络存储共享',
                    _ => names[scope]!,
                  },
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (value) {
            if (value != null) setState(() => _selectedSource = value);
          },
        ),
      ),
    );
  }
}
