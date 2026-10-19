import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../features/video_cache/video_cache_source.dart';
import 'package:provider/provider.dart';

import '../../core/errors/app_exception.dart';
import '../../data/models/media_library_item.dart';
import '../../data/models/media_source.dart';
import '../../data/models/film_catalog_item.dart';
import '../controllers/film_catalog_controller.dart';
import '../../data/models/playback_history.dart';
import '../../data/models/film_playlist.dart';
import '../../domain/repositories/media_directory_source.dart';
import '../../domain/services/webdav_media_source_adapter.dart';
import '../../domain/services/film_version_resolver.dart';
import '../localization/app_text.dart';
import '../localization/app_localizations.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/sp_dialog.dart';
import '../state/app_state.dart';
import '../widgets/sp_notice.dart';
import '../widgets/film_library_background.dart';
import '../widgets/app_background.dart';
import '../widgets/transition_content.dart';
import '../widgets/film_connected_transition.dart';
import 'browser_page.dart';
import 'film_library_page.dart';

/// 详情导航与播放会话共存，来源各自持有原有播放链路。
class FilmLibraryShell extends StatefulWidget {
  const FilmLibraryShell({super.key, this.sidebarInset = 0, this.sourceId});
  final double sidebarInset;
  final String? sourceId;
  @override
  State<FilmLibraryShell> createState() => FilmLibraryShellState();
}

class FilmLibraryShellState extends State<FilmLibraryShell> {
  final _heroes = FilmConnectedHeroController();
  final _hosts = <String, BrowserPage>{};
  final _cacheSources = <String, MediaDirectorySource>{};
  final _keys = <String, GlobalKey<BrowserPageState>>{};
  bool _playbackMenuOpen = false;
  Future<void>? _restoreFuture;
  FilmCatalogController? _backgroundCatalog;
  VoidCallback? _onBackgroundReady;
  String? _backgroundPath;

  void setBackground(FilmCatalogController catalog, VoidCallback onReady) {
    if (_backgroundCatalog != catalog) {
      _backgroundCatalog?.removeListener(_backgroundChanged);
      _backgroundCatalog = catalog;
      catalog.addListener(_backgroundChanged);
    }
    setState(() {
      _onBackgroundReady = onReady;
      _backgroundPath = catalog.backgroundFile?.path;
    });
  }

  void _backgroundChanged() {
    final path = _backgroundCatalog!.backgroundFile?.path;
    if (path != _backgroundPath) setState(() => _backgroundPath = path);
  }

  @override
  void dispose() {
    _backgroundCatalog?.removeListener(_backgroundChanged);
    _heroes.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreFuture = _restore();
    });
  }

  BrowserPage? _hostFor(String sourceId) {
    final app = context.read<AppState>();
    final local = sourceId.startsWith('local:');
    final root = local
        ? app.localRoots
              .where((r) => r.enabled && r.sourceId == sourceId)
              .firstOrNull
        : null;
    final native = app.nativeSource(sourceId);
    final server = app.serverSource(sourceId);
    final cached = _cacheSources[sourceId];
    final service = local
        ? null
        : cached is WebDavMediaSourceAdapter
        ? cached.service
        : native?.service ?? server?.service ?? app.mountedService(sourceId);
    if (local ? root == null : service == null) return null;
    if (_hosts[sourceId] case final host?) {
      if (host.localRoot?.path == root?.path && host.webDavSource == service) {
        return host;
      }
    }
    final key = GlobalKey<BrowserPageState>();
    _keys[sourceId] = key;
    return _hosts[sourceId] = BrowserPage(
      key: key,
      localRoot: root,
      webDavSource: service,
      directorySource: cached ?? native ?? server,
      playbackOnly: true,
      onFilmSourceBoundary: _confirmSourceBoundary,
    );
  }

  Future<void> _restore() async {
    final app = context.read<AppState>();
    await app.restoreVideoCache();
    await app.initializeFilmPlayback();
    final histories = await app.filmPlaybackHistoryStore.loadAll();
    if (!mounted) return;
    final sources = {
      for (final history in histories)
        if (history.sourceId != null &&
            (history.kind == PlaybackHistoryKind.video ||
                history.kind == PlaybackHistoryKind.iso))
          history.sourceId!,
    };
    final records = app.filmMediaLibraryStore;
    if (records != null) {
      for (final source in {
        ...app.localRoots.where((r) => r.enabled).map((r) => r.sourceId),
        ...app.configStore.current.mountedProfileIds,
      }) {
        final discs = await records.playbackHistory(
          source,
          audio: false,
          iso: true,
        );
        if (discs.any((r) => !r.continueDismissed)) sources.add(source);
      }
    }
    if (!mounted) return;
    for (final source in sources) {
      if (app.videoCache?.hasSource(source) == true) {
        _cacheSources[source] = await app.videoCacheSource(source);
      }
    }
    void restoreHosts() => setState(() {
      for (final source in sources) {
        _hostFor(source);
      }
    });
    restoreHosts();
    for (final source
        in sources
            .where(
              (id) =>
                  app.mediaSourceKind(id).isNativeStorage ||
                  app.mediaSourceKind(id).isMediaServer,
            )
            .where((id) => !_cacheSources.containsKey(id))) {
      try {
        await app.mountMediaConnection(source);
      } on FilmCatalogException {
        continue;
      }
    }
    if (mounted) restoreHosts();
    if (sources.any(
      (source) =>
          !source.startsWith('local:') &&
          !_cacheSources.containsKey(source) &&
          app.configStore.current.mountedProfileIds.contains(source) &&
          app.mountedService(source) == null,
    )) {
      await app.restoreMountedProfiles();
      if (mounted) restoreHosts();
    }
  }

  Future<void> _play(MediaLibraryItem item, {String? resumeSessionId}) async {
    final app = context.read<AppState>();
    await app.initializeFilmPlayback();
    final version = item.filmVersionContext;
    if (version != null) {
      final histories = await app.filmPlaybackHistoryStore.loadAll();
      final candidates =
          histories
              .where(
                (h) =>
                    h.filmVersionContext?.identity == version.identity &&
                    h.filmVersionContext!.signature != version.signature &&
                    (resumeSessionId == null
                        ? h.playerPid != null
                        : h.sessionId == resumeSessionId),
              )
              .toList()
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      if (candidates.isNotEmpty) {
        for (final key in _keys.values.toList()) {
          if (await key.currentState?.stopFilmVersionSession(
                version.identity,
                version.signature,
                sessionId: candidates.first.sessionId,
              ) ==
              false) {
            return;
          }
        }
      }
      if (!mounted) return;
    }
    await _withHost(
      item,
      (host) => host.playLibraryItem(
        item,
        resumeSessionId: resumeSessionId,
        versionSessionHandled: true,
      ),
    );
  }

  Future<String?> _confirmSourceBoundary(MediaLibraryItem item) async {
    if (!mounted) return null;
    bool? activated;
    try {
      activated = await const MethodChannel(
        'streampath/appearance',
      ).invokeMethod<bool>('activate');
    } on PlatformException {
      activated = false;
    } on MissingPluginException {
      activated = false;
    }
    if (!mounted) return null;
    if (activated != true) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SPNotice(content: AppText('请返回主程序后继续播放下一季')));
      return null;
    }
    final store = await context.read<AppState>().getFilmCatalogStore();
    final resource = await store.resourceAt(item.sourceId, item.targetPath);
    if (!mounted) return null;
    if (resource == null || resource.availability != 'present') {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SPNotice(content: AppText('所选版本不可用')));
      return null;
    }
    final proceed = await showGlassDialog<bool>(
      context: context,
      builder: (dialogContext) => SPDialog(
        title: const AppText('继续播放下一季'),
        content: Text(
          context.l10n.format('下一季需要切换播放来源：{version}\n第 {season} 季 · {file}', {
            'version':
                resource.versionName ?? automaticFilmVersion(resource).name,
            'season': resource.season ?? '',
            'file': item.name,
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const AppText('稍后播放'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const AppText('继续播放'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return null;
    final histories = context.read<AppState>().filmPlaybackHistoryStore;
    final before = (await histories.loadAll()).map((h) => h.sessionId).toSet();
    await _play(item);
    final started = (await histories.loadAll())
        .where(
          (h) =>
              !before.contains(h.sessionId) &&
              h.playerPid != null &&
              h.sourceId == item.sourceId &&
              h.filmVersionContext?.signature ==
                  item.filmVersionContext?.signature,
        )
        .firstOrNull;
    return started?.sessionId;
  }

  Future<void> play(MediaLibraryItem item) => _play(item);
  Future<void> playPlaylist(FilmPlaylistSnapshot snapshot, int index) async {
    final entry = snapshot.entries[index];
    var resource = entry.resource;
    if (resource == null) return;
    final app = context.read<AppState>();
    if (entry.pinnedPath == null) {
      for (final version in entry.queueItem.versions) {
        if (await app.cachedTarget(snapshot.playlist.sourceId, version.path) !=
            null) {
          resource = await (await app.getFilmCatalogStore()).resourceAt(
            snapshot.playlist.sourceId,
            version.path,
          );
          break;
        }
      }
    }
    if (resource == null || !mounted) return;
    await app.initializeFilmPlayback();
    await _withHost(
      resource.playbackItem,
      (host) => host.playFilmPlaylist(snapshot, index),
    );
  }

  Future<void> continuePlaying(MediaLibraryRecord record) =>
      _play(record.item, resumeSessionId: record.playbackSessionId);

  Future<void> refreshPlaybackStatuses() async {
    await _restoreFuture;
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    for (final key in _keys.values.toList()) {
      await key.currentState?.refreshLibraryPlaybackStatuses();
      if (!mounted) return;
    }
  }

  Future<void> showPlaybackMenu(
    MediaLibraryRecord record,
    Offset position,
  ) async {
    if (_playbackMenuOpen) return;
    _playbackMenuOpen = true;
    try {
      await _withHost(
        record.item,
        (host) => host.showLibraryPlaybackMenu(record, position),
      );
    } finally {
      _playbackMenuOpen = false;
    }
  }

  Future<void> _withHost(
    MediaLibraryItem item,
    Future<void> Function(BrowserPageState) action,
  ) async {
    final app = context.read<AppState>();
    try {
      await app.restoreVideoCache();
      final cached = await app.cachedTarget(
        item.sourceId,
        item.discRootPath ?? item.targetPath,
      );
      final existing = _cacheSources[item.sourceId];
      if (existing is VideoCacheSource &&
          existing.identity != await app.videoCacheIdentity(item.sourceId)) {
        _cacheSources.remove(item.sourceId);
      }
      if (cached != null) {
        _cacheSources[item.sourceId] ??= await app.videoCacheSource(
          item.sourceId,
        );
        if (!mounted) return;
        _hostFor(item.sourceId);
        setState(() {});
        await WidgetsBinding.instance.endOfFrame;
        if (mounted) await action(_keys[item.sourceId]!.currentState!);
        return;
      }
      if ((item.sourceKind.isNativeStorage &&
              app.nativeSource(item.sourceId) == null) ||
          (item.sourceKind.isMediaServer &&
              app.serverSource(item.sourceId) == null)) {
        await app.mountMediaConnection(item.sourceId);
      }
      if (item.sourceKind == MediaSourceKind.webdav &&
          app.mountedService(item.sourceId) == null) {
        await app.mountProfile(item.sourceId);
      }
      if (!mounted) return;
      if (app.videoCache?.hasSource(item.sourceId) == true) {
        _cacheSources[item.sourceId] ??= await app.videoCacheSource(
          item.sourceId,
          original: app.directorySource(item.sourceId),
        );
      }
      final host = _hostFor(item.sourceId);
      if (host == null) throw AppException.config('来源不可用，请在文件夹中重新挂载');
      setState(() {});
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      await action(_keys[item.sourceId]!.currentState!);
    } on AppException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SPNotice(content: AppText(error.message)));
      }
    } on FilmCatalogException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SPNotice(content: AppText(filmCatalogErrorText(error.code))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    body: Column(
      children: [
        Expanded(
          child: StreamPathTransitionBackdropScope(
            hasBackdrop:
                AppBackgroundScope.maybeOf(context)?.hasBackground ??
                (_backgroundCatalog?.backgroundFile != null),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_backgroundCatalog case final catalog?
                    when catalog.backgroundFile != null)
                  FilmLibraryBackground(
                    cache: catalog.images,
                    file: catalog.backgroundFile,
                    onReady: _onBackgroundReady,
                  )
                else
                  const SizedBox.expand(),
                Navigator(
                  observers: [_heroes],
                  onGenerateRoute: (_) => MaterialPageRoute<void>(
                    builder: (_) => FilmLibraryPage(
                      sourceId: widget.sourceId,
                      onOpenItem: _play,
                      sidebarInset: widget.sidebarInset,
                      onContinueMenu: showPlaybackMenu,
                      onRefreshPlaybackStatus: refreshPlaybackStatuses,
                      onContinueSelected: (record) => _play(
                        record.item,
                        resumeSessionId: record.playbackSessionId,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Offstage(
          offstage: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: _hosts.values.toList(),
          ),
        ),
      ],
    ),
  );
}
