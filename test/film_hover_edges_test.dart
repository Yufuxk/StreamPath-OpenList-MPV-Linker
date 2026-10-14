import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';
import 'package:streampath/presentation/widgets/film_shelf.dart';

void main() {
  testWidgets('shelf reserves poster hover space and blends the scroll edge', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    for (final width in [364.0, 458.99, 459.0, 648.99, 649.0]) {
      final layout = FilmShelf.adaptiveLayout(width, 15);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: boundary,
              child: SizedBox(
                width: 800,
                height: 500,
                child: ColoredBox(
                  color: const Color(0xFF33445C),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 50),
                      child: SizedBox(
                        width: width,
                        child: FilmShelf(
                          title: 'Movies',
                          count: 30,
                          builder: (_, i) => FilmPosterHover(
                            hovered: i == layout.visible - 1,
                            child: FilmPosterHoverSurface(
                              child: ColoredBox(
                                key: ValueKey(i),
                                color: Colors.black,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final last = tester.getRect(find.byKey(ValueKey(layout.visible - 1)));
      expect(last.width, closeTo(layout.width * 1.05, .01));
      expect(
        tester.getRect(find.byType(Viewport)).right,
        greaterThan(last.right + 1),
      );
      final outer =
          boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final capture = await tester.runAsync(() async {
        final image = await outer.toImage();
        final pixels = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final imageWidth = image.width;
        image.dispose();
        return (pixels, imageWidth);
      });
      final y = (last.top + 50).floor();
      var brightest = 0;
      for (var x = (50 + width + 1).ceil(); x <= last.right.ceil(); x++) {
        final value = capture!.$1.getUint8((y * capture.$2 + x) * 4);
        if (value > brightest) brightest = value;
      }
      expect(
        brightest,
        closeTo(0x33, 3),
        reason:
            'Faded right edge reveals the actual background at width $width',
      );
      expect(tester.takeException(), isNull);
    }
  });
}
