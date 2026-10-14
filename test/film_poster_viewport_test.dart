import 'dart:ui' as ui;
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';
import 'package:streampath/presentation/widgets/film_shelf.dart';

void main() {
  for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
    testWidgets('ten fitted posters keep the last edge visible at $dpr DPR', (
      tester,
    ) async {
      tester.view.physicalSize = Size(2000 * dpr, 650 * dpr);
      tester.view.devicePixelRatio = dpr;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: RepaintBoundary(
            key: boundary,
            child: Material(
              color: const Color(0xFF607080),
              child: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 40.3, top: 20.7),
                  child: SizedBox(
                    width: 1808,
                    child: FilmShelf(
                      title: 'Movies',
                      count: 10,
                      builder: (_, i) => FilmPosterHover(
                        key: ValueKey('card-$i'),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: FilmPosterHoverSurface(
                                child: ColoredBox(
                                  key: ValueKey('poster-$i'),
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            const Text('Static caption'),
                          ],
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
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      final slot = tester.getRect(find.byKey(const ValueKey('card-9')));
      final title = tester.getRect(find.text('Static caption').last);
      final baseWidth = tester
          .getSize(find.byKey(const ValueKey('poster-9')))
          .width;
      final outer = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(boundary),
      );
      final viewport = tester.getRect(find.byType(Viewport));
      for (final hovered in [true, false, true, false]) {
        await mouse.moveTo(
          hovered ? Offset(slot.right - 1, slot.top + 80) : Offset.zero,
        );
        var previousWidth = tester
            .getRect(find.byKey(const ValueKey('poster-9')))
            .width;
        for (var frame = 0; frame < 14; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          final rect = tester.getRect(find.byKey(const ValueKey('poster-9')));
          if (hovered) {
            expect(rect.width, greaterThanOrEqualTo(previousWidth - .001));
          } else {
            expect(rect.width, lessThanOrEqualTo(previousWidth + .001));
          }
          previousWidth = rect.width;
          expect(tester.getRect(find.text('Static caption').last), title);
          final value = await tester.runAsync(() async {
            final image = await outer.toImage(pixelRatio: dpr);
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            final value = bytes.getUint8(
              ((rect.center.dy * dpr).floor() * image.width +
                      ((rect.right - 2) * dpr).floor()) *
                  4,
            );
            image.dispose();
            return value;
          });
          if (value! <= 235) {
            await tester.runAsync(() async {
              final image = await outer.toImage(pixelRatio: dpr);
              await File(
                'build/poster-edge-fixes/failed-edge-$dpr.png',
              ).writeAsBytes(
                (await image.toByteData(
                  format: ui.ImageByteFormat.png,
                ))!.buffer.asUint8List(),
              );
              image.dispose();
            });
          }
          expect(
            value,
            greaterThan(235),
            reason: 'right edge, hovered=$hovered frame=$frame',
          );
        }
        expect(previousWidth, closeTo(baseWidth * (hovered ? 1.05 : 1), .01));
        if (hovered) {
          final jump = await tester.runAsync(() async {
            final image = await outer.toImage(pixelRatio: dpr);
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            final rect = tester.getRect(find.byKey(const ValueKey('poster-9')));
            final y = (rect.center.dy * dpr).floor();
            final inside = bytes.getUint8(
              (y * image.width + (viewport.right * dpr).floor() - 1) * 4,
            );
            final outside = bytes.getUint8(
              (y * image.width + (viewport.right * dpr).ceil() + 1) * 4,
            );
            image.dispose();
            return (inside - outside).abs();
          });
          expect(
            jump,
            lessThanOrEqualTo(3),
            reason: 'the last shadow must fade before the viewport clips',
          );
        }
      }
      expect(tester.takeException(), isNull);
    });
  }
}
