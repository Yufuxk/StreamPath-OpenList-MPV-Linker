import 'package:flutter/material.dart';
import '../../data/models/film_collection.dart';
import '../../data/local/film_catalog_store.dart';
import '../controllers/film_catalog_controller.dart';
import '../localization/app_text.dart';
import '../localization/app_localizations.dart';
import 'directory_scroll_view.dart';
import 'glass_dialog.dart';
import 'sp_dialog.dart';

Future<void> showAddToFilmCollection(
  BuildContext context,
  FilmCatalogController catalog,
  int workId,
) => showGlassDialog<void>(
  context: context,
  builder: (_) => _CollectionDialog(catalog: catalog, workId: workId),
);

class _CollectionDialog extends StatefulWidget {
  const _CollectionDialog({required this.catalog, required this.workId});
  final FilmCatalogController catalog;
  final int workId;
  @override
  State<_CollectionDialog> createState() => _CollectionDialogState();
}

class _CollectionDialogState extends State<_CollectionDialog> {
  final _name = TextEditingController();
  List<FilmCollection> _collections = [];
  bool _busy = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ok = await widget.catalog.run(() async {
      _collections = await widget.catalog.store.collections(customOnly: true);
    });
    if (mounted) {
      setState(() {
        _busy = false;
        _error = ok ? null : widget.catalog.error;
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _add(String? id) async {
    setState(() => _busy = true);
    final ok = await widget.catalog.run(() async {
      final key = id ?? await widget.catalog.store.createCollection(_name.text);
      await widget.catalog.store.addCollectionMember(key, widget.workId);
    });
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _error = widget.catalog.error;
      });
    }
  }

  @override
  Widget build(BuildContext context) => SPDialog(
    title: const AppText('加入合集'),
    content: SizedBox(
      width: 440,
      height: 360,
      child: Column(
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) AppText(filmCatalogErrorText(_error!)),
          Expanded(
            child: DirectoryScrollView(
              builder: (controller) => ListView.builder(
                controller: controller,
                itemCount: _collections.length,
                itemBuilder: (_, i) => ListTile(
                  title: Text(_collections[i].name),
                  onTap: _busy ? null : () => _add(_collections[i].id),
                ),
              ),
            ),
          ),
          TextField(
            controller: _name,
            enabled: !_busy,
            decoration: InputDecoration(labelText: context.l10n.text('合集名称')),
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
        onPressed: _busy ? null : () => _add(null),
        child: const AppText('创建合集'),
      ),
    ],
  );
}
