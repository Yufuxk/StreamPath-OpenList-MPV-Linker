import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';
import 'package:streampath/presentation/widgets/film_watch_overlay.dart';

import 'helpers/pump_until.dart';

void main() {
  for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
    testWidgets(
      'poster hover keeps static glyphs and blurred edges stable at $dpr DPR',
      (tester) async {
        tester.view.physicalSize = Size(800 * dpr, 600 * dpr);
        tester.view.devicePixelRatio = dpr;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = await tester.runAsync(() async {
          final bytes = await File(
            'C:/Windows/Fonts/segoeui.ttf',
          ).readAsBytes();
          await (FontLoader(
            'CardHoverText',
          )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawRect(
            const Rect.fromLTWH(0, 0, 32, 32),
            Paint()..color = Colors.white,
          );
          final picture = recorder.endRecording();
          final image = await picture.toImage(32, 32);
          picture.dispose();
          final temp = await Directory.systemTemp.createTemp(
            'film_card_sampling_',
          );
          final store = await FilmCatalogStore.open('${temp.path}/catalog.db');
          await store.setPreference('spoiler_protection', true);
          return (temp, store, image);
        });
        final (temp, store, white) = fixture!;
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          white.dispose();
          await tester.runAsync(() async {
            await store.close();
            await temp.delete(recursive: true);
          });
        });
        final boundary = GlobalKey();
        const coverKey = Key('sampling-cover'), textKey = Key('sampling-text');
        final card = Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.none,
          child: Column(
            children: [
              FilmPosterHoverSurface(
                blurred: true,
                borderRadius: BorderRadius.zero,
                child: SizedBox(
                  key: coverKey,
                  height: 160.5,
                  width: double.infinity,
                  child: FilmWatchOverlay(
                    store: store,
                    showStatus: false,
                    canReveal: false,
                    spoilerSensitive: true,
                    child: ClipRRect(
                      borderRadius: BorderRadius.zero,
                      clipBehavior: Clip.hardEdge,
                      child: RawImage(
                        image: white,
                        width: double.infinity,
                        height: double.infinity,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
              ),
              const Text(
                'StreamPath 2026',
                key: textKey,
                style: TextStyle(
                  fontFamily: 'CardHoverText',
                  fontSize: 14,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        );
        Future<void> frame(bool hovered) => tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark(),
            home: Center(
              child: RepaintBoundary(
                key: boundary,
                child: SizedBox(
                  width: 380,
                  height: 300,
                  child: ColoredBox(
                    color: Colors.black,
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 30.3, top: 30.7),
                        child: SizedBox(
                          width: 300.5,
                          height: 220.5,
                          child: FilmPosterHover(hovered: hovered, child: card),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await frame(false);
        await pumpUntil(
          tester,
          () => find.byType(ImageFiltered).evaluate().isNotEmpty,
          reason:
              'The spoiler watch state must load before sampling hover frames',
        );
        await tester.pumpAndSettle();
        final edgeErrors = <double>[];
        List<double>? referenceEdge;
        final glyphCenters = <double>[];
        final textRect = tester.getRect(find.byKey(textKey));
        // 从海报变换外采样，覆盖滤镜真正显示到视口时的边缘。
        for (final hovered in [true, false]) {
          await frame(hovered);
          for (var i = 0; i < 14; i++) {
            await tester.pump(const Duration(milliseconds: 16));
            final outer =
                boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            final origin = tester.getTopLeft(find.byKey(boundary));
            final cover = tester.getRect(find.byKey(coverKey)).shift(-origin);

            final pixels = await tester.runAsync(() async {
              final image = await outer.toImage(pixelRatio: dpr);
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              );
              final width = image.width;
              image.dispose();
              return (bytes!, width);
            });
            final scale =
                cover.width / tester.getSize(find.byKey(coverKey)).width;
            List<double> edgeProfile(double pixelShift) => [
              for (var inset = 3; inset <= 32; inset++)
                [
                      for (final fraction in [.4, .5, .6])
                        _redAt(
                          pixels!.$1,
                          pixels.$2,
                          (cover.right - inset * scale) * dpr + pixelShift,
                          (cover.top + cover.height * fraction) * dpr,
                        ),
                    ].reduce((a, b) => a + b) /
                    3,
            ];
            referenceEdge ??= edgeProfile(0);
            // 比较同一图像位置的边缘轮廓，允许设备像素取整带来的一像素相位差。
            final error = [
              for (final shift in [-1.0, -.5, 0.0, .5, 1.0])
                [
                  for (final pair in edgeProfile(shift).indexed)
                    (pair.$2 - referenceEdge[pair.$1]).abs(),
                ].reduce((a, b) => a > b ? a : b),
            ].reduce((a, b) => a < b ? a : b);
            edgeErrors.add(error);
            final paragraph = tester.renderObject<RenderParagraph>(
              find.byKey(textKey),
            );
            final glyph = paragraph
                .getBoxesForSelection(
                  const TextSelection(baseOffset: 6, extentOffset: 7),
                )
                .single
                .toRect();
            final box = MatrixUtils.transformRect(
              paragraph.getTransformTo(outer),
              glyph,
            );
            var weight = 0.0, position = 0.0;
            for (
              var y = (box.top * dpr).ceil();
              y < (box.bottom * dpr).floor();
              y++
            ) {
              for (
                var x = (box.left * dpr).ceil();
                x < (box.right * dpr).floor();
                x++
              ) {
                final value = pixels!.$1.getUint8((y * pixels.$2 + x) * 4);
                final signal = (value - 18).clamp(0, 255).toDouble();
                position += signal * ((x + .5) / dpr - box.left);
                weight += signal;
              }
            }
            glyphCenters.add(position / weight);
            expect(tester.getRect(find.byKey(textKey)), textRect);
            expect(
              tester.widget<RawImage>(find.byType(RawImage)).image,
              same(white),
            );
          }
        }
        edgeErrors.sort();
        glyphCenters.sort();
        expect(edgeErrors.last, lessThanOrEqualTo(12));
        expect(glyphCenters.last - glyphCenters.first, lessThan(.12));
        expect(tester.takeException(), isNull);
      },
      skip: !Platform.isWindows,
    );
  }
}

// 在物理像素中心插值，保持分数 DPR 下的采样位置一致。
double _redAt(ByteData bytes, int width, double x, double y) {
  x -= .5;
  y -= .5;
  final left = x.floor(), top = y.floor();
  final horizontal = x - left, vertical = y - top;
  double row(int line) {
    final offset = (line * width + left) * 4;
    final first = bytes.getUint8(offset);
    return first + (bytes.getUint8(offset + 4) - first) * horizontal;
  }

  return row(top) * (1 - vertical) + row(top + 1) * vertical;
}
