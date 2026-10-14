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
        await tester.pumpAndSettle();
        final edgeValues = <int>[];
        final glyphCenters = <double>[];
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
            var edge = 255;
            for (var y = cover.top + 40; y < cover.bottom - 20; y += 4) {
              final x = ((cover.right - 3) * dpr).floor();
              final value = pixels!.$1.getUint8(
                ((y * dpr).floor() * pixels.$2 + x) * 4,
              );
              if (value < edge) edge = value;
            }
            edgeValues.add(edge);
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
            expect(
              tester.widget<RawImage>(find.byType(RawImage)).image,
              same(white),
            );
          }
        }
        edgeValues.sort();
        glyphCenters.sort();
        expect(edgeValues.last - edgeValues.first, lessThanOrEqualTo(12));
        expect(glyphCenters.last - glyphCenters.first, lessThan(.12));
        expect(tester.takeException(), isNull);
      },
      skip: !Platform.isWindows,
    );
  }
}
