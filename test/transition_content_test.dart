import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/section_switcher.dart';
import 'package:streampath/presentation/widgets/transition_content.dart';

void main() {
  testWidgets('冷路由到静止帧之后才初始化正文，途中返回不启动加载', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    var starts = 0;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: AppTheme.dark().copyWith(platform: TargetPlatform.windows),
        home: const Scaffold(),
      ),
    );
    void open() => navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => StreamPathTransitionContent(
          shellBuilder: (_) => const StreamPathPageShell(),
          contentBuilder: (_) => _Probe(onInit: () => starts++),
        ),
      ),
    );
    open();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(starts, 0);
    expect(find.byType(StreamPathPageShell), findsOneWidget);
    final shell = find.descendant(
      of: find.byType(StreamPathPageShell),
      matching: find.byType(Scaffold),
    );
    expect(tester.widget<Scaffold>(shell).appBar, isNull);
    expect(tester.widget<Scaffold>(shell).body, isNull);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(starts, 0);
    open();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(starts, 0);
    await tester.pumpAndSettle();
    expect(starts, 1);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('局部切换合并最新目标，不初始化略过的分类，已访问页保留 State', (tester) async {
    final selected = ValueNotifier(0);
    addTearDown(selected.dispose);
    final starts = <int, int>{};
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<int>(
          valueListenable: selected,
          builder: (_, value, _) => StreamPathSectionSwitcher<int>(
            selected: value,
            order: const [0, 1, 2, 3],
            retainContent: true,
            shellBuilder: (_, section) => Text('shell-$section'),
            contentBuilder: (_, section) => _Probe(
              onInit: () =>
                  starts.update(section, (n) => n + 1, ifAbsent: () => 1),
            ),
          ),
        ),
      ),
    );
    expect(starts, {0: 1});
    selected.value = 1;
    await tester.pump();
    selected.value = 2;
    await tester.pump();
    selected.value = 3;
    await tester.pump();
    await tester.pumpAndSettle();
    expect(starts, {0: 1, 3: 1});
    selected.value = 0;
    await tester.pumpAndSettle();
    selected.value = 3;
    await tester.pumpAndSettle();
    expect(starts, {0: 1, 3: 1});
    expect(tester.takeException(), isNull);
  });

  testWidgets('运动中的异步展示通知合并，结束时提交最新值', (tester) async {
    final moving = ValueNotifier(false);
    final value = ValueNotifier(0);
    addTearDown(moving.dispose);
    addTearDown(value.dispose);
    var builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: moving,
          builder: (_, active, _) => StreamPathTransitionScope(
            isTransitioning: active,
            child: StreamPathTransitionBuilder(
              listenable: value,
              builder: (_) {
                builds++;
                return Text('value-${value.value}');
              },
            ),
          ),
        ),
      ),
    );
    moving.value = true;
    await tester.pump();
    final before = builds;
    for (var i = 1; i <= 10; i++) {
      value.value = i;
      await tester.pump();
    }
    expect(builds, before);
    expect(find.text('value-0'), findsOneWidget);
    moving.value = false;
    await tester.pump();
    expect(find.text('value-10'), findsOneWidget);
    expect(builds, before + 1);
  });
}

class _Probe extends StatefulWidget {
  const _Probe({required this.onInit});
  final VoidCallback onInit;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) => const Text('content');
}
