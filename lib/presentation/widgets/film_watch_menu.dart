import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../data/models/film_catalog_item.dart';
import '../localization/app_text.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import 'glass_dialog.dart';
import 'sp_dialog.dart';

Future<void> showFilmWatchMenu(
  BuildContext context, {
  required Offset position,
  required List<FilmResource> resources,
}) async {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final local = overlay.globalToLocal(position);
  final watched = await showMenu<bool>(
    context: context,
    color: AppTheme.dropdownMenuColor(Theme.of(context)),
    shape: RoundedRectangleBorder(borderRadius: AppTheme.dropdownBorderRadius),
    position: RelativeRect.fromRect(
      Rect.fromLTWH(local.dx, local.dy, 0, 0),
      Offset.zero & overlay.size,
    ),
    items: const [
      PopupMenuItem(value: true, child: AppText('标记已看完')),
      PopupMenuItem(value: false, child: AppText('标记未观看')),
    ],
  );
  if (watched != null && context.mounted) {
    await markFilmWatch(context, resources, watched);
  }
}

Future<void> markFilmWatch(
  BuildContext context,
  List<FilmResource> resources,
  bool watched,
) async {
  resources = resources.where((r) => r.canMarkWatched).toList();
  if (resources.isEmpty) return;
  final sources = resources.map((r) => r.sourceId).toSet();
  String? selected;
  if (sources.length > 1) {
    selected = await showGlassDialog<String>(
      context: context,
      builder: (ctx) => SPDialog(
        title: const AppText('选择作用来源'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final id in sources)
                ListTile(
                  title: Text(
                    resources.firstWhere((r) => r.sourceId == id).rootName,
                  ),
                  subtitle: Text(id),
                  onTap: () => Navigator.of(ctx).pop(id),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const AppText('取消'),
          ),
        ],
      ),
    );
    if (selected == null || !context.mounted) return;
  }
  if (!context.mounted) return;
  await context.read<AppState>().markFilmWatched(
    resources.where((r) => selected == null || r.sourceId == selected).toList(),
    watched,
  );
}
