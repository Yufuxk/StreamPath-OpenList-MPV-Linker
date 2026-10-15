import '../widgets/transition_content.dart';
import '../widgets/cinematic_states.dart';
import '../../data/models/film_playlist.dart';
import '../widgets/film_playlist_dialog.dart';
import '../widgets/sp_menu.dart';
import '../widgets/film_continue_card.dart';
import 'film_related_page.dart';
import '../widgets/directory_scroll_view.dart';
import '../widgets/film_watch_overlay.dart';
import '../widgets/film_watch_menu.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/film_catalog_item.dart';
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
  @override
  void initState() {
    super.initState();
    _work = widget.initialWork;
    widget.catalog.store.addListener(_load);
    final app = context.read<AppState>();
    unawaited(_listenToProgress(app));
    _playbackStores = [
      app.filmMediaLibraryStore,
      app.mediaLibraryStore,
    ].whereType<MediaLibraryStore>().toList();
    for (final store in _playbackStores) {
      store.addListener(_load);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
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
    final scheme = theme.colorScheme;
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
    final summary = Text.rich(
      key: const Key('film-detail-metadata'),
      TextSpan(
        style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
        children: [
          if (score != null && score > 0) ...[
            TextSpan(
              text: '★ ${score.toStringAsFixed(1)}',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            TextSpan(text: ' ${context.l10n.text('TMDB')}'),
          ],
          if (work.year != null)
            TextSpan(
              text: '${score != null && score > 0 ? '   ' : ''}${work.year}',
            ),
          if (minutes.isNotEmpty || work.metadata['runtime'] != null)
            TextSpan(
              text:
                  '   ${context.l10n.format(minutes.isEmpty ? '官方时长：{minutes} 分钟' : '影片时长：{minutes} 分钟', {'minutes': minutes.isEmpty ? work.metadata['runtime'] : minutes.join(' & ')})}',
            ),
        ],
      ),
    );
    return Wrap(
      spacing: 12,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (score != null && score > 0)
          Tooltip(
            message: context.l10n.format('TMDB 评分：{score}（{votes} 票）', {
              'score': score,
              'votes': work.metadata['vote_count'] ?? 0,
            }),
            child: summary,
          )
        else
          summary,
        for (final tag in tags)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: scheme.onSurface.withValues(alpha: .08),
              border: Border.all(
                color: scheme.onSurface.withValues(alpha: .14),
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              tag,
              style: theme.textTheme.labelMedium?.copyWith(color: foreground),
            ),
          ),
      ],
    );
  }

  Future<void> _load() async {
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
      final filmRecords = <MediaLibraryRecord>{};
      final paths = {for (final r in resources) '${r.sourceId}\u0000${r.path}'};
      for (final library in _playbackStores) {
        for (final source in resources.map((r) => r.sourceId).toSet()) {
          for (final iso in [false, true]) {
            final matching =
                (await library.playbackHistory(source, audio: false, iso: iso))
                    .where(
                      (record) =>
                          !record.continueDismissed &&
                          paths.contains(
                            '${record.item.sourceId}\u0000${record.item.targetPath}',
                          ),
                    )
                    .toList();
            records.addAll(matching);
            if (library == app.filmMediaLibraryStore) {
              filmRecords.addAll(matching);
            }
          }
        }
      }
      records.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
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
            work.metadata['presentation_version'] != 3 &&
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

  Widget _cards(List<FilmResource> resources, AppState app, FilmWork work) =>
      LayoutBuilder(
        builder: (context, constraints) {
          final columns = (constraints.maxWidth / 270).floor().clamp(1, 6);
          final width = (constraints.maxWidth - 16 * (columns - 1)) / columns;
          return Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              for (var i = 0; i < resources.length; i++)
                SizedBox(
                  width: width,
                  child: FilmEpisodeCard(
                    resource: resources[i],
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
                    onOpenItem: widget.onOpenItem,
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
            ],
          );
        },
      );

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
    };
    final credits = work.metadata['credits'] as Map?;
    final people = [
      ...(credits?['cast'] as List? ?? []),
      ...(credits?['crew'] as List? ?? []),
    ].whereType<Map>().toList();
    return FilmShelf(
      title: '演职人员',
      count: people.length,
      height: 84 + MediaQuery.textScalerOf(context).scale(14) * 4,
      itemWidth: 112,
      horizontal: true,
      builder: (_, i) {
        final person = people[i];
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
                child: ClipOval(
                  child: FilmArtwork(
                    cache: c.images,
                    path: person['profile_path'] as String?,
                    target: 'w185',
                    width: 68,
                    height: 68,
                    borderRadius: 0,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              person['name'] as String? ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(
              person['character'] != null
                  ? context.l10n.format('饰 {role}', {
                      'role': person['character'],
                    })
                  : context.l10n.text(
                      jobs[person['job']] ?? (person['job'] ?? '') as String,
                    ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        );
      },
    );
  }

  FilmResource? _recommended(AppState app, FilmWork work) {
    return recommendedFilmResource(app, work, _resources);
  }

  Widget _playEntry(AppState app, FilmWork work) {
    final target = _recommended(app, work);
    final record =
        _continueRecord ??
        (target == null
            ? null
            : MediaLibraryRecord(
                item: target.playbackItem,
                updatedAt: DateTime.now(),
              ));
    if (record == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText(
          _continueRecord == null ? '开始播放' : '继续播放',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: FilmContinueCard.landscapeWidth,
          height: FilmContinueCard.landscapeHeight,
          child: FilmContinueCard(
            catalog: widget.catalog,
            record: record,
            positionMs: _continuePositionMs,
            durationMs: _continueDurationMs,
            onMenu: widget.onContinueMenu == null
                ? null
                : (position) => widget.onContinueMenu!(record, position),
            onTap: () =>
                _continueRecord != null && widget.onContinueSelected != null
                ? widget.onContinueSelected!(record)
                : widget.onOpenItem(record.item),
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
    final work = _work;
    final theme = Theme.of(context);
    final topInset = MediaQuery.paddingOf(context).top;
    final numbers = _resources.map((r) => r.season).toSet().toList()
      ..sort((a, b) => (a ?? 9999).compareTo(b ?? 9999));
    final playable = _resources
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
      builder: (context) => _loading && work == null
          ? const SizedBox.shrink()
          : Scaffold(
              body: Stack(
                children: [
                  Positioned.fill(
                    child: work == null
                        ? const Center(child: AppText('影视目录库操作失败'))
                        : Stack(
                            children: [
                              if (work.backdropPath != null)
                                Positioned.fill(
                                  child: FilmDetailBackdrop(
                                    catalog: c,
                                    workId: work.id,
                                    path: work.backdropPath,
                                    textColors: _textColors,
                                  ),
                                ),
                              if (_loading)
                                const SizedBox.shrink()
                              else
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
                                      if (c.error != null)
                                        AppText(
                                          filmCatalogErrorText(c.error!),
                                          style: TextStyle(
                                            color: theme.colorScheme.error,
                                          ),
                                        ),
                                      if (_refreshing)
                                        const LinearProgressIndicator(),
                                      Wrap(
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
                                              child: FilmWatchOverlay(
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
                                                ),
                                              ),
                                            ),
                                          ),
                                          ConstrainedBox(
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
                                                  FilmArtwork(
                                                    cache: c.images,
                                                    path:
                                                        work.metadata['logo_path']
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
                                                  const SizedBox(height: 8),
                                                  Text(
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
                                                  const SizedBox(height: 14),
                                                  KeyedSubtree(
                                                    key: _metadataTextKey,
                                                    child: _metadata(
                                                      work,
                                                      brief,
                                                      foreground,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 8),
                                                  Text(
                                                    key: _genresTextKey,
                                                    (work.metadata['genres']
                                                                as List? ??
                                                            [])
                                                        .join(' · '),
                                                    style: theme
                                                        .textTheme
                                                        .bodyMedium
                                                        ?.copyWith(
                                                          color: foreground,
                                                        ),
                                                  ),
                                                  const SizedBox(height: 16),
                                                  Wrap(
                                                    spacing: 12,
                                                    runSpacing: 8,
                                                    children: [
                                                      if (playable != null)
                                                        FilmDetailPlayButton(
                                                          onPressed: () =>
                                                              widget.onOpenItem(
                                                                playable
                                                                    .playbackItem,
                                                              ),
                                                        ),
                                                      FilmDetailActionButton(
                                                        onPressed: () => c.run(
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
                                                    ],
                                                  ),
                                                  const SizedBox(height: 16),
                                                  work.overview.isEmpty
                                                      ? AppText(
                                                          '暂无简介',
                                                          style: TextStyle(
                                                            color: foreground,
                                                          ),
                                                        )
                                                      : FilmWatchOverlay(
                                                          store: c.store,
                                                          workId: work.id,
                                                          rootId: c.rootId,
                                                          spoilerSensitive:
                                                              true,
                                                          showStatus: false,
                                                          revealBelow: true,
                                                          footer: TextButton(
                                                            onPressed: () => setState(
                                                              () => _expandedOverview =
                                                                  !_expandedOverview,
                                                            ),
                                                            child: AppText(
                                                              _expandedOverview
                                                                  ? '收起简介'
                                                                  : '展开简介',
                                                            ),
                                                          ),
                                                          child: Text(
                                                            key:
                                                                _overviewTextKey,
                                                            work.overview,
                                                            maxLines:
                                                                _expandedOverview
                                                                ? null
                                                                : 4,
                                                            overflow:
                                                                _expandedOverview
                                                                ? TextOverflow
                                                                      .visible
                                                                : TextOverflow
                                                                      .ellipsis,
                                                            style: theme
                                                                .textTheme
                                                                .bodyMedium
                                                                ?.copyWith(
                                                                  color:
                                                                      foreground,
                                                                  height: 1.55,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w400,
                                                                ),
                                                          ),
                                                        ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 28),
                                      _playEntry(app, work),
                                      _credits(work, c),
                                      AppText(
                                        '关联资源',
                                        style: theme.textTheme.titleLarge,
                                      ),
                                      const SizedBox(height: 12),
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
                                      if (work.type == FilmMediaType.tv) ...[
                                        if (numbers.isNotEmpty) ...[
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              bottom: 12,
                                            ),
                                            child: AppText(
                                              '季',
                                              style: theme.textTheme.titleLarge,
                                            ),
                                          ),
                                          Wrap(
                                            spacing: 12,
                                            runSpacing: 12,
                                            children: [
                                              for (final number in numbers)
                                                SizedBox(
                                                  width: 156,
                                                  child: FilmPosterHover(
                                                    child: Card(
                                                      key: ValueKey(
                                                        'film-season-${number ?? 'unmapped'}',
                                                      ),
                                                      clipBehavior:
                                                          Clip.antiAlias,
                                                      shape: RoundedRectangleBorder(
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                        side: BorderSide(
                                                          color:
                                                              _activeSeason ==
                                                                  number
                                                              ? theme
                                                                    .colorScheme
                                                                    .primary
                                                              : theme
                                                                    .dividerColor,
                                                          width:
                                                              _activeSeason ==
                                                                  number
                                                              ? 2
                                                              : .5,
                                                        ),
                                                      ),
                                                      child: InkWell(
                                                        hoverColor:
                                                            Colors.transparent,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                        onSecondaryTapDown:
                                                            number == null
                                                            ? null
                                                            : (
                                                                details,
                                                              ) => showFilmWatchMenu(
                                                                context,
                                                                catalog: c,
                                                                playlistScope:
                                                                    FilmPlaylistScope.work(
                                                                      work.id,
                                                                      season:
                                                                          number,
                                                                    ),
                                                                title:
                                                                    '${work.title} S${number.toString().padLeft(2, '0')}',
                                                                position: details
                                                                    .globalPosition,
                                                                resources: _resources
                                                                    .where(
                                                                      (r) =>
                                                                          r.season ==
                                                                          number,
                                                                    )
                                                                    .toList(),
                                                              ),
                                                        onTap: () => setState(
                                                          () => _activeSeason =
                                                              number,
                                                        ),
                                                        child: Column(
                                                          crossAxisAlignment:
                                                              CrossAxisAlignment
                                                                  .start,
                                                          children: [
                                                            FilmPosterHoverSurface(
                                                              child: FilmWatchOverlay(
                                                                rootId: widget
                                                                    .catalog
                                                                    .rootId,
                                                                store: c.store,
                                                                workId: work.id,
                                                                season: number,
                                                                child: ClipRect(
                                                                  child: FilmArtwork(
                                                                    cache: c
                                                                        .images,
                                                                    path:
                                                                        (_seasons[number]?['poster_path']
                                                                            as String?) ??
                                                                        work.posterPath,
                                                                    borderRadius:
                                                                        0,
                                                                  ),
                                                                ),
                                                              ),
                                                            ),
                                                            Padding(
                                                              padding:
                                                                  const EdgeInsets.all(
                                                                    12,
                                                                  ),
                                                              child: Column(
                                                                crossAxisAlignment:
                                                                    CrossAxisAlignment
                                                                        .start,
                                                                children: [
                                                                  Text(
                                                                    number ==
                                                                            null
                                                                        ? context.l10n.text(
                                                                            '集号待确认',
                                                                          )
                                                                        : number ==
                                                                              0
                                                                        ? context.l10n.text(
                                                                            '特别篇',
                                                                          )
                                                                        : context.l10n.format(
                                                                            '第 {season} 季',
                                                                            {
                                                                              'season': number,
                                                                            },
                                                                          ),
                                                                  ),
                                                                  Text(
                                                                    context.l10n.format(
                                                                      '{count} 个资源',
                                                                      {
                                                                        'count': _resources
                                                                            .where(
                                                                              (
                                                                                r,
                                                                              ) =>
                                                                                  r.season ==
                                                                                  number,
                                                                            )
                                                                            .length,
                                                                      },
                                                                    ),
                                                                  ),
                                                                ],
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
                                        ],
                                        for (final number in numbers.where(
                                          (n) => n == _activeSeason,
                                        )) ...[
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 16,
                                            ),
                                            child: Text(
                                              number == null
                                                  ? context.l10n.text('集号待确认')
                                                  : number == 0
                                                  ? context.l10n.text('特别篇')
                                                  : context.l10n.format(
                                                      '第 {season} 季',
                                                      {'season': number},
                                                    ),
                                              style: theme.textTheme.titleLarge,
                                            ),
                                          ),
                                          _cards(
                                            _resources
                                                .where(
                                                  (r) => r.season == number,
                                                )
                                                .toList(),
                                            app,
                                            work,
                                          ),
                                        ],
                                      ] else
                                        _cards(_resources, app, work),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                  ),
                  if (!_loading)
                    Positioned(
                      top: topInset - 10,
                      left: 4,
                      child: FilmDetailBackButton(scrollController: _scroll),
                    ),
                ],
              ),
            ),
    );
  }
}

enum _FilmFileAction {
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
        if (resource.canMarkWatched) ...[
          const PopupMenuItem(
            value: _FilmFileAction.watched,
            child: AppText('标记已看完'),
          ),
          const PopupMenuItem(
            value: _FilmFileAction.unwatched,
            child: AppText('标记未观看'),
          ),
        ],
        const PopupMenuItem(
          value: _FilmFileAction.source,
          child: AppText('查看来源信息'),
        ),
        const PopupMenuItem(
          value: _FilmFileAction.refresh,
          child: AppText('刷新元数据'),
        ),
        const PopupMenuItem(
          value: _FilmFileAction.match,
          child: AppText('纠正作品匹配'),
        ),
        if (resource.type == FilmMediaType.tv && resource.workId != null)
          const PopupMenuItem(
            value: _FilmFileAction.mapping,
            child: AppText('调整季集'),
          ),
        if (onSelected != null)
          PopupMenuItem(
            value: _FilmFileAction.select,
            child: AppText(selected ? '取消选择' : '选择此集'),
          ),
        PopupMenuItem(
          value: _FilmFileAction.playlist,
          enabled: !resource.isDisc && resource.availability == 'present',
          child: AppText(
            resource.type == FilmMediaType.tv ? '以本集创建播放列表' : '以本资源创建播放列表',
          ),
        ),
        PopupMenuItem(
          value: _FilmFileAction.addPlaylist,
          enabled: !resource.isDisc && resource.availability == 'present',
          child: const AppText('加入播放列表…'),
        ),
      ],
    );
    if (!context.mounted || action == null) return;
    switch (action) {
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
  Widget build(BuildContext context) {
    final tv = resource.type == FilmMediaType.tv;
    final title = episode?['name'] as String?;
    final still = tv ? (episode?['still_path'] as String?) : null;
    final theme = Theme.of(context);
    return GestureDetector(
      onSecondaryTapDown: (details) => _menu(context, details.globalPosition),
      child: FilmPosterHover(
        child: Card(
          key: ValueKey('film-resource-${resource.id}'),
          borderOnForeground: false,
          color: theme.colorScheme.surface.withValues(alpha: .18),
          elevation: 0,
          clipBehavior: Clip.none,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface.withValues(alpha: .12),
              width: selected ? 2 : 1,
            ),
          ),
          child: InkWell(
            hoverColor: Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            onTap: () => onOpenItem(resource.playbackItem),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FilmWatchOverlay(
                  hoverSurface: true,
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
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              tv && title != null && title.isNotEmpty
                                  ? '${resource.episode}. $title'
                                  : tv
                                  ? (resource.episode == null
                                        ? context.l10n.text('集号待确认')
                                        : displayTitle == null
                                        ? context.l10n.format('第 {episode} 集', {
                                            'episode': resource.episode,
                                          })
                                        : '${resource.episode}. $displayTitle')
                                  : displayTitle ?? context.l10n.text('播放此文件'),
                              style: theme.textTheme.titleSmall,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Builder(
                            builder: (buttonContext) => IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(SPIcons.more),
                              tooltip: context.l10n.text('更多操作'),
                              onPressed: () {
                                final box =
                                    buttonContext.findRenderObject()!
                                        as RenderBox;
                                _menu(
                                  context,
                                  box.localToGlobal(Offset(0, box.size.height)),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                      if (version != null)
                        Text(
                          context.l10n.format('版本 {number}', {
                            'number': version,
                          }),
                        ),
                      if (state != '可用') AppText(state),
                      if (filmTechnicalTags(probe).isNotEmpty)
                        Text(
                          filmTechnicalTags(probe).join(' · '),
                          style: theme.textTheme.bodySmall,
                        ),
                      if (episode?['air_date'] != null)
                        Text(
                          context.l10n.format('播出日期：{date}', {
                            'date': episode!['air_date'],
                          }),
                        ),
                      if ((probe?['duration'] is num &&
                              (probe!['duration'] as num) > 0) ||
                          (episode?['runtime'] is num &&
                              (episode!['runtime'] as num) > 0))
                        Text(
                          context.l10n.format(
                            probe?['duration'] is num &&
                                    (probe!['duration'] as num) > 0
                                ? '影片时长：{minutes} 分钟'
                                : '官方时长：{minutes} 分钟',
                            {
                              'minutes':
                                  probe?['duration'] is num &&
                                      (probe!['duration'] as num) > 0
                                  ? ((probe!['duration'] as num) / 60).round()
                                  : episode!['runtime'],
                            },
                          ),
                        ),
                      if (tv)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: FilmWatchOverlay(
                            store: catalog.store,
                            resource: resource,
                            spoilerSensitive: true,
                            showStatus: false,
                            revealBelow: true,
                            revealLabel: '展示封面',
                            child: Text(
                              episode?['overview'] as String? ?? '',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      if (!tv)
                        TextButton.icon(
                          onPressed: () => onOpenItem(resource.playbackItem),
                          icon: const Icon(SPIcons.play),
                          label: const AppText('播放此文件'),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
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
                        if (_loading) const LinearProgressIndicator(),
                        if (c.error != null)
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: AppText(filmCatalogErrorText(c.error!)),
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
