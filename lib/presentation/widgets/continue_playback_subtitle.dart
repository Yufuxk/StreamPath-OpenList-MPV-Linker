import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../core/errors/app_exception.dart';
import '../../core/utils/url_utils.dart';
import '../../data/local/playback_progress_db.dart';
import '../../data/models/audio_playback_history.dart';
import '../../data/models/media_library_item.dart';
import '../../data/models/playback_history.dart';
import '../localization/app_localizations.dart';
import '../state/app_state.dart';

/// 从已有进度存储读取底栏信息，不读取媒体正文或新增轮询。
class ContinuePlaybackSubtitle extends StatefulWidget {
  const ContinuePlaybackSubtitle.video({
    super.key,
    required this.label,
    required PlaybackHistory history,
    this.fallbackSourceId,
  }) : video = history,
       audio = null,
       disc = null;

  const ContinuePlaybackSubtitle.audio({
    super.key,
    required this.label,
    required AudioPlaybackHistory history,
    this.fallbackSourceId,
  }) : audio = history,
       video = null,
       disc = null;

  const ContinuePlaybackSubtitle.disc({
    super.key,
    required this.label,
    required MediaLibraryRecord record,
  }) : disc = record,
       video = null,
       audio = null,
       fallbackSourceId = null;

  final String label;
  final PlaybackHistory? video;
  final AudioPlaybackHistory? audio;
  final MediaLibraryRecord? disc;
  final String? fallbackSourceId;

  @override
  State<ContinuePlaybackSubtitle> createState() =>
      _ContinuePlaybackSubtitleState();
}

class _ContinuePlaybackSubtitleState extends State<ContinuePlaybackSubtitle> {
  late final AppState _app;
  int _generation = 0;
  int? _positionMs;
  int? _episodeNumber;
  int? _episodeCount;
  PlaybackProgressReader? _listenedProgressReader;

  String? get _sourceId =>
      widget.video?.sourceId ??
      widget.audio?.sourceId ??
      widget.disc?.item.sourceId ??
      widget.fallbackSourceId;
  bool get _iso =>
      widget.disc != null || widget.video?.kind == PlaybackHistoryKind.iso;
  bool get _strm =>
      widget.video?.fileName.toLowerCase().endsWith('.strm') ?? false;
  PlaybackProgressReader? get _progressReader =>
      widget.audio != null ? _app.audioProgressService : _app.progressService;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _listenedProgressReader = _progressReader;
    _listenedProgressReader?.addListener(_onProgress);
    _app.isoPlaybackService?.addLibraryProgressListener(_onIsoProgress);
    _app.localDiscPlaybackService.addLibraryProgressListener(_onIsoProgress);
    _app.mediaLibraryStore?.addListener(_onLibrary);
    _load();
  }

  @override
  void didUpdateWidget(ContinuePlaybackSubtitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_listenedProgressReader != _progressReader) {
      _listenedProgressReader?.removeListener(_onProgress);
      _listenedProgressReader = _progressReader;
      _listenedProgressReader?.addListener(_onProgress);
    }
    if (widget.video != oldWidget.video ||
        widget.audio != oldWidget.audio ||
        widget.disc != oldWidget.disc ||
        widget.fallbackSourceId != oldWidget.fallbackSourceId) {
      _positionMs = null;
      _episodeNumber = null;
      _episodeCount = null;
      _load();
    }
  }

  @override
  void dispose() {
    _generation++;
    _listenedProgressReader?.removeListener(_onProgress);
    _app.isoPlaybackService?.removeLibraryProgressListener(_onIsoProgress);
    _app.localDiscPlaybackService.removeLibraryProgressListener(_onIsoProgress);
    _app.mediaLibraryStore?.removeListener(_onLibrary);
    super.dispose();
  }

  void _onProgress(PlaybackProgressChange change) {
    if ((!_iso || (_sourceId?.startsWith('local:') ?? false)) &&
        !_strm &&
        (change.affectsAll ||
            change.profileId == _sourceId &&
                stripUserInfo(change.url!) == _target())) {
      _load();
    }
  }

  void _onIsoProgress() {
    if (_iso) _load();
  }

  void _onLibrary() {
    if (_strm) _load();
  }

  String? _target() {
    final sourceId = _sourceId;
    if (sourceId == null) return null;
    final video = widget.video;
    final audio = widget.audio;
    final disc = widget.disc;
    final relativePath = disc != null
        ? disc.localDiscSession?.relativePath ?? disc.item.targetPath
        : video != null &&
              video.playlistRelativePaths.length ==
                  video.playlistFileNames.length &&
              video.videoIndex >= 0 &&
              video.videoIndex < video.playlistRelativePaths.length
        ? video.playlistRelativePaths[video.videoIndex]
        : [
            ...(video?.dirCrumbs ?? audio!.dirCrumbs),
            video?.fileName ?? audio!.fileName,
          ].join('/');
    if (sourceId.startsWith('local:')) {
      final root = _app.localRoots
          .where((root) => root.sourceId == sourceId && root.enabled)
          .firstOrNull;
      return root == null
          ? null
          : _app.localMediaSource(root).lexicalPath(relativePath);
    }
    final profile = _app.configStore.current.profiles
        .where((profile) => profile.profileId == sourceId)
        .firstOrNull;
    if (profile == null) return null;
    final parent = normalizeLibraryPath(
      p.posix.dirname(relativePath).replaceFirst(RegExp(r'^\.$'), ''),
    );
    final name = p.posix.basename(relativePath);
    for (final directory in _app.directoryCache.visitedDirectories(sourceId)) {
      if (normalizeLibraryPath(directory.path) != parent) continue;
      final file = directory.entries
          .where((file) => file.name == name)
          .firstOrNull;
      if (file != null) {
        return stripUserInfo(resolveHref(profile.serverUrl, file.href));
      }
    }
    return null;
  }

  Future<void> _load() async {
    final generation = ++_generation;
    int? positionMs;
    int? episodeNumber;
    int? episodeCount;
    try {
      if (_iso) {
        final snapshot = widget.disc?.localDiscSession;
        episodeNumber = snapshot?.currentEdition == null
            ? null
            : snapshot!.currentEdition! + 1;
        episodeCount = snapshot?.editionCount;
        final sourceId = _sourceId;
        final isoKey = widget.video?.isoKey;
        final target = _target();
        final mode =
            widget.video?.playbackMode ?? widget.disc!.item.playbackMode;
        final progress = isoKey != null
            ? await _app.isoPlaybackService?.getLibraryProgressByKey(
                isoKey,
                playbackMode: mode,
              )
            : sourceId != null && target != null
            ? await (sourceId.startsWith('local:')
                      ? _app.localDiscPlaybackService
                      : _app.isoPlaybackService)
                  ?.getLibraryProgress(
                    profileId: sourceId,
                    resolvedUrl: target,
                    playbackMode: mode,
                  )
            : null;
        positionMs = progress?.position.inMilliseconds;
        episodeNumber = progress?.episodeNumber ?? episodeNumber;
        episodeCount = progress?.episodeCount ?? episodeCount;
      } else if (_strm) {
        final records = await _app.mediaLibraryStore?.playbackHistory(
          _sourceId!,
          audio: false,
        );
        final record = records
            ?.where(
              (record) =>
                  record.playbackSessionId == widget.video!.sessionId &&
                  record.item.name == widget.video!.fileName,
            )
            .firstOrNull;
        positionMs = record?.strmPositionMs;
      } else {
        final target = _target();
        if (target != null) {
          final progress = widget.audio != null
              ? await _progressReader?.getProgress(target, profileId: _sourceId)
              : await _progressReader?.getResumeProgress(
                  target,
                  profileId: _sourceId,
                );
          positionMs = progress?.positionMs;
        }
      }
    } on AppException catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'continue playback',
          context: ErrorDescription('while reading playback details'),
        ),
      );
    }
    if (!mounted || generation != _generation) return;
    setState(() {
      _positionMs = positionMs;
      _episodeNumber = episodeNumber;
      _episodeCount = episodeCount;
    });
  }

  @override
  Widget build(BuildContext context) {
    final index = widget.video?.videoIndex ?? widget.audio?.trackIndex;
    final count =
        widget.video?.playlistFileNames.length ??
        widget.audio?.playlistFileNames.length;
    return Text(
      context.l10n.playbackDetails(
        widget.label,
        positionMs: _positionMs,
        episodeNumber: _iso
            ? _episodeNumber
            : index == null
            ? null
            : index + 1,
        episodeCount: _iso ? _episodeCount : count,
        audio: widget.audio != null,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
