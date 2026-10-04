import 'dart:io';
import 'helpers/shell_test_app_state.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/navigation_location_store.dart';
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
import 'package:streampath/presentation/widgets/directory_breadcrumbs.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  for (final mode in DirectoryMemoryMode.values) {
    testWidgets('侧边栏首帧直接打开记忆目录 ${mode.name}', (tester) async {
      final temp = Directory.systemTemp.createTempSync('directory_restore_');
      final media = Directory(p.join(temp.path, 'Media'))..createSync();
      Directory(
        p.join(media.path, 'Series', 'Season 1'),
      ).createSync(recursive: true);
      final root = LocalRootConfig(
        rootId: 'remembered',
        displayName: '记忆挂载',
        path: media.path,
      );
      final config = StreamPathConfigStore.forPath(
        p.join(temp.path, 'config.json'),
      );
      late PlaybackProgressService progress;
      late NavigationLocationStore locations;
      await tester.runAsync(() async {
        await config.save(StreamPathConfig(localRoots: [root]));
        progress = await PlaybackProgressService.open(
          inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        final file = File(p.join(temp.path, 'locations.json'));
        locations = NavigationLocationStore(file, mode: mode);
        await locations.remember(
          sourceId: root.sourceId,
          kind: 'local',
          path: 'Series/Season 1',
        );
        if (mode == DirectoryMemoryMode.persistent) {
          locations = NavigationLocationStore(file, mode: mode);
          await locations.load();
        }
      });
      final app = ShellTestAppState(
        configStore: config,
        playbackHistoryStore: PlaybackHistoryStore.forPath(
          p.join(temp.path, 'history.json'),
        ),
        progressService: progress,
        navigationLocationStore: locations,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(app.closeTestStores);
        app.dispose();
        await tester.runAsync(() async {
          await progress.close();
          temp.deleteSync(recursive: true);
        });
      });

      await tester.runAsync(app.getFilmCatalog);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: app,
          child: const MaterialApp(home: AppShellPage()),
        ),
      );

      expect(find.byKey(const Key('sidebar-films')), findsOneWidget);
      expect(find.byType(DirectoryBreadcrumbs), findsNothing);
      await tester.tap(find.byKey(const Key('sidebar-folders')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('folders-local-tab')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.byKey(const ValueKey('local-root-remembered')));
      await tester.pump();
      expect(find.byType(DirectoryBreadcrumbs), findsOneWidget);
      expect(
        tester
            .widget<DirectoryBreadcrumbs>(find.byType(DirectoryBreadcrumbs))
            .crumbs,
        ['Series', 'Season 1'],
      );
      await tester.pump(const Duration(milliseconds: 350));
      for (var attempt = 0; attempt < 4; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump();
      }
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('local-root-remembered')),
        findsOneWidget,
      );
    });
  }

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
    final appState = ShellTestAppState(
      configStore: configStore,
      playbackHistoryStore: PlaybackHistoryStore.forPath(
        p.join(temporaryDirectory.path, 'history.json'),
      ),
      progressService: progress,
    );
    await tester.runAsync(appState.getFilmCatalog);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(appState.closeTestStores);
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
                const WindowTitleBar(),
                const Expanded(child: AppShellPage()),
              ],
            ),
          ),
        ),
      ),
    );

    for (final section in [
      'films',
      'folders',
      'library',
      'mounts',
      'settings',
    ]) {
      expect(find.byKey(Key('sidebar-$section')), findsOneWidget);
    }
    Finder pageTitle(String text) =>
        find.descendant(of: find.byType(AppBar), matching: find.text(text));
    await tester.tap(find.byKey(const Key('sidebar-folders')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('本地文件夹'), findsOneWidget);
    expect(find.text('网络文件夹'), findsOneWidget);
    expect(find.byKey(const Key('folders-search')), findsOneWidget);
    await tester.tap(find.byKey(const Key('folders-local-tab')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    final localTitle = pageTitle('文件夹');
    final localTitlePosition = tester.getTopLeft(localTitle);
    final localTitleStyle = DefaultTextStyle.of(
      tester.element(localTitle),
    ).style;
    expect(tester.widget<AppBar>(find.byType(AppBar)).toolbarHeight, 48);
    for (final (section, title) in [('mounts', '文件夹管理')]) {
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
    await tester.tap(find.byKey(const Key('sidebar-folders')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      tester.getTopLeft(find.byKey(const Key('sidebar-mounts'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('sidebar-library'))).dy),
    );
    expect(find.byTooltip('文件夹管理'), findsOneWidget);
    expect(find.text('StreamPath'), findsNothing);
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
    await tester.tap(find.byKey(const Key('sidebar-folders')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('episode.mp4'), findsOneWidget);

    expect(find.byKey(const Key('sidebar-controls')), findsNothing);
    expect(find.byKey(const Key('sidebar-mode-toggle')), findsNothing);
    expect(find.byKey(const Key('sidebar-compact-toggle')), findsNothing);
    expect(tester.getSize(find.byKey(const Key('sidebar-rail'))).width, 64);
    expect(tester.getSize(find.byKey(const Key('sidebar-surface'))).width, 56);
    for (final label in ['影视库', '文件夹', '文件夹管理', '媒体中心', '设置']) {
      expect(find.byTooltip(label), findsOneWidget);
    }
    expect(find.byKey(const Key('sidebar-search')), findsNothing);
    expect(find.byKey(const Key('sidebar-local')), findsNothing);
    expect(find.byKey(const Key('sidebar-network')), findsNothing);
    final edge = tester.widget<DecoratedBox>(
      find.byKey(const Key('sidebar-edge')),
    );
    expect(
      (edge.decoration as BoxDecoration).borderRadius,
      BorderRadius.circular(28),
    );
    expect(tester.takeException(), isNull);
  });
}
