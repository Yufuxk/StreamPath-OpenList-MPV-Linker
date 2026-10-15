import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';

void main() {
  for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
    for (final immediate in [false, true]) {
      testWidgets(
        'settled poster keeps fractional motion inside its display list at $dpr DPR, immediate=$immediate',
        (tester) async {
          tester.view.physicalSize = Size(600 * dpr, 500 * dpr);
          tester.view.devicePixelRatio = dpr;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final fixture = (await tester.runAsync(() async {
            final temp = await Directory.systemTemp.createTemp(
              'poster_motion_',
            );
            final tmdb = TmdbMetadataService(credentials: _NoToken());
            final cache = FilmCatalogImageCache(temp, tmdb);
            final recorder = ui.PictureRecorder();
            final canvas = Canvas(recorder);
            canvas.drawColor(Colors.black, BlendMode.src);
            canvas.drawCircle(
              const Offset(70, 90),
              4.5,
              Paint()..color = Colors.white,
            );
            final picture = recorder.endRecording();
            final image = await picture.toImage(342, 513);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            image.dispose();
            picture.dispose();
            final file = File(
              '${temp.path}/${FilmCatalogImageCache.cacheKey('/motion.png', 'w342')}.img',
            );
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            await cache.cached('/motion.png', 'w342');
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
          const coverKey = Key('motion-image');
          Future<void> frame(bool hovered) => tester.pumpWidget(
            MaterialApp(
              home: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 70.25, top: 60.75),
                  child: SizedBox(
                    width: 166.5,
                    height: 249.75,
                    child: FilmPosterHover(
                      hovered: hovered,
                      child: FilmPosterHoverSurface(
                        child: FilmArtwork(
                          key: coverKey,
                          cache: cache,
                          path: '/motion.png',
                          width: 166.5,
                          height: 249.75,
                          borderRadius: 0,
                          showCachedImmediately: immediate,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await frame(false);
          for (var i = 0; i < 20; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 30));
          }
          final source = tester.widget<RawImage>(find.byType(RawImage)).image;
          expect(source, isNotNull);
          final original = tester.getRect(find.byKey(coverKey));
          final transform = find.byWidgetPredicate(
            (widget) => widget is Transform && !widget.transformHitTests,
          );
          for (final hovered in [true, false, true, false]) {
            await frame(hovered);
            for (var i = 0; i < 13; i++) {
              await tester.pump(const Duration(milliseconds: 16));
              final render = tester.renderObject<RenderTransform>(transform);
              // 独立 TransformLayer 会触发 Skia 对平移取整，破坏亚像素运动。
              expect(render.needsCompositing, isFalse);
              expect(
                tester.widget<RawImage>(find.byType(RawImage)).image,
                same(source),
              );
            }
          }
          await tester.pumpAndSettle();
          expect(tester.getRect(find.byKey(coverKey)), original);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}

class _NoToken extends TmdbCredentialStore {
  @override
  Future<String?> read() async => null;
}
