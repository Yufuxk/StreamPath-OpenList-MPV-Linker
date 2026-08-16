import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/theme/page_transitions.dart';

void main() {
  testWidgets('Windows 页面切换只淡化且不缩放旧页面', (tester) async {
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
      find.byKey(StreamPathPageTransitionsBuilder.incomingFadeKey),
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
