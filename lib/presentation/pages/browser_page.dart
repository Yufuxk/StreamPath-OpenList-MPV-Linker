import '../widgets/video_version_dialog.dart';
import '../../data/models/video_queue.dart';
import '../../data/models/video_playlist_mode.dart';
import '../../data/models/film_catalog_item.dart';
import '../../domain/services/film_video_timeline.dart';
import '../../domain/services/video_entry_preparer.dart';
import '../../data/local/playback_history_store.dart';
import '../../data/models/webdav_bdmv.dart';
import '../../domain/services/webdav_bdmv_service.dart';
import 'dart:async';
import '../../domain/services/remote_menu_playback_service.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import '../widgets/sp_icons.dart';
import '../widgets/sp_dialog.dart';
import '../widgets/sp_notice.dart';

import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../theme/app_theme.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../core/constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/app_paths.dart';
import '../../core/utils/file_sort.dart';
import '../../core/utils/url_utils.dart';
import '../../data/local/playback_progress_db.dart';
import '../../data/local/media_library_store.dart';
import '../../data/models/audio_media_entry.dart';
import '../../data/models/audio_playback_history.dart';
import '../../data/models/media_library_item.dart';
import '../../data/models/local_root_config.dart';
import '../../data/models/media_directory_entry.dart';
import '../../data/models/media_source.dart';
import '../../data/models/playback_history.dart';
import '../../data/models/video_playback_scope.dart';
import '../../data/models/playback_progress.dart';
import '../../data/models/subtitle_item.dart';
import '../../data/models/web_dav_file.dart';
import '../../data/models/media_entry.dart';
import '../../domain/services/external_player_service.dart';
import '../../domain/services/external_audio_matcher.dart';
import '../../domain/services/audio_player_service.dart';
import '../../domain/services/iso_playback_service.dart';
import '../../domain/services/local_disc_playback_service.dart';
import '../../domain/services/local_media_source.dart';
import '../../domain/services/mpv_idle_completion_marker.dart';
import '../../domain/services/openlist_index_service.dart';
import '../../domain/services/openlist_api_client.dart';
import '../../domain/services/player_process_controller.dart';
import '../../domain/services/webdav_service.dart';
import '../../domain/services/webdav_media_source_adapter.dart';
import '../../domain/services/webdav_font_matcher.dart';
import '../../domain/services/webdav_font_localizer.dart';
import '../../domain/services/special_video_playlist_collector.dart';
import '../../domain/services/season_video_playlist_collector.dart';
import '../../domain/services/iso_subtitle_service.dart';
import '../widgets/iso_subtitle_dialog.dart';
import '../../domain/repositories/media_directory_source.dart';
import '../controllers/directory_browser_controller.dart';
import '../controllers/directory_scroll_state.dart';
import '../presenters/playback_session_presenter.dart';
import '../state/app_state.dart';
import '../widgets/clipboard_history_menu.dart';
import '../widgets/directory_breadcrumbs.dart';
import '../widgets/directory_file_list.dart';
import '../widgets/directory_file_grid.dart';
import '../widgets/file_tile.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/playback_bar.dart';
import '../widgets/continue_playback_subtitle.dart';

/// 文件浏览页：WebDAV 目录虚拟列表浏览 + 视频一键外部播放。
///
/// 特性：
///  - `ListView.builder` 虚拟列表，万级文件流畅滚动；
///  - 目录点击异步按需加载子目录（面包屑导航）；
///  - 首帧同步读 Hive 缓存秒开，后台自动刷新；
///  - 视频点击 → 字幕自动匹配 → 查询续播进度 → 调起外部播放器。
class BrowserPage extends StatefulWidget {
  const BrowserPage({
    super.key,
    this.localRoot,
    this.initialLibraryItem,
    this.resumeSessionId,
    this.initialVideoResumeHistory,
    this.initialSkipSeasonSessionId,
    this.initialVideoSelectIndex,
    this.initialDirectoryPath,
    this.initialRevealName,
    this.playbackOnly = false,
    this.webDavSource,
  });

  final LocalRootConfig? localRoot;
  final MediaLibraryItem? initialLibraryItem;
  final String? resumeSessionId;
  final PlaybackHistory? initialVideoResumeHistory;
  final String? initialSkipSeasonSessionId;
  final int? initialVideoSelectIndex;
  final String? initialDirectoryPath;
  final String? initialRevealName;
  final bool playbackOnly;
  final WebDAVService? webDavSource;

  @override
  BrowserPageState createState() => BrowserPageState();
}

class _LocalDiscContinueEntry {
  const _LocalDiscContinueEntry({
    required this.record,
    required this.running,
    required this.paused,
  });

  final MediaLibraryRecord record;
  final bool running;
  final bool? paused;
}

class _PreparedSeason {
  const _PreparedSeason({
    required this.rootPath,
    required this.items,
    required this.playback,
  });

  final String rootPath;
  final List<SpecialVideoItem> items;
  final SeasonPlaybackEntries playback;
}

class _LocalDiscLaunchSelection {
  const _LocalDiscLaunchSelection({required this.mode, this.resumeEdition});

  final LocalDiscLaunchMode mode;
  final int? resumeEdition;
  bool get resumesSavedTitle => resumeEdition != null;
}

class _IsoDialogResult {
  const _IsoDialogResult._({
    required this.launched,
    required this.cancelled,
    this.errorMessage,
    this.launchResult,
  });

  const _IsoDialogResult.launched(IsoPlaybackLaunchResult result)
    : this._(launched: true, cancelled: false, launchResult: result);

  const _IsoDialogResult.cancelled() : this._(launched: false, cancelled: true);

  const _IsoDialogResult.failed(String message)
    : this._(launched: false, cancelled: false, errorMessage: message);

  final bool launched;
  final bool cancelled;
  final String? errorMessage;
  final IsoPlaybackLaunchResult? launchResult;
}

class _IsoTitleSelectionDialog extends StatefulWidget {
  const _IsoTitleSelectionDialog({
    required this.request,
    this.menuUnavailableReason,
    this.subtitles,
  });

  final IsoTitleSelectionRequest request;
  final IsoSubtitleContext? subtitles;
  final String? menuUnavailableReason;

  @override
  State<_IsoTitleSelectionDialog> createState() =>
      _IsoTitleSelectionDialogState();
}

class _IsoTitleSelectionDialogState extends State<_IsoTitleSelectionDialog> {
  late final List<IsoDiscTitle> _titles = List.of(widget.request.titles);
  late final Set<String> _selected = Set.of(widget.request.selectedMplsIds);
  bool _showSubtitles = false;
  bool _subtitleSaving = false;

  void _move(int index, int offset) {
    final target = index + offset;
    if (target < 0 || target >= _titles.length) return;
    setState(() {
      final title = _titles.removeAt(index);
      _titles.insert(target, title);
    });
  }

  static String _duration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) => SPDialog(
    key: const Key('iso-title-selection-dialog'),
    title: AppText(_showSubtitles ? '蓝光外挂字幕' : '选择 Blu-ray 标题'),
    content: SizedBox(
      width: 680,
      height: 430,
      child: _showSubtitles
          ? IsoSubtitleDialog(
              subtitles: widget.subtitles!,
              titles: _titles
                  .map(
                    (title) => <String, dynamic>{
                      'id': title.mplsId,
                      'duration': title.duration.inMilliseconds / 1000,
                    },
                  )
                  .toList(),
              embedded: true,
              onSavingChanged: (saving) =>
                  setState(() => _subtitleSaving = saving),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.request.discName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                const AppText('选择要播放的 Title，并用箭头调整虚拟播放列表顺序。'),
                if (widget.menuUnavailableReason != null)
                  AppText(widget.menuUnavailableReason!),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.builder(
                    itemCount: _titles.length,
                    itemBuilder: (context, index) {
                      final title = _titles[index];
                      final resume =
                          widget.request.resumeByMplsId[title.mplsId];
                      final isLast = widget.request.lastMplsId == title.mplsId;
                      final details = <String>[
                        '${title.mplsId}.mpls',
                        _duration(title.duration),
                        if (resume != null)
                          context.l10n.format('上次播放 {position}', {
                            'position': _duration(resume.position),
                          }),
                        if (isLast) context.l10n.text('上次所在标题'),
                      ];
                      return CheckboxListTile(
                        key: Key('iso-title-${title.mplsId}'),
                        value: _selected.contains(title.mplsId),
                        onChanged: (selected) => setState(() {
                          if (selected == true) {
                            _selected.add(title.mplsId);
                          } else {
                            _selected.remove(title.mplsId);
                          }
                        }),
                        title: Text('Title ${title.titleIndex}'),
                        subtitle: Text(details.join(' · ')),
                        secondary: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              key: Key('iso-title-up-${title.mplsId}'),
                              tooltip: context.l10n.text('上移'),
                              onPressed: index == 0
                                  ? null
                                  : () => _move(index, -1),
                              icon: const Icon(SPIcons.up),
                            ),
                            IconButton(
                              key: Key('iso-title-down-${title.mplsId}'),
                              tooltip: context.l10n.text('下移'),
                              onPressed: index == _titles.length - 1
                                  ? null
                                  : () => _move(index, 1),
                              icon: const Icon(SPIcons.down),
                            ),
                          ],
                        ),
                        controlAffinity: ListTileControlAffinity.leading,
                      );
                    },
                  ),
                ),
              ],
            ),
    ),
    actions: [
      if (_showSubtitles)
        TextButton(
          onPressed: _subtitleSaving
              ? null
              : () => setState(() => _showSubtitles = false),
          child: const AppText('返回标题选择'),
        )
      else ...[
        if (widget.subtitles != null)
          TextButton(
            onPressed: () => setState(() => _showSubtitles = true),
            child: const AppText('蓝光外挂字幕'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const AppText('取消播放'),
        ),
        FilledButton(
          key: const Key('iso-title-play'),
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(
                  IsoTitleSelection(
                    orderedTitles: List<IsoDiscTitle>.unmodifiable(_titles),
                    selectedMplsIds: Set<String>.unmodifiable(_selected),
                  ),
                ),
          child: const AppText('播放所选标题'),
        ),
        if (widget.menuUnavailableReason != null)
          const OutlinedButton(onPressed: null, child: AppText('蓝光菜单播放')),
      ],
    ],
  );
}

class _IsoStreamingDialog extends StatefulWidget {
  const _IsoStreamingDialog({
    required this.service,
    required this.webDavService,
    required this.file,
    this.remoteMenu = false,
    this.menuUnavailableReason,
    this.subtitles,
    this.startupClock,
    this.startupTrace,
    this.precheckedMenuExecutable,
    this.cancelPreparation,
  });

  final IsoPlaybackService service;
  final WebDAVService webDavService;
  final WebDavFile file;
  final Future<IsoSubtitleContext?>? subtitles;
  final Stopwatch? startupClock;
  final DiscStartupTrace? startupTrace;
  final String? precheckedMenuExecutable;
  final VoidCallback? cancelPreparation;
  final bool remoteMenu;
  final String? menuUnavailableReason;

  @override
  State<_IsoStreamingDialog> createState() => _IsoStreamingDialogState();
}

class _IsoStreamingDialogState extends State<_IsoStreamingDialog> {
  late IsoPlaybackProgress _progress;
  bool _cancelling = false;
  IsoSubtitleContext? _subtitles;
  bool _preparingSubtitles = true;

  @override
  void initState() {
    super.initState();
    _progress = IsoPlaybackProgress(
      phase: IsoPlaybackPhase.checkingPlayer,
      fileName: widget.file.name,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    try {
      Future<IsoSubtitleContext?>? preparation;
      if (widget.file is WebDavBdmv) {
        preparation = widget.subtitles?.then((value) {
          _subtitles = value;
          return value;
        });
        // 提前注册错误处理，避免原生准备期间异步异常无人接收。
        preparation?.ignore();
      } else {
        _subtitles = await widget.subtitles;
      }
      if (!mounted) return;
      if (_cancelling) {
        Navigator.of(context).pop(const _IsoDialogResult.cancelled());
        return;
      }
      setState(() => _preparingSubtitles = false);
      final result = widget.remoteMenu
          ? await widget.service.startRemoteMenu(
              webDavService: widget.webDavService,
              file: widget.file,
              subtitles: _subtitles,
              subtitlePreparation: preparation,
              startupClock: widget.startupClock,
              startupTrace: widget.startupTrace,
              precheckedMenuExecutable: widget.precheckedMenuExecutable,
              onProgress: (progress) {
                if (mounted) setState(() => _progress = progress);
              },
            )
          : await widget.service.start(
              webDavService: widget.webDavService,
              file: widget.file,
              selectTitles: _selectTitles,
              subtitles: _subtitles,
              subtitlePreparation: preparation,
              startupClock: widget.startupClock,
              startupTrace: widget.startupTrace,
              onProgress: (progress) {
                if (mounted) setState(() => _progress = progress);
              },
            );
      if (!mounted) return;
      Navigator.of(context).pop(
        result == null
            ? const _IsoDialogResult.cancelled()
            : _IsoDialogResult.launched(result),
      );
    } on AppException catch (error) {
      if (!mounted) return;
      Navigator.of(context).pop(_IsoDialogResult.failed(error.message));
    } on FileSystemException {
      if (!mounted) return;
      Navigator.of(context).pop(const _IsoDialogResult.failed('ISO 会话文件读写失败'));
    }
  }

  Future<IsoTitleSelection?> _selectTitles(
    IsoTitleSelectionRequest request,
  ) async {
    if (!mounted) return null;
    final selection = await showGlassDialog<IsoTitleSelection>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _IsoTitleSelectionDialog(
        request: request,
        subtitles: _subtitles,
        menuUnavailableReason: widget.menuUnavailableReason,
      ),
    );
    return selection;
  }

  void _cancel() {
    if (_cancelling ||
        (!widget.remoteMenu && _progress.phase == IsoPlaybackPhase.launching)) {
      return;
    }
    setState(() => _cancelling = true);
    widget.cancelPreparation?.call();
    widget.service.cancel();
  }

  String _statusText() => _preparingSubtitles
      ? '正在准备外挂字幕…'
      : switch (_progress.phase) {
          IsoPlaybackPhase.checkingPlayer => '正在检查 MPV 播放器…',
          IsoPlaybackPhase.startingBridge => '正在启动 ISO Bridge…',
          IsoPlaybackPhase.probingStream => '正在探测 ISO 流式读取…',
          IsoPlaybackPhase.parsingTitles => '正在解析 Blu-ray Title/MPLS…',
          IsoPlaybackPhase.selectingTitles => '正在等待标题选择…',
          IsoPlaybackPhase.launching => '正在启动 ISO 播放器…',
          IsoPlaybackPhase.playing => 'ISO 播放器已启动',
        };

  @override
  Widget build(BuildContext context) {
    final canCancel =
        !_cancelling &&
        (widget.remoteMenu || _progress.phase != IsoPlaybackPhase.launching) &&
        _progress.phase != IsoPlaybackPhase.playing;
    return PopScope(
      canPop: false,
      child: SPDialog(
        key: const Key('iso-streaming-dialog'),
        title: AppText(
          widget.file is WebDavBdmv ? 'BDMV 远程播放系统' : 'ISO 远程播放系统',
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText(
                _progress.fileName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 16),
              AppText(_statusText()),
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
              AppText(
                widget.file is WebDavBdmv
                    ? '仅支持未加密 Blu-ray BDMV；播放期间请保持网络连接。'
                    : '仅支持未加密 Blu-ray ISO；播放期间请保持网络连接。',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const Key('iso-streaming-cancel'),
            onPressed: canCancel ? _cancel : null,
            child: AppText(_cancelling ? '正在取消…' : '取消'),
          ),
        ],
      ),
    );
  }
}

class _WebDavVideoPreparationDialog extends StatefulWidget {
  const _WebDavVideoPreparationDialog({
    required this.fileName,
    required this.run,
  });

  final String fileName;
  final Future<void> Function(
    void Function(String stage, WebDavFontLocalizationProgress? font) report,
  )
  run;

  @override
  State<_WebDavVideoPreparationDialog> createState() =>
      _WebDavVideoPreparationDialogState();
}

class _WebDavVideoPreparationDialogState
    extends State<_WebDavVideoPreparationDialog> {
  String _stage = '正在读取视频目录…';
  WebDavFontLocalizationProgress? _font;

  String _formatBytes(int bytes) => bytes < 1048576
      ? '${(bytes / 1024).toStringAsFixed(0)} KiB'
      : '${(bytes / 1048576).toStringAsFixed(1)} MiB';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await widget.run((stage, font) {
          if (mounted) {
            setState(() {
              _stage = stage;
              _font = font;
            });
          }
        });
      } finally {
        if (mounted) Navigator.of(context).pop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final font = _font;
    final fraction = font == null || font.fromCache || font.expectedBytes <= 0
        ? null
        : (font.receivedBytes / font.expectedBytes).clamp(0.0, 1.0);
    return PopScope(
      canPop: false,
      child: SPDialog(
        key: const Key('webdav-video-preparation-dialog'),
        title: const AppText('普通视频播放准备'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText(
                widget.fileName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 16),
              AppText(_stage),
              if (font != null) ...[
                const SizedBox(height: 8),
                AppText(
                  font.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  font.fromCache
                      ? '${font.completedFiles}/${font.totalFiles}'
                      : '${font.completedFiles}/${font.totalFiles} · '
                            '${_formatBytes(font.receivedBytes)}'
                            '${font.expectedBytes > 0 ? ' / ${_formatBytes(font.expectedBytes)}' : ''}',
                ),
              ],
              const SizedBox(height: 12),
              LinearProgressIndicator(value: fraction),
            ],
          ),
        ),
      ),
    );
  }
}

class BrowserPageState extends State<BrowserPage> {
  late final Future<void> _sessionsLoaded;

  /// 影视库复用现有起播与续播流程，不改变所在导航页面。
  Future<void> playLibraryItem(
    MediaLibraryItem item, {
    String? resumeSessionId,
  }) async {
    await _sessionsLoaded;
    if (!mounted) return;
    var session = resumeSessionId == null
        ? null
        : _playbackPresenter.videoSessionById(resumeSessionId);
    if (widget.playbackOnly && resumeSessionId == null) {
      session = _playbackSessions.where((candidate) {
        final history = candidate.history;
        if (history.sourceId != item.sourceId) return false;
        if (item.kind.isVideoLane &&
            history.kind == PlaybackHistoryKind.video) {
          return history.playlistRelativePaths.contains(item.targetPath) ||
              history.queueItems.any(
                (i) => i.versions.any((v) => v.path == item.targetPath),
              ) ||
              history.dirCrumbs.join('/') == item.normalizedParentPath;
        }
        return item.kind == MediaLibraryKind.iso &&
            history.kind == PlaybackHistoryKind.iso &&
            history.dirCrumbs.join('/') == item.normalizedParentPath &&
            history.fileName == item.name;
      }).firstOrNull;
      if (session != null && item.kind.isVideoLane) {
        if (session.launching || session.deleting || session.recovering) return;
        final history = session.history;
        final running = await _playerService.isPlayerRunning(history.sessionId);
        if (!mounted) return;
        if (running) {
          final index = history.videoPlaylistMode == VideoPlaylistMode.implicit
              ? history.queueItems.indexWhere(
                  (i) => i.versions.any((v) => v.path == item.targetPath),
                )
              : history.playlistRelativePaths.indexOf(item.targetPath);
          if (index == history.videoIndex &&
              history.playlistRelativePaths[index] == item.targetPath &&
              !_playerService.hasPendingVideo(history.sessionId)) {
            await _playerService.sendResume(history.sessionId);
            return;
          }
          try {
            if (index < 0 ||
                !await _playerService.selectPlaylistEntry(
                  history.sessionId,
                  index,
                  versionPath: item.targetPath,
                )) {
              _showLibraryError('无法切换播放集数，请关闭播放器后重试');
            }
          } on StateError {
            _showLibraryError('无法切换播放集数，请关闭播放器后重试');
          } on TimeoutException {
            _showLibraryError('无法切换播放集数，请关闭播放器后重试');
          }
          return;
        }
        await _playerService.waitForExitSync(history.sessionId);
        if (!mounted) return;
        final closedHistory = session.history;
        if (closedHistory.videoPlaylistMode == VideoPlaylistMode.implicit &&
            closedHistory.playlistRelativePaths[closedHistory.videoIndex] !=
                item.targetPath) {
          await _openLibraryItem(item);
          return;
        }
        _directoryBrowser.navigateToPath(closedHistory.dirCrumbs.join('/'));
        await _load(force: true);
        if (!mounted) return;
        await _playVideo(
          null,
          sessionId: closedHistory.sessionId,
          playlistRootPath: closedHistory.dirCrumbs.join('/'),
          resumeTargetPath: item.targetPath,
        );
        return;
      }
    }
    if (session != null) {
      await _resumePlaybackSession(session);
      return;
    }
    if (_isLocal &&
        item.kind == MediaLibraryKind.iso &&
        resumeSessionId != null &&
        await _localDiscPlaybackService.isPlayerRunning(resumeSessionId)) {
      await _localDiscPlaybackService.sendResume(resumeSessionId);
      return;
    }
    await _openLibraryItem(item, resumeSessionId: resumeSessionId);
  }

  Future<void> showLibraryPlaybackMenu(
    MediaLibraryRecord record,
    Offset position,
  ) async {
    await _sessionsLoaded;
    if (!mounted) return;
    final session = record.playbackSessionId == null
        ? null
        : _sessionById(record.playbackSessionId!);
    PlaybackBar? bar;
    _LocalDiscContinueEntry? discEntry;
    if (session != null) {
      bar = _buildPlaybackBar(session) as PlaybackBar;
    } else if (_isLocal &&
        record.item.kind == MediaLibraryKind.iso &&
        record.playbackSessionId != null) {
      final status = await _localDiscPlaybackService.sessionStatus(
        record.playbackSessionId!,
      );
      if (!mounted) return;
      discEntry = _LocalDiscContinueEntry(
        record: record,
        running: status.running,
        paused: status.paused,
      );
      bar = _buildLocalDiscPlaybackBar(discEntry) as PlaybackBar;
    }
    if (!mounted) return;
    final controls = bar;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      color: AppTheme.dropdownMenuColor(Theme.of(context)),
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        if (controls?.onPressed != null)
          PopupMenuItem(value: 'play', child: AppText(controls!.tooltip)),
        if (controls?.onSubtitles != null)
          const PopupMenuItem(value: 'subtitles', child: AppText('蓝光外挂字幕')),
        if (controls?.onSkipSeason != null)
          const PopupMenuItem(value: 'skip', child: AppText('跳过本季')),
        const PopupMenuItem(value: 'delete', child: AppText('删除并关闭播放器')),
      ],
    );
    if (!mounted) return;
    switch (selected) {
      case 'play':
        controls!.onPressed!();
      case 'subtitles':
        controls!.onSubtitles!();
      case 'skip':
        controls!.onSkipSeason!();
      case 'delete':
        bool removed;
        if (session != null) {
          removed = await _removePlaybackSession(
            session,
            terminateProcess: true,
          );
        } else if (discEntry != null) {
          removed = await _removeLocalDiscContinue(discEntry);
        } else if (record.item.kind.isVideoLane &&
            record.playbackSessionId != null) {
          final outcome = await _playerService.terminateSession(
            record.playbackSessionId!,
          );
          removed = outcome.isSafeToRelaunch;
          if (!removed) {
            _showLibraryError('无法确认视频播放器身份，已保留会话且未终止进程');
          }
        } else {
          // 已删除会话的遗留卡片仍可清除自己的记录。
          removed = true;
        }
        if (removed) {
          try {
            await _mediaLibraryStore?.removePlaybackRecord(record);
          } on FileSystemException catch (error) {
            _showLibraryError('删除最近播放失败：$error');
          } on AppException catch (error) {
            _showLibraryError('删除最近播放失败：$error');
          }
        }
    }
  }

  late final MediaDirectorySource _source;
  WebDAVService? _webDavSourceService;
  final Set<String> _seasonStageAttempts = {};
  final Map<String, Future<String?>> _seasonStageTasks = {};
  final Set<String> _seasonSkipInProgress = {};
  LocalMediaSource? _localSource;
  late final DirectoryBrowserController _directoryBrowser;
  late final PlaybackSessionPresenter _playbackPresenter;
  final TextEditingController _directorySearchController =
      TextEditingController();
  final FocusNode _directorySearchFocusNode = FocusNode();
  Set<String> _favoriteKeys = const {};

  late final DirectoryScrollState _directoryScroll;

  /// MPV 状态目录在应用生命周期内固定，只解析一次，避免播放监控每轮
  /// 重复执行路径探测和可写目录检查。
  late final Future<Directory?> _sessionCacheDirectory;

  /// 播放中动态保护警告的订阅（网络带宽持续不足等）。
  StreamSubscription<String>? _cacheWarningSub;
  StreamSubscription<PlaybackRecoveryEvent>? _playbackRecoverySub;
  IsoPlaybackService? _isoPlaybackService;
  late final LocalDiscPlaybackService _localDiscPlaybackService;
  MediaLibraryStore? _mediaLibraryStore;
  PlaybackHistoryStore get _historyStore => widget.playbackOnly
      ? context.read<AppState>().filmPlaybackHistoryStore
      : context.read<AppState>().playbackHistoryStore;
  ExternalPlayerService get _playerService => widget.playbackOnly
      ? context.read<AppState>().filmPlayerService
      : context.read<AppState>().playerService;
  PlaybackProgressService get _progressService => widget.playbackOnly
      ? context.read<AppState>().filmProgressService
      : context.read<AppState>().progressService;
  bool _hasLocalDisc = false;
  bool _preparingBdmv = false;
  bool _tileView = false;
  String? _revealedName;
  final Map<String, Future<int>> _folderSizes = {};
  Future<void> _folderSizeTail = Future<void>.value();
  int _localDiscProbeGeneration = 0;
  int _localDiscContinueGeneration = 0;
  Timer? _localDiscContinueDebounce;
  List<_LocalDiscContinueEntry> _localDiscContinue = const [];

  @override
  void dispose() {
    _cacheWarningSub?.cancel();
    _playbackRecoverySub?.cancel();
    _directoryBrowser
      ..removeListener(_handleDirectoryBrowserChanged)
      ..dispose();
    _playbackPresenter
      ..removeListener(_handlePlaybackPresenterChanged)
      ..dispose();
    _isoPlaybackService?.removeLibraryProgressListener(
      _handleIsoProgressChanged,
    );
    _localDiscProbeGeneration++;
    _localDiscContinueGeneration++;
    _localDiscContinueDebounce?.cancel();
    _mediaLibraryStore?.removeListener(_scheduleLocalDiscContinueRefresh);
    _localDiscPlaybackService.removeLibraryProgressListener(
      _scheduleLocalDiscContinueRefresh,
    );
    _directorySearchController.dispose();
    _directorySearchFocusNode.dispose();
    _directoryScroll.dispose();
    super.dispose();
  }

  WebDAVService get _service =>
      _webDavSourceService ?? context.read<AppState>().webDavService!;

  bool get _isLocal => widget.localRoot != null;
  String get _sourceId => _source.descriptor.sourceId;

  Set<String> get _visibleSourceIds {
    if (widget.playbackOnly) return {_sourceId};
    final config = context.read<AppState>().configStore.current;
    return {
          _sourceId,
          ...config.localRoots
              .where((root) => root.enabled)
              .map((root) => root.sourceId),
          ...config.profiles.map((profile) => profile.profileId),
        }
        .where(
          (id) => config.mediaLibrary.includesSource(
            _sourceId,
            id,
            mountedProfileIds: config.mountedProfileIds.toSet(),
          ),
        )
        .toSet();
  }

  LocalMediaSource? _localSourceFor(String sourceId) {
    if (sourceId == _sourceId && _localSource != null) return _localSource;
    final appState = context.read<AppState>();
    final root = appState.localRoots
        .where((root) => root.sourceId == sourceId && root.enabled)
        .firstOrNull;
    return root == null ? null : appState.localMediaSource(root);
  }

  List<String> get _crumbs => _directoryBrowser.crumbs;
  List<MediaDirectoryEntry> get _files => _directoryBrowser.files;
  String? get _error => _directoryBrowser.error;
  bool get _refreshing => _directoryBrowser.refreshing;
  FileSortMode get _sortMode => _directoryBrowser.sortMode;
  FileSortDirection get _sortDirection => _directoryBrowser.sortDirection;
  bool get _directorySearchOpen => _directoryBrowser.searchOpen;
  String get _directorySearchQuery => _directoryBrowser.searchQuery;
  DirectorySearchScope get _directorySearchScope =>
      _directoryBrowser.searchScope;
  String get _currentPath => _directoryBrowser.currentPath;
  List<MediaDirectoryEntry> get _visibleFiles => _directoryBrowser.visibleFiles;
  bool get _canSortBySize => _directoryBrowser.canSortBySize;
  List<PlaybackUiSession> get _playbackSessions =>
      _playbackPresenter.videoSessions;
  List<AudioPlaybackUiSession> get _audioPlaybackSessions =>
      _playbackPresenter.audioSessions;
  Timer? get _playMonitor => _playbackPresenter.videoMonitor;
  set _playMonitor(Timer? value) => _playbackPresenter.videoMonitor = value;
  Timer? get _audioPlayMonitor => _playbackPresenter.audioMonitor;
  set _audioPlayMonitor(Timer? value) =>
      _playbackPresenter.audioMonitor = value;

  /// 当前目录列表的内存状态键。
  String get _directoryScrollCacheKey =>
      'directory-scroll:${_tileView ? 'grid' : 'list'}:${_sortMode.jsonValue}:'
      '${_sortDirection.jsonValue}:$_currentPath:'
      '${_directorySearchOpen ? '${_directorySearchScope.name}:$_directorySearchQuery' : ''}';

  ValueKey<String> get _directoryScrollKey =>
      ValueKey<String>(_directoryScrollCacheKey);

  ScrollController get _directoryScrollController =>
      _directoryScroll.controller;

  void _rememberDirectoryScroll() {
    _directoryScroll.remember(_directoryScrollCacheKey);
  }

  void _scheduleDirectoryScrollRestore() {
    final key = _directoryScrollCacheKey;
    _directoryScroll.scheduleRestore(
      key: key,
      isCurrent: () => mounted && key == _directoryScrollCacheKey,
    );
  }

  void _changeDirectoryScrollScope(VoidCallback mutation) {
    _rememberDirectoryScroll();
    mutation();
    _scheduleDirectoryScrollRestore();
  }

  @override
  void initState() {
    super.initState();
    final appState = context.read<AppState>();
    _localDiscPlaybackService = widget.playbackOnly
        ? appState.filmLocalDiscPlaybackService
        : appState.localDiscPlaybackService;
    unawaited(_localDiscPlaybackService.cleanupSubtitleSessions());
    _mediaLibraryStore = widget.playbackOnly
        ? appState.filmMediaLibraryStore
        : appState.mediaLibraryStore;
    _isoPlaybackService = widget.playbackOnly
        ? appState.filmIsoPlaybackService
        : appState.isoPlaybackService;
    final localRoot = widget.localRoot;
    if (localRoot == null) {
      _webDavSourceService = widget.webDavSource ?? appState.webDavService!;
      _source = WebDavMediaSourceAdapter(_webDavSourceService!);
      _isoPlaybackService = widget.playbackOnly
          ? appState.filmIsoPlaybackService
          : appState.isoPlaybackService;
    } else {
      _localSource = appState.localMediaSource(localRoot);
      _source = _localSource!;
    }
    _mediaLibraryStore?.addListener(_scheduleLocalDiscContinueRefresh);
    _localDiscPlaybackService.addLibraryProgressListener(
      _scheduleLocalDiscContinueRefresh,
    );
    final expirationStore = appState.cacheExpirationConfigStore;
    _directoryScroll = DirectoryScrollState(
      maxEntries: AppConstants.maxDirectoryScrollEntries,
      idleTtl: AppConstants.directoryScrollRetention,
      idleTtlProvider: expirationStore == null
          ? null
          : () => expirationStore.current.directoryScrollRetention,
    );
    _directoryBrowser = DirectoryBrowserController(
      service: _source,
      configStore: appState.configStore,
      initialPath:
          widget.initialDirectoryPath ??
          appState.navigationLocations.pathFor(_sourceId),
      onDirectoryLoaded: widget.playbackOnly ? null : _recordRecentDirectory,
      onForcedRefresh: _isLocal
          ? null
          : _playerService.captureOpenListProcessIdentity,
      openListIndexSearch: _isLocal ? null : _searchNetworkIndex,
    )..addListener(_handleDirectoryBrowserChanged);
    _playbackPresenter = PlaybackSessionPresenter()
      ..addListener(_handlePlaybackPresenterChanged);
    _isoPlaybackService?.addLibraryProgressListener(_handleIsoProgressChanged);
    _sessionCacheDirectory = _resolveSessionCacheDirectory();
    _sessionsLoaded = Future.wait([
      _loadPlaybackSessions(),
      if (!widget.playbackOnly) _loadAudioPlaybackSessions(),
    ]);
    _initLoad(_sessionsLoaded);
    _refreshLocalDiscContinue();
    if (!widget.playbackOnly) {
      _loadFavoriteKeys();
      if (_isLocal) _refreshLocalDiscState();
    }
    // 播放中动态保护警告（如网络带宽不足）：SnackBar 展示。
    _cacheWarningSub = appState.cacheWarnings.listen((message) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SPNotice(content: AppText(message)));
    });
    _playbackRecoverySub = appState.playbackRecoveryEvents.listen(
      _handlePlaybackRecoveryEvent,
    );
  }

  void _handleDirectoryBrowserChanged() {
    if (!mounted) return;
    setState(() {});
  }

  Future<List<OpenListIndexEntry>> _searchNetworkIndex(String query) async {
    final app = context.read<AppState>();
    final profile = app.configStore.current.profiles
        .where((item) => item.profileId == _sourceId)
        .firstOrNull;
    if (profile == null) return const [];
    final capabilities = await app.getOpenListCapabilities(profile: profile);
    if (capabilities.indexSearch == OpenListCapabilitySupport.supported) {
      return app.searchOpenListIndexForProfile(profile, query);
    }
    final index = await app.getGlobalSearchIndex();
    if (await index.status(_sourceId) == null) {
      await index.indexSource(
        sourceId: _sourceId,
        list: (path) => _service.refreshDirectory(path),
      );
    }
    final results = await index.search(query, sourceId: _sourceId);
    return results
        .map(
          (result) => OpenListIndexEntry(
            name: result.name,
            parent: result.parentPath,
            isDirectory: result.isDirectory,
          ),
        )
        .toList();
  }

  void _handlePlaybackPresenterChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _handleIsoProgressChanged() {
    if (!mounted) return;
    _syncPlaybackSessions();
  }

  void _scheduleLocalDiscContinueRefresh() {
    if (!mounted) return;
    _localDiscContinueDebounce?.cancel();
    _localDiscContinueDebounce = Timer(const Duration(milliseconds: 120), () {
      unawaited(_refreshLocalDiscContinue());
    });
  }

  Future<void> _refreshLocalDiscContinue() async {
    final generation = ++_localDiscContinueGeneration;
    final store = _mediaLibraryStore;
    if (store == null) return;
    try {
      final history =
          (await Future.wait([
              for (final id in _visibleSourceIds.where(
                (id) => id.startsWith('local:'),
              ))
                store.playbackHistory(id, audio: false, iso: true),
            ])).expand((records) => records).toList()
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      final entries = <_LocalDiscContinueEntry>[];
      for (final record in history.where(
        (record) => !record.continueDismissed && !record.playbackBarDismissed,
      )) {
        final relativePath =
            record.localDiscSession?.relativePath ??
            (_isRootLocalDiscItem(record.item) ? '' : record.item.targetPath);
        try {
          final source = _localSourceFor(record.item.sourceId);
          if (source == null) continue;
          await source.resolveDiscDevice(relativePath);
          final sessionId = record.playbackSessionId;
          final status = sessionId == null
              ? const LocalDiscSessionStatus(running: false)
              : await _localDiscPlaybackService.sessionStatus(sessionId);
          entries.add(
            _LocalDiscContinueEntry(
              record: record,
              running: status.running,
              paused: status.paused,
            ),
          );
          if (entries.length >= store.config.normalized.maxContinuePerLane) {
            break;
          }
        } on AppException {
          // 已移动或失效的本地蓝光不显示为可续播项。
        }
      }
      if (!mounted || generation != _localDiscContinueGeneration) return;
      setState(() => _localDiscContinue = List.unmodifiable(entries));
    } catch (error) {
      if (!mounted || generation != _localDiscContinueGeneration) return;
      _showLibraryError('读取本地蓝光续播记录失败：$error');
    }
  }

  Future<void> _refreshLocalDiscState() async {
    if (!_isLocal) return;
    final generation = ++_localDiscProbeGeneration;
    final path = _currentPath;
    final hasDisc = await _localSource!.hasDiscAt(path);
    if (!mounted ||
        generation != _localDiscProbeGeneration ||
        path != _currentPath) {
      return;
    }
    if (_hasLocalDisc != hasDisc) setState(() => _hasLocalDisc = hasDisc);
  }

  void _handlePlaybackRecoveryEvent(PlaybackRecoveryEvent event) {
    if (!mounted) return;
    final session = _sessionById(event.sessionId);
    final appState = context.read<AppState>();
    if (session != null) {
      switch (event.stage) {
        case PlaybackRecoveryStage.preparing:
          setState(() {
            session
              ..recovering = true
              ..launching = false
              ..paused = null;
          });
          break;
        case PlaybackRecoveryStage.relaunched:
          final result = event.launchResult;
          if (result != null) {
            final now = DateTime.now();
            final timeoutSeconds = appState
                .configStore
                .current
                .playerStartupTimeoutSeconds
                .clamp(
                  AppConstants.minPlayerStartupTimeoutSeconds,
                  AppConstants.maxPlayerStartupTimeoutSeconds,
                )
                .toInt();
            final history = session.history.copyWith(
              playerPid: result.process.pid,
              playerExecutablePath: result.processIdentity?.executablePath,
              clearPlayerExecutablePath: result.processIdentity == null,
              playerCreationTime: result.processIdentity?.creationTime,
              clearPlayerCreationTime: result.processIdentity == null,
              ipcPipeName: result.ipcPipeName,
              updatedAt: now,
            );
            setState(() {
              session.statusNotBefore = now;
              session.activationGuard.start(
                now: now,
                timeout: Duration(seconds: timeoutSeconds),
              );
              session
                ..history = history
                ..recovering = false
                ..launching = false
                ..paused = null
                ..finishPending = 0
                ..lastReportedPositionSeconds = null
                ..lastReportedDurationSeconds = null;
            });
            unawaited(_historyStore.upsert(history));
            _refreshPlaybackMonitor();
          }
          break;
        case PlaybackRecoveryStage.failed:
          setState(() {
            session
              ..recovering = false
              ..launching = false
              ..paused = null;
          });
          break;
      }
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SPNotice(content: AppText(event.message)));
  }

  void _resetDirectorySearch() {
    _directoryBrowser.closeSearch();
    _directorySearchController.clear();
    _directorySearchFocusNode.unfocus();
  }

  void _openDirectorySearch() {
    _changeDirectoryScrollScope(_directoryBrowser.openSearch);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _directorySearchOpen) {
        _directorySearchFocusNode.requestFocus();
      }
    });
  }

  void _closeDirectorySearch() {
    _changeDirectoryScrollScope(_resetDirectorySearch);
  }

  void _onDirectorySearchChanged(String query) {
    if (query == _directorySearchQuery) return;
    _changeDirectoryScrollScope(
      () => _directoryBrowser.updateSearchQuery(query),
    );
  }

  Future<void> _loadFavoriteKeys() async {
    final store = _mediaLibraryStore;
    final sourceId = _sourceId;
    if (store == null) return;
    try {
      final favorites = await store.favorites(sourceId);
      if (!mounted || sourceId != _sourceId) return;
      setState(() {
        _favoriteKeys = favorites
            .map((record) => record.item.stableKey)
            .toSet();
      });
    } catch (_) {
      // 个人资产读取失败不阻止目录浏览和播放。
    }
  }

  MediaLibraryItem? _libraryItemForFile(
    MediaDirectoryEntry file, {
    String? parentPath,
    PlaybackMode? playbackMode,
    VideoPlaybackScope playbackScope = VideoPlaybackScope.directory,
  }) {
    final kind = file is WebDavBdmv
        ? MediaLibraryKind.iso
        : MediaLibraryKindX.fromEntry(file);
    if (kind == null) return null;
    return MediaLibraryItem(
      sourceId: _sourceId,
      sourceKind: _source.descriptor.kind,
      playbackMode:
          playbackMode ??
          (_isLocal ? PlaybackMode.localFile : PlaybackMode.legacyTitle),
      parentPath: parentPath ?? _currentPath,
      name: file.name,
      kind: kind,
      discRootPath: file is WebDavBdmv ? file.rootPath : null,
      playbackScope: playbackScope,
    );
  }

  Future<void> _toggleFavorite(MediaDirectoryEntry file) async {
    final item = _libraryItemForFile(file);
    final store = _mediaLibraryStore;
    if (item == null || store == null) return;
    try {
      final added = await store.toggleFavorite(item);
      if (!mounted) return;
      setState(() {
        final keys = Set<String>.of(_favoriteKeys);
        if (added) {
          keys.add(item.stableKey);
        } else {
          keys.remove(item.stableKey);
        }
        _favoriteKeys = keys;
      });
    } catch (error) {
      _showLibraryError('保存收藏失败：$error');
    }
  }

  Future<void> _recordRecentDirectory(String path) async {
    final normalized = normalizeLibraryPath(path);
    final appState = context.read<AppState>();
    final store = _mediaLibraryStore;
    try {
      await appState.navigationLocations.remember(
        sourceId: _sourceId,
        kind: _isLocal ? 'local' : 'network',
        path: normalized,
      );
    } on FileSystemException catch (error) {
      _showLibraryError('保存浏览位置失败：$error');
    }
    if (normalized.isEmpty) return;
    if (store == null) return;
    final segments = normalized.split('/');
    final item = MediaLibraryItem(
      sourceId: _sourceId,
      sourceKind: _source.descriptor.kind,
      playbackMode: _isLocal
          ? PlaybackMode.localFile
          : PlaybackMode.legacyTitle,
      parentPath: segments.length == 1
          ? ''
          : segments.sublist(0, segments.length - 1).join('/'),
      name: segments.last,
      kind: MediaLibraryKind.directory,
    );
    try {
      await store.recordRecentDirectory(item);
    } catch (error) {
      _showLibraryError('保存最近目录失败：$error');
    }
  }

  Future<void> _recordPlaybackFile(
    MediaDirectoryEntry file, {
    required String parentPath,
    required String playbackSessionId,
    PlaybackMode? playbackMode,
  }) async {
    final item = _libraryItemForFile(
      file,
      parentPath: parentPath,
      playbackMode: playbackMode,
      playbackScope:
          _sessionById(playbackSessionId)?.history.playbackScope ??
          VideoPlaybackScope.directory,
    );
    final appState = context.read<AppState>();
    final store = _mediaLibraryStore;
    if (item == null || store == null || !item.kind.isMedia) return;
    try {
      final video = _sessionById(playbackSessionId);
      final audio = _audioSessionById(playbackSessionId);
      await store.recordPlayback(
        item,
        playbackSessionId: playbackSessionId,
        playlistIndex: audio?.history.trackIndex ?? video?.history.videoIndex,
        playlistCount:
            audio?.playlistFileNames.length ?? video?.playlistFileNames.length,
      );
      if (!_isLocal && item.kind.isVideoLane) {
        appState.scheduleWebDavFontCachePrune();
      }
    } catch (error) {
      _showLibraryError('保存最近播放失败：$error');
    }
  }

  Future<void> _recordPlaybackByName({
    required List<String> dirCrumbs,
    required String fileName,
    required bool audio,
    required String playbackSessionId,
    String? playbackSourceId,
  }) async {
    final appState = context.read<AppState>();
    final store = _mediaLibraryStore;
    final sourceId = playbackSourceId ?? _sourceId;
    if (store == null) return;
    final parentPath = normalizeLibraryPath(dirCrumbs.join('/'));
    MediaDirectoryEntry? matched;
    if (sourceId == _sourceId &&
        normalizeLibraryPath(_currentPath) == parentPath) {
      matched = _files
          .where((file) => file.name == fileName && !file.isDirectory)
          .firstOrNull;
    }
    if (matched == null && !sourceId.startsWith('local:')) {
      for (final snapshot in appState.directoryCache.visitedDirectories(
        sourceId,
      )) {
        if (normalizeLibraryPath(snapshot.path) != parentPath) continue;
        matched = snapshot.entries
            .where((file) => file.name == fileName && !file.isDirectory)
            .firstOrNull;
        break;
      }
    }
    final kind = matched == null
        ? (audio
              ? MediaLibraryKind.audio
              : fileName.toLowerCase().endsWith('.strm')
              ? MediaLibraryKind.strm
              : MediaLibraryKind.video)
        : MediaLibraryKindX.fromEntry(matched);
    if (kind == null || !kind.isMedia) return;
    final item = MediaLibraryItem(
      sourceId: sourceId,
      sourceKind: sourceId.startsWith('local:')
          ? MediaSourceKind.local
          : MediaSourceKind.webdav,
      playbackMode: sourceId.startsWith('local:')
          ? PlaybackMode.localFile
          : PlaybackMode.legacyTitle,
      parentPath: parentPath,
      name: fileName,
      kind: kind,
      playbackScope:
          _sessionById(playbackSessionId)?.history.playbackScope ??
          VideoPlaybackScope.directory,
    );
    try {
      final video = _sessionById(playbackSessionId);
      final audioSession = _audioSessionById(playbackSessionId);
      await store.recordPlayback(
        item,
        playbackSessionId: playbackSessionId,
        playlistIndex:
            audioSession?.history.trackIndex ?? video?.history.videoIndex,
        playlistCount:
            audioSession?.playlistFileNames.length ??
            video?.playlistFileNames.length,
      );
      if (kind.isVideoLane && !sourceId.startsWith('local:')) {
        appState.scheduleWebDavFontCachePrune();
      }
    } catch (error) {
      _showLibraryError('保存最近播放失败：$error');
    }
  }

  void _showLibraryError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SPNotice(content: AppText(message)));
  }

  Future<Directory?> _resolveSessionCacheDirectory() async {
    try {
      return await AppPaths.cacheDirectory();
    } catch (_) {
      return null;
    }
  }

  bool get _needsPlaybackMonitor => _playbackSessions.any(
    (session) =>
        !session.deleting &&
        (session.history.playerPid != null ||
            session.history.ipcPipeName != null ||
            session.activationGuard.isWaiting),
  );

  /// 仅在确实有播放器进程需要跟踪时启用 700ms 监控。
  ///
  /// 纯“继续播放”历史没有活动 PID/IPC，不需要常驻计时器；恢复播放成功
  /// 后会重新启动监控，不改变暂停、切集、完成判定和启动保护行为。
  void _refreshPlaybackMonitor() {
    if (!mounted) return;
    if (!_needsPlaybackMonitor) {
      _playMonitor?.cancel();
      _playMonitor = null;
      return;
    }
    if (_playMonitor != null) return;
    _playMonitor = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (!_needsPlaybackMonitor) {
        _refreshPlaybackMonitor();
        return;
      }
      _syncPlaybackSessions();
    });
    _syncPlaybackSessions();
  }

  /// 载入持久化播放会话并恢复各自 PID/IPC 追踪。
  Future<void> _loadPlaybackSessions() async {
    final histories = (await _historyStore.loadAll())
        .where(
          (history) =>
              _visibleSourceIds.contains(history.sourceId) ||
              (!_isLocal && history.sourceId == null),
        )
        .toList();
    if (!mounted) return;
    _playbackPresenter.replaceVideoSessions(histories);
    for (final history in histories) {
      if (history.kind == PlaybackHistoryKind.iso) continue;
      await _playerService.restoreSession(
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
      if (history.sourceId == _sourceId && history.queueItems.isNotEmpty) {
        await _restoreImplicitControl(history);
      }
    }
    _refreshPlaybackMonitor();
    _syncPlaybackSessions();
  }

  Future<void> _restoreImplicitControl(PlaybackHistory history) async {
    final source = _source, id = history.sessionId;
    final player = _playerService,
        histories = _historyStore,
        records = _mediaLibraryStore;
    final app = context.read<AppState>(),
        navigator = Navigator.of(context, rootNavigator: true);
    final service = _isLocal ? null : _service;
    final store = await app.getFilmCatalogStore();
    final items = history.queueItems;
    final titles = app.configStore.current.videoPlaylistSimpleNaming
        ? await store.videoPlaylistTitles(
            history.sourceId!,
            items.expand((i) => i.versions.map((v) => v.path)).toList(),
          )
        : <String, String>{};
    final preparer = VideoEntryPreparer(
      source: source,
      config: app.configStore.current.toPlayerConfig(),
      subtitleMatcher: app.subtitleMatcher,
      fontMatcher: app.webDavFontMatcher,
      titles: titles,
    );
    await preparer.prepareSharedFonts(
      history.videoQueueRootPath ?? history.dirCrumbs.join('/'),
    );
    Future<void> target(
      int index,
      VideoQueueVersion version, {
      bool loaded = false,
    }) async {
      final current = (await histories.loadAll())
          .where((h) => h.sessionId == id)
          .firstOrNull;
      if (current == null) return;
      final paths = List<String>.of(current.playlistRelativePaths),
          names = List<String>.of(current.playlistFileNames);
      paths[index] = version.path;
      names[index] = version.name;
      final parent = p.posix.dirname(version.path);
      if (!loaded) {
        await histories.upsert(current.copyWith(pendingVideoIndex: index));
        return;
      }
      final updated = current.copyWith(
        clearPendingVideoIndex: true,
        videoIndex: index,
        fileName: version.name,
        playlistRelativePaths: paths,
        playlistFileNames: names,
        dirCrumbs: parent == '.' ? [] : parent.split('/'),
        updatedAt: DateTime.now(),
      );
      await histories.upsert(updated);
      if (loaded) {
        await records?.recordPlayback(
          MediaLibraryItem(
            sourceId: history.sourceId!,
            sourceKind: source.descriptor.kind,
            parentPath: parent == '.' ? '' : parent,
            name: version.name,
            kind: version.name.endsWith('.strm')
                ? MediaLibraryKind.strm
                : MediaLibraryKind.video,
          ),
          playbackSessionId: id,
          playlistIndex: index,
          playlistCount: items.length,
        );
      }
      if (mounted) {
        final session = _sessionById(id);
        if (session != null) setState(() => session.history = updated);
      }
    }

    final plan = ImplicitVideoPlan(
      items: items,
      index: history.videoIndex,
      prepare: preparer.prepare,
      chooseVersion: (item) async {
        if (!navigator.mounted) return null;
        return showVideoVersionDialog(navigator.context, item);
      },
      activated: (i, v) => target(i, v, loaded: true),
      pending: (i) => target(i, items[i].versions.first),
      failed: (message) {
        if (navigator.mounted) {
          ScaffoldMessenger.of(
            navigator.context,
          ).showSnackBar(SPNotice(content: AppText(message)));
        }
      },
    );
    for (var i = 0; i < items.length; i++) {
      final path = history.playlistRelativePaths[i];
      final version = items[i].versions
          .where((v) => v.path == path)
          .firstOrNull;
      if (version != null &&
          (i <= history.videoIndex || items[i].versions.length == 1)) {
        plan.selected[i] = version;
      }
    }
    await player.attachImplicitPlan(
      id,
      plan,
      serverUrl: service?.baseUrl,
      username: service?.credentialSnapshot.username,
      password: service?.credentialSnapshot.password,
      fontLoader: service?.fetchFileBytes,
      fontFileLoader: service?.downloadFile,
    );
  }

  PlaybackUiSession? _sessionById(String sessionId) =>
      _playbackPresenter.videoSessionById(sessionId);

  String _newSessionId() => _playbackPresenter.newVideoSessionId();

  String _newAudioSessionId() => _playbackPresenter.newAudioSessionId();

  bool get _needsAudioPlaybackMonitor => _audioPlaybackSessions.any(
    (session) =>
        !session.deleting &&
        (session.history.playerPid != null ||
            session.history.ipcPipeName != null ||
            session.activationGuard.isWaiting),
  );

  void _refreshAudioPlaybackMonitor() {
    if (!mounted) return;
    if (!_needsAudioPlaybackMonitor) {
      _audioPlayMonitor?.cancel();
      _audioPlayMonitor = null;
      return;
    }
    if (_audioPlayMonitor != null) return;
    _audioPlayMonitor = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (!_needsAudioPlaybackMonitor) {
        _refreshAudioPlaybackMonitor();
        return;
      }
      _syncAudioPlaybackSessions();
    });
    _syncAudioPlaybackSessions();
  }

  Future<void> _loadAudioPlaybackSessions() async {
    final appState = context.read<AppState>();
    final store = appState.audioPlaybackHistoryStore;
    final player = appState.audioPlayerService;
    if (store == null || player == null) return;
    final histories = (await store.loadAll())
        .where(
          (history) =>
              _visibleSourceIds.contains(history.sourceId) ||
              (!_isLocal && history.sourceId == null),
        )
        .toList();
    if (!mounted) return;
    _playbackPresenter.replaceAudioSessions(histories);
    for (final history in histories) {
      await player.restoreSession(
        sessionId: history.sessionId,
        profileId: history.sourceId,
        pid: history.playerPid,
        executablePath: history.playerExecutablePath,
        creationTime: history.playerCreationTime,
        ipcPipeName: history.ipcPipeName,
        launchEpoch: history.launchEpoch,
      );
    }
    _refreshAudioPlaybackMonitor();
  }

  AudioPlaybackUiSession? _audioSessionById(String sessionId) =>
      _playbackPresenter.audioSessionById(sessionId);

  /// 首帧加载：先同步读缓存秒开，再走网络/缓存编排。
  Future<void> _initLoad(Future<void> sessionsLoaded) async {
    if (!widget.playbackOnly) await _directoryBrowser.initialize();
    if (mounted && widget.initialRevealName != null && _error == null) {
      final found = _files.any(
        (file) => !file.isSelfEntry && file.name == widget.initialRevealName,
      );
      if (found) {
        setState(() => _revealedName = widget.initialRevealName);
      } else {
        _showLibraryError('搜索条目已失效，请刷新索引后重试');
      }
    }
    if (_isLocal && !widget.playbackOnly) await _refreshLocalDiscState();
    if (mounted) _scheduleDirectoryScrollRestore();
    if (mounted && _revealedName != null) _scrollToRevealed();
    if (mounted &&
        widget.initialVideoSelectIndex != null &&
        widget.resumeSessionId != null) {
      await sessionsLoaded;
      if (!mounted) return;
      final session = _sessionById(widget.resumeSessionId!);
      if (session != null) {
        await _selectVideoIndex(session, widget.initialVideoSelectIndex!);
      }
    } else if (mounted && widget.initialSkipSeasonSessionId != null) {
      await sessionsLoaded;
      if (!mounted) return;
      final session = _sessionById(widget.initialSkipSeasonSessionId!);
      if (session != null) {
        await _skipSeason(session, confirmed: true);
      }
    } else if (mounted && widget.initialVideoResumeHistory != null) {
      await sessionsLoaded;
      if (!mounted) return;
      await _resumePlaylistHistory(widget.initialVideoResumeHistory!);
    } else if (mounted && widget.initialLibraryItem != null) {
      await sessionsLoaded;
      if (!mounted) return;
      await _openLibraryItem(
        widget.initialLibraryItem!,
        resumeSessionId: widget.resumeSessionId,
      );
    }
  }

  /// 加载当前目录（[force] 为 true 时强制刷新网络）。
  Future<void> _load({bool force = false}) async {
    if (force) _folderSizes.clear();
    await _directoryBrowser.load(force: force);
    if (_isLocal && !widget.playbackOnly) await _refreshLocalDiscState();
    if (mounted) _scheduleDirectoryScrollRestore();
  }

  void _scrollToRevealed() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_directoryScrollController.hasClients) return;
      final index = _visibleFiles.indexWhere(
        (file) => !file.isSelfEntry && file.name == _revealedName,
      );
      if (index < 0) return;
      final width = MediaQuery.sizeOf(context).width;
      final columns = ((width - 260) / 250).floor().clamp(1, 20);
      final offset = _tileView
          ? (index ~/ columns) * 120.0
          : index * (width < 680 ? 72.0 : 56.0);
      _directoryScrollController.jumpTo(
        offset.clamp(0.0, _directoryScrollController.position.maxScrollExtent),
      );
    });
  }

  Future<int>? _folderSizeFor(MediaDirectoryEntry entry) {
    if (!_isLocal || !entry.isDirectory || entry.isSelfEntry) return null;
    return _folderSizes.putIfAbsent(entry.relativePath, () {
      final task = _folderSizeTail.then((_) async {
        final path = await _localSource!.resolveRelativePath(
          entry.relativePath,
          expectDirectory: true,
        );
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
      });
      _folderSizeTail = task.then<void>((_) {}).catchError((Object _) {});
      return task;
    });
  }

  // ── 目录导航 ─────────────────────────────────────────────────

  void _enterDirectory(MediaDirectoryEntry dir) {
    _changeDirectoryScrollScope(() {
      _directorySearchController.clear();
      _directorySearchFocusNode.unfocus();
      _directoryBrowser.enterDirectory(dir);
    });
    unawaited(_load());
  }

  void _backTo(int index) {
    // index 为面包屑位置；切到该层（含其子层移除）。
    _changeDirectoryScrollScope(() {
      _directorySearchController.clear();
      _directorySearchFocusNode.unfocus();
      _directoryBrowser.backTo(index);
    });
    unawaited(_load());
  }

  // ── Blu-ray ISO 远程流式播放入口 ────────────────────────────

  bool _isRootLocalDiscItem(MediaLibraryItem item) {
    final root = widget.localRoot;
    return root != null &&
        item.kind == MediaLibraryKind.iso &&
        item.normalizedParentPath.isEmpty &&
        item.name == root.displayName;
  }

  Future<MediaLibraryRecord?> _findLocalDiscContinueRecord(
    MediaLibraryItem item,
  ) async {
    final store = _mediaLibraryStore;
    if (store == null) return null;
    final history = await store.playbackHistory(
      _sourceId,
      audio: false,
      iso: true,
    );
    return history
        .where(
          (record) =>
              !record.continueDismissed &&
              record.item.stableKey == item.stableKey,
        )
        .firstOrNull;
  }

  Future<void> _recordLocalDiscPlayback(
    MediaLibraryItem item,
    String sessionId,
    LocalDiscSessionSnapshot snapshot,
  ) async {
    final store = _mediaLibraryStore;
    if (store == null) return;
    try {
      await store.recordPlayback(
        item,
        playbackSessionId: sessionId,
        localDiscSession: snapshot,
      );
    } catch (error) {
      _showLibraryError('保存最近播放失败：$error');
    }
  }

  Future<void> _playLocalDisc({
    required String relativePath,
    required String displayName,
    MediaLibraryRecord? continueRecord,
  }) => context.read<AppState>().withMediaPlaybackPriority(
    () => _playLocalDiscPrepared(
      relativePath: relativePath,
      displayName: displayName,
      continueRecord: continueRecord,
    ),
  );

  Future<void> _playLocalDiscPrepared({
    required String relativePath,
    required String displayName,
    MediaLibraryRecord? continueRecord,
  }) async {
    final root = widget.localRoot!;
    late final String devicePath;
    try {
      devicePath = await _localSource!.resolveDiscDevice(relativePath);
      final snapshot = continueRecord?.localDiscSession;
      if (snapshot != null &&
          !await LocalDiscPlaybackService.matchesSnapshot(
            snapshot: snapshot,
            devicePath: devicePath,
          )) {
        continueRecord = null;
        _showLibraryError('本地蓝光内容已变更，已忽略旧续播位置');
      }
    } on AppException catch (error) {
      _showLibraryError(error.message);
      return;
    }
    if (!mounted) return;
    final resumeSnapshot = continueRecord?.localDiscSession;
    final resumeEdition = resumeSnapshot?.currentEdition;
    final selection = await showDialog<_LocalDiscLaunchSelection>(
      context: context,
      builder: (dialogContext) => SPDialog(
        title: AppText(displayName),
        content: AppText(
          resumeEdition == null
              ? '请选择本地 Blu-ray 的播放方式。菜单失败时不会自动切换模式。'
              : '可继续上次播放的 Title，也可以从头打开菜单或主标题。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const AppText('取消'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.of(dialogContext).pop(
              const _LocalDiscLaunchSelection(
                mode: LocalDiscLaunchMode.longestTitle,
              ),
            ),
            child: const AppText('主标题模式'),
          ),
          if (resumeEdition != null)
            OutlinedButton(
              onPressed: () => Navigator.of(dialogContext).pop(
                const _LocalDiscLaunchSelection(mode: LocalDiscLaunchMode.menu),
              ),
              child: const AppText('从头打开菜单'),
            ),
          OutlinedButton(
            onPressed: () => Navigator.of(dialogContext).pop(
              _LocalDiscLaunchSelection(
                mode: LocalDiscLaunchMode.menu,
                resumeEdition: resumeEdition,
              ),
            ),
            child: AppText(resumeEdition == null ? '蓝光菜单播放' : '继续上次标题'),
          ),
        ],
      ),
    );
    if (!mounted || selection == null) return;
    try {
      final discRelativePath = _localSource!.discRelativePath(devicePath);
      final subtitles = await _isoSubtitlesForPath(_source, discRelativePath);
      if (!mounted) return;
      final result = await _localDiscPlaybackService.launch(
        rootId: root.rootId,
        relativePath: discRelativePath,
        devicePath: devicePath,
        mode: selection.mode,
        subtitles: subtitles,
        resumeFromSavedPosition: selection.resumesSavedTitle,
        resumeEdition: selection.resumeEdition,
        expectedFingerprint: selection.resumesSavedTitle
            ? resumeSnapshot?.fingerprint
            : null,
      );
      final normalized = normalizeLibraryPath(discRelativePath);
      final segments = normalized.isEmpty
          ? const <String>[]
          : normalized.split('/');
      final item = MediaLibraryItem(
        sourceId: _sourceId,
        sourceKind: MediaSourceKind.local,
        playbackMode: PlaybackMode.localHdmvMenu,
        parentPath: segments.length <= 1
            ? ''
            : segments.sublist(0, segments.length - 1).join('/'),
        name: segments.isEmpty ? root.displayName : segments.last,
        kind: MediaLibraryKind.iso,
      );
      await _recordLocalDiscPlayback(
        item,
        result.sessionId,
        LocalDiscSessionSnapshot(
          rootId: result.rootId,
          relativePath: result.relativePath,
          size: result.size,
          modified: result.modified,
          fingerprint: result.fingerprint,
          playerPid: result.processIdentity?.pid,
          playerExecutablePath: result.processIdentity?.executablePath,
          playerCreationTime: result.processIdentity?.creationTime,
          currentEdition: selection.resumeEdition,
          editionCount: selection.resumesSavedTitle
              ? resumeSnapshot?.editionCount
              : null,
        ),
      );
      if (continueRecord != null) {
        await _mediaLibraryStore?.removePlaybackRecord(continueRecord);
      }
      await _refreshLocalDiscContinue();
      _showLibraryError('本地蓝光播放器已启动');
      if (subtitles != null && subtitles.issues.isNotEmpty) {
        _showLibraryError('部分字幕或字体资源不可用，视频播放不受影响。');
      }
    } on AppException catch (error) {
      _showLibraryError(error.message);
    }
  }

  Future<void> _playRemoteBdmv(String path, {String? sessionId}) async {
    await context.read<AppState>().withMediaPlaybackPriority(
      () => _playRemoteBdmvPrepared(path, sessionId: sessionId),
    );
  }

  Future<void> _playRemoteBdmvPrepared(String path, {String? sessionId}) async {
    if (_preparingBdmv) return;
    final service = _service;
    final startupTrace = DiscStartupTrace();
    startupTrace.mark('menuCapabilityStarted');
    final menuAvailability = _isoPlaybackService?.remoteMenu
        .checkAvailability()
        .then((value) {
          startupTrace.mark('menuCapabilityReady');
          return value;
        });
    menuAvailability?.ignore();
    setState(() => _preparingBdmv = true);
    try {
      final disc = await WebDavBdmvService.discover(service, path);
      startupTrace.mark('manifestReady');
      if (!mounted || service != _service) return;
      await _playIso(
        disc,
        sessionId: sessionId,
        startupTrace: startupTrace,
        menuAvailability: menuAvailability,
      );
    } on AppException catch (error) {
      if (mounted) _showLibraryError(error.message);
    } on TimeoutException {
      if (mounted) _showLibraryError('BDMV 目录读取超时');
    } finally {
      if (mounted) setState(() => _preparingBdmv = false);
    }
  }

  Future<void> _playIso(
    WebDavFile file, {
    String? sessionId,
    bool titleOnly = false,
    DiscStartupTrace? startupTrace,
    Future<RemoteMenuAvailability>? menuAvailability,
  }) => context.read<AppState>().withMediaPlaybackPriority(
    () => _playIsoPrepared(
      file,
      sessionId: sessionId,
      titleOnly: titleOnly,
      startupTrace: startupTrace,
      menuAvailability: menuAvailability,
    ),
  );

  Future<void> _playIsoPrepared(
    WebDavFile file, {
    String? sessionId,
    bool titleOnly = false,
    DiscStartupTrace? startupTrace,
    Future<RemoteMenuAvailability>? menuAvailability,
  }) async {
    final trace = startupTrace ?? DiscStartupTrace();
    final isoService = _isoPlaybackService;
    final webDavService = _service;
    if (isoService == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SPNotice(content: AppText('ISO 远程播放测试模块初始化失败，视频和音频播放不受影响')),
      );
      return;
    }
    final existingSession = sessionId == null ? null : _sessionById(sessionId);
    if (existingSession != null &&
        existingSession.history.kind != PlaybackHistoryKind.iso) {
      return;
    }
    if (sessionId == null &&
        _playbackSessions
                .where(
                  (session) =>
                      (session.history.sourceId ?? _sourceId) == _sourceId,
                )
                .length >=
            _historyStore.maxSessionsPerSource) {
      await showGlassDialog<void>(
        context: context,
        builder: (dialogContext) => SPDialog(
          title: const AppText('播放位置已占满'),
          content: Text(
            context.l10n.format('当前最多同时保留 {count} 个播放会话，请先关闭或删除一个下边栏后再播放。', {
              'count': _historyStore.maxSessionsPerSource,
            }),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const AppText('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    if (isoService.isBusy) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SPNotice(content: AppText('ISO 远程播放测试模块正在执行其他任务')));
      return;
    }

    Stopwatch? startupClock;
    var remoteMenu = false;
    RemoteMenuAvailability? availability;
    final String? menuReasonInitial;
    if (titleOnly) {
      menuReasonInitial = 'disabled';
    } else if (menuAvailability != null) {
      availability = await menuAvailability;
      menuReasonInitial = availability.reason;
    } else {
      menuReasonInitial = await isoService.remoteMenu.unavailableReason();
    }
    var menuReason = menuReasonInitial;
    if (!trace.eventsMs.containsKey('menuCapabilityReady')) {
      trace.mark('menuCapabilityReady');
    }
    if (!mounted) return;
    while (!titleOnly &&
        (menuReason == null ||
            menuReason == RemoteMenuPlaybackService.runtimeMissing)) {
      final mode = await showGlassDialog<Object>(
        context: context,
        builder: (dialogContext) => SPDialog(
          title: AppText(file.name),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const AppText('请选择 Blu-ray 播放方式。菜单模式仅支持 HDMV，失败时不会自动切换。'),
              if (menuReason != null) ...[
                const SizedBox(height: 12),
                AppText(menuReason),
              ],
              ...[
                const SizedBox(height: 12),
                const SelectableText(
                  'WinFsp - Windows File System Proxy\nCopyright (C) Bill Zissimopoulos\nhttps://github.com/winfsp/winfsp',
                  style: TextStyle(fontSize: 11),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const AppText('取消'),
            ),
            OutlinedButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(PlaybackMode.legacyTitle),
              child: const AppText('标题/播放列表模式'),
            ),
            OutlinedButton(
              onPressed: menuReason == null
                  ? () => Navigator.of(
                      dialogContext,
                    ).pop(PlaybackMode.webdavHdmvMenu)
                  : null,
              child: const AppText('蓝光菜单播放'),
            ),
            if (menuReason == RemoteMenuPlaybackService.runtimeMissing)
              OutlinedButton(
                onPressed: () => Navigator.of(dialogContext).pop('install'),
                child: const AppText('安装 WinFsp 运行时'),
              ),
          ],
        ),
      );
      if (!mounted || mode == null) return;
      if (mode == 'install') {
        try {
          await isoService.remoteMenu.installRuntime();
          availability = await isoService.remoteMenu.checkAvailability();
          menuReason = availability.reason;
        } on AppException catch (error) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SPNotice(content: AppText(error.message)));
          }
          return;
        }
        if (!mounted) return;
        continue;
      }
      startupClock = Stopwatch()..start();
      trace.mark('modeSelected');
      remoteMenu = mode == PlaybackMode.webdavHdmvMenu;
      break;
    }
    startupClock ??= Stopwatch()..start();
    if (!trace.eventsMs.containsKey('modeSelected')) trace.mark('modeSelected');
    var preparationCancelled = false;
    trace.mark('subtitleDiscoveryStarted');
    final subtitlePreparation =
        _createIsoSubtitles(
          _source,
          file,
          cancelled: file is WebDavBdmv ? () => preparationCancelled : null,
        ).then((value) {
          trace.mark('subtitleDiscoveryReady');
          return value;
        });
    if (!mounted) return;
    final result = await showGlassDialog<_IsoDialogResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _IsoStreamingDialog(
        service: isoService,
        startupClock: startupClock,
        startupTrace: trace,
        precheckedMenuExecutable: file is WebDavBdmv && remoteMenu
            ? availability?.executable
            : null,
        cancelPreparation: () => preparationCancelled = true,
        webDavService: webDavService,
        file: file,
        subtitles: subtitlePreparation,
        remoteMenu: remoteMenu,
        menuUnavailableReason: titleOnly ? null : menuReason,
      ),
    );
    if (result?.launched != true) preparationCancelled = true;
    if (!mounted || result == null) return;
    final subtitles = result.launched ? await subtitlePreparation : null;
    if (!mounted) return;
    if (result.launched) {
      if (subtitles != null && subtitles.issues.isNotEmpty) {
        _showLibraryError('部分字幕或字体资源不可用，视频播放不受影响。');
      }
      final launch = result.launchResult!;
      final resolvedSessionId = sessionId ?? _newSessionId();
      final now = DateTime.now();
      final history = PlaybackHistory(
        sessionId: resolvedSessionId,
        dirCrumbs: file is WebDavBdmv
            ? (file.rootPath.isEmpty ? <String>[] : file.rootPath.split('/')
                ..removeLast())
            : List<String>.of(_crumbs),
        fileName: file.name,
        videoIndex: 0,
        updatedAt: now,
        createdAt: existingSession?.history.createdAt ?? now,
        playlistFileNames: [file.name],
        playerPid: launch.playerIdentity.pid,
        playerExecutablePath: launch.playerIdentity.executablePath,
        playerCreationTime: launch.playerIdentity.creationTime,
        kind: PlaybackHistoryKind.iso,
        isoKey: launch.isoKey,
        playbackMode: launch.playbackMode,
        isoSessionDirectoryPath: launch.sessionDirectoryPath,
        sourceId: _sourceId,
      );
      final session = existingSession ?? PlaybackUiSession(history);
      session
        ..history = history
        ..lastSyncedPos = 0
        ..paused = false
        ..launching = false;
      if (existingSession == null) {
        _playbackPresenter.addVideoSession(session);
      }
      final stored = await _historyStore.upsert(history);
      if (!stored) {
        await isoService.terminateSession(launch.sessionDirectoryPath);
        if (mounted) _playbackPresenter.removeVideoSession(session);
        return;
      }
      if (!mounted) return;
      unawaited(
        _recordPlaybackFile(
          file,
          parentPath: file is WebDavBdmv
              ? (file.rootPath.isEmpty
                    ? ''
                    : p.posix
                          .dirname(file.rootPath)
                          .replaceFirst(RegExp(r'^\.$'), ''))
              : _currentPath,
          playbackSessionId: resolvedSessionId,
          playbackMode: launch.playbackMode,
        ),
      );
      _refreshPlaybackMonitor();
      ScaffoldMessenger.of(context).showSnackBar(
        const SPNotice(content: AppText('ISO 播放器已启动，关闭 MPV 后将清理会话文件')),
      );
      return;
    }
    if (result.cancelled) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SPNotice(content: AppText('已取消 ISO 播放')));
      return;
    }
    final errorMessage = result.errorMessage ?? '未知错误';
    if (remoteMenu) {
      final returnToTitles = await showGlassDialog<bool>(
        context: context,
        builder: (dialogContext) => SPDialog(
          title: const AppText('蓝光菜单播放失败'),
          content: AppText(errorMessage),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const AppText('取消'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const AppText('返回选择标题模式'),
            ),
          ],
        ),
      );
      if (mounted && returnToTitles == true) {
        await _playIso(file, sessionId: sessionId, titleOnly: true);
      }
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SPNotice(
        content: Text(
          context.l10n.format('ISO 流式播放失败：{message}', {
            'message': context.l10n.text(errorMessage),
          }),
        ),
      ),
    );
  }

  // ── 视频播放联动（自动切集） ─────────────────────────────────

  Future<IsoSubtitleContext?> _createIsoSubtitles(
    MediaDirectorySource source,
    MediaDirectoryEntry iso, {
    bool Function()? cancelled,
  }) async {
    if (!context
        .read<AppState>()
        .configStore
        .current
        .subtitleInjectionEnabled) {
      return null;
    }
    try {
      return await IsoSubtitleContext.create(source, iso, cancelled: cancelled);
    } on AppException {
      if (mounted) _showLibraryError('字幕资源准备失败，视频继续播放');
    } on FileSystemException {
      if (mounted) _showLibraryError('字幕资源准备失败，视频继续播放');
    } on FormatException {
      if (mounted) _showLibraryError('字幕资源准备失败，视频继续播放');
    }
    return null;
  }

  Future<IsoSubtitleContext?> _isoSubtitlesForPath(
    MediaDirectorySource source,
    String path,
  ) async {
    if (!context
        .read<AppState>()
        .configStore
        .current
        .subtitleInjectionEnabled) {
      return null;
    }
    try {
      if (source is LocalMediaSource) {
        final devicePath = await source.resolveDiscDevice(path);
        if (await Directory(devicePath).exists()) {
          final index = await File(
            p.join(devicePath, 'BDMV', 'index.bdmv'),
          ).stat();
          return _createIsoSubtitles(
            source,
            LocalMediaEntry(
              name: path.isEmpty
                  ? source.root.displayName
                  : p.posix.basename(path),
              relativePath: path,
              absolutePath: devicePath,
              isDirectory: true,
              size: index.size,
              modified: index.modified,
            ),
          );
        }
      }
      final parent = p.posix.dirname(path);
      final files = await source.fetchDirectory(parent == '.' ? '' : parent);
      final file = files
          .where(
            (e) =>
                (e.isIso || e.isDirectory) && e.name == p.posix.basename(path),
          )
          .firstOrNull;
      if (file != null && mounted) {
        if (file.isDirectory && source is WebDavMediaSourceAdapter) {
          final disc = await WebDavBdmvService.discover(source.service, path);
          if (mounted) return _createIsoSubtitles(source, disc);
        } else if (file.isIso) {
          return _createIsoSubtitles(source, file);
        }
      }
    } on AppException {
      if (mounted) _showLibraryError('字幕资源准备失败，视频继续播放');
    } on FileSystemException {
      if (mounted) _showLibraryError('字幕资源准备失败，视频继续播放');
    }
    return null;
  }

  Future<void> _showIsoSubtitleSession(
    MediaDirectorySource source,
    String isoPath,
    Directory directory,
  ) async {
    final subtitles = await _isoSubtitlesForPath(source, isoPath);
    if (!mounted || subtitles == null) return;
    try {
      final session = await IsoSubtitleSession.restore(subtitles, directory);
      if (!mounted) return;
      if (session == null) {
        _showLibraryError('此会话未启用蓝光外挂字幕，请重新打开蓝光');
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (_) =>
            IsoSubtitleDialog(subtitles: subtitles, session: session),
      );
    } on FileSystemException {
      if (mounted) _showLibraryError('字幕绑定已保存；播放器暂不可用');
    } on FormatException {
      if (mounted) _showLibraryError('字幕绑定文件不可用，原文件未覆盖');
    }
  }

  Future<void> _showLocalIsoSubtitles(_LocalDiscContinueEntry entry) async {
    final source = _localSourceFor(entry.record.item.sourceId);
    final id = entry.record.playbackSessionId;
    if (source == null || id == null) return;
    final base = await AppPaths.cacheDirectory();
    if (!mounted) return;
    final path =
        entry.record.localDiscSession?.relativePath ??
        (_isRootLocalDiscItem(entry.record.item)
            ? ''
            : entry.record.item.targetPath);
    await _showIsoSubtitleSession(
      source,
      path,
      Directory(p.join(base.path, 'local_iso_subtitles', id)),
    );
  }

  Future<SubtitleItem?> _resolvedSubtitleFor(
    MediaDirectoryEntry video,
    List<MediaDirectoryEntry> siblings,
  ) async {
    final appState = context.read<AppState>();
    if (!appState.configStore.current.subtitleInjectionEnabled) return null;
    final match = appState.subtitleMatcher.findBestFor(video, siblings);
    if (match == null || !_isLocal) return match;
    final subtitleEntry = siblings
        .where((entry) => entry.entryKey == match.url)
        .firstOrNull;
    if (subtitleEntry == null) return null;
    final target = await _source.resolve(subtitleEntry);
    if (target is! LocalMediaOpenTarget) return null;
    return SubtitleItem(
      name: match.name,
      url: target.path,
      language: match.language,
      score: match.score,
    );
  }

  Future<WebDavFontDirectory?> _resolvedWebDavFontsFor(
    MediaDirectoryEntry video,
    List<MediaDirectoryEntry> siblings,
  ) async {
    if (_isLocal) return null;
    final appState = context.read<AppState>();
    if (!appState.configStore.current.subtitleInjectionEnabled) return null;
    final service = _service;
    final match = appState.webDavFontMatcher.findBestFor(
      video,
      siblings,
      baseUrl: service.baseUrl,
    );
    if (match == null) return null;
    try {
      final entries = await service.fetchDirectory(match.requestPath);
      final resolved = appState.webDavFontMatcher.withDirectFontFiles(
        match,
        entries,
        baseUrl: service.baseUrl,
      );
      return resolved.files.isEmpty ? null : resolved;
    } on AppException {
      return null;
    }
  }

  Future<({String path, int files, int bytes})?> _resolvedLocalFontsFor(
    List<MediaDirectoryEntry> siblings, {
    required int maxFiles,
    required int maxBytes,
    required DateTime deadline,
  }) async {
    if (!_isLocal) return null;
    final candidates =
        siblings
            .where(
              (entry) =>
                  entry.isDirectory &&
                  !entry.isSelfEntry &&
                  WebDavFontMatcher.directoryScore(entry.name) != null,
            )
            .toList()
          ..sort((left, right) {
            final score = WebDavFontMatcher.directoryScore(
              right.name,
            )!.compareTo(WebDavFontMatcher.directoryScore(left.name)!);
            return score != 0 ? score : naturalCompare(left.name, right.name);
          });
    for (final candidate in candidates) {
      var remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero || maxFiles <= 0 || maxBytes <= 0) {
        return null;
      }
      try {
        final target = await _source.resolve(candidate).timeout(remaining);
        if (target is! LocalMediaOpenTarget) continue;
        remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) return null;
        final files = await _source
            .fetchDirectory(candidate.relativePath)
            .timeout(remaining);
        var fontCount = 0;
        var fontBytes = 0;
        var valid = true;
        for (final file in files) {
          if (file.isDirectory ||
              !AppConstants.fontExtensions.contains(file.extension) ||
              SpecialVideoPlaylistCollector.directChildPath(
                    _source,
                    candidate.relativePath,
                    file,
                  ) ==
                  null) {
            continue;
          }
          try {
            remaining = deadline.difference(DateTime.now());
            if (remaining <= Duration.zero) return null;
            final fontTarget = await _source.resolve(file).timeout(remaining);
            if (fontTarget is! LocalMediaOpenTarget) continue;
            remaining = deadline.difference(DateTime.now());
            if (remaining <= Duration.zero) return null;
            final size = await File(
              fontTarget.path,
            ).length().timeout(remaining);
            fontCount++;
            fontBytes += size;
            if (size > WebDavFontLocalizer.maxFontBytes ||
                fontCount > maxFiles ||
                fontBytes > maxBytes) {
              valid = false;
              break;
            }
          } on AppException {
            valid = false;
            break;
          }
        }
        if (!valid || fontCount == 0) {
          continue;
        }
        return (path: target.path, files: fontCount, bytes: fontBytes);
      } on AppException {
        continue;
      } on FileSystemException {
        continue;
      } on TimeoutException {
        return null;
      }
    }
    return null;
  }

  Future<String> _resolvedMediaUrl(MediaDirectoryEntry entry) async {
    final target = await _source.resolve(entry);
    return switch (target) {
      WebDavMediaOpenTarget(:final url) => url,
      LocalMediaOpenTarget(:final path) => path,
    };
  }

  Future<_PreparedSeason?> _prepareNextSeason(
    String rootPath,
    List<MediaDirectoryEntry> rootEntries,
  ) async {
    final config = context.read<AppState>().configStore.current;
    if (!config.autoSeasonTransitionEnabled) return null;
    final candidate = await const SeasonVideoPlaylistCollector().findNext(
      source: _source,
      rootPath: rootPath,
      rootEntries: rootEntries,
      allowGap: config.allowSeasonGap,
    );
    if (candidate == null || !mounted) return null;
    final rootVideos = <SpecialVideoItem>[];
    for (final file in candidate.entries) {
      if (!(_isLocal ? file.isVideo : file.isPlayable)) continue;
      final path = SpecialVideoPlaylistCollector.directChildPath(
        _source,
        candidate.path,
        file,
      );
      if (path != null) {
        rootVideos.add(
          SpecialVideoItem(file, candidate.entries, candidate.path, path),
        );
      }
    }
    rootVideos.sort((left, right) {
      final result = naturalCompare(left.entry.name, right.entry.name);
      return result != 0 ? result : left.path.compareTo(right.path);
    });
    final scan = await const SpecialVideoPlaylistCollector().collect(
      source: _source,
      rootPath: candidate.path,
      rootEntries: candidate.entries,
      mode: config.specialPlaylistMode,
      scanChildFolders: config.scanSpecialChildFolders,
      scanSiblingFolders: config.scanSpecialSiblingFolders,
    );
    if (scan.incomplete || !mounted) return null;
    final items = [...rootVideos, ...scan.items];
    if (items.isEmpty) return null;
    final titles = await _videoPlaylistTitles(items);
    final entries = <MediaEntry>[];
    final active = <SpecialVideoItem>[];
    final localFonts = <String?>[];
    final remoteFonts = <WebDavFontDirectory?>[];
    final localCache = <String, ({String path, int files, int bytes})?>{};
    final remoteCache = <String, WebDavFontDirectory?>{};
    var remainingFiles = WebDavFontLocalizer.maxFontFiles;
    var remainingBytes = WebDavFontLocalizer.maxSessionBytes;
    final fontDeadline = DateTime.now().add(const Duration(seconds: 30));
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final video = item.entry;
      String url;
      try {
        if (video is WebDavFile && video.isStrm) {
          final resolved = await _service.fetchStrmUrl(video);
          if (resolved == null) return null;
          url = resolved;
        } else {
          url = await _resolvedMediaUrl(video);
        }
      } on AppException {
        return null;
      } on FileSystemException {
        return null;
      }
      entries.add(
        MediaEntry(
          url: url,
          title: titles[i],
          catalogPath: item.path,
          externalAudioTracks: !_isLocal
              ? const ExternalAudioMatcher().matchFor(
                  video,
                  item.siblings,
                  baseUrl: _service.baseUrl,
                )
              : const [],
          subtitle: config.subtitleInjectionEnabled
              ? await _resolvedSubtitleFor(video, item.siblings)
              : null,
        ),
      );
      active.add(item);
      if (!config.subtitleInjectionEnabled) continue;
      if (_isLocal) {
        if (!localCache.containsKey(item.parentPath)) {
          final fonts = await _resolvedLocalFontsFor(
            item.siblings,
            maxFiles: remainingFiles,
            maxBytes: remainingBytes,
            deadline: fontDeadline,
          );
          localCache[item.parentPath] = fonts;
          remainingFiles -= fonts?.files ?? 0;
          remainingBytes -= fonts?.bytes ?? 0;
        }
        localFonts.add(localCache[item.parentPath]?.path);
      } else {
        if (!remoteCache.containsKey(item.parentPath)) {
          remoteCache[item.parentPath] = await _resolvedWebDavFontsFor(
            video,
            item.siblings,
          );
        }
        remoteFonts.add(remoteCache[item.parentPath]);
      }
    }
    if (config.sharePlaylistFonts && config.subtitleInjectionEnabled) {
      if (_isLocal) {
        final shared = localCache[candidate.path]?.path;
        for (var i = 0; i < localFonts.length; i++) {
          localFonts[i] ??= shared;
        }
      } else {
        final shared = remoteCache[candidate.path];
        for (var i = 0; i < remoteFonts.length; i++) {
          remoteFonts[i] ??= shared;
        }
      }
    }
    return _PreparedSeason(
      rootPath: candidate.path,
      items: active,
      playback: SeasonPlaybackEntries(
        entries: entries,
        localFontDirectories: localFonts,
        webDavFontsByEntry: remoteFonts,
      ),
    );
  }

  Future<List<String>> _videoPlaylistTitles(
    List<SpecialVideoItem> items,
  ) async {
    final filenames = [for (final item in items) item.entry.name];
    if (!context
        .read<AppState>()
        .configStore
        .current
        .videoPlaylistSimpleNaming) {
      return filenames;
    }
    final fallback = context.l10n.videoPlaylistTitles(filenames);
    if (!widget.playbackOnly) return fallback;
    final catalog = await context.read<AppState>().getFilmCatalog();
    final titles = await catalog.store.videoPlaylistTitles(_sourceId, [
      for (final item in items) item.path,
    ]);
    return [
      for (var i = 0; i < items.length; i++)
        titles[items[i].path] ?? fallback[i],
    ];
  }

  Future<AudioCompanionFile?> _resolvedAudioCompanion(
    AudioCompanionFile? companion,
  ) async {
    if (companion == null) return null;
    if (!_isLocal) {
      return AudioCompanionFile(
        name: companion.name,
        url: _service.resolveUrl(companion.url),
      );
    }
    final entry = _files
        .where((item) => item.entryKey == companion.url)
        .firstOrNull;
    if (entry == null) return null;
    final target = await _source.resolve(entry);
    return target is LocalMediaOpenTarget
        ? AudioCompanionFile(name: companion.name, url: target.path)
        : null;
  }

  Future<void> _playVideo(
    MediaDirectoryEntry? video, {
    String? sessionId,
    String? playlistRootPath,
    String? resumeTargetPath,
    VideoPlaybackScope playbackScope = VideoPlaybackScope.directory,
  }) => context.read<AppState>().withMediaPlaybackPriority(
    () => _playVideoPrepared(
      video,
      sessionId: sessionId,
      playlistRootPath: playlistRootPath,
      resumeTargetPath: resumeTargetPath,
      playbackScope: playbackScope,
    ),
  );

  Future<void> _playVideoPrepared(
    MediaDirectoryEntry? video, {
    String? sessionId,
    String? playlistRootPath,
    String? resumeTargetPath,
    VideoPlaybackScope playbackScope = VideoPlaybackScope.directory,
  }) async {
    if (_isLocal) {
      return _playVideoCore(
        video,
        sessionId: sessionId,
        playlistRootPath: playlistRootPath,
        resumeTargetPath: resumeTargetPath,
        playbackScope: playbackScope,
      );
    }
    await showGlassDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _WebDavVideoPreparationDialog(
        fileName:
            video?.name ??
            p.basename(resumeTargetPath ?? playlistRootPath ?? ''),
        run: (report) async {
          try {
            await _playVideoCore(
              video,
              sessionId: sessionId,
              playlistRootPath: playlistRootPath,
              resumeTargetPath: resumeTargetPath,
              playbackScope: playbackScope,
              report: report,
            );
          } on AppException catch (error) {
            _showLibraryError(error.message);
          } on FileSystemException catch (error) {
            if (!mounted) return;
            _showLibraryError(
              context.l10n.format('视频准备文件读写失败：{message}', {
                'message': error.message,
              }),
            );
          }
        },
      ),
    );
  }

  Future<void> _playImplicitVideo(
    List<SpecialVideoItem> ordered,
    String targetPath,
    String rootPath,
    List<MediaDirectoryEntry> rootFiles,
    String? sessionId,
    PlaybackUiSession? existingSession,
    VideoPlaybackScope scope,
  ) async {
    final app = context.read<AppState>();
    final source = _source;
    final sourceId = _sourceId;
    final player = _playerService;
    final histories = _historyStore;
    final progressStore = _progressService;
    final records = _mediaLibraryStore;
    final local = _isLocal;
    final service = local ? null : _service;
    final navigator = Navigator.of(context, rootNavigator: true);
    final config = app.configStore.current.toPlayerConfig();
    final store = await app.getFilmCatalogStore();
    var items = [
      for (final item in ordered)
        VideoQueueItem(
          versions: [VideoQueueVersion(path: item.path, name: item.entry.name)],
        ),
    ];
    final mapped = await store.resourceAt(sourceId, targetPath);
    if (scope == VideoPlaybackScope.directory &&
        mapped?.type == FilmMediaType.tv &&
        mapped?.workId != null &&
        mapped?.season != null &&
        mapped?.episode != null) {
      final resources = await store.resources(
        sourceId: sourceId,
        workId: mapped!.workId!,
      );
      final seasons = <int, Map<String, dynamic>>{};
      for (final number
          in resources.map((r) => r.season).whereType<int>().toSet()) {
        final metadata = await store.season(mapped.workId!, number);
        if (metadata != null) seasons[number] = metadata;
      }
      items = buildFilmVideoTimeline(
        resources,
        seasons,
        selectedPath: targetPath,
        autoSeason: config.autoSeasonTransitionEnabled,
        allowGap: config.allowSeasonGap,
      );
    }
    if (scope == VideoPlaybackScope.directory &&
        config.autoSeasonTransitionEnabled &&
        !(mapped?.type == FilmMediaType.tv &&
            mapped?.season != null &&
            mapped?.episode != null)) {
      var path = rootPath;
      var files = rootFiles;
      final seen = <String>{rootPath};
      final expanded = List<SpecialVideoItem>.of(ordered);
      while (true) {
        final next = await const SeasonVideoPlaylistCollector().findNext(
          source: source,
          rootPath: path,
          rootEntries: files,
          allowGap: config.allowSeasonGap,
        );
        if (next == null || !seen.add(next.path)) break;
        final videos = <SpecialVideoItem>[];
        for (final entry in next.entries.where(
          (e) => local ? e.isVideo : e.isPlayable,
        )) {
          final child = SpecialVideoPlaylistCollector.directChildPath(
            source,
            next.path,
            entry,
          );
          if (child != null) {
            videos.add(SpecialVideoItem(entry, next.entries, next.path, child));
          }
        }
        videos.sort((a, b) => naturalCompare(a.entry.name, b.entry.name));
        final special = await const SpecialVideoPlaylistCollector().collect(
          source: source,
          rootPath: next.path,
          rootEntries: next.entries,
          mode: config.specialPlaylistMode,
          scanChildFolders: config.scanSpecialChildFolders,
          scanSiblingFolders: config.scanSpecialSiblingFolders,
        );
        expanded.addAll(
          [
            ...videos,
            ...special.items,
          ].where((i) => !expanded.any((old) => old.path == i.path)),
        );
        path = next.path;
        files = next.entries;
      }
      ordered = expanded;
      items = [
        for (final item in ordered)
          VideoQueueItem(
            versions: [
              VideoQueueVersion(path: item.path, name: item.entry.name),
            ],
            season:
                SeasonVideoPlaylistCollector.seasonFromVideo(item.entry.name) ??
                SeasonVideoPlaylistCollector.seasonFromFolder(
                  p.posix.basename(item.parentPath),
                ),
          ),
      ];
    }
    final index = items.indexWhere(
      (item) => item.versions.any((v) => v.path == targetPath),
    );
    if (index < 0) throw AppException.config('未找到上次播放的视频，请检查文件或特典设置');
    final titles = await _videoPlaylistTitles(ordered);
    final titleMap = {
      for (var i = 0; i < ordered.length; i++) ordered[i].path: titles[i],
    };
    if (config.videoPlaylistSimpleNaming) {
      titleMap.addAll(
        await store.videoPlaylistTitles(
          sourceId,
          items.expand((i) => i.versions.map((v) => v.path)).toList(),
        ),
      );
    }
    final preparer = VideoEntryPreparer(
      source: source,
      config: config,
      subtitleMatcher: app.subtitleMatcher,
      fontMatcher: app.webDavFontMatcher,
      titles: titleMap,
      directories: {
        rootPath: rootFiles,
        for (final item in ordered) item.parentPath: item.siblings,
      },
    );
    await preparer.prepareSharedFonts(rootPath, siblings: rootFiles);
    final version = items[index].versions.firstWhere(
      (v) => v.path == targetPath,
    );
    final initial = await preparer.prepare(version);
    if (!mounted) return;
    final id = sessionId ?? _newSessionId();
    final now = DateTime.now();
    final history = PlaybackHistory(
      sessionId: id,
      sourceId: sourceId,
      dirCrumbs: rootPath.isEmpty ? [] : rootPath.split('/'),
      fileName: version.name,
      videoIndex: index,
      updatedAt: now,
      createdAt: existingSession?.history.createdAt ?? now,
      playlistFileNames: [for (final item in items) item.versions.first.name],
      playlistRelativePaths: [
        for (final item in items) item.versions.first.path,
      ],
      videoQueueRootPath: rootPath,
      queueItems: items,
      videoPlaylistMode: VideoPlaylistMode.implicit,
      playbackScope: scope,
    );
    final session = existingSession ?? PlaybackUiSession(history);
    session
      ..history = history
      ..lastSyncedPos = index
      ..finishPending = 0
      ..paused = null
      ..recovering = false
      ..launching = true;
    session.activationGuard.reset();
    if (existingSession == null) _playbackPresenter.addVideoSession(session);
    if (!await histories.upsert(history)) return;
    Future<void> updateTarget(
      int next,
      VideoQueueVersion target, {
      required bool loaded,
    }) async {
      final current = (await histories.loadAll())
          .where((h) => h.sessionId == id)
          .firstOrNull;
      if (current == null) return;
      final paths = List<String>.of(current.playlistRelativePaths);
      final names = List<String>.of(current.playlistFileNames);
      paths[next] = target.path;
      names[next] = target.name;
      final parent = p.posix.dirname(target.path);
      if (!loaded) {
        await histories.upsert(current.copyWith(pendingVideoIndex: next));
        return;
      }
      final updated = current.copyWith(
        clearPendingVideoIndex: true,
        videoIndex: next,
        fileName: target.name,
        dirCrumbs: parent == '.' ? [] : parent.split('/'),
        updatedAt: DateTime.now(),
        playlistRelativePaths: paths,
        playlistFileNames: names,
      );
      await histories.upsert(updated);
      if (loaded) {
        await records?.recordPlayback(
          MediaLibraryItem(
            sourceId: sourceId,
            sourceKind: source.descriptor.kind,
            parentPath: parent == '.' ? '' : parent,
            name: target.name,
            kind: target.name.toLowerCase().endsWith('.strm')
                ? MediaLibraryKind.strm
                : MediaLibraryKind.video,
            playbackMode: local
                ? PlaybackMode.localFile
                : PlaybackMode.legacyTitle,
            playbackScope: scope,
          ),
          playbackSessionId: id,
          playlistIndex: next,
          playlistCount: items.length,
        );
      }
      if (mounted && _playbackSessions.contains(session)) {
        setState(() {
          session.history = updated;
          if (loaded) {
            session.lastSyncedPos = next;
            session.launching = false;
          }
        });
      }
    }

    final plan = ImplicitVideoPlan(
      items: items,
      index: index,
      prepare: preparer.prepare,
      chooseVersion: (item) async {
        if (!navigator.mounted) return null;
        return showVideoVersionDialog(navigator.context, item);
      },
      activated: (i, v) => updateTarget(i, v, loaded: true),
      pending: (i) => updateTarget(i, items[i].versions.first, loaded: false),
      failed: (message) {
        if (navigator.mounted) {
          ScaffoldMessenger.of(
            navigator.context,
          ).showSnackBar(SPNotice(content: AppText(message)));
        }
      },
    );
    plan.selected[index] = version;
    plan.prepared[version.path] = initial;
    try {
      final progress = await progressStore.getResumeProgress(
        initial.entry.url,
        profileId: sourceId,
      );
      final resume = progress != null && !progress.isFinishedNearEnd()
          ? progress.resumeSeconds
          : null;
      session.statusNotBefore = DateTime.now();
      final result = local
          ? await player.launchLocal(
              entries: [initial.entry],
              sourceId: sourceId,
              sessionId: id,
              resumeSeconds: resume,
              localFontDirectories: [initial.localFontDirectory],
              implicitPlan: plan,
            )
          : await player.launch(
              entries: [initial.entry],
              sessionId: id,
              resumeSeconds: resume,
              implicitPlan: plan,
              username: service!.credentialSnapshot.username,
              password: service.credentialSnapshot.password,
              webDavSourceUrl: service.baseUrl,
              webDavSourceId: sourceId,
              webDavFontsByEntry: [initial.remoteFonts],
              webDavFontLoader: service.fetchFileBytes,
              webDavFontFileLoader: service.downloadFile,
            );
      final current = (await histories.loadAll()).firstWhere(
        (h) => h.sessionId == id,
      );
      final launched = current.copyWith(
        playerPid: result.process.pid,
        playerExecutablePath: result.processIdentity?.executablePath,
        playerCreationTime: result.processIdentity?.creationTime,
        ipcPipeName: result.ipcPipeName,
        launchEpoch: result.launchEpoch,
        clearSeasonPlaylistPath: true,
        clearNextSeason: true,
      );
      await histories.upsert(launched);
      if (mounted) {
        setState(() {
          session.history = launched;
          session.launching = false;
        });
        _refreshPlaybackMonitor();
      }
    } on AppException catch (error) {
      session.launching = false;
      if (mounted) {
        setState(() {});
        _showLibraryError(error.message);
      }
    }
  }

  Future<void> _playVideoCore(
    MediaDirectoryEntry? video, {
    String? sessionId,
    String? playlistRootPath,
    String? resumeTargetPath,
    VideoPlaybackScope playbackScope = VideoPlaybackScope.directory,
    void Function(String stage, WebDavFontLocalizationProgress? font)? report,
  }) async {
    if (widget.playbackOnly) playbackScope = VideoPlaybackScope.directory;
    final appState = context.read<AppState>();
    final rootPath = playlistRootPath ?? _currentPath;
    final rootFiles = rootPath == _currentPath
        ? List<MediaDirectoryEntry>.of(_files)
        : await _source.fetchDirectory(rootPath);
    report?.call('正在生成播放列表…', null);
    if (!mounted) return;
    final existingSession = sessionId == null ? null : _sessionById(sessionId);
    if (sessionId == null &&
        _playbackSessions
                .where(
                  (session) =>
                      (session.history.sourceId ?? _sourceId) == _sourceId,
                )
                .length >=
            _historyStore.maxSessionsPerSource) {
      await showGlassDialog<void>(
        context: context,
        builder: (dialogContext) => SPDialog(
          title: const AppText('播放位置已占满'),
          content: Text(
            context.l10n.format('当前最多同时保留 {count} 个播放会话，请先关闭或删除一个下边栏后再播放。', {
              'count': _historyStore.maxSessionsPerSource,
            }),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const AppText('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    if (existingSession?.deleting == true ||
        existingSession?.launching == true) {
      return;
    }

    final rootVideos = <SpecialVideoItem>[];
    for (final file in rootFiles) {
      if (!(_isLocal ? file.isVideo : file.isPlayable)) continue;
      final path = SpecialVideoPlaylistCollector.directChildPath(
        _source,
        rootPath,
        file,
      );
      if (path != null) {
        rootVideos.add(SpecialVideoItem(file, rootFiles, rootPath, path));
      }
    }
    rootVideos.sort((left, right) {
      final result = naturalCompare(left.entry.name, right.entry.name);
      return result != 0 ? result : left.path.compareTo(right.path);
    });
    final targetPath =
        resumeTargetPath ??
        (video == null
            ? null
            : SpecialVideoPlaylistCollector.directChildPath(
                _source,
                rootPath,
                video,
              ));
    final config = appState.configStore.current;
    final scan = playbackScope == VideoPlaybackScope.singleItem
        ? const SpecialVideoScanResult([], false)
        : await const SpecialVideoPlaylistCollector().collect(
            source: _source,
            rootPath: rootPath,
            rootEntries: rootFiles,
            mode: config.specialPlaylistMode,
            scanChildFolders: config.scanSpecialChildFolders,
            scanSiblingFolders: config.scanSpecialSiblingFolders,
          );
    final ordered = playbackScope == VideoPlaybackScope.singleItem
        ? rootVideos.where((item) => item.path == targetPath).toList()
        : [...rootVideos, ...scan.items];
    report?.call('正在匹配外挂字幕…', null);
    if (!mounted) return;
    if (targetPath == null || !ordered.any((item) => item.path == targetPath)) {
      _showLibraryError('未找到上次播放的视频，请检查文件或特典设置');
      return;
    }
    final mode =
        existingSession?.history.videoPlaylistMode ?? config.videoPlaylistMode;
    if (mode == VideoPlaylistMode.implicit &&
        p.basename(config.playerExecutable).toLowerCase().contains('mpv')) {
      await _playImplicitVideo(
        ordered,
        targetPath,
        rootPath,
        rootFiles,
        sessionId,
        existingSession,
        playbackScope,
      );
      return;
    }
    // strm 流指针条目：分批并发预取指向的真实媒体地址（每批限流，
    // 避免大量 strm 打爆服务器）；解析失败的条目从播放列表剔除。
    final strmUrls = <String, String>{};
    final strmFiles = ordered
        .map((item) => item.entry)
        .whereType<WebDavFile>()
        .where((file) => file.isStrm)
        .toList();
    const batchSize = 4;
    for (var i = 0; i < strmFiles.length; i += batchSize) {
      final batch = strmFiles.sublist(
        i,
        (i + batchSize < strmFiles.length) ? i + batchSize : strmFiles.length,
      );
      await Future.wait(
        batch.map((f) async {
          final url = await _service.fetchStrmUrl(f);
          if (url != null) strmUrls[f.href] = url;
        }),
      );
    }

    final entries = <MediaEntry>[];
    var clickedIndex = -1;
    var playlistIncomplete = scan.incomplete;
    final subtitleInjectionEnabled =
        appState.configStore.current.subtitleInjectionEnabled;
    final activeVideos = <SpecialVideoItem>[];
    final titles = await _videoPlaylistTitles(ordered);
    for (var i = 0; i < ordered.length; i++) {
      final item = ordered[i];
      final v = item.entry;
      String? url;
      try {
        url = v is WebDavFile && v.isStrm
            ? strmUrls[v.href]
            : await _resolvedMediaUrl(v);
      } on AppException {
        if (item.path == targetPath) {
          _showLibraryError('未找到上次播放的视频，请检查文件或特典设置');
          return;
        }
        if (item.parentPath != rootPath) playlistIncomplete = true;
        continue;
      } on FileSystemException {
        if (item.path == targetPath) {
          _showLibraryError('未找到上次播放的视频，请检查文件或特典设置');
          return;
        }
        if (item.parentPath != rootPath) playlistIncomplete = true;
        continue;
      }
      if (url == null) continue;
      if (item.path == targetPath) clickedIndex = entries.length;
      activeVideos.add(item);
      entries.add(
        MediaEntry(
          url: url,
          title: titles[i],
          catalogPath: item.path,
          externalAudioTracks: !_isLocal
              ? const ExternalAudioMatcher().matchFor(
                  v,
                  item.siblings,
                  baseUrl: _service.baseUrl,
                )
              : const [],
          subtitle: subtitleInjectionEnabled
              ? await _resolvedSubtitleFor(v, item.siblings)
              : null,
        ),
      );
    }
    if (entries.isEmpty || clickedIndex < 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SPNotice(
            content: AppText('无法播放「${video?.name ?? ''}」：strm 内容无效或读取失败'),
          ),
        );
      }
      return;
    }
    final playStart = clickedIndex;
    final seasonLookup =
        playbackScope == VideoPlaybackScope.directory &&
            config.autoSeasonTransitionEnabled &&
            playStart == entries.length - 1 &&
            p.basename(config.playerExecutable).toLowerCase().contains('mpv')
        ? _prepareNextSeason(rootPath, rootFiles)
        : Future<_PreparedSeason?>.value(null);
    final resolvedSessionId = sessionId ?? _newSessionId();
    final remoteFonts = <WebDavFontDirectory?>[];
    final localFonts = <String?>[];
    WebDavFontDirectory? sharedRemoteFonts;
    if (subtitleInjectionEnabled) {
      report?.call('正在查找外挂字体…', null);
      final remoteCache = <String, WebDavFontDirectory?>{};
      final localCache = <String, ({String path, int files, int bytes})?>{};
      var remainingLocalFiles = WebDavFontLocalizer.maxFontFiles;
      var remainingLocalBytes = WebDavFontLocalizer.maxSessionBytes;
      final localFontDeadline = DateTime.now().add(const Duration(seconds: 30));
      for (final item in activeVideos) {
        if (_isLocal) {
          if (!localCache.containsKey(item.parentPath)) {
            final fonts = await _resolvedLocalFontsFor(
              item.siblings,
              maxFiles: remainingLocalFiles,
              maxBytes: remainingLocalBytes,
              deadline: localFontDeadline,
            );
            localCache[item.parentPath] = fonts;
            remainingLocalFiles -= fonts?.files ?? 0;
            remainingLocalBytes -= fonts?.bytes ?? 0;
          }
          localFonts.add(localCache[item.parentPath]?.path);
        } else {
          if (!remoteCache.containsKey(item.parentPath)) {
            remoteCache[item.parentPath] = await _resolvedWebDavFontsFor(
              item.entry,
              item.siblings,
            );
          }
          remoteFonts.add(remoteCache[item.parentPath]);
        }
      }
      if (appState.configStore.current.sharePlaylistFonts) {
        if (_isLocal) {
          final rootFont = localCache[rootPath]?.path;
          for (var i = 0; i < activeVideos.length; i++) {
            localFonts[i] ??= rootFont;
          }
        } else {
          final rootFont = remoteCache[rootPath];
          sharedRemoteFonts = rootFont;
          for (var i = 0; i < activeVideos.length; i++) {
            remoteFonts[i] ??= rootFont;
          }
        }
      }
    }
    _PreparedSeason? nextSeason;
    report?.call('正在准备播放列表…', null);
    try {
      nextSeason = await seasonLookup;
    } on AppException catch (error) {
      // 候选季不可用时仍正常播放当前季。
      debugPrint('Season preparation skipped: $error');
    } on FileSystemException catch (error) {
      // 本地候选季读取失败时仍正常播放当前季。
      debugPrint('Season preparation skipped: $error');
    } on TimeoutException catch (error) {
      // 候选季准备有界，超时仍正常播放当前季。
      debugPrint('Season preparation skipped: $error');
    }
    if (!mounted) return;
    final now = DateTime.now();
    final history = PlaybackHistory(
      sessionId: resolvedSessionId,
      dirCrumbs: rootPath.isEmpty ? const [] : rootPath.split('/'),
      fileName: activeVideos[playStart].entry.name,
      videoIndex: playStart,
      updatedAt: now,
      createdAt: existingSession?.history.createdAt ?? now,
      playlistFileNames: activeVideos.map((item) => item.entry.name).toList(),
      playlistRelativePaths: activeVideos.map((item) => item.path).toList(),
      playbackScope: playbackScope,
      nextSeasonRootPath: nextSeason?.rootPath,
      nextSeasonFileNames:
          nextSeason?.items.map((item) => item.entry.name).toList() ?? const [],
      nextSeasonRelativePaths:
          nextSeason?.items.map((item) => item.path).toList() ?? const [],
      sourceId: _sourceId,
    );
    final session = existingSession ?? PlaybackUiSession(history);
    session
      ..history = history
      ..lastSyncedPos = playStart
      ..finishPending = 0
      ..paused = null
      ..recovering = false
      ..launching = true;
    session.activationGuard.reset();
    session
      ..lastReportedPositionSeconds = null
      ..lastReportedDurationSeconds = null
      ..lastProgressPersistedAt = null;
    if (mounted && existingSession == null) {
      _playbackPresenter.addVideoSession(session);
    }
    final stored = await _historyStore.upsert(history);
    if (!stored) {
      if (mounted) _playbackPresenter.removeVideoSession(session);
      return;
    }

    // 2. 查询播放起点视频的续播进度（失败不阻塞播放）。
    //    进度接近结尾（剩余不足 1 分钟，视为已看完）→ 从头播放，
    //    避免 mpv 从片尾恢复导致秒切下一集。
    PlaybackProgress? progress;
    try {
      progress = await _progressService.getResumeProgress(
        entries[playStart].url,
        profileId: _sourceId,
      );
      // 已看完（时长已知且位置接近片尾，剩余不足 1 分钟）→ 从头播放，
      // 避免 mpv 从片尾恢复导致秒切下一集。
      // 注意：时长缺失（mpv 对网络流不写 duration）时**不**视为已看完，
      // 否则每次播放都会从头开始。
      if (progress != null && progress.isFinishedNearEnd()) {
        progress = null;
      }
    } on AppException {
      // 进度读取失败忽略，正常播放。
    }

    // 3. 调起外部播放器（凭据注入由服务内部按播放器类型处理）。
    try {
      report?.call(
        remoteFonts.any((font) => font != null) ? '正在下载外挂字体…' : '正在启动播放器…',
        null,
      );
      session.statusNotBefore = DateTime.now();
      final result = _isLocal
          ? await _playerService.launchLocal(
              entries: entries,
              sourceId: _sourceId,
              sessionId: resolvedSessionId,
              playlistStart: playStart,
              resumeSeconds: progress?.resumeSeconds,
              localFontDirectories: localFonts,
              nextSeason: nextSeason?.playback,
            )
          : await _playerService.launch(
              entries: entries,
              sessionId: resolvedSessionId,
              playlistStart: playStart,
              resumeSeconds: progress?.resumeSeconds,
              username: _service.credentialSnapshot.username,
              password: _service.credentialSnapshot.password,
              webDavSourceUrl: _service.baseUrl,
              webDavSourceId: _sourceId,
              webDavFonts: sharedRemoteFonts,
              webDavFontsByEntry: remoteFonts,
              webDavFontLoader: _service.fetchFileBytes,
              webDavFontFileLoader: _service.downloadFile,
              onFontProgress: (font) =>
                  report?.call(font.fromCache ? '已使用缓存字体' : '正在下载外挂字体…', font),
              onPreparationStage: (stage) => report?.call(stage, null),
              nextSeason: nextSeason?.playback,
            );
      if (!mounted || !_playbackSessions.contains(session)) {
        await _playerService.terminateLaunch(result);
        return;
      }
      final launchedHistory = session.history.copyWith(
        playerPid: result.process.pid,
        playerExecutablePath: result.processIdentity?.executablePath,
        clearPlayerExecutablePath: result.processIdentity == null,
        playerCreationTime: result.processIdentity?.creationTime,
        clearPlayerCreationTime: result.processIdentity == null,
        ipcPipeName: result.ipcPipeName,
        launchEpoch: result.launchEpoch,
        seasonPlaylistPath: result.seasonPlaylistPath,
        nextSeasonPlaylistPath: result.nextSeasonPlaylistPath,
        clearNextSeason: result.nextSeasonPlaylistPath == null,
        updatedAt: DateTime.now(),
      );
      if (playStart == entries.length - 1 &&
          result.seasonPlaylistPath != null) {
        _seasonStageAttempts.add(
          '$resolvedSessionId|${result.seasonPlaylistPath}',
        );
      }
      setState(() {
        final activatedAt = DateTime.now();
        final timeoutSeconds = appState
            .configStore
            .current
            .playerStartupTimeoutSeconds
            .clamp(
              AppConstants.minPlayerStartupTimeoutSeconds,
              AppConstants.maxPlayerStartupTimeoutSeconds,
            )
            .toInt();
        session.activationGuard.start(
          now: activatedAt,
          timeout: Duration(seconds: timeoutSeconds),
        );
        session
          ..history = launchedHistory
          ..paused = null
          ..launching = false;
      });
      unawaited(_historyStore.upsert(launchedHistory));
      await _recordPlaybackFile(
        activeVideos[playStart].entry,
        parentPath: activeVideos[playStart].parentPath,
        playbackSessionId: resolvedSessionId,
      );
      if (!mounted || !_playbackSessions.contains(session)) return;
      _refreshPlaybackMonitor();

      final subtitle = entries[playStart].subtitle;
      final parts = <String>[
        '已启动播放器（${entries.length} 集）',
        if (subtitle != null) '字幕：${subtitle.name}',
        if (progress?.resumeSeconds != null) '续播于 ${progress!.resumeSeconds}s',
      ];
      ScaffoldMessenger.of(context).showSnackBar(
        SPNotice(
          content: AppText(parts.join(' · ')),
          duration: const Duration(seconds: 3),
        ),
      );
      if (playlistIncomplete) {
        _showLibraryError('部分特典目录未能读取，播放列表可能不完整');
      }
    } on AppException catch (e) {
      if (!mounted) return;
      if (_playbackSessions.contains(session)) {
        setState(() {
          session
            ..launching = false
            ..paused = null;
        });
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SPNotice(content: AppText(e.message)));
    }
  }

  // ── 音频播放联动（独立 M3U8、歌词、封面与进度） ─────────────

  Future<void> _playAudio(
    MediaDirectoryEntry audio, {
    String? sessionId,
  }) async {
    final appState = context.read<AppState>();
    final libraryParentPath = _currentPath;
    final player = appState.audioPlayerService;
    final historyStore = appState.audioPlaybackHistoryStore;
    final progressService = appState.audioProgressService;
    if (player == null || historyStore == null || progressService == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SPNotice(content: AppText('音频播放模块初始化失败，视频播放不受影响')));
      return;
    }
    final existingSession = sessionId == null
        ? null
        : _audioSessionById(sessionId);
    if (sessionId == null &&
        _audioPlaybackSessions
                .where(
                  (session) =>
                      (session.history.sourceId ?? _sourceId) == _sourceId,
                )
                .length >=
            AppConstants.maxPlaybackSessions) {
      await showGlassDialog<void>(
        context: context,
        builder: (dialogContext) => SPDialog(
          title: const AppText('音频播放位置已占满'),
          content: AppText(
            '当前最多同时保留 ${AppConstants.maxPlaybackSessions} 个音频会话，'
            '请先关闭或删除一个音频下边栏后再播放。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const AppText('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    if (existingSession?.deleting == true ||
        existingSession?.launching == true) {
      return;
    }

    // 与视频稳定列表相同：只取后台全量目录，不受显示排序、搜索或隐藏影响。
    final audioFiles = _files.where((file) => file.isAudio).toList();
    final clickedIndex = audioFiles.indexWhere(
      (file) => file.entryKey == audio.entryKey,
    );
    final ordered = clickedIndex < 0 ? [audio] : audioFiles;
    final subtitleInjectionEnabled =
        appState.configStore.current.subtitleInjectionEnabled;
    final entries = <AudioMediaEntry>[];
    var playStart = -1;
    for (final file in ordered) {
      if (file.entryKey == audio.entryKey) playStart = entries.length;
      final lyrics = subtitleInjectionEnabled
          ? appState.audioCompanionMatcher.findLyricsFor(file, _files)
          : null;
      final cover = appState.audioCompanionMatcher.findCoverFor(file, _files);
      entries.add(
        AudioMediaEntry(
          url: await _resolvedMediaUrl(file),
          title: file.name,
          lyrics: await _resolvedAudioCompanion(lyrics),
          coverArt: await _resolvedAudioCompanion(cover),
        ),
      );
    }
    if (entries.isEmpty || playStart < 0) return;

    final resolvedSessionId = sessionId ?? _newAudioSessionId();
    final now = DateTime.now();
    final history = AudioPlaybackHistory(
      sessionId: resolvedSessionId,
      dirCrumbs: List.of(_crumbs),
      fileName: ordered[playStart].name,
      trackIndex: playStart,
      updatedAt: now,
      createdAt: existingSession?.history.createdAt ?? now,
      playlistFileNames: ordered.map((file) => file.name).toList(),
      sourceId: _sourceId,
    );
    final session = existingSession ?? AudioPlaybackUiSession(history);
    session
      ..history = history
      ..lastSyncedPos = playStart
      ..finishPending = 0
      ..paused = null
      ..launching = true
      ..lastReportedPositionSeconds = null
      ..lastReportedDurationSeconds = null
      ..lastProgressPersistedAt = null;
    session.activationGuard.reset();
    if (mounted && existingSession == null) {
      _playbackPresenter.addAudioSession(session);
    }
    if (!await historyStore.upsert(history)) {
      if (mounted) _playbackPresenter.removeAudioSession(session);
      return;
    }

    PlaybackProgress? progress;
    try {
      if (!_isLocal) {
        await player.syncPersistedProgress(
          sessionId: resolvedSessionId,
          entries: entries,
          username: appState.username,
          password: appState.password,
          launchEpoch: existingSession?.history.launchEpoch,
        );
      }
      progress = await progressService.getProgress(
        entries[playStart].url,
        profileId: _sourceId,
      );
      if (progress != null && progress.isFinishedNearEnd()) progress = null;
    } on AppException {
      // 音频进度读取失败时从头播放，视频链路不受影响。
    }

    try {
      session.statusNotBefore = DateTime.now();
      final result = _isLocal
          ? await player.launchLocal(
              entries: entries,
              sessionId: resolvedSessionId,
              sourceId: _sourceId,
              playlistStart: playStart,
              resumeSeconds: progress?.resumeSeconds,
            )
          : await player.launch(
              entries: entries,
              sessionId: resolvedSessionId,
              playlistStart: playStart,
              resumeSeconds: progress?.resumeSeconds,
              username: appState.username,
              password: appState.password,
              lyricsLoader: (url, {required maxBytes, required timeout}) =>
                  _service.fetchFileBytes(
                    url,
                    maxBytes: maxBytes,
                    timeout: timeout,
                  ),
            );
      if (!mounted || !_audioPlaybackSessions.contains(session)) {
        await player.terminateLaunch(result);
        return;
      }
      final launchedHistory = session.history.copyWith(
        playerPid: result.process.pid,
        playerExecutablePath: result.processIdentity?.executablePath,
        clearPlayerExecutablePath: result.processIdentity == null,
        playerCreationTime: result.processIdentity?.creationTime,
        clearPlayerCreationTime: result.processIdentity == null,
        ipcPipeName: result.ipcPipeName,
        launchEpoch: result.launchEpoch,
        updatedAt: DateTime.now(),
      );
      setState(() {
        final activatedAt = DateTime.now();
        final timeoutSeconds = appState
            .configStore
            .current
            .playerStartupTimeoutSeconds
            .clamp(
              AppConstants.minPlayerStartupTimeoutSeconds,
              AppConstants.maxPlayerStartupTimeoutSeconds,
            )
            .toInt();
        session.activationGuard.start(
          now: activatedAt,
          timeout: Duration(seconds: timeoutSeconds),
        );
        session
          ..history = launchedHistory
          ..paused = null
          ..launching = false;
      });
      _refreshAudioPlaybackMonitor();
      unawaited(historyStore.upsert(launchedHistory));
      unawaited(
        _recordPlaybackFile(
          audio,
          parentPath: libraryParentPath,
          playbackSessionId: resolvedSessionId,
        ),
      );

      final current = entries[playStart];
      final parts = <String>[
        '已启动音频播放器（${entries.length} 首）',
        if (current.lyrics != null) '歌词：${current.lyrics!.name}',
        if (current.coverArt != null) '封面：${current.coverArt!.name}',
        if (progress?.resumeSeconds != null) '续播于 ${progress!.resumeSeconds}s',
      ];
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SPNotice(content: AppText(parts.join(' · '))));
    } on AppException catch (error) {
      if (!mounted) return;
      if (_audioPlaybackSessions.contains(session)) {
        setState(() {
          session
            ..launching = false
            ..paused = null;
        });
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SPNotice(content: AppText(error.message)));
    } catch (_) {
      if (!mounted) return;
      if (_audioPlaybackSessions.contains(session)) {
        setState(() {
          session
            ..launching = false
            ..paused = null;
        });
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SPNotice(content: AppText('音频播放模块发生错误，视频播放不受影响')));
    }
  }

  void _syncAudioPlaybackSessions() {
    for (final session in List<AudioPlaybackUiSession>.of(
      _audioPlaybackSessions,
    )) {
      if (session.syncBusy || session.deleting || session.launching) continue;
      session.syncBusy = true;
      unawaited(
        _syncAudioPlaybackSession(session).whenComplete(() {
          session.syncBusy = false;
          _refreshAudioPlaybackMonitor();
        }),
      );
    }
  }

  Future<void> _syncAudioPlaybackSession(AudioPlaybackUiSession session) async {
    if (!_audioPlaybackSessions.contains(session)) return;
    final names = session.playlistFileNames;
    if (names.isEmpty) return;
    final appState = context.read<AppState>();
    final store = appState.audioPlaybackHistoryStore;
    final player = appState.audioPlayerService;
    if (store == null || player == null) return;
    final sessionId = session.history.sessionId;
    final now = DateTime.now();
    final guard = session.activationGuard;
    if (guard.shouldProbe(now)) {
      final running = await player.isPlayerRunning(sessionId);
      guard.recordProbe(now: now, running: running);
    }
    var running = guard.lastKnownRunning ?? false;
    if (!_audioPlaybackSessions.contains(session)) return;

    final Directory? dataDir = await _sessionCacheDirectory;
    if (dataDir == null) return;
    final statusFile = File(
      p.join(
        dataDir.path,
        AudioPlayerService.sessionStatusFileName(
          sessionId,
          launchEpoch: session.history.launchEpoch,
        ),
      ),
    );
    DateTime? statusModifiedAt;
    try {
      final status = await statusFile.stat();
      if (status.type == FileSystemEntityType.file) {
        statusModifiedAt = status.modified;
      }
    } catch (_) {
      // 音频状态文件尚未创建或正在替换，留待下一轮。
    }
    List<String>? lines;
    if (statusModifiedAt?.isAfter(session.statusNotBefore) ?? false) {
      try {
        lines = await statusFile.readAsLines();
      } catch (_) {
        // MPV 正在写状态文件时留待下一轮。
      }
    }

    _rememberAudioProgress(session, lines, running: running);
    final loadedPos = lines == null || lines.isEmpty
        ? null
        : int.tryParse(lines.first.trim());
    final hasLoaded =
        loadedPos != null &&
        loadedPos >= 0 &&
        loadedPos < names.length &&
        lines!.length >= 2 &&
        lines[1].trim().isNotEmpty;
    if (guard.isWaiting && hasLoaded) {
      guard.confirmActivation();
      running = true;
      guard.recordProbe(now: DateTime.now(), running: true);
    }
    if (guard.isWaiting) {
      if (guard.hasTimedOut(now)) {
        await _removeAudioPlaybackSession(session, terminateProcess: true);
      } else if (session.paused != null && mounted) {
        setState(() => session.paused = null);
      }
      return;
    }

    if (!running) {
      await player.waitForExitSync(sessionId);
      if (!_audioPlaybackSessions.contains(session)) return;
      final pos = lines == null || lines.isEmpty
          ? null
          : int.tryParse(lines.first.trim());
      final naturallyFinished =
          _isFreshStatus(statusModifiedAt) &&
          (_isOwnedIdleCompletion(
                lines,
                expectedLastPos: names.length - 1,
                expectedEpoch: session.history.launchEpoch,
              ) ||
              (pos == -1 && session.lastSyncedPos == names.length - 1));
      var completed = _hasReachedAudioCompletion(session, lines);
      if (!completed) {
        completed = await _hasPersistedAudioCompletion(session, lines);
      }
      if (naturallyFinished || completed) {
        await _removeAudioPlaybackSession(session, terminateProcess: false);
        return;
      }
      final needsHistoryUpdate =
          session.history.playerPid != null ||
          session.history.ipcPipeName != null;
      if (needsHistoryUpdate) {
        session.history = session.history.copyWith(
          clearPlayerPid: true,
          clearIpcPipeName: true,
          updatedAt: DateTime.now(),
        );
        await store.upsert(session.history);
      }
      if (session.paused != null && mounted) {
        setState(() => session.paused = null);
      }
      return;
    }

    if (lines == null || lines.length < 2) return;
    final pos = int.tryParse(lines.first.trim());
    if (pos == null || pos < 0 || pos >= names.length) {
      final reachedLast =
          session.lastSyncedPos == names.length - 1 ||
          _isOwnedIdleCompletion(
            lines,
            expectedLastPos: names.length - 1,
            expectedEpoch: session.history.launchEpoch,
          );
      if (pos == -1 && reachedLast && _isFreshStatus(statusModifiedAt)) {
        session.finishPending++;
        if (session.finishPending >= 2) {
          session.finishPending = 0;
          await _removeAudioPlaybackSession(session, terminateProcess: true);
        }
      } else {
        session.finishPending = 0;
      }
      return;
    }
    session.finishPending = 0;
    final paused = lines.length >= 3 ? lines[2].trim() == '1' : false;
    final pauseChanged = paused != session.paused;
    final mediaChanged = pos != session.lastSyncedPos;
    if (mediaChanged) {
      try {
        await player.syncActiveProgress(sessionId);
      } catch (_) {
        // 切歌进度同步失败不影响播放列表和下边栏更新。
      }
    }
    final progressService = appState.audioProgressService;
    if (progressService != null) {
      await _persistLiveProgress(
        service: progressService,
        profileId: session.history.sourceId ?? _sourceId,
        lines: lines,
        running: running,
        force: pauseChanged || mediaChanged,
        lastPersistedAt: session.lastProgressPersistedAt,
        onPersisted: (value) => session.lastProgressPersistedAt = value,
      );
    }
    if (paused != session.paused && mounted) {
      setState(() => session.paused = paused);
    }
    if (pos == session.lastSyncedPos) return;
    session.lastSyncedPos = pos;
    session.history = session.history.copyWith(
      fileName: names[pos],
      trackIndex: pos,
      updatedAt: DateTime.now(),
    );
    await store.upsert(session.history);
    unawaited(
      _recordPlaybackByName(
        dirCrumbs: session.history.dirCrumbs,
        fileName: names[pos],
        audio: true,
        playbackSessionId: session.history.sessionId,
        playbackSourceId: session.history.sourceId,
      ),
    );
    if (mounted && _audioPlaybackSessions.contains(session)) setState(() {});
  }

  void _rememberAudioProgress(
    AudioPlaybackUiSession session,
    List<String>? lines, {
    required bool running,
  }) {
    if (lines == null || lines.length < 5) return;
    final playlistPos = int.tryParse(lines.first.trim());
    if (playlistPos == null || playlistPos < 0 || lines[1].trim().isEmpty) {
      return;
    }
    final position = double.tryParse(lines[3].trim());
    final duration = double.tryParse(lines[4].trim());
    if (position != null && position >= 0) {
      final exitZero =
          !running &&
          position == 0 &&
          session.lastReportedPositionSeconds != null;
      if (!exitZero) session.lastReportedPositionSeconds = position;
    }
    if (duration != null && duration > 0) {
      session.lastReportedDurationSeconds = duration;
    }
  }

  Future<void> _persistLiveProgress({
    required PlaybackProgressService service,
    required String? profileId,
    required List<String> lines,
    required bool running,
    required bool force,
    required DateTime? lastPersistedAt,
    required ValueChanged<DateTime> onPersisted,
    String? videoSessionId,
  }) async {
    if (!running || lines.length < 5) return;
    final url = lines[1].trim();
    final position = double.tryParse(lines[3].trim());
    final duration = double.tryParse(lines[4].trim());
    if (url.isEmpty || position == null || position < 0) return;
    final now = DateTime.now();
    if (!force &&
        lastPersistedAt != null &&
        now.difference(lastPersistedAt) < const Duration(seconds: 10)) {
      return;
    }
    try {
      await service.saveProgress(
        url: stripUserInfo(url),
        positionMs: (position * 1000).round(),
        durationMs: duration != null && duration > 0
            ? (duration * 1000).round()
            : null,
        profileId: profileId,
      );
      onPersisted(now);
      if (videoSessionId != null) {
        final session = _sessionById(videoSessionId);
        if (session != null) {
          await _saveStrmPlaybackProgress(
            session,
            playlistIndex: int.parse(lines[0].trim()),
            positionMs: (position * 1000).round(),
            durationMs: duration != null && duration > 0
                ? (duration * 1000).round()
                : null,
          );
        }
      }
    } on AppException {
      // 运行中进度属于旁路刷新，失败时仍由退出同步提供最终进度。
    }
  }

  bool _hasReachedAudioCompletion(
    AudioPlaybackUiSession session,
    List<String>? lines,
  ) => hasReachedExitCompletion(
    positionSeconds: lines != null && lines.length >= 5
        ? double.tryParse(lines[3].trim())
        : null,
    durationSeconds: lines != null && lines.length >= 5
        ? double.tryParse(lines[4].trim())
        : null,
    fallbackPositionSeconds: session.lastReportedPositionSeconds,
    fallbackDurationSeconds: session.lastReportedDurationSeconds,
  );

  Future<void> _saveStrmPlaybackProgress(
    PlaybackUiSession session, {
    int? playlistIndex,
    int? positionMs,
    int? durationMs,
  }) async {
    final index = playlistIndex ?? session.history.videoIndex;
    final name = session.playlistFileNames[index];
    final store = _mediaLibraryStore;
    if (!name.toLowerCase().endsWith('.strm') || store == null) return;
    final sourceId = session.history.sourceId ?? _sourceId;
    if (positionMs == null && session.lastReportedUrl != null) {
      final progress = await _progressService.getResumeProgress(
        session.lastReportedUrl!,
        profileId: sourceId,
      );
      positionMs = progress?.positionMs;
      durationMs = progress?.durationMs;
    }
    if (positionMs == null) return;
    try {
      await store.updateStrmProgress(
        sourceId: sourceId,
        playbackSessionId: session.history.sessionId,
        fileName: name,
        playlistIndex: index,
        positionMs: positionMs,
        durationMs: durationMs,
      );
    } on AppException catch (error) {
      _showLibraryError(error.message);
    }
  }

  Future<bool> _hasPersistedAudioCompletion(
    AudioPlaybackUiSession session,
    List<String>? lines,
  ) async {
    if (lines == null || lines.length < 2 || lines[1].trim().isEmpty) {
      return false;
    }
    final progressService = context.read<AppState>().audioProgressService;
    if (progressService == null) return false;
    try {
      final progress = await progressService.getProgress(
        stripUserInfo(lines[1].trim()),
        profileId: session.history.sourceId ?? _sourceId,
      );
      final updatedAt = progress?.updatedAt;
      if (progress == null ||
          updatedAt == null ||
          updatedAt.isBefore(session.statusNotBefore)) {
        return false;
      }
      return progress.hasReachedFraction();
    } on AppException {
      return false;
    }
  }

  Future<void> _removeAudioPlaybackSession(
    AudioPlaybackUiSession session, {
    required bool terminateProcess,
  }) async {
    if (session.deleting || !_audioPlaybackSessions.contains(session)) return;
    session.deleting = true;
    if (mounted) setState(() {});
    final appState = context.read<AppState>();
    final player = appState.audioPlayerService;
    final store = appState.audioPlaybackHistoryStore;
    if (terminateProcess) {
      final termination = await player?.terminateSession(
        session.history.sessionId,
      );
      if (termination != null && !termination.isSafeToRelaunch) {
        session.deleting = false;
        if (mounted) {
          setState(() {});
          ScaffoldMessenger.of(context).showSnackBar(
            const SPNotice(content: AppText('无法确认音频播放器身份，已保留会话且未终止进程')),
          );
        }
        return;
      }
    } else {
      player?.releaseSession(session.history.sessionId);
    }
    await store?.remove(session.history.sessionId);
    if (!mounted) return;
    _playbackPresenter.removeAudioSession(session);
    _refreshAudioPlaybackMonitor();
  }

  Future<void> _resumeAudioPlaybackSession(
    AudioPlaybackUiSession session,
  ) async {
    if (session.launching || session.deleting) return;
    final history = session.history;
    if (history.sourceId != null && history.sourceId != _sourceId) {
      await _openLibraryItem(
        MediaLibraryItem(
          sourceId: history.sourceId!,
          sourceKind: history.sourceId!.startsWith('local:')
              ? MediaSourceKind.local
              : MediaSourceKind.webdav,
          parentPath: history.dirCrumbs.join('/'),
          name: history.fileName,
          kind: MediaLibraryKind.audio,
        ),
        resumeSessionId: history.sessionId,
      );
      return;
    }
    _directorySearchController.clear();
    _directorySearchFocusNode.unfocus();
    _directoryBrowser.navigateToPath(history.dirCrumbs.join('/'));
    try {
      await _load();
    } on AppException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SPNotice(content: AppText(error.message)));
      return;
    }
    if (!mounted) return;
    final audioFiles = _files.where((file) => file.isAudio).toList();
    if (audioFiles.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SPNotice(content: AppText('该目录下没有可播放的音频')));
      return;
    }
    var index = audioFiles.indexWhere((file) => file.name == history.fileName);
    if (index < 0) index = history.trackIndex.clamp(0, audioFiles.length - 1);
    await _playAudio(audioFiles[index], sessionId: history.sessionId);
  }

  void _syncPlaybackSessions() {
    for (final session in List<PlaybackUiSession>.of(_playbackSessions)) {
      if (session.syncBusy || session.deleting || session.launching) continue;
      session.syncBusy = true;
      final operation = session.history.kind == PlaybackHistoryKind.iso
          ? _syncIsoPlaybackSession(session)
          : _syncPlaybackSession(session);
      unawaited(
        operation.whenComplete(() {
          session.syncBusy = false;
          _refreshPlaybackMonitor();
        }),
      );
    }
  }

  Future<void> _syncIsoPlaybackSession(PlaybackUiSession session) async {
    if (!_playbackSessions.contains(session)) return;
    final service = _isoPlaybackService;
    if (service == null) return;
    final history = session.history;
    final snapshot = await service.sessionSnapshot(
      history.isoSessionDirectoryPath,
    );
    if (!_playbackSessions.contains(session)) return;
    if (snapshot.liveness == PlayerProcessLiveness.unknown) return;
    if (snapshot.liveness == PlayerProcessLiveness.alive) {
      final paused = snapshot.paused;
      if (paused != null && paused != session.paused && mounted) {
        setState(() => session.paused = paused);
      }
      return;
    }
    final failureMessage = snapshot.failureMessage;
    if (failureMessage != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SPNotice(
          content: Text(
            context.l10n.format('ISO 流式播放失败：{message}', {
              'message': context.l10n.text(failureMessage),
            }),
          ),
        ),
      );
    }

    final isoKey = history.isoKey;
    if (isoKey != null && history.playbackMode != PlaybackMode.webdavHdmvMenu) {
      final progress = await service.getLibraryProgressByKey(
        isoKey,
        playbackMode: history.playbackMode,
      );
      if (!_playbackSessions.contains(session)) return;
      if (progress == null) {
        await _removePlaybackSession(session, terminateProcess: false);
        return;
      }
    }
    final needsHistoryUpdate =
        history.playerPid != null || history.isoSessionDirectoryPath != null;
    if (needsHistoryUpdate) {
      session.history = history.copyWith(
        clearPlayerPid: true,
        clearIsoSessionDirectoryPath: true,
        updatedAt: DateTime.now(),
      );
      await _historyStore.upsert(session.history);
    }
    if (session.paused != null && mounted) {
      setState(() => session.paused = null);
    }
  }

  /// 独立同步一个下边栏对应的 PID、状态文件、暂停状态与切集位置。
  Future<void> _syncPlaybackSession(PlaybackUiSession session) async {
    if (!_playbackSessions.contains(session)) return;
    if (session.history.playerPid == null &&
        session.history.ipcPipeName == null &&
        !session.activationGuard.isWaiting) {
      return;
    }
    var names = session.playlistFileNames;
    if (names.isEmpty) return;
    final store = _historyStore;
    if (session.history.videoPlaylistMode == VideoPlaylistMode.implicit) {
      final latest = store.sessions
          .where((h) => h.sessionId == session.history.sessionId)
          .firstOrNull;
      if (latest == null) {
        _playbackPresenter.removeVideoSession(session);
        return;
      }
      session.history = latest;
    }
    final playerService = _playerService;
    final sessionId = session.history.sessionId;
    final now = DateTime.now();
    final guard = session.activationGuard;
    if (guard.shouldProbe(now)) {
      final probedRunning = await playerService.isPlayerRunning(sessionId);
      guard.recordProbe(now: now, running: probedRunning);
    }
    var running = guard.lastKnownRunning ?? false;
    if (!_playbackSessions.contains(session)) return;

    final File statusFile;
    try {
      final dataDir = await _sessionCacheDirectory; // mpv 状态文件
      if (dataDir == null) return;
      statusFile = File(
        p.join(
          dataDir.path,
          ExternalPlayerService.sessionStatusFileName(
            sessionId,
            launchEpoch: session.history.launchEpoch,
          ),
        ),
      );
    } catch (_) {
      return;
    }
    DateTime? statusModifiedAt;
    try {
      final status = await statusFile.stat();
      if (status.type == FileSystemEntityType.file) {
        statusModifiedAt = status.modified;
      }
    } catch (_) {
      // 状态文件尚未创建或正在被替换，留待下一轮。
    }
    List<String>? lines;
    if (_isStatusForSession(statusModifiedAt, session)) {
      try {
        lines = await statusFile.readAsLines();
      } catch (_) {
        // MPV 正在写状态文件时留待下一轮读取。
      }
    }
    if (!mounted || !_playbackSessions.contains(session)) return;
    final pendingPlaylist = session.history.nextSeasonPlaylistPath;
    final reportedPos = lines == null || lines.isEmpty
        ? null
        : int.tryParse(lines[0].trim());
    final cachedLoadedPos = lines != null && lines.length > 22
        ? int.tryParse(lines[22].trim())
        : null;
    final activationPos = reportedPos != null && reportedPos >= 0
        ? reportedPos
        : (!running &&
                  lines != null &&
                  lines.length > 1 &&
                  lines[1].trim().isEmpty
              ? cachedLoadedPos
              : null);
    if (pendingPlaylist != null &&
        lines != null &&
        lines.length > 21 &&
        activationPos != null &&
        activationPos >= 0 &&
        (lines[1].trim().isNotEmpty || !running) &&
        _sameSeasonPlaylist(lines[21].trim(), pendingPlaylist)) {
      await _activateNextSeason(session, activationPos);
      if (!mounted || !_playbackSessions.contains(session)) return;
      names = session.playlistFileNames;
    }

    if (lines != null && statusModifiedAt != null) {
      final i = int.tryParse(lines.first);
      if (i != null &&
          i >= 0 &&
          i < session.history.playlistRelativePaths.length &&
          !playerService.acceptsVideoSample(
            session.history.sourceId ?? _sourceId,
            session.history.playlistRelativePaths[i],
            statusModifiedAt,
          )) {
        return;
      }
    }
    if (running &&
        session.history.videoPlaylistMode == VideoPlaylistMode.implicit &&
        lines != null &&
        (lines.length < 26 || lines[25] != '1')) {
      return;
    }
    final loadedPos = lines == null || lines.isEmpty
        ? null
        : int.tryParse(lines[0].trim());
    final mediaChanged =
        loadedPos != null &&
        loadedPos >= 0 &&
        loadedPos < names.length &&
        loadedPos != session.lastSyncedPos;
    if (mediaChanged) {
      // 切集后的零秒或未知进度不能回退到上一集的片尾采样。
      session.lastReportedPositionSeconds = null;
      session.lastReportedUrl = null;
      session.lastReportedDurationSeconds = null;
    }
    _rememberReportedProgress(session, lines, running: running);
    final hasLoadedCurrentMedia =
        loadedPos != null &&
        loadedPos >= 0 &&
        loadedPos < names.length &&
        lines!.length >= 2 &&
        lines[1].trim().isNotEmpty;
    final isMpvSession = session.history.ipcPipeName != null;
    if (guard.isWaiting && hasLoadedCurrentMedia) {
      guard.confirmActivation();
      // 状态文件可能先于进程探测结果到达。本轮直接视为已运行，
      // 下一次 1 秒探测再确认进程存活，避免命中短暂 false 缓存。
      running = true;
      guard.recordProbe(now: DateTime.now(), running: true);
    } else if (guard.isWaiting && !isMpvSession && running) {
      guard.confirmActivation();
    }

    // MPV 进程已创建但尚未写出首个 file-loaded 状态时，保留下边栏并
    // 显示“继续播放”。每 1 秒只探测一次进程；超过配置期限仍未激活
    // 才终止对应进程并清理该会话。
    if (guard.isWaiting) {
      if (guard.hasTimedOut(now)) {
        await _removePlaybackSession(session, terminateProcess: true);
      } else if (session.paused != null && mounted) {
        setState(() => session.paused = null);
      }
      return;
    }

    // 进程退出后直接收敛为“完成”或“继续播放”，不再应用残留状态文件
    // 中的 pause 值，避免两个状态在轮询中互相覆盖而闪烁。
    if (!running) {
      await playerService.waitForExitSync(sessionId);
      if (!_playbackSessions.contains(session)) return;
      final pos = lines == null || lines.isEmpty
          ? null
          : int.tryParse(lines[0].trim());
      final naturallyFinished =
          _isFreshStatus(statusModifiedAt) &&
          (_isOwnedIdleCompletion(
                lines,
                expectedLastPos: names.length - 1,
                expectedEpoch: session.history.launchEpoch,
              ) ||
              (pos == -1 && session.lastSyncedPos == names.length - 1));
      final currentPos = pos != null && pos >= 0 && pos < names.length
          ? pos
          : session.lastSyncedPos;
      final isLastItem = currentPos == names.length - 1;
      var reachedCompletion = _hasReachedCompletionThreshold(session, lines);
      if (!reachedCompletion) {
        reachedCompletion = await _hasPersistedCompletionThreshold(
          session,
          lines,
        );
      }
      if (naturallyFinished || (isLastItem && reachedCompletion)) {
        await _removePlaybackSession(
          session,
          terminateProcess: false,
          completed: true,
        );
        return;
      }

      // shutdown 时 path 可能已清空，仍按本会话有效的 playlist-pos 收敛历史。
      if (reachedCompletion) {
        await _advanceCompletedVideoSession(
          session,
          session.history.pendingVideoIndex ?? currentPos + 1,
        );
        if (!mounted || !_playbackSessions.contains(session)) return;
      } else if (mediaChanged) {
        await _updateVideoPlaybackHistory(session, loadedPos);
        if (!mounted || !_playbackSessions.contains(session)) return;
      }
      session.finishPending = 0;
      await _saveStrmPlaybackProgress(session);
      final needsHistoryUpdate =
          session.history.playerPid != null ||
          session.history.ipcPipeName != null;
      if (needsHistoryUpdate) {
        session.history = session.history.copyWith(
          clearPlayerPid: true,
          clearIpcPipeName: true,
          updatedAt: DateTime.now(),
        );
        await store.upsert(session.history);
      }
      if (session.paused != null && mounted) {
        setState(() => session.paused = null);
      }
      return;
    }

    if (lines == null) return;
    if (lines.length < 2) return;
    if (session.history.videoPlaylistMode == VideoPlaylistMode.implicit &&
        playerService.hasPendingVideo(sessionId)) {
      session.finishPending = 0;
      if (session.paused != null && mounted) {
        setState(() => session.paused = null);
      }
      return;
    }
    final pos = int.tryParse(lines[0].trim());
    if (pos == null || pos < 0 || pos >= names.length) {
      if (session.history.nextSeasonPlaylistPath != null && running) {
        session.finishPending = 0;
        return;
      }
      final reachedSortedLast =
          session.lastSyncedPos == names.length - 1 ||
          _isOwnedIdleCompletion(
            lines,
            expectedLastPos: names.length - 1,
            expectedEpoch: session.history.launchEpoch,
          );
      if (pos == -1 && reachedSortedLast && _isFreshStatus(statusModifiedAt)) {
        session.finishPending++;
        if (session.finishPending >= 2) {
          session.finishPending = 0;
          await _removePlaybackSession(
            session,
            terminateProcess: true,
            completed: true,
          );
        }
      } else {
        session.finishPending = 0;
      }
      return;
    }
    session.finishPending = 0;

    final paused = lines.length >= 3 ? lines[2].trim() == '1' : false;
    final pauseChanged = paused != session.paused;
    if (mediaChanged) {
      try {
        await playerService.syncActiveProgress(sessionId);
      } catch (_) {
        // 切集进度同步失败不影响播放列表和下边栏更新。
      }
    }
    if (!mounted || !_playbackSessions.contains(session)) return;
    await _persistLiveProgress(
      service: _progressService,
      videoSessionId: sessionId,
      profileId: session.history.sourceId ?? _sourceId,
      lines: lines,
      running: running,
      force: pauseChanged || mediaChanged,
      lastPersistedAt: session.lastProgressPersistedAt,
      onPersisted: (value) => session.lastProgressPersistedAt = value,
    );
    if (paused != session.paused && mounted) {
      setState(() => session.paused = paused);
    }

    if (!mounted || !_playbackSessions.contains(session)) return;
    final seasonPlaylist = session.history.seasonPlaylistPath;
    if (running &&
        pos >= names.length - 2 &&
        seasonPlaylist != null &&
        session.history.nextSeasonPlaylistPath == null) {
      unawaited(
        _stageFollowingSeason(
          session,
          session.history.dirCrumbs.join('/'),
          seasonPlaylist,
        ).then((_) {}),
      );
    }

    if (pos == session.lastSyncedPos) return;
    await _updateVideoPlaybackHistory(session, pos);
  }

  Future<void> _advanceCompletedVideoSession(
    PlaybackUiSession session,
    int nextPos,
  ) async {
    session
      ..lastReportedPositionSeconds = null
      ..lastReportedUrl = null
      ..lastReportedDurationSeconds = null;
    final appState = context.read<AppState>();
    final history = session.history;
    final name = session.playlistFileNames[nextPos];
    final sourceId = history.sourceId ?? _sourceId;
    if (!name.toLowerCase().endsWith('.strm')) {
      final path =
          history.playlistRelativePaths.length ==
              history.playlistFileNames.length
          ? history.playlistRelativePaths[nextPos]
          : [...history.dirCrumbs, name].join('/');
      String? url;
      if (sourceId.startsWith('local:')) {
        url = _localSourceFor(sourceId)?.lexicalPath(path);
      } else {
        final serverUrl = sourceId == _sourceId
            ? _service.baseUrl
            : appState.configStore.current.profiles
                  .where((profile) => profile.profileId == sourceId)
                  .firstOrNull
                  ?.serverUrl;
        final parent = normalizeLibraryPath(
          p.posix.dirname(path).replaceFirst(RegExp(r'^\.$'), ''),
        );
        final file = appState.directoryCache
            .visitedDirectories(sourceId)
            .where((snapshot) => normalizeLibraryPath(snapshot.path) == parent)
            .expand((snapshot) => snapshot.entries)
            .where((file) => file.name == name)
            .firstOrNull;
        if (serverUrl != null && file != null) {
          url = stripUserInfo(resolveHref(serverUrl, file.href));
        }
      }
      if (url != null &&
          await _progressService.getResumeProgress(url, profileId: sourceId) ==
              null) {
        await _progressService.saveProgress(
          url: url,
          positionMs: 0,
          profileId: sourceId,
        );
      }
    }
    if (!mounted || !_playbackSessions.contains(session)) return;
    await _updateVideoPlaybackHistory(session, nextPos);
  }

  Future<void> _updateVideoPlaybackHistory(
    PlaybackUiSession session,
    int pos,
  ) async {
    session.lastSyncedPos = pos;
    final history = session.history.copyWith(
      fileName: session.playlistFileNames[pos],
      videoIndex: pos,
      updatedAt: DateTime.now(),
    );
    session.history = history;
    await _historyStore.upsert(history);
    if (!mounted || !_playbackSessions.contains(session)) return;
    final path =
        history.playlistRelativePaths.length == history.playlistFileNames.length
        ? history.playlistRelativePaths[pos]
        : null;
    final parent = path == null
        ? history.dirCrumbs.join('/')
        : p.posix.dirname(path).replaceFirst(RegExp(r'^\.$'), '');
    await _recordPlaybackByName(
      dirCrumbs: parent.isEmpty ? const [] : parent.split('/'),
      fileName: history.fileName,
      audio: false,
      playbackSessionId: history.sessionId,
      playbackSourceId: history.sourceId,
    );
    await _saveStrmPlaybackProgress(session);
    if (!mounted || !_playbackSessions.contains(session)) return;
    setState(() {});
  }

  bool _sameSeasonPlaylist(String left, String right) =>
      left.replaceAll('\\', '/').toLowerCase() ==
      right.replaceAll('\\', '/').toLowerCase();

  Future<void> _activateNextSeason(PlaybackUiSession session, int pos) async {
    final old = session.history;
    final root = old.nextSeasonRootPath;
    final playlist = old.nextSeasonPlaylistPath;
    final names = old.nextSeasonFileNames;
    final paths = old.nextSeasonRelativePaths;
    if (root == null ||
        playlist == null ||
        names.isEmpty ||
        paths.length != names.length ||
        pos < 0 ||
        pos >= names.length) {
      return;
    }
    await _playerService.syncActiveProgress(old.sessionId);
    _playerService.commitSeasonTransition(
      old.sessionId,
      playlistPath: playlist,
      playlistLength: names.length,
    );
    final history = old.copyWith(
      dirCrumbs: root.split('/'),
      fileName: names[pos],
      videoIndex: pos,
      playlistFileNames: names,
      playlistRelativePaths: paths,
      seasonPlaylistPath: playlist,
      clearNextSeason: true,
      updatedAt: DateTime.now(),
    );
    session
      ..history = history
      ..lastSyncedPos = pos
      ..finishPending = 0
      ..lastReportedPositionSeconds = null
      ..lastReportedUrl = null
      ..lastReportedDurationSeconds = null;
    await _historyStore.upsert(history);
    if (!mounted || !_playbackSessions.contains(session)) return;
    await _recordPlaybackByName(
      dirCrumbs: root.split('/'),
      fileName: names[pos],
      audio: false,
      playbackSessionId: old.sessionId,
      playbackSourceId: old.sourceId,
    );
    if (!mounted || !_playbackSessions.contains(session)) return;
    setState(() {});
    unawaited(_stageFollowingSeason(session, root, playlist).then((_) {}));
  }

  Future<String?> _stageFollowingSeason(
    PlaybackUiSession session,
    String rootPath,
    String playlistPath, {
    bool retry = false,
  }) {
    if (session.history.playbackScope == VideoPlaybackScope.singleItem ||
        session.history.sourceId != _sourceId ||
        !context
            .read<AppState>()
            .configStore
            .current
            .autoSeasonTransitionEnabled) {
      return Future.value(null);
    }
    final key = '${session.history.sessionId}|$playlistPath';
    final running = _seasonStageTasks[key];
    if (running != null) return running;
    if (!retry && !_seasonStageAttempts.add(key)) {
      return Future.value(null);
    }
    _seasonStageAttempts.add(key);
    final task = _prepareAndStageFollowingSeason(
      session,
      rootPath,
      playlistPath,
    );
    _seasonStageTasks[key] = task;
    return task.whenComplete(() => _seasonStageTasks.remove(key));
  }

  Future<String?> _prepareAndStageFollowingSeason(
    PlaybackUiSession session,
    String rootPath,
    String playlistPath,
  ) async {
    try {
      final rootEntries = await _source
          .fetchDirectory(rootPath)
          .timeout(SeasonVideoPlaylistCollector.lookupTimeout);
      if (!mounted || !_playbackSessions.contains(session)) return null;
      final next = await _prepareNextSeason(rootPath, rootEntries);
      if (next == null ||
          !mounted ||
          !_playbackSessions.contains(session) ||
          session.history.seasonPlaylistPath != playlistPath) {
        return null;
      }
      final stagedPath = await _playerService.stageNextSeason(
        session.history.sessionId,
        season: next.playback,
        currentPlaylistPath: playlistPath,
        username: _isLocal ? null : _service.credentialSnapshot.username,
        password: _isLocal ? null : _service.credentialSnapshot.password,
        serverUrl: _isLocal ? null : _service.baseUrl,
        webDavFontLoader: _isLocal ? null : _service.fetchFileBytes,
        webDavFontFileLoader: _isLocal ? null : _service.downloadFile,
      );
      if (stagedPath == null ||
          !mounted ||
          !_playbackSessions.contains(session) ||
          session.history.seasonPlaylistPath != playlistPath) {
        return null;
      }
      final updated = session.history.copyWith(
        nextSeasonRootPath: next.rootPath,
        nextSeasonFileNames: next.items.map((item) => item.entry.name).toList(),
        nextSeasonRelativePaths: next.items.map((item) => item.path).toList(),
        nextSeasonPlaylistPath: stagedPath,
        updatedAt: DateTime.now(),
      );
      session.history = updated;
      await _historyStore.upsert(updated);
      return stagedPath;
    } on AppException catch (error) {
      // 候选季读取失败时当前播放不受影响。
      debugPrint('Next season staging skipped: $error');
    } on FileSystemException catch (error) {
      // 本地目录发生变化时当前播放不受影响。
      debugPrint('Next season staging skipped: $error');
    } on TimeoutException catch (error) {
      // 网络候选季超时后保持当前播放。
      debugPrint('Next season staging skipped: $error');
    } on StateError catch (error) {
      // MPV IPC 断开时保留当前季播放。
      debugPrint('Next season staging failed: $error');
    }
    return null;
  }

  /// 只供“MPV 进程已经退出”分支使用；运行中的 99% 不提前隐藏。
  bool _hasReachedCompletionThreshold(
    PlaybackUiSession session,
    List<String>? lines,
  ) {
    final positionSeconds = lines != null && lines.length >= 5
        ? double.tryParse(lines[3].trim())
        : null;
    final durationSeconds = lines != null && lines.length >= 5
        ? double.tryParse(lines[4].trim())
        : null;
    return hasReachedExitCompletion(
      positionSeconds: positionSeconds,
      durationSeconds: durationSeconds,
      fallbackPositionSeconds: session.lastReportedPositionSeconds,
      fallbackDurationSeconds: session.lastReportedDurationSeconds,
    );
  }

  void _rememberReportedProgress(
    PlaybackUiSession session,
    List<String>? lines, {
    required bool running,
  }) {
    if (lines == null || lines.length < 5) return;
    final playlistPos = int.tryParse(lines[0].trim());
    if (playlistPos == null || playlistPos < 0 || lines[1].trim().isEmpty) {
      return;
    }
    session.lastReportedUrl = stripUserInfo(lines[1].trim());
    final position = double.tryParse(lines[3].trim());
    final duration = double.tryParse(lines[4].trim());
    if (position != null && position >= 0) {
      final exitZero =
          !running &&
          position == 0 &&
          session.lastReportedPositionSeconds != null;
      if (!exitZero) {
        session.lastReportedPositionSeconds = position;
      }
    }
    if (duration != null && duration > 0) {
      session.lastReportedDurationSeconds = duration;
    }
  }

  /// 兼容旧版三行状态脚本：进程退出同步 watch_later 后，从进度库复核。
  /// 只接受本次会话启动后的记录，避免旧的 99% 进度误清当前会话。
  Future<bool> _hasPersistedCompletionThreshold(
    PlaybackUiSession session,
    List<String>? lines,
  ) async {
    if (lines == null || lines.length < 2 || lines[1].trim().isEmpty) {
      return false;
    }
    try {
      final progress = await _progressService.getProgress(
        stripUserInfo(lines[1].trim()),
        profileId: session.history.sourceId ?? _sourceId,
      );
      final updatedAt = progress?.updatedAt;
      if (progress == null ||
          updatedAt == null ||
          updatedAt.isBefore(session.statusNotBefore)) {
        return false;
      }
      return progress.hasReachedFraction();
    } on AppException {
      return false;
    }
  }

  bool _isStatusForSession(
    DateTime? statusModifiedAt,
    PlaybackUiSession session,
  ) => statusModifiedAt?.isAfter(session.statusNotBefore) ?? false;

  bool _isOwnedIdleCompletion(
    List<String>? lines, {
    required int expectedLastPos,
    required String? expectedEpoch,
  }) {
    if (expectedEpoch == null) return false;
    return MpvIdleCompletionMarker.parse(lines)?.matches(
          expectedLastPlaylistPos: expectedLastPos,
          expectedLaunchEpoch: expectedEpoch,
        ) ??
        false;
  }

  /// 状态文件是否「新鲜」（最近 [Duration] 内写入）。
  ///
  /// mpv 的 current 脚本在 file-loaded / idle 时写状态文件；「播完」
  /// 的 `-1` 标记只有刚写出（轮询间隔内）才是本次播放的真实结果，
  /// 陈旧文件不应触发清除「继续播放」历史。
  bool _isFreshStatus(
    DateTime? statusModifiedAt, {
    Duration maxAge = const Duration(seconds: 10),
  }) =>
      statusModifiedAt != null &&
      DateTime.now().difference(statusModifiedAt) <= maxAge;

  Future<bool> _removePlaybackSession(
    PlaybackUiSession session, {
    required bool terminateProcess,
    bool completed = false,
  }) async {
    if (session.deleting || !_playbackSessions.contains(session)) return false;
    session.deleting = true;
    if (mounted) setState(() {});
    final appState = context.read<AppState>();
    final sessionId = session.history.sessionId;
    if (session.history.kind == PlaybackHistoryKind.iso) {
      if (terminateProcess && session.history.playerPid != null) {
        final service = _isoPlaybackService;
        final termination = service == null
            ? PlayerTerminationOutcome.refused
            : await service.terminateSession(
                session.history.isoSessionDirectoryPath,
              );
        if (!termination.isSafeToRelaunch) {
          session.deleting = false;
          if (mounted) {
            setState(() {});
            ScaffoldMessenger.of(context).showSnackBar(
              const SPNotice(content: AppText('无法确认 ISO 播放器身份，已保留会话且未终止进程')),
            );
          }
          return false;
        }
      }
      await _historyStore.remove(sessionId);
      if (!mounted) return true;
      _playbackPresenter.removeVideoSession(session);
      _refreshPlaybackMonitor();
      return true;
    }
    if (terminateProcess) {
      final termination = await _playerService.terminateSession(sessionId);
      if (!termination.isSafeToRelaunch) {
        session.deleting = false;
        if (mounted) {
          setState(() {});
          ScaffoldMessenger.of(context).showSnackBar(
            const SPNotice(content: AppText('无法确认视频播放器身份，已保留会话且未终止进程')),
          );
        }
        return false;
      }
    } else {
      _playerService.releaseSession(sessionId);
    }
    if (completed) {
      try {
        await _mediaLibraryStore?.dismissVideoContinueSession(
          session.history.sourceId ?? _sourceId,
          sessionId,
        );
      } on FileSystemException catch (error) {
        debugPrint('Video continue cleanup failed: $error');
      } on AppException catch (error) {
        debugPrint('Video continue cleanup failed: $error');
      }
    }
    await _historyStore.remove(sessionId);
    appState.scheduleWebDavFontCachePrune();
    if (!mounted) return true;
    _seasonStageAttempts.removeWhere((key) => key.startsWith('$sessionId|'));
    _seasonStageTasks.removeWhere((key, _) => key.startsWith('$sessionId|'));
    _playbackPresenter.removeVideoSession(session);
    _refreshPlaybackMonitor();
    return true;
  }

  Future<void> _selectVideoIndex(PlaybackUiSession session, int index) async {
    final history = session.history;
    if (index < 0 ||
        index >= history.playlistRelativePaths.length ||
        session.launching ||
        session.recovering ||
        session.deleting) {
      return;
    }
    if (history.sourceId != null && history.sourceId != _sourceId) {
      final target = history.playlistRelativePaths[index];
      final parent = p.posix.dirname(target);
      await _openLibraryItem(
        MediaLibraryItem(
          sourceId: history.sourceId!,
          sourceKind: history.sourceId!.startsWith('local:')
              ? MediaSourceKind.local
              : MediaSourceKind.webdav,
          parentPath: parent == '.' ? '' : parent,
          name: history.playlistFileNames[index],
          kind: MediaLibraryKind.video,
        ),
        selectVideoSessionId: history.sessionId,
        selectVideoIndex: index,
      );
      return;
    }
    if (await _playerService.isPlayerRunning(history.sessionId)) {
      if (!await _playerService.selectPlaylistEntry(history.sessionId, index) &&
          mounted) {
        _showLibraryError('无法切换播放集数，请关闭播放器后重试');
      }
    } else {
      final target = history.playlistRelativePaths[index];
      final parent = p.posix.dirname(target);
      await _playVideo(
        null,
        sessionId: history.sessionId,
        playlistRootPath: parent == '.' ? '' : parent,
        resumeTargetPath: target,
        playbackScope: history.playbackScope,
      );
    }
  }

  Future<void> _skipSeason(
    PlaybackUiSession session, {
    bool confirmed = false,
  }) async {
    if (session.history.playbackScope == VideoPlaybackScope.singleItem ||
        session.deleting ||
        session.launching ||
        session.recovering ||
        !_playbackSessions.contains(session) ||
        !context
            .read<AppState>()
            .configStore
            .current
            .autoSeasonTransitionEnabled ||
        !_seasonSkipInProgress.add(session.history.sessionId)) {
      return;
    }
    final sessionId = session.history.sessionId;
    try {
      if (!confirmed) {
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
      }
      final old = session.history;
      if (old.videoPlaylistMode == VideoPlaylistMode.implicit &&
          old.queueItems.isNotEmpty) {
        final season = old.queueItems[old.videoIndex].season;
        final next = old.queueItems.indexWhere(
          (i) => i.season != null && i.season! > 0 && i.season != season,
          old.videoIndex + 1,
        );
        if (next < 0) {
          _showLibraryError('未找到可用的下一季，当前季播放列表保持不变');
          return;
        }
        await _selectVideoIndex(session, next);
        return;
      }
      if (old.sourceId != null && old.sourceId != _sourceId) {
        await _openLibraryItem(
          MediaLibraryItem(
            sourceId: old.sourceId!,
            sourceKind: old.sourceId!.startsWith('local:')
                ? MediaSourceKind.local
                : MediaSourceKind.webdav,
            parentPath: old.dirCrumbs.join('/'),
            name: old.fileName,
            kind: MediaLibraryKind.video,
          ),
          skipSeasonSessionId: sessionId,
        );
        return;
      }
      final appState = context.read<AppState>();
      final rootPath = old.dirCrumbs.join('/');
      final running = await _playerService.isPlayerRunning(sessionId);
      if (!mounted || !_playbackSessions.contains(session)) return;
      if (running) {
        final currentPlaylist = old.seasonPlaylistPath;
        if (currentPlaylist == null || old.ipcPipeName == null) {
          _showLibraryError('当前播放器不支持直接切季，播放列表保持不变');
          return;
        }
        var nextPlaylist = old.nextSeasonPlaylistPath;
        if (nextPlaylist == null || !await File(nextPlaylist).exists()) {
          nextPlaylist = await _stageFollowingSeason(
            session,
            rootPath,
            currentPlaylist,
            retry: true,
          );
        }
        if (!mounted || !_playbackSessions.contains(session)) return;
        if (nextPlaylist == null) {
          _showLibraryError('未找到可用的下一季，当前季播放列表保持不变');
          return;
        }
        final switched = await _playerService.skipToNextSeason(
          sessionId,
          currentPlaylistPath: currentPlaylist,
          nextPlaylistPath: nextPlaylist,
        );
        if (!mounted || !_playbackSessions.contains(session)) return;
        if (!switched) {
          _showLibraryError('切换下一季失败，当前季播放列表保持不变');
          return;
        }
        _refreshPlaybackMonitor();
        return;
      }
      final rootEntries = await _source
          .fetchDirectory(rootPath)
          .timeout(SeasonVideoPlaylistCollector.lookupTimeout);
      if (!mounted || !_playbackSessions.contains(session)) return;
      final next = await const SeasonVideoPlaylistCollector().findNext(
        source: _source,
        rootPath: rootPath,
        rootEntries: rootEntries,
        allowGap: appState.configStore.current.allowSeasonGap,
      );
      if (!mounted || !_playbackSessions.contains(session)) return;
      if (next == null) {
        _showLibraryError('未找到可用的下一季，当前季播放列表保持不变');
        return;
      }
      final firstVideo =
          next.entries
              .where(
                (entry) =>
                    (_isLocal ? entry.isVideo : entry.isPlayable) &&
                    SeasonVideoPlaylistCollector.seasonFromVideo(entry.name) ==
                        next.season,
              )
              .toList()
            ..sort((left, right) => naturalCompare(left.name, right.name));
      final firstPath = SpecialVideoPlaylistCollector.directChildPath(
        _source,
        next.path,
        firstVideo.first,
      );
      if (firstPath == null) {
        _showLibraryError('未找到可用的下一季，当前季播放列表保持不变');
        return;
      }
      await _playerService.waitForExitSync(sessionId);
      await _playVideo(
        null,
        sessionId: sessionId,
        playlistRootPath: next.path,
        resumeTargetPath: firstPath,
      );
      if (!mounted || !_playbackSessions.contains(session)) return;
      if (session.history.playerPid == null) {
        session.history = old;
        await _historyStore.upsert(old);
        if (mounted) setState(() {});
      }
    } on AppException catch (error) {
      debugPrint('Manual season skip failed: $error');
      _showLibraryError('切换下一季失败，当前季播放列表保持不变');
    } on FileSystemException catch (error) {
      debugPrint('Manual season skip failed: $error');
      _showLibraryError('切换下一季失败，当前季播放列表保持不变');
    } on TimeoutException {
      _showLibraryError('查找下一季超时，当前季播放列表保持不变');
    } on StateError catch (error) {
      debugPrint('Manual season skip failed: $error');
      _showLibraryError('切换下一季失败，当前季播放列表保持不变');
    } on FormatException catch (error) {
      debugPrint('Manual season skip failed: $error');
      _showLibraryError('切换下一季失败，当前季播放列表保持不变');
    } finally {
      _seasonSkipInProgress.remove(sessionId);
    }
  }

  /// 「继续播放」：进入上次目录扫描并复用对应类型的常规播放入口。
  Future<void> _resumePlaybackSession(PlaybackUiSession session) async {
    if (widget.playbackOnly && session.paused != null) {
      if (session.history.kind == PlaybackHistoryKind.iso) {
        await _isoPlaybackService?.sendResume(
          session.history.isoSessionDirectoryPath,
        );
      } else {
        await _playerService.sendResume(session.history.sessionId);
      }
      return;
    }
    final origin = session.history.sourceId;
    if (origin != null && origin != _sourceId) {
      await _openLibraryItem(
        MediaLibraryItem(
          sourceId: origin,
          sourceKind: origin.startsWith('local:')
              ? MediaSourceKind.local
              : MediaSourceKind.webdav,
          parentPath: session.history.dirCrumbs.join('/'),
          name: session.history.fileName,
          playbackScope: session.history.playbackScope,
          kind: session.history.kind == PlaybackHistoryKind.iso
              ? MediaLibraryKind.iso
              : session.history.fileName.toLowerCase().endsWith('.strm')
              ? MediaLibraryKind.strm
              : MediaLibraryKind.video,
        ),
        resumeSessionId: session.history.sessionId,
        resumeVideoHistory:
            session.history.kind == PlaybackHistoryKind.video &&
                session.history.playlistRelativePaths.isNotEmpty
            ? session.history
            : null,
      );
      return;
    }
    if (session.launching || session.deleting) return;
    final history = session.history;

    if (history.kind == PlaybackHistoryKind.video &&
        history.playlistRelativePaths.isNotEmpty) {
      await _resumePlaylistHistory(history);
      return;
    }

    _directorySearchController.clear();
    _directorySearchFocusNode.unfocus();
    _directoryBrowser.navigateToPath(history.dirCrumbs.join('/'));
    try {
      await _load(
        force: history.playbackScope == VideoPlaybackScope.singleItem,
      );
    } on AppException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SPNotice(content: AppText(e.message)));
      return;
    }
    if (!mounted) return;

    if (history.kind == PlaybackHistoryKind.iso) {
      final iso = _files
          .where(
            (file) =>
                (file.isIso || file.isDirectory) &&
                file.name == history.fileName,
          )
          .firstOrNull;
      if (iso == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SPNotice(content: AppText('未找到上次播放的 ISO 文件')));
        return;
      }
      if (iso is WebDavFile) {
        if (iso.isDirectory) {
          await _playRemoteBdmv(
            [...history.dirCrumbs, iso.name].join('/'),
            sessionId: history.sessionId,
          );
        } else {
          await _playIso(iso, sessionId: history.sessionId);
        }
      }
      return;
    }

    final videos = _files.where((f) => f.isPlayable).toList();
    if (videos.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SPNotice(content: AppText('该目录下没有可播放的视频')));
      return;
    }
    // 优先按文件名定位（strm 解析失败剔除后索引可能错位）；
    // 找不到或目录内容已变化时回退到历史索引（越界取首项）。
    var index = videos.indexWhere((f) => f.name == history.fileName);
    if (index < 0) {
      if (history.playbackScope == VideoPlaybackScope.singleItem) {
        _showLibraryError('未找到上次播放的视频，请检查文件或特典设置');
        return;
      }
      index = history.videoIndex.clamp(0, videos.length - 1);
    }
    await _playVideo(
      videos[index],
      sessionId: history.sessionId,
      playbackScope: history.playbackScope,
    );
  }

  Future<void> _resumePlaylistHistory(PlaybackHistory history) async {
    if (await _playerService.isPlayerRunning(history.sessionId)) {
      await _playerService.sendResume(history.sessionId);
      return;
    }
    if (!mounted) return;
    final index = history.pendingVideoIndex ?? history.videoIndex;
    if (index < 0 || index >= history.playlistRelativePaths.length) {
      _showLibraryError('未找到上次播放的视频，请检查文件或特典设置');
      return;
    }
    var target = history.playlistRelativePaths[index];
    if (history.pendingVideoIndex != null &&
        history.queueItems.elementAtOrNull(index)?.versions.length != 1) {
      final item = history.queueItems.elementAtOrNull(index);
      if (item != null) {
        final selected = await showVideoVersionDialog(context, item);
        if (selected == null || !mounted) return;
        target = selected.path;
      }
    }
    final selectedParent = p.posix.dirname(target);
    final rootPath = selectedParent == '.' ? '' : selectedParent;
    _directorySearchController.clear();
    _directorySearchFocusNode.unfocus();
    _directoryBrowser.navigateToPath(rootPath);
    try {
      await _load(
        force: history.playbackScope == VideoPlaybackScope.singleItem,
      );
      if (!mounted) return;
      await _playVideo(
        null,
        sessionId: history.sessionId,
        playlistRootPath: rootPath,
        resumeTargetPath: target,
        playbackScope: history.playbackScope,
      );
    } on AppException catch (error) {
      _showLibraryError(error.message);
    }
  }

  Future<void> _openLibraryItem(
    MediaLibraryItem item, {
    String? resumeSessionId,
    PlaybackHistory? resumeVideoHistory,
    String? skipSeasonSessionId,
    String? selectVideoSessionId,
    int? selectVideoIndex,
  }) async {
    if (item.sourceId != _sourceId) {
      if (!_visibleSourceIds.contains(item.sourceId)) {
        _showLibraryError('该条目不属于当前连接来源');
        return;
      }
      final appState = context.read<AppState>();
      LocalRootConfig? root;
      try {
        if (item.sourceKind == MediaSourceKind.local) {
          root = _localSourceFor(item.sourceId)?.root;
          if (root == null) throw AppException.config('本地媒体已移动、删除或来源不可用');
        } else {
          final config = appState.configStore.current;
          final profile = config.profiles
              .where((profile) => profile.profileId == item.sourceId)
              .firstOrNull;
          if (profile == null) throw AppException.config('该条目不属于当前连接来源');
          if (appState.webDavService?.sourceId != item.sourceId) {
            if (config.mountedProfileIds.contains(item.sourceId)) {
              await appState.activateMountedProfile(item.sourceId);
            } else {
              await appState.connectAndActivateProfile(
                profile: profile,
                config: config,
              );
            }
          }
        }
        if (!mounted) return;
        unawaited(
          Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(
              builder: (_) => BrowserPage(
                localRoot: root,
                initialLibraryItem:
                    skipSeasonSessionId == null && selectVideoSessionId == null
                    ? item
                    : null,
                resumeSessionId: selectVideoSessionId ?? resumeSessionId,
                initialVideoSelectIndex: selectVideoIndex,
                initialVideoResumeHistory: resumeVideoHistory,
                initialSkipSeasonSessionId: skipSeasonSessionId,
              ),
            ),
          ),
        );
      } on AppException catch (error) {
        _showLibraryError(error.message);
      }
      return;
    }
    if (_isLocal && item.kind == MediaLibraryKind.iso) {
      final continueRecord = await _findLocalDiscContinueRecord(item);
      if (_isRootLocalDiscItem(item) && await _localSource!.hasDiscAt('')) {
        await _playLocalDisc(
          relativePath: '',
          displayName: widget.localRoot!.displayName,
          continueRecord: continueRecord,
        );
        return;
      }
      // 本地蓝光是目录型资产：直接按记录的相对路径恢复播放，
      // 不做目录导航与条目匹配（目录条目的分类不是 iso，匹配必然失败）。
      await _playLocalDisc(
        relativePath: item.targetPath,
        displayName: item.name,
        continueRecord: continueRecord,
      );
      return;
    }
    final destination = item.kind == MediaLibraryKind.directory
        ? item.targetPath
        : item.normalizedParentPath;
    _changeDirectoryScrollScope(() {
      _directorySearchController.clear();
      _directorySearchFocusNode.unfocus();
      _directoryBrowser.navigateToPath(normalizeLibraryPath(destination));
    });
    await _load(
      force:
          widget.playbackOnly ||
          item.playbackScope == VideoPlaybackScope.singleItem,
    );
    if (!mounted || item.kind == MediaLibraryKind.directory) return;
    if (!_isLocal && item.discRootPath != null) {
      await _playRemoteBdmv(item.discRootPath!, sessionId: resumeSessionId);
      return;
    }
    final file = _files.where(item.matches).firstOrNull;
    if (file == null) {
      _showLibraryError(
        _isLocal
            ? '本地媒体已移动、删除或来源不可用'
            : context.l10n.format('未在当前服务器目录中找到「{name}」', {'name': item.name}),
      );
      return;
    }
    if (_isLocal && item.kind == MediaLibraryKind.iso) {
      await _playLocalDisc(
        relativePath: file.relativePath,
        displayName: file.name,
        continueRecord: await _findLocalDiscContinueRecord(item),
      );
      return;
    }
    if (item.kind == MediaLibraryKind.iso && file.isDirectory && !_isLocal) {
      await _playRemoteBdmv(item.targetPath, sessionId: resumeSessionId);
    } else if (file.isAudio) {
      await _playAudio(file, sessionId: resumeSessionId);
    } else if (file.isIso && file is WebDavFile) {
      await _playIso(file, sessionId: resumeSessionId);
    } else {
      await _playVideo(
        file,
        sessionId: resumeSessionId,
        playbackScope: item.playbackScope,
      );
    }
  }

  void _onFileTap(MediaDirectoryEntry file) {
    if (file.isSelfEntry) {
      // 「返回上级」条目：回到上级目录（根目录时无操作）。
      if (_crumbs.isEmpty) return;
      _backTo(_crumbs.length - 2);
    } else if (file.isDirectory) {
      _enterDirectory(file);
    } else if (file.isIso) {
      if (_isLocal) {
        unawaited(
          _playLocalDisc(
            relativePath: file.relativePath,
            displayName: file.name,
          ),
        );
      } else {
        unawaited(_playIso(file as WebDavFile));
      }
    } else if (file.isAudio) {
      unawaited(_playAudio(file));
    } else if (_isLocal ? file.isVideo : file.isPlayable) {
      unawaited(_playVideo(file));
    }
    // 其他文件：暂无操作（可后续扩展下载/预览）。
  }

  Future<void> _openIndexEntry(OpenListIndexEntry entry) async {
    final destination = entry.isDirectory ? entry.path : entry.parent;
    _changeDirectoryScrollScope(() {
      _directorySearchController.clear();
      _directorySearchFocusNode.unfocus();
      _directoryBrowser.navigateToPath(destination);
    });
    await _load();
    if (!mounted || entry.isDirectory) return;
    final file = _files
        .where((item) => !item.isSelfEntry && item.name == entry.name)
        .firstOrNull;
    if (file == null) {
      _showLibraryError('索引条目已失效，请更新索引后重试');
      return;
    }
    _onFileTap(file);
  }

  // ── UI ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (widget.playbackOnly) return _buildPlaybackBars();
    return Scaffold(
      appBar: AppBar(
        titleSpacing: _directorySearchOpen ? null : 4,
        title: _directorySearchOpen
            ? TextField(
                key: const Key('browser-directory-search'),
                controller: _directorySearchController,
                focusNode: _directorySearchFocusNode,
                contextMenuBuilder: buildClipboardHistoryMenu,
                onChanged: _onDirectorySearchChanged,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: context.l10n.text(
                    _directorySearchScope ==
                            DirectorySearchScope.currentDirectory
                        ? '搜索当前目录'
                        : '搜索全部索引（至少 2 个字符）',
                  ),
                  prefixIcon: const Icon(SPIcons.search),
                  border: InputBorder.none,
                ),
              )
            : _buildTitle(),
        actions: [
          if (_directorySearchOpen && !_isLocal)
            PopupMenuButton<DirectorySearchScope>(
              key: const Key('browser-search-scope'),
              tooltip: context.l10n.text('搜索范围'),
              icon: const Icon(SPIcons.manageSearch),
              initialValue: _directorySearchScope,
              onSelected: (scope) => _changeDirectoryScrollScope(
                () => _directoryBrowser.updateSearchScope(scope),
              ),
              itemBuilder: (context) => [
                CheckedPopupMenuItem(
                  value: DirectorySearchScope.currentDirectory,
                  checked:
                      _directorySearchScope ==
                      DirectorySearchScope.currentDirectory,
                  child: const AppText('当前目录'),
                ),
                CheckedPopupMenuItem(
                  value: DirectorySearchScope.openListIndex,
                  checked:
                      _directorySearchScope ==
                      DirectorySearchScope.openListIndex,
                  child: const AppText('全部索引（默认）'),
                ),
              ],
            ),
          PopupMenuButton<String>(
            tooltip: context.l10n.format('排序：{mode} · {direction}', {
              'mode': context.l10n.text(_sortMode.label),
              'direction': context.l10n.text(_sortDirection.label),
            }),
            icon: const Icon(SPIcons.sort),
            onSelected: (value) {
              _changeDirectoryScrollScope(() {
                switch (value) {
                  case 'mode:name':
                    _directoryBrowser.updateSortMode(FileSortMode.name);
                  case 'mode:modified':
                    _directoryBrowser.updateSortMode(FileSortMode.modified);
                  case 'mode:size':
                    _directoryBrowser.updateSortMode(FileSortMode.size);
                  case 'direction:ascending':
                    _directoryBrowser.updateSortDirection(
                      FileSortDirection.ascending,
                    );
                  case 'direction:descending':
                    _directoryBrowser.updateSortDirection(
                      FileSortDirection.descending,
                    );
                }
              });
            },
            itemBuilder: (context) => [
              const PopupMenuItem<String>(
                enabled: false,
                height: 32,
                child: AppText('排序方式'),
              ),
              for (final mode in FileSortMode.values)
                CheckedPopupMenuItem<String>(
                  value: 'mode:${mode.jsonValue}',
                  checked: mode == _sortMode,
                  enabled: mode != FileSortMode.size || _canSortBySize,
                  child: AppText(mode.label),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem<String>(
                enabled: false,
                height: 32,
                child: AppText('排序顺序'),
              ),
              for (final direction in FileSortDirection.values)
                CheckedPopupMenuItem<String>(
                  value: 'direction:${direction.jsonValue}',
                  checked: direction == _sortDirection,
                  child: Row(
                    children: [
                      Icon(
                        direction == FileSortDirection.ascending
                            ? SPIcons.up
                            : SPIcons.down,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      AppText(direction.label),
                    ],
                  ),
                ),
            ],
          ),
          if (_directorySearchOpen)
            IconButton(
              key: const Key('close-browser-directory-search'),
              icon: const Icon(SPIcons.close),
              tooltip: context.l10n.text('关闭搜索'),
              onPressed: _closeDirectorySearch,
            )
          else
            IconButton(
              key: const Key('open-browser-directory-search'),
              icon: const Icon(SPIcons.search),
              tooltip: context.l10n.text('搜索当前目录'),
              onPressed: _openDirectorySearch,
            ),
          IconButton(
            key: const Key('browser-view-mode'),
            icon: Icon(_tileView ? SPIcons.list : SPIcons.apps),
            tooltip: context.l10n.text(_tileView ? '列表浏览' : '平铺浏览'),
            onPressed: () => setState(() => _tileView = !_tileView),
          ),
          IconButton(
            icon: const Icon(SPIcons.refresh),
            tooltip: context.l10n.text('刷新'),
            onPressed: () => _load(force: true),
          ),
          if (!_isLocal)
            IconButton(
              icon: const Icon(SPIcons.signOut),
              tooltip: context.l10n.text('断开连接'),
              onPressed: () {
                context.read<AppState>().disconnect();
                // 进入登录界面时清空导航栈，保留已保存的连接配置。
                Navigator.of(context).popUntil((route) => route.isFirst);
              },
            ),
        ],
      ),
      body: _buildBody(),
      bottomNavigationBar:
          _playbackSessions.isEmpty &&
              _audioPlaybackSessions.isEmpty &&
              _localDiscContinue.isEmpty
          ? null
          : _buildPlaybackBars(),
    );
  }

  /// 共享展示时标注会话的原始来源。
  String _barDirectoryLabel(String? sourceId, String directory) {
    if (_visibleSourceIds.length <= 1) return directory;
    final id = sourceId ?? _sourceId;
    final config = context.read<AppState>().configStore.current;
    final name =
        config.localRoots
            .where((root) => root.sourceId == id)
            .firstOrNull
            ?.displayName ??
        config.profiles
            .where((profile) => profile.profileId == id)
            .firstOrNull
            ?.name ??
        id;
    return '$name · ${context.l10n.text(directory)}';
  }

  /// 播放会话垂直堆栈：新会话在上，越早创建的会话越靠下。
  Widget _buildPlaybackBars() {
    final displayed = _playbackSessions.reversed.toList();
    final displayedAudio = _audioPlaybackSessions.reversed.toList();
    final bars = <Widget>[
      for (final session in displayedAudio) _buildAudioPlaybackBar(session),
      for (final session in displayed) _buildPlaybackBar(session),
      for (final entry in _localDiscContinue) _buildLocalDiscPlaybackBar(entry),
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

  Future<bool> _removeLocalDiscContinue(_LocalDiscContinueEntry entry) async {
    final sessionId = entry.record.playbackSessionId;
    if (sessionId != null && entry.running) {
      final outcome = await _localDiscPlaybackService.terminateSession(
        sessionId,
      );
      if (!outcome.isSafeToRelaunch) {
        _showLibraryError('无法确认对应蓝光播放器进程，未删除播放会话');
        return false;
      }
    }
    await _mediaLibraryStore?.dismissLocalDiscPlaybackBar(entry.record);
    await _refreshLocalDiscContinue();
    return true;
  }

  Future<void> _setLocalDiscPaused(
    _LocalDiscContinueEntry entry,
    bool paused,
  ) async {
    final sessionId = entry.record.playbackSessionId;
    if (sessionId == null) return;
    if (paused) {
      await _localDiscPlaybackService.sendPause(sessionId);
    } else {
      await _localDiscPlaybackService.sendResume(sessionId);
    }
    if (!mounted) return;
    setState(() {
      _localDiscContinue = [
        for (final candidate in _localDiscContinue)
          identical(candidate, entry)
              ? _LocalDiscContinueEntry(
                  record: candidate.record,
                  running: candidate.running,
                  paused: paused,
                )
              : candidate,
      ];
    });
  }

  Widget _buildLocalDiscPlaybackBar(_LocalDiscContinueEntry entry) {
    final record = entry.record;
    final String title;
    final IconData icon;
    final String tooltip;
    final VoidCallback? onPressed;
    if (entry.running && entry.paused == true) {
      title = '本地蓝光已暂停：${record.item.name}';
      icon = SPIcons.play;
      tooltip = '继续播放';
      onPressed = () => _setLocalDiscPaused(entry, false);
    } else if (entry.running) {
      title = '正在播放本地蓝光：${record.item.name}';
      icon = SPIcons.pause;
      tooltip = '暂停';
      onPressed = () => _setLocalDiscPaused(entry, true);
    } else {
      title = '继续播放本地蓝光：${record.item.name}';
      icon = SPIcons.play;
      tooltip = '继续播放';
      onPressed = record.item.sourceId != _sourceId
          ? () => _openLibraryItem(record.item)
          : () => _playLocalDisc(
              relativePath:
                  record.localDiscSession?.relativePath ??
                  (_isRootLocalDiscItem(record.item)
                      ? ''
                      : record.item.targetPath),
              displayName: record.item.name,
              continueRecord: record,
            );
    }
    final details = <String>[
      record.item.normalizedParentPath.isEmpty
          ? context.l10n.text('根目录')
          : record.item.normalizedParentPath,
    ];
    return PlaybackBar(
      key: ValueKey<String>('local-disc-playback-bar-${record.recordKey}'),
      onSubtitles:
          entry.running &&
              context
                  .read<AppState>()
                  .configStore
                  .current
                  .subtitleInjectionEnabled
          ? () => _showLocalIsoSubtitles(entry)
          : null,
      title: title,
      dirLabel: _barDirectoryLabel(record.item.sourceId, details.join(' · ')),
      subtitle: ContinuePlaybackSubtitle.disc(
        label: _barDirectoryLabel(record.item.sourceId, details.join(' · ')),
        record: record,
      ),
      icon: icon,
      tooltip: tooltip,
      deleting: false,
      onPressed: onPressed,
      onDelete: () => _removeLocalDiscContinue(entry),
      onSecondaryTapDown: (details) =>
          _showLocalDiscSessionMenu(entry, details.globalPosition),
    );
  }

  Future<void> _showLocalDiscSessionMenu(
    _LocalDiscContinueEntry entry,
    Offset globalPosition,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem<String>(
          value: 'delete',
          child: Row(
            children: [
              Icon(SPIcons.delete),
              SizedBox(width: 10),
              AppText('删除并关闭播放器'),
            ],
          ),
        ),
      ],
    );
    if (selected == 'delete' && mounted) {
      await _removeLocalDiscContinue(entry);
    }
  }

  Widget _buildAudioPlaybackBar(AudioPlaybackUiSession session) {
    final history = session.history;
    final sessionId = history.sessionId;
    final dirLabel =
        '${context.l10n.text('音乐')} · '
        '${history.dirCrumbs.isEmpty ? context.l10n.text('根目录') : history.dirCrumbs.join(' / ')}';
    final paused = session.paused;

    final String title;
    final IconData icon;
    final String tooltip;
    final VoidCallback? onPressed;
    if (session.launching) {
      title = '正在打开音频：${history.fileName}';
      icon = SPIcons.progress;
      tooltip = '正在打开播放器';
      onPressed = null;
    } else if (paused == false) {
      title = '正在播放音频：${history.fileName}';
      icon = SPIcons.pause;
      tooltip = '暂停';
      onPressed = () =>
          context.read<AppState>().audioPlayerService?.sendPause(sessionId);
    } else if (paused == true) {
      title = '音频已暂停：${history.fileName}';
      icon = SPIcons.play;
      tooltip = '继续播放';
      onPressed = () =>
          context.read<AppState>().audioPlayerService?.sendResume(sessionId);
    } else {
      title = '继续播放音频：${history.fileName}';
      icon = SPIcons.play;
      tooltip = '继续播放';
      onPressed = () => _resumeAudioPlaybackSession(session);
    }

    return PlaybackBar(
      key: ValueKey<String>('audio-playback-bar-$sessionId'),
      title: title,
      dirLabel: _barDirectoryLabel(history.sourceId, dirLabel),
      subtitle: ContinuePlaybackSubtitle.audio(
        label: _barDirectoryLabel(history.sourceId, dirLabel),
        history: history,
        fallbackSourceId: _sourceId,
      ),
      icon: icon,
      tooltip: tooltip,
      deleting: session.deleting,
      onPressed: onPressed,
      onDelete: () =>
          _removeAudioPlaybackSession(session, terminateProcess: true),
      onSecondaryTapDown: (details) =>
          _showAudioSessionMenu(session, details.globalPosition),
    );
  }

  Future<void> _showAudioSessionMenu(
    AudioPlaybackUiSession session,
    Offset globalPosition,
  ) async {
    if (session.deleting) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem<String>(
          value: 'delete',
          child: Row(
            children: [
              Icon(SPIcons.delete),
              SizedBox(width: 10),
              AppText('删除并关闭音频播放器'),
            ],
          ),
        ),
      ],
    );
    if (selected == 'delete' && mounted) {
      await _removeAudioPlaybackSession(session, terminateProcess: true);
    }
  }

  Widget _buildPlaybackBar(PlaybackUiSession session) {
    if (session.history.kind == PlaybackHistoryKind.iso) {
      return _buildIsoPlaybackBar(session);
    }
    final history = session.history;
    final sessionId = history.sessionId;
    final dirLabel = history.dirCrumbs.isEmpty
        ? '根目录'
        : history.dirCrumbs.join(' / ');
    final paused = session.paused;

    final String title;
    final IconData icon;
    final String tooltip;
    final VoidCallback? onPressed;
    if (session.recovering) {
      title = '正在恢复：${history.fileName}';
      icon = SPIcons.sync;
      tooltip = '正在刷新链接并恢复播放';
      onPressed = null;
    } else if (session.launching) {
      title = '正在打开：${history.fileName}';
      icon = SPIcons.progress;
      tooltip = '正在打开播放器';
      onPressed = null;
    } else if (paused == false) {
      title = '正在播放：${history.fileName}';
      icon = SPIcons.pause;
      tooltip = '暂停';
      onPressed = () => _playerService.sendPause(sessionId);
    } else if (paused == true) {
      title = '已暂停：${history.fileName}';
      icon = SPIcons.play;
      tooltip = '继续播放';
      onPressed = () => _playerService.sendResume(sessionId);
    } else {
      title = '继续播放：${history.fileName}';
      icon = SPIcons.play;
      tooltip = '继续播放';
      onPressed = () => _resumePlaybackSession(session);
    }

    return PlaybackBar(
      key: ValueKey<String>('playback-bar-$sessionId'),
      onPrevious:
          history.videoPlaylistMode == VideoPlaylistMode.implicit &&
              history.videoIndex > 0
          ? () => _selectVideoIndex(session, history.videoIndex - 1)
          : null,
      onNext:
          history.videoPlaylistMode == VideoPlaylistMode.implicit &&
              history.videoIndex + 1 < history.playlistRelativePaths.length
          ? () => _selectVideoIndex(session, history.videoIndex + 1)
          : null,
      onSkipSeason:
          history.playbackScope == VideoPlaybackScope.directory &&
              context
                  .read<AppState>()
                  .configStore
                  .current
                  .autoSeasonTransitionEnabled &&
              !session.launching &&
              !session.recovering &&
              ((history.playerPid == null && history.ipcPipeName == null) ||
                  (history.ipcPipeName != null &&
                      (history.seasonPlaylistPath != null ||
                          history.videoPlaylistMode ==
                              VideoPlaylistMode.implicit)))
          ? () => _skipSeason(session)
          : null,
      title: title,
      dirLabel: _barDirectoryLabel(history.sourceId, dirLabel),
      subtitle: ContinuePlaybackSubtitle.video(
        label: _barDirectoryLabel(
          history.sourceId,
          context.l10n.text(dirLabel),
        ),
        history: history,
        fallbackSourceId: _sourceId,
      ),
      icon: icon,
      tooltip: tooltip,
      deleting: session.deleting,
      onPressed: onPressed,
      onDelete: () => _removePlaybackSession(session, terminateProcess: true),
      onSecondaryTapDown: (details) =>
          _showSessionMenu(session, details.globalPosition),
    );
  }

  Widget _buildIsoPlaybackBar(PlaybackUiSession session) {
    final history = session.history;
    final sessionId = history.sessionId;
    final dirLabel =
        'ISO · '
        '${history.dirCrumbs.isEmpty ? context.l10n.text('根目录') : history.dirCrumbs.join(' / ')}';
    final paused = session.paused;

    final String title;
    final IconData icon;
    final String tooltip;
    final VoidCallback? onPressed;
    if (session.launching) {
      title = '正在打开 ISO：${history.fileName}';
      icon = SPIcons.progress;
      tooltip = '正在打开播放器';
      onPressed = null;
    } else if (paused == false) {
      title = '正在播放 ISO：${history.fileName}';
      icon = SPIcons.pause;
      tooltip = '暂停';
      onPressed = () =>
          _isoPlaybackService?.sendPause(history.isoSessionDirectoryPath);
    } else if (paused == true) {
      title = 'ISO 已暂停：${history.fileName}';
      icon = SPIcons.play;
      tooltip = '继续播放';
      onPressed = () =>
          _isoPlaybackService?.sendResume(history.isoSessionDirectoryPath);
    } else {
      title = '继续播放 ISO：${history.fileName}';
      icon = SPIcons.play;
      tooltip = '继续播放';
      onPressed = () => _resumePlaybackSession(session);
    }

    return PlaybackBar(
      key: ValueKey<String>('iso-playback-bar-$sessionId'),
      onSubtitles:
          history.isoSessionDirectoryPath != null &&
              (history.sourceId == null || history.sourceId == _sourceId) &&
              context
                  .read<AppState>()
                  .configStore
                  .current
                  .subtitleInjectionEnabled
          ? () => _showIsoSubtitleSession(
              _source,
              [...history.dirCrumbs, history.fileName].join('/'),
              Directory(history.isoSessionDirectoryPath!),
            )
          : null,
      title: title,
      dirLabel: _barDirectoryLabel(history.sourceId, dirLabel),
      subtitle: ContinuePlaybackSubtitle.video(
        label: _barDirectoryLabel(history.sourceId, dirLabel),
        history: history,
        fallbackSourceId: _sourceId,
      ),
      icon: icon,
      tooltip: tooltip,
      deleting: session.deleting,
      onPressed: onPressed,
      onDelete: () => _removePlaybackSession(session, terminateProcess: true),
      onSecondaryTapDown: (details) =>
          _showSessionMenu(session, details.globalPosition),
    );
  }

  Future<void> _showSessionMenu(
    PlaybackUiSession session,
    Offset globalPosition,
  ) async {
    if (session.deleting) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem<String>(
          value: 'delete',
          child: Row(
            children: [
              Icon(SPIcons.delete),
              SizedBox(width: 10),
              AppText('删除并关闭播放器'),
            ],
          ),
        ),
      ],
    );
    if (selected == 'delete' && mounted) {
      await _removePlaybackSession(session, terminateProcess: true);
    }
  }

  Widget _buildTitle() => SizedBox(
    height: Theme.of(context).appBarTheme.toolbarHeight ?? kToolbarHeight,
    child: DirectoryBreadcrumbs(crumbs: _crumbs, onNavigate: _backTo),
  );

  Widget? _buildFileTrailing(MediaDirectoryEntry file, int index) {
    if (_refreshing && index == 0) {
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (_mediaLibraryStore == null) return null;
    final item = _libraryItemForFile(file);
    if (item == null) return null;
    final selected = _favoriteKeys.contains(item.stableKey);
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        key: ValueKey<String>('favorite-${item.stableKey}'),
        tooltip: context.l10n.text(selected ? '取消收藏' : '收藏'),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        iconSize: 20,
        onPressed: () => _toggleFavorite(file),
        icon: Icon(selected ? SPIcons.favoriteFill : SPIcons.favorite),
      ),
    );
  }

  Widget _buildBody() {
    if (_directorySearchOpen &&
        _directorySearchScope == DirectorySearchScope.openListIndex) {
      return _buildIndexSearchBody();
    }
    if (_error != null && _files.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              SPIcons.error,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: AppText(_error!, textAlign: TextAlign.center),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => _load(force: true),
              icon: const Icon(SPIcons.refresh),
              label: const AppText('重试'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () {
                _directoryBrowser.navigateToPath('');
                unawaited(_load());
              },
              icon: const Icon(SPIcons.folder),
              label: const AppText('返回根目录'),
            ),
          ],
        ),
      );
    }

    if (_files.isEmpty && _refreshing) {
      return const Center(child: CircularProgressIndicator());
    }

    final visibleFiles = _visibleFiles;
    final fileList = _tileView
        ? DirectoryFileGrid(
            entries: visibleFiles,
            controller: _directoryScrollController,
            scrollKey: _directoryScrollKey,
            onRefresh: () => _load(force: true),
            emptyLabel: _directorySearchQuery.trim().isEmpty ? '空目录' : '未找到匹配项',
            onParentTap: _onFileTap,
            refreshing: _refreshing,
            itemBuilder: (context, entry, index) => FileGridTile(
              file: entry,
              onTap: () => _onFileTap(entry),
              trailing: _buildFileTrailing(entry, index),
              folderSize: _folderSizeFor(entry),
              revealed: _revealedName == entry.name,
            ),
          )
        : DirectoryFileList(
            entries: visibleFiles,
            controller: _directoryScrollController,
            scrollKey: _directoryScrollKey,
            onRefresh: () => _load(force: true),
            emptyLabel: _directorySearchQuery.trim().isEmpty ? '空目录' : '未找到匹配项',
            itemBuilder: (context, entry, index) => FileTile(
              file: entry,
              onTap: () => _onFileTap(entry),
              trailing: _buildFileTrailing(entry, index),
              folderSize: _folderSizeFor(entry),
              selected: _revealedName == entry.name,
            ),
          );
    final remoteBdmv =
        !_isLocal &&
        WebDavBdmvService.isCandidate(
          _currentPath,
          _files.whereType<WebDavFile>(),
        );
    if (!(_isLocal && _hasLocalDisc) && !remoteBdmv) return fileList;
    return Column(
      children: [
        ListTile(
          key: Key(
            remoteBdmv ? 'webdav-bdmv-action' : 'local-bdmv-menu-action',
          ),
          leading: const Icon(SPIcons.disc),
          title: const AppText('检测到 Blu-ray BDMV'),
          subtitle: const AppText('由 MPV/libbluray 显示并控制蓝光菜单'),
          trailing: FilledButton.icon(
            onPressed: _preparingBdmv
                ? null
                : remoteBdmv
                ? () => _playRemoteBdmv(_currentPath)
                : () => _playLocalDisc(
                    relativePath: _currentPath,
                    displayName:
                        _crumbs.lastOrNull ?? widget.localRoot!.displayName,
                  ),
            icon: const Icon(SPIcons.play),
            label: AppText(_preparingBdmv ? '正在读取 BDMV 目录' : '选择播放方式'),
          ),
        ),
        Expanded(child: fileList),
      ],
    );
  }

  Widget _buildIndexSearchBody() {
    final query = _directorySearchQuery.trim();
    final results = _directoryBrowser.indexSearchResults;
    final error = _directoryBrowser.indexSearchError;
    Widget content;
    if (query.length < 2) {
      content = const Center(child: AppText('请输入至少 2 个字符后搜索全部索引'));
    } else if (_directoryBrowser.indexSearching && results.isEmpty) {
      content = const Center(child: CircularProgressIndicator());
    } else if (error != null) {
      content = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: AppText(error, textAlign: TextAlign.center),
        ),
      );
    } else if (results.isEmpty) {
      content = const Center(child: AppText('索引中未找到匹配项'));
    } else {
      content = ListView.builder(
        key: _directoryScrollKey,
        controller: _directoryScrollController,
        itemCount: results.length,
        itemBuilder: (context, index) {
          final entry = results[index];
          final file = WebDavFile(
            name: entry.name,
            href: entry.path,
            isDirectory: entry.isDirectory,
            size: entry.size,
          );
          return FileTile(
            file: file,
            subtitle: entry.parent.isEmpty ? '/' : entry.parent,
            metadataColumnText: entry.parentFolderName,
            onTap: () => _openIndexEntry(entry),
          );
        },
      );
    }
    return FileListSurface(
      child: Column(
        children: [
          const FileListHeader(metadataColumnLabel: '所在文件夹'),
          Expanded(child: content),
        ],
      ),
    );
  }
}
