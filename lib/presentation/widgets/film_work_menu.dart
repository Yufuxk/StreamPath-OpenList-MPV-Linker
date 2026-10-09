import 'sp_menu.dart';
import 'film_collection_dialog.dart';
import 'film_watch_menu.dart';
import 'film_playlist_dialog.dart';
import '../../data/models/film_playlist.dart';
import 'package:flutter/material.dart';

import '../../data/models/film_catalog_item.dart';
import '../controllers/film_catalog_controller.dart';
import '../localization/app_text.dart';
import '../theme/app_theme.dart';
import 'sp_notice.dart';
import 'film_match_dialog.dart';

enum _WorkAction {
  watched,
  unwatched,
  favorite,
  refresh,
  correct,
  collection,
  playlist,
  addPlaylist,
  remove,
}

/// 作品封面共用原资源菜单的材质与作品操作。
Future<void> showFilmWorkMenu(
  BuildContext context, {
  required FilmCatalogController catalog,
  required FilmWork work,
  required Offset position,
  bool refreshing = false,
  Future<void> Function()? onRefresh,
  Future<void> Function()? onRemove,
}) async {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  var favorite = false;
  var watchable = false;
  var playlistable = false;
  final loaded = await catalog.run(() async {
    favorite = await catalog.store.isFavorite(work.id);
    final resources = await catalog.store.resources(
      workId: work.id,
      sourceId: catalog.sourceId,
    );
    watchable = resources.any((r) => r.canMarkWatched);
    playlistable = resources.any(
      (r) =>
          r.availability == 'present' &&
          (r.mediaKind == 'video' || r.mediaKind == 'strm') &&
          (r.type == FilmMediaType.movie ||
              r.season != null && r.episode != null),
    );
  }, clearError: false);
  if (!context.mounted) return;
  if (!loaded) {
    ScaffoldMessenger.of(context).showSnackBar(
      SPNotice(content: AppText(filmCatalogErrorText(catalog.error!))),
    );
    return;
  }
  final local = overlay.globalToLocal(position);
  final action = await showSPMenu<_WorkAction>(
    context: context,
    color: AppTheme.dropdownMenuColor(Theme.of(context)),
    shape: RoundedRectangleBorder(borderRadius: AppTheme.dropdownBorderRadius),
    position: RelativeRect.fromRect(
      Rect.fromLTWH(local.dx, local.dy, 0, 0),
      Offset.zero & overlay.size,
    ),
    items: [
      if (onRemove != null)
        const PopupMenuItem(value: _WorkAction.remove, child: AppText('移除成员')),
      if (onRemove == null) ...[
        const PopupMenuItem(
          value: _WorkAction.collection,
          child: AppText('加入合集'),
        ),
        if (watchable) ...[
          const PopupMenuItem(
            value: _WorkAction.watched,
            child: AppText('标记已看完'),
          ),
          const PopupMenuItem(
            value: _WorkAction.unwatched,
            child: AppText('标记未观看'),
          ),
        ],
        PopupMenuItem(
          value: _WorkAction.favorite,
          child: AppText(favorite ? '取消收藏' : '收藏'),
        ),
        PopupMenuItem(
          value: _WorkAction.refresh,
          enabled: !refreshing,
          child: const AppText('刷新元数据'),
        ),
        const PopupMenuItem(
          value: _WorkAction.correct,
          child: AppText('纠正作品匹配'),
        ),
      ],
      PopupMenuItem(
        value: _WorkAction.playlist,
        enabled: playlistable,
        child: const AppText('以本作品创建播放列表'),
      ),
      PopupMenuItem(
        value: _WorkAction.addPlaylist,
        enabled: playlistable,
        child: const AppText('加入播放列表…'),
      ),
    ],
  );
  if (!context.mounted || action == null) return;
  if (action == _WorkAction.playlist || action == _WorkAction.addPlaylist) {
    await showFilmPlaylistDialog(
      context,
      catalog,
      FilmPlaylistScope.work(work.id),
      create: action == _WorkAction.playlist,
      title: work.title,
    );
    return;
  }
  if (action == _WorkAction.remove) {
    await onRemove!();
    return;
  }
  if (action == _WorkAction.collection) {
    await showAddToFilmCollection(context, catalog, work.id);
    return;
  }
  if (action == _WorkAction.watched || action == _WorkAction.unwatched) {
    final resources = await catalog.store.resources(workId: work.id);
    if (context.mounted) {
      await markFilmWatch(context, resources, action == _WorkAction.watched);
    }
    return;
  }
  if (action == _WorkAction.correct) {
    List<FilmResource> resources = [];
    final ok = await catalog.run(() async {
      resources = await catalog.store.resources(workId: work.id);
    });
    if (!context.mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SPNotice(content: AppText(filmCatalogErrorText(catalog.error!))),
      );
      return;
    }
    if (ok && resources.isNotEmpty) {
      await showFilmMatchDialog(
        context,
        catalog,
        resources.first,
        initialResources: resources,
      );
    }
    return;
  }
  if (action == _WorkAction.refresh && onRefresh != null) {
    await onRefresh();
    return;
  }
  final ok = await catalog.run(
    () => action == _WorkAction.favorite
        ? catalog.store.setFavorite(work.id, !favorite)
        : catalog.matcher.refresh(work),
  );
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SPNotice(content: AppText(filmCatalogErrorText(catalog.error!))),
    );
  }
}
