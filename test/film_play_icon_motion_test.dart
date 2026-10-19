import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';
import 'package:streampath/presentation/widgets/film_play_icon.dart';

void main() {
  testWidgets(
    'edge episode play mark keeps fractional motion in the cover display list',
    (tester) async {
      final evidence = <Map<String, Object>>[];
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
        tester.view.physicalSize = Size(660 * dpr, 400 * dpr);
        tester.view.devicePixelRatio = dpr;
        for (final left in [4.25, 346.25]) {
          final boundary = GlobalKey();
          final mark = GlobalKey();
          Future<void> frame(bool hovered) => tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                backgroundColor: Colors.black,
                body: RepaintBoundary(
                  key: boundary,
                  child: ClipRect(
                    child: Stack(
                      children: [
                        Positioned(
                          left: left,
                          top: 54.75,
                          width: 309.5,
                          height: 174.09375,
                          child: FilmPosterHover(
                            hovered: hovered,
                            child: FilmPosterHoverSurface(
                              showBorder: false,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  const ColoredBox(color: Colors.black),
                                  Center(
                                    child: FilmPosterHoverPlayIcon(key: mark),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const Positioned(
                          left: 24,
                          top: 300,
                          child: Text('Static episode details'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await frame(false);
          final labelRect = tester.getRect(find.text('Static episode details'));
          for (final hovered in [true, false, true, false]) {
            await frame(hovered);
            for (var step = 0; step < 10; step++) {
              await tester.pump(const Duration(milliseconds: 20));
              final fade = tester
                  .widget<FilmPlayIcon>(
                    find.descendant(
                      of: find.byType(FilmPosterHoverPlayIcon),
                      matching: find.byType(FilmPlayIcon),
                    ),
                  )
                  .opacity!
                  .value;
              final rect = tester.getRect(find.byKey(mark));
              expect(rect.center.dx, closeTo(left + 309.5 / 2, .0001));
              final transform = tester.renderObject<RenderTransform>(
                find.byWidgetPredicate(
                  (widget) => widget is Transform && !widget.transformHitTests,
                ),
              );
              final row = <String, Object>{
                'dpr': dpr,
                'left': left,
                'enter': hovered,
                'step': step,
                'opacity': fade,
                'centerX': rect.center.dx,
                'composited': transform.needsCompositing,
              };
              if (fade >= .25) {
                final image = (await tester.runAsync(
                  () =>
                      (boundary.currentContext!.findRenderObject()!
                              as RenderRepaintBoundary)
                          .toImage(pixelRatio: dpr),
                ))!;
                final data = (await tester.runAsync(
                  () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
                ))!;
                final scale = rect.width / 48;
                var weightedX = 0.0, weight = 0.0;
                final upper = ((rect.center.dy - 18 * scale) * dpr).floor();
                for (var y = upper; y < upper + (2 * dpr).ceil(); y++) {
                  for (
                    var x = ((rect.center.dx - 25 * scale) * dpr).floor();
                    x <= ((rect.center.dx + 25 * scale) * dpr).ceil();
                    x++
                  ) {
                    final value = data.getUint8((y * image.width + x) * 4);
                    weightedX += (x + .5) * value;
                    weight += value;
                  }
                }
                row['pixelCenterX'] = weightedX / weight / dpr;
                row['error'] = weightedX / weight / dpr - rect.center.dx;
                image.dispose();
              }
              evidence.add(row);
              expect(
                tester.getRect(find.text('Static episode details')),
                labelRect,
              );
            }
          }
        }
      }
      await tester.runAsync(() async {
        final file = File('build/play-icon-motion/motion-samples.json');
        await file.parent.create(recursive: true);
        await file.writeAsString(jsonEncode(evidence));
      });
      final composited = evidence
          .where((row) => row['composited'] == true)
          .toList();
      expect(
        composited,
        isEmpty,
        reason:
            'Clear cover movement must keep the fading play mark in the same display list',
      );
      final maximumError = evidence
          .where((row) => row.containsKey('error'))
          .map((row) => (row['error'] as double).abs())
          .reduce((a, b) => a > b ? a : b);
      expect(maximumError, lessThan(.15));
    },
  );
}
