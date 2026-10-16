import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/media_connection.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/domain/services/film_scan_scheduler.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
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
import 'package:streampath/presentation/widgets/section_switcher.dart';

import 'helpers/shell_test_app_state.dart';

class _CountingCredentials extends TmdbCredentialStore {
  int reads = 0;
  @override
  Future<String?> read() async {
    reads++;
    return null;
  }
}

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

  testWidgets('空目录标签在动画结束后初始化，保留键盘入口且正文拖拽不切页', (tester) async {
    final (app, catalog) = await _fixture(tester);
    await tester.runAsync(() async {
      for (final root in catalog.roots) {
        await catalog.store.removeRoot(root.id);
      }
      await catalog.refresh();
    });
    await tester.pumpWidget(
      _frame(app, FoldersPage(onOpenResult: (_) async {})),
    );
    await _settle(tester);
    await tester.tap(find.widgetWithText(Tab, '影视库'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(FilmLibraryManagePage), findsNothing);
    await _settle(tester);
    expect(find.byType(FilmLibraryManagePage), findsOneWidget);
    expect(catalog.roots, isEmpty);
    await tester.drag(
      find.byType(StreamPathSectionSwitcher<int>),
      const Offset(200, 0),
    );
    await _settle(tester);
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 3);
    Focus.of(tester.element(find.widgetWithText(Tab, '影视库'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(tester);
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('目录页按需在编辑窗口加载来源设置，保存提交、取消保留原配置', (tester) async {
    final (app, shared) = await _fixture(tester);
    final credentials = _CountingCredentials();
    final tmdb = TmdbMetadataService(credentials: credentials);
    final catalog = FilmCatalogController(
      store: shared.store,
      tmdb: tmdb,
      images: shared.images,
      sourceFor: shared.sourceFor,
      ownsResources: false,
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await catalog.close();
      tmdb.close();
    });
    final root = shared.roots.single;
    await tester.runAsync(() async {
      await catalog.store.setPreference('root_enabled:${root.id}', false);
      await catalog.store.setPreference(
        'local_metadata:${root.sourceId}',
        true,
      );
      await catalog.store.setPreference('write_back:${root.sourceId}', true);
      await catalog.store.setPreference('read_only:${root.sourceId}', true);
      await catalog.refresh();
    });
    await tester.pumpWidget(
      _frame(
        app,
        FilmLibraryManagePage(
          key: const Key('directories'),
          catalog: catalog,
          directories: true,
        ),
      ),
    );
    await _settle(tester);
    expect(find.byType(Checkbox), findsNothing);
    await tester.ensureVisible(find.text('编辑影视目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑影视目录'));
    await _settle(tester);
    Checkbox option(String text) => tester.widget<Checkbox>(
      find.descendant(
        of: find.widgetWithText(ListTile, text),
        matching: find.byType(Checkbox),
      ),
    );
    expect(credentials.reads, 0);
    expect(option('参与定时扫描').value, isFalse);
    expect(option('本地元数据模式').value, isTrue);
    expect(option('只读来源').value, isTrue);
    expect(option('允许写回缺少的 NFO 和图片').onChanged, isNull);
    for (final title in ['本地元数据模式', '只读来源']) {
      option(title).onChanged!(false);
      await tester.pump();
      expect(option(title).value, isFalse);
      option(title).onChanged!(true);
      await tester.pump();
      expect(option(title).value, isTrue);
    }
    for (var i = 0; i < 6; i++) {
      final checkbox = find.descendant(
        of: find.widgetWithText(ListTile, '参与定时扫描'),
        matching: find.byType(Checkbox),
      );
      await tester.tap(checkbox);
      await tester.pump();
      expect(option('参与定时扫描').value, i.isEven);
    }
    await tester.tap(find.text('参与定时扫描'));
    await tester.pump();
    expect(option('参与定时扫描').value, isTrue);
    expect(
      await tester.runAsync(
        () => catalog.store.preference('root_enabled:${root.id}'),
      ),
      isFalse,
    );
    await tester.tap(find.text('取消'));
    await _settle(tester);
    expect(find.byType(Checkbox), findsNothing);
    await tester.tap(find.text('编辑影视目录'));
    await _settle(tester);
    expect(option('参与定时扫描').value, isFalse);
    option('参与定时扫描').onChanged!(true);
    option('只读来源').onChanged!(false);
    await tester.pump();
    expect(option('允许写回缺少的 NFO 和图片').onChanged, isNotNull);
    option('允许写回缺少的 NFO 和图片').onChanged!(false);
    await tester.pump();
    expect(option('允许写回缺少的 NFO 和图片').value, isFalse);
    option('允许写回缺少的 NFO 和图片').onChanged!(true);
    await tester.pump();
    expect(option('允许写回缺少的 NFO 和图片').value, isTrue);
    option('允许写回缺少的 NFO 和图片').onChanged!(false);
    option('本地元数据模式').onChanged!(false);
    await tester.pump();
    await tester.tap(find.text('保存'));
    await _settle(tester);
    expect(find.byType(Checkbox), findsNothing);
    expect(
      await tester.runAsync(
        () => catalog.store.preference('root_enabled:${root.id}'),
      ),
      isTrue,
    );
    for (final setting in ['read_only', 'write_back', 'local_metadata']) {
      expect(
        await tester.runAsync(
          () => catalog.store.preference('$setting:${root.sourceId}'),
        ),
        isFalse,
      );
    }
    expect(
      (await tester.runAsync(
        () => catalog.store.resources(rootId: root.id),
      ))!.first.workId,
      isNotNull,
    );
    expect(credentials.reads, 0);
    await tester.pumpWidget(
      _frame(
        app,
        FilmLibraryManagePage(key: const Key('settings'), catalog: catalog),
      ),
    );
    await _settle(tester);
    expect(credentials.reads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('影视库四项统计随目录关闭、启用和资源扫描自动更新', (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (app, c) = await _fixture(tester);
    await tester.pumpWidget(
      _frame(app, FilmLibraryManagePage(catalog: c, directories: true)),
    );
    await _settle(tester);
    String count(String label) => tester
        .widget<Text>(
          find
              .descendant(
                of: find.byKey(ValueKey('film-statistics-$label')),
                matching: find.byType(Text),
              )
              .first,
        )
        .data!;
    expect(count('电视剧'), '0');
    expect(count('电视剧集'), '0');
    expect(count('电影'), '1');
    expect(count('其他'), '1');
    final toggle = find.byKey(
      ValueKey('film-root-enabled-${c.roots.single.id}'),
    );
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await _settle(tester);
    expect(count('电影'), '0');
    expect(count('其他'), '0');
    await tester.tap(toggle);
    await _settle(tester);
    expect(count('电影'), '1');
    expect(count('其他'), '1');
    await tester.runAsync(() async {
      final root = c.roots.single;
      final generation = await c.store.beginScan(root.id);
      await c.store.stage(root, generation, [
        const FilmScanEntry(
          path: 'Library/new.iso',
          parentPath: 'Library',
          name: 'new.iso',
          mediaKind: 'iso',
        ),
      ]);
      await c.store.commitScan(root.id, generation, cancelled: () => false);
    });
    await _settle(tester);
    expect(count('电影'), '1');
    expect(count('其他'), '0');
    expect(tester.takeException(), isNull);
  });

  testWidgets('统计卡片四语言、材质、宽窄窗与放大字号不溢出', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (app, c) = await _fixture(tester);
    await tester.runAsync(() async {
      for (final (family, path) in [
        ('LibraryStatisticsTest', r'C:\Windows\Fonts\msyh.ttc'),
        ('Segoe Fluent Icons', r'C:\Windows\Fonts\SegoeIcons.ttf'),
      ]) {
        final font = File(path);
        if (await font.exists()) {
          final loader = FontLoader(family)
            ..addFont(
              Future.value(ByteData.sublistView(await font.readAsBytes())),
            );
          await loader.load();
        }
      }
    });
    c.statistics = const FilmLibraryStatistics(
      episodes: 2022,
      series: 123,
      movies: 64,
      other: 1,
    );
    for (final language in AppLanguage.values) {
      for (final (name, theme) in [
        ('light', AppTheme.light(fontFamily: 'LibraryStatisticsTest')),
        ('dark', AppTheme.dark(fontFamily: 'LibraryStatisticsTest')),
        (
          'light-glass',
          AppTheme.light(glass: true, fontFamily: 'LibraryStatisticsTest'),
        ),
        (
          'dark-glass',
          AppTheme.dark(glass: true, fontFamily: 'LibraryStatisticsTest'),
        ),
      ]) {
        for (final width in [480.0, 1280.0]) {
          tester.view.physicalSize = Size(width, 1100);
          for (final scale in [1.0, 2.0]) {
            await tester.pumpWidget(
              ChangeNotifierProvider<AppState>.value(
                value: app,
                child: MaterialApp(
                  locale: language.locale,
                  supportedLocales: AppLanguage.values.map(
                    (item) => item.locale,
                  ),
                  localizationsDelegates: const [
                    AppLocalizations.delegate,
                    GlobalMaterialLocalizations.delegate,
                    GlobalWidgetsLocalizations.delegate,
                    GlobalCupertinoLocalizations.delegate,
                  ],
                  theme: theme,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: RepaintBoundary(
                    key: const Key('statistics-preview'),
                    child: FilmLibraryManagePage(catalog: c, directories: true),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final l10n = AppLocalizations(language);
            for (final label in ['电视剧', '电视剧集', '电影', '其他']) {
              final card = find.byKey(ValueKey('film-statistics-$label'));
              expect(
                find.descendant(
                  of: card,
                  matching: find.text(l10n.text(label)),
                ),
                findsOneWidget,
              );
              expect(tester.getRect(card).right, lessThanOrEqualTo(width - 24));
            }
            expect(find.text('2,022'), findsOneWidget);
            expect(tester.takeException(), isNull);
            if (Platform.environment['FILM_STATISTICS_RENDER'] == '1' &&
                language == AppLanguage.simplifiedChinese &&
                (name == 'dark' || name == 'light')) {
              await tester.runAsync(() async {
                final boundary = tester.renderObject<RenderRepaintBoundary>(
                  find.byKey(const Key('statistics-preview')),
                );
                final image = await boundary.toImage(pixelRatio: 1);
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                image.dispose();
                final file = File(
                  'build/library-statistics-preview/$name-$width-$scale.png',
                );
                await file.parent.create(recursive: true);
                await file.writeAsBytes(bytes!.buffer.asUint8List());
              });
            }
          }
        }
      }
    }
  });

  testWidgets('影视目录卡片限制宽度、宽窗并列且窄窗不溢出', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
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
      _frame(app, FilmLibraryManagePage(catalog: c, directories: true)),
    );
    await _settle(tester);
    final cards = [
      for (final root in c.roots)
        find.widgetWithText(Card, root.displayName).last,
    ];
    final first = tester.getRect(cards.first);
    expect(first.width, lessThanOrEqualTo(600));
    expect(first.height, lessThan(300));
    expect(tester.getTopLeft(cards[1]).dy, first.top);
    expect(tester.getTopLeft(cards[2]).dy, first.top);
    expect(find.byType(Checkbox), findsNothing);
    for (final size in [const Size(800, 600), const Size(480, 720)]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(cards[1]).dy, greaterThan(first.top));
      expect(tester.getRect(cards.first).right, lessThanOrEqualTo(size.width));
      expect(tester.takeException(), isNull);
    }
  });

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
        final edit = find.text(AppLocalizations(language).text('编辑影视目录'));
        await tester.scrollUntilVisible(
          edit,
          250,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pumpAndSettle();
        await tester.tap(edit);
        await _settle(tester);
        expect(find.byType(Checkbox), findsNWidgets(4));
        expect(tester.takeException(), isNull);
        await tester.tap(find.text(AppLocalizations(language).text('取消')));
        await _settle(tester);
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
