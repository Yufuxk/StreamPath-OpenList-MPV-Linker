import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/theme/glass_tokens.dart';
import 'package:streampath/presentation/widgets/file_tile.dart';
import 'package:streampath/presentation/widgets/glass_surface.dart';

void main() {
  testWidgets('音频使用独立图标而非视频图标', (tester) async {
    const audio = WebDavFile(
      name: 'song.flac',
      href: '/song.flac',
      isDirectory: false,
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: FileTile(file: audio)),
      ),
    );

    expect(find.byIcon(Icons.audiotrack_outlined), findsOneWidget);
    expect(find.byIcon(Icons.movie_outlined), findsNothing);
  });

  Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(body: ListView(children: [child])),
  );

  group('FileTile 元数据显示', () {
    testWidgets('宽布局悬浮反馈使用未被纯色层遮挡的 Material', (tester) async {
      tester.view.physicalSize = const Size(900, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const directory = WebDavFile(
        name: 'Media',
        href: '/dav/Media/',
        isDirectory: true,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: const FileListSurface(
              child: Align(
                alignment: Alignment.topCenter,
                child: SizedBox(width: 800, child: FileTile(file: directory)),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final inkFinder = find.byType(InkWell);
      final ink = tester.widget<InkWell>(inkFinder);
      expect(ink.hoverColor, AppTheme.dark().hoverColor);

      var foundMaterial = false;
      var opaqueLayerBeforeMaterial = false;
      tester.element(inkFinder).visitAncestorElements((ancestor) {
        if (ancestor.widget is Material) {
          foundMaterial = true;
          return false;
        }
        if (ancestor.widget is ColoredBox) opaqueLayerBeforeMaterial = true;
        return true;
      });

      expect(foundMaterial, isTrue);
      expect(opaqueLayerBeforeMaterial, isFalse);
      final surface = tester.widget<GlassSurface>(
        find.descendant(
          of: find.byType(FileListSurface),
          matching: find.byType(GlassSurface),
        ),
      );
      expect(surface.level, GlassSurfaceLevel.content);
      final material = tester.widget<Material>(
        find.descendant(
          of: find.byType(GlassSurface),
          matching: find.byType(Material),
        ),
      );
      expect(material.type, MaterialType.transparency);
      expect(tester.takeException(), isNull);
    });

    testWidgets('宽窗口显示文件大小和修改时间', (tester) async {
      final file = WebDavFile(
        name: 'movie.mkv',
        href: '/dav/movie.mkv',
        isDirectory: false,
        size: 1073741824,
        modified: DateTime(2024, 1, 2, 3, 4, 5),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const FileListHeader(),
                FileTile(file: file),
              ],
            ),
          ),
        ),
      );

      expect(find.text('名称'), findsOneWidget);
      expect(find.text('修改时间'), findsOneWidget);
      expect(find.text('大小'), findsOneWidget);
      final header = tester.widget<Container>(
        find.byKey(const Key('file-list-header')),
      );
      expect(header.color, isNull);
      expect(header.decoration, isNull);
      expect(find.text('1.0 GB'), findsOneWidget);
      expect(find.text('2024-01-02 03:04:05'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('名称')).dx,
        tester.getTopLeft(find.byIcon(Icons.movie_outlined)).dx,
      );
      expect(
        tester.getTopRight(find.text('修改时间')).dx,
        tester.getTopRight(find.text('2024-01-02 03:04:05')).dx,
      );
      final tile = find.byKey(
        const ValueKey<String>('wide-file-tile-/dav/movie.mkv'),
      );
      expect(tester.getSize(tile).height, 56);
      expect(
        tester.getCenter(find.text('movie.mkv')).dy,
        tester.getCenter(tile).dy,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('宽窗口中的目录以短杠表示大小并显示修改时间', (tester) async {
      final directory = WebDavFile(
        name: 'Season 1',
        href: '/dav/Season%201/',
        isDirectory: true,
        modified: DateTime(2024, 5, 6, 7, 8, 9),
      );

      await tester.pumpWidget(wrap(FileTile(file: directory)));

      expect(find.text('-'), findsOneWidget);
      expect(find.text('0 B'), findsNothing);
      expect(find.text('2024-05-06 07:08:09'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('窄窗口中的目录只把时间放入副标题', (tester) async {
      final directory = WebDavFile(
        name: 'Season 1',
        href: '/dav/Season%201/',
        isDirectory: true,
        modified: DateTime(2024, 5, 6, 7, 8, 9),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 500, child: FileTile(file: directory)),
          ),
        ),
      );

      expect(find.text('2024-05-06 07:08:09'), findsOneWidget);
      expect(find.textContaining('目录'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('窄窗口中的普通文件显示大小和时间', (tester) async {
      final file = WebDavFile(
        name: 'movie.mkv',
        href: '/dav/movie.mkv',
        isDirectory: false,
        size: 1048576,
        modified: DateTime(2024, 5, 6, 7, 8, 9),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 500, child: FileTile(file: file)),
          ),
        ),
      );

      expect(find.text('1.0 MB · 2024-05-06 07:08:09'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('FileTile 单击行为', () {
    testWidgets('视频文件：单击触发播放回调', (tester) async {
      var taps = 0;
      final video = WebDavFile(
        name: '01.mp4',
        href: '/dav/01.mp4',
        isDirectory: false,
      );
      await tester.pumpWidget(wrap(FileTile(file: video, onTap: () => taps++)));

      await tester.tap(find.text('01.mp4'));
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
      await tester.pumpWidget(wrap(FileTile(file: dir, onTap: () => taps++)));

      await tester.tap(find.text('Season 1'));
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
      await tester.pumpWidget(wrap(FileTile(file: self, onTap: () => taps++)));

      await tester.tap(find.text('.'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(taps, 1);
    });
  });
}
