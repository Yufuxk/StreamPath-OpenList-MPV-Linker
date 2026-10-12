import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/theme/page_transitions.dart';

void main() {
  testWidgets('转场曲线重建和父动画交接后只保留当前监听', (tester) async {
    const builder = StreamPathPageTransitionsBuilder();
    final primary = _CountingAnimation();
    final secondary = _CountingAnimation();
    Widget transition(Animation<double> incoming, Animation<double> outgoing) =>
        Directionality(
          textDirection: TextDirection.ltr,
          child: builder.buildTransitions<void>(
            null,
            null,
            incoming,
            outgoing,
            const SizedBox(),
          ),
        );
    for (var i = 0; i < 120; i++) {
      await tester.pumpWidget(transition(primary, secondary));
    }
    expect(primary.statusListeners.length, 2);
    expect(secondary.statusListeners.length, 2);
    final replacement = _CountingAnimation();
    await tester.pumpWidget(transition(replacement, secondary));
    expect(primary.statusListeners, isEmpty);
    expect(replacement.statusListeners.length, 2);
    await tester.pumpWidget(const SizedBox());
    expect(replacement.statusListeners, isEmpty);
    expect(secondary.statusListeners, isEmpty);
  });

  testWidgets('动画中途反向并重建时页面位移连续', (tester) async {
    const builder = StreamPathPageTransitionsBuilder();
    final primary = _CountingAnimation(
      initialValue: .4,
      currentStatus: AnimationStatus.forward,
    );
    final secondary = _CountingAnimation();
    Widget transition() => Directionality(
      textDirection: TextDirection.ltr,
      child: builder.buildTransitions<void>(
        null,
        null,
        primary,
        secondary,
        const SizedBox(),
      ),
    );
    await tester.pumpWidget(transition());
    double position() => tester
        .widget<Transform>(
          find.byKey(StreamPathPageTransitionsBuilder.incomingSlideKey),
        )
        .transform
        .storage[12];
    final before = position();
    primary.changeStatus(AnimationStatus.reverse);
    await tester.pumpWidget(transition());
    expect(position(), before);
  });

  testWidgets('异类路由委托转场反向连续并释放监听', (tester) async {
    const builder = StreamPathPageTransitionsBuilder();
    final secondary = _CountingAnimation(
      initialValue: .4,
      currentStatus: AnimationStatus.forward,
    );
    Widget transition() => Directionality(
      textDirection: TextDirection.ltr,
      child: Builder(
        builder: (context) => builder.delegatedTransition(
          context,
          kAlwaysCompleteAnimation,
          secondary,
          true,
          const SizedBox(),
        )!,
      ),
    );
    await tester.pumpWidget(transition());
    final before = tester
        .widget<Transform>(find.byType(Transform))
        .transform
        .storage[12];
    secondary.changeStatus(AnimationStatus.reverse);
    await tester.pumpWidget(transition());
    expect(
      tester.widget<Transform>(find.byType(Transform)).transform.storage[12],
      before,
    );
    expect(secondary.statusListeners.length, 1);
    await tester.pumpWidget(const SizedBox());
    expect(secondary.statusListeners, isEmpty);
  });

  testWidgets('实际路由二十次往返后首页转场监听数稳定', (tester) async {
    final builder = _CountingTransitionsBuilder();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: ThemeData(
          platform: TargetPlatform.windows,
          pageTransitionsTheme: PageTransitionsTheme(
            builders: {TargetPlatform.windows: builder},
          ),
        ),
        home: const Scaffold(),
      ),
    );
    final primary = builder.homePrimary!;
    final secondary = builder.homeSecondary!;
    for (var i = 0; i < 20; i++) {
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold()),
      );
      await tester.pump();
      await tester.pumpAndSettle(const Duration(milliseconds: 16));
      navigator.currentState!.pop();
      await tester.pump();
      await tester.pumpAndSettle(const Duration(milliseconds: 16));
    }
    expect(primary.statusListeners.length, 2);
    expect(secondary.statusListeners.length, 2);
    await tester.pumpWidget(const SizedBox());
    expect(primary.statusListeners, isEmpty);
    expect(secondary.statusListeners, isEmpty);
  });

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
        theme: AppTheme.dark(glass: true).copyWith(
          platform: TargetPlatform.windows,
          scaffoldBackgroundColor: pageColor,
        ),
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
        double opacity(Key key) {
          final finder = find.byKey(key);
          if (finder.evaluate().isEmpty) return 0;
          return tester
              .widgetList<Opacity>(
                find.ancestor(of: finder, matching: find.byType(Opacity)),
              )
              .fold(1.0, (value, widget) => value * widget.opacity);
        }

        expect(
          opacity(firstKey) > 0 && opacity(secondKey) > 0,
          isFalse,
          reason: '第 $frame 帧只显示退出或进入页面',
        );
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(frameKey),
          );
          final image = await boundary.toImage();
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List();
          final pixel = (200 * image.width + 400) * 4;
          expect(bytes[pixel], lessThan(200), reason: '主题底色不闪白');
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
          theme: AppTheme.dark().copyWith(
            platform: TargetPlatform.windows,
            scaffoldBackgroundColor: pageColor,
          ),
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
          for (var channel = 0; channel < 4; channel++) {
            expect(
              current[channel],
              closeTo(baseline[channel], 2),
              reason: '过渡第 $frame 帧背景亮度和透明度应稳定',
            );
          }
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

  testWidgets('Windows 页面短距离位移与分段淡化，保持尺寸', (tester) async {
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
    final nextOpacity = tester
        .widgetList<Opacity>(
          find.ancestor(of: find.text('第二页'), matching: find.byType(Opacity)),
        )
        .fold(1.0, (v, w) => v * w.opacity);
    final nextTransform = tester
        .widgetList<Transform>(
          find.ancestor(
            of: find.text('第二页'),
            matching: find.byKey(
              StreamPathPageTransitionsBuilder.incomingSlideKey,
            ),
          ),
        )
        .first;
    expect(nextOpacity, inExclusiveRange(0, 1));
    expect(nextTransform.transform.storage[12], inInclusiveRange(0, 30));

    await tester.pumpAndSettle();
    expect(find.text('第二页'), findsOneWidget);
    expect(find.text('第一页'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _CountingAnimation extends Animation<double> {
  _CountingAnimation({
    this.parent,
    this.initialValue = 0,
    this.currentStatus = AnimationStatus.dismissed,
  });
  final Animation<double>? parent;
  final double initialValue;
  AnimationStatus currentStatus;
  final statusListeners = <AnimationStatusListener>{};
  @override
  double get value => parent?.value ?? initialValue;
  @override
  AnimationStatus get status => parent?.status ?? currentStatus;
  @override
  void addListener(VoidCallback listener) => parent?.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      parent?.removeListener(listener);
  @override
  void addStatusListener(AnimationStatusListener listener) {
    statusListeners.add(listener);
    parent?.addStatusListener(listener);
  }

  @override
  void removeStatusListener(AnimationStatusListener listener) {
    statusListeners.remove(listener);
    parent?.removeStatusListener(listener);
  }

  void changeStatus(AnimationStatus status) {
    currentStatus = status;
    for (final listener in statusListeners.toList()) {
      listener(status);
    }
  }
}

class _CountingTransitionsBuilder extends PageTransitionsBuilder {
  final _probes = Expando<_CountingAnimation>();
  _CountingAnimation? homePrimary, homeSecondary;
  static const _delegate = StreamPathPageTransitionsBuilder();
  @override
  Duration get transitionDuration => _delegate.transitionDuration;
  @override
  Duration get reverseTransitionDuration => _delegate.reverseTransitionDuration;
  _CountingAnimation _wrap(Animation<double> animation) =>
      _probes[animation] ??= _CountingAnimation(parent: animation);
  @override
  Widget buildTransitions<T>(
    PageRoute<T>? route,
    BuildContext? context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final primary = _wrap(animation);
    final secondary = _wrap(secondaryAnimation);
    if (route!.isFirst) {
      homePrimary = primary;
      homeSecondary = secondary;
    }
    return _delegate.buildTransitions(
      route,
      context,
      primary,
      secondary,
      child,
    );
  }
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
