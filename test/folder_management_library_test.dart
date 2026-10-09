import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/local/directory_cache.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/media_connection.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/domain/services/film_scan_scheduler.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/pages/film_library_manage_page.dart';
import 'package:streampath/presentation/pages/film_library_page.dart';
import 'package:streampath/presentation/pages/folders_page.dart';
import 'package:streampath/presentation/pages/media_library_page.dart';
import 'package:streampath/presentation/widgets/film_continue_card.dart';
import 'package:streampath/presentation/widgets/directory_scroll_view.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/sp_menu.dart';

import 'helpers/shell_test_app_state.dart';

FilmWork _work(int id) => FilmWork(
  type: FilmMediaType.movie,
  tmdbId: id,
  title: 'Movie $id',
  originalTitle: 'Movie $id',
  overview: '',
  language: 'en-US',
  metadata: {
    'belongs_to_collection': {'id': 123, 'name': 'Series'},
    'credits': {
      'cast': [
        {'id': 456, 'name': 'Person'},
      ],
    },
  },
);

Future<FilmCatalogRoot> _root(
  FilmCatalogStore store,
  String path,
  int id, {
  String sourceId = 'local:fixture',
  MediaSourceKind kind = MediaSourceKind.local,
}) async {
  final rootId = await store.addRoot(
    sourceId: sourceId,
    kind: kind,
    path: path,
    type: FilmMediaType.movie,
    name: path,
  );
  final root = (await store.root(rootId))!;
  final generation = await store.beginScan(rootId);
  await store.stage(root, generation, [
    FilmScanEntry(
      path: '$path/movie.mkv',
      parentPath: path,
      name: 'movie.mkv',
      mediaKind: 'video',
    ),
    FilmScanEntry(
      path: '$path/pending.mkv',
      parentPath: path,
      name: 'pending.mkv',
      mediaKind: 'video',
    ),
  ]);
  await store.commitScan(rootId, generation, cancelled: () => false);
  await store.bind([(await store.resources(rootId: rootId)).first], _work(id));
  return (await store.root(rootId))!;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<(ShellTestAppState, FilmCatalogController)> _fixture(
  WidgetTester tester,
) async {
  final fixture = await tester.runAsync(() async {
    final dir = await Directory.systemTemp.createTemp('folder_library_');
    final config = StreamPathConfigStore.forPath('${dir.path}/config.json');
    await config.save(
      StreamPathConfig(
        localRoots: [
          LocalRootConfig(
            rootId: 'fixture',
            displayName: 'Fixture',
            path: dir.path,
          ),
        ],
      ),
    );
    final progress = await PlaybackProgressService.open(
      '${dir.path}/progress.db',
    );
    final app = ShellTestAppState(
      configStore: config,
      playbackHistoryStore: PlaybackHistoryStore.forPath(
        '${dir.path}/history.json',
      ),
      progressService: progress,
    );
    final c = await app.getFilmCatalog();
    await _root(c.store, 'Library', 1);
    await c.refresh();
    return (dir, app, c, progress);
  });
  final (dir, app, c, progress) = fixture!;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await app.closeTestStores();
      app.dispose();
      await progress.close();
      await dir.delete(recursive: true);
    });
  });
  return (app, c);
}

Widget _frame(AppState app, Widget page) =>
    ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    );

void main() {
  setUpAll(sqfliteFfiInit);

  testWidgets('合并文件夹页在四语言、明暗与玻璃模式窄窗两倍字号下可操作', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (app, _) = await _fixture(tester);
    for (final language in AppLanguage.values) {
      for (final theme in [
        AppTheme.light(),
        AppTheme.dark(),
        AppTheme.light(glass: true),
        AppTheme.dark(glass: true),
      ]) {
        await tester.pumpWidget(
          ChangeNotifierProvider<AppState>.value(
            value: app,
            child: MaterialApp(
              locale: language.locale,
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: AppLanguage.values.map((item) => item.locale),
              theme: theme,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: FoldersPage(onOpenResult: (_) async {}),
            ),
          ),
        );
        await _settle(tester);
        for (final tab in ['network', 'local', 'server', 'film']) {
          await tester.ensureVisible(find.byKey(Key('folders-$tab-tab')));
          await tester.tap(find.byKey(Key('folders-$tab-tab')));
          await _settle(tester);
          expect(tester.widget<AppBar>(find.byType(AppBar)).toolbarHeight, 48);
          expect(
            tester.takeException(),
            isNull,
            reason: '${language.name}: $tab',
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  test(
    'disabled roots hide works and collections, retain records and skip scheduled scans',
    () async {
      final dir = await Directory.systemTemp.createTemp('root_visibility_');
      var store = await FilmCatalogStore.open('${dir.path}/catalog.db');
      try {
        final hidden = await _root(store, 'Hidden', 1);
        final visible = await _root(store, 'Visible', 2);
        final resources = await store.resources(rootId: hidden.id);
        final workId = resources.first.workId!;
        await store.setFavorite(workId, true);
        await store.markWatched([resources.first], true);
        final collection = await store.createCollection('Hidden collection');
        await store.addCollectionMember(collection, workId);
        final mixed = await store.createCollection('Mixed collection');
        await store.addCollectionMember(mixed, workId);
        await store.addCollectionMember(
          mixed,
          (await store.resources(rootId: visible.id)).first.workId!,
        );
        final daily = await store.dailySelection();
        expect(hidden.enabled, isTrue);
        expect(await store.collections(), hasLength(3));
        await store.setRootEnabled(hidden.id, false);
        expect((await store.root(hidden.id))!.enabled, isFalse);
        expect(await store.roots(), hasLength(2));
        expect((await store.works(type: null)).single.tmdbId, 2);
        expect(await store.works(type: null, rootId: hidden.id), isEmpty);
        expect(await store.works(type: null, favoritesOnly: true), isEmpty);
        expect(
          (await store.works(type: null, personId: 'tmdb:456')).single.tmdbId,
          2,
        );
        expect(
          (await store.works(type: null, sectionId: 'daily')).single.tmdbId,
          2,
        );
        expect(await store.dailySelection(), daily);
        expect((await store.collections()).single.id, mixed);
        expect((await store.collections()).single.count, 1);
        expect(await store.pendingCount(), 1);
        expect(await store.resources(enabledOnly: true), hasLength(2));
        expect(await store.unprobedResources(limit: 10), hasLength(2));
        expect(await store.resources(), hasLength(4));
        expect(await store.isFavorite(workId), isTrue);
        expect((await store.resourceWatchState(resources.first))!.fraction, 1);
        await store.close();
        store = await FilmCatalogStore.open('${dir.path}/catalog.db');
        expect((await store.root(hidden.id))!.enabled, isFalse);
        final scans = <int>[];
        final scheduler = FilmScanScheduler(
          store: store,
          isBusy: () async => false,
          scan: (roots) async => scans.addAll(roots.map((root) => root.id)),
        );
        final now = DateTime(2026, 10, 8);
        await scheduler.tick(now: now);
        await scheduler.tick(now: now.add(const Duration(days: 1)));
        expect(scans, [visible.id]);
        await scheduler.close();
        await store.setRootEnabled(hidden.id, true);
        expect(await store.works(type: null), hasLength(2));
        expect(await store.collections(), hasLength(3));
        expect(await store.pendingCount(), 2);
        await store.bind([
          (await store.resources(rootId: visible.id)).first,
        ], _work(1));
        await store.setRootEnabled(hidden.id, false);
        expect((await store.works(type: null)).single.resourceCount, 1);
        expect((await store.works(type: null)).single.id, workId);
        expect(
          (await store.collections()).map((row) => row.id),
          contains(collection),
        );
        final server = await _root(
          store,
          'Server',
          1,
          sourceId: 'server-fixture',
          kind: MediaSourceKind.jellyfin,
        );
        const connection = MediaConnection(
          id: 'server-fixture',
          kind: MediaSourceKind.jellyfin,
          name: 'Server',
          url: 'http://127.0.0.1:8096',
        );
        await store.saveServerCollection(
          connection,
          {'Id': 'set', 'Name': 'Server collection'},
          [workId],
        );
        expect(
          (await store.collections()).map((row) => row.id),
          contains('server:server-fixture:set'),
        );
        await store.setRootEnabled(server.id, false);
        expect(
          (await store.collections()).map((row) => row.id),
          isNot(contains('server:server-fixture:set')),
        );
        await store.setRootEnabled(server.id, true);
        expect(
          (await store.collections()).map((row) => row.id),
          contains('server:server-fixture:set'),
        );
      } finally {
        await store.close();
        await dir.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'continue cards follow directory toggles and keep stored progress',
    (tester) async {
      final (app, c) = await _fixture(tester);
      late MediaLibraryStore records;
      final item = (await tester.runAsync(
        () => c.store.resources(),
      ))!.first.playbackItem;
      await tester.runAsync(() async {
        records = MediaLibraryStore.forPath(
          '${File(app.configStore.configFilePath).parent.path}/continue.json',
        );
        await records.recordPlayback(item, playbackSessionId: 'session');
        await app.progressService.saveProgress(
          url: app.resolveMediaLibraryTarget(item)!,
          profileId: item.sourceId,
          positionMs: 20000,
          durationMs: 600000,
        );
      });
      await tester.pumpWidget(
        _frame(
          app,
          MediaLibraryPage(
            sourceId: item.sourceId,
            store: records,
            directoryCache: DirectoryCache(),
            videoProgressService: app.progressService,
            audioProgressService: null,
            resolveUrl: (url) => url,
            resolveDirectTarget: app.resolveMediaLibraryTarget,
            filmCatalog: c,
            filmContinueAll: true,
          ),
        ),
      );
      await _settle(tester);
      expect(find.byType(FilmContinueCard), findsOneWidget);
      final id = c.roots.single.id;
      await tester.runAsync(() async {
        await c.store.setRootEnabled(id, false);
        await c.refresh();
      });
      await _settle(tester);
      expect(find.byType(FilmContinueCard), findsNothing);
      await tester.runAsync(
        () => records.recordPlayback(item, playbackSessionId: 'session'),
      );
      await _settle(tester);
      expect(find.byType(FilmContinueCard), findsNothing);
      await tester.runAsync(() async {
        await c.store.setRootEnabled(id, true);
        await c.refresh();
      });
      await _settle(tester);
      final card = tester.widget<FilmContinueCard>(
        find.byType(FilmContinueCard),
      );
      expect(card.positionMs, 20000);
      expect(
        (await tester.runAsync(
          () => records.playbackHistory(item.sourceId, audio: false),
        ))!,
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'network management has one add button with both existing flows',
    (tester) async {
      final (app, _) = await _fixture(tester);
      await tester.pumpWidget(
        _frame(app, FoldersPage(onOpenResult: (_) async {})),
      );
      await _settle(tester);
      expect(find.widgetWithText(FilledButton, '添加网络存储'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '添加 WebDAV 挂载'), findsNothing);
      await tester.tap(find.text('添加网络存储'));
      await tester.pumpAndSettle();
      expect(find.text('SMB / FTP / NFS'), findsOneWidget);
      await tester.tap(find.text('添加 WebDAV 挂载'));
      await tester.pumpAndSettle();
      expect(find.text('添加已保存的服务器'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加网络存储'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SMB / FTP / NFS'));
      await tester.pumpAndSettle();
      expect(find.text('添加来源'), findsOneWidget);
      expect(find.text('SMB'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'folder network and media server add buttons align above the lists',
    (tester) async {
      final (app, _) = await _fixture(tester);
      await tester.pumpWidget(
        _frame(app, FoldersPage(onOpenResult: (_) async {})),
      );
      await _settle(tester);
      final network = tester.getTopLeft(
        find.widgetWithText(FilledButton, '添加网络存储'),
      );
      expect(
        network.dy,
        lessThan(tester.getTopLeft(find.text('添加服务器以浏览文件夹')).dy),
      );
      await tester.tap(find.byKey(const Key('folders-server-tab')));
      await tester.pumpAndSettle();
      final server = tester.getTopLeft(
        find.widgetWithText(FilledButton, '添加媒体服务器'),
      );
      expect(server, network);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'library tab initializes directory data when the shared catalog is not loaded',
    (tester) async {
      final (app, c) = await _fixture(tester);
      c.roots = [];
      await tester.pumpWidget(
        _frame(app, FoldersPage(onOpenResult: (_) async {})),
      );
      await _settle(tester);
      await tester.tap(find.widgetWithText(Tab, '影视库'));
      await _settle(tester);
      expect(c.roots.single.displayName, 'Library');
      expect(find.text('Library'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'library tab retains state and scroll, avoids return refreshes and releases its host',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final (app, c) = await _fixture(tester);
      await tester.runAsync(() async {
        await _root(c.store, 'Second', 2);
        await _root(c.store, 'Third', 3);
        await c.refresh();
      });
      await tester.pumpWidget(
        _frame(app, FoldersPage(onOpenResult: (_) async {})),
      );
      await _settle(tester);
      var refreshStarts = 0;
      var wasLoading = c.loading;
      void observe() {
        if (c.loading && !wasLoading) refreshStarts++;
        wasLoading = c.loading;
      }

      c.addListener(observe);
      addTearDown(() => c.removeListener(observe));
      await tester.tap(find.widgetWithText(Tab, '影视库'));
      await _settle(tester);
      final page = find.byType(FilmLibraryManagePage);
      final state = tester.state(page);
      final list = tester.widget<ListView>(
        find.descendant(of: page, matching: find.byType(ListView)),
      );
      expect(
        find.descendant(of: page, matching: find.byType(DirectoryScrollView)),
        findsOneWidget,
      );
      list.controller!.jumpTo(150);
      await tester.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.widgetWithText(Tab, '网络存储'));
        await _settle(tester);
        await tester.tap(find.widgetWithText(Tab, '影视库'));
        await _settle(tester);
        expect(tester.state(page), same(state));
        expect(
          tester
              .widget<ListView>(
                find.descendant(of: page, matching: find.byType(ListView)),
              )
              .controller,
          same(list.controller),
        );
        expect(list.controller!.offset, 150);
      }
      expect(refreshStarts, 0);
      await tester.tap(find.widgetWithText(Tab, '网络存储'));
      await _settle(tester);
      await tester.runAsync(() async {
        await c.store.setRootEnabled(c.roots.first.id, false);
        await c.refresh();
      });
      await tester.tap(find.widgetWithText(Tab, '影视库'));
      await _settle(tester);
      expect(tester.state(page), same(state));
      final toggle = find.byKey(
        ValueKey('film-root-enabled-${c.roots.first.id}'),
      );
      expect(tester.widget<Switch>(toggle).value, isFalse);
      c.removeListener(observe);
      await tester.pumpWidget(_frame(app, const Scaffold()));
      await tester.pumpAndSettle();
      expect(state.mounted, isFalse);
      await tester.runAsync(c.refresh);
      await tester.pump();
      expect(c.roots, hasLength(3));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'library directory tab toggles visibility and settings contain no directory cards',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final (app, c) = await _fixture(tester);
      final id = c.roots.single.id;
      await tester.pumpWidget(
        _frame(app, FoldersPage(onOpenResult: (_) async {})),
      );
      await _settle(tester);
      await tester.tap(find.widgetWithText(Tab, '影视库'));
      await _settle(tester);
      expect(find.text('添加影视目录'), findsOneWidget);
      expect(find.text('TMDB 元数据凭据'), findsNothing);
      final toggle = find.byKey(ValueKey('film-root-enabled-$id'));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await _settle(tester);
      expect(c.enabledRoots, isEmpty);
      expect(c.works, isEmpty);
      expect(
        c.isItemEnabled(
          (await tester.runAsync(
            () => c.store.resources(),
          ))!.first.playbackItem,
        ),
        isFalse,
      );
      expect(find.text('Library'), findsWidgets);
      await tester.pumpWidget(
        _frame(
          app,
          FilmLibraryPage(
            onOpenItem: (_) async {},
            continueShelf: const SizedBox.shrink(),
          ),
        ),
      );
      await _settle(tester);
      final selector = tester.widget<SPDropdownButtonFormField<int>>(
        find.byKey(const ValueKey('film-root-filter')),
      );
      expect(selector.items!.map((item) => item.value), [0]);
      expect(find.text('Library'), findsNothing);
      await tester.pumpWidget(
        _frame(app, FilmLibraryManagePage(catalog: c, directories: true)),
      );
      await _settle(tester);
      await tester.tap(toggle);
      await _settle(tester);
      expect(c.enabledRoots, hasLength(1));
      expect(c.works, hasLength(1));
      await tester.pumpWidget(
        _frame(
          app,
          FilmLibraryManagePage(key: const Key('settings'), catalog: c),
        ),
      );
      await _settle(tester);
      expect(find.text('添加影视目录'), findsNothing);
      expect(find.text('Library'), findsNothing);
      expect(find.text('首页栏目'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
