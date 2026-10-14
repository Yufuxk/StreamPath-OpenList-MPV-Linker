import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/cinematic_states.dart';
import 'package:streampath/presentation/widgets/directory_scroll_view.dart';
import 'package:streampath/presentation/widgets/glass_surface.dart';

void main() {
  testWidgets('horizontal fade reveals wallpaper without tinting empty space', (
    tester,
  ) async {
    const background = Color(0xFF566878);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Center(
          child: RepaintBoundary(
            key: boundary,
            child: SizedBox(
              width: 300,
              height: 120,
              child: ColoredBox(
                color: background,
                child: DirectoryScrollView(
                  scrollDirection: Axis.horizontal,
                  hideScrollbar: true,
                  builder: (controller) => ListView(
                    controller: controller,
                    scrollDirection: Axis.horizontal,
                    children: const [
                      Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: SizedBox(
                          width: 800,
                          child: ColoredBox(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final capture = await tester.runAsync(() async {
      final image =
          await (boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final width = image.width;
      image.dispose();
      return (pixels, width);
    });
    for (final y in [10, 110]) {
      for (var channel = 0; channel < 3; channel++) {
        expect(
          capture!.$1.getUint8((y * capture.$2 + 296) * 4 + channel),
          [0x56, 0x68, 0x78][channel],
        );
      }
    }
    expect(capture!.$1.getUint8((60 * capture.$2 + 160) * 4), 255);
    expect(capture.$1.getUint8((60 * capture.$2 + 296) * 4), closeTo(0x56, 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'empty panels use the lighter shared surface without changing blur or radius',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(
            body: ImmersiveEmptyState(
              icon: Icons.list,
              title: '暂无播放列表',
              description: '播放列表为空',
            ),
          ),
        ),
      );
      final surface = tester.widget<GlassSurface>(find.byType(GlassSurface));
      expect(surface.color!.a, closeTo(.25, .001));
      expect(surface.borderRadius, AppTheme.panelRadius);
      expect(surface.blurSigma, 16);
      expect(surface.blur, isTrue);
    },
  );
}
