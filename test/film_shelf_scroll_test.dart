import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/widgets/film_shelf.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';

void main() {
  testWidgets('分辨率、DPI 与侧栏宽度变化时填满一行并保留海报比例', (tester) async {
    final tmdb = TmdbMetadataService();
    final cache = FilmCatalogImageCache(Directory.systemTemp, tmdb);
    addTearDown(cache.close);
    addTearDown(tmdb.close);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const rowKey = Key('adaptive-shelf');
    for (final resolution in [1280.0, 1366.0, 1600.0, 1920.0, 2560.0, 3840.0]) {
      for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
        for (final sidebar in [64.0, 220.0]) {
          tester.view.physicalSize = Size(resolution, 1200 * dpr);
          tester.view.devicePixelRatio = dpr;
          final available = resolution / dpr - sidebar - 40;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: available,
                    child: FilmShelf(
                      key: rowKey,
                      title: 'Movies',
                      count: 30,
                      builder: (_, i) => FilmWorkCard(
                        key: ValueKey(i),
                        work: FilmWork(
                          type: FilmMediaType.movie,
                          tmdbId: i + 1,
                          title: 'Movie $i',
                          originalTitle: 'Movie $i',
                          year: 2020,
                          overview: '',
                          language: 'en-US',
                        ),
                        cache: cache,
                        onTap: () {},
                        onMenu: (_) {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          final cards = find.byType(FilmWorkCard);
          final last = tester.getRect(cards.last);
          expect(
            last.right,
            closeTo(tester.getRect(find.byKey(rowKey)).right, .01),
            reason: 'resolution=$resolution DPR=$dpr sidebar=$sidebar',
          );
          final first = tester.getRect(cards.first);
          expect(first.width, greaterThan(0));
          for (final element in cards.evaluate()) {
            final card = find.byWidget(element.widget);
            expect(tester.getSize(card).width, closeTo(first.width, .01));
            final poster = tester.getSize(
              find.descendant(of: card, matching: find.byType(AspectRatio)),
            );
            expect(poster.width / poster.height, closeTo(2 / 3, .001));
          }
          if (resolution == 1920 && dpr == 1 && sidebar == 64) {
            expect(cards, findsNWidgets(10));
          }
          expect(tester.takeException(), isNull);
        }
      }
    }
  });

  testWidgets('断点两侧自然填充，数量不足时保持卡片尺寸', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1920, 1000);
    tester.view.devicePixelRatio = 1;
    Future<void> frame(
      double width, {
      int count = 30,
      double itemWidth = 174,
      double height = 304,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: FilmShelf(
                title: 'Movies',
                count: count,
                itemWidth: itemWidth,
                height: height,
                builder: (_, i) =>
                    ColoredBox(key: ValueKey(i), color: Colors.teal),
              ),
            ),
          ),
        ),
      ),
    );
    for (final width in [
      458.99,
      459.0,
      648.99,
      649.0,
      838.99,
      839.0,
      1788.99,
      1789.0,
      1816.0,
    ]) {
      await frame(width);
      final first = tester.getRect(find.byKey(const ValueKey(0)));
      final last = tester.getRect(find.byType(ColoredBox).last);
      expect(last.right, closeTo(width, .01));
      expect(first.width, greaterThan(0));
      expect(tester.takeException(), isNull);
    }
    await frame(1816, count: 2);
    expect(tester.getSize(find.byKey(const ValueKey(0))), const Size(174, 304));
    expect(tester.getRect(find.byKey(const ValueKey(1))).right, 364);
    await frame(1816, count: 3, itemWidth: 280, height: 188);
    expect(tester.getSize(find.byKey(const ValueKey(0))), const Size(280, 188));
    await frame(1816, count: 2, itemWidth: 300, height: 220);
    expect(tester.getSize(find.byKey(const ValueKey(0))), const Size(300, 220));
  });

  testWidgets('主页栏目只构建可见卡片，滚轮始终滚动整页', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: scroll,
            children: [
              FilmShelf(
                title: 'Movies',
                count: 30,
                builder: (_, i) => Text('Movie $i'),
              ),
              const SizedBox(height: 1500),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Movie 4'), findsNothing);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(find.text('Movie 0'))),
    );
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
    await tester.pump();
    expect(scroll.offset, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖到页面底部再返回不会重新创建已加载栏目', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    var created = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: scroll,
            children: [
              FilmShelf(
                title: 'Movies',
                count: 2,
                builder: (_, i) => _LoadedCard(onCreate: () => created++),
              ),
              const SizedBox(height: 2500),
            ],
          ),
        ),
      ),
    );
    final initial = created;
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    scroll.jumpTo(0);
    await tester.pump();
    expect(created, initial);
    expect(tester.takeException(), isNull);
  });
}

class _LoadedCard extends StatefulWidget {
  const _LoadedCard({required this.onCreate});
  final VoidCallback onCreate;
  @override
  State<_LoadedCard> createState() => _LoadedCardState();
}

class _LoadedCardState extends State<_LoadedCard> {
  @override
  void initState() {
    super.initState();
    widget.onCreate();
  }

  @override
  Widget build(BuildContext context) => const Placeholder();
}
