import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/theme/app_theme.dart';

void main() {
  for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
    testWidgets('开关圆角边缘与操作在 DPR $dpr 保持一致', (tester) async {
      tester.view.physicalSize = Size(240 * dpr, 112 * dpr);
      tester.view.devicePixelRatio = dpr;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final theme = AppTheme.light(accentColor: 0xFFFFFFFF);
      var value = true;
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: RepaintBoundary(
            key: const Key('switch-preview'),
            child: Material(
              color: theme.scaffoldBackgroundColor,
              child: Row(
                children: [
                  Expanded(
                    child: SwitchTheme(
                      data: theme.switchTheme.copyWith(
                        trackOutlineColor: WidgetStatePropertyAll(
                          theme.colorScheme.outlineVariant,
                        ),
                        trackOutlineWidth: const WidgetStatePropertyAll(2),
                      ),
                      child: Column(
                        children: [
                          Switch(value: true, onChanged: (_) {}),
                          Switch(value: false, onChanged: (_) {}),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: StatefulBuilder(
                      builder: (context, update) => Column(
                        children: [
                          Switch(
                            key: const Key('smooth-switch'),
                            value: value,
                            focusNode: focus,
                            onChanged: (next) => update(() => value = next),
                          ),
                          Switch(value: false, onChanged: (_) {}),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (Platform.environment['SP_ACCENT_RENDER'] == '1') {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const Key('switch-preview')),
          );
          final picture = await boundary.toImage(pixelRatio: dpr);
          final bytes = await picture.toByteData(
            format: ui.ImageByteFormat.png,
          );
          picture.dispose();
          final file = File('build/accent-color/switch-edges-$dpr.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
        });
      }
      final control = find.byKey(const Key('smooth-switch'));
      final size = tester.getSize(control);
      await tester.tap(control);
      await tester.pumpAndSettle();
      expect(value, isFalse);
      expect(tester.getSize(control), size);
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(value, isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}
