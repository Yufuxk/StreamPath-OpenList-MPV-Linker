import '../widgets/transition_content.dart';
import '../widgets/film_connected_transition.dart';
import '../widgets/cinematic_states.dart';
import '../widgets/skeleton_scope.dart';
import '../../data/models/film_playlist.dart';
import '../widgets/video_cache_widgets.dart';
import '../widgets/film_playlist_dialog.dart';
import '../widgets/sp_menu.dart';
import '../widgets/film_continue_card.dart';
import '../widgets/film_card_glass.dart';
import 'film_related_page.dart';
import '../widgets/directory_scroll_view.dart';
import '../widgets/film_watch_overlay.dart';
import '../widgets/film_watch_menu.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import '../widgets/film_segmented_control.dart';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/models/film_catalog_item.dart';
import '../../data/models/film_version.dart';
import '../../domain/services/film_version_resolver.dart';
import '../widgets/film_extra_controls.dart';
import '../../domain/services/film_catalog_image_cache.dart';
import '../../data/local/film_catalog_store.dart';
import '../widgets/sp_notice.dart';
import '../../data/local/media_library_store.dart';
import '../../data/local/playback_progress_db.dart';
import '../../domain/services/iso_playback_service.dart';
import '../../data/models/media_library_item.dart';
import '../../data/models/media_source.dart';
import '../controllers/film_catalog_controller.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/sp_dialog.dart';
import '../widgets/film_artwork.dart';
import '../widgets/film_detail_back_button.dart';
import '../widgets/film_detail_backdrop.dart';
import '../widgets/film_adaptive_foreground.dart';
import '../widgets/film_certification_badge.dart';
import '../widgets/film_information_pill.dart';
import '../widgets/film_detail_buttons.dart';
import '../widgets/film_catalog_tasks.dart';
import '../widgets/film_library_background.dart';
import '../widgets/film_match_dialog.dart';
import '../widgets/sp_icons.dart';
import '../widgets/film_shelf.dart';
import '../widgets/film_technical_info.dart';
import '../widgets/film_work_menu.dart';

String filmResourceState(AppState app, FilmResource resource) {
  final available = resource.sourceKind == MediaSourceKind.local
      ? app.localRoots.any((r) => r.sourceId == resource.sourceId && r.enabled)
      : resource.sourceKind.isNativeStorage || resource.sourceKind.isMediaServer
      ? app.mediaConnections.any((r) => r.id == resource.sourceId && r.enabled)
      : app.configStore.current.mountedProfileIds.contains(resource.sourceId) &&
            app.isProfileConnected(resource.sourceId);
  if (!available) return '来源不可用';
  if (resource.availability == 'missing') return '位置缺失';
  if (resource.workId == null) return '未匹配';
  if (resource.type == FilmMediaType.tv && resource.season == null) {
    return '集号待确认';
  }
  return '可用';
}

/// 精选橱窗与详情入口采用同一可用资源和首集规则。
FilmResource? recommendedFilmResource(
  AppState app,
  FilmWork work,
  List<FilmResource> resources,
) {
  final available = resources
      .where((r) => filmResourceState(app, r) == '可用')
      .toList();
  if (work.type == FilmMediaType.movie) {
    return available.where((r) => r.isMovieMain).firstOrNull;
  }
  final episodes = available
      .where((r) => (r.season ?? 0) > 0 && r.episode != null)
      .toList();
  episodes.sort((a, b) {
    final season = a.season!.compareTo(b.season!);
    return season != 0 ? season : a.episode!.compareTo(b.episode!);
  });
  return episodes.firstOrNull;
}

class FilmDetailPage extends StatefulWidget {
  const FilmDetailPage({
    super.key,
    required this.catalog,
    required this.workId,
    required this.onOpenItem,
    this.initialWork,
    this.onContinueSelected,
    this.onContinueMenu,
  });
  final FilmCatalogController catalog;
  final int workId;
  final FilmWork? initialWork;
  final Future<void> Function(MediaLibraryItem) onOpenItem;
  final ValueChanged<MediaLibraryRecord>? onContinueSelected;
  final void Function(MediaLibraryRecord, Offset)? onContinueMenu;
  @override
  State<FilmDetailPage> createState() => _FilmDetailPageState();
}

class _FilmDetailPageState extends State<FilmDetailPage>
    with StreamPathTransitionState {
  MaterialPageRoute<void>? _relatedRoute;
  final _scroll = ScrollController();
  final _textColors = FilmBackdropTextController();
  final _titleTextKey = GlobalKey();
  final _originalTitleTextKey = GlobalKey();
  final _metadataTextKey = GlobalKey();
  final _overviewTextKey = GlobalKey();
  FilmWork? _work;
  String? _logoOverride;
  List<FilmResource> _resources = [];
  String? _extraFilter;
  FilmVersionIndex _versions = FilmVersionIndex([]);
  FilmVersionSelection? _versionSelection;
  Future<void> _versionWrites = Future.value();
  final _workVersionField = GlobalKey<FormFieldState<String>>();
  List<FilmResource>? _visibleSnapshot;
  FilmVersionSelection? _visibleSelection;
  FilmVersionIndex? _visibleVersions;
  List<FilmResource> get _visibleResources {
    if (_versionSelection == null) return _resources;
    if (_visibleSnapshot == null ||
        _visibleSelection != _versionSelection ||
        _visibleVersions != _versions) {
      _visibleSelection = _versionSelection;
      _visibleVersions = _versions;
      _visibleSnapshot = [
        ..._versions.selected(_versionSelection!),
        ..._resources.where(
          (r) => r.isDisc || r.season == null || r.episode == null,
        ),
      ];
    }
    return _visibleSnapshot!;
  }

  MediaLibraryItem _versionItem(MediaLibraryItem item) =>
      _versionSelection == null ||
          !item.kind.isVideoLane ||
          !_resources.any(
            (r) =>
                r.sourceId == item.sourceId &&
                r.path == item.targetPath &&
                r.season != null &&
                r.episode != null &&
                !r.isDisc,
          )
      ? item
      : item.withFilmVersion(
          FilmPlaybackContext(
            workId: widget.workId,
            identity: _work!.identity,
            sourceScope: widget.catalog.sourceId,
            selection: _versionSelection!,
          ),
        );

  Future<void> _openVersionItem(MediaLibraryItem item) =>
      widget.onOpenItem(_versionItem(item));

  void _changeVersion(String key, {int? season}) {
    _versionWrites = _versionWrites.then((_) async {
      if (!mounted) return;
      final next = season == null
          ? FilmVersionSelection(defaultKey: key)
          : _versionSelection!.withSeason(season, key);
      final ok = await widget.catalog.run(
        () => widget.catalog.store.saveVersionSelection(
          _work!.identity,
          next,
          sourceScope: widget.catalog.sourceId,
        ),
      );
      if (!mounted) return;
      if (ok) {
        setState(() {
          _versionSelection = next;
          _selected.clear();
        });
        _scheduleContinue();
      } else {
        _workVersionField.currentState?.didChange(
          _versionSelection?.defaultKey,
        );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SPNotice(content: AppText('版本选择保存失败')));
      }
    });
  }

  Map<(int?, int?), Map> _episodes = {};
  Map<int, Map<String, dynamic>?> _probes = {};
  final Set<int> _selected = {};
  int? _activeSeason;
  bool _expandedOverview = false;
  MediaLibraryRecord? _continueRecord;
  int? _continuePositionMs, _continueDurationMs;
  final _progressReaders = <PlaybackProgressReader>[];
  final _isoReaders = <IsoLibraryProgressReader>[];
  late final List<MediaLibraryStore> _playbackStores;
  bool _favorite = false;
  bool _loading = true;
  bool _refreshing = false;
  bool _backdropChecked = false;
  int _generation = 0;
  bool _initialLoadStarted = false;
  @override
  void initState() {
    super.initState();
    _work = widget.initialWork;
    unawaited(_loadLogoOverride());
    widget.catalog.store.dataChanges.addListener(_scheduleDetails);
    widget.catalog.store.presentationChanges.addListener(_loadPreferences);
    final app = context.read<AppState>();
    _playbackStores = [
      app.filmMediaLibraryStore,
      app.mediaLibraryStore,
    ].whereType<MediaLibraryStore>().toList();
    for (final store in _playbackStores) {
      store.addListener(_scheduleContinue);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialLoadStarted && !StreamPathTransitionScope.of(context)) {
      _initialLoadStarted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_listenToProgress(context.read<AppState>()));
        unawaited(_load());
      });
    }
  }

  @override
  void dispose() {
    ++_generation;
    for (final reader in _progressReaders) {
      reader.removeListener(_progressChanged);
    }
    for (final reader in _isoReaders) {
      reader.removeLibraryProgressListener(_scheduleContinue);
    }
    widget.catalog.store.dataChanges.removeListener(_scheduleDetails);
    widget.catalog.store.presentationChanges.removeListener(_loadPreferences);
    _detailTimer?.cancel();
    _continueChanges.dispose();
    for (final store in _playbackStores) {
      store.removeListener(_scheduleContinue);
    }
    _scroll.dispose();
    _textColors.dispose();
    super.dispose();
  }

  Future<void> _listenToProgress(AppState app) async {
    await app.initializeFilmPlayback();
    if (!mounted) return;
    _progressReaders.addAll([app.progressService, app.filmProgressService]);
    _isoReaders.addAll([
      app.localDiscPlaybackService,
      app.filmLocalDiscPlaybackService,
      ?app.isoPlaybackService,
      ?app.filmIsoPlaybackService,
    ]);
    for (final reader in _progressReaders) {
      reader.addListener(_progressChanged);
    }
    for (final reader in _isoReaders) {
      reader.addLibraryProgressListener(_scheduleContinue);
    }
  }

  void _progressChanged(PlaybackProgressChange change) {
    if (change.affectsAll ||
        change.profileId == _continueRecord?.item.sourceId) {
      _scheduleContinue();
    }
  }

  Future<(int?, int?)> _continueProgress(
    AppState app,
    MediaLibraryRecord record,
    bool film,
  ) async {
    final item = record.item;
    if (item.kind == MediaLibraryKind.strm) {
      return (record.strmPositionMs, record.strmDurationMs);
    }
    final target = app.resolveMediaLibraryTarget(item, allowLogicalPath: true);
    if (target == null) return (null, null);
    if (item.kind == MediaLibraryKind.iso) {
      if (item.playbackMode == PlaybackMode.webdavHdmvMenu) return (null, null);
      final IsoLibraryProgressReader? reader =
          item.sourceKind == MediaSourceKind.local &&
              item.playbackMode == PlaybackMode.localHdmvMenu
          ? film
                ? app.filmLocalDiscPlaybackService
                : app.localDiscPlaybackService
          : film
          ? app.filmIsoPlaybackService
          : app.isoPlaybackService;
      var progress = await reader?.getLibraryProgress(
        profileId: item.sourceId,
        resolvedUrl: target,
        playbackMode: item.playbackMode,
      );
      if (progress == null &&
          item.sourceKind == MediaSourceKind.local &&
          item.playbackMode != PlaybackMode.localHdmvMenu) {
        progress =
            await (film
                    ? app.filmLocalDiscPlaybackService
                    : app.localDiscPlaybackService)
                .getLibraryProgress(
                  profileId: item.sourceId,
                  resolvedUrl: target,
                  playbackMode: item.playbackMode,
                );
      }
      return (
        progress?.position.inMilliseconds,
        progress?.duration?.inMilliseconds,
      );
    }
    final progress =
        await (film ? app.filmProgressService : app.progressService)
            .getResumeProgress(target, profileId: item.sourceId);
    return (progress?.positionMs, progress?.durationMs);
  }

  /// 详情页与主页共用同一完成判定：仅末项且达到 99% 时视为已完成。
  bool _completedContinue(
    MediaLibraryRecord? record,
    int? positionMs,
    int? durationMs,
  ) {
    if (record == null || !record.item.kind.isVideoLane) return false;
    final index = record.playlistIndex;
    final count = record.playlistCount;
    if (index != null && count != null && index != count - 1) return false;
    if (positionMs == null ||
        positionMs <= 0 ||
        durationMs == null ||
        durationMs <= 0) {
      return false;
    }
    return positionMs / durationMs >= .99;
  }

  Widget _metadata(FilmWork work, List<String> tags, Color foreground) {
    final score = work.metadata['vote_average'] as num?;
    final minutes = work.type == FilmMediaType.movie
        ? _resources
              .map((r) => _probes[r.id]?['duration'])
              .whereType<num>()
              .where((duration) => duration > 0)
              .map((duration) => (duration / 60).round())
              .toSet()
              .toList()
        : <int>[];
    final genres = (work.metadata['genres'] as List? ?? [])
        .whereType<String>()
        .where((genre) => genre.isNotEmpty);
    return Wrap(
      key: const Key('film-detail-metadata'),
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (score != null && score > 0)
          Tooltip(
            message: context.l10n.format('TMDB 评分：{score}（{votes} 票）', {
              'score': score,
              'votes': work.metadata['vote_count'] ?? 0,
            }),
            child: FilmInformationPill(
              foreground: foreground,
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '★ ${score.toStringAsFixed(1)}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    TextSpan(
                      text: '  ${context.l10n.text('TMDB')}',
                      style: TextStyle(color: foreground.withValues(alpha: .7)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (work.year != null)
          FilmInformationPill(
            foreground: foreground,
            child: Text('${work.year}'),
          ),
        if (minutes.isNotEmpty || work.metadata['runtime'] != null)
          FilmInformationPill(
            foreground: foreground,
            child: Text(
              context.l10n.format('{minutes} 分钟', {
                'minutes': minutes.isEmpty
                    ? work.metadata['runtime']
                    : minutes.join(' & '),
              }),
            ),
          ),
        for (final genre in genres)
          FilmInformationPill(foreground: foreground, child: Text(genre)),
        for (final tag in tags)
          FilmInformationPill(foreground: foreground, child: Text(tag)),
        FilmCertificationBadge(rating: work.certification, color: foreground),
      ],
    );
  }

  Widget _overview(
    FilmWork work,
    FilmCatalogController catalog,
    Color foreground,
  ) => LayoutBuilder(
    builder: (context, constraints) {
      final style = Theme.of(context).textTheme.bodyMedium!.copyWith(
        height: 1.55,
        color: foreground,
        fontWeight: FontWeight.w400,
      );
      final painter = TextPainter(
        text: TextSpan(text: work.overview, style: style),
        maxLines: 4,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.localeOf(context),
      )..layout(maxWidth: constraints.maxWidth);
      final overflows = painter.didExceedMaxLines;
      painter.dispose();
      final text = Text(
        key: _overviewTextKey,
        work.overview,
        maxLines: _expandedOverview ? null : 4,
        overflow: TextOverflow.clip,
        style: style,
      );
      return FilmWatchOverlay(
        store: catalog.store,
        workId: work.id,
        rootId: catalog.rootId,
        spoilerSensitive: true,
        showStatus: false,
        revealBelow: true,
        footer: overflows
            ? TextButton(
                onPressed: () =>
                    setState(() => _expandedOverview = !_expandedOverview),
                child: AppText(_expandedOverview ? '收起简介' : '展开简介'),
              )
            : null,
        child: overflows && !_expandedOverview
            ? ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (bounds) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.white, Colors.white, Colors.transparent],
                  stops: [0, .72, 1],
                ).createShader(bounds),
                child: text,
              )
            : text,
      );
    },
  );

  int _preferenceGeneration = 0;
  Future<void> _loadPreferences() async {
    final generation = ++_preferenceGeneration;
    final favorite = await widget.catalog.store.isFavorite(widget.workId);
    final selection = _work == null
        ? null
        : await widget.catalog.store.versionSelection(
            _work!.identity,
            sourceScope: widget.catalog.sourceId,
          );
    if (!mounted || generation != _preferenceGeneration) return;
    final versionChanged =
        selection?.defaultKey != _versionSelection?.defaultKey ||
        !mapEquals(selection?.seasons, _versionSelection?.seasons);
    if (favorite != _favorite || versionChanged) {
      setState(() {
        _favorite = favorite;
        _versionSelection = selection;
      });
      if (versionChanged) _scheduleContinue();
    }
  }

  final _continueChanges = ValueNotifier<int>(0);
  int _continueGeneration = 0;
  Timer? _detailTimer;
  Future<void>? _detailLoad;
  bool _detailsPending = false;

  void _scheduleDetails() {
    _detailTimer?.cancel();
    _detailTimer = Timer(Duration.zero, _load);
  }

  void _scheduleContinue() {
    unawaited(_load(playbackOnly: true));
  }

  Future<void> _load({bool playbackOnly = false}) {
    if (!mounted) return Future.value();
    if (playbackOnly) {
      if (_loading) return Future.value();
      return _readDetails(playbackOnly: true);
    }
    if (_detailLoad != null) {
      _detailsPending = true;
      ++_generation;
      return _detailLoad!;
    }
    _detailTimer?.cancel();
    return _detailLoad = _drainDetails();
  }

  Future<void> _drainDetails() async {
    try {
      do {
        _detailsPending = false;
        await _readDetails();
      } while (_detailsPending && mounted);
    } finally {
      _detailLoad = null;
    }
  }

  Future<void> _readDetails({bool playbackOnly = false}) async {
    if (StreamPathTransitionScope.read(context)) return;
    final app = context.read<AppState>();
    final generation = playbackOnly ? _generation : ++_generation;
    final continueGeneration = ++_continueGeneration;
    await widget.catalog.run(() async {
      final work = playbackOnly
          ? _work
          : await widget.catalog.store.work(widget.workId);
      final favorite = playbackOnly
          ? _favorite
          : await widget.catalog.store.isFavorite(widget.workId);
      final resources = playbackOnly
          ? _resources
          : await widget.catalog.store.resources(
              workId: widget.workId,
              sourceId: widget.catalog.sourceId,
              enabledOnly: true,
            );
      if (!mounted) return;
      final records = <MediaLibraryRecord>[];
      MediaLibraryRecord? recentVersionRecord;
      final filmRecords = <MediaLibraryRecord>{};
      final paths = {
        for (final r in resources.where(
          (r) => work?.type != FilmMediaType.movie || r.isMovieMain,
        ))
          '${r.sourceId}\u0000${r.path}',
      };
      for (final library in _playbackStores) {
        for (final source in resources.map((r) => r.sourceId).toSet()) {
          for (final iso in [false, true]) {
            final available =
                (await library.playbackHistory(source, audio: false, iso: iso))
                    .where(
                      (record) => paths.contains(
                        '${record.item.sourceId}\u0000${record.item.targetPath}',
                      ),
                    )
                    .toList();
            for (final record in available) {
              if (recentVersionRecord == null ||
                  record.updatedAt.isAfter(recentVersionRecord.updatedAt)) {
                recentVersionRecord = record;
              }
            }
            final matching = available
                .where((r) => !r.continueDismissed)
                .toList();
            records.addAll(matching);
            if (library == app.filmMediaLibraryStore) {
              filmRecords.addAll(matching);
            }
          }
        }
      }
      records.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      final versions = playbackOnly ? _versions : FilmVersionIndex(resources);
      FilmVersionSelection? selection = playbackOnly ? _versionSelection : null;
      if (work?.type == FilmMediaType.tv && versions.families.isNotEmpty) {
        selection ??= await widget.catalog.store.versionSelection(
          work!.identity,
          sourceScope: widget.catalog.sourceId,
        );
        if (selection == null) {
          selection = versions.initial(
            recentSource: recentVersionRecord?.item.sourceId,
            recentPath: recentVersionRecord?.item.targetPath,
          );
          await widget.catalog.store.saveVersionSelection(
            work!.identity,
            selection,
            sourceScope: widget.catalog.sourceId,
          );
        }
        final allowed = versions
            .selected(selection)
            .map((r) => '${r.sourceId}\u0000${r.path}')
            .toSet();
        records.removeWhere(
          (r) =>
              r.item.kind.isVideoLane &&
              !allowed.contains('${r.item.sourceId}\u0000${r.item.targetPath}'),
        );
      }
      await app.initializeFilmPlayback();
      if (!mounted || generation != _generation) return;
      final record = records.firstOrNull;
      final (positionMs, durationMs) = record == null
          ? (null, null)
          : await _continueProgress(app, record, filmRecords.contains(record));
      final continueRecord = _completedContinue(record, positionMs, durationMs)
          ? null
          : record;
      if (playbackOnly) {
        if (mounted &&
            generation == _generation &&
            continueGeneration == _continueGeneration) {
          _continueRecord = continueRecord;
          _continuePositionMs = continueRecord == null ? null : positionMs;
          _continueDurationMs = continueRecord == null ? null : durationMs;
          _continueChanges.value++;
        }
        return;
      }
      final episodes = <(int?, int?), Map>{};
      final probes = await widget.catalog.store.probes(
        resources.map((r) => r.id),
      );
      for (final number
          in resources.map((r) => r.season).whereType<int>().toSet()) {
        final metadata = await widget.catalog.store.season(
          widget.workId,
          number,
        );
        for (final episode
            in (metadata?['episodes'] as List? ?? []).whereType<Map>()) {
          episodes.putIfAbsent((
            number,
            episode['episode_number'] as int?,
          ), () => episode);
        }
      }
      if (mounted && generation == _generation) {
        setState(() {
          _work = work;
          _favorite = favorite;
          _resources = resources;
          _versions = versions;
          _visibleSnapshot = null;
          _versionSelection = selection;
          if (continueGeneration == _continueGeneration) {
            _continueRecord = continueRecord;
            _continuePositionMs = continueRecord == null ? null : positionMs;
            _continueDurationMs = continueRecord == null ? null : durationMs;
          }
          _episodes = episodes;
          _probes = probes;
          final numbers = resources.map((r) => r.season).toSet().toList()
            ..sort((a, b) => (a ?? 9999).compareTo(b ?? 9999));
          if (_loading || !numbers.contains(_activeSeason)) {
            _activeSeason =
                numbers.whereType<int>().where((n) => n > 0).firstOrNull ??
                numbers.firstOrNull;
          }
          _loading = false;
          _selected.removeWhere((id) => !resources.any((r) => r.id == id));
        });
      }
      if (mounted && !_backdropChecked && work != null) {
        _backdropChecked = true;
        if (work.tmdbId > 0 &&
            work.metadataOrigin == 'network' &&
            (work.metadata['presentation_version'] != 5 ||
                work.metadata['certification_version'] != 1) &&
            await widget.catalog.tmdb.hasToken()) {
          await widget.catalog.store.refreshWork(
            await widget.catalog.matcher.lookup(
              work.type,
              work.tmdbId,
              refresh: true,
            ),
          );
        }
      }
    }, clearError: false);
    if (mounted && generation == _generation && _loading) {
      setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    await widget.catalog.run(() => widget.catalog.matcher.refresh(_work!));
    if (mounted) setState(() => _refreshing = false);
    await _load();
  }

  Future<void> _posterMenu(Offset position) => showFilmWorkMenu(
    context,
    catalog: widget.catalog,
    work: _work!,
    position: position,
    refreshing: _refreshing,
    onRefresh: _refresh,
  );

  List<Map> get _logoCandidates =>
      (_work?.metadata['logo_candidates'] as List? ?? [])
          .whereType<Map>()
          .where((candidate) => candidate['path'] is String)
          .toList(growable: false);

  Future<void> _loadLogoOverride() async {
    final path = await widget.catalog.store.logoOverride(widget.workId);
    if (!mounted || path == _logoOverride) return;
    setState(() => _logoOverride = path);
  }

  Future<void> _logoMenu(Offset position) async {
    if (_logoCandidates.length < 2) return;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final local = overlay.globalToLocal(position);
    final action = await showSPMenu<String>(
      context: context,
      color: AppTheme.dropdownMenuColor(Theme.of(context)),
      shape: RoundedRectangleBorder(
        borderRadius: AppTheme.dropdownBorderRadius,
      ),
      position: RelativeRect.fromRect(
        Rect.fromLTWH(local.dx, local.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(
          value: 'logo',
          child: SPMenuItemContent(
            icon: SPIcons.image,
            child: AppText('更换 Logo'),
          ),
        ),
      ],
    );
    if (action == null || !mounted) return;
    await _pickLogo();
  }

  Future<void> _pickLogo() async {
    final work = _work;
    if (work == null || _logoCandidates.length < 2) return;
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => _LogoPickerDialog(
        cache: widget.catalog.images,
        candidates: _logoCandidates,
        current: _logoOverride ?? work.metadata['logo_path'] as String?,
      ),
    );
    if (chosen == null || !mounted) return;
    await widget.catalog.store.setLogoOverride(work.id, chosen);
    if (!mounted) return;
    setState(() => _logoOverride = chosen);
  }

  Map? _episode(FilmResource resource) =>
      _episodes[(resource.season, resource.episode)];

  Future<void> _playDefault(FilmResource resource) async {
    if (resource.type == FilmMediaType.tv && !resource.isDisc) {
      await _openVersionItem(resource.playbackItem);
      return;
    }
    final app = context.read<AppState>();
    var selected = resource;
    for (final version in _resources.where(
      (r) =>
          r.sourceId == resource.sourceId &&
          r.workId == resource.workId &&
          r.season == resource.season &&
          r.episode == resource.episode &&
          (resource.type != FilmMediaType.movie || r.isMovieMain) &&
          r.availability == 'present',
    )) {
      if (await app.cachedTarget(version.sourceId, version.path) != null) {
        selected = version;
        break;
      }
    }
    if (mounted) await widget.onOpenItem(selected.playbackItem);
  }

  Widget _cards(List<FilmResource> resources, AppState app, FilmWork work) {
    Object? layoutKey;
    Widget? sliver;
    var rowHeights = <double>[];
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.crossAxisExtent / 270).floor().clamp(1, 6);
        final width =
            (constraints.crossAxisExtent - 16 * (columns - 1)) / columns;
        if (resources.isEmpty && _loading) {
          return SliverToBoxAdapter(
            child: Align(
              alignment: AlignmentDirectional.topStart,
              child: SizedBox(
                width: width,
                child: SkeletonRegion(
                  borderRadius: AppTheme.panelRadius,
                  child: Column(
                    children: [
                      const AspectRatio(aspectRatio: 16 / 9),
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: SizedBox(
                          height: MediaQuery.textScalerOf(context).scale(40),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }
        final text = Theme.of(context).textTheme;
        final nextKey = (
          constraints.crossAxisExtent,
          MediaQuery.textScalerOf(context),
          text.bodySmall!.fontSize,
          text.titleSmall!.fontSize,
          text.titleSmall!.height,
          CardTheme.of(context).margin,
          Directionality.of(context),
        );
        // 滚动约束变化时复用 delegate，保留缓存范围内的卡片。
        if (layoutKey == nextKey) return sliver!;
        layoutKey = nextKey;
        final timedHeight = FilmEpisodeCard._collapsedHeight(
          context,
          width,
          hasTiming: true,
        );
        final plainHeight = FilmEpisodeCard._collapsedHeight(
          context,
          width,
          hasTiming: false,
        );
        final hasDate = (work.metadata['release_date'] as String? ?? '')
            .trim()
            .isNotEmpty;
        final officialRuntime = (work.metadata['runtime'] as num?)?.toInt();
        rowHeights = [];
        for (var start = 0; start < resources.length; start += columns) {
          var height = 0.0;
          for (
            var i = start;
            i < math.min(resources.length, start + columns);
            i++
          ) {
            final resource = resources[i];
            final hasTiming =
                resource.type == FilmMediaType.tv ||
                hasDate ||
                (FilmEpisodeCard._runtime(
                          _probes[resource.id],
                          null,
                          resource.isExtra ? null : officialRuntime,
                        ) ??
                        0) >
                    0;
            height = math.max(height, hasTiming ? timedHeight : plainHeight);
          }
          rowHeights.add(height + (start == 0 ? 0 : 16));
        }
        return sliver = SliverVariedExtentList.builder(
          itemCount: rowHeights.length,
          itemExtentBuilder: (row, dimensions) => rowHeights[row],
          itemBuilder: (context, row) => Padding(
            padding: EdgeInsets.only(top: row == 0 ? 0 : 16),
            child: Wrap(
              spacing: 16,
              children: [
                for (
                  var i = row * columns;
                  i < math.min(resources.length, (row + 1) * columns);
                  i++
                )
                  SizedBox(
                    key: ValueKey(
                      resources[i].episode != null &&
                              work.type == FilmMediaType.tv &&
                              !resources[i].isDisc
                          ? 'film-episode-slot-${work.id}-${resources[i].season}-${resources[i].episode}'
                          : 'film-resource-slot-${resources[i].id}',
                    ),
                    width: width,
                    child: SkeletonRegion(
                      borderRadius: AppTheme.panelRadius,
                      child: FilmEpisodeCard(
                        resource: resources[i],
                        stableEpisodeIdentity: true,
                        catalog: widget.catalog,
                        episode: _episode(resources[i]),
                        probe: _probes[resources[i].id],
                        state: filmResourceState(app, resources[i]),
                        displayTitle:
                            resources[i].isExtra &&
                                work.type == FilmMediaType.movie
                            ? resources[i].name
                            : work.title,
                        artworkPath: work.backdropPath,
                        releaseDate: work.metadata['release_date'] as String?,
                        officialRuntime: resources[i].isExtra
                            ? null
                            : (work.metadata['runtime'] as num?)?.toInt(),
                        key: ValueKey(
                          work.type == FilmMediaType.tv &&
                                  resources[i].episode != null &&
                                  !resources[i].isDisc
                              ? 'film-episode-${work.id}-${resources[i].season}-${resources[i].episode}'
                              : 'film-resource-card-${resources[i].id}',
                        ),
                        onOpenItem: _openVersionItem,
                        onChanged: _load,
                        selected: _selected.contains(resources[i].id),
                        onSelected: work.type != FilmMediaType.tv
                            ? null
                            : (selected) => setState(() {
                                if (selected) {
                                  _selected.add(resources[i].id);
                                } else {
                                  _selected.remove(resources[i].id);
                                }
                              }),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _extraHeader(List<FilmResource> resources, {String? title}) =>
      SizedBox(
        width: double.infinity,
        child: Wrap(
          spacing: 16,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: title == null
              ? WrapAlignment.end
              : WrapAlignment.spaceBetween,
          children: [
            if (title != null)
              AppText(title, style: Theme.of(context).textTheme.titleLarge),
            FilmExtraFilter(
              store: widget.catalog.store,
              resources: resources,
              selected: _extraFilter,
              onChanged: (value) => setState(() => _extraFilter = value),
            ),
          ],
        ),
      );

  List<FilmResource> _filteredExtras(List<FilmResource> resources) =>
      _extraFilter == null ||
          !resources.any((r) => filmExtraFilterKey(r) == _extraFilter)
      ? resources
      : resources.where((r) => filmExtraFilterKey(r) == _extraFilter).toList();

  List<Widget> _movieSections(AppState app, FilmWork work) {
    final main = _resources.where((r) => r.isMovieMain).toList();
    final extras = _resources.where((r) => r.isExtra).toList();
    final unknown = _resources
        .where((r) => !r.isExtra && !r.isMovieMain)
        .toList();
    return [
      if (main.isEmpty && !_loading)
        const SliverToBoxAdapter(child: AppText('请选择资源播放，或将正片标记为非特典')),
      if (main.isNotEmpty || _loading) ...[
        SliverToBoxAdapter(
          child: AppText(
            '正片与版本',
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        SliverToBoxAdapter(child: const SizedBox(height: 12)),
        _cards(main, app, work),
      ],
      if (extras.isNotEmpty) ...[
        SliverToBoxAdapter(child: const SizedBox(height: 24)),
        SliverToBoxAdapter(child: _extraHeader(extras, title: '特典映像')),
        SliverToBoxAdapter(child: const SizedBox(height: 12)),
        _cards(_filteredExtras(extras), app, work),
      ],
      if (unknown.isNotEmpty) ...[
        SliverToBoxAdapter(child: const SizedBox(height: 24)),
        SliverToBoxAdapter(
          child: AppText(
            '待确认资源',
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        SliverToBoxAdapter(child: const SizedBox(height: 8)),
        SliverToBoxAdapter(child: const SizedBox(height: 12)),
        _cards(unknown, app, work),
      ],
    ];
  }

  Widget _seasonSelector(FilmWork work, List<int?> numbers) => LayoutBuilder(
    builder: (context, constraints) {
      final versionFamilies = _activeSeason == null
          ? const <FilmVersionFamily>[]
          : _versions.families
                .where((f) => f.resources.any((r) => r.season == _activeSeason))
                .toList();
      return Wrap(
        spacing: 16,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SkeletonRegion(
            child: AppText(
              '剧集列表',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (numbers.isNotEmpty)
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth),
              child: SkeletonRegion(
                key: const Key('film-season-selector'),
                borderRadius: AppTheme.pillRadius,
                child: DirectoryScrollView(
                  scrollDirection: Axis.horizontal,
                  hideScrollbar: true,
                  builder: (controller) => SingleChildScrollView(
                    controller: controller,
                    scrollDirection: Axis.horizontal,
                    child: FilmSegmentedControl<int?>(
                      compact: true,
                      selected: _activeSeason,
                      onSelectionChanged: (number) =>
                          setState(() => _activeSeason = number),
                      onSecondaryTapDown: (number, position) {
                        if (number == null) return;
                        showFilmWatchMenu(
                          context,
                          catalog: widget.catalog,
                          playlistScope: FilmPlaylistScope.work(
                            work.id,
                            season: number,
                          ),
                          title:
                              '${work.title} S${number.toString().padLeft(2, '0')}',
                          position: position,
                          resources: _resources
                              .where((r) => r.season == number)
                              .toList(),
                        );
                      },
                      segments: [
                        for (final number in numbers)
                          ButtonSegment<int?>(
                            value: number,
                            label: Text(
                              '${number == null
                                  ? context.l10n.text('集号待确认')
                                  : number == 0
                                  ? context.l10n.text('特别篇')
                                  : context.l10n.format('第 {season} 季', {'season': number})} (${_visibleResources.where((r) => r.season == number).length})',
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (_activeSeason != null &&
              _versionSelection != null &&
              (versionFamilies.length > 1 ||
                  !versionFamilies.any(
                    (f) =>
                        f.key == _versionSelection!.forSeason(_activeSeason!),
                  )))
            SkeletonRegion(
              borderRadius: AppTheme.pillRadius,
              child: _seasonVersionSelector(
                constraints.maxWidth,
                versionFamilies,
              ),
            ),
          if (_versions.unresolved.isNotEmpty)
            SkeletonRegion(
              child: TextButton(
                onPressed: () => showFilmVersionMapping(
                  context,
                  widget.catalog,
                  _resources
                      .where(
                        (r) =>
                            !r.isDisc && r.season != null && r.episode != null,
                      )
                      .toList(),
                ),
                child: const AppText('确认版本归属'),
              ),
            ),
        ],
      );
    },
  );

  Widget _seasonVersionSelector(
    double maxWidth,
    List<FilmVersionFamily> families,
  ) {
    final key = _versionSelection!.forSeason(_activeSeason!);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: DirectoryScrollView(
        scrollDirection: Axis.horizontal,
        hideScrollbar: true,
        builder: (controller) => SingleChildScrollView(
          controller: controller,
          scrollDirection: Axis.horizontal,
          child: FilmSegmentedControl<String>(
            key: const Key('film-season-version-selector'),
            compact: true,
            selected: key,
            onSelectionChanged: (value) =>
                _changeVersion(value, season: _activeSeason),
            segments: [
              if (!families.any((f) => f.key == key))
                ButtonSegment(
                  value: key,
                  enabled: false,
                  label: const AppText('所选版本在本季不可用'),
                ),
              for (final f in families)
                ButtonSegment(
                  value: f.key,
                  enabled: families.length > 1 || f.key != key,
                  tooltip: f.name,
                  label: Text(
                    '${f.name} (${f.count(_activeSeason!)})',
                    maxLines: 1,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _workVersionSelector() {
    final selection = _versionSelection!;
    return SizedBox(
      width: 300,
      key: const Key('film-work-version-selector'),
      child: SPDropdownButtonFormField<String>(
        key: _workVersionField,
        initialValue: selection.defaultKey,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: context.l10n.text(
            selection.seasons.isEmpty ? '全剧版本' : '全剧版本（部分季已单独设置）',
          ),
        ),
        onChanged: _versions.families.length > 1 || selection.seasons.isNotEmpty
            ? (key) {
                if (key != null) _changeVersion(key);
              }
            : null,
        items: [
          if (_versions.family(selection.defaultKey) == null)
            DropdownMenuItem(
              value: selection.defaultKey,
              child: const AppText('所选版本不可用'),
            ),
          for (final f in _versions.families)
            DropdownMenuItem(
              value: f.key,
              child: Tooltip(
                message: f.name,
                child: Text(f.name, overflow: TextOverflow.ellipsis),
              ),
            ),
        ],
      ),
    );
  }

  Widget _credits(FilmWork work, FilmCatalogController c) {
    const jobs = {
      'Director': '导演',
      'Writer': '编剧',
      'Screenplay': '编剧',
      'Producer': '制片人',
      'Executive Producer': '执行制片人',
      'Original Music Composer': '作曲',
      'Director of Photography': '摄影指导',
      'Editor': '剪辑',
      'Original Story': '原作',
      'Novel': '原作',
    };
    final credits = work.metadata['credits'] as Map?;
    final people = [
      ...(credits?['cast'] as List? ?? []),
      ...(credits?['crew'] as List? ?? []),
    ].whereType<Map>().toList();
    return FilmShelf(
      title: '演职人员',
      titleWidget: Align(
        alignment: Alignment.centerLeft,
        child: SkeletonRegion(
          child: AppText(
            '演职人员',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontSize: 22),
          ),
        ),
      ),
      count: people.isEmpty && _loading ? 8 : people.length,
      height: 84 + MediaQuery.textScalerOf(context).scale(14) * 4,
      itemWidth: 112,
      horizontal: true,
      builder: (_, i) {
        final person = people.isEmpty ? <String, dynamic>{} : people[i];
        final name = person['name'] as String? ?? '';
        final profilePath = person['profile_path'] as String?;
        final words = name.trim().split(RegExp(r'\s+'));
        final initials = words.length > 1
            ? '${words.first.characters.first}${words.last.characters.first}'
                  .toUpperCase()
            : name.characters.take(1).toString().toUpperCase();
        final theme = Theme.of(context);
        return Column(
          children: [
            GestureDetector(
              onTap: person['id'] == null
                  ? null
                  : () async {
                      final chrome = context.read<ValueNotifier<double?>?>();
                      final previous = chrome?.value;
                      chrome?.value = null;
                      final route = MaterialPageRoute<void>(
                        builder: (_) => StreamPathTransitionContent(
                          shellBuilder: (_) => const StreamPathPageShell(),
                          contentBuilder: (_) => FilmRelatedPage(
                            catalog: c,
                            title: person['name'] as String? ?? '',
                            personId:
                                person['identity'] as String? ??
                                'tmdb:${person['id']}',
                            onOpenItem: widget.onOpenItem,
                            onContinueSelected: widget.onContinueSelected,
                            onContinueMenu: widget.onContinueMenu,
                          ),
                        ),
                      );
                      _relatedRoute = route;
                      await Navigator.of(context).push(route);
                      await route.completed;
                      if (mounted &&
                          _relatedRoute == route &&
                          ModalRoute.of(context)?.isActive == true) {
                        _relatedRoute = null;
                        chrome?.value = previous;
                      }
                    },
              child: Padding(
                padding: const EdgeInsets.all(4),
                // 骨架透明度层必须在悬停变换之外，避免变换进入合成层取整。
                child: SkeletonRegion(
                  borderRadius: BorderRadius.circular(999),
                  child: FilmPosterHover(
                    borderRadius: BorderRadius.circular(999),
                    child: FilmPosterHoverSurface(
                      borderRadius: BorderRadius.circular(999),
                      child: ClipOval(
                        child: FilmArtwork(
                          cache: c.images,
                          path: StreamPathTransitionScope.of(context)
                              ? null
                              : profilePath,
                          target: 'w185',
                          width: 68,
                          height: 68,
                          borderRadius: 0,
                          placeholder:
                              profilePath == null || profilePath.isEmpty
                              ? Container(
                                  width: 68,
                                  height: 68,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [
                                        theme.colorScheme.primary.withValues(
                                          alpha: .14,
                                        ),
                                        theme.colorScheme.onSurface.withValues(
                                          alpha: .04,
                                        ),
                                      ],
                                    ),
                                    border: Border.all(
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: .1),
                                    ),
                                  ),
                                  child: Text(
                                    initials,
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.w500,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SkeletonRegion(
              child: SizedBox(
                width: people.isEmpty ? 76 : null,
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ),
            SkeletonRegion(
              child: SizedBox(
                width: people.isEmpty ? 96 : null,
                child: Text(
                  person['character'] != null
                      ? context.l10n.format('饰 {role}', {
                          'role': person['character'],
                        })
                      : context.l10n.text(
                          jobs[person['job']] ??
                              (person['job'] ?? '') as String,
                        ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  FilmResource? _recommended(AppState app, FilmWork work) {
    return recommendedFilmResource(app, work, _visibleResources);
  }

  Widget _playEntry(AppState app, FilmWork work) {
    final target = _recommended(app, work);
    final originalRecord =
        _continueRecord ??
        (target == null
            ? null
            : MediaLibraryRecord(
                item: target.playbackItem,
                updatedAt: DateTime.now(),
              ));
    final record = originalRecord?.copyWith(
      item: _versionItem(originalRecord.item),
    );
    if (record == null && !_loading) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SkeletonRegion(
          child: AppText(
            _continueRecord == null ? '开始播放' : '继续播放',
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: FilmContinueCard.landscapeWidth,
          height: FilmContinueCard.landscapeHeight,
          child: SkeletonRegion(
            borderRadius: AppTheme.panelRadius,
            child: record == null
                ? const SizedBox.expand()
                : FilmContinueCard(
                    catalog: widget.catalog,
                    record: record,
                    positionMs: _continuePositionMs,
                    durationMs: _continueDurationMs,
                    onMenu: widget.onContinueMenu == null
                        ? null
                        : (position) =>
                              widget.onContinueMenu!(record, position),
                    onTap: () =>
                        _continueRecord != null &&
                            widget.onContinueSelected != null
                        ? widget.onContinueSelected!(record)
                        : widget.onOpenItem(record.item),
                  ),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => FilmSpoilerScope(
    key: ValueKey(widget.workId),
    child: Builder(builder: _buildPage),
  );
  Widget _buildPage(BuildContext context) {
    final c = widget.catalog;
    final app = context.read<AppState>();
    context.select<AppState, List<String>>(
      (value) => [
        for (final resource in _resources) filmResourceState(value, resource),
      ],
    );
    final work =
        _work ??
        (_loading
            ? FilmWork(
                id: widget.workId,
                type: FilmMediaType.movie,
                title: '',
                originalTitle: '',
                overview: '',
                language: '',
              )
            : null);
    final theme = Theme.of(context);
    final topInset = MediaQuery.paddingOf(context).top;
    final poster = filmConnectedPoster(context);
    final moving = StreamPathTransitionScope.of(context);
    // 仅在仍使用飞行携带的海报路径时用它兜底，刷新元数据换图后不显示旧图。
    final posterFallback = work?.posterPath == widget.initialWork?.posterPath
        ? poster?.provider
        : null;
    final initialSkeleton = _loading && _work == null;
    final numbers = _resources.map((r) => r.season).toSet().toList()
      ..sort((a, b) {
        if (a == b) return 0;
        if (a == null) return 1;
        if (b == null) return -1;
        if (a == 0) return 1;
        if (b == 0) return -1;
        return a.compareTo(b);
      });
    final playable = _visibleResources
        .where(
          (r) =>
              r.availability == 'present' &&
              (work?.type != FilmMediaType.tv || r.season == _activeSeason),
        )
        .firstOrNull;
    final brief = filmTechnicalTags(
      playable == null ? null : _probes[playable.id],
    );
    return SkeletonScope(
      ready: !_loading,
      enabled: !moving,
      child: StreamPathTransitionBuilder(
        builder: (context) => Scaffold(
          backgroundColor: poster == null ? null : Colors.transparent,
          body: Stack(
            children: [
              if (poster != null)
                Positioned.fill(
                  child: FilmConnectedReveal(
                    part: FilmConnectedPart.background,
                    child: ColoredBox(color: theme.scaffoldBackgroundColor),
                  ),
                ),
              Positioned.fill(
                child: work == null
                    ? const Center(child: AppText('影视目录库操作失败'))
                    : Stack(
                        children: [
                          if (work.backdropPath != null)
                            Positioned.fill(
                              child: FilmConnectedReveal(
                                part: FilmConnectedPart.background,
                                child: FilmDetailBackdrop(
                                  catalog: c,
                                  workId: work.id,
                                  path: work.backdropPath,
                                  textColors: _textColors,
                                  fadeFirstFrame: poster != null,
                                ),
                              ),
                            ),
                          DirectoryScrollView(
                            controller: _scroll,
                            builder: (scrollController) => CustomScrollView(
                              key: const Key('film-detail-scroll'),
                              controller: scrollController,
                              slivers: [
                                SliverPadding(
                                  padding: EdgeInsets.fromLTRB(
                                    24,
                                    topInset + 68,
                                    24,
                                    32,
                                  ),
                                  sliver: SliverMainAxisGroup(
                                    slivers: [
                                      SliverToBoxAdapter(
                                        child: Wrap(
                                          spacing: 24,
                                          runSpacing: 16,
                                          children: [
                                            GestureDetector(
                                              onSecondaryTapDown: (details) =>
                                                  _posterMenu(
                                                    details.globalPosition,
                                                  ),
                                              child: ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                child: Builder(
                                                  builder: (_) {
                                                    final artwork = FilmWatchOverlay(
                                                      rootId:
                                                          widget.catalog.rootId,
                                                      store: c.store,
                                                      workId: work.id,
                                                      child: FilmArtwork(
                                                        key: const Key(
                                                          'film-detail-poster',
                                                        ),
                                                        cache: c.images,
                                                        path: work.posterPath,
                                                        fallbackPath:
                                                            work.posterPath,
                                                        target: 'w500',
                                                        width: 180,
                                                        provider:
                                                            moving && _loading
                                                            ? poster?.provider
                                                            : null,
                                                        fallbackProvider:
                                                            posterFallback,
                                                        showCachedImmediately:
                                                            poster != null,
                                                      ),
                                                    );
                                                    return poster == null
                                                        ? artwork
                                                        : FilmSharedPoster(
                                                            anchor: poster,
                                                            child: FilmConnectedReveal(
                                                              part:
                                                                  FilmConnectedPart
                                                                      .poster,
                                                              child: artwork,
                                                            ),
                                                          );
                                                  },
                                                ),
                                              ),
                                            ),
                                            FilmConnectedReveal(
                                              child: ConstrainedBox(
                                                constraints:
                                                    const BoxConstraints(
                                                      maxWidth: 700,
                                                    ),
                                                child: FilmAdaptiveForeground(
                                                  controller: _textColors,
                                                  textKeys: [
                                                    _titleTextKey,
                                                    _originalTitleTextKey,
                                                    _metadataTextKey,
                                                    _overviewTextKey,
                                                  ],
                                                  scrollController: _scroll,
                                                  builder: (context, foreground) => Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      SkeletonRegion(
                                                        key: const Key(
                                                          'film-skeleton-logo',
                                                        ),
                                                        child: GestureDetector(
                                                          behavior:
                                                              HitTestBehavior
                                                                  .opaque,
                                                          onSecondaryTapDown:
                                                              (
                                                                details,
                                                              ) => _logoMenu(
                                                                details
                                                                    .globalPosition,
                                                              ),
                                                          child: FilmArtwork(
                                                            cache: c.images,
                                                            path:
                                                                moving &&
                                                                    poster !=
                                                                        null
                                                                ? null
                                                                : _logoOverride ??
                                                                      work.metadata['logo_path']
                                                                          as String?,
                                                            target: 'original',
                                                            transparent: true,
                                                            logoInkTint: true,
                                                            logoPadding: 3,
                                                            borderRadius: 0,
                                                            width: 500,
                                                            height: 108,
                                                            placeholder: Align(
                                                              alignment: Alignment
                                                                  .centerLeft,
                                                              child: Text(
                                                                key:
                                                                    _titleTextKey,
                                                                work.title,
                                                                style: theme
                                                                    .textTheme
                                                                    .headlineMedium
                                                                    ?.copyWith(
                                                                      color:
                                                                          foreground,
                                                                    ),
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                      const SizedBox(height: 8),
                                                      SkeletonRegion(
                                                        key: const Key(
                                                          'film-skeleton-original-title',
                                                        ),
                                                        child: SizedBox(
                                                          width: initialSkeleton
                                                              ? 240
                                                              : null,
                                                          child: Text(
                                                            key:
                                                                _originalTitleTextKey,
                                                            work.originalTitle,
                                                            style: theme
                                                                .textTheme
                                                                .titleMedium
                                                                ?.copyWith(
                                                                  color:
                                                                      foreground,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w400,
                                                                ),
                                                          ),
                                                        ),
                                                      ),
                                                      const SizedBox(
                                                        height: 14,
                                                      ),
                                                      SkeletonRegion(
                                                        key: const Key(
                                                          'film-skeleton-metadata',
                                                        ),
                                                        child: SizedBox(
                                                          width: initialSkeleton
                                                              ? 300
                                                              : null,
                                                          height:
                                                              initialSkeleton
                                                              ? 28
                                                              : null,
                                                          child: KeyedSubtree(
                                                            key:
                                                                _metadataTextKey,
                                                            child: _metadata(
                                                              work,
                                                              brief,
                                                              foreground,
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                      const SizedBox(
                                                        height: 16,
                                                      ),
                                                      SkeletonRegion(
                                                        key: const Key(
                                                          'film-skeleton-actions',
                                                        ),
                                                        child: Wrap(
                                                          spacing: 12,
                                                          runSpacing: 8,
                                                          children: [
                                                            if (playable !=
                                                                    null ||
                                                                _loading)
                                                              FilmDetailPlayButton(
                                                                onPressed:
                                                                    playable ==
                                                                        null
                                                                    ? null
                                                                    : () => _playDefault(
                                                                        playable,
                                                                      ),
                                                              ),
                                                            Opacity(
                                                              opacity: _loading
                                                                  ? 0
                                                                  : 1,
                                                              child: FilmDetailActionButton(
                                                                onPressed:
                                                                    _loading
                                                                    ? null
                                                                    : () => c.run(
                                                                        () => c.store.setFavorite(
                                                                          work.id,
                                                                          !_favorite,
                                                                        ),
                                                                      ),
                                                                icon: Icon(
                                                                  _favorite
                                                                      ? SPIcons
                                                                            .favoriteFill
                                                                      : SPIcons
                                                                            .favorite,
                                                                ),
                                                                label: AppText(
                                                                  _favorite
                                                                      ? '取消收藏'
                                                                      : '收藏',
                                                                ),
                                                              ),
                                                            ),
                                                            if (_versionSelection !=
                                                                    null &&
                                                                _versions
                                                                        .families
                                                                        .length >
                                                                    1)
                                                              _workVersionSelector(),
                                                          ],
                                                        ),
                                                      ),
                                                      const SizedBox(
                                                        height: 16,
                                                      ),
                                                      SkeletonRegion(
                                                        key: const Key(
                                                          'film-skeleton-overview',
                                                        ),
                                                        child: SizedBox(
                                                          width: initialSkeleton
                                                              ? 700
                                                              : null,
                                                          height:
                                                              initialSkeleton
                                                              ? MediaQuery.textScalerOf(
                                                                          context,
                                                                        ).scale(
                                                                          theme.textTheme.bodyMedium!.fontSize! *
                                                                              1.55,
                                                                        ) *
                                                                        4 +
                                                                    48
                                                              : null,
                                                          child:
                                                              work
                                                                  .overview
                                                                  .isEmpty
                                                              ? AppText(
                                                                  '暂无简介',
                                                                  style: TextStyle(
                                                                    color:
                                                                        foreground,
                                                                  ),
                                                                )
                                                              : _overview(
                                                                  work,
                                                                  c,
                                                                  foreground,
                                                                ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      FilmConnectedReveal(
                                        sliver: true,
                                        part: FilmConnectedPart.secondary,
                                        child: SliverMainAxisGroup(
                                          slivers: [
                                            SliverToBoxAdapter(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  const SizedBox(height: 28),
                                                  ValueListenableBuilder<int>(
                                                    valueListenable:
                                                        _continueChanges,
                                                    builder:
                                                        (context, _, child) =>
                                                            _playEntry(
                                                              app,
                                                              work,
                                                            ),
                                                  ),
                                                  _credits(work, c),
                                                  if (work.type ==
                                                      FilmMediaType.tv)
                                                    _seasonSelector(
                                                      work,
                                                      numbers,
                                                    ),
                                                  const SizedBox(height: 12),
                                                  if (work.type ==
                                                          FilmMediaType.tv &&
                                                      _versionSelection !=
                                                          null &&
                                                      !_visibleResources.any(
                                                        (r) =>
                                                            r.season ==
                                                            _activeSeason,
                                                      ))
                                                    const AppText(
                                                      '所选版本在本季没有可用剧集',
                                                    ),
                                                  if (_selected.isNotEmpty)
                                                    Wrap(
                                                      spacing: 12,
                                                      children: [
                                                        TextButton(
                                                          onPressed: () async {
                                                            await showFilmEpisodeMapping(
                                                              context,
                                                              c,
                                                              _resources
                                                                  .where(
                                                                    (
                                                                      r,
                                                                    ) => _selected
                                                                        .contains(
                                                                          r.id,
                                                                        ),
                                                                  )
                                                                  .toList(),
                                                            );
                                                            await _load();
                                                          },
                                                          child: const AppText(
                                                            '映射选中文件的季集',
                                                          ),
                                                        ),
                                                        TextButton(
                                                          onPressed: () =>
                                                              setState(
                                                                _selected.clear,
                                                              ),
                                                          child: const AppText(
                                                            '取消选择',
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                ],
                                              ),
                                            ),
                                            if (work.type ==
                                                FilmMediaType.tv) ...[
                                              if (_activeSeason == 0) ...[
                                                SliverToBoxAdapter(
                                                  child: _extraHeader(
                                                    _visibleResources
                                                        .where(
                                                          (r) => r.season == 0,
                                                        )
                                                        .toList(),
                                                  ),
                                                ),
                                                const SliverToBoxAdapter(
                                                  child: SizedBox(height: 12),
                                                ),
                                              ],
                                              _cards(
                                                _activeSeason == 0
                                                    ? _filteredExtras(
                                                        _visibleResources
                                                            .where(
                                                              (r) =>
                                                                  r.season == 0,
                                                            )
                                                            .toList(),
                                                      )
                                                    : _visibleResources
                                                          .where(
                                                            (r) =>
                                                                r.season ==
                                                                _activeSeason,
                                                          )
                                                          .toList(),
                                                app,
                                                work,
                                              ),
                                            ] else
                                              ..._movieSections(app, work),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
              ),
              if (!_loading || poster != null)
                Positioned(
                  top: topInset - 10,
                  left: 4,
                  child: FilmConnectedReveal(
                    child: FilmDetailBackButton(scrollController: _scroll),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _FilmFileAction {
  extraType,
  cache,
  playlist,
  addPlaylist,
  watched,
  unwatched,
  source,
  refresh,
  match,
  mapping,
  select,
}

class FilmEpisodeCard extends StatelessWidget {
  const FilmEpisodeCard({
    super.key,
    required this.resource,
    required this.catalog,
    required this.state,
    required this.onOpenItem,
    required this.onChanged,
    this.episode,
    this.probe,
    this.displayTitle,
    this.artworkPath,
    this.releaseDate,
    this.officialRuntime,
    this.selected = false,
    this.onSelected,
    this.stableEpisodeIdentity = false,
  });
  final FilmResource resource;
  final FilmCatalogController catalog;
  final String state;
  final Map? episode;
  final Map<String, dynamic>? probe;
  final String? displayTitle, artworkPath, releaseDate;
  final int? officialRuntime;
  final Future<void> Function(MediaLibraryItem) onOpenItem;
  final Future<void> Function() onChanged;
  final bool selected;
  final void Function(bool)? onSelected;

  static double _lineHeight(BuildContext context) =>
      MediaQuery.textScalerOf(
        context,
      ).scale(Theme.of(context).textTheme.bodySmall!.fontSize!) *
      1.5;
  static double _titleHeight(BuildContext context) => math.max(
    32.0,
    MediaQuery.textScalerOf(
          context,
        ).scale(Theme.of(context).textTheme.titleSmall!.fontSize!) *
        (Theme.of(context).textTheme.titleSmall!.height ?? 1.4),
  );

  /// 收起卡片的固定槽位与正文共用字号计算，滚动跳转无需逐行测量卡片。
  static double _collapsedHeight(
    BuildContext context,
    double width, {
    required bool hasTiming,
  }) {
    final margin = (CardTheme.of(context).margin ?? const EdgeInsets.all(4))
        .resolve(Directionality.of(context));
    return margin.vertical +
        (width - margin.horizontal) * 9 / 16 +
        24 +
        _titleHeight(context) +
        2 +
        _lineHeight(context) +
        (hasTiming ? 18 + _lineHeight(context) : 0);
  }

  static num? _runtime(Map? probe, Map? episode, int? officialRuntime) {
    final measured = probe?['duration'] is num
        ? probe!['duration'] as num
        : null;
    return measured != null && measured > 0
        ? (measured / 60).round()
        : episode?['runtime'] is num
        ? episode!['runtime'] as num
        : officialRuntime;
  }

  final bool stableEpisodeIdentity;

  Future<void> _menu(BuildContext context, Offset position) async {
    final keepAlive = KeepAliveHandle();
    KeepAliveNotification(keepAlive).dispatch(context);
    try {
      await _showMenu(context, position);
    } finally {
      keepAlive.dispose();
    }
  }

  Future<void> _showMenu(BuildContext context, Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    position = overlay.globalToLocal(position);
    final action = await showSPMenu<_FilmFileAction>(
      context: context,
      color: AppTheme.dropdownMenuColor(Theme.of(context)),
      shape: RoundedRectangleBorder(
        borderRadius: AppTheme.dropdownBorderRadius,
      ),
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        if (!resource.isDisc)
          const PopupMenuItem(
            value: _FilmFileAction.extraType,
            child: SPMenuItemContent(
              icon: SPIcons.settings,
              child: AppText('修改特典类型'),
            ),
          ),
        PopupMenuItem(
          value: _FilmFileAction.cache,
          enabled:
              resource.sourceKind != MediaSourceKind.local &&
              resource.availability == 'present',
          child: const SPMenuItemContent(
            icon: SPIcons.download,
            child: AppText('缓存视频…'),
          ),
        ),
        if (resource.canMarkWatched) ...[
          const PopupMenuItem(
            value: _FilmFileAction.watched,
            child: SPMenuItemContent(
              icon: SPIcons.view,
              child: AppText('标记已看完'),
            ),
          ),
          const PopupMenuItem(
            value: _FilmFileAction.unwatched,
            child: SPMenuItemContent(
              icon: SPIcons.hide,
              child: AppText('标记未观看'),
            ),
          ),
        ],
        const PopupMenuItem(
          value: _FilmFileAction.source,
          child: SPMenuItemContent(
            icon: SPIcons.document,
            child: AppText('查看来源信息'),
          ),
        ),
        const PopupMenuItem(
          value: _FilmFileAction.refresh,
          child: SPMenuItemContent(
            icon: SPIcons.refresh,
            child: AppText('刷新元数据'),
          ),
        ),
        const PopupMenuItem(
          value: _FilmFileAction.match,
          child: SPMenuItemContent(
            icon: SPIcons.manageSearch,
            child: AppText('纠正作品匹配'),
          ),
        ),
        if (resource.type == FilmMediaType.tv && resource.workId != null)
          const PopupMenuItem(
            value: _FilmFileAction.mapping,
            child: SPMenuItemContent(
              icon: SPIcons.sort,
              child: AppText('调整季集'),
            ),
          ),
        if (onSelected != null)
          PopupMenuItem(
            value: _FilmFileAction.select,
            child: SPMenuItemContent(
              icon: SPIcons.checklist,
              child: AppText(selected ? '取消选择' : '选择此集'),
            ),
          ),
        PopupMenuItem(
          value: _FilmFileAction.playlist,
          enabled: !resource.isDisc && resource.availability == 'present',
          child: SPMenuItemContent(
            icon: SPIcons.list,
            child: AppText(
              resource.type == FilmMediaType.tv ? '以本集创建播放列表' : '以本资源创建播放列表',
            ),
          ),
        ),
        PopupMenuItem(
          value: _FilmFileAction.addPlaylist,
          enabled: !resource.isDisc && resource.availability == 'present',
          child: const SPMenuItemContent(
            icon: SPIcons.add,
            child: AppText('加入播放列表…'),
          ),
        ),
      ],
    );
    if (!context.mounted || action == null) return;
    switch (action) {
      case _FilmFileAction.cache:
        await showVideoCacheDialog(
          context,
          catalog,
          FilmPlaylistScope.resource(resource),
          title: displayTitle ?? resource.name,
        );
      case _FilmFileAction.playlist:
      case _FilmFileAction.addPlaylist:
        await showFilmPlaylistDialog(
          context,
          catalog,
          FilmPlaylistScope.resource(resource),
          create: action == _FilmFileAction.playlist,
          title: displayTitle ?? resource.name,
        );
      case _FilmFileAction.watched:
      case _FilmFileAction.unwatched:
        await markFilmWatch(context, [
          resource,
        ], action == _FilmFileAction.watched);
      case _FilmFileAction.source:
        Map<String, dynamic>? info;
        final loaded = await catalog.run(() async {
          info = await catalog.store.probe(resource.id);
        });
        if (!loaded || !context.mounted) return;
        await showGlassDialog<void>(
          context: context,
          builder: (dialogContext) => SPDialog(
            title: const AppText('来源信息'),
            content: SizedBox(
              width: 560,
              child: DirectoryScrollView(
                builder: (scrollController) => SingleChildScrollView(
                  controller: scrollController,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SelectableText(
                        contextMenuBuilder: buildSPTextSelectionMenu,
                        resource.name,
                      ),
                      const SizedBox(height: 12),
                      SelectableText(
                        contextMenuBuilder: buildSPTextSelectionMenu,
                        resource.rootName,
                      ),
                      SelectableText(
                        contextMenuBuilder: buildSPTextSelectionMenu,
                        resource.path,
                      ),
                      const SizedBox(height: 12),
                      AppText(state),
                      if (resource.extraKind != null)
                        Text(
                          filmExtraLabel(
                            context,
                            catalog.store,
                            resource.extraKind!,
                          ),
                        ),
                      Text(
                        context.l10n.text(switch (resource.extraOrigin) {
                          'manual' => '人工分类',
                          'filename' => '文件名识别',
                          'folder' => '目录识别',
                          _ => '尚未分类',
                        }),
                      ),
                      if (resource.extraEvidence != '{}')
                        SelectableText(
                          context.l10n.format('识别依据：{keywords}', {
                            'keywords':
                                ((jsonDecode(resource.extraEvidence)
                                                as Map)['keywords']
                                            as List? ??
                                        [])
                                    .join(' · '),
                          }),
                          contextMenuBuilder: buildSPTextSelectionMenu,
                        ),
                      const Divider(height: 24),
                      FilmTechnicalInfo(info: info),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const AppText('关闭'),
              ),
            ],
          ),
        );
      case _FilmFileAction.refresh:
        await catalog.run(() async {
          final work = await catalog.store.work(resource.workId!);
          if (work != null) await catalog.matcher.refresh(work);
        });
        await onChanged();
      case _FilmFileAction.match:
        await showFilmMatchDialog(context, catalog, resource);
        await onChanged();
      case _FilmFileAction.extraType:
        await catalog.run(
          () => showFilmExtraPicker(context, catalog.store, resource),
        );
        await onChanged();
      case _FilmFileAction.mapping:
        await showFilmEpisodeMapping(context, catalog, [resource]);
        await onChanged();
      case _FilmFileAction.select:
        onSelected!(!selected);
    }
  }

  @override
  Widget build(BuildContext context) => resource.type == FilmMediaType.tv
      ? _FilmEpisodeCardSurface(
          key: ValueKey(
            stableEpisodeIdentity &&
                    resource.episode != null &&
                    !resource.isDisc
                ? (resource.workId, resource.season, resource.episode)
                : resource.id,
          ),
          builder: (expanded, toggle) =>
              _card(context, expanded: expanded, onBodyTap: toggle),
        )
      : _card(context);

  Widget _card(
    BuildContext context, {
    bool expanded = false,
    VoidCallback? onBodyTap,
  }) {
    final tv = resource.type == FilmMediaType.tv;
    final title = episode?['name'] as String?;
    final overview = episode?['overview'] as String? ?? '';
    final hasOverview = overview.trim().isNotEmpty;
    final still = tv ? (episode?['still_path'] as String?) : null;
    final theme = Theme.of(context);
    final measured = probe?['duration'] is num
        ? probe!['duration'] as num
        : null;
    final runtime = _runtime(probe, episode, officialRuntime);
    final rawDate = tv ? (episode?['air_date'] as String?) : releaseDate;
    final airDate = (rawDate ?? '').trim();
    final runtimeText = runtime != null && runtime > 0
        ? context.l10n.format('{minutes} 分钟', {'minutes': runtime})
        : '';
    final timing = [
      if (airDate.isNotEmpty) airDate,
      if (runtimeText.isNotEmpty) runtimeText,
    ];
    final timingDescription = [
      if (airDate.isNotEmpty)
        context.l10n.format(tv ? '播出日期：{date}' : '上映日期：{date}', {
          'date': airDate,
        }),
      if (runtime != null && runtime > 0)
        context.l10n.format(
          measured != null && measured > 0
              ? '影片时长：{minutes} 分钟'
              : '官方时长：{minutes} 分钟',
          {'minutes': runtime},
        ),
    ];
    final compactLineHeight = _lineHeight(context);
    final titleHeight = _titleHeight(context);
    final badges = [
      if (resource.extraKind != null)
        filmExtraLabel(context, catalog.store, resource.extraKind!),
      if (state != '可用') context.l10n.text(state),
      ...filmTechnicalTags(probe),
    ];
    final filenameLine = Tooltip(
      message: resource.name,
      child: SizedBox(
        height: compactLineHeight,
        width: double.infinity,
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(
            resource.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
          ),
        ),
      ),
    );

    final details = expanded
        ? DirectoryScrollView(
            builder: (controller) => SingleChildScrollView(
              controller: controller,
              child: Text(
                hasOverview ? overview : resource.name,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
              ),
            ),
          )
        : hasOverview
        ? SizedBox(
            height: compactLineHeight,
            width: double.infinity,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                overview,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
              ),
            ),
          )
        : filenameLine;

    return GestureDetector(
      onSecondaryTapDown: (details) => _menu(context, details.globalPosition),
      child: Card(
        key: ValueKey(
          stableEpisodeIdentity &&
                  tv &&
                  resource.episode != null &&
                  !resource.isDisc
              ? 'film-episode-surface-${resource.workId}-${resource.season}-${resource.episode}'
              : 'film-resource-${resource.id}',
        ),
        borderOnForeground: false,
        color: Colors.transparent,
        elevation: expanded ? 12 : 0,
        shadowColor: theme.shadowColor,
        surfaceTintColor: Colors.transparent,
        clipBehavior: Clip.none,
        shape: RoundedRectangleBorder(
          borderRadius: AppTheme.panelRadius,
          side: BorderSide(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurface.withValues(alpha: .12),
            width: selected ? 2 : 1,
          ),
        ),
        child: FilmCardGlass(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilmPosterHover(
                borderRadius: AppTheme.panelRadius,
                child: InkWell(
                  hoverColor: Colors.transparent,
                  borderRadius: AppTheme.panelRadius,
                  onTap: () {
                    if (expanded) onBodyTap!();
                    onOpenItem(resource.playbackItem);
                  },
                  child: FilmWatchOverlay(
                    hoverSurface: true,
                    foreground: Stack(
                      children: [
                        const Center(child: FilmPosterHoverPlayIcon()),
                        if (badges.isNotEmpty)
                          PositionedDirectional(
                            top: 8,
                            start: 8,
                            end: 8,
                            child: Align(
                              alignment: AlignmentDirectional.topStart,
                              child: FilmPosterHoverAttachment(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.surface.withValues(
                                      alpha: .86,
                                    ),
                                    borderRadius: AppTheme.controlRadius,
                                  ),
                                  child: Text(
                                    badges.join(' · '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    store: catalog.store,
                    resource: resource,
                    spoilerSensitive: tv,
                    canReveal: tv && !hasOverview,
                    revealLabel: '展示封面',
                    child: ClipRect(
                      child: FilmArtwork(
                        cache: catalog.images,
                        path: still ?? artworkPath,
                        target: still != null ? 'w300' : 'w780',
                        aspectRatio: 16 / 9,
                        borderRadius: 0,
                      ),
                    ),
                  ),
                ),
              ),
              Flexible(
                fit: FlexFit.loose,
                child: AnimatedSize(
                  duration: AppTheme.hoverDuration,
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: InkWell(
                    hoverColor: Colors.transparent,
                    borderRadius: AppTheme.panelRadius,
                    onTap: onBodyTap ?? () => onOpenItem(resource.playbackItem),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            height: titleHeight,
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    tv && title != null && title.isNotEmpty
                                        ? '${resource.episode}. $title'
                                        : tv
                                        ? (resource.episode == null
                                              ? context.l10n.text('集号待确认')
                                              : displayTitle == null
                                              ? context.l10n.format(
                                                  '第 {episode} 集',
                                                  {'episode': resource.episode},
                                                )
                                              : '${resource.episode}. $displayTitle')
                                        : displayTitle ?? resource.name,
                                    style: theme.textTheme.titleSmall,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Builder(
                                  builder: (buttonContext) => IconButton(
                                    visualDensity: VisualDensity.compact,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints.tightFor(
                                      width: 32,
                                      height: 32,
                                    ),
                                    iconSize: 18,
                                    icon: const Icon(SPIcons.more),
                                    tooltip: context.l10n.text('更多操作'),
                                    onPressed: () {
                                      final box =
                                          buttonContext.findRenderObject()!
                                              as RenderBox;
                                      _menu(
                                        context,
                                        box.localToGlobal(
                                          Offset(0, box.size.height),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (tv)
                            Flexible(
                              fit: FlexFit.loose,
                              child: Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: TextButtonTheme(
                                  data: TextButtonThemeData(
                                    style: TextButton.styleFrom(
                                      minimumSize: Size.zero,
                                      padding: EdgeInsets.zero,
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      textStyle: theme.textTheme.bodySmall,
                                    ),
                                  ),
                                  child: hasOverview
                                      ? FilmWatchOverlay(
                                          store: catalog.store,
                                          resource: resource,
                                          spoilerSensitive: true,
                                          showStatus: false,
                                          softEdges: true,
                                          revealLabel: '展示封面',
                                          child: details,
                                        )
                                      : details,
                                ),
                              ),
                            )
                          else
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: filenameLine,
                            ),
                          if (tv || timing.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  border: Border(
                                    top: BorderSide(
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: .08),
                                    ),
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Tooltip(
                                    message: timingDescription.join(' · '),
                                    child: SizedBox(
                                      height: compactLineHeight,
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          Expanded(
                                            child: Text(
                                              airDate,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.textTheme.bodySmall,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Flexible(
                                            child: Text(
                                              runtimeText,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.textTheme.bodySmall,
                                              textAlign: TextAlign.end,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
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

class _FilmEpisodeCardSurface extends StatefulWidget {
  const _FilmEpisodeCardSurface({super.key, required this.builder});
  final Widget Function(bool expanded, VoidCallback toggle) builder;
  @override
  State<_FilmEpisodeCardSurface> createState() =>
      _FilmEpisodeCardSurfaceState();
}

class _FilmEpisodeCardSurfaceState extends State<_FilmEpisodeCardSurface>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => _open;
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _anchorKey = GlobalKey();
  final _cardKey = GlobalKey();
  late final AnimationController _lift;
  Size? _sourceSize;
  bool _open = false, _expanded = false, _closing = false;

  @override
  void initState() {
    super.initState();
    _lift = AnimationController(vsync: this, duration: AppTheme.hoverDuration);
  }

  void _toggle() {
    if (_open) {
      _close();
      return;
    }
    _sourceSize =
        (_anchorKey.currentContext!.findRenderObject()! as RenderBox).size;
    setState(() => _open = true);
    updateKeepAlive();
    _portal.show();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_open || _closing) return;
      setState(() => _expanded = true);
      _lift.forward();
    });
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    setState(() => _expanded = false);
    await _lift.animateBack(0, duration: AppTheme.hoverDuration);
    if (!mounted) return;
    _portal.hide();
    setState(() {
      _open = false;
      _closing = false;
    });
    updateKeepAlive();
  }

  Widget _card() =>
      KeyedSubtree(key: _cardKey, child: widget.builder(_expanded, _toggle));

  @override
  void dispose() {
    _lift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return CompositedTransformTarget(
      key: _anchorKey,
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (context) => Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final overlay =
                  Overlay.of(context).context.findRenderObject()! as RenderBox;
              final anchor =
                  _anchorKey.currentContext!.findRenderObject()! as RenderBox;
              final origin = anchor.localToGlobal(
                Offset.zero,
                ancestor: overlay,
              );
              final width = math.min(
                _sourceSize!.width,
                constraints.maxWidth - 32,
              );
              final left = origin.dx.clamp(
                16.0,
                math.max(16.0, constraints.maxWidth - width - 16),
              );
              final minTop = 16 + AppTheme.posterHoverLift;
              final top = origin.dy.clamp(
                minTop,
                math.max(
                  minTop,
                  constraints.maxHeight - _sourceSize!.height - 120,
                ),
              );
              return FocusScope(
                autofocus: true,
                child: Focus(
                  autofocus: true,
                  onKeyEvent: (_, event) {
                    if (event is KeyDownEvent &&
                        event.logicalKey == LogicalKeyboardKey.escape) {
                      _close();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _close,
                        ),
                      ),
                      Positioned(
                        left: 0,
                        top: 0,
                        width: width,
                        child: AnimatedBuilder(
                          animation: _lift,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: constraints.maxHeight - top - 16,
                            ),
                            child: _card(),
                          ),
                          builder: (_, child) {
                            final progress = Curves.easeOutCubic.transform(
                              _lift.value,
                            );
                            return CompositedTransformFollower(
                              link: _link,
                              showWhenUnlinked: false,
                              offset: Offset(
                                (left - origin.dx) * progress,
                                (top - origin.dy - AppTheme.posterHoverLift) *
                                    progress,
                              ),
                              child: child,
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        child: _open ? SizedBox.fromSize(size: _sourceSize) : _card(),
      ),
    );
  }
}

class FilmResourceTile extends StatelessWidget {
  const FilmResourceTile({
    super.key,
    required this.resource,
    required this.catalog,
    required this.onOpenItem,
    required this.state,
    required this.onChanged,
    this.episode,
    this.selected = false,
    this.onSelected,
  });
  final FilmResource resource;
  final FilmCatalogController catalog;
  final Future<void> Function(MediaLibraryItem) onOpenItem;
  final String state;
  final Future<void> Function() onChanged;
  final Map? episode;
  final bool selected;
  final void Function(bool)? onSelected;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (resource.season != null)
            Text(
              'S${resource.season}E${resource.episode} · ${episode?['name'] ?? ''}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          SelectableText(
            contextMenuBuilder: buildSPTextSelectionMenu,
            resource.name,
          ),
          SelectableText(
            contextMenuBuilder: buildSPTextSelectionMenu,
            '${resource.rootName} · ${resource.path}',
          ),
          AppText(state),
          if (episode?['air_date'] != null)
            Text(
              context.l10n.format('播出日期：{date}', {
                'date': episode!['air_date'],
              }),
            ),
          if ((episode?['overview'] as String?)?.isNotEmpty == true)
            FilmWatchOverlay(
              store: catalog.store,
              resource: resource,
              showStatus: false,
              spoilerSensitive: true,
              revealBelow: true,
              revealLabel: '展示封面',
              child: Text(episode!['overview'] as String),
            ),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (onSelected != null)
                Checkbox(value: selected, onChanged: (v) => onSelected!(v!)),
              FilledButton.icon(
                onPressed: () => onOpenItem(resource.playbackItem),
                icon: const Icon(SPIcons.play),
                label: const AppText('播放此文件'),
              ),
              TextButton(
                onPressed: () async {
                  await showFilmMatchDialog(context, catalog, resource);
                  await onChanged();
                },
                child: const AppText('纠正作品匹配'),
              ),
              if (resource.type == FilmMediaType.tv && resource.workId != null)
                TextButton(
                  onPressed: () async {
                    await showFilmEpisodeMapping(context, catalog, [resource]);
                    await onChanged();
                  },
                  child: const AppText('调整季集'),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

class FilmPendingPage extends StatefulWidget {
  const FilmPendingPage({
    super.key,
    required this.catalog,
    required this.onOpenItem,
    this.sidebarInset = 0,
  });
  final FilmCatalogController catalog;
  final Future<void> Function(MediaLibraryItem) onOpenItem;
  final double sidebarInset;
  @override
  State<FilmPendingPage> createState() => _FilmPendingPageState();
}

class _FilmPendingPageState extends State<FilmPendingPage>
    with StreamPathTransitionState {
  List<FilmResource> _resources = [];
  final Set<int> _selected = {};
  bool _loading = true;
  bool _more = false;
  int _generation = 0;
  Timer? _reloadTimer;
  @override
  void initState() {
    super.initState();
    widget.catalog.store.addListener(_changed);
    _load();
  }

  void _changed() {
    _reloadTimer?.cancel();
    _reloadTimer = Timer(const Duration(milliseconds: 150), () => _load());
  }

  @override
  void dispose() {
    _reloadTimer?.cancel();
    widget.catalog.store.removeListener(_changed);
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    final generation = ++_generation;
    setState(() => _loading = true);
    await widget.catalog.run(() async {
      final rows = await widget.catalog.store.resources(
        pending: true,
        enabledOnly: true,
        rootId: widget.catalog.rootId,
        limit: 60,
        offset: more ? _resources.length : 0,
      );
      if (mounted && generation == _generation) {
        setState(() {
          _resources = more ? [..._resources, ...rows] : rows;
          _more = rows.length == 60;
          _selected.removeWhere((id) => !_resources.any((r) => r.id == id));
        });
      }
    }, clearError: false);
    if (mounted && generation == _generation) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final c = widget.catalog;
    final selected = _resources.where((r) => _selected.contains(r.id)).toList();
    final canMap =
        selected.isNotEmpty &&
        selected.first.workId != null &&
        selected.every(
          (r) =>
              r.type == FilmMediaType.tv && r.workId == selected.first.workId,
        );
    return StreamPathTransitionBuilder(
      listenable: c,
      builder: (context) => Stack(
        children: [
          Positioned.fill(
            child: ExcludeSemantics(
              child: IgnorePointer(
                child: FilmLibraryBackground(
                  cache: c.images,
                  file: c.backgroundFile,
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.only(left: widget.sidebarInset),
            child: _loading && _resources.isEmpty
                ? const SizedBox.shrink()
                : Scaffold(
                    backgroundColor: Colors.transparent,
                    appBar: AppBar(
                      toolbarHeight: 48,
                      automaticallyImplyLeading: false,
                      backgroundColor: Colors.transparent,
                      shape: const Border(),
                      title: Row(
                        children: [
                          const AppText('影视库'),
                          const SizedBox(width: 16),
                          Expanded(
                            child: SizedBox(
                              height: 44,
                              child: FilmCatalogTasks(
                                catalog: c,
                                compact: true,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    body: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 48),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              heightFactor: 1,
                              child: Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(context).pop(),
                                    child: const AppText('主页'),
                                  ),
                                  const AppText('待整理'),
                                  TextButton(
                                    onPressed: canMap && !_loading
                                        ? () async {
                                            await showFilmEpisodeMapping(
                                              context,
                                              c,
                                              selected,
                                            );
                                            await _load();
                                          }
                                        : null,
                                    child: const AppText('映射选中文件的季集'),
                                  ),
                                  IconButton(
                                    onPressed: _loading ? null : _load,
                                    icon: const Icon(SPIcons.refresh),
                                    tooltip: context.l10n.text('刷新'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: _resources.isEmpty
                              ? c.error != null
                                    ? const SizedBox.shrink()
                                    : DirectoryScrollView(
                                        builder: (controller) => ListView(
                                          controller: controller,
                                          children: const [
                                            ImmersiveEmptyState(
                                              icon: SPIcons.folderOpen,
                                              title: '没有待整理文件',
                                              description:
                                                  '当前文件已整理完成，新发现的未匹配文件会显示在这里。',
                                            ),
                                          ],
                                        ),
                                      )
                              : DirectoryScrollView(
                                  builder: (scrollController) =>
                                      ListView.builder(
                                        controller: scrollController,
                                        padding: const EdgeInsets.all(16),
                                        itemCount: _resources.length,
                                        itemBuilder: (context, i) =>
                                            FilmResourceTile(
                                              resource: _resources[i],
                                              catalog: c,
                                              onOpenItem: widget.onOpenItem,
                                              state: filmResourceState(
                                                app,
                                                _resources[i],
                                              ),
                                              onChanged: _load,
                                              selected: _selected.contains(
                                                _resources[i].id,
                                              ),
                                              onSelected: (value) =>
                                                  setState(() {
                                                    if (value) {
                                                      _selected.add(
                                                        _resources[i].id,
                                                      );
                                                    } else {
                                                      _selected.remove(
                                                        _resources[i].id,
                                                      );
                                                    }
                                                  }),
                                            ),
                                      ),
                                ),
                        ),
                        if (_more)
                          TextButton(
                            onPressed: _loading
                                ? null
                                : () => _load(more: true),
                            child: const AppText('加载更多'),
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _LogoPickerDialog extends StatelessWidget {
  const _LogoPickerDialog({
    required this.cache,
    required this.candidates,
    required this.current,
  });
  final FilmCatalogImageCache cache;
  final List<Map> candidates;
  final String? current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.l10n.text('选择 Logo'),
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Flexible(
              child: GridView.extent(
                maxCrossAxisExtent: 240,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.45,
                children: [
                  for (final candidate in candidates) _tile(context, candidate),
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(context.l10n.text('取消')),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, Map candidate) {
    final theme = Theme.of(context);
    final path = candidate['path'] as String;
    final selected = path == current;
    final language = candidate['language'] as String?;
    final width = candidate['width'], height = candidate['height'];
    final detail = [
      if (language != null && language.isNotEmpty) language,
      if (width is int && height is int) '$width x $height',
    ].join(' · ');
    return InkWell(
      onTap: () => Navigator.pop(context, path),
      borderRadius: BorderRadius.circular(10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? theme.colorScheme.primary : theme.dividerColor,
            width: selected ? 2 : 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: FilmArtwork(
                    cache: cache,
                    path: path,
                    target: 'w300',
                    transparent: true,
                    borderRadius: 6,
                    height: 64,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.black54,
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
