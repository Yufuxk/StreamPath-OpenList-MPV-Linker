import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/adaptive_backdrop_layout.dart';
import 'package:streampath/presentation/widgets/adaptive_film_backdrop.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';

void main() {
  Future<(Directory, FilmCatalogImageCache, TmdbMetadataService)> fixture(
    WidgetTester tester, {
    String target = 'original',
    Size imageSize = const Size(1920, 1080),
    Color? plainColor,
  }) async {
    final result = (await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('adaptive_backdrop_');
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        Offset.zero & imageSize,
        Paint()..color = plainColor ?? Colors.teal,
      );
      if (plainColor == null) {
        canvas.drawRect(
          Rect.fromLTWH(0, 0, 200, imageSize.height),
          Paint()..color = Colors.blue,
        );
        canvas.drawRect(
          Rect.fromLTWH(imageSize.width - 200, 0, 200, imageSize.height),
          Paint()..color = Colors.red,
        );
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(
        imageSize.width.toInt(),
        imageSize.height.toInt(),
      );
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      final file = File(
        p.join(
          temp.path,
          '${FilmCatalogImageCache.cacheKey('/frame.png', target)}.img',
        ),
      );
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      final tmdb = TmdbMetadataService(credentials: _NoToken());
      final cache = FilmCatalogImageCache(temp, tmdb);
      await cache.cached('/frame.png', target);
      await cache.backdropBlurs.get(file);
      return (temp, cache, tmdb);
    }))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      result.$2.close();
      result.$3.close();
      await tester.runAsync(() async {
        await result.$2.backdropBlurs.clear();
        await result.$1.delete(recursive: true);
      });
    });
    return result;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('离线原图不可用时只复用已缓存背景', (tester) async {
    final (_, cache, _) = await fixture(
      tester,
      target: 'w780',
      imageSize: const Size(780, 439),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: AdaptiveFilmBackdrop(cache: cache, path: '/frame.png'),
      ),
    );
    await settle(tester);
    final sharp = tester.widget<RawImage>(
      find.byKey(const Key('adaptive-backdrop-sharp')),
    );
    expect(sharp.image!.width, 780);
    expect(sharp.fit, BoxFit.contain);
    expect(find.byType(ImageFiltered), findsNothing);
    expect(
      await tester.runAsync(() => cache.cached('/frame.png', 'original')),
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('影视库顶部在极亮极暗背景下保持主次文字可读性', (tester) async {
    const size = Size(1280, 720);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var minimum = double.infinity;
    for (final color in [Colors.white, Colors.black]) {
      for (final imageSize in [size * 1.5, size * .7]) {
        final (_, cache, _) = await fixture(
          tester,
          imageSize: imageSize,
          plainColor: color,
        );
        for (final dark in [true, false]) {
          final theme = dark ? AppTheme.dark() : AppTheme.light();
          final boundaryKey = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              key: ValueKey((cache, dark)),
              theme: theme,
              home: RepaintBoundary(
                key: boundaryKey,
                child: AdaptiveFilmBackdrop(
                  cache: cache,
                  path: '/frame.png',
                  style: FilmBackdropStyle.library,
                ),
              ),
            ),
          );
          await settle(tester);
          final pixels = (await tester.runAsync(() async {
            final boundary =
                boundaryKey.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            final image = await boundary.toImage();
            final data = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            image.dispose();
            return data!;
          }))!;
          // 标题栏与筛选条透明，直接检查整段顶部的主题主次前景色。
          for (var y = 0; y < 112; y += 4) {
            for (var x = 0; x < size.width; x += 4) {
              final offset = (y * size.width.toInt() + x) * 4;
              final background = Color.fromARGB(
                255,
                pixels.getUint8(offset),
                pixels.getUint8(offset + 1),
                pixels.getUint8(offset + 2),
              );
              for (final foreground in [
                theme.colorScheme.onSurface,
                theme.colorScheme.onSurfaceVariant,
              ]) {
                final a = foreground.computeLuminance(),
                    b = background.computeLuminance();
                final contrast = a > b
                    ? (a + .05) / (b + .05)
                    : (b + .05) / (a + .05);
                if (contrast < minimum) minimum = contrast;
                expect(
                  contrast,
                  greaterThanOrEqualTo(4.5),
                  reason:
                      'Library header: $color, $imageSize, dark=$dark, ($x,$y), $foreground, background=$background, base=${theme.scaffoldBackgroundColor}',
                );
              }
            }
          }
          expect(tester.takeException(), isNull);
        }
      }
    }
    await tester.runAsync(() async {
      await File(
        'build/adaptive-background/readability/library-header.json',
      ).writeAsString('{"scenes":8,"minimum":$minimum}');
    });
  });

  testWidgets('浅色背景的白色徽标保持原色并提供局部清晰轮廓', (tester) async {
    final (dir, cache, _) = await fixture(tester);
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(20, 8, 56, 16),
        Paint()..color = Colors.white,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(96, 32);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        p.join(
          dir.path,
          '${FilmCatalogImageCache.cacheKey('/logo.png', 'original')}.img',
        ),
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
      picture.dispose();
    });
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Center(
          child: RepaintBoundary(
            key: boundaryKey,
            child: ColoredBox(
              color: Colors.white,
              child: FilmArtwork(
                cache: cache,
                path: '/logo.png',
                target: 'original',
                transparent: true,
                width: 192,
                height: 64,
                borderRadius: 0,
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    final images = tester.widgetList<RawImage>(find.byType(RawImage)).toList();
    expect(images, hasLength(2));
    expect(identical(images[0].image, images[1].image), isTrue);
    final pixels = (await tester.runAsync(() async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data!;
    }))!;
    int red(int x, int y) => pixels.getUint8((y * 192 + x) * 4);
    expect(red(96, 32), 255);
    expect(red(30, 32), 255);
    expect(
      [
        for (var x = 36; x < 40; x++) red(x, 32),
      ].reduce((a, b) => a < b ? a : b),
      lessThan(140),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('窗口缩放后的切图保留上一帧的布局滞回模式', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (dir, cache, _) = await fixture(tester);
    final next = await tester.runAsync(() async {
      final next = await cache
          .knownFile('/frame.png', 'original')!
          .copy(p.join(dir.path, 'next.png'));
      await cache.backdropBlurs.get(next);
      return next;
    });
    final first = cache.knownFile('/frame.png', 'original')!;
    Widget frame(File file) => MaterialApp(
      home: AdaptiveFilmBackdrop(cache: cache, file: file),
    );
    await tester.pumpWidget(frame(first));
    await settle(tester);
    tester.view.physicalSize = const Size(1600, 600);
    await tester.pump();
    expect(
      tester
          .widget<RawImage>(find.byKey(const Key('adaptive-backdrop-sharp')))
          .fit,
      BoxFit.cover,
    );
    await tester.pumpWidget(frame(next!));
    for (
      var i = 0;
      find.byKey(const Key('adaptive-backdrop-sharp')).evaluate().length < 2 &&
          i < 60;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    final layers = tester
        .widgetList<RawImage>(find.byKey(const Key('adaptive-backdrop-sharp')))
        .toList();
    try {
      expect(layers, hasLength(2));
      expect(layers.first.fit, BoxFit.cover);
      expect(layers.last.fit, BoxFit.contain);
    } finally {
      await settle(tester);
    }
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(1280, 720),
    const Size(1600, 600),
    const Size(640, 1000),
  ]) {
    for (final dpr in [1.0, 2.0]) {
      testWidgets('自适应背景清晰度与羽化 $size DPR=$dpr', (tester) async {
        tester.view.physicalSize = size * dpr;
        tester.view.devicePixelRatio = dpr;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final (_, cache, _) = await fixture(tester);
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(
              key: boundaryKey,
              child: AdaptiveFilmBackdrop(cache: cache, path: '/frame.png'),
            ),
          ),
        );
        await settle(tester);
        final sharp = find.byKey(const Key('adaptive-backdrop-sharp'));
        final render = tester.renderObject<RenderImage>(sharp);
        final layout = AdaptiveBackdropLayout.calculate(
          image: const Size(1920, 1080),
          viewport: size,
          devicePixelRatio: dpr,
        );
        expect(render.image!.width, 1920);
        expect(render.image!.height, 1080);
        expect(render.scale, dpr);
        expect(find.byType(ImageFiltered), findsNothing);
        if (layout.mode == AdaptiveBackdropMode.cover) {
          expect(render.fit, BoxFit.cover);
          expect(find.byType(ShaderMask), findsNothing);
          expect(find.byType(Image), findsNothing);
        } else {
          expect(render.fit, BoxFit.contain);
          expect(find.byType(ShaderMask), findsOneWidget);
          expect(find.byType(Image), findsOneWidget);
          expect(
            render.size.width * dpr,
            lessThanOrEqualTo(1920 * 1.04 + .001),
          );
          expect(
            render.size.height * dpr,
            lessThanOrEqualTo(1080 * 1.04 + .001),
          );
          final pixels = (await tester.runAsync(() async {
            final boundary =
                boundaryKey.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            final image = await boundary.toImage();
            final data = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            image.dispose();
            return data!;
          }))!;
          int difference(Offset a, Offset b) {
            final first =
                (a.dy.floor() * size.width.toInt() + a.dx.floor()) * 4;
            final second =
                (b.dy.floor() * size.width.toInt() + b.dx.floor()) * 4;
            return List.generate(
              3,
              (c) => (pixels.getUint8(first + c) - pixels.getUint8(second + c))
                  .abs(),
            ).reduce((a, b) => a + b);
          }

          final rect = layout.foreground;
          if (rect.left > 4) {
            expect(
              difference(
                Offset(rect.left - 2, size.height / 2),
                Offset(rect.left + 2, size.height / 2),
              ),
              lessThan(32),
            );
          }
          if (rect.top > 4) {
            expect(
              difference(
                Offset(rect.center.dx, rect.top - 2),
                Offset(rect.center.dx, rect.top + 2),
              ),
              lessThan(32),
            );
          }
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'detail style adds a top-left radial shade without touching other styles',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final (_, cache, _) = await fixture(tester);
      Finder detailCorner() => find.byWidgetPredicate((widget) {
        if (widget is! DecoratedBox) return false;
        final decoration = widget.decoration;
        if (decoration is! BoxDecoration) return false;
        final gradient = decoration.gradient;
        return gradient is RadialGradient &&
            gradient.center == const Alignment(-.7, -.85);
      });
      Future<void> pump(FilmBackdropStyle style) async {
        await tester.pumpWidget(
          MaterialApp(
            home: AdaptiveFilmBackdrop(
              cache: cache,
              path: '/frame.png',
              style: style,
            ),
          ),
        );
        await settle(tester);
      }

      await pump(FilmBackdropStyle.detail);
      expect(detailCorner(), findsOneWidget);
      final radial =
          ((tester.widget<DecoratedBox>(detailCorner())).decoration
                      as BoxDecoration)
                  .gradient!
              as RadialGradient;
      expect(radial.radius, 1.35);
      expect(radial.stops, [0, .45, 1]);
      expect(radial.colors.last, Colors.transparent);
      for (final style in [
        FilmBackdropStyle.library,
        FilmBackdropStyle.showcase,
      ]) {
        await pump(style);
        expect(detailCorner(), findsNothing, reason: '$style');
      }
      expect(tester.takeException(), isNull);
    },
  );
}

class _NoToken extends TmdbCredentialStore {
  @override
  Future<String?> read() async => null;
}
