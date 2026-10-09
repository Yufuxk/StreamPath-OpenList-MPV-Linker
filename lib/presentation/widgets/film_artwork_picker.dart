import '../../data/local/film_catalog_store.dart';
import 'directory_scroll_view.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/errors/app_exception.dart';
import '../../data/models/film_catalog_item.dart';
import '../../domain/services/windows_folder_picker.dart';
import '../controllers/film_catalog_controller.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import 'glass_dialog.dart';
import 'sp_dialog.dart';
import 'film_artwork.dart';

Future<void> showFilmArtworkPicker(
  BuildContext context,
  FilmCatalogController catalog, {
  int? rootId,
  String? collectionId,
}) async {
  await showGlassDialog<void>(
    context: context,
    builder: (_) => _ArtworkPicker(
      catalog: catalog,
      rootId: rootId,
      collectionId: collectionId,
    ),
  );
}

class _ArtworkPicker extends StatefulWidget {
  const _ArtworkPicker({required this.catalog, this.rootId, this.collectionId});
  final FilmCatalogController catalog;
  final int? rootId;
  final String? collectionId;
  @override
  State<_ArtworkPicker> createState() => _ArtworkPickerState();
}

class _ArtworkPickerState extends State<_ArtworkPicker> {
  List<(File, String)> _cached = [];
  bool _loading = true, _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = widget.catalog;
    final cached = <(File, String)>[];
    final paths = <String>{};
    final ok = await c.run(() async {
      for (final work in await c.store.artworkWorks()) {
        for (final path in [
          work.backdropPath,
          work.posterPath,
        ].whereType<String>()) {
          for (final size in ['original', 'w780', 'w342']) {
            final file = await c.images.cached(path, size);
            if (file != null && paths.add(file.path)) {
              cached.add((file, work.title));
            }
          }
        }
      }
    }, clearError: false);
    if (mounted) {
      setState(() {
        _cached = cached;
        _loading = false;
        _error = ok ? null : c.error;
      });
    }
  }

  Future<void> _save(File? file) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final c = widget.catalog;
    final ok = await c.run(() async {
      String? path;
      if (file != null) {
        if (await file.length() > c.images.maxImageBytes) {
          throw const FilmCatalogException('imageTooLarge');
        }
        final bytes = await file.readAsBytes();
        try {
          final codec = await ui.instantiateImageCodec(bytes, targetWidth: 16);
          try {
            final frame = await codec.getNextFrame();
            frame.image.dispose();
          } finally {
            codec.dispose();
          }
        } on Exception {
          throw const FilmCatalogException('invalidImage');
        }
        final directory = Directory(
          p.join(p.dirname(c.store.path), 'film_custom_artwork'),
        );
        await directory.create(recursive: true);
        final copy = File(
          p.join(directory.path, '${sha256.convert(bytes)}.img'),
        );
        if (!await copy.exists()) await copy.writeAsBytes(bytes, flush: true);
        path = copy.path;
      }
      if (widget.collectionId case final id?) {
        await c.store.setCollectionCover(id, path);
      } else if (widget.rootId case final id?) {
        await c.store.setCustomRootCover(id, path);
      } else {
        await c.store.setBackgroundPath(path);
      }
      await c.refresh();
    });
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _error = c.error;
      });
    }
  }

  Future<void> _local() async {
    String? path;
    final ok = await widget.catalog.run(() async {
      try {
        path = await WindowsFolderPicker.pickImage(
          title: context.l10n.text('选择本地图片'),
        );
      } on AppException {
        throw const FilmCatalogException('imagePickerFailed');
      }
    });
    if (!mounted) return;
    if (!ok) {
      setState(() => _error = widget.catalog.error);
      return;
    }
    if (path != null) await _save(File(path!));
  }

  @override
  Widget build(BuildContext context) => SPDialog(
    title: AppText(
      widget.rootId == null && widget.collectionId == null ? '影视库背景' : '修改图片',
    ),
    content: SizedBox(
      width: 760,
      height: MediaQuery.sizeOf(context).height * .55,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            children: [
              OutlinedButton(
                onPressed: _saving ? null : () => _save(null),
                child: const AppText('默认'),
              ),
              FilledButton(
                onPressed: _saving ? null : _local,
                child: const AppText('选择本地图片'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const AppText('选择已缓存封面'),
          if (_error != null) AppText(filmCatalogErrorText(_error!)),
          const SizedBox(height: 12),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : DirectoryScrollView(
                    builder: (scrollController) => GridView.builder(
                      controller: scrollController,
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 180,
                            mainAxisExtent: 140,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                          ),
                      itemCount: _cached.length,
                      itemBuilder: (_, i) => InkWell(
                        onTap: _saving ? null : () => _save(_cached[i].$1),
                        child: Column(
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(
                                  _cached[i].$1,
                                  key: ValueKey(_cached[i].$1.path),
                                  fit: BoxFit.cover,
                                  width: double.infinity,
                                  cacheWidth: 360,
                                  frameBuilder: filmCoverFrameBuilder,
                                ),
                              ),
                            ),
                            Text(
                              _cached[i].$2,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
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
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).pop(),
        child: const AppText('取消'),
      ),
    ],
  );
}
