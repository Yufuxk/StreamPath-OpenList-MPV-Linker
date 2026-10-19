import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/film_home_section.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/film_shelf.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';

void main() {
  for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
    testWidgets('明亮分类封面悬停与取消悬停逐帧无边缘漏色 DPR=$dpr', (tester) async {
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = Size(800 * dpr, 600 * dpr);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final temp = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('category_surface_'),
      ))!;
      final tmdb = TmdbMetadataService();
      final cache = FilmCatalogImageCache(temp, tmdb);
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.white, BlendMode.src);
      final picture = recorder.endRecording();
      final image = (await tester.runAsync(() => picture.toImage(320, 180)))!;
      final bytes = await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.png),
      );
      image.dispose();
      picture.dispose();
      await tester.runAsync(() async {
        await File(
          '${temp.path}/${FilmCatalogImageCache.cacheKey('/fixture.png', 'w780')}.img',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        await cache.cached('/fixture.png', 'w780');
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        cache.close();
        tmdb.close();
        await tester.runAsync(() => temp.delete(recursive: true));
      });
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(glass: true),
          home: RepaintBoundary(
            key: boundary,
            child: Material(
              color: Colors.black,
              child: Center(
                child: SizedBox(
                  width: 320,
                  height: 180,
                  child: FilmCategoryCard(
                    category: const FilmCategory(
                      section: FilmHomeSection('decade:2010'),
                      count: 54,
                      coverPath: '/fixture.png',
                    ),
                    cache: cache,
                    onTap: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 30));
      }
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      final original = tester.getRect(find.byType(FilmArtwork));
      final matrices = <double>[];
      for (final hovered in [true, false]) {
        await mouse.moveTo(
          hovered
              ? tester.getCenter(find.byType(FilmCategoryCard))
              : Offset.zero,
        );
        await tester.pump();
        for (var frameIndex = 0; frameIndex < 13; frameIndex++) {
          await tester.pump(const Duration(milliseconds: 16));
          final transform = find.descendant(
            of: find.byType(FilmPosterHoverSurface),
            matching: find.byWidgetPredicate(
              (w) => w is Transform && !w.transformHitTests,
            ),
          );
          final render = tester.renderObject<RenderTransform>(transform);
          expect(render.needsCompositing, isFalse);
          matrices.add(
            tester.widget<Transform>(transform).transform.entry(0, 0),
          );
          final rect = tester.getRect(find.byType(FilmArtwork));
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: dpr);
            final pixels = (await image.toByteData())!.buffer.asUint8List();
            final x = (rect.center.dx * dpr).floor();
            final y = (rect.bottom * dpr).ceil() - 1;
            final offset = (y * image.width + x) * 4;
            image.dispose();
            expect(
              pixels[offset],
              lessThanOrEqualTo(79),
              reason: 'frame=$frameIndex hovered=$hovered',
            );
            expect(pixels[offset + 1], lessThanOrEqualTo(79));
            expect(pixels[offset + 2], lessThanOrEqualTo(79));
          });
        }
      }
      expect(matrices.take(13).first, greaterThan(1));
      expect(matrices[12], closeTo(AppTheme.posterHoverScale, .0001));
      expect(matrices.last, closeTo(1, .0001));
      expect(tester.getRect(find.byType(FilmArtwork)), original);
      await mouse.removePointer();
    });
  }
}
