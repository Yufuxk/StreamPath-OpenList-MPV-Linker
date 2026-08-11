import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/presentation/widgets/directory_wheel_scroll_region.dart';

void main() {
  testWidgets('列表被命中层覆盖时，目录区域仍可把滚轮交给显式控制器', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectoryWheelScrollRegion(
            controller: controller,
            child: Stack(
              key: const ValueKey('covered-directory'),
              fit: StackFit.expand,
              children: [
                ListView.builder(
                  controller: controller,
                  itemCount: 100,
                  itemBuilder: (_, index) =>
                      ListTile(title: Text('item $index')),
                ),
                const ColoredBox(color: Color(0x01000000)),
              ],
            ),
          ),
        ),
      ),
    );

    expect(controller.offset, 0);
    final location = tester.getCenter(
      find.byKey(const ValueKey('covered-directory')),
    );
    final pointer = TestPointer(1, ui.PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(location));
    await tester.sendEventToBinding(
      PointerScrollEvent(position: location, scrollDelta: const Offset(0, 120)),
    );
    await tester.pump();

    expect(controller.offset, greaterThan(0));
  });

  testWidgets('正常列表自行接管滚轮时不会被兜底重复滚动', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectoryWheelScrollRegion(
            controller: controller,
            child: ListView.builder(
              controller: controller,
              itemCount: 100,
              itemBuilder: (_, index) => ListTile(title: Text('item $index')),
            ),
          ),
        ),
      ),
    );

    final location = tester.getCenter(find.byType(ListView));
    final pointer = TestPointer(1, ui.PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(location));
    await tester.sendEventToBinding(
      PointerScrollEvent(position: location, scrollDelta: const Offset(0, 120)),
    );
    await tester.pump();

    expect(controller.offset, 120);
  });
}
