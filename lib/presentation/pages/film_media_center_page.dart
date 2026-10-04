import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../data/models/media_library_item.dart';
import '../controllers/film_catalog_controller.dart';
import '../localization/app_text.dart';
import '../state/app_state.dart';
import 'global_media_library_page.dart';

class FilmMediaCenterPage extends StatefulWidget {
  const FilmMediaCenterPage({
    super.key,
    required this.onOpenItem,
    required this.onContinueSelected,
    required this.onContinueMenu,
    required this.onOpenLegacyItem,
  });
  final ValueChanged<MediaLibraryItem> onOpenItem, onOpenLegacyItem;
  final ValueChanged<MediaLibraryRecord> onContinueSelected;
  final void Function(MediaLibraryRecord, Offset) onContinueMenu;
  @override
  State<FilmMediaCenterPage> createState() => _FilmMediaCenterPageState();
}

class _FilmMediaCenterPageState extends State<FilmMediaCenterPage> {
  late final Future<FilmCatalogController> _catalog;
  @override
  void initState() {
    super.initState();
    _catalog = context.read<AppState>().getFilmCatalog();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<FilmCatalogController>(
    future: _catalog,
    builder: (context, snapshot) {
      if (!snapshot.hasData) {
        return Scaffold(
          appBar: AppBar(toolbarHeight: 48, title: const AppText('媒体中心')),
          body: Center(
            child: snapshot.hasError
                ? const AppText('影视目录库操作失败')
                : const CircularProgressIndicator(),
          ),
        );
      }
      return Navigator(
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (pageContext) => GlobalMediaLibraryPage(
            filmCatalog: snapshot.data!,
            filmCenter: true,
            onOpenItem: widget.onOpenItem,
            onContinueSelected: widget.onContinueSelected,
            onContinueMenu: widget.onContinueMenu,
            headerAction: TextButton(
              onPressed: () => Navigator.of(pageContext).push(
                MaterialPageRoute<void>(
                  builder: (legacyContext) => GlobalMediaLibraryPage(
                    onOpenItem: widget.onOpenLegacyItem,
                    headerAction: TextButton(
                      onPressed: () => Navigator.of(legacyContext).pop(),
                      child: const AppText('返回新媒体中心'),
                    ),
                  ),
                ),
              ),
              child: const AppText('旧媒体中心'),
            ),
          ),
        ),
      );
    },
  );
}
