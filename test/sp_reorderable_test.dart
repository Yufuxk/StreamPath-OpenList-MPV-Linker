import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/theme/glass_tokens.dart';
import 'package:streampath/presentation/theme/window_appearance_status.dart';
import 'package:streampath/presentation/widgets/directory_scroll_view.dart';
import 'package:streampath/presentation/widgets/sp_icons.dart';
import 'package:streampath/presentation/widgets/sp_menu.dart';
import 'package:streampath/presentation/widgets/sp_reorderable.dart';

void main() {
  for (final material in [
    null,
    WindowBackdropType.systemAcrylic,
    WindowBackdropType.mica,
  ]) {
    for (final dark in [false, true]) {
      testWidgets(
        'drag uses menu material and keeps reorder for $material dark=$dark',
        (tester) async {
          final theme = dark
              ? AppTheme.dark(
                  glass: material != null,
                  windowBackdrop: material ?? WindowBackdropType.systemAcrylic,
                )
              : AppTheme.light(
                  glass: material != null,
                  windowBackdrop: material ?? WindowBackdropType.systemAcrylic,
                );
          final scroll = ScrollController();
          addTearDown(scroll.dispose);
          final items = [0, 1, 2];
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: Scaffold(
                body: DirectoryScrollView(
                  controller: scroll,
                  builder: (controller) => ReorderableListView.builder(
                    scrollController: controller,
                    buildDefaultDragHandles: false,
                    proxyDecorator: spReorderProxy,
                    itemCount: items.length,
                    onReorderItem: (from, to) =>
                        items.insert(to, items.removeAt(from)),
                    itemBuilder: (_, i) => ListTile(
                      key: ValueKey(items[i]),
                      title: Text('Item ${items[i]}'),
                      trailing: SPReorderHandle(index: i, tooltip: 'Reorder'),
                    ),
                  ),
                ),
              ),
            ),
          );
          expect(
            tester.widget<Icon>(find.byIcon(SPIcons.swapVertical).first).icon,
            SPIcons.swapVertical,
          );
          final drag = await tester.startGesture(
            tester.getCenter(find.byType(SPReorderHandle).first),
          );
          await drag.moveBy(const Offset(0, 20));
          await tester.pump(const Duration(milliseconds: 250));
          expect(find.byType(SPMenuSurface), findsOneWidget);
          final surface = tester.widget<Material>(
            find
                .descendant(
                  of: find.byType(SPMenuSurface),
                  matching: find.byType(Material),
                )
                .first,
          );
          expect(
            surface.color,
            theme.glass.enabled
                ? theme.glass.modalSurface
                : AppTheme.dropdownMenuColor(theme),
          );
          expect(surface.surfaceTintColor, Colors.transparent);
          await drag.moveBy(const Offset(0, 100));
          await tester.pump(const Duration(milliseconds: 500));
          await drag.up();
          await tester.pumpAndSettle();
          expect(items.first, 1);
          expect(find.byType(SPMenuSurface), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
