import 'dart:io';
import 'package:flutter/material.dart';

import '../../domain/services/film_catalog_image_cache.dart';
import 'adaptive_film_backdrop.dart';
import 'app_background.dart';

class FilmLibraryBackground extends StatelessWidget {
  const FilmLibraryBackground({
    super.key,
    required this.cache,
    required this.file,
    this.onReady,
    this.onError,
    this.revision = 0,
  });
  final FilmCatalogImageCache cache;
  final File? file;
  final VoidCallback? onReady;
  final VoidCallback? onError;
  final int revision;

  @override
  Widget build(BuildContext context) =>
      AppBackgroundScope.maybeOf(context) != null && file != null
      ? const SizedBox.expand()
      : AdaptiveFilmBackdrop(
          key: const Key('film-library-background'),
          cache: cache,
          file: file,
          revision: revision,
          onReady: onReady,
          onError: onError,
          style: FilmBackdropStyle.library,
        );
}
