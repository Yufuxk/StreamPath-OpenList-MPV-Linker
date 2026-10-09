import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/theme/window_appearance_status.dart';
import 'package:streampath/presentation/widgets/sp_menu.dart';
import 'package:streampath/presentation/theme/glass_tokens.dart';
import 'package:streampath/presentation/widgets/directory_scroll_view.dart';

void main() {
  for (final material in [
    null,
    WindowBackdropType.systemAcrylic,
    WindowBackdropType.mica,
  ]) {
    testWidgets('menu and dropdown retain selection and focus for $material', (
      tester,
    ) async {
      String? choice;
      final focus = FocusNode();
      final theme = AppTheme.dark(
        glass: material != null,
        windowBackdrop: material ?? WindowBackdropType.systemAcrylic,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  TextButton(
                    focusNode: focus,
                    onPressed: () async {
                      choice = await showSPMenu(
                        context: context,
                        position: const RelativeRect.fromLTRB(60, 70, 0, 0),
                        items: const [
                          PopupMenuItem(value: 'one', child: Text('One')),
                          PopupMenuItem(value: 'two', child: Text('Two')),
                        ],
                      );
                    },
                    child: const Text('Open'),
                  ),
                  SPDropdownButtonFormField<String>(
                    initialValue: 'one',
                    dropdownColor: AppTheme.dropdownMenuColor(theme),
                    items: const [
                      DropdownMenuItem(value: 'one', child: Text('First')),
                      DropdownMenuItem(value: 'two', child: Text('Second')),
                    ],
                    onChanged: (value) => choice = value,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      focus.requestFocus();
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(
        find.byType(BackdropFilter),
        material == null ? findsNothing : findsOneWidget,
      );
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
        material == null
            ? AppTheme.dropdownMenuColor(theme)
            : theme.glass.modalSurface,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(choice, 'one');
      expect(focus.hasFocus, true);
      await tester.tap(find.text('First'));
      await tester.pumpAndSettle();
      expect(
        find.byType(BackdropFilter),
        material == null ? findsNothing : findsOneWidget,
      );
      await tester.tap(find.text('Second').last);
      await tester.pumpAndSettle();
      expect(choice, 'two');
      await tester.pumpWidget(const SizedBox());
      focus.dispose();
    });
  }
  testWidgets('glass selection menu invokes existing copy action', (
    tester,
  ) async {
    var copied = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(
          glass: true,
        ).copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: Builder(
            builder: (context) => buildSPSelectionToolbar(
              context,
              const TextSelectionToolbarAnchors(primaryAnchor: Offset(70, 90)),
              [
                ContextMenuButtonItem(
                  type: ContextMenuButtonType.copy,
                  onPressed: () => copied = true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);
    await tester.tap(find.text('Copy'));
    expect(copied, true);
  });
  testWidgets('dropdown inside a dialog adds glass only when its menu opens', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(glass: true),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => Dialog(
                  child: SPDropdownButtonFormField<String>(
                    initialValue: 'one',
                    items: const [
                      DropdownMenuItem(value: 'one', child: Text('First')),
                      DropdownMenuItem(value: 'two', child: Text('Second')),
                    ],
                    onChanged: (_) {},
                  ),
                ),
              ),
              child: const Text('Dialog'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Dialog'));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
    await tester.tap(find.text('First'));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsOneWidget);
  });
  testWidgets(
    'new dropdown preserves form validation, reset, disabled options and Escape',
    (tester) async {
      final form = GlobalKey<FormState>();
      final field = GlobalKey<FormFieldState<String>>();
      final focus = FocusNode();
      String? choice;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(glass: true),
          home: Scaffold(
            body: Form(
              key: form,
              child: SPDropdownButtonFormField<String>(
                key: field,
                initialValue: 'one',
                focusNode: focus,
                items: const [
                  DropdownMenuItem(value: 'one', child: Text('One')),
                  DropdownMenuItem(value: 'two', child: Text('Two')),
                  DropdownMenuItem(
                    value: 'disabled',
                    enabled: false,
                    child: Text('Disabled'),
                  ),
                ],
                validator: (value) => value == 'two' ? null : 'Choose Two',
                onChanged: (value) => choice = value,
              ),
            ),
          ),
        ),
      );
      expect(form.currentState!.validate(), false);
      await tester.pump();
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(SPMenuSurface), findsOneWidget);
      await tester.tap(find.text('Disabled'));
      await tester.pump();
      expect(choice, isNull);
      expect(find.byType(SPMenuSurface), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(field.currentState!.value, 'one');
      expect(focus.hasFocus, true);
      await tester.tap(find.text('One'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Two'));
      await tester.pumpAndSettle();
      expect(choice, 'two');
      expect(form.currentState!.validate(), true);
      form.currentState!.reset();
      await tester.pump();
      expect(field.currentState!.value, 'one');
      await tester.pumpWidget(const SizedBox());
      focus.dispose();
    },
  );
  testWidgets(
    'long dropdown uses the shared scroll controller and keeps the whole surface',
    (tester) async {
      String? choice;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(glass: true),
          home: Scaffold(
            body: SizedBox(
              width: 250,
              child: SPDropdownButtonFormField<String>(
                initialValue: '0',
                menuMaxHeight: 180,
                items: [
                  for (var i = 0; i < 40; i++)
                    DropdownMenuItem(value: '$i', child: Text('Option $i')),
                ],
                onChanged: (value) => choice = value,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Option 0'));
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsOneWidget);
      final shared = find.byType(DirectoryScrollView);
      final scrollable = find.descendant(
        of: shared,
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.text('Option 39'),
        300,
        scrollable: scrollable,
      );
      await tester.tap(find.text('Option 39'));
      await tester.pumpAndSettle();
      expect(choice, '39');
      expect(tester.takeException(), isNull);
    },
  );
}
