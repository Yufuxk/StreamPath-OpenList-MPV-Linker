import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/media_directory_entry.dart';
import 'package:streampath/presentation/widgets/directory_file_grid.dart';

void main() {
  testWidgets('平铺浏览的上级入口保留导航且不占文件卡片', (tester) async {
    const parent = LocalMediaEntry(
      name: '上级目录',
      relativePath: '',
      absolutePath: r'C:\media',
      isDirectory: true,
      isSelfEntry: true,
    );
    const folder = LocalMediaEntry(
      name: 'MusicLibrary',
      relativePath: 'MusicLibrary',
      absolutePath: r'C:\media\MusicLibrary',
      isDirectory: true,
    );
    MediaDirectoryEntry? opened;
    final builtIndices = <int>[];
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 500,
            child: DirectoryFileGrid(
              entries: const [parent, folder],
              controller: controller,
              scrollKey: const Key('grid-scroll'),
              onRefresh: () async {},
              emptyLabel: '空目录',
              onParentTap: (entry) => opened = entry,
              refreshing: false,
              itemBuilder: (_, entry, index) {
                builtIndices.add(index);
                return Text(entry.name);
              },
            ),
          ),
        ),
      ),
    );

    expect(find.text('返回上级目录'), findsOneWidget);
    expect(find.text('MusicLibrary'), findsOneWidget);
    expect(builtIndices, contains(1));
    expect(builtIndices, isNot(contains(0)));
    await tester.tap(find.text('返回上级目录'));
    expect(opened, same(parent));
  });
}
