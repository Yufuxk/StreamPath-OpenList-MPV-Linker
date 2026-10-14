import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/cinematic_states.dart';
import 'package:streampath/presentation/widgets/directory_scroll_view.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';

void main() {
  testWidgets('hover moves only the poster through interruption and return', (
    tester,
  ) async {
    const poster = Key('poster'), title = Key('title'), card = Key('card');
    final pixels = GlobalKey();
    Future<void> frame(bool hovered) => tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Center(
          child: SizedBox(
            key: card,
            width: 180,
            height: 300,
            child: FilmPosterHover(
              hovered: hovered,
              child: Column(
                children: [
                  const FilmPosterHoverSurface(
                    child: SizedBox(
                      key: poster,
                      width: 180,
                      height: 240,
                      child: ColoredBox(color: Colors.white),
                    ),
                  ),
                  const SizedBox(height: 12),
                  RepaintBoundary(
                    key: pixels,
                    child: const Text(
                      '影片名称 · 2026',
                      key: title,
                      style: TextStyle(fontSize: 14, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await frame(false);
    final originalPoster = tester.getRect(find.byKey(poster));
    final originalTitle = tester.getRect(find.byKey(title));
    final originalCard = tester.getRect(find.byKey(card));
    Future<List<int>> caption() async {
      final result = await tester.runAsync(() async {
        final image =
            await (pixels.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        image.dispose();
        return bytes!.buffer.asUint8List().toList();
      });
      return result!;
    }

    final originalPixels = await caption();
    await frame(true);
    for (var i = 0; i < 13; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getRect(find.byKey(title)), originalTitle);
      expect(tester.getRect(find.byKey(card)), originalCard);
      expect(await caption(), originalPixels);
    }
    final enlarged = tester.getRect(find.byKey(poster));
    expect(enlarged.width, closeTo(originalPoster.width * 1.05, .001));
    expect(enlarged.center.dy, closeTo(originalPoster.center.dy - 6, .001));
    await frame(false);
    await tester.pump(const Duration(milliseconds: 64));
    final interrupted = tester.getRect(find.byKey(poster));
    await frame(true);
    expect(tester.getRect(find.byKey(poster)), interrupted);
    await tester.pump(const Duration(milliseconds: 200));
    await frame(false);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getRect(find.byKey(poster)), originalPoster);
    expect(tester.getRect(find.byKey(title)), originalTitle);
  });

  testWidgets('edge fades follow overflow, scroll ends and viewport resize', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    Future<void> frame(double width, {bool reverse = false}) =>
        tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark(),
            home: Center(
              child: SizedBox(
                width: width,
                height: 100,
                child: DirectoryScrollView(
                  scrollDirection: Axis.horizontal,
                  controller: controller,
                  hideScrollbar: true,
                  builder: (scroll) => ListView(
                    controller: scroll,
                    reverse: reverse,
                    scrollDirection: Axis.horizontal,
                    children: const [SizedBox(width: 600)],
                  ),
                ),
              ),
            ),
          ),
        );
    List<double> fades() {
      final end = tester
          .widget<TweenAnimationBuilder<Offset>>(
            find.byWidgetPredicate((w) => w is TweenAnimationBuilder<Offset>),
          )
          .tween
          .end!;
      return [end.dx, end.dy];
    }

    await frame(300);
    await tester.pumpAndSettle();
    expect(fades(), [0, 1]);
    controller.jumpTo(150);
    await tester.pumpAndSettle();
    expect(fades(), [1, 1]);
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(fades(), [1, 0]);
    await frame(700);
    await tester.pumpAndSettle();
    expect(fades(), [0, 0]);
    await frame(300, reverse: true);
    controller.jumpTo(0);
    await tester.pumpAndSettle();
    expect(fades(), [1, 0]);
  });

  testWidgets('skeleton pulses without relayout and honors reduced motion', (
    tester,
  ) async {
    const key = Key('skeleton');
    Future<void> frame(bool reduced) => tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: const Center(
            child: SizedBox(
              width: 200,
              height: 300,
              child: CinematicSkeleton(key: key),
            ),
          ),
        ),
      ),
    );
    await frame(false);
    final original = tester.getRect(find.byKey(key));
    BoxDecoration decoration() =>
        tester
                .widget<DecoratedBox>(
                  find
                      .descendant(
                        of: find.byKey(key),
                        matching: find.byType(DecoratedBox),
                      )
                      .first,
                )
                .decoration
            as BoxDecoration;
    final initial = (decoration().gradient! as LinearGradient).colors[1].a;
    await tester.pump(const Duration(milliseconds: 900));
    expect(
      (decoration().gradient! as LinearGradient).colors[1].a,
      greaterThan(initial),
    );
    expect(tester.getRect(find.byKey(key)), original);
    expect(
      (decoration().gradient! as LinearGradient).colors.first.a,
      closeTo(.45, .001),
    );
    await frame(true);
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets(
    'empty states fit narrow views and enlarged text in every language',
    (tester) async {
      for (final brightness in Brightness.values) {
        for (final language in AppLanguage.values) {
          await tester.pumpWidget(
            MaterialApp(
              theme: brightness == Brightness.dark
                  ? AppTheme.dark()
                  : AppTheme.light(),
              locale: switch (language) {
                AppLanguage.simplifiedChinese => const Locale('zh', 'CN'),
                AppLanguage.traditionalChinese => const Locale('zh', 'TW'),
                AppLanguage.japanese => const Locale('ja'),
                AppLanguage.english => const Locale('en'),
              },
              supportedLocales: const [
                Locale('zh', 'CN'),
                Locale('zh', 'TW'),
                Locale('ja'),
                Locale('en'),
              ],
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              home: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                child: Center(
                  child: SizedBox(
                    width: 320,
                    height: 450,
                    child: DirectoryScrollView(
                      builder: (controller) => SingleChildScrollView(
                        controller: controller,
                        child: const ImmersiveEmptyState(
                          icon: Icons.folder_outlined,
                          title: '暂无播放列表',
                          description: '右键作品或单集封面，创建你的第一个播放列表。',
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.text(AppLocalizations(language).text('暂无播放列表')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          if (brightness == Brightness.dark) {
            expect(find.byType(BackdropFilter), findsOneWidget);
          }
        }
      }
    },
  );

  test('scrollbar stays six pixels while the thumb highlights', () {
    final theme = AppTheme.dark().scrollbarTheme;
    for (final states in [
      <WidgetState>{},
      {WidgetState.hovered},
      {WidgetState.dragged},
    ]) {
      expect(theme.thickness!.resolve(states), 6);
      expect(
        theme.thumbColor!.resolve(states)!.a,
        closeTo(states.isEmpty ? .15 : .3, .001),
      );
    }
  });
}
