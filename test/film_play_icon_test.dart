import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';
import 'package:streampath/presentation/widgets/film_play_icon.dart';

void main() {
  testWidgets(
    'cover play mark has a filled triangle, transparent aperture and soft lower shadow',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final keys = [GlobalKey(), GlobalKey(), GlobalKey()];
      for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  for (var i = 0; i < 3; i++)
                    RepaintBoundary(
                      key: keys[i],
                      child: SizedBox.square(
                        dimension: 96,
                        child: CustomPaint(
                          painter: _CoverBackground(i),
                          child: const Center(child: FilmPlayIcon()),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();
        for (var i = 0; i < 3; i++) {
          final image = (await tester.runAsync(
            () =>
                (keys[i].currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: dpr),
          ))!;
          final bytes = (await tester.runAsync(
            () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
          ))!;
          int channel(double x, double y) => bytes.getUint8(
            ((y * dpr).floor() * image.width + (x * dpr).floor()) * 4,
          );
          // 中央三角填充为白色，圆环内部仍透出黑色封面。
          expect(channel(48, 48), greaterThanOrEqualTo(250));
          if (i == 0) {
            expect(channel(48, 32), lessThanOrEqualTo(2));
            expect(channel(33, 48), lessThanOrEqualTo(2));
            expect(channel(48, 26), greaterThan(230));
          }
          if (i == 1) {
            expect(channel(48, 32), greaterThanOrEqualTo(240));
            final lower = channel(48, 75);
            final upper = channel(48, 21);
            expect(lower, lessThan(upper));
            expect(lower, greaterThan(205));
            expect(channel(48, 79), greaterThanOrEqualTo(lower));
          }
          await tester.runAsync(() async {
            final png = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!;
            final file = File('build/cover-play-icon/mark-$i-dpr-$dpr.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(png.buffer.asUint8List());
          });
          image.dispose();
        }
      }
    },
  );

  testWidgets('painted play fade preserves grouped ring and shadow pixels', (
    tester,
  ) async {
    for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
      for (final background in [0, 1, 2]) {
        for (final alpha in [0.0, .25, .5, .875, 1.0]) {
          final samples = <List<int>>[];
          for (final groupedLayer in [true, false]) {
            final key = GlobalKey();
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  body: RepaintBoundary(
                    key: key,
                    child: SizedBox.square(
                      dimension: 96,
                      child: CustomPaint(
                        painter: _CoverBackground(background),
                        child: Center(
                          child: Transform.translate(
                            offset: const Offset(.25, .75),
                            child: groupedLayer
                                ? Opacity(
                                    opacity: alpha,
                                    child: const FilmPlayIcon(),
                                  )
                                : FilmPlayIcon(
                                    opacity: AlwaysStoppedAnimation(alpha),
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();
            samples.add(
              (await tester.runAsync(() async {
                final image =
                    await (key.currentContext!.findRenderObject()!
                            as RenderRepaintBoundary)
                        .toImage(pixelRatio: dpr);
                final data = (await image.toByteData(
                  format: ui.ImageByteFormat.rawRgba,
                ))!;
                final bytes = data.buffer.asUint8List().toList();
                image.dispose();
                return bytes;
              }))!,
            );
          }
          var maximumDifference = 0;
          for (var i = 0; i < samples.first.length; i++) {
            final difference = (samples.first[i] - samples.last[i]).abs();
            if (difference > maximumDifference) maximumDifference = difference;
          }
          expect(
            maximumDifference,
            lessThanOrEqualTo(1),
            reason:
                'Grouped fade differs: dpr=$dpr background=$background alpha=$alpha',
          );
        }
      }
    }
  });

  testWidgets(
    'cover hover fade reverses continuously and never captures playback clicks',
    (tester) async {
      var plays = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                FilmPosterHover(
                  child: GestureDetector(
                    onTap: () {
                      plays++;
                    },
                    child: const SizedBox(
                      width: 240,
                      height: 140,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: ColoredBox(color: Colors.teal),
                          ),
                          Center(child: FilmPosterHoverPlayIcon()),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(
                  width: 240,
                  height: 60,
                  child: Center(child: Text('Details')),
                ),
              ],
            ),
          ),
        ),
      );
      double opacity() => tester
          .widget<FilmPlayIcon>(
            find.descendant(
              of: find.byType(FilmPosterHoverPlayIcon),
              matching: find.byType(FilmPlayIcon),
            ),
          )
          .opacity!
          .value;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(500, 400));
      await tester.pump();
      expect(opacity(), 0);
      await mouse.moveTo(tester.getCenter(find.text('Details')));
      await tester.pump(AppTheme.hoverDuration);
      expect(opacity(), 0);
      final cover = find.byType(FilmPosterHover);
      await tester.tap(cover);
      expect(plays, 1);
      await mouse.moveTo(tester.getCenter(cover));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final entering = opacity();
      expect(entering, inExclusiveRange(0, 1));
      await mouse.moveTo(tester.getCenter(find.text('Details')));
      await tester.pump();
      expect(opacity(), closeTo(entering, .0001));
      await tester.pump(const Duration(milliseconds: 50));
      final exiting = opacity();
      expect(exiting, inExclusiveRange(0, entering));
      await mouse.moveTo(tester.getCenter(cover));
      await tester.pump();
      expect(opacity(), closeTo(exiting, .0001));
      await tester.pump(AppTheme.hoverDuration);
      expect(opacity(), 1);
      await tester.tapAt(tester.getCenter(find.byType(FilmPlayIcon)));
      expect(plays, 2);
      await mouse.moveTo(tester.getCenter(find.text('Details')));
      await tester.pumpAndSettle();
      expect(opacity(), 0);
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    },
  );
}

class _CoverBackground extends CustomPainter {
  const _CoverBackground(this.index);
  final int index;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(index == 0 ? Colors.black : Colors.white, BlendMode.src);
    if (index == 2) {
      for (var y = 0; y < size.height; y += 6) {
        for (var x = 0; x < size.width; x += 6) {
          canvas.drawRect(
            Rect.fromLTWH(x.toDouble(), y.toDouble(), 6, 6),
            Paint()..color = (x + y) % 12 == 0 ? Colors.teal : Colors.orange,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_CoverBackground oldDelegate) =>
      index != oldDelegate.index;
}
