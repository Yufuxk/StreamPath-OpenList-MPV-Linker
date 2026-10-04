import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/errors/app_exception.dart';
import '../../data/models/media_library_item.dart';
import '../../data/models/media_source.dart';
import '../../data/models/playback_history.dart';
import '../localization/app_text.dart';
import '../state/app_state.dart';
import '../widgets/sp_notice.dart';
import 'browser_page.dart';
import 'film_library_page.dart';

/// 详情导航与播放会话共存，来源各自持有原有播放链路。
class FilmLibraryShell extends StatefulWidget {
  const FilmLibraryShell({super.key, this.sidebarInset = 0});
  final double sidebarInset;
  @override
  State<FilmLibraryShell> createState() => FilmLibraryShellState();
}

class FilmLibraryShellState extends State<FilmLibraryShell> {
  final _hosts = <String, BrowserPage>{};
  final _keys = <String, GlobalKey<BrowserPageState>>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
  }

  BrowserPage? _hostFor(String sourceId) {
    final app = context.read<AppState>();
    final local = sourceId.startsWith('local:');
    final root = local
        ? app.localRoots
              .where((r) => r.enabled && r.sourceId == sourceId)
              .firstOrNull
        : null;
    final service = local ? null : app.mountedService(sourceId);
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
      playbackOnly: true,
    );
  }

  Future<void> _restore() async {
    final app = context.read<AppState>();
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
    void restoreHosts() => setState(() {
      for (final source in sources) {
        _hostFor(source);
      }
    });
    restoreHosts();
    if (sources.any(
      (source) =>
          !source.startsWith('local:') &&
          app.configStore.current.mountedProfileIds.contains(source) &&
          app.mountedService(source) == null,
    )) {
      await app.restoreMountedProfiles();
      if (mounted) restoreHosts();
    }
  }

  Future<void> _play(MediaLibraryItem item, {String? resumeSessionId}) async {
    await context.read<AppState>().initializeFilmPlayback();
    await _withHost(
      item,
      (host) => host.playLibraryItem(item, resumeSessionId: resumeSessionId),
    );
  }

  Future<void> play(MediaLibraryItem item) => _play(item);
  Future<void> continuePlaying(MediaLibraryRecord record) =>
      _play(record.item, resumeSessionId: record.playbackSessionId);
  Future<void> showPlaybackMenu(MediaLibraryRecord record, Offset position) =>
      _withHost(
        record.item,
        (host) => host.showLibraryPlaybackMenu(record, position),
      );

  Future<void> _withHost(
    MediaLibraryItem item,
    Future<void> Function(BrowserPageState) action,
  ) async {
    final app = context.read<AppState>();
    try {
      if (item.sourceKind == MediaSourceKind.webdav &&
          app.mountedService(item.sourceId) == null) {
        await app.mountProfile(item.sourceId);
      }
      if (!mounted) return;
      final host = _hostFor(item.sourceId);
      if (host == null) throw AppException.config('来源不可用，请在文件夹管理中重新挂载');
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
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    body: Column(
      children: [
        Expanded(
          child: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => FilmLibraryPage(
                onOpenItem: _play,
                sidebarInset: widget.sidebarInset,
                onContinueMenu: (record, position) => _withHost(
                  record.item,
                  (host) => host.showLibraryPlaybackMenu(record, position),
                ),
                onContinueSelected: (record) => _play(
                  record.item,
                  resumeSessionId: record.playbackSessionId,
                ),
              ),
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
