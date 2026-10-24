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
  Uint8List pixels(int width, int height, List<Rect> ink) {
    final data = Uint8List(width * height * 4);
    for (final rect in ink) {
      for (var y = rect.top.toInt(); y < rect.bottom; y++) {
        for (var x = rect.left.toInt(); x < rect.right; x++) {
          data[(y * width + x) * 4 + 3] = 255;
        }
      }
    }
    return data;
  }

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
      for (final (path, width, height, ink) in [
        ('/left.png', 400, 100, [const Rect.fromLTWH(10, 20, 180, 40)]),
        ('/right.png', 800, 300, [const Rect.fromLTWH(400, 160, 360, 80)]),
        (
          '/vertical.png',
          240,
          220,
          [for (var i = 0; i < 4; i++) Rect.fromLTWH(70, 10 + i * 44, 32, 32)],
        ),
        ('/empty.png', 100, 100, <Rect>[]),
      ]) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        for (final rect in ink) {
          canvas.drawRect(rect, Paint()..color = Colors.red);
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
