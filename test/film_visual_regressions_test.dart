import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';
import 'package:streampath/presentation/widgets/film_watch_overlay.dart';

void main() {
  testWidgets(
    'cover return starts gently and stays continuous when interrupted',
    (tester) async {
      const contentKey = Key('cover-return-content');
      Future<void> frame(bool hovered) => tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 180,
              height: 270,
              child: FilmPosterHover(
                hovered: hovered,
                child: const FilmPosterHoverSurface(
                  child: ColoredBox(key: contentKey, color: Colors.teal),
                ),
              ),
            ),
          ),
        ),
      );
      await frame(false);
      final original = tester.getRect(find.byKey(contentKey));
      await frame(true);
      await tester.pump(const Duration(milliseconds: 200));
      final enlarged = tester.getRect(find.byKey(contentKey));
      expect(enlarged.width, closeTo(original.width * 1.05, .001));
      expect(enlarged.center.dy, closeTo(original.center.dy - 6, .001));
      await frame(false);
      await tester.pump(const Duration(milliseconds: 16));
      final first = tester.getRect(find.byKey(contentKey));
      expect(enlarged.width - first.width, lessThan(.5));
      expect(first.center.dy, greaterThan(enlarged.center.dy));
      await tester.pump(const Duration(milliseconds: 64));
      final interrupted = tester.getRect(find.byKey(contentKey));
      await frame(true);
      expect(tester.getRect(find.byKey(contentKey)), interrupted);
      await tester.pump(const Duration(milliseconds: 200));
      await frame(false);
      var lastWidth = enlarged.width;
      for (var i = 0; i < 13; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final current = tester.getRect(find.byKey(contentKey));
        expect(current.width, lessThanOrEqualTo(lastWidth + .001));
        expect(current.center.dx, closeTo(original.center.dx, .001));
        expect(
          current.center.dy,
          inInclusiveRange(original.center.dy - 6, original.center.dy),
        );
        lastWidth = current.width;
      }
      expect(tester.getRect(find.byKey(contentKey)), original);
    },
  );

  testWidgets('spoiler overview fades into its background without a hard box', (
    tester,
  ) async {
    final fixture = await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('film_soft_spoiler_');
      final store = await FilmCatalogStore.open('${temp.path}/catalog.db');
      await store.setPreference('spoiler_protection', true);
      return (temp, store);
    });
    final (temp, store) = fixture!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await store.close();
        await temp.delete(recursive: true);
      });
    });
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: boundary,
            child: ColoredBox(
              color: Colors.black,
              child: FilmWatchOverlay(
                store: store,
                spoilerSensitive: true,
                showStatus: false,
                canReveal: false,
                revealBelow: true,
                child: const SizedBox(
                  width: 300,
                  height: 60,
                  child: ColoredBox(color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final image = await tester.runAsync(
      () =>
          (boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage(),
    );
    final bytes = (await tester.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    image!.dispose();
    int light(int x, int y) => bytes.getUint8((y * 300 + x) * 4);
    expect(light(150, 30), greaterThan(100));
    expect(light(150, 30), lessThan(220));
    expect(light(1, 30), lessThan(40));
    expect(light(298, 30), lessThan(40));
    expect(light(150, 1), lessThan(40));
    expect(light(150, 58), lessThan(40));
  });

  testWidgets('防剧透封面保持边缘亮度，模糊不进入封面下方', (tester) async {
    final fixture = await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('film_blur_bounds_');
      final store = await FilmCatalogStore.open('${temp.path}/catalog.db');
      await store.setPreference('spoiler_protection', true);
      return (temp, store);
    });
    final (temp, store) = fixture!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await store.close();
        await temp.delete(recursive: true);
      });
    });
    final boundary = GlobalKey();
    const coverKey = Key('spoiler-cover');
    // 保持子树身份，在不同悬浮帧比较实际像素。
    Future<void> cover(bool hovered) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: FilmPosterHover(
              hovered: hovered,
              child: RepaintBoundary(
                key: boundary,
                child: SizedBox(
                  width: 260,
                  height: 240,
                  child: ColoredBox(
                    color: Colors.red,
                    child: Column(
                      children: [
                        FilmPosterHoverSurface(
                          child: FilmWatchOverlay(
                            store: store,
                            spoilerSensitive: true,
                            canReveal: false,
                            showStatus: false,
                            child: SizedBox(
                              key: coverKey,
                              width: 260,
                              height: 160,
                              child: ClipRect(
                                child: const ColoredBox(
                                  key: Key('zoomed-cover-content'),
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await cover(false);
    await tester.pump();
    for (final hovered in [false, true, false]) {
      await cover(hovered);
      for (var i = 0; i < 11; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          tester.getCenter(find.byKey(const Key('zoomed-cover-content'))),
          tester.getCenter(find.byKey(coverKey)),
        );
        final image = await tester.runAsync(
          () =>
              (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(),
        );
        final bytes = (await tester.runAsync(
          () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
        ))!;
        image!.dispose();
        int channel(int x, int y, int component) =>
            bytes.getUint8((y * 260 + x) * 4 + component);
        expect(
          channel(
            130,
            (tester.getRect(find.byKey(coverKey)).bottom -
                    tester.getRect(find.byKey(boundary)).top -
                    3)
                .floor(),
            1,
          ),
          greaterThan(245),
          reason: 'cover edge hovered=$hovered frame=$i',
        );
        expect(
          channel(
            130,
            (tester.getRect(find.byKey(coverKey)).bottom -
                    tester.getRect(find.byKey(boundary)).top +
                    5)
                .floor(),
            1,
          ),
          closeTo(
            channel(
                  130,
                  (tester.getRect(find.byKey(coverKey)).bottom -
                          tester.getRect(find.byKey(boundary)).top +
                          5)
                      .floor(),
                  0,
                ) *
                Colors.red.g /
                Colors.red.r,
            1,
          ),
          reason: 'blur outside cover hovered=$hovered frame=$i',
        );
      }
    }
  });

  testWidgets('竖封面进度轨道覆盖整条底边，不透出海报像素', (tester) async {
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: boundary,
              child: SizedBox(
                width: 174,
                height: 261,
                child: FilmWatchOverlay(
                  fallbackFraction: .3,
                  child: const ColoredBox(color: Colors.pink),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final image = await tester.runAsync(
      () =>
          (boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage(),
    );
    final bytes = (await tester.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    image!.dispose();
    final poster = Colors.pink.toARGB32();
    for (var x = 1; x < 173; x++) {
      final offset = (260 * 174 + x) * 4;
      final color =
          0xff000000 |
          bytes.getUint8(offset) << 16 |
          bytes.getUint8(offset + 1) << 8 |
          bytes.getUint8(offset + 2);
      expect(color, isNot(poster), reason: 'poster exposed at x=$x');
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
