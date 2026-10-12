import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/directory_scroll_view.dart';
import 'package:streampath/presentation/widgets/film_detail_back_button.dart';
import 'package:streampath/presentation/widgets/sp_back_icon.dart';

Widget frame(Widget child, {ThemeData? theme}) => MaterialApp(
  theme: theme ?? AppTheme.dark(),
  locale: const Locale('zh', 'CN'),
  supportedLocales: const [Locale('zh', 'CN')],
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  home: child,
);

void main() {
  testWidgets('自动返回按钮复用圆角矢量图标，点击仍返回原页面', (tester) async {
    for (final theme in [
      AppTheme.light(),
      AppTheme.dark(),
      AppTheme.light(glass: true),
      AppTheme.dark(glass: true),
    ]) {
      await tester.pumpWidget(
        frame(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) =>
                        Scaffold(appBar: AppBar(title: const Text('Detail'))),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
          theme: theme,
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(SPBackIcon), findsOneWidget);
      expect(tester.getSize(find.byType(SPBackIcon)), const Size(24, 24));
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Open'), findsOneWidget);
    }
  });

  testWidgets('详情返回按钮空闲隐藏，真实滚轮与附近悬停显示，只改变透明度', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      frame(
        Scaffold(
          body: Stack(
            children: [
              DirectoryScrollView(
                controller: scroll,
                builder: (controller) => ListView(
                  controller: controller,
                  children: [
                    for (var i = 0; i < 40; i++)
                      SizedBox(height: 80, child: Text('$i')),
                  ],
                ),
              ),
              Positioned(
                top: 22,
                left: 4,
                child: FilmDetailBackButton(scrollController: scroll),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final fade = find.descendant(
      of: find.byType(FilmDetailBackButton),
      matching: find.byType(AnimatedOpacity),
    );
    double opacity() => tester.widget<AnimatedOpacity>(fade).opacity;
    final button = find.byKey(const Key('film-detail-back'));
    final originalRect = tester.getRect(button);
    expect(opacity(), 0);
    expect(
      tester
          .widget<IgnorePointer>(
            find.descendant(of: fade, matching: find.byType(IgnorePointer)),
          )
          .ignoring,
      isTrue,
    );
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(300, 300),
        scrollDelta: Offset(0, 80),
      ),
    );
    await tester.pump();
    expect(scroll.offset, greaterThan(0));
    expect(opacity(), 1);
    await tester.pump(const Duration(milliseconds: 90));
    final renderFade = tester.renderObject<RenderAnimatedOpacity>(
      find.descendant(of: fade, matching: find.byType(FadeTransition)),
    );
    expect(renderFade.opacity.value, allOf(greaterThan(0), lessThan(1)));
    await tester.pump(const Duration(milliseconds: 700));
    expect(opacity(), 0);
    await tester.pump(const Duration(milliseconds: 180));
    expect(tester.getRect(button), originalRect);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(300, 300));
    final region = tester.getRect(
      find.byKey(const Key('film-detail-back-region')),
    );
    await mouse.moveTo(region.topLeft + const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(opacity(), 1);
    await mouse.moveTo(const Offset(300, 300));
    await tester.pump();
    expect(opacity(), 0);
    await tester.pump(const Duration(milliseconds: 180));
    expect(tester.getRect(button), originalRect);
    Focus.of(tester.element(button)).requestFocus();
    await tester.pumpAndSettle();
    expect(opacity(), 1);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('矢量返回图标支持多种像素比例并输出清晰度预览', (tester) async {
    await tester.pumpWidget(
      frame(
        Center(
          child: RepaintBoundary(
            key: const Key('icons'),
            child: ColoredBox(
              color: const Color(0xFF202A31),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final size in [20.0, 24.0, 32.0])
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: IconTheme(
                        data: IconThemeData(color: Colors.white, size: size),
                        child: const SPBackIcon(),
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
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('icons')),
    );
    for (final ratio in [1.0, 1.25, 1.5, 2.0]) {
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: ratio);
        expect(image.width, (boundary.size.width * ratio).ceil());
        final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        image.dispose();
        final file = File('build/back-icons/icons-$ratio.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data.buffer.asUint8List());
      });
    }
    expect(tester.takeException(), isNull);
  });
}
