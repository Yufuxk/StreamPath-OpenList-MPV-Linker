import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/theme/glass_tokens.dart';
import 'package:streampath/presentation/widgets/glass_dialog.dart';
import 'package:streampath/presentation/widgets/glass_surface.dart';

void main() {
  testWidgets('玻璃表面使用统一层级且不会自行创建背景模糊', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(glass: true),
        home: const GlassSurface(
          level: GlassSurfaceLevel.raised,
          borderRadius: BorderRadius.all(Radius.circular(16)),
          child: SizedBox(width: 240, height: 120),
        ),
      ),
    );

    expect(find.byType(GlassSurface), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    final surface = tester.widget<GlassSurface>(find.byType(GlassSurface));
    expect(surface.level, GlassSurfaceLevel.raised);
    expect(
      Theme.of(tester.element(find.byType(GlassSurface))).glass.enabled,
      isTrue,
    );
  });

  testWidgets('玻璃对话框只在模态层创建一层背景模糊', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(glass: true),
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () => showGlassDialog<void>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: const Text('确认'),
                content: const Text('测试对话框'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });
}
