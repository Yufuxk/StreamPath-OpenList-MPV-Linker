import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/connection_config.dart';
import 'package:streampath/presentation/pages/home_page.dart';

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
}
