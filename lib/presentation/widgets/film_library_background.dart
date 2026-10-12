import 'dart:io';
import 'package:flutter/material.dart';

import '../../domain/services/film_catalog_image_cache.dart';
import 'adaptive_film_backdrop.dart';

class FilmLibraryBackground extends StatelessWidget {
  const FilmLibraryBackground({
    super.key,
    required this.cache,
    required this.file,
    this.onReady,
  });
  final FilmCatalogImageCache cache;
  final File? file;
  final VoidCallback? onReady;

  @override
  Widget build(BuildContext context) => AdaptiveFilmBackdrop(
    key: const Key('film-library-background'),
    cache: cache,
    file: file,
    onReady: onReady,
    style: FilmBackdropStyle.library,
  );
}
