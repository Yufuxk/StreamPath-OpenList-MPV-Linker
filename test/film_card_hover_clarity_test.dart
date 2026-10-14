import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';

void main() {
  for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
    for (final hovered in [false, true]) {
      testWidgets(
        'card text detail at $dpr DPR, hovered=$hovered',
        (tester) async {
          tester.view.physicalSize = Size(1400 * dpr, 600 * dpr);
          tester.view.devicePixelRatio = dpr;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.runAsync(() async {
            for (final font in [
              ('HoverLatin', 'segoeui.ttf'),
              ('HoverCjk', 'msyh.ttc'),
            ]) {
              final bytes = await File(
                'C:/Windows/Fonts/${font.$2}',
              ).readAsBytes();
              await (FontLoader(
                font.$1,
              )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
            }
          });
          final boundary = GlobalKey();
          final captions = [GlobalKey(), GlobalKey(), GlobalKey()];
          Widget card(int index) => ColoredBox(
            color: const Color(0xFF14161E),
            child: Center(
              child: Column(
                key: captions[index],
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Text(
                    '《进击的巨人》Q版剧场',
                    style: TextStyle(
                      fontFamily: 'HoverCjk',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  Text(
                    'Season 2 · Episode 4 · 47–49',
                    style: TextStyle(
                      fontFamily: 'HoverLatin',
                      fontSize: 13,
                      color: Colors.white54,
                    ),
                  ),
                ],
              ),
            ),
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.dark(),
              home: Align(
                alignment: Alignment.topLeft,
                child: RepaintBoundary(
                  key: boundary,
                  child: SizedBox(
                    width: 1180,
                    height: 180,
                    child: Stack(
                      children: [
                        for (var i = 0; i < 3; i++)
                          Positioned(
                            left: 30.3 + i * 400,
                            top: 30.7,
                            child: SizedBox(
                              width: 300.5,
                              height: 100.5,
                              child: i == 1
                                  ? FilmPosterHover(
                                      hovered: hovered,
                                      child: card(i),
                                    )
                                  : i == 0
                                  ? Transform(
                                      alignment: Alignment.center,
                                      transform: Matrix4.diagonal3Values(
                                        (hovered ? 1.03 : 1) /
                                            (i == 0 ? 1.03 : 1),
                                        (hovered ? 1.03 : 1) /
                                            (i == 0 ? 1.03 : 1),
                                        1,
                                      )..setEntry(1, 3, hovered ? -4 : 0),
                                      filterQuality: i == 0
                                          ? FilterQuality.high
                                          : null,
                                      child: i == 0
                                          ? Transform.scale(
                                              scale: 1.03,
                                              child: card(i),
                                            )
                                          : card(i),
                                    )
                                  : card(i),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final outer =
              boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final text =
              captions[2].currentContext!.findRenderObject() as RenderBox;
          final rect = MatrixUtils.transformRect(
            text.getTransformTo(outer),
            Offset.zero & text.size,
          );
          final errors = await tester.runAsync(() async {
            final image = await outer.toImage(pixelRatio: dpr);
            final pixels = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            final result = <double>[];
            for (var i = 0; i < 2; i++) {
              var error = 0.0, count = 0, gradient = 0.0, energy = 0.0;
              for (
                var y = (rect.top * dpr).ceil();
                y < (rect.bottom * dpr).floor();
                y++
              ) {
                for (
                  var x = (rect.left * dpr).ceil();
                  x < (rect.right * dpr).floor();
                  x++
                ) {
                  final ref = pixels.getUint8((y * image.width + x) * 4);
                  final actual = pixels.getUint8(
                    (y * image.width + x - ((2 - i) * 400 * dpr).round()) * 4,
                  );
                  error += (actual - ref).abs();
                  count++;
                  final at =
                      (y * image.width + x - ((2 - i) * 400 * dpr).round()) * 4;
                  if (x > (rect.left * dpr).ceil() &&
                      y > (rect.top * dpr).ceil()) {
                    energy += (actual - 20).clamp(0, 255);
                    gradient +=
                        (actual - pixels.getUint8(at - 4)).abs() +
                        (actual - pixels.getUint8(at - image.width * 4)).abs();
                  }
                }
              }
              result.add(error / count);
              result.add(gradient / energy);
            }
            image.dispose();
            return result;
          });
          // 标题直接绘制，在两种海报状态下均与静止参考逐像素一致。
          expect(errors![2], closeTo(0, .01));
          expect(tester.takeException(), isNull);
        },
        skip: !Platform.isWindows,
      );
    }
  }
}
