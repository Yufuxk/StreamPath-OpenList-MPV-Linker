import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/core/utils/file_sort.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/directory_file_list.dart';
import 'package:streampath/presentation/widgets/file_tile.dart';

void main() {
  for (final glass in [false, true]) {
    for (final dark in [false, true]) {
      for (final dpr in [1.0, 2.0]) {
        testWidgets('排序与时间还原的列表像素一致 glass=$glass dark=$dark dpr=$dpr', (
          tester,
        ) async {
          tester.view.devicePixelRatio = dpr;
          tester.view.physicalSize = Size(1000 * dpr, 700 * dpr);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          const frameKey = Key('directory-pixels');
          final originals = List.generate(
            80,
            (index) => WebDavFile(
              name: index % 3 == 0
                  ? '第${80 - index}集'
                  : 'Library_${80 - index}',
              href: '/dav/entry-$index',
              isDirectory: index % 4 == 0,
              size: index * 1024,
              modified: DateTime.utc(2026, 10, 9, 1, 2, index % 60),
            ),
          );
          // 对照原缓存的本地时间还原与逐项排序。
          final reference =
              originals
                  .map(
                    (file) => WebDavFile(
                      name: file.name,
                      href: file.href,
                      isDirectory: file.isDirectory,
                      size: file.size,
                      modified: DateTime.fromMillisecondsSinceEpoch(
                        file.modified!.millisecondsSinceEpoch,
                      ),
                    ),
                  )
                  .toList()
                ..sort(compareMediaEntries);
          final optimized = sortedWebDavFiles(
            originals.map((file) => WebDavFile.fromCacheMap(file.toCacheMap())),
          );
          final theme =
              (dark
                      ? AppTheme.dark(glass: glass)
                      : AppTheme.light(glass: glass))
                  .copyWith(platform: TargetPlatform.windows);

          Future<List<int>> render(
            List<WebDavFile> entries,
            double offset,
          ) async {
            final controller = ScrollController();
            await tester.pumpWidget(
              MaterialApp(
                theme: theme,
                home: RepaintBoundary(
                  key: frameKey,
                  child: Scaffold(
                    body: DirectoryFileList(
                      entries: entries,
                      controller: controller,
                      scrollKey: UniqueKey(),
                      onRefresh: () async {},
                      itemBuilder: (_, entry, _) =>
                          FileTile(file: entry, onTap: () {}),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            controller.jumpTo(offset);
            await tester.pumpAndSettle();
            final pixels = (await tester.runAsync(() async {
              final image = await tester
                  .renderObject<RenderRepaintBoundary>(find.byKey(frameKey))
                  .toImage(pixelRatio: dpr);
              final data = (await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
              final bytes = data.buffer.asUint8List().toList();
              image.dispose();
              return bytes;
            }))!;
            await tester.pumpWidget(const SizedBox.shrink());
            controller.dispose();
            return pixels;
          }

          for (final offset in [0.0, 600.0]) {
            final before = await render(reference, offset);
            final after = await render(optimized, offset);
            expect(listEquals(before, after), isTrue, reason: 'scroll=$offset');
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
