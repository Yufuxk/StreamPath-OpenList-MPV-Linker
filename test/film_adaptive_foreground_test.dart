import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/widgets/film_adaptive_foreground.dart';

void main() {
  testWidgets('centered short lines ignore bright padding and blank lines', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = FilmBackdropTextController();
    final scroll = ScrollController();
    final keys = [GlobalKey(), GlobalKey()];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(),
        home: Stack(
          children: [
            Positioned.fill(
              child: FilmBackdropSamplingBoundary(
                controller: controller,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Expanded(
                      flex: 4,
                      child: ColoredBox(color: Colors.white),
                    ),
                    const Expanded(
                      flex: 2,
                      child: ColoredBox(color: Colors.black),
                    ),
                    const Expanded(
                      flex: 4,
                      child: ColoredBox(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              top: 80,
              left: 0,
              right: 0,
              child: FilmAdaptiveForeground(
                controller: controller,
                textKeys: keys,
                scrollController: scroll,
                builder: (_, color) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    KeyedSubtree(
                      key: keys[0],
                      child: Text(
                        '2010',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, color: color),
                      ),
                    ),
                    Text(
                      '2010\n\nStory',
                      key: keys[1],
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      style: TextStyle(fontSize: 14, color: color),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    controller.refresh();
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(tester.widget<Text>(find.byKey(keys[1])).style!.color, Colors.white);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    scroll.dispose();
  });

  testWidgets('bright patches do not outweigh unreadable dark text regions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = FilmBackdropTextController();
    final scroll = ScrollController();
    final keys = List.generate(3, (_) => GlobalKey());
    final brightMajority = ValueNotifier(false);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Stack(
          children: [
            Positioned.fill(
              child: ValueListenableBuilder<bool>(
                valueListenable: brightMajority,
                builder: (_, bright, _) {
                  controller.refresh();
                  return FilmBackdropSamplingBoundary(
                    controller: controller,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          flex: 7,
                          child: ColoredBox(
                            color: bright
                                ? Colors.white
                                : const Color(0xff414141),
                          ),
                        ),
                        Expanded(
                          flex: 3,
                          child: ColoredBox(
                            color: bright ? Colors.black : Colors.white,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Positioned(
              top: 80,
              left: 0,
              right: 0,
              child: FilmAdaptiveForeground(
                controller: controller,
                textKeys: keys,
                scrollController: scroll,
                builder: (_, color) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < keys.length; i++)
                      Text(
                        'Information $i',
                        key: keys[i],
                        style: TextStyle(color: color),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    Future<void> settle(Color expected) async {
      for (var i = 0; i < 25; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      for (final key in keys) {
        expect(tester.widget<Text>(find.byKey(key)).style!.color, expected);
      }
    }

    await settle(Colors.white);
    brightMajority.value = true;
    await settle(Colors.black);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    scroll.dispose();
    brightMajority.dispose();
  });

  testWidgets('information text shares one animated black or white color', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = FilmBackdropTextController();
    final scroll = ScrollController();
    final background = ValueNotifier(Colors.black);
    final keys = List.generate(3, (_) => GlobalKey());
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Stack(
          children: [
            Positioned.fill(
              child: ValueListenableBuilder<Color>(
                valueListenable: background,
                builder: (_, color, _) {
                  controller.refresh();
                  return FilmBackdropSamplingBoundary(
                    controller: controller,
                    child: ColoredBox(color: color),
                  );
                },
              ),
            ),
            Positioned(
              top: 80,
              left: 40,
              right: 40,
              child: FilmAdaptiveForeground(
                controller: controller,
                textKeys: keys,
                scrollController: scroll,
                builder: (_, color) => Column(
                  children: [
                    for (var i = 0; i < keys.length; i++)
                      Text(
                        'Information $i',
                        key: keys[i],
                        style: TextStyle(fontSize: 14, color: color),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    Future<List<Color>> advance() async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      final colors = [
        for (final key in keys)
          tester.widget<Text>(find.byKey(key)).style!.color!,
      ];
      expect(colors.toSet(), hasLength(1));
      expect(
        tester.widget<Text>(find.byKey(keys.first)).style!.shadows,
        isNull,
      );
      return colors;
    }

    for (var i = 0; i < 20; i++) {
      await advance();
    }
    expect((await advance()).first, Colors.white);
    background.value = Colors.white;
    var sawIntermediate = false;
    for (var i = 0; i < 20; i++) {
      final color = (await advance()).first;
      if (color != Colors.white && color != Colors.black) {
        sawIntermediate = true;
      }
    }
    expect(sawIntermediate, isTrue);
    expect((await advance()).first, Colors.black);
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 2;
    background.value = Colors.black;
    controller.refresh();
    for (var i = 0; i < 20; i++) {
      await advance();
    }
    expect((await advance()).first, Colors.white);
    background.value = Colors.white;
    controller.refresh();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    scroll.dispose();
    background.dispose();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'scrolling samples the text location and keeps the group uniform',
    (tester) async {
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = FilmBackdropTextController();
      final scroll = ScrollController();
      final keys = List.generate(3, (_) => GlobalKey());
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Stack(
            children: [
              Positioned.fill(
                child: FilmBackdropSamplingBoundary(
                  controller: controller,
                  child: Column(
                    children: [
                      Expanded(child: Container(color: Colors.black)),
                      Expanded(child: Container(color: Colors.white)),
                    ],
                  ),
                ),
              ),
              SingleChildScrollView(
                controller: scroll,
                child: Column(
                  children: [
                    const SizedBox(height: 210),
                    FilmAdaptiveForeground(
                      controller: controller,
                      textKeys: keys,
                      scrollController: scroll,
                      builder: (_, color) => Column(
                        children: [
                          for (var i = 0; i < keys.length; i++)
                            Text(
                              'Information $i',
                              key: keys[i],
                              style: TextStyle(fontSize: 14, color: color),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 400),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
      controller.refresh();
      Future<void> settleColor(Color expected) async {
        for (var i = 0; i < 25; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
          final colors = [
            for (final key in keys)
              tester.widget<Text>(find.byKey(key)).style!.color!,
          ];
          expect(colors.toSet(), hasLength(1));
        }
        for (final key in keys) {
          expect(tester.widget<Text>(find.byKey(key)).style!.color, expected);
        }
      }

      await settleColor(Colors.black);
      scroll.jumpTo(180);
      await settleColor(Colors.white);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      scroll.dispose();
    },
  );
}
