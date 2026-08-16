import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/window_title_bar.dart';

void main() {
  Widget wrap(Widget child, {ThemeData? theme}) {
    return MaterialApp(
      theme: theme ?? AppTheme.light(),
      home: Scaffold(body: child),
    );
  }

  testWidgets('标题栏显示应用标识与三个窗口控制按钮', (tester) async {
    await tester.pumpWidget(wrap(const WindowTitleBar()));

    expect(find.text('StreamPath'), findsOneWidget);
    expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
    expect(find.byKey(WindowTitleBar.minimizeButtonKey), findsOneWidget);
    expect(find.byKey(WindowTitleBar.maximizeButtonKey), findsOneWidget);
    expect(find.byKey(WindowTitleBar.closeButtonKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('三个窗口控制图标使用 Windows 系统字形并垂直居中', (tester) async {
    await tester.pumpWidget(wrap(const WindowTitleBar()));

    final iconFinders = [
      find.byKey(WindowTitleBar.minimizeIconKey),
      find.byKey(WindowTitleBar.maximizeIconKey),
      find.byKey(WindowTitleBar.closeIconKey),
    ];
    final centers = iconFinders.map(tester.getCenter).toList();

    for (final finder in iconFinders) {
      expect(tester.getSize(finder), const Size.square(12));
      final glyph = tester.widget<Text>(
        find.descendant(of: finder, matching: find.byType(Text)),
      );
      expect(glyph.style?.fontFamily, 'Segoe Fluent Icons');
      expect(glyph.style?.fontFamilyFallback, ['Segoe MDL2 Assets']);
    }
    expect(
      iconFinders
          .map(
            (finder) => tester
                .widget<Text>(
                  find.descendant(of: finder, matching: find.byType(Text)),
                )
                .data,
          )
          .toList(),
      ['\uE921', '\uE922', '\uE8BB'],
    );
    expect(centers.map((center) => center.dy).toSet(), hasLength(1));
    expect(centers.first.dy, WindowTitleBar.height / 2);
  });

  testWidgets('标题栏与页面 AppBar 的最终合成颜色一致', (tester) async {
    await tester.pumpWidget(
      wrap(
        Column(
          children: [
            const WindowTitleBar(),
            AppBar(title: const Text('根目录')),
            const Expanded(child: SizedBox()),
          ],
        ),
      ),
    );

    final context = tester.element(find.byType(WindowTitleBar));
    final theme = Theme.of(context);
    final titleBarSurface = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(WindowTitleBar),
            matching: find.byType(Material),
          )
          .first,
    );
    final appBarSurface = tester.widget<Material>(
      find
          .descendant(of: find.byType(AppBar), matching: find.byType(Material))
          .first,
    );
    expect(
      titleBarSurface.color,
      Color.alphaBlend(appBarSurface.color!, theme.scaffoldBackgroundColor),
    );
  });

  testWidgets('磨砂玻璃主题下标题栏保留合成后的透明度', (tester) async {
    await tester.pumpWidget(
      wrap(
        const WindowTitleBar(),
        theme: AppTheme.light(glass: true, glassOpacity: 0.8),
      ),
    );

    final context = tester.element(find.byType(WindowTitleBar));
    final surface = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(WindowTitleBar),
            matching: find.byType(Material),
          )
          .first,
    );
    final theme = Theme.of(context);
    expect(
      surface.color,
      Color.alphaBlend(
        theme.appBarTheme.backgroundColor!,
        theme.scaffoldBackgroundColor,
      ),
    );
    expect(surface.color!.a, lessThan(1));
  });

  testWidgets('原生通道缺失时窗口控制按钮安全降级', (tester) async {
    await tester.pumpWidget(wrap(const WindowTitleBar()));

    await tester.tap(find.byKey(WindowTitleBar.minimizeButtonKey));
    await tester.tap(find.byKey(WindowTitleBar.maximizeButtonKey));
    await tester.tap(find.byKey(WindowTitleBar.closeButtonKey));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('自绘图标不改变三个窗口控制操作与最大化状态同步', (tester) async {
    const channel = MethodChannel('streampath/appearance');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return switch (call.method) {
            'isMaximized' => false,
            'toggleMaximize' => true,
            _ => null,
          };
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await tester.pumpWidget(wrap(const WindowTitleBar()));
    await tester.pump();
    calls.clear();

    await tester.tap(find.byKey(WindowTitleBar.minimizeButtonKey));
    await tester.tap(find.byKey(WindowTitleBar.maximizeButtonKey));
    await tester.pump();
    await tester.tap(find.byKey(WindowTitleBar.closeButtonKey));
    await tester.pump();

    expect(calls, containsAllInOrder(['minimize', 'toggleMaximize', 'close']));
    expect(find.byTooltip('还原'), findsOneWidget);
    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(WindowTitleBar.maximizeIconKey),
              matching: find.byType(Text),
            ),
          )
          .data,
      '\uE923',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('推送给原生的窗口框架色与标题栏背景完全一致', (tester) async {
    const channel = MethodChannel('streampath/appearance');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await tester.pumpWidget(wrap(const WindowTitleBar()));
    await tester.pump();

    final frameCalls = calls
        .where((call) => call.method == 'setFrameColor')
        .toList(growable: false);
    expect(frameCalls, isNotEmpty);
    final args = frameCalls.first.arguments as Map<Object?, Object?>;
    final topBarColor = tester
        .widget<Material>(
          find
              .descendant(
                of: find.byType(WindowTitleBar),
                matching: find.byType(Material),
              )
              .first,
        )
        .color!;
    final argb = topBarColor.toARGB32();
    expect(args['r'], (argb >> 16) & 0xFF);
    expect(args['g'], (argb >> 8) & 0xFF);
    expect(args['b'], argb & 0xFF);
    expect(args['a'], (argb >> 24) & 0xFF);
  });

  testWidgets('磨砂玻璃主题下原生框架保持透明并由 Flutter 覆盖', (tester) async {
    const channel = MethodChannel('streampath/appearance');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await tester.pumpWidget(
      wrap(
        const WindowTitleBar(),
        theme: AppTheme.light(glass: true, glassOpacity: 0.8),
      ),
    );
    await tester.pump();

    final frameCalls = calls
        .where((call) => call.method == 'setFrameColor')
        .toList(growable: false);
    expect(frameCalls, isNotEmpty);
    final args = frameCalls.first.arguments as Map<Object?, Object?>;
    final topBarColor = tester
        .widget<Material>(
          find
              .descendant(
                of: find.byType(WindowTitleBar),
                matching: find.byType(Material),
              )
              .first,
        )
        .color!;
    final argb = topBarColor.toARGB32();
    expect(args['r'], (argb >> 16) & 0xFF);
    expect(args['g'], (argb >> 8) & 0xFF);
    expect(args['b'], argb & 0xFF);
    expect(args['a'], (argb >> 24) & 0xFF);
    expect((argb >> 24) & 0xFF, lessThan(255));
  });
}
