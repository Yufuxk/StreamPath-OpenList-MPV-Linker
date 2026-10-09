import 'sp_menu.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import '../../core/errors/app_exception.dart';
import '../../data/models/media_directory_entry.dart';
import '../../domain/repositories/media_directory_source.dart';
import '../../domain/services/film_catalog_scanner.dart';
import '../../domain/services/local_media_source.dart';
import '../../domain/services/special_video_playlist_collector.dart';
import '../../domain/services/webdav_media_source_adapter.dart';
import '../localization/app_text.dart';
import '../widgets/directory_scroll_view.dart';
import '../widgets/sp_dialog.dart';
import '../widgets/sp_icons.dart';
import '../controllers/film_catalog_controller.dart';

class FilmDirectoryDialog extends StatefulWidget {
  const FilmDirectoryDialog({
    super.key,
    required this.source,
    this.initialPath = '',
    this.boundaryPath = '',
  });
  final String initialPath, boundaryPath;
  final MediaDirectorySource source;
  @override
  State<FilmDirectoryDialog> createState() => FilmDirectoryDialogState();
}

class FilmDirectoryDialogState extends State<FilmDirectoryDialog> {
  String _path = '';
  List<MediaDirectoryEntry> _directories = [];
  bool _loading = true;
  bool _unsupported = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load(widget.initialPath);
  }

  Future<void> _load(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final source = widget.source;
      final entries = source is LocalMediaSource
          ? await source.fetchCatalogDirectory(path)
          : source is WebDavMediaSourceAdapter
          ? await source.fetchCatalogDirectory(path)
          : await source.fetchDirectory(path, forceRefresh: true);
      if (mounted) {
        setState(() {
          _path = path;
          _unsupported = entries.any(
            (e) =>
                e.isDirectory &&
                !e.isSelfEntry &&
                e.name.toLowerCase() == 'video_ts',
          );
          _directories = entries
              .where(
                (e) =>
                    e.isDirectory &&
                    !e.isSelfEntry &&
                    !FilmCatalogScanner.excludedDirectory(e.name) &&
                    SpecialVideoPlaylistCollector.directChildPath(
                          source,
                          path,
                          e,
                        ) !=
                        null,
              )
              .toList();
          _directories.sort((a, b) => a.name.compareTo(b.name));
        });
      }
    } on AppException {
      if (mounted) setState(() => _error = 'directoryReadFailed');
    } on FileSystemException {
      if (mounted) setState(() => _error = 'directoryReadFailed');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => SPDialog(
    title: const AppText('选择来源内目录'),
    content: SizedBox(
      width: 560,
      height: MediaQuery.sizeOf(context).height * 0.45,
      child: Column(
        children: [
          SelectableText(contextMenuBuilder: buildSPTextSelectionMenu, _path.isEmpty ? '/' : _path),
          if (_path != widget.boundaryPath)
            TextButton(
              onPressed: _loading
                  ? null
                  : () {
                      final parts = _path.split('/')..removeLast();
                      _load(parts.join('/'));
                    },
              child: const AppText('返回上级'),
            ),
          if (_unsupported) const AppText('影视库暂不收录 DVD 结构'),
          if (_error != null) AppText(filmCatalogErrorText(_error!)),
          if (_loading) const LinearProgressIndicator(),
          Expanded(
            child: DirectoryScrollView(
              builder: (scrollController) => ListView.builder(
                controller: scrollController,
                itemCount: _directories.length,
                itemBuilder: (context, i) => ListTile(
                  leading: const Icon(SPIcons.folder),
                  title: Text(_directories[i].name),
                  onTap: _loading
                      ? null
                      : () {
                          final path =
                              SpecialVideoPlaylistCollector.directChildPath(
                                widget.source,
                                _path,
                                _directories[i],
                              );
                          if (path != null) _load(path);
                        },
                ),
              ),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const AppText('取消'),
      ),
      FilledButton(
        onPressed: _loading || _error != null || _unsupported
            ? null
            : () => Navigator.of(context).pop(_path),
        child: const AppText('选择此目录'),
      ),
    ],
  );
}
