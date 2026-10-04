import 'dart:async';
import 'package:flutter/material.dart';
import '../../data/models/film_home_section.dart';
import '../controllers/film_catalog_controller.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import 'sp_icons.dart';
import 'sp_notice.dart';

String filmSectionTitle(BuildContext context, FilmHomeSection section) =>
    context.l10n.format(section.label, {'value': section.value});

class FilmSectionSettings extends StatefulWidget {
  const FilmSectionSettings({super.key, required this.catalog});
  final FilmCatalogController catalog;
  @override
  State<FilmSectionSettings> createState() => _FilmSectionSettingsState();
}

class _FilmSectionSettingsState extends State<FilmSectionSettings> {
  bool _saving = false;
  List<FilmHomeSection>? _sections;
  FilmCatalogController get catalog => widget.catalog;
  Future<void> _save(List<FilmHomeSection> sections) async {
    setState(() {
      _saving = true;
      _sections = sections;
    });
    try {
      if (await catalog.run(() => catalog.store.setHomeSections(sections))) {
        catalog.homeSections = sections;
        unawaited(catalog.refresh());
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SPNotice(content: AppText(filmCatalogErrorText(catalog.error!))),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _sections = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: _saving,
    child: ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: (_sections ?? catalog.homeSections).length,
      onReorderItem: (oldIndex, newIndex) {
        final sections = List<FilmHomeSection>.of(
          _sections ?? catalog.homeSections,
        );
        final section = sections.removeAt(oldIndex);
        sections.insert(newIndex, section);
        _save(sections);
      },
      itemBuilder: (context, i) {
        final section = (_sections ?? catalog.homeSections)[i];
        return ListTile(
          key: ValueKey(section.id),
          contentPadding: EdgeInsets.zero,
          leading: Checkbox(
            value: section.enabled,
            onChanged: (value) {
              final sections = List<FilmHomeSection>.of(
                _sections ?? catalog.homeSections,
              );
              sections[i] = section.withEnabled(value!);
              _save(sections);
            },
          ),
          title: Text(
            filmSectionTitle(context, section),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: ReorderableDragStartListener(
            index: i,
            child: Tooltip(
              message: context.l10n.text('拖动调整栏目顺序'),
              child: const Icon(SPIcons.sort),
            ),
          ),
        );
      },
    ),
  );
}
