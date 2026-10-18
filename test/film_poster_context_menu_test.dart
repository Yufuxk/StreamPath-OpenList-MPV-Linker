import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';
import 'package:streampath/presentation/widgets/sp_menu.dart';

void main() {
  for (final openOnDown in [true, false]) {
    for (final select in [true, false]) {
      testWidgets(
        'poster holds hover until menu closes: down=$openOnDown select=$select',
        (tester) async {
          String? result;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) {
                    Future<void> menu(TapDownDetails details) async {
                      final point = details.globalPosition;
                      result = await showSPMenu<String>(
                        context: context,
                        position: RelativeRect.fromRect(
                          point & Size.zero,
                          Offset.zero & MediaQuery.sizeOf(context),
                        ),
                        items: const [
                          PopupMenuItem(
                            value: 'selected',
                            child: Text('Action'),
                          ),
                        ],
                      );
                    }

                    final poster = FilmPosterHover(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onSecondaryTapUp: openOnDown
                            ? null
                            : (details) => menu(
                                TapDownDetails(
                                  globalPosition: details.globalPosition,
                                ),
                              ),
                        child: const FilmPosterHoverSurface(
                          child: SizedBox(width: 160, height: 240),
                        ),
                      ),
                    );
                    return Padding(
                      padding: const EdgeInsets.all(40),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          GestureDetector(
                            onSecondaryTapDown: openOnDown ? menu : null,
                            child: poster,
                          ),
                          const SizedBox(width: 40),
                          const FilmPosterHover(
                            child: FilmPosterHoverSurface(
                              child: SizedBox(width: 160, height: 240),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          );
          final transforms = find.byWidgetPredicate(
            (widget) => widget is Transform && !widget.transformHitTests,
          );
          double scale(int index) => tester
              .widget<Transform>(transforms.at(index))
              .transform
              .entry(0, 0);
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: const Offset(10, 10));
          await mouse.moveTo(const Offset(100, 100));
          await tester.pumpAndSettle();
          expect(scale(0), AppTheme.posterHoverScale);
          expect(scale(1), 1);

          await tester.tapAt(
            const Offset(100, 100),
            buttons: kSecondaryMouseButton,
          );
          await tester.pumpAndSettle();
          await mouse.moveTo(const Offset(700, 500));
          await tester.pumpAndSettle();
          expect(find.text('Action'), findsOneWidget);
          expect(scale(0), AppTheme.posterHoverScale);
          expect(scale(1), 1);

          if (select) {
            await tester.tap(find.text('Action'));
          } else {
            await tester.tapAt(const Offset(700, 500));
          }
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 80));
          expect(scale(0), greaterThan(1));
          expect(scale(0), lessThan(AppTheme.posterHoverScale));
          await tester.pumpAndSettle();
          expect(scale(0), 1);
          expect(result, select ? 'selected' : isNull);
          expect(spMenuAnchor.value, isNull);
          await mouse.removePointer();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
