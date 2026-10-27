import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';
import 'package:streampath/presentation/widgets/film_shelf.dart';

void main() {
  testWidgets('shelf reserves poster hover space and blends the scroll edge', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    for (final width in [364.0, 458.99, 459.0, 648.99, 649.0]) {
      final layout = FilmShelf.adaptiveLayout(width, 15);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: boundary,
              child: SizedBox(
                width: 800,
                height: 500,
                child: ColoredBox(
                  color: const Color(0xFF33445C),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 50),
                      child: SizedBox(
                        width: width,
                        child: FilmShelf(
                          title: 'Movies',
                          count: 30,
                          builder: (_, i) => FilmPosterHover(
                            hovered: i == layout.visible - 1,
                            child: FilmPosterHoverSurface(
                              child: ColoredBox(
                                key: ValueKey(i),
                                color: Colors.black,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final last = tester.getRect(find.byKey(ValueKey(layout.visible - 1)));
      expect(last.width, closeTo(layout.width * 1.05, .01));
      expect(
        tester.getRect(find.byType(Viewport)).right,
        greaterThan(last.right + 1),
      );
      final outer =
          boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final capture = await tester.runAsync(() async {
        final image = await outer.toImage();
        final pixels = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final imageWidth = image.width;
        image.dispose();
        return (pixels, imageWidth);
      });
      final y = (last.top + 50).floor();
      var brightest = 0;
      for (var x = (50 + width + 1).ceil(); x <= last.right.ceil(); x++) {
        final value = capture!.$1.getUint8((y * capture.$2 + x) * 4);
        if (value > brightest) brightest = value;
      }
      expect(
        brightest,
        closeTo(0x33, 3),
        reason:
            'Faded right edge reveals the actual background at width $width',
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('横向栏目为悬停放大与上浮保留绘制空间且内容位置不变', (tester) async {
    tester.view.physicalSize = const Size(1200, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const itemWidth = 112.0;
    const itemHeight = 140.0;
    const avatarSize = 68.0;
    final hoverInset =
        AppTheme.posterHoverLift +
        (itemWidth * (AppTheme.posterHoverScale - 1) / 2).ceilToDouble() +
        2;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 600,
            child: FilmShelf(
              title: 'Cast',
              count: 4,
              itemWidth: itemWidth,
              height: itemHeight,
              horizontal: true,
              builder: (_, i) => Column(
                key: ValueKey('item$i'),
                children: [
                  Padding(
                    key: ValueKey('slot$i'),
                    padding: const EdgeInsets.all(4),
                    child: FilmPosterHover(
                      hovered: i == 0,
                      borderRadius: BorderRadius.circular(999),
                      child: FilmPosterHoverSurface(
                        key: ValueKey('surface$i'),
                        borderRadius: BorderRadius.circular(999),
                        child: SizedBox(
                          key: ValueKey('avatar$i'),
                          width: avatarSize,
                          height: avatarSize,
                          child: const ColoredBox(color: Colors.black),
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
    );
    await tester.pumpAndSettle();
    final item = tester.getRect(find.byKey(const ValueKey('item0')));
    final idleItem = tester.getRect(find.byKey(const ValueKey('item1')));
    final idleAvatar = tester.getRect(find.byKey(const ValueKey('avatar1')));
    final avatar = tester.getRect(find.byKey(const ValueKey('avatar0')));
    final viewport = tester.getRect(
      find.descendant(
        of: find.byType(FilmShelf),
        matching: find.byType(Viewport),
      ),
    );
    // 视口向外扩展，内容仍从原位置开始。
    expect(viewport.top, closeTo(item.top - hoverInset, .01));
    expect(viewport.bottom, closeTo(item.bottom + hoverInset, .01));
    expect(viewport.left, closeTo(item.left - hoverInset, .01));
    expect(idleItem.left, closeTo(item.left + itemWidth + 16, .01));
    expect(idleAvatar.size, const Size(avatarSize, avatarSize));
    expect(idleAvatar.top, closeTo(idleItem.top + 4, .01));
    // 悬停项按共享倍率放大并上浮，绘制范围仍在扩展后的视口内。
    expect(avatar.width, closeTo(avatarSize * AppTheme.posterHoverScale, .01));
    expect(avatar.center.dx, closeTo(item.center.dx, .01));
    expect(
      avatar.top,
      closeTo(
        item.top +
            4 -
            AppTheme.posterHoverLift -
            avatarSize * (AppTheme.posterHoverScale - 1) / 2,
        .01,
      ),
    );
    expect(avatar.top, greaterThan(viewport.top));
    expect(avatar.left, greaterThan(viewport.left));
    final transform = find.descendant(
      of: find.byKey(const ValueKey('surface0')),
      matching: find.byWidgetPredicate(
        (widget) => widget is Transform && !widget.transformHitTests,
      ),
    );
    expect(transform, findsOneWidget);
    // 变换不拆出合成层，保持亚像素运动。
    expect(
      tester.renderObject<RenderTransform>(transform).needsCompositing,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });
}
