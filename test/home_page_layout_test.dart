import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/connection_config.dart';
import 'package:streampath/presentation/pages/home_page.dart';
import 'package:streampath/presentation/theme/app_theme.dart';

void main() {
  testWidgets('返回登录页时首帧直接显示已保存配置且标签位置稳定', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: HomePage(
          initialConnection: ConnectionConfig(
            baseUrl: 'https://example.com/dav',
            username: 'saved-user',
          ),
        ),
      ),
    );

    final fields = tester
        .widgetList<TextFormField>(find.byType(TextFormField))
        .toList(growable: false);
    expect(fields, hasLength(3));
    expect(fields.map((field) => field.controller!.text), [
      'https://example.com/dav',
      'saved-user',
      '',
    ]);
    expect(find.byIcon(Icons.route_outlined), findsNothing);
    expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

    final labelFinders = [
      find.text('服务器地址'),
      find.text('用户名'),
      find.text('密码'),
    ];
    final initialLabelPositions = labelFinders
        .map(tester.getTopLeft)
        .toList(growable: false);

    await tester.pump(const Duration(milliseconds: 50));

    for (var index = 0; index < labelFinders.length; index++) {
      expect(
        tester.getTopLeft(labelFinders[index]),
        initialLabelPositions[index],
        reason: '已填入文本的标签不应在登录页出现后继续从输入框内向上移动',
      );
    }
  });

  testWidgets('登录页在宽窄窗口下均保持可用布局', (tester) async {
    Future<void> pumpAt(Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const HomePage(
            initialConnection: ConnectionConfig(
              baseUrl: 'https://example.com/dav',
              username: 'saved-user',
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('直接浏览，顺畅播放'), findsNothing);
      expect(find.text('连接服务器'), findsOneWidget);
      expect(find.byType(TextFormField), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    }

    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpAt(const Size(1200, 800));
    await pumpAt(const Size(520, 720));
  });
}
