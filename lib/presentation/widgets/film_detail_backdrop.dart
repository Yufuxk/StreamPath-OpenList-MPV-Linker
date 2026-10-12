import 'package:flutter/material.dart';

import '../controllers/film_catalog_controller.dart';
import 'adaptive_film_backdrop.dart';
import 'film_adaptive_foreground.dart';

/// 详情与橱窗使用同一背景策略和防剧透状态。
class FilmDetailBackdrop extends StatelessWidget {
  const FilmDetailBackdrop({
    super.key,
    required this.catalog,
    required this.path,
    this.workId,
    this.style = FilmBackdropStyle.detail,
    this.textColors,
    this.onImageReady,
    this.artworkKey = const Key('film-detail-backdrop'),
  });
  final FilmCatalogController catalog;
  final String? path;
  final int? workId;
  final Key artworkKey;
  final FilmBackdropStyle style;
  final FilmBackdropTextController? textColors;
  final VoidCallback? onImageReady;

  @override
  Widget build(BuildContext context) => AdaptiveFilmBackdrop(
    key: artworkKey,
    cache: catalog.images,
    path: path,
    watchStore: catalog.store,
    workId: workId,
    style: style,
    textColors: textColors,
    onImageReady: onImageReady,
  );
}
