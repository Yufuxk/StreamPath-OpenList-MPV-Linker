import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/presentation/widgets/file_tile.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        home: Scaffold(body: ListView(children: [child])),
      );

  group('FileTile 单击行为', () {
    testWidgets('视频文件：单击触发播放回调', (tester) async {
      var taps = 0;
      final video = WebDavFile(
        name: '01.mp4',
        href: '/dav/01.mp4',
        isDirectory: false,
      );
      await tester.pumpWidget(wrap(FileTile(
        file: video,
        onTap: () => taps++,
      )));

      await tester.tap(find.byType(ListTile));
      await tester.pump(const Duration(milliseconds: 100));
      expect(taps, 1, reason: '视频单击直接触发播放');
    });

    testWidgets('目录文件：单击正常触发 onTap', (tester) async {
      var taps = 0;
      final dir = WebDavFile(
        name: 'Season 1',
        href: '/dav/Season%201',
        isDirectory: true,
      );
      await tester.pumpWidget(wrap(FileTile(
        file: dir,
        onTap: () => taps++,
      )));

      await tester.tap(find.byType(ListTile));
      await tester.pump(const Duration(milliseconds: 100));
      expect(taps, 1, reason: '目录单击进入');
    });

    testWidgets('「返回上级」条目：单击正常触发', (tester) async {
      var taps = 0;
      final self = WebDavFile(
        name: '.',
        href: '/dav/',
        isDirectory: true,
        isSelfEntry: true,
      );
      await tester.pumpWidget(wrap(FileTile(
        file: self,
        onTap: () => taps++,
      )));

      await tester.tap(find.byType(ListTile));
      await tester.pump(const Duration(milliseconds: 100));
      expect(taps, 1);
    });
  });
}
