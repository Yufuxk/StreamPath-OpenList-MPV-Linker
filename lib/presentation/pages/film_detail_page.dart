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
import 'dart:math' as math;
import '../widgets/film_segmented_control.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/models/film_catalog_item.dart';
import '../../data/models/film_version.dart';
import '../../domain/services/film_version_resolver.dart';
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
import '../theme/glass_tokens.dart';
import '../widgets/glass_surface.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/sp_dialog.dart';
import '../widgets/film_artwork.dart';
import '../widgets/film_detail_back_button.dart';
import '../widgets/film_detail_backdrop.dart';
import '../widgets/film_adaptive_foreground.dart';
import '../widgets/film_certification_badge.dart';
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
  if (work.type == FilmMediaType.movie) return available.firstOrNull;
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
  final _genresTextKey = GlobalKey();
  final _overviewTextKey = GlobalKey();
  FilmWork? _work;
  List<FilmResource> _resources = [];
  FilmVersionIndex _versions = FilmVersionIndex([]);
  FilmVersionSelection? _versionSelection;
  Future<void> _versionWrites = Future.value();
  final _workVersionField = GlobalKey<FormFieldState<String>>();
  List<FilmResource> get _visibleResources => _versionSelection == null
      ? _resources
      : [
          ..._versions.selected(_versionSelection!),
          ..._resources.where(
            (r) => r.isDisc || r.season == null || r.episode == null,
          ),
        ];

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

  Map<int, Map<String, dynamic>> _seasons = {};
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
    widget.catalog.store.addListener(_load);
    final app = context.read<AppState>();
    _playbackStores = [
      app.filmMediaLibraryStore,
      app.mediaLibraryStore,
    ].whereType<MediaLibraryStore>().toList();
    for (final store in _playbackStores) {
      store.addListener(_load);
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
      reader.removeLibraryProgressListener(_load);
    }
    widget.catalog.store.removeListener(_load);
    for (final store in _playbackStores) {
      store.removeListener(_load);
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
      reader.addLibraryProgressListener(_load);
    }
  }

  void _progressChanged(PlaybackProgressChange change) {
    if (change.affectsAll ||
        change.profileId == _continueRecord?.item.sourceId) {
      _load();
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
          item.sourceKind == MediaSourceKind.local
          ? film
                ? app.filmLocalDiscPlaybackService
                : app.localDiscPlaybackService
          : film
          ? app.filmIsoPlaybackService
          : app.isoPlaybackService;
      final progress = await reader?.getLibraryProgress(
        profileId: item.sourceId,
        resolvedUrl: target,
        playbackMode: item.playbackMode,
      );
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

  Widget _metadata(FilmWork work, List<String> tags, Color foreground) {
    final theme = Theme.of(context);
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
    return Wrap(
      key: const Key('film-detail-metadata'),
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (score != null && score > 0)
          Tooltip(
            message: context.l10n.format('TMDB 评分：{score}（{votes} 票）', {
              'score': score,
              'votes': work.metadata['vote_count'] ?? 0,
            }),
            child: _informationPill(
              foreground,
              Text.rich(
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
          _informationPill(foreground, Text('${work.year}')),
        if (minutes.isNotEmpty || work.metadata['runtime'] != null)
          Text(
            context.l10n.format(
              minutes.isEmpty ? '官方时长：{minutes} 分钟' : '影片时长：{minutes} 分钟',
              {
                'minutes': minutes.isEmpty
                    ? work.metadata['runtime']
                    : minutes.join(' & '),
              },
            ),
            style: theme.textTheme.bodySmall?.copyWith(color: foreground),
          ),
        for (final tag in tags) _informationPill(foreground, Text(tag)),
        FilmCertificationBadge(rating: work.certification, color: foreground),
      ],
    );
  }

  Widget _informationPill(Color foreground, Widget child) => GlassSurface(
    level: GlassSurfaceLevel.content,
    borderRadius: AppTheme.pillRadius,
    border: Border.all(color: foreground.withValues(alpha: .14)),
    color: Theme.of(context).colorScheme.surface.withValues(alpha: .18),
    showShadow: false,
    blur: true,
    blurSigma: 10,
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
    child: DefaultTextStyle(
      style: Theme.of(
        context,
      ).textTheme.labelMedium!.copyWith(color: foreground),
      child: child,
    ),
  );

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

  Future<void> _load() async {
    if (StreamPathTransitionScope.read(context)) return;
    final app = context.read<AppState>();
    final generation = ++_generation;
    await widget.catalog.run(() async {
      final work = await widget.catalog.store.work(widget.workId);
      if (mounted && generation == _generation) setState(() => _work = work);
      final favorite = await widget.catalog.store.isFavorite(widget.workId);
      final resources = await widget.catalog.store.resources(
        workId: widget.workId,
        sourceId: widget.catalog.sourceId,
        enabledOnly: true,
      );
      if (!mounted) return;
      final records = <MediaLibraryRecord>[];
      MediaLibraryRecord? recentVersionRecord;
      final filmRecords = <MediaLibraryRecord>{};
      final paths = {for (final r in resources) '${r.sourceId}\u0000${r.path}'};
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
      final versions = FilmVersionIndex(resources);
      FilmVersionSelection? selection;
      if (work?.type == FilmMediaType.tv && versions.families.isNotEmpty) {
        selection = await widget.catalog.store.versionSelection(
          work!.identity,
          sourceScope: widget.catalog.sourceId,
        );
        if (selection == null) {
          selection = versions.initial(
            recentSource: recentVersionRecord?.item.sourceId,
            recentPath: recentVersionRecord?.item.targetPath,
          );
          await widget.catalog.store.saveVersionSelection(
            work.identity,
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
      final seasons = <int, Map<String, dynamic>>{};
      final probes = <int, Map<String, dynamic>?>{};
      for (final resource in resources) {
        probes[resource.id] = await widget.catalog.store.probe(resource.id);
      }
      for (final number
          in resources.map((r) => r.season).whereType<int>().toSet()) {
        final metadata = await widget.catalog.store.season(
          widget.workId,
          number,
        );
        if (metadata != null) seasons[number] = metadata;
      }
      if (mounted && generation == _generation) {
        setState(() {
          _work = work;
          _favorite = favorite;
          _resources = resources;
          _versions = versions;
          _versionSelection = selection;
          _continueRecord = records.firstOrNull;
          _continuePositionMs = positionMs;
          _continueDurationMs = durationMs;
          _seasons = seasons;
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
            (work.metadata['presentation_version'] != 3 ||
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

  Map? _episode(FilmResource resource) =>
      (_seasons[resource.season]?['episodes'] as List?)
              ?.where((e) => e['episode_number'] == resource.episode)
              .firstOrNull
          as Map?;

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
          r.availability == 'present',
    )) {
      if (await app.cachedTarget(version.sourceId, version.path) != null) {
        selected = version;
        break;
      }
    }
    if (mounted) await widget.onOpenItem(selected.playbackItem);
  }

  Widget _cards(
    List<FilmResource> resources,
    AppState app,
    FilmWork work,
  ) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = (constraints.maxWidth / 270).floor().clamp(1, 6);
      final width = (constraints.maxWidth - 16 * (columns - 1)) / columns;
      return Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          if (resources.isEmpty && _loading)
            SizedBox(
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
          for (var i = 0; i < resources.length; i++)
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
                  displayTitle: work.title,
                  artworkPath: work.backdropPath,
                  version:
                      work.type == FilmMediaType.movie && resources.length > 1
                      ? i + 1
                      : null,
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
      );
    },
  );

  Widget _seasonSelector(FilmWork work, List<int?> numbers) => LayoutBuilder(
    builder: (context, constraints) => Wrap(
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
        if (_versionSelection != null && _activeSeason != null)
          SkeletonRegion(
            borderRadius: AppTheme.pillRadius,
            child: _seasonVersionSelector(constraints.maxWidth),
          ),
        if (_versions.unresolved.isNotEmpty)
          SkeletonRegion(
            child: TextButton(
              onPressed: () => showFilmVersionMapping(
                context,
                widget.catalog,
                _resources
                    .where(
                      (r) => !r.isDisc && r.season != null && r.episode != null,
                    )
                    .toList(),
              ),
              child: const AppText('确认版本归属'),
            ),
          ),
      ],
    ),
  );

  Widget _seasonVersionSelector(double maxWidth) {
    final key = _versionSelection!.forSeason(_activeSeason!);
    final families = _versions.families
        .where((f) => f.resources.any((r) => r.season == _activeSeason))
        .toList();
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
              child: _CreditAvatar(
                child: SkeletonRegion(
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
                      placeholder: profilePath == null || profilePath.isEmpty
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
                                  color: theme.colorScheme.onSurface.withValues(
                                    alpha: .1,
                                  ),
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
    final app = context.watch<AppState>();
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
    return StreamPathTransitionBuilder(
      listenable: c,
      builder: (context) => SkeletonScope(
        ready: !_loading,
        enabled: !moving,
        child: Scaffold(
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
                            builder: (scrollController) => ListView(
                              key: const Key('film-detail-scroll'),
                              controller: scrollController,
                              padding: EdgeInsets.fromLTRB(
                                24,
                                topInset + 68,
                                24,
                                32,
                              ),
                              children: [
                                Wrap(
                                  spacing: 24,
                                  runSpacing: 16,
                                  children: [
                                    GestureDetector(
                                      onSecondaryTapDown: (details) =>
                                          _posterMenu(details.globalPosition),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: Builder(
                                          builder: (_) {
                                            final artwork = FilmWatchOverlay(
                                              rootId: widget.catalog.rootId,
                                              store: c.store,
                                              workId: work.id,
                                              child: FilmArtwork(
                                                key: const Key(
                                                  'film-detail-poster',
                                                ),
                                                cache: c.images,
                                                path: work.posterPath,
                                                fallbackPath: work.posterPath,
                                                target: 'w500',
                                                width: 180,
                                                provider: moving && _loading
                                                    ? poster?.provider
                                                    : null,
                                                showCachedImmediately:
                                                    poster != null,
                                              ),
                                            );
                                            return poster == null
                                                ? artwork
                                                : FilmSharedPoster(
                                                    anchor: poster,
                                                    child: FilmConnectedReveal(
                                                      part: FilmConnectedPart
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
                                        constraints: const BoxConstraints(
                                          maxWidth: 700,
                                        ),
                                        child: FilmAdaptiveForeground(
                                          controller: _textColors,
                                          textKeys: [
                                            _titleTextKey,
                                            _originalTitleTextKey,
                                            _metadataTextKey,
                                            _genresTextKey,
                                            _overviewTextKey,
                                          ],
                                          scrollController: _scroll,
                                          builder: (context, foreground) => Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              SkeletonRegion(
                                                key: const Key(
                                                  'film-skeleton-logo',
                                                ),
                                                child: FilmArtwork(
                                                  cache: c.images,
                                                  path: moving && poster != null
                                                      ? null
                                                      : work.metadata['logo_path']
                                                            as String?,
                                                  target: 'original',
                                                  transparent: true,
                                                  width: 420,
                                                  height: 90,
                                                  placeholder: Align(
                                                    alignment:
                                                        Alignment.centerLeft,
                                                    child: Text(
                                                      key: _titleTextKey,
                                                      work.title,
                                                      style: theme
                                                          .textTheme
                                                          .headlineMedium
                                                          ?.copyWith(
                                                            color: foreground,
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
                                                    key: _originalTitleTextKey,
                                                    work.originalTitle,
                                                    style: theme
                                                        .textTheme
                                                        .titleMedium
                                                        ?.copyWith(
                                                          color: foreground,
                                                          fontWeight:
                                                              FontWeight.w400,
                                                        ),
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(height: 14),
                                              SkeletonRegion(
                                                key: const Key(
                                                  'film-skeleton-metadata',
                                                ),
                                                child: SizedBox(
                                                  width: initialSkeleton
                                                      ? 300
                                                      : null,
                                                  height: initialSkeleton
                                                      ? 28
                                                      : null,
                                                  child: KeyedSubtree(
                                                    key: _metadataTextKey,
                                                    child: _metadata(
                                                      work,
                                                      brief,
                                                      foreground,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(height: 8),
                                              SkeletonRegion(
                                                key: const Key(
                                                  'film-skeleton-genres',
                                                ),
                                                child: SizedBox(
                                                  width: initialSkeleton
                                                      ? 260
                                                      : null,
                                                  child:
                                                      (work.metadata['genres']
                                                                      as List? ??
                                                                  [])
                                                              .isEmpty &&
                                                          !initialSkeleton
                                                      ? const SizedBox.shrink()
                                                      : _informationPill(
                                                          foreground,
                                                          Text(
                                                            key: _genresTextKey,
                                                            (work.metadata['genres']
                                                                        as List? ??
                                                                    [])
                                                                .join(' · '),
                                                          ),
                                                        ),
                                                ),
                                              ),
                                              const SizedBox(height: 16),
                                              SkeletonRegion(
                                                key: const Key(
                                                  'film-skeleton-actions',
                                                ),
                                                child: Wrap(
                                                  spacing: 12,
                                                  runSpacing: 8,
                                                  children: [
                                                    if (playable != null ||
                                                        _loading)
                                                      FilmDetailPlayButton(
                                                        onPressed:
                                                            playable == null
                                                            ? null
                                                            : () =>
                                                                  _playDefault(
                                                                    playable,
                                                                  ),
                                                      ),
                                                    Opacity(
                                                      opacity: _loading ? 0 : 1,
                                                      child: FilmDetailActionButton(
                                                        onPressed: _loading
                                                            ? null
                                                            : () => c.run(
                                                                () => c.store
                                                                    .setFavorite(
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
                                                        null)
                                                      _workVersionSelector(),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(height: 16),
                                              SkeletonRegion(
                                                key: const Key(
                                                  'film-skeleton-overview',
                                                ),
                                                child: SizedBox(
                                                  width: initialSkeleton
                                                      ? 700
                                                      : null,
                                                  height: initialSkeleton
                                                      ? MediaQuery.textScalerOf(
                                                                  context,
                                                                ).scale(
                                                                  theme
                                                                          .textTheme
                                                                          .bodyMedium!
                                                                          .fontSize! *
                                                                      1.55,
                                                                ) *
                                                                4 +
                                                            48
                                                      : null,
                                                  child: work.overview.isEmpty
                                                      ? AppText(
                                                          '暂无简介',
                                                          style: TextStyle(
                                                            color: foreground,
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
                                FilmConnectedReveal(
                                  part: FilmConnectedPart.secondary,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const SizedBox(height: 28),
                                      _playEntry(app, work),
                                      _credits(work, c),
                                      if (work.type == FilmMediaType.tv)
                                        _seasonSelector(work, numbers)
                                      else
                                        SkeletonRegion(
                                          child: AppText(
                                            '关联资源',
                                            style: theme.textTheme.titleLarge,
                                          ),
                                        ),
                                      const SizedBox(height: 12),
                                      if (work.type == FilmMediaType.tv &&
                                          _versionSelection != null &&
                                          !_visibleResources.any(
                                            (r) => r.season == _activeSeason,
                                          ))
                                        const AppText('所选版本在本季没有可用剧集'),
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
                                                        (r) => _selected
                                                            .contains(r.id),
                                                      )
                                                      .toList(),
                                                );
                                                await _load();
                                              },
                                              child: const AppText('映射选中文件的季集'),
                                            ),
                                            TextButton(
                                              onPressed: () =>
                                                  setState(_selected.clear),
                                              child: const AppText('取消选择'),
                                            ),
                                          ],
                                        ),
                                      _cards(
                                        work.type == FilmMediaType.tv
                                            ? _visibleResources
                                                  .where(
                                                    (r) =>
                                                        r.season ==
                                                        _activeSeason,
                                                  )
                                                  .toList()
                                            : _resources,
                                        app,
                                        work,
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
    this.version,
    this.selected = false,
    this.onSelected,
    this.stableEpisodeIdentity = false,
  });
  final FilmResource resource;
  final FilmCatalogController catalog;
  final String state;
  final Map? episode;
  final Map<String, dynamic>? probe;
  final String? displayTitle, artworkPath;
  final int? version;
  final Future<void> Function(MediaLibraryItem) onOpenItem;
  final Future<void> Function() onChanged;
  final bool selected;
  final void Function(bool)? onSelected;
  final bool stableEpisodeIdentity;

  Future<void> _menu(BuildContext context, Offset position) async {
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
        await onChanged();
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
    final still = tv ? (episode?['still_path'] as String?) : null;
    final theme = Theme.of(context);
    final measured = probe?['duration'] is num
        ? probe!['duration'] as num
        : null;
    final runtime = measured != null && measured > 0
        ? (measured / 60).round()
        : episode?['runtime'] is num
        ? episode!['runtime'] as num
        : null;
    final airDate = episode?['air_date'] as String?;
    final runtimeText = runtime != null && runtime > 0
        ? context.l10n.format('{minutes} 分钟', {'minutes': runtime})
        : '';
    final timing = [
      if (airDate != null && airDate.isNotEmpty) airDate,
      if (runtimeText.isNotEmpty) runtimeText,
    ];
    final timingDescription = [
      if (airDate != null && airDate.isNotEmpty)
        context.l10n.format('播出日期：{date}', {'date': airDate}),
      if (runtime != null && runtime > 0)
        context.l10n.format(
          measured != null && measured > 0
              ? '影片时长：{minutes} 分钟'
              : '官方时长：{minutes} 分钟',
          {'minutes': runtime},
        ),
    ];
    final compactLineHeight =
        MediaQuery.textScalerOf(
          context,
        ).scale(theme.textTheme.bodySmall!.fontSize!) *
        1.5;
    final titleHeight = math.max(
      32.0,
      MediaQuery.textScalerOf(
            context,
          ).scale(theme.textTheme.titleSmall!.fontSize!) *
          (theme.textTheme.titleSmall!.height ?? 1.4),
    );
    final badges = [
      if (state != '可用') context.l10n.text(state),
      ...filmTechnicalTags(probe),
    ];

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
        color: tv
            ? Colors.transparent
            : theme.colorScheme.surface.withValues(alpha: .18),
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
          enabled: tv,
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
                    foreground: tv
                        ? Stack(
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
                                          color: theme.colorScheme.surface
                                              .withValues(alpha: .86),
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
                          )
                        : null,
                    store: catalog.store,
                    resource: resource,
                    spoilerSensitive: tv,
                    canReveal: false,
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
                                        : displayTitle ??
                                              context.l10n.text('播放此文件'),
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
                          if (version != null)
                            Text(
                              context.l10n.format('版本 {number}', {
                                'number': version,
                              }),
                            ),
                          if (!tv && state != '可用') AppText(state),
                          if (!tv && filmTechnicalTags(probe).isNotEmpty)
                            Text(
                              filmTechnicalTags(probe).join(' · '),
                              style: theme.textTheme.bodySmall,
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
                                  child: FilmWatchOverlay(
                                    store: catalog.store,
                                    resource: resource,
                                    spoilerSensitive: true,
                                    showStatus: false,
                                    softEdges: true,
                                    revealLabel: '展示封面',
                                    child: expanded
                                        ? DirectoryScrollView(
                                            builder: (controller) =>
                                                SingleChildScrollView(
                                                  controller: controller,
                                                  child: Text(
                                                    (episode?['overview']
                                                                    as String? ??
                                                                '')
                                                            .isEmpty
                                                        ? context.l10n.text(
                                                            '暂无简介',
                                                          )
                                                        : episode!['overview']
                                                              as String,
                                                    style: theme
                                                        .textTheme
                                                        .bodyMedium
                                                        ?.copyWith(height: 1.6),
                                                  ),
                                                ),
                                          )
                                        : SizedBox(
                                            height: compactLineHeight,
                                            width: double.infinity,
                                            child: Align(
                                              alignment: AlignmentDirectional
                                                  .centerStart,
                                              child: Text(
                                                episode?['overview']
                                                        as String? ??
                                                    '',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: theme.textTheme.bodySmall
                                                    ?.copyWith(height: 1.5),
                                              ),
                                            ),
                                          ),
                                  ),
                                ),
                              ),
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
                                              airDate ?? '',
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
                          if (!tv)
                            TextButton.icon(
                              onPressed: () =>
                                  onOpenItem(resource.playbackItem),
                              icon: const Icon(SPIcons.play),
                              label: const AppText('播放此文件'),
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
    with SingleTickerProviderStateMixin {
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
  }

  Widget _card() =>
      KeyedSubtree(key: _cardKey, child: widget.builder(_expanded, _toggle));

  @override
  void dispose() {
    _lift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CompositedTransformTarget(
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
            final origin = anchor.localToGlobal(Offset.zero, ancestor: overlay);
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

class _CreditAvatar extends StatefulWidget {
  const _CreditAvatar({required this.child});
  final Widget child;
  @override
  State<_CreditAvatar> createState() => _CreditAvatarState();
}

class _CreditAvatarState extends State<_CreditAvatar> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(4),
    child: MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        scale: _hovered ? 1.08 : 1,
        duration: const Duration(milliseconds: 120),
        child: widget.child,
      ),
    ),
  );
}
