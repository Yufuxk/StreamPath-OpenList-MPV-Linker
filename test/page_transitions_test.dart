import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/theme/page_transitions.dart';

void main() {
  testWidgets('半透明页面进出时内容不重叠且背景透明度稳定', (tester) async {
    const frameKey = Key('page-overlap-frame');
    const firstKey = Key('first-page-marker');
    const secondKey = Key('second-page-marker');
    const pageColor = Color(0xA620242A);
    final navigator = GlobalKey<NavigatorState>();
    Widget page(Key markerKey, Color markerColor) => Scaffold(
      backgroundColor: pageColor,
      body: Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.only(left: 100, top: 100),
          child: SizedBox(
            key: markerKey,
            width: 200,
            height: 40,
            child: ColoredBox(color: markerColor),
          ),
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: AppTheme.dark(
          glass: true,
        ).copyWith(platform: TargetPlatform.windows),
        builder: (_, child) => RepaintBoundary(
          key: frameKey,
          child: ColoredBox(color: Colors.white, child: child!),
        ),
        home: page(firstKey, Colors.red),
      ),
    );
    Future<void> checkFrames() async {
      await tester.pump();
      for (var frame = 0; frame < 15; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final markerRects = [
          for (final key in [firstKey, secondKey])
            if (find.byKey(key).evaluate().isNotEmpty)
              tester.getRect(find.byKey(key)),
        ];
        if (find.byKey(firstKey).evaluate().isNotEmpty &&
            find.byKey(secondKey).evaluate().isNotEmpty) {
          expect(
            tester
                .getRect(find.byKey(firstKey))
                .overlaps(tester.getRect(find.byKey(secondKey))),
            isFalse,
            reason: '第 $frame 帧的新旧页面内容不得重叠',
          );
        }
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(frameKey),
          );
          final image = await boundary.toImage();
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List();
          for (var x = 0; x < image.width; x++) {
            // 避开矩形边缘的亚像素混色。
            if (markerRects.any(
              (rect) =>
                  (x + .5 - rect.left).abs() <= 1 ||
                  (x + .5 - rect.right).abs() <= 1,
            )) {
              continue;
            }
            final marker = (120 * image.width + x) * 4;
            final background = (200 * image.width + x) * 4;
            final markerPixel = bytes.sublist(marker, marker + 4);
            final backgroundPixel = bytes.sublist(background, background + 4);
            expect(
              listEquals(markerPixel, backgroundPixel) ||
                  listEquals(markerPixel, [244, 67, 54, 255]) ||
                  listEquals(markerPixel, [76, 175, 80, 255]),
              isTrue,
              reason: '第 $frame 帧 x=$x 只能绘制一页的标记或背景',
            );
          }
          image.dispose();
        });
      }
      await tester.pumpAndSettle();
    }

    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => page(secondKey, Colors.green)),
    );
    await checkFrames();
    navigator.currentState!.pop();
    await checkFrames();
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => page(secondKey, Colors.green)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 48));
    navigator.currentState!.pop();
    await checkFrames();
    expect(tester.takeException(), isNull);
  });

  for (final pageColor in [const Color(0xFF20242A), const Color(0xA620242A)]) {
    testWidgets('同背景页面往返及替换期间不闪白 alpha=${pageColor.a}', (tester) async {
      const frameKey = Key('transition-pixel-frame');
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: AppTheme.dark().copyWith(platform: TargetPlatform.windows),
          builder: (_, child) => RepaintBoundary(
            key: frameKey,
            child: ColoredBox(color: Colors.white, child: child!),
          ),
          home: Scaffold(backgroundColor: pageColor),
        ),
      );
      Future<List<int>> pixel() async => (await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(frameKey),
        );
        final image = await boundary.toImage();
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        final offset = (150 * image.width + 400) * 4;
        final result = bytes.sublist(offset, offset + 4);
        image.dispose();
        return result;
      }))!;
      final baseline = await pixel();
      Future<void> checkFrames() async {
        await tester.pump();
        for (var frame = 0; frame < 15; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          final current = await pixel();
          expect(current, baseline, reason: '过渡第 $frame 帧背景亮度和透明度应稳定');
        }
        await tester.pumpAndSettle();
        expect(await pixel(), baseline);
      }

      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(backgroundColor: pageColor),
        ),
      );
      await checkFrames();
      navigator.currentState!.pop();
      await checkFrames();
      navigator.currentState!.pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(backgroundColor: pageColor),
        ),
      );
      await checkFrames();
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(backgroundColor: pageColor),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 48));
      navigator.currentState!.pop();
      await checkFrames();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Windows 页面相邻滑动且不淡化或缩放', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(
          glass: true,
        ).copyWith(platform: TargetPlatform.windows),
        home: const _TransitionTestHome(),
      ),
    );

    await tester.tap(find.byKey(const Key('open-next-page')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.text('第一页'), findsOneWidget);
    expect(find.text('第二页'), findsOneWidget);
    expect(
      find.byKey(StreamPathPageTransitionsBuilder.incomingSlideKey),
      findsWidgets,
    );
    final scaleTransitions = <ScaleTransition>[
      ...tester.widgetList<ScaleTransition>(
        find.ancestor(
          of: find.text('第一页'),
          matching: find.byType(ScaleTransition),
        ),
      ),
      ...tester.widgetList<ScaleTransition>(
        find.ancestor(
          of: find.text('第二页'),
          matching: find.byType(ScaleTransition),
        ),
      ),
    ];
    expect(
      scaleTransitions.every((transition) => transition.scale.value == 1),
      isTrue,
      reason: '路由常驻包装可以存在，但页面切换期间不得产生实际缩放',
    );
    expect(find.byType(AnimatedContainer), findsNothing);
    expect(find.byType(FadeTransition), findsNothing);

    await tester.pumpAndSettle();
    expect(find.text('第二页'), findsOneWidget);
    expect(find.text('第一页'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _TransitionTestHome extends StatelessWidget {
  const _TransitionTestHome();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const Text('第一页'),
          FilledButton(
            key: const Key('open-next-page'),
            onPressed: () => Navigator.of(context).pushReplacement(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('第二页')),
              ),
            ),
            child: const Text('切换'),
          ),
        ],
      ),
    );
  }
}
