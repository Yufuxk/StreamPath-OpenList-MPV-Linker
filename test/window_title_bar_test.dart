import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/sp_icons.dart';
import 'package:streampath/presentation/widgets/window_title_bar.dart';

void main() {
  testWidgets('窗口关闭等待后台任务完成后回复原生', (tester) async {
    final finished = Completer<void>();
    var replied = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WindowTitleBar(onCloseRequested: () => finished.future),
        ),
      ),
    );
    final response = TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger
        .handlePlatformMessage(
          'streampath/appearance',
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('closeRequested'),
          ),
          null,
        )
        .then((_) => replied = true);
    await tester.pump();
    expect(replied, false);
    finished.complete();
    await response;
    expect(replied, true);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('标题栏销毁后注销原生回调', (tester) async {
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: WindowTitleBar())),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    final reply = await messenger.handlePlatformMessage(
      'streampath/appearance',
      codec.encodeMethodCall(const MethodCall('maximizeChanged', true)),
      null,
    );
    expect(reply, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('旧标题栏销毁不注销新标题栏原生回调', (tester) async {
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Widget frame(bool old) => MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            if (old) const WindowTitleBar(key: ValueKey('old')),
            const WindowTitleBar(key: ValueKey('new')),
          ],
        ),
      ),
    );
    await tester.pumpWidget(frame(true));
    await tester.pumpWidget(frame(false));
    final reply = await messenger.handlePlatformMessage(
      'streampath/appearance',
      codec.encodeMethodCall(const MethodCall('maximizeChanged', true)),
      null,
    );
    expect(reply, isNotNull);
    await tester.pump();
    expect(find.byTooltip('还原'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(
      await messenger.handlePlatformMessage(
        'streampath/appearance',
        codec.encodeMethodCall(const MethodCall('maximizeChanged', false)),
        null,
      ),
      isNull,
    );
  });
  testWidgets('全屏按钮、F11 和 Escape 同步原生状态且保留原控制', (tester) async {
    const channel = MethodChannel('streampath/appearance');
    var fullscreen = false;
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'toggleFullscreen') {
            return fullscreen = !fullscreen;
          }
          if (call.method == 'isFullscreen') return fullscreen;
          if (call.method == 'isMaximized') return false;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: const WindowTitleBar())),
    );
    await tester.pump();
    await tester.tap(find.byKey(WindowTitleBar.fullscreenButtonKey));
    await tester.pump();
    expect(fullscreen, isTrue);
    expect(find.byTooltip('退出全屏'), findsNWidgets(2));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(fullscreen, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    expect(fullscreen, isTrue);
    await tester.tap(find.byKey(WindowTitleBar.maximizeButtonKey));
    await tester.pump();
    expect(fullscreen, isFalse);
    expect(calls.where((c) => c == 'toggleFullscreen'), hasLength(4));
    expect(calls, isNot(contains('toggleMaximize')));
    expect(tester.takeException(), isNull);
  });
  Widget wrap(Widget child, {ThemeData? theme}) {
    return MaterialApp(
      theme: theme ?? AppTheme.light(),
      home: Scaffold(body: child),
    );
  }

  testWidgets('详情标题栏在所有滚动位置保持透明并保留窗口控件', (tester) async {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      for (final progress in [0.0, 0.5, 1.0]) {
        await tester.pumpWidget(
          wrap(WindowTitleBar(detailScrollProgress: progress), theme: theme),
        );
        await tester.pump();
        final material = tester.widget<Material>(
          find.byKey(WindowTitleBar.mainSurfaceKey),
        );
        expect(material.color!.a, 0);
        expect(find.byType(BackdropFilter), findsNothing);
        expect(
          tester.getRect(find.byKey(WindowTitleBar.mainSurfaceKey)).left,
          0,
        );
        expect(find.byKey(WindowTitleBar.closeButtonKey), findsOneWidget);
        expect(find.byKey(WindowTitleBar.minimizeButtonKey), findsOneWidget);
        expect(find.byKey(WindowTitleBar.maximizeButtonKey), findsOneWidget);
        expect(find.byKey(WindowTitleBar.fullscreenButtonKey), findsOneWidget);
        expect(find.byKey(WindowTitleBar.sidebarSurfaceKey), findsNothing);
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('标题栏保留窗口控制按钮且不显示应用标识', (tester) async {
    await tester.pumpWidget(wrap(const WindowTitleBar()));

    expect(find.text('StreamPath'), findsNothing);
    expect(find.byIcon(SPIcons.folder), findsNothing);
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
      expect(glyph.style?.color, AppTheme.light().colorScheme.onSurfaceVariant);
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
      find.byKey(WindowTitleBar.mainSurfaceKey),
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
      find.byKey(WindowTitleBar.mainSurfaceKey),
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
        .widget<Material>(find.byKey(WindowTitleBar.mainSurfaceKey))
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
        .widget<Material>(find.byKey(WindowTitleBar.mainSurfaceKey))
        .color!;
    final argb = topBarColor.toARGB32();
    expect(args['r'], (argb >> 16) & 0xFF);
    expect(args['g'], (argb >> 8) & 0xFF);
    expect(args['b'], argb & 0xFF);
    expect(args['a'], (argb >> 24) & 0xFF);
    expect((argb >> 24) & 0xFF, lessThan(255));
  });
}
