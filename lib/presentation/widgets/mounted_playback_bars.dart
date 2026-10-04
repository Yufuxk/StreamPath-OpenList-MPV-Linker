import '../../data/models/video_playlist_mode.dart';
import 'package:flutter/material.dart';
import 'sp_icons.dart';
import 'sp_dialog.dart';
import 'sp_notice.dart';
import 'package:provider/provider.dart';

import '../../core/errors/app_exception.dart';
import '../../data/models/audio_playback_history.dart';
import '../../data/models/media_library_config.dart';
import '../../data/models/media_library_item.dart';
import '../../data/models/media_source.dart';
import '../../data/models/playback_history.dart';
import '../../data/models/video_playback_scope.dart';
import '../../domain/services/player_process_controller.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../pages/browser_page.dart';
import '../state/app_state.dart';
import 'glass_dialog.dart';
import 'playback_bar.dart';
import 'continue_playback_subtitle.dart';

/// 挂载列表中展示对应来源的持久化续播会话。
class MountedPlaybackBars extends StatefulWidget {
  const MountedPlaybackBars({super.key, required this.network});

  final bool network;

  @override
  State<MountedPlaybackBars> createState() => _MountedPlaybackBarsState();
}

class _MountedPlaybackBarsState extends State<MountedPlaybackBars> {
  List<PlaybackHistory> _videos = const [];
  List<AudioPlaybackHistory> _audio = const [];
  List<MediaLibraryRecord> _localDiscs = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SPNotice(content: AppText(message)));
  }

  Future<void> _load() async {
    final appState = context.read<AppState>();
    final config = appState.configStore.current;
    final sourceIds = widget.network
        ? config.mountedProfileIds.toSet()
        : config.localRoots
              .where((root) => root.enabled)
              .map((root) => root.sourceId)
              .toSet();
    try {
      final video =
          (await appState.playbackHistoryStore.loadAll())
              .where((item) => sourceIds.contains(item.sourceId))
              .toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final audio =
          (await appState.audioPlaybackHistoryStore?.loadAll() ??
                  const <AudioPlaybackHistory>[])
              .where((item) => sourceIds.contains(item.sourceId))
              .toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      for (final history in video) {
        if (history.kind == PlaybackHistoryKind.iso ||
            (history.playerPid == null && history.ipcPipeName == null)) {
          continue;
        }
        await appState.playerService.restoreSession(
          sessionId: history.sessionId,
          profileId: history.sourceId,
          pid: history.playerPid,
          executablePath: history.playerExecutablePath,
          creationTime: history.playerCreationTime,
          ipcPipeName: history.ipcPipeName,
          launchEpoch: history.launchEpoch,
          currentSeasonPlaylistPath: history.seasonPlaylistPath,
          currentStageLength: history.playlistFileNames.length,
        );
      }
      final audioPlayer = appState.audioPlayerService;
      if (audioPlayer != null) {
        for (final history in audio) {
          if (history.playerPid == null && history.ipcPipeName == null) {
            continue;
          }
          await audioPlayer.restoreSession(
            sessionId: history.sessionId,
            profileId: history.sourceId,
            pid: history.playerPid,
            executablePath: history.playerExecutablePath,
            creationTime: history.playerCreationTime,
            ipcPipeName: history.ipcPipeName,
            launchEpoch: history.launchEpoch,
          );
        }
      }
      final discs = <MediaLibraryRecord>[];
      if (!widget.network && appState.mediaLibraryStore != null) {
        for (final id in sourceIds) {
          discs.addAll(
            await appState.mediaLibraryStore!.playbackHistory(
              id,
              audio: false,
              iso: true,
            ),
          );
        }
        discs.removeWhere(
          (item) => item.continueDismissed || item.playbackBarDismissed,
        );
        discs.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      }
      if (!mounted) return;
      setState(() {
        _videos = video;
        _audio = audio;
        _localDiscs = discs;
      });
    } on AppException catch (error) {
      _showError(error.message);
    }
  }

  String _sourceName(String? sourceId) {
    final config = context.read<AppState>().configStore.current;
    if (sourceId == null) return '';
    return config.profiles
            .where((item) => item.profileId == sourceId)
            .firstOrNull
            ?.name ??
        config.localRoots
            .where((item) => item.sourceId == sourceId)
            .firstOrNull
            ?.displayName ??
        sourceId;
  }

  String _directory(String? sourceId, List<String> crumbs) =>
      '${_sourceName(sourceId)} / ${crumbs.isEmpty ? context.l10n.text('根目录') : crumbs.join(' / ')}';

  Future<void> _openItem(
    MediaLibraryItem item, {
    String? sessionId,
    PlaybackHistory? videoHistory,
    bool openOnly = false,
    String? skipSeasonSessionId,
    int? videoIndex,
  }) async {
    final appState = context.read<AppState>();
    try {
      if (item.sourceKind == MediaSourceKind.webdav) {
        await appState.activateMountedProfile(item.sourceId);
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => BrowserPage(
              initialLibraryItem:
                  openOnly ||
                      videoIndex != null ||
                      videoHistory != null ||
                      skipSeasonSessionId != null
                  ? null
                  : item,
              initialVideoResumeHistory: openOnly ? null : videoHistory,
              resumeSessionId: openOnly ? null : sessionId,
              initialSkipSeasonSessionId: skipSeasonSessionId,
              initialVideoSelectIndex: videoIndex,
            ),
          ),
        );
      } else {
        final root = appState.localRoots
            .where((root) => root.sourceId == item.sourceId && root.enabled)
            .firstOrNull;
        if (root == null) throw AppException.config('本地媒体已移动、删除或来源不可用');
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => BrowserPage(
              localRoot: root,
              initialLibraryItem:
                  openOnly ||
                      videoIndex != null ||
                      videoHistory != null ||
                      skipSeasonSessionId != null
                  ? null
                  : item,
              initialVideoResumeHistory: openOnly ? null : videoHistory,
              resumeSessionId: openOnly ? null : sessionId,
              initialSkipSeasonSessionId: skipSeasonSessionId,
              initialVideoSelectIndex: videoIndex,
            ),
          ),
        );
      }
      if (mounted) await _load();
    } on AppException catch (error) {
      _showError(error.message);
    }
  }

  Future<void> _selectIndex(PlaybackHistory history, int index) async {
    final path = history.playlistRelativePaths[index],
        parent = history.playlistRelativePaths[index].split('/')..removeLast();
    await _openItem(
      MediaLibraryItem(
        sourceId: history.sourceId!,
        sourceKind: widget.network
            ? MediaSourceKind.webdav
            : MediaSourceKind.local,
        parentPath: parent.join('/'),
        name: history.playlistFileNames[index],
        kind: path.endsWith('.strm')
            ? MediaLibraryKind.strm
            : MediaLibraryKind.video,
      ),
      sessionId: history.sessionId,
      videoIndex: index,
    );
  }

  Future<void> _removeVideo(PlaybackHistory history) async {
    final appState = context.read<AppState>();
    final result = history.kind == PlaybackHistoryKind.iso
        ? history.playerPid == null
              ? PlayerTerminationOutcome.alreadyExited
              : appState.isoPlaybackService == null
              ? PlayerTerminationOutcome.refused
              : await appState.isoPlaybackService!.terminateSession(
                  history.isoSessionDirectoryPath,
                )
        : await appState.playerService.terminateSession(history.sessionId);
    if (!result.isSafeToRelaunch) {
      _showError('无法确认对应播放器进程，未删除播放会话');
      return;
    }
    await appState.playbackHistoryStore.remove(history.sessionId);
    await _load();
  }

  MediaLibraryItem _videoItem(PlaybackHistory history) => MediaLibraryItem(
    sourceId: history.sourceId!,
    sourceKind: widget.network ? MediaSourceKind.webdav : MediaSourceKind.local,
    parentPath: history.dirCrumbs.join('/'),
    name: history.fileName,
    kind: history.kind == PlaybackHistoryKind.iso
        ? MediaLibraryKind.iso
        : history.fileName.toLowerCase().endsWith('.strm')
        ? MediaLibraryKind.strm
        : MediaLibraryKind.video,
    playbackMode: history.playbackMode,
    playbackScope: history.playbackScope,
  );

  Future<void> _confirmSkipSeason(PlaybackHistory history) async {
    final accepted = await showGlassDialog<bool>(
      context: context,
      builder: (dialogContext) => SPDialog(
        title: const AppText('跳过本季？'),
        content: const AppText('确认后将跳过当前播放列表的所有剩余集数，直接播放下一季。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const AppText('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const AppText('确认跳过'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    await _openItem(
      _videoItem(history),
      skipSeasonSessionId: history.sessionId,
      openOnly: true,
    );
  }

  Future<void> _removeAudio(AudioPlaybackHistory history) async {
    final appState = context.read<AppState>();
    final result = appState.audioPlayerService == null
        ? history.playerPid == null
              ? PlayerTerminationOutcome.alreadyExited
              : PlayerTerminationOutcome.refused
        : await appState.audioPlayerService!.terminateSession(
            history.sessionId,
          );
    if (!result.isSafeToRelaunch) {
      _showError('无法确认音频播放器身份，已保留会话且未终止进程');
      return;
    }
    await appState.audioPlaybackHistoryStore?.remove(history.sessionId);
    await _load();
  }

  Future<void> _removeDisc(MediaLibraryRecord record) async {
    final appState = context.read<AppState>();
    final sessionId = record.playbackSessionId;
    if (sessionId != null) {
      final result = await appState.localDiscPlaybackService.terminateSession(
        sessionId,
      );
      if (!result.isSafeToRelaunch) {
        _showError('无法确认对应蓝光播放器进程，未删除播放会话');
        return;
      }
    }
    await appState.mediaLibraryStore?.dismissLocalDiscPlaybackBar(record);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final config = context.watch<AppState>().configStore.current;
    final mode = config.mediaLibrary.sharingMode;
    final enabled = widget.network
        ? mode == MediaLibrarySharingMode.networkShared ||
              mode == MediaLibrarySharingMode.networkAndLocalShared ||
              mode == MediaLibrarySharingMode.allShared
        : mode == MediaLibrarySharingMode.localShared ||
              mode == MediaLibrarySharingMode.networkAndLocalShared ||
              mode == MediaLibrarySharingMode.allShared;
    if (!enabled) return const SizedBox.shrink();
    final bars = <Widget>[
      for (final history in _audio)
        PlaybackBar(
          key: ValueKey('mounted-audio-${history.sessionId}'),
          title: '继续播放音频：${history.fileName}',
          dirLabel: _directory(history.sourceId, history.dirCrumbs),
          subtitle: ContinuePlaybackSubtitle.audio(
            label: _directory(history.sourceId, history.dirCrumbs),
            history: history,
          ),
          icon: SPIcons.play,
          tooltip: '继续播放',
          deleting: false,
          onPressed: () => _openItem(
            MediaLibraryItem(
              sourceId: history.sourceId!,
              sourceKind: widget.network
                  ? MediaSourceKind.webdav
                  : MediaSourceKind.local,
              parentPath: history.dirCrumbs.join('/'),
              name: history.fileName,
              kind: MediaLibraryKind.audio,
            ),
            sessionId: history.sessionId,
            openOnly: history.playerPid != null || history.ipcPipeName != null,
          ),
          onDelete: () => _removeAudio(history),
          onSecondaryTapDown: (_) {},
        ),
      for (final history in _videos)
        PlaybackBar(
          key: ValueKey('mounted-video-${history.sessionId}'),
          onPrevious:
              history.videoPlaylistMode == VideoPlaylistMode.implicit &&
                  history.videoIndex > 0
              ? () => _selectIndex(history, history.videoIndex - 1)
              : null,
          onNext:
              history.videoPlaylistMode == VideoPlaylistMode.implicit &&
                  history.videoIndex + 1 < history.playlistRelativePaths.length
              ? () => _selectIndex(history, history.videoIndex + 1)
              : null,
          onSkipSeason:
              history.kind == PlaybackHistoryKind.video &&
                  history.playbackScope == VideoPlaybackScope.directory &&
                  config.autoSeasonTransitionEnabled &&
                  ((history.playerPid == null && history.ipcPipeName == null) ||
                      (history.ipcPipeName != null &&
                          (history.seasonPlaylistPath != null ||
                              history.videoPlaylistMode ==
                                  VideoPlaylistMode.implicit)))
              ? () => _confirmSkipSeason(history)
              : null,
          title: history.kind == PlaybackHistoryKind.iso
              ? '继续播放 ISO：${history.fileName}'
              : '继续播放：${history.fileName}',
          dirLabel: _directory(history.sourceId, history.dirCrumbs),
          subtitle: ContinuePlaybackSubtitle.video(
            label: _directory(history.sourceId, history.dirCrumbs),
            history: history,
          ),
          icon: SPIcons.play,
          tooltip: '继续播放',
          deleting: false,
          onPressed: () => _openItem(
            _videoItem(history),
            sessionId: history.sessionId,
            openOnly:
                history.playerPid != null ||
                history.ipcPipeName != null ||
                history.isoSessionDirectoryPath != null,
            videoHistory:
                history.kind == PlaybackHistoryKind.video &&
                    history.playlistRelativePaths.isNotEmpty
                ? history
                : null,
          ),
          onDelete: () => _removeVideo(history),
          onSecondaryTapDown: (_) {},
        ),
      for (final record in _localDiscs)
        PlaybackBar(
          key: ValueKey('mounted-disc-${record.recordKey}'),
          title: '继续播放本地蓝光：${record.item.name}',
          dirLabel: _directory(record.item.sourceId, [
            record.item.normalizedParentPath,
          ]),
          subtitle: ContinuePlaybackSubtitle.disc(
            label: _directory(record.item.sourceId, [
              record.item.normalizedParentPath,
            ]),
            record: record,
          ),
          icon: SPIcons.play,
          tooltip: '继续播放',
          deleting: false,
          onPressed: () => _openItem(record.item),
          onDelete: () => _removeDisc(record),
          onSecondaryTapDown: (_) {},
        ),
    ];
    if (bars.isEmpty) return const SizedBox.shrink();
    final surface = PlaybackBarsSurface(children: bars);
    if (bars.length <= 4) return surface;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.4,
      ),
      child: SingleChildScrollView(child: surface),
    );
  }
}
