import 'film_watch_overlay.dart';
import 'film_card_glass.dart';
import 'skeleton_scope.dart';
import 'package:flutter/material.dart';

import '../../data/models/media_library_item.dart';
import '../../data/models/film_catalog_item.dart';
import '../controllers/film_catalog_controller.dart';
import '../localization/app_localizations.dart';
import 'film_artwork.dart';
import '../theme/app_theme.dart';
import 'sp_icons.dart';
import 'film_play_icon.dart';

class FilmContinueCard extends StatefulWidget {
  static const landscapeWidth = 300.0;
  static const landscapeHeight = 220.0;
  const FilmContinueCard({
    super.key,
    required this.catalog,
    required this.record,
    required this.onTap,
    this.positionMs,
    this.durationMs,
    this.onMenu,
    this.poster = false,
  });
  final FilmCatalogController catalog;
  final MediaLibraryRecord record;
  final int? positionMs, durationMs;
  final VoidCallback onTap;
  final ValueChanged<Offset>? onMenu;
  final bool poster;
  @override
  State<FilmContinueCard> createState() => _FilmContinueCardState();
}

class _FilmContinueCardState extends State<FilmContinueCard> {
  late Future<Map<String, dynamic>> _metadata;
  @override
  void initState() {
    super.initState();
    _metadata = _load();
  }

  @override
  void didUpdateWidget(FilmContinueCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.record.item.stableKey != widget.record.item.stableKey ||
        oldWidget.catalog != widget.catalog ||
        oldWidget.poster != widget.poster) {
      _metadata = _load();
    }
  }

  Future<Map<String, dynamic>> _load() async {
    final store = widget.catalog.store;
    final item = widget.record.item;
    final resource = await store.resourceAt(
      item.sourceId,
      item.discRootPath ?? item.targetPath,
    );
    final work = resource?.workId == null
        ? null
        : await store.work(resource!.workId!);
    final season = resource?.season == null || work == null
        ? null
        : await store.season(work.id, resource!.season!);
    final episode = (season?['episodes'] as List?)
        ?.where((e) => e['episode_number'] == resource?.episode)
        .firstOrNull;
    return {
      'resource': resource,
      'title': work?.title ?? item.name,
      'path': widget.poster
          ? work?.posterPath
          : episode?['still_path'] ?? work?.backdropPath ?? work?.posterPath,
      'season': resource?.season,
      'episode': resource?.episode,
      'episodeTitle': episode?['name'],
      'spoilerSensitive':
          !widget.poster &&
          resource?.season != null &&
          resource?.episode != null,
    };
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(
    future: _metadata,
    builder: (_, snapshot) {
      final data = snapshot.data ?? {'title': widget.record.item.name};
      final cover = FilmPosterHover(
        borderRadius: AppTheme.panelRadius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            FilmWatchOverlay(
              hoverSurface: true,
              store: widget.catalog.store,
              resource: data['resource'] as FilmResource?,
              canReveal: false,
              spoilerSensitive: data['spoilerSensitive'] == true,
              fallbackFraction:
                  widget.positionMs != null && (widget.durationMs ?? 0) > 0
                  ? (widget.positionMs! / widget.durationMs!).clamp(0.0, 1.0)
                  : null,
              sourceId: widget.record.item.sourceId,
              path: widget.record.item.targetPath,
              child: ClipRect(
                child: FilmArtwork(
                  cache: widget.catalog.images,
                  path: data['path'] as String?,
                  width: double.infinity,
                  height: double.infinity,
                  borderRadius: 0,
                  placeholder: const SizedBox.shrink(),
                ),
              ),
            ),
            const Center(child: FilmPlayIcon()),
            if (widget.onMenu != null)
              Align(
                alignment: Alignment.topRight,
                child: Builder(
                  builder: (buttonContext) => IconButton(
                    tooltip: context.l10n.text('更多操作'),
                    icon: const Icon(SPIcons.more, color: Colors.white),
                    onPressed: () {
                      final box =
                          buttonContext.findRenderObject()! as RenderBox;
                      widget.onMenu!(
                        box.localToGlobal(Offset(0, box.size.height)),
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      );
      return SkeletonLoadBoundary(
        ready: snapshot.connectionState == ConnectionState.done,
        child: GestureDetector(
          onSecondaryTapDown: widget.onMenu == null
              ? null
              : (details) => widget.onMenu!(details.globalPosition),
          child: Card(
            margin: EdgeInsets.zero,
            color: Colors.transparent,
            clipBehavior: Clip.none,
            borderOnForeground: false,
            child: InkWell(
              hoverColor: Colors.transparent,
              borderRadius: AppTheme.panelRadius,
              onTap: widget.onTap,
              child: FilmCardGlass(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: cover),
                    Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            data['title'] as String,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          if (data['season'] != null)
                            Text(
                              '${context.l10n.format('第 {season} 季', {'season': data['season']})} · ${context.l10n.format('第 {episode} 集', {'episode': data['episode']})}${data['episodeTitle'] == null ? '' : ' · ${data['episodeTitle']}'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          if (widget.poster && widget.positionMs != null)
                            Text(
                              context.l10n.format('已播放 {time}', {
                                'time': Duration(
                                  milliseconds: widget.positionMs!,
                                ).toString().split('.').first,
                              }),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
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
      );
    },
  );
}
