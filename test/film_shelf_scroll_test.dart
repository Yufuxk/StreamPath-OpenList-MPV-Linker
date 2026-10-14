import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/widgets/film_shelf.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';
import 'package:streampath/presentation/widgets/directory_scroll_view.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/film_home_section.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';

void main() {
  testWidgets('分类入口在明暗主题、窄宽度和放大文字下保留边界与点击', (tester) async {
    final tmdb = TmdbMetadataService();
    final cache = FilmCatalogImageCache(Directory.systemTemp, tmdb);
    addTearDown(cache.close);
    addTearDown(tmdb.close);
    var taps = 0;
    for (final brightness in Brightness.values) {
      for (final width in [180.0, 320.0]) {
        for (final scale in [1.0, 2.0]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: brightness),
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Center(
                  child: SizedBox(
                    width: width,
                    height: width * 9 / 16,
                    child: FilmCategoryCard(
                      category: const FilmCategory(
                        section: FilmHomeSection(
                          'genre:Animation & Science Fiction',
                        ),
                        count: 12,
                        coverPath: null,
                      ),
                      cache: cache,
                      onTap: () => taps++,
                    ),
                  ),
                ),
              ),
            ),
          );
          final card = tester.widget<Card>(find.byType(Card));
          expect(card.clipBehavior, Clip.none);
          expect(
            find.descendant(
              of: find.byType(FilmPosterHoverSurface),
              matching: find.byType(ClipRRect),
            ),
            findsWidgets,
          );
          final artwork = tester.getRect(find.byType(FilmArtwork));
          final cardBounds = tester.getRect(find.byType(FilmCategoryCard));
          expect(artwork.left, closeTo(cardBounds.left, .001));
          expect(artwork.top, closeTo(cardBounds.top, .001));
          expect(artwork.width, closeTo(cardBounds.width, .001));
          expect(artwork.height, closeTo(cardBounds.height, .001));
          await tester.tap(find.byType(FilmCategoryCard));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      }
    }
    expect(taps, 8);
  });

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
          final layout = FilmShelf.adaptiveLayout(available, 15);
          final last = tester.getRect(cards.at(layout.visible - 1));
          expect(
            last.right,
            closeTo(
              layout.visible * layout.width + (layout.visible - 1) * 16,
              .01,
            ),
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
      final visible = FilmShelf.adaptiveLayout(width, 15).visible;
      final last = tester.getRect(find.byKey(ValueKey(visible - 1)));
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

  testWidgets('主页鼠标拖动最多 15 张卡片，滚轮只滚动整页并保留查看全部', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    var opened = 0;
    var showAll = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: scroll,
            children: [
              FilmShelf(
                title: 'Movies',
                count: 30,
                onShowAll: () => showAll++,
                builder: (_, i) =>
                    InkWell(onTap: () => opened++, child: Text('Movie $i')),
              ),
              const SizedBox(height: 1500),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Movie 4'), findsNothing);
    final shelf = find.byType(FilmShelf);
    final shared = tester.widget<DirectoryScrollView>(
      find.descendant(of: shelf, matching: find.byType(DirectoryScrollView)),
    );
    final horizontal = shared.controller!;
    expect(shared.hideScrollbar, isTrue);
    expect(
      tester
          .widget<ListView>(
            find.descendant(of: shelf, matching: find.byType(ListView)),
          )
          .semanticChildCount,
      15,
    );
    await tester.tap(find.text('Movie 0'));
    expect(opened, 1);
    await tester.tap(find.text('查看全部'));
    expect(showAll, 1);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(find.text('Movie 0'))),
    );
    await tester.sendEventToBinding(pointer.scroll(const Offset(120, 0)));
    await tester.pump();
    expect(horizontal.offset, 0);
    scroll.jumpTo(0);
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
    await tester.pump();
    expect(scroll.offset, greaterThan(0));
    expect(horizontal.offset, 0);
    scroll.jumpTo(0);
    await tester.pump();
    await tester.drag(shelf, const Offset(-400, 0));
    expect(horizontal.offset, 0);
    await tester.drag(
      shelf,
      const Offset(-400, 0),
      kind: PointerDeviceKind.mouse,
    );
    expect(horizontal.offset, greaterThan(0));
    expect(scroll.offset, 0);
    expect(opened, 1);
    await tester.pumpAndSettle();
    await tester.drag(
      shelf,
      const Offset(-5000, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(horizontal.offset, horizontal.position.maxScrollExtent);
    expect(find.text('Movie 14'), findsOneWidget);
    expect(find.text('Movie 15'), findsNothing);
    await tester.drag(
      shelf,
      const Offset(5000, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(horizontal.offset, 0);
    expect(find.text('Movie 0'), findsOneWidget);
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
