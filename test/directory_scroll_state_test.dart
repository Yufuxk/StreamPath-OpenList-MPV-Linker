import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/controllers/directory_scroll_state.dart';

void main() {
  testWidgets('目录滚动状态按缓存键恢复原位置', (tester) async {
    final state = DirectoryScrollState(
      maxEntries: 8,
      idleTtl: const Duration(minutes: 30),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 240,
          child: ListView(
            controller: state.controller,
            children: List.generate(
              30,
              (index) => SizedBox(height: 48, child: Text('row-$index')),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    state.controller.jumpTo(360);
    state.remember('folder-a');
    state.controller.jumpTo(0);
    state.scheduleRestore(key: 'folder-a', isCurrent: () => true);
    await tester.pump();

    expect(state.controller.offset, closeTo(360, 0.5));
  });
}
