import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/data/models/film_image_reference.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';

void main() {
  testWidgets('Late file completion cannot replace the current poster', (
    tester,
  ) async {
    final fixture = (await tester.runAsync(() async {
      final first = Completer<Uint8List>(), second = Completer<Uint8List>();
      final temp = await Directory.systemTemp.createTemp('poster_pending_');
      final tmdb = TmdbMetadataService(credentials: _NoToken());
      final cache = FilmCatalogImageCache(
        temp,
        tmdb,
        readReference: (reference, _) =>
            reference.path == 'first.png' ? first.future : second.future,
      );
      return (
        temp,
        tmdb,
        cache,
        await File('assets/tmdb_logo.png').readAsBytes(),
        first,
        second,
        (
          cache.get(
            FilmImageReference('file', 'test-source', 'first.png').encode(),
          ),
          cache.get(
            FilmImageReference('file', 'test-source', 'second.png').encode(),
          ),
        ),
      );
    }))!;
    final (temp, tmdb, cache, bytes, first, second, requests) = fixture;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      cache.close();
      tmdb.close();
      PaintingBinding.instance.imageCache.clear();
      await tester.runAsync(() => temp.delete(recursive: true));
    });
    Widget cover(String path) => MaterialApp(
      home: Center(
        child: FilmArtwork(
          cache: cache,
          path: FilmImageReference('file', 'test-source', path).encode(),
          showCachedImmediately: true,
          width: 100,
          height: 150,
        ),
      ),
    );
    Future<void> drain() async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    }

    await tester.pumpWidget(cover('first.png'));
    await drain();
    await tester.pumpWidget(cover('second.png'));
    await drain();
    await tester.runAsync(() async => first.complete(bytes));
    await tester.runAsync(() => requests.$1);
    for (var i = 0; i < 5; i++) {
      await drain();
    }
    expect(find.byType(RawImage), findsNothing);
    await tester.runAsync(() async => second.complete(bytes));
    await tester.runAsync(() => requests.$2);
    for (var i = 0; i < 20; i++) {
      await drain();
      if (tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((image) => image.image != null)) {
        break;
      }
    }
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    final layer = find.descendant(
      of: find.byType(FilmArtwork),
      matching: find.byType(Opacity),
    );
    expect(tester.widget<Opacity>(layer).opacity, 0);
    await tester.pump(const Duration(milliseconds: 70));
    final progress = tester.widget<Opacity>(layer).opacity;
    await tester.pumpWidget(cover('second.png'));
    expect(tester.widget<Opacity>(layer).opacity, progress);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<Opacity>(layer).opacity, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Synchronous cover does not schedule fade frames', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => filmPosterFrameBuilder(
            context,
            const SizedBox(width: 100, height: 150),
            0,
            true,
          ),
        ),
      ),
    );
    for (final layer in tester.widgetList<Opacity>(find.byType(Opacity))) {
      expect(layer.opacity, 1);
    }
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pump(const Duration(milliseconds: 70));
    expect(tester.binding.transientCallbackCount, 0);
  });
  for (final dpr in [1.0, 1.5, 2.0]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'Hot-cache first frame matches settled pixels DPR=$dpr $brightness',
        (tester) async {
          tester.view.devicePixelRatio = dpr;
          tester.view.physicalSize = const Size(800, 600) * dpr;
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          final fixture = (await tester.runAsync(() async {
            final temp = await Directory.systemTemp.createTemp(
              'poster_pixels_',
            );
            final recorder = ui.PictureRecorder();
            final canvas = Canvas(recorder);
            canvas.drawColor(Colors.teal, BlendMode.src);
            canvas.drawRect(
              const Rect.fromLTWH(0, 0, 171, 513),
              Paint()..color = Colors.orange,
            );
            final picture = recorder.endRecording();
            final image = await picture.toImage(342, 513);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            image.dispose();
            picture.dispose();
            final tmdb = TmdbMetadataService(credentials: _NoToken());
            final cache = FilmCatalogImageCache(temp, tmdb);
            await File(
              p.join(
                temp.path,
                '${FilmCatalogImageCache.cacheKey('/pixels.png', 'w342')}.img',
              ),
            ).writeAsBytes(bytes!.buffer.asUint8List());
            await cache.cached('/pixels.png', 'w342');
            return (temp, tmdb, cache);
          }))!;
          final (temp, tmdb, cache) = fixture;
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            cache.close();
            tmdb.close();
            PaintingBinding.instance.imageCache.clear();
            await tester.runAsync(() => temp.delete(recursive: true));
          });
          await tester.pumpWidget(const MaterialApp(home: Scaffold()));
          await tester.runAsync(
            () => precacheImage(
              filmArtworkProvider(cache.knownFile('/pixels.png', 'w342')!),
              tester.element(find.byType(Scaffold)),
            ),
          );
          final boundaryKey = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              key: ValueKey((cache, brightness)),
              theme: ThemeData(brightness: brightness),
              home: Center(
                child: RepaintBoundary(
                  key: boundaryKey,
                  child: FilmArtwork(
                    showCachedImmediately: true,
                    cache: cache,
                    path: '/pixels.png',
                    width: 174,
                    height: 261,
                  ),
                ),
              ),
            ),
          );
          Future<List<int>> pixels(String stage) async =>
              (await tester.runAsync(() async {
                final boundary =
                    boundaryKey.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary;
                final image = await boundary.toImage(pixelRatio: dpr);
                try {
                  final label =
                      Platform.environment['POSTER_TEST_LABEL'] ?? 'candidate';
                  final directory = await Directory(
                    'build/poster-scroll-round2-20261014/pixels',
                  ).create(recursive: true);
                  final png = await image.toByteData(
                    format: ui.ImageByteFormat.png,
                  );
                  await File(
                    p.join(
                      directory.path,
                      '$label-${brightness.name}-$dpr-$stage.png',
                    ),
                  ).writeAsBytes(png!.buffer.asUint8List());
                  final bytes = await image.toByteData(
                    format: ui.ImageByteFormat.rawRgba,
                  );
                  return bytes!.buffer.asUint8List().toList();
                } finally {
                  image.dispose();
                }
              }))!;
          final first = await pixels('first');
          await tester.pump(const Duration(milliseconds: 300));
          final settled = await pixels('settled');
          expect(listEquals(first, settled), isTrue);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final cached in [false, true]) {
    testWidgets(
      'Synchronous hits display immediately; async decoding retains fade and identity cached=$cached',
      (tester) async {
        final fixture = await tester.runAsync(() async {
          final temp = await Directory.systemTemp.createTemp(
            'film_cover_fade_',
          );
          final tmdb = TmdbMetadataService(credentials: _NoToken());
          final cache = FilmCatalogImageCache(temp, tmdb);
          final bytes = await File('assets/tmdb_logo.png').readAsBytes();
          for (final path in ['/first.png', '/second.png']) {
            await File(
              p.join(
                temp.path,
                '${FilmCatalogImageCache.cacheKey(path, 'w342')}.img',
              ),
            ).writeAsBytes(bytes);
            await cache.cached(path, 'w342');
          }
          return (temp, tmdb, cache);
        });
        final (temp, tmdb, cache) = fixture!;
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          cache.close();
          tmdb.close();
          PaintingBinding.instance.imageCache.clear();
          await tester.runAsync(() => temp.delete(recursive: true));
        });
        await tester.pumpWidget(const MaterialApp(home: Scaffold()));
        if (cached) {
          await tester.runAsync(
            () => precacheImage(
              filmArtworkProvider(cache.knownFile('/first.png', 'w342')!),
              tester.element(find.byType(Scaffold)),
            ),
          );
        }
        Widget frame(String path) => MaterialApp(
          home: Center(
            child: FilmArtwork(
              showCachedImmediately: true,
              cache: cache,
              path: path,
              width: 100,
              height: 150,
            ),
          ),
        );
        final opacityLayer = find.descendant(
          of: find.byType(FilmArtwork),
          matching: find.byType(Opacity),
        );
        double opacity() => opacityLayer.evaluate().isEmpty
            ? 1
            : tester.widget<Opacity>(opacityLayer).opacity;
        Future<void> decode() async {
          for (var i = 0; i < 20; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
            final images = tester.widgetList<RawImage>(find.byType(RawImage));
            if (images.any((image) => image.image != null)) return;
          }
          fail('Cover did not decode');
        }

        await tester.pumpWidget(frame('/first.png'));
        if (cached) {
          expect(opacity(), 1);
          expect(
            tester.widget<RawImage>(find.byType(RawImage)).image,
            isNotNull,
          );
        }
        await decode();
        expect(opacity(), cached ? 1 : 0);
        await tester.pump(const Duration(milliseconds: 70));
        expect(opacity(), cached ? 1 : allOf(greaterThan(0), lessThan(1)));
        await tester.pump(const Duration(milliseconds: 300));
        expect(opacity(), 1);
        await tester.pumpWidget(frame('/first.png'));
        expect(opacity(), 1);
        await tester.pumpWidget(frame('/second.png'));
        expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNull);
        await decode();
        expect(opacity(), 0);
        await tester.pump(const Duration(milliseconds: 300));
        expect(opacity(), 1);
        final second = tester
            .widget<RawImage>(find.byType(RawImage))
            .image!
            .clone();
        addTearDown(second.dispose);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(frame('/second.png'));
        expect(opacity(), 1);
        expect(
          tester
              .widget<RawImage>(find.byType(RawImage))
              .image!
              .isCloneOf(second),
          isTrue,
        );
        await tester.pumpWidget(frame('/first.png'));
        expect(opacity(), 1);
        expect(
          tester
              .widget<RawImage>(find.byType(RawImage))
              .image!
              .isCloneOf(second),
          isFalse,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('Failed poster keeps retry and never displays previous cover', (
    tester,
  ) async {
    final fixture = (await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('poster_error_');
      final tmdb = TmdbMetadataService(credentials: _NoToken());
      final cache = FilmCatalogImageCache(temp, tmdb);
      for (final path in ['/good.png', '/bad.png']) {
        await File(
          p.join(
            temp.path,
            '${FilmCatalogImageCache.cacheKey(path, 'w342')}.img',
          ),
        ).writeAsBytes(
          path == '/good.png'
              ? await File('assets/tmdb_logo.png').readAsBytes()
              : [0, 1, 2, 3],
        );
        await cache.cached(path, 'w342');
      }
      return (temp, tmdb, cache);
    }))!;
    final (temp, tmdb, cache) = fixture;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      cache.close();
      tmdb.close();
      PaintingBinding.instance.imageCache.clear();
      await tester.runAsync(() => temp.delete(recursive: true));
    });
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await tester.runAsync(
      () => precacheImage(
        filmArtworkProvider(cache.knownFile('/good.png', 'w342')!),
        tester.element(find.byType(Scaffold)),
      ),
    );
    Widget cover(String path) => MaterialApp(
      home: Center(
        child: FilmArtwork(
          cache: cache,
          path: path,
          showCachedImmediately: true,
          width: 100,
          height: 150,
        ),
      ),
    );
    await tester.pumpWidget(cover('/good.png'));
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    await tester.pumpWidget(cover('/bad.png'));
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNull);
    for (var i = 0; i < 20 && find.byType(IconButton).evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(find.byType(IconButton), findsOneWidget);
    expect(find.byType(RawImage), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _NoToken extends TmdbCredentialStore {
  @override
  Future<String?> read() async => null;
}
