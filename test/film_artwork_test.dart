import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';

void main() {
  testWidgets('离线原图不可用时只复用已缓存背景', (tester) async {
    final fixture = await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp(
        'film_backdrop_offline_',
      );
      final file = File(
        p.join(
          temp.path,
          '${FilmCatalogImageCache.cacheKey('/frame.png', 'w780')}.img',
        ),
      );
      await file.writeAsBytes(await File('assets/tmdb_logo.png').readAsBytes());
      final tmdb = TmdbMetadataService(credentials: _NoToken());
      final cache = FilmCatalogImageCache(temp, tmdb);
      await cache.cached('/frame.png', 'w780');
      return (temp, file, tmdb, cache);
    });
    final (temp, file, tmdb, cache) = fixture!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      cache.close();
      tmdb.close();
      await tester.runAsync(() => temp.delete(recursive: true));
    });
    await tester.pumpWidget(
      MaterialApp(
        home: FilmArtwork(
          cache: cache,
          path: '/frame.png',
          target: 'original',
          backdrop: true,
          height: double.infinity,
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    final image = tester.widgetList<Image>(find.byType(Image)).last;
    expect((image.image as FileImage).file.path, file.path);
    expect(image.fit, BoxFit.scaleDown);
    expect(tester.takeException(), isNull);
  });
  for (final size in [
    const Size(1280, 720),
    const Size(1600, 600),
    const Size(640, 1000),
  ]) {
    for (final dpr in [1.0, 2.0]) {
      testWidgets('背景完整构图与物理像素限制 $size DPR=$dpr', (tester) async {
        tester.view.physicalSize = size * dpr;
        tester.view.devicePixelRatio = dpr;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = await tester.runAsync(() async {
          final temp = await Directory.systemTemp.createTemp('film_backdrop_');
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          canvas.drawRect(
            const Rect.fromLTWH(0, 0, 1920, 1080),
            Paint()..color = Colors.teal,
          );
          canvas.drawRect(
            const Rect.fromLTWH(0, 0, 200, 1080),
            Paint()..color = Colors.blue,
          );
          canvas.drawRect(
            const Rect.fromLTWH(1720, 0, 200, 1080),
            Paint()..color = Colors.red,
          );
          final picture = recorder.endRecording();
          final image = await picture.toImage(1920, 1080);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          picture.dispose();
          await File(
            p.join(
              temp.path,
              '${FilmCatalogImageCache.cacheKey('/frame.png', 'original')}.img',
            ),
          ).writeAsBytes(bytes!.buffer.asUint8List());
          final tmdb = TmdbMetadataService();
          final cache = FilmCatalogImageCache(temp, tmdb);
          await cache.get('/frame.png', target: 'original');
          return (temp, tmdb, cache);
        });
        final (temp, tmdb, cache) = fixture!;
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          cache.close();
          tmdb.close();
          await tester.runAsync(() => temp.delete(recursive: true));
        });
        await tester.pumpWidget(
          MaterialApp(
            home: FilmArtwork(
              cache: cache,
              path: '/frame.png',
              target: 'original',
              backdrop: true,
              width: double.infinity,
              height: double.infinity,
              borderRadius: 0,
            ),
          ),
        );
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        final images = tester.widgetList<Image>(find.byType(Image)).toList();
        expect(images, hasLength(2));
        expect(images.first.fit, BoxFit.cover);
        expect(images.last.fit, BoxFit.scaleDown);
        expect(images.last.image, isA<FileImage>());
        expect((images.last.image as FileImage).scale, dpr);
        expect(find.byType(ImageFiltered), findsOneWidget);
        final render = tester.renderObject<RenderImage>(
          find.byType(RawImage).last,
        );
        expect(render.image!.width, 1920);
        expect(render.image!.height, 1080);
        final fitted = applyBoxFit(
          render.fit!,
          Size(1920 / dpr, 1080 / dpr),
          render.size,
        );
        expect(fitted.source, Size(1920 / dpr, 1080 / dpr));
        expect(fitted.destination.width * dpr, lessThanOrEqualTo(1920));
        expect(fitted.destination.height * dpr, lessThanOrEqualTo(1080));
        // 比例不同的窗口里，清晰图与补边交界应连续。
        final rect = Alignment.center.inscribe(
          fitted.destination,
          Offset.zero & size,
        );
        if (rect.left > 4 || rect.top > 4) {
          final pixels = await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.descendant(
                of: find.byType(FilmArtwork),
                matching: find.byType(RepaintBoundary),
              ),
            );
            final snapshot = await boundary.toImage(pixelRatio: 1);
            final data = await snapshot.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            snapshot.dispose();
            return data!;
          });
          int difference(Offset a, Offset b) {
            final first =
                (a.dy.floor() * size.width.toInt() + a.dx.floor()) * 4;
            final second =
                (b.dy.floor() * size.width.toInt() + b.dx.floor()) * 4;
            return List.generate(
              3,
              (channel) =>
                  (pixels!.getUint8(first + channel) -
                          pixels.getUint8(second + channel))
                      .abs(),
            ).reduce((a, b) => a + b);
          }

          if (rect.left > 4) {
            expect(
              difference(
                Offset(rect.left - 2, size.height / 2),
                Offset(rect.left + 2, size.height / 2),
              ),
              lessThan(32),
            );
            expect(
              difference(
                Offset(rect.right - 2, size.height / 2),
                Offset(rect.right + 2, size.height / 2),
              ),
              lessThan(32),
            );
          }
          if (rect.top > 4) {
            expect(
              difference(
                Offset(size.width / 2, rect.top - 2),
                Offset(size.width / 2, rect.top + 2),
              ),
              lessThan(32),
            );
            expect(
              difference(
                Offset(size.width / 2, rect.bottom - 2),
                Offset(size.width / 2, rect.bottom + 2),
              ),
              lessThan(32),
            );
          }
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}

class _NoToken extends TmdbCredentialStore {
  @override
  Future<String?> read() async => null;
}
