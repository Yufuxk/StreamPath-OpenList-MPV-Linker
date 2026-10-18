import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/cinematic_states.dart';
import 'package:streampath/presentation/widgets/skeleton_scope.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';

void main() {
  Widget frame({
    bool ready = true,
    bool assetReady = true,
    bool enabled = true,
    bool disabledAnimations = false,
    Widget? content,
  }) => MaterialApp(
    theme: AppTheme.dark(),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disabledAnimations),
      child: SkeletonScope(
        ready: ready,
        enabled: enabled,
        child: Center(
          child: SkeletonLoadBoundary(
            ready: assetReady,
            child: SkeletonRegion(
              child: content ?? const SizedBox(width: 240, height: 90),
            ),
          ),
        ),
      ),
    ),
  );

  Finder skeleton() => find.byType(CinematicSkeleton);

  testWidgets('缓存命中仍保留最短展示时间并淡入，真实布局和 State 不变', (tester) async {
    final content = _StateProbe(key: GlobalKey());
    await tester.pumpWidget(frame(content: content));
    final state = tester.state(find.byType(_StateProbe));
    final rect = tester.getRect(find.byType(_StateProbe));
    expect(tester.getRect(skeleton()), rect);
    await tester.pump(const Duration(milliseconds: 699));
    expect(skeleton(), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(skeleton(), findsOneWidget);
    final opacity = tester
        .widget<Opacity>(
          find.ancestor(
            of: find.byType(_StateProbe),
            matching: find.byType(Opacity),
          ),
        )
        .opacity;
    expect(opacity, inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 120));
    expect(skeleton(), findsNothing);
    expect(tester.state(find.byType(_StateProbe)), same(state));
    expect(tester.getRect(find.byType(_StateProbe)), rect);
  });

  testWidgets('资料及图片分别门控，晚到的图片不会提前露出正文', (tester) async {
    await tester.pumpWidget(frame(ready: false, assetReady: false));
    await tester.pump(const Duration(seconds: 2));
    expect(skeleton(), findsOneWidget);
    await tester.pumpWidget(frame(assetReady: false));
    await tester.pump(const Duration(milliseconds: 300));
    expect(skeleton(), findsOneWidget);
    await tester.pumpWidget(frame());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    expect(skeleton(), findsNothing);
  });

  testWidgets('切页运动门控，已显示正文刷新或返回不重新进入骨架', (tester) async {
    await tester.pumpWidget(frame(enabled: false));
    await tester.pump(const Duration(seconds: 1));
    expect(skeleton(), findsOneWidget);
    await tester.pumpWidget(frame());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    expect(skeleton(), findsNothing);
    await tester.pumpWidget(
      frame(ready: false, assetReady: false, enabled: false),
    );
    await tester.pump();
    expect(skeleton(), findsNothing);
  });

  testWidgets('占位期间屏蔽命中和正文语义，揭示后恢复操作', (tester) async {
    var taps = 0;
    final semantics = tester.ensureSemantics();
    final button = TextButton(
      onPressed: () => taps++,
      child: const Text('Action'),
    );
    await tester.pumpWidget(frame(content: button));
    await tester.tap(find.text('Action'), warnIfMissed: false);
    expect(taps, 0);
    expect(find.bySemanticsLabel('Action'), findsNothing);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    await tester.tap(find.text('Action'));
    expect(taps, 1);
    expect(find.bySemanticsLabel('Action'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('关闭动画保留阅读停留时间，随后直接显示静态内容', (tester) async {
    await tester.pumpWidget(frame(disabledAnimations: true));
    await tester.pump(const Duration(milliseconds: 699));
    expect(skeleton(), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(skeleton(), findsNothing);
  });

  testWidgets('提前离开释放计时器，移除未完成图片解除等待', (tester) async {
    await tester.pumpWidget(frame(assetReady: false));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);

    final showAsset = ValueNotifier(true);
    await tester.pumpWidget(
      MaterialApp(
        home: SkeletonScope(
          ready: true,
          child: ValueListenableBuilder<bool>(
            valueListenable: showAsset,
            builder: (_, show, _) => Column(
              children: [
                if (show)
                  const SkeletonLoadBoundary(ready: false, child: SizedBox()),
                const SkeletonRegion(child: SizedBox(width: 200, height: 30)),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 700));
    expect(skeleton(), findsOneWidget);
    showAsset.value = false;
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    expect(skeleton(), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    showAsset.dispose();
  });

  for (final fail in [false, true]) {
    testWidgets('FilmArtwork ${fail ? '失败后显示原重试入口' : '文件及解码首帧就绪前保持占位'}', (
      tester,
    ) async {
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('skeleton-artwork-'),
      ))!;
      final tmdb = TmdbMetadataService();
      final cache = _DelayedCache(directory, tmdb);
      await tester.pumpWidget(
        frame(
          content: FilmArtwork(
            cache: cache,
            path: '/logo.png',
            transparent: true,
            width: 420,
            height: 90,
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2));
      expect(skeleton(), findsOneWidget);
      if (fail) {
        cache.file.completeError(
          const FileSystemException('Fixture read failed'),
        );
      } else {
        final file = await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawRect(
            const Rect.fromLTWH(0, 0, 16, 16),
            Paint()..color = Colors.blue,
          );
          final picture = recorder.endRecording();
          final image = await picture.toImage(16, 16);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = await File(
            '${directory.path}/logo.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
          picture.dispose();
          return file;
        });
        cache.file.complete(file);
      }
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 240));
      expect(skeleton(), findsNothing);
      if (fail) {
        expect(find.byTooltip('重试图片'), findsOneWidget);
      } else {
        expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      cache.close();
      tmdb.close();
      await tester.runAsync(() => directory.delete(recursive: true));
    });
  }
}

class _DelayedCache extends FilmCatalogImageCache {
  _DelayedCache(super.directory, super.tmdb);
  final file = Completer<File>();
  @override
  Future<File> get(String path, {String target = 'w342'}) => file.future;
}

class _StateProbe extends StatefulWidget {
  const _StateProbe({super.key});
  @override
  State<_StateProbe> createState() => _StateProbeState();
}

class _StateProbeState extends State<_StateProbe> {
  @override
  Widget build(BuildContext context) => const SizedBox(width: 240, height: 90);
}
