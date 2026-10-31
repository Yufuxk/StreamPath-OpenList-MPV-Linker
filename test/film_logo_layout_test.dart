import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';
import 'package:streampath/presentation/widgets/film_logo_layout.dart';

void main() {
  Uint8List pixels(
    int width,
    int height,
    List<Rect> ink, {
    Color color = Colors.black,
  }) {
    final argb = color.toARGB32();
    final data = Uint8List(width * height * 4);
    for (final rect in ink) {
      for (var y = rect.top.toInt(); y < rect.bottom; y++) {
        for (var x = rect.left.toInt(); x < rect.right; x++) {
          final offset = (y * width + x) * 4;
          data[offset] = (argb >> 16) & 0xFF;
          data[offset + 1] = (argb >> 8) & 0xFF;
          data[offset + 2] = argb & 0xFF;
          data[offset + 3] = (argb >> 24) & 0xFF;
        }
      }
    }
    return data;
  }

  Uint8List nestedPixels(Color outer, Color inner) {
    final data = pixels(140, 60, [
      const Rect.fromLTWH(10, 10, 100, 40),
    ], color: outer);
    final layer = pixels(140, 60, [
      const Rect.fromLTWH(12, 12, 96, 36),
    ], color: inner);
    for (var index = 3; index < layer.length; index += 4) {
      if (layer[index] == 0) continue;
      data[index - 3] = layer[index - 3];
      data[index - 2] = layer[index - 2];
      data[index - 1] = layer[index - 1];
      data[index] = layer[index];
    }
    return data;
  }

  test('only plain near-black clearlogos need a contrast outline', () {
    const ink = Rect.fromLTWH(10, 10, 100, 40);
    FilmLogoLayout analyze(Color color) =>
        FilmLogoLayout.analyze(pixels(140, 60, [ink], color: color), 140, 60)!;
    final black = analyze(Colors.black);
    expect(black.nearBlack, isTrue);
    expect(black.hasBrightEdge, isFalse);
    final navy = analyze(const Color(0xFF0A141E));
    expect(navy.nearBlack, isTrue);
    expect(navy.hasBrightEdge, isFalse);
    expect(analyze(Colors.red).nearBlack, isFalse);
    expect(analyze(const Color(0xFF808080)).nearBlack, isFalse);
    expect(analyze(Colors.white).nearBlack, isFalse);
  });

  test('near-black clearlogos with a built-in bright edge are left alone', () {
    final layout = FilmLogoLayout.analyze(
      nestedPixels(Colors.white, Colors.black),
      140,
      60,
    )!;
    expect(layout.nearBlack, isTrue);
    expect(layout.hasBrightEdge, isTrue);
  });

  test(
    'asymmetric padding and source resolution do not change glyph size or center',
    () {
      for (final source in [
        (400, 100, const Rect.fromLTWH(10, 20, 180, 40)),
        (800, 300, const Rect.fromLTWH(400, 160, 360, 80)),
      ]) {
        final layout = FilmLogoLayout.analyze(
          pixels(source.$1, source.$2, [source.$3]),
          source.$1,
          source.$2,
        )!;
        expect(layout.bounds, source.$3);
        final destination = layout.destination(const Size(420, 220), 64);
        expect(destination.center.dx, 210);
        expect(destination.height, 64);
        expect(destination.bottom, 220);
      }
    },
  );

  test('a missing glyph target still centers and fits the available slot', () {
    final layout = FilmLogoLayout.analyze(
      pixels(400, 100, [const Rect.fromLTWH(10, 20, 180, 40)]),
      400,
      100,
    )!;
    final destination = layout.destination(const Size(420, 220), null);
    expect(destination.center.dx, 210);
    expect(destination.bottom, 220);
    expect(destination.width, closeTo(420, .001));
    expect(destination.height, closeTo(420 * 40 / 180, .001));
  });

  test(
    'vertical lettering uses its width and remains inside the available slot',
    () {
      final ink = [
        for (var i = 0; i < 4; i++) Rect.fromLTWH(70, 10 + i * 44, 32, 32),
      ];
      final layout = FilmLogoLayout.analyze(pixels(240, 220, ink), 240, 220)!;
      final destination = layout.destination(const Size(420, 220), 40);
      expect(destination.width, 40);
      expect(destination.center.dx, 210);
      expect(destination.height, 205);
      expect(layout.destination(const Size(120, 90), 64).height, 90);
    },
  );

  test('a smaller subtitle line does not define the main lettering scale', () {
    final layout = FilmLogoLayout.analyze(
      pixels(300, 100, [
        const Rect.fromLTWH(20, 10, 220, 40),
        const Rect.fromLTWH(100, 65, 100, 8),
      ]),
      300,
      100,
    )!;
    expect(layout.glyphExtent, 40);
    expect(
      layout.destination(const Size(420, 220), 64).height,
      closeTo(100.8, .001),
    );
  });

  test('fully transparent artwork has no usable logo', () {
    expect(FilmLogoLayout.analyze(Uint8List(40 * 80 * 4), 40, 80), isNull);
  });

  test(
    'decorated horizontal logos retain a readable width at either resolution',
    () {
      for (final factor in [1, 2]) {
        final layout = FilmLogoLayout.analyze(
          pixels(540 * factor, 240 * factor, [
            Rect.fromLTWH(
              5.0 * factor,
              10.0 * factor,
              530.0 * factor,
              210.0 * factor,
            ),
          ]),
          540 * factor,
          240 * factor,
        )!;
        final destination = layout.destination(const Size(420, 220), 64);
        expect(destination.width, greaterThanOrEqualTo(280));
        expect(destination.width, lessThanOrEqualTo(420));
        expect(destination.center.dx, 210);
        expect(destination.bottom, 220);
        expect(
          destination.width / destination.height,
          closeTo(530 / 210, .001),
        );
        final narrow = layout.destination(const Size(120, 90), 64);
        expect(narrow.width, lessThanOrEqualTo(120));
        expect(narrow.height, lessThanOrEqualTo(90));
      }
    },
  );

  late Directory temp;
  late FilmCatalogImageCache cache;
  late TmdbMetadataService tmdb;
  final boundaryKey = GlobalKey();

  Future<void> prepare(WidgetTester tester) async {
    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('film_logo_layout_');
      tmdb = TmdbMetadataService(credentials: _NoToken());
      cache = FilmCatalogImageCache(temp, tmdb);
      Future<void> write(
        String path,
        int width,
        int height,
        List<(Rect, Color)> layers,
      ) async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        for (final (rect, color) in layers) {
          canvas.drawRect(rect, Paint()..color = color);
        }
        final picture = recorder.endRecording();
        final image = await picture.toImage(width, height);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '${temp.path}/${FilmCatalogImageCache.cacheKey(path, 'original')}.img',
        ).writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
        picture.dispose();
        await cache.cached(path, 'original');
      }

      for (final (path, width, height, ink, color)
          in <(String, int, int, List<Rect>, Color)>[
            (
              '/left.png',
              400,
              100,
              [const Rect.fromLTWH(10, 20, 180, 40)],
              Colors.red,
            ),
            (
              '/right.png',
              800,
              300,
              [const Rect.fromLTWH(400, 160, 360, 80)],
              Colors.red,
            ),
            (
              '/vertical.png',
              240,
              220,
              [
                for (var i = 0; i < 4; i++)
                  Rect.fromLTWH(70, 10 + i * 44, 32, 32),
              ],
              Colors.red,
            ),
            ('/empty.png', 100, 100, const <Rect>[], Colors.red),
            (
              '/ink-black.png',
              96,
              32,
              [const Rect.fromLTWH(20, 8, 56, 16)],
              Colors.black,
            ),
            (
              '/ink-white.png',
              96,
              32,
              [const Rect.fromLTWH(20, 8, 56, 16)],
              Colors.white,
            ),
          ]) {
        await write(path, width, height, [
          for (final rect in ink) (rect, color),
        ]);
      }
      // 黑色本体自带白色细描边的徽标。
      await write('/ink-outlined.png', 96, 32, [
        (const Rect.fromLTWH(20, 8, 56, 16), Colors.white),
        (const Rect.fromLTWH(22, 10, 52, 12), Colors.black),
      ]);
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      cache.close();
      tmdb.close();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await tester.runAsync(() => temp.delete(recursive: true));
    });
  }

  Widget frame(
    String path, {
    bool normalized = true,
    bool light = false,
    bool inkTint = false,
    double width = 420,
    double height = 220,
    FilmCatalogImageCache? imageCache,
  }) => MaterialApp(
    theme: ThemeData(brightness: light ? Brightness.light : Brightness.dark),
    home: Center(
      child: RepaintBoundary(
        key: boundaryKey,
        child: FilmArtwork(
          cache: imageCache ?? cache,
          path: path,
          target: 'original',
          transparent: true,
          logoGlyphSize: normalized ? 40 : null,
          logoInkTint: inkTint,
          width: width,
          height: height,
          borderRadius: 0,
          placeholder: const Text('fallback title'),
        ),
      ),
    ),
  );

  Finder paintedLogo() => find.descendant(
    of: find.byType(FilmArtwork),
    matching: find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter != null,
    ),
  );

  Future<void> settle(WidgetTester tester, {bool normalized = true}) async {
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      if (normalized
          ? paintedLogo().evaluate().isNotEmpty
          : tester
                .widgetList<RawImage>(find.byType(RawImage))
                .any((w) => w.image != null)) {
        return;
      }
    }
    fail('Logo did not become ready');
  }

  Future<Rect?> visibleInk(WidgetTester tester) async =>
      tester.runAsync<Rect?>(() async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        var left = image.width, top = image.height, right = -1, bottom = -1;
        for (var y = 0; y < image.height; y++) {
          for (var x = 0; x < image.width; x++) {
            final index = (y * image.width + x) * 4;
            if (data!.getUint8(index) > 150 &&
                data.getUint8(index + 1) < 80 &&
                data.getUint8(index + 3) > 150) {
              if (x < left) left = x;
              if (x > right) right = x;
              if (y < top) top = y;
              if (y > bottom) bottom = y;
            }
          }
        }
        image.dispose();
        return right < left
            ? null
            : Rect.fromLTRB(
                left.toDouble(),
                top.toDouble(),
                (right + 1).toDouble(),
                (bottom + 1).toDouble(),
              );
      });

  testWidgets(
    'original display reproduces drift; normalized horizontal and vertical ink is centered',
    (tester) async {
      await prepare(tester);
      await tester.pumpWidget(frame('/left.png', normalized: false));
      await settle(tester, normalized: false);
      expect((await visibleInk(tester))!.center.dx, lessThan(150));
      for (final path in ['/left.png', '/right.png', '/vertical.png']) {
        await tester.pumpWidget(frame(path));
        await settle(tester);
        final ink = (await visibleInk(tester))!;
        expect(ink.center.dx, closeTo(210, .5), reason: path);
        expect(
          path == '/vertical.png' ? ink.width : ink.height,
          closeTo(40, 1),
          reason: path,
        );
      }
    },
  );

  testWidgets(
    'cold and switched logos never paint before analysis; every visible frame has the final position',
    (tester) async {
      await prepare(tester);
      for (final path in ['/right.png', '/left.png', '/vertical.png']) {
        await tester.pumpWidget(frame(path));
        expect(paintedLogo(), findsNothing);
        expect(await visibleInk(tester), isNull);
        await settle(tester);
        final first = await visibleInk(tester);
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          expect(await visibleInk(tester), first);
        }
        expect(first!.center.dx, closeTo(210, .5));
      }
      await tester.pumpWidget(frame('/left.png'));
      expect(paintedLogo(), findsOneWidget);
      expect((await visibleInk(tester))!.center.dx, closeTo(210, .5));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'clearing cached artwork invalidates a previously measured layout',
    (tester) async {
      await prepare(tester);
      await tester.pumpWidget(frame('/left.png'));
      await settle(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        final replacement = await cache
            .knownFile('/right.png', 'original')!
            .readAsBytes();
        await cache.clear();
        await File(
          '${temp.path}/${FilmCatalogImageCache.cacheKey('/left.png', 'original')}.img',
        ).writeAsBytes(replacement);
        await cache.cached('/left.png', 'original');
        await filmArtworkProvider(
          cache.knownFile('/left.png', 'original')!,
          target: 'original',
        ).evict();
      });
      await tester.pumpWidget(frame('/left.png'));
      await settle(tester);
      final ink = (await visibleInk(tester))!;
      expect(ink.center.dx, closeTo(210, .5));
      expect(ink.height, closeTo(40, 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'file waits and obsolete file results never reveal a provisional logo or title',
    (tester) async {
      await prepare(tester);
      final requests = {
        '/left.png': Completer<File>(),
        '/right.png': Completer<File>(),
      };
      final gated = _GatedCache(temp, tmdb, requests);
      addTearDown(gated.close);
      await tester.pumpWidget(frame('/left.png', imageCache: gated));
      expect(find.text('fallback title'), findsNothing);
      expect(await visibleInk(tester), isNull);
      await tester.pumpWidget(frame('/right.png', imageCache: gated));
      requests['/left.png']!.complete(cache.knownFile('/left.png', 'original'));
      await tester.pump();
      expect(paintedLogo(), findsNothing);
      expect(find.text('fallback title'), findsNothing);
      requests['/right.png']!.complete(
        cache.knownFile('/right.png', 'original'),
      );
      await settle(tester);
      final ink = (await visibleInk(tester))!;
      expect(ink.center.dx, closeTo(210, .5));
      expect(ink.height, closeTo(40, 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'light outline shares the final geometry; narrow viewport scales uniformly',
    (tester) async {
      await prepare(tester);
      await tester.pumpWidget(
        frame('/right.png', light: true, width: 120, height: 70),
      );
      await settle(tester);
      expect(paintedLogo(), findsNWidgets(2));
      final ink = (await visibleInk(tester))!;
      expect(ink.center.dx, closeTo(60, .5));
      expect(ink.width, closeTo(120, 1));
      expect(ink.height, closeTo(120 / 4.5, 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty and failed artwork use the title; disposal during analysis is safe',
    (tester) async {
      await prepare(tester);
      for (final path in ['/empty.png', '/missing.png']) {
        await tester.pumpWidget(frame(path));
        for (
          var i = 0;
          i < 100 && find.text('fallback title').evaluate().isEmpty;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(find.text('fallback title'), findsOneWidget);
        expect(paintedLogo(), findsNothing);
      }
      await tester.pumpWidget(frame('/right.png'));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('detail renders only near-black clearlogos in white', (
    tester,
  ) async {
    await prepare(tester);
    Widget page(
      String path, {
      required bool light,
      required Color background,
    }) => MaterialApp(
      theme: ThemeData(brightness: light ? Brightness.light : Brightness.dark),
      themeAnimationDuration: Duration.zero,
      home: Center(
        child: RepaintBoundary(
          key: boundaryKey,
          child: ColoredBox(
            color: background,
            child: FilmArtwork(
              cache: cache,
              path: path,
              target: 'original',
              transparent: true,
              logoInkTint: true,
              width: 192,
              height: 64,
              borderRadius: 0,
            ),
          ),
        ),
      ),
    );
    bool filtered() => find.byType(ColorFiltered).evaluate().isNotEmpty;
    Future<bool> waitFor(bool Function() ready) async {
      for (var i = 0; i < 100; i++) {
        if (ready()) return true;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      return false;
    }

    Future<ByteData> capture() async => (await tester.runAsync(() async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data!;
    }))!;
    int red(ByteData data, int x, int y) => data.getUint8((y * 192 + x) * 4);

    await tester.pumpWidget(
      page('/ink-black.png', light: false, background: Colors.black),
    );
    expect(await waitFor(filtered), isTrue);
    final dark = await capture();
    await saveBoundaryPng(tester, boundaryKey, 'component-dark-ink-white');
    expect(
      red(dark, 96, 32),
      greaterThan(230),
      reason: 'near-black ink is rendered white on dark themes',
    );
    expect(find.byType(ImageFiltered), findsNothing);

    await tester.pumpWidget(
      page('/left.png', light: false, background: Colors.black),
    );
    expect(
      await waitFor(filtered),
      isFalse,
      reason: 'colored clearlogos keep their original look',
    );
    await saveBoundaryPng(tester, boundaryKey, 'component-red-ink-no-outline');

    await tester.pumpWidget(
      page('/ink-white.png', light: false, background: Colors.black),
    );
    expect(
      await waitFor(filtered),
      isFalse,
      reason: 'light ink on a dark backdrop needs no tint',
    );

    await tester.pumpWidget(
      page('/ink-outlined.png', light: false, background: Colors.black),
    );
    expect(
      await waitFor(filtered),
      isFalse,
      reason: 'near-black logos with a built-in bright edge keep their colors',
    );
    await saveBoundaryPng(
      tester,
      boundaryKey,
      'component-outlined-ink-no-tint',
    );

    await tester.pumpWidget(
      page('/ink-white.png', light: true, background: Colors.white),
    );
    expect(await waitFor(filtered), isTrue);
    final light = await capture();
    await saveBoundaryPng(tester, boundaryKey, 'component-light-ink-outline');
    expect(red(light, 96, 32), greaterThan(230), reason: 'ink stays white');
    expect(
      [
        for (var x = 34; x < 42; x++) red(light, x, 32),
      ].reduce((a, b) => a < b ? a : b),
      lessThan(140),
      reason: 'light ink keeps the original dark rim on light themes',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('near-black tint stays off for logos outside the detail page', (
    tester,
  ) async {
    await prepare(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Center(
          child: RepaintBoundary(
            key: boundaryKey,
            child: ColoredBox(
              color: Colors.black,
              child: FilmArtwork(
                cache: cache,
                path: '/ink-black.png',
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
    await settle(tester, normalized: false);
    await saveBoundaryPng(tester, boundaryKey, 'component-no-tint');
    expect(find.byType(ColorFiltered), findsNothing);
    expect(find.byType(ImageFiltered), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

/// 保存组件截图，供本次优化的明暗与墨色对照核对。
Future<void> saveBoundaryPng(
  WidgetTester tester,
  GlobalKey key,
  String name,
) async {
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('build/detail-shadow-logo')
      ..createSync(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
  });
}

class _NoToken extends TmdbCredentialStore {
  @override
  Future<String?> read() async => null;
}

class _GatedCache extends FilmCatalogImageCache {
  _GatedCache(super.directory, super.tmdb, this.requests);
  final Map<String, Completer<File>> requests;

  @override
  Future<File> get(String path, {String target = 'w342'}) =>
      requests[path]!.future;
}
