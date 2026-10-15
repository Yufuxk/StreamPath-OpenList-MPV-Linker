import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';
import 'package:streampath/presentation/widgets/film_watch_overlay.dart';

void main() {
  for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
    testWidgets('poster preserves source detail during hover at $dpr DPR', (
      tester,
    ) async {
      tester.view.physicalSize = Size(400 * dpr, 400 * dpr);
      tester.view.devicePixelRatio = dpr;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final image = (await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawColor(Colors.white, BlendMode.src);
        final paint = Paint()..color = const Color(0xFF164E81);
        for (var x = -513; x < 342; x += 8) {
          canvas.drawLine(
            Offset(x.toDouble(), 0),
            Offset(x + 513.0, 513),
            paint..strokeWidth = 3,
          );
        }
        final picture = recorder.endRecording();
        final result = await picture.toImage(342, 513);
        picture.dispose();
        return result;
      }))!;
      addTearDown(image.dispose);
      final boundary = GlobalKey();
      const size = Size(166.5, 249.75);
      const origin = Offset(70.25, 60.75);

      Future<ByteData> capture({
        required bool reference,
        required bool hovered,
        bool watchOverlay = false,
      }) async {
        final poster = SizedBox.fromSize(
          size: size,
          child: RawImage(image: image, fit: BoxFit.cover),
        );
        final scale = hovered ? AppTheme.posterHoverScale : 1.0;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark(),
            home: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                key: boundary,
                child: SizedBox(
                  width: 320,
                  height: 370,
                  child: ColoredBox(
                    color: Colors.black,
                    child: Stack(
                      children: [
                        Positioned(
                          left: origin.dx,
                          top: origin.dy,
                          child: reference
                              ? Transform(
                                  alignment: Alignment.center,
                                  transform:
                                      Matrix4.diagonal3Values(
                                        scale,
                                        scale,
                                        1,
                                      )..setEntry(
                                        1,
                                        3,
                                        hovered ? -AppTheme.posterHoverLift : 0,
                                      ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: poster,
                                  ),
                                )
                              : FilmPosterHover(
                                  key: ValueKey(hovered),
                                  hovered: hovered,
                                  child: watchOverlay
                                      ? FilmWatchOverlay(
                                          hoverSurface: true,
                                          showStatus: false,
                                          child: poster,
                                        )
                                      : FilmPosterHoverSurface(child: poster),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        return (await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final snapshot = await render.toImage(pixelRatio: dpr);
          final pixels = await snapshot.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          snapshot.dispose();
          return pixels!;
        }))!;
      }

      for (final state in [
        (false, false),
        (true, false),
        (false, true),
        (true, true),
      ]) {
        final (hovered, watchOverlay) = state;
        final reference = await capture(reference: true, hovered: hovered);
        final actual = await capture(
          reference: false,
          hovered: hovered,
          watchOverlay: watchOverlay,
        );
        final width = (320 * dpr).ceil();
        final region = (origin & size).deflate(16);
        var error = 0.0, samples = 0;
        // 内部细节应与同一原图直接绘制到目标尺寸一致，排除阴影和描边。
        for (
          var y = (region.top * dpr).ceil();
          y < (region.bottom * dpr).floor();
          y++
        ) {
          for (
            var x = (region.left * dpr).ceil();
            x < (region.right * dpr).floor();
            x++
          ) {
            final at = (y * width + x) * 4;
            for (var channel = 0; channel < 3; channel++) {
              error +=
                  (actual.getUint8(at + channel) -
                          reference.getUint8(at + channel))
                      .abs();
              samples++;
            }
          }
        }
        expect(
          error / samples,
          lessThan(1),
          reason: 'Source detail must survive poster scaling, hovered=$hovered',
        );
        expect(
          tester.widget<RawImage>(find.byType(RawImage)).image,
          same(image),
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}
