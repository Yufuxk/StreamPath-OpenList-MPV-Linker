import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/appearance_config.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/presentation/pages/app_shell_page.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/theme/glass_tokens.dart';
import 'package:streampath/presentation/widgets/window_title_bar.dart';
import 'package:streampath/presentation/widgets/glass_surface.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  testWidgets('侧边栏保留本地浏览页并显示本地根目录递归大小', (tester) async {
    final temporaryDirectory = Directory.systemTemp.createTempSync(
      'streampath_storage_root_',
    );
    final mediaDirectory = Directory(p.join(temporaryDirectory.path, 'Media'))
      ..createSync();
    final nested = Directory(p.join(mediaDirectory.path, 'Series'))
      ..createSync();
    File(
      p.join(nested.path, 'episode.mp4'),
    ).writeAsBytesSync(List<int>.filled(1536, 0));
    final configStore = StreamPathConfigStore.forPath(
      p.join(temporaryDirectory.path, 'config.json'),
    );
    late PlaybackProgressService progress;
    await tester.runAsync(() async {
      await configStore.save(
        StreamPathConfig(
          localRoots: [
            LocalRootConfig(
              rootId: 'root-test',
              displayName: '本地影视',
              path: mediaDirectory.path,
            ),
          ],
        ),
      );
      progress = await PlaybackProgressService.open(
        inMemoryDatabasePath,
        factory: databaseFactoryFfi,
        legacyProfileId: 'legacy',
      );
    });
    final appState = AppState(
      configStore: configStore,
      playbackHistoryStore: PlaybackHistoryStore.forPath(
        p.join(temporaryDirectory.path, 'history.json'),
      ),
      progressService: progress,
    );
    addTearDown(() async {
      appState.dispose();
      await tester.runAsync(() async {
        await progress.close();
        if (temporaryDirectory.existsSync()) {
          temporaryDirectory.deleteSync(recursive: true);
        }
      });
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: appState,
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Consumer<AppState>(
                  builder: (context, app, _) => WindowTitleBar(
                    sidebarMode: app.configStore.current.appearance.sidebarMode,
                    sidebarRevealProgress: app.sidebarRevealProgress,
                  ),
                ),
                const Expanded(child: AppShellPage()),
              ],
            ),
          ),
        ),
      ),
    );

    for (final section in [
      'network',
      'local',
      'library',
      'mounts',
      'search',
      'settings',
    ]) {
      expect(find.byKey(Key('sidebar-$section')), findsOneWidget);
    }
    Finder pageTitle(String text) =>
        find.descendant(of: find.byType(AppBar), matching: find.text(text));
    final localTitle = pageTitle('本地文件夹');
    final localTitlePosition = tester.getTopLeft(localTitle);
    final localTitleStyle = DefaultTextStyle.of(
      tester.element(localTitle),
    ).style;
    expect(tester.widget<AppBar>(find.byType(AppBar)).toolbarHeight, 48);
    for (final (section, title) in [
      ('network', '网络文件夹'),
      ('mounts', '文件夹管理'),
    ]) {
      await tester.tap(find.byKey(Key('sidebar-$section')));
      await tester.pump(const Duration(milliseconds: 250));
      final currentTitle = pageTitle(title);
      final currentPosition = tester.getTopLeft(currentTitle);
      final currentStyle = DefaultTextStyle.of(
        tester.element(currentTitle),
      ).style;
      expect(currentPosition.dx, closeTo(localTitlePosition.dx, 0.1));
      expect(currentPosition.dy, closeTo(localTitlePosition.dy, 0.1));
      expect(currentStyle.fontSize, localTitleStyle.fontSize);
      expect(currentStyle.fontWeight, localTitleStyle.fontWeight);
      expect(tester.widget<AppBar>(find.byType(AppBar)).toolbarHeight, 48);
    }
    await tester.tap(find.byKey(const Key('sidebar-local')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      tester.getTopLeft(find.byKey(const Key('sidebar-mounts'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('sidebar-library'))).dy),
    );
    expect(find.text('文件夹管理'), findsOneWidget);
    expect(find.text('StreamPath'), findsOneWidget);
    expect(find.text('本地影视'), findsOneWidget);
    final localSurface = find.ancestor(
      of: find.byKey(const ValueKey('local-root-root-test')),
      matching: find.byType(GlassSurface),
    );
    expect(
      tester.widget<GlassSurface>(localSurface).borderRadius,
      BorderRadius.circular(14),
    );
    expect(
      tester.widget<GlassSurface>(localSurface).level,
      GlassSurfaceLevel.content,
    );
    expect(
      tester.widget<GlassSurface>(localSurface).clipBehavior,
      Clip.antiAlias,
    );
    expect(find.byKey(const Key('add-local-root-button')), findsNothing);
    for (
      var attempt = 0;
      attempt < 12 && find.text('1.5 KiB').evaluate().isEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(
      find.text('1.5 KiB'),
      findsOneWidget,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data)
          .join(' | '),
    );

    await tester.tap(find.byKey(const ValueKey('local-root-root-test')));
    for (
      var attempt = 0;
      attempt < 12 && find.text('Series').evaluate().isEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    await tester.tap(find.text('Series').last);
    for (
      var attempt = 0;
      attempt < 12 && find.text('episode.mp4').evaluate().isEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(find.text('episode.mp4'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sidebar-mounts')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('sidebar-local')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('episode.mp4'), findsOneWidget);

    final pinnedColor = tester
        .widget<Material>(find.byKey(const Key('sidebar-surface')))
        .color;
    final edge = tester.widget<DecoratedBox>(
      find.byKey(const Key('sidebar-edge')),
    );
    expect((edge.decoration as BoxDecoration).border, isA<Border>());
    await tester.runAsync(
      () => appState.setSidebarMode(SidebarDisplayMode.autoHide),
    );
    await tester.pumpAndSettle();
    final titleBarSurface = find.byKey(WindowTitleBar.sidebarSurfaceKey);
    expect(tester.widget<Material>(titleBarSurface).color, pinnedColor);
    expect(
      tester.getTopLeft(titleBarSurface).dx,
      closeTo(
        WindowTitleBar.sidebarTriggerWidth - WindowTitleBar.sidebarWidth,
        0.1,
      ),
    );
    expect(
      tester.getSize(find.byKey(const Key('sidebar-visible-strip'))).width,
      WindowTitleBar.sidebarTriggerWidth,
    );
    expect(
      tester.getSize(find.byKey(const Key('sidebar-hover-zone'))).width,
      36,
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(300, 100));
    await mouse.moveTo(const Offset(28, 100));
    await mouse.moveTo(const Offset(40, 100));
    await tester.pump(const Duration(milliseconds: 45));
    final movingTitleEdge = tester.getRect(titleBarSurface).right;
    final movingSidebarEdge = tester
        .getRect(find.byKey(const Key('sidebar-surface')))
        .right;
    expect(movingTitleEdge, closeTo(movingSidebarEdge, 0.1));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(titleBarSurface).dx, closeTo(0, 0.1));
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.getTopLeft(titleBarSurface).dx, closeTo(0, 0.1));
    final floatingColor = tester
        .widget<Material>(find.byKey(const Key('sidebar-surface')))
        .color;
    expect(floatingColor, pinnedColor);
    final clip = find.byKey(const Key('sidebar-content-clip'));
    expect(
      tester.widget<ClipRect>(clip).clipper!.getClip(tester.getSize(clip)).left,
      closeTo(WindowTitleBar.sidebarWidth - 12, 0.1),
    );
    expect(find.text('episode.mp4'), findsOneWidget);
    await mouse.moveTo(const Offset(300, 100));
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump(const Duration(milliseconds: 45));
    final hidingTitleEdge = tester.getRect(titleBarSurface).right;
    final hidingSidebarEdge = tester
        .getRect(find.byKey(const Key('sidebar-surface')))
        .right;
    expect(hidingTitleEdge, closeTo(hidingSidebarEdge, 0.1));
    expect(hidingSidebarEdge, greaterThan(WindowTitleBar.sidebarTriggerWidth));
    expect(hidingSidebarEdge, lessThan(WindowTitleBar.sidebarWidth));
    await tester.pumpAndSettle();
    for (var attempt = 0; attempt < 3; attempt++) {
      await mouse.moveTo(const Offset(9, 100));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(titleBarSurface).dx, closeTo(0, 0.1));
      await mouse.moveTo(const Offset(300, 100));
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(titleBarSurface).right,
        closeTo(WindowTitleBar.sidebarTriggerWidth, 0.1),
      );
    }
    await mouse.removePointer();
  });
}
