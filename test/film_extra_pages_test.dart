import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/pages/film_detail_page.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/film_extra_controls.dart';
import 'package:streampath/presentation/widgets/sp_menu.dart';

Future<void> settleExtras(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 80));
  }
}

void main() {
  setUpAll(sqfliteFfiInit);
  test('电影默认推荐跳过排在正片前面的特典，只有特典时不回退误播', () async {
    final dir = await Directory.systemTemp.createTemp('extra_recommended_');
    final store = await FilmCatalogStore.open('${dir.path}/catalog.db');
    final progress = await PlaybackProgressService.open(
      '${dir.path}/progress.db',
    );
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
    final app = AppState(
      configStore: config,
      playbackHistoryStore: PlaybackHistoryStore.forPath(
        '${dir.path}/history.json',
      ),
      progressService: progress,
    );
    try {
      final id = await store.addRoot(
        sourceId: 'local:fixture',
        kind: MediaSourceKind.local,
        path: 'Movies',
        type: FilmMediaType.movie,
        name: 'Fixture',
      );
      final root = (await store.root(id))!, gen = await store.beginScan(id);
      await store.stage(root, gen, [
        for (final name in ['MENU.mkv', 'PV01.mkv', 'Work.2020.mkv'])
          FilmScanEntry(
            path: 'Movies/Work/$name',
            parentPath: 'Movies/Work',
            name: name,
            mediaKind: 'video',
          ),
      ]);
      await store.bind(
        await store.resources(),
        const FilmWork(
          type: FilmMediaType.movie,
          tmdbId: 1,
          title: 'Work',
          originalTitle: 'Work',
          year: 2020,
          overview: '',
          language: 'zh-CN',
        ),
      );
      final resources = await store.resources();
      final work = (await store.work(resources.first.workId!))!;
      expect(resources.first.isExtra, isTrue);
      expect(
        recommendedFilmResource(app, work, resources)!.name,
        'Work.2020.mkv',
      );
      expect(
        recommendedFilmResource(
          app,
          work,
          resources.where((r) => r.isExtra).toList(),
        ),
        isNull,
      );
    } finally {
      app.dispose();
      await progress.close();
      await store.close();
      await dir.delete(recursive: true);
    }
  });
  testWidgets('无简介集数卡片显示原始文件名，正式简介仍保持', (tester) async {
    late Directory dir;
    late FilmCatalogController catalog;
    late FilmResource resource;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('extra_filename_ui_');
      final store = await FilmCatalogStore.open('${dir.path}/catalog.db');
      final id = await store.addRoot(
        sourceId: 'tv',
        kind: MediaSourceKind.webdav,
        path: 'TV',
        type: FilmMediaType.tv,
        name: 'TV',
      );
      final root = (await store.root(id))!, gen = await store.beginScan(id);
      await store.stage(root, gen, [
        const FilmScanEntry(
          path: 'TV/Work/Specials/Work.S00E01.NCOP.strm',
          parentPath: 'TV/Work/Specials',
          name: 'Work.S00E01.NCOP.strm',
          mediaKind: 'strm',
        ),
      ]);
      await store.bind(
        await store.resources(),
        const FilmWork(
          type: FilmMediaType.tv,
          tmdbId: 1,
          title: 'Work',
          originalTitle: 'Work',
          overview: '',
          language: 'zh-CN',
        ),
      );
      resource = (await store.resources()).single;
      await store.mapEpisodes({resource: (0, 1)});
      resource = (await store.resource(resource.id))!;
      final tmdb = TmdbMetadataService(credentials: _NoExtraCredentials());
      catalog = FilmCatalogController(
        store: store,
        tmdb: tmdb,
        images: FilmCatalogImageCache(Directory('${dir.path}/images'), tmdb),
        sourceFor: (_) => throw StateError('No media I/O in UI test'),
      );
    });
    addTearDown(() async {
      await catalog.close();
      await dir.delete(recursive: true);
    });
    Future<void> show(Map? episode) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: SizedBox(
              width: 300,
              child: FilmEpisodeCard(
                resource: resource,
                catalog: catalog,
                state: '可用',
                displayTitle: 'Work',
                episode: episode,
                onOpenItem: (_) async {},
                onChanged: () async {},
              ),
            ),
          ),
        ),
      );
      await settleExtras(tester);
    }

    await show(null);
    expect(find.text(resource.name), findsOneWidget);
    expect(find.text('1. Work'), findsOneWidget);
    await show({'name': 'Official title', 'overview': 'Official overview'});
    expect(find.text('Official overview'), findsOneWidget);
    expect(find.text(resource.name), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await settleExtras(tester);
  });
  for (final language in AppLanguage.values) {
    testWidgets('分类设置与筛选四语言、窄窗和放大文字 $language', (tester) async {
      tester.view.physicalSize = const Size(760, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory dir;
      late FilmCatalogStore store;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('extra_ui_');
        store = await FilmCatalogStore.open('${dir.path}/catalog.db');
      });
      addTearDown(() async {
        await store.close();
        await dir.delete(recursive: true);
      });
      await tester.pumpWidget(
        MaterialApp(
          locale: language.locale,
          supportedLocales: AppLanguage.values.map((l) => l.locale),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: AppTheme.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                key: const Key('open-extra-settings'),
                onPressed: () => showFilmExtraSettings(context, store),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open-extra-settings')));
      await tester.pumpAndSettle();
      expect(find.text('NCOP'), findsOneWidget);
      await tester.tap(find.text('NCOP'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('film-extra-type-aliases')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await settleExtras(tester);
    });
  }
  testWidgets('新增类别保存、重复别名校验、取消与筛选隔离', (tester) async {
    late Directory dir;
    late FilmCatalogStore store;
    late List<FilmResource> resources;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('extra_ui_save_');
      store = await FilmCatalogStore.open('${dir.path}/catalog.db');
      final id = await store.addRoot(
        sourceId: 'dav',
        kind: MediaSourceKind.webdav,
        path: 'Movies',
        type: FilmMediaType.movie,
        name: 'Fixture',
      );
      final root = (await store.root(id))!;
      final generation = await store.beginScan(id);
      await store.stage(root, generation, [
        for (final name in ['NCOP01.mkv', 'PV01.mkv'])
          FilmScanEntry(
            path: 'Movies/Work/Extras/$name',
            parentPath: 'Movies/Work/Extras',
            name: name,
            mediaKind: 'video',
          ),
      ]);
      resources = await store.resources();
    });
    addTearDown(() async {
      await store.close();
      await dir.delete(recursive: true);
    });
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                TextButton(
                  onPressed: () => showFilmExtraSettings(context, store),
                  child: const Text('Open'),
                ),
                FilmExtraFilter(
                  store: store,
                  resources: resources,
                  selected: null,
                  onChanged: (value) => selected = value,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新增分类'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('film-extra-type-name')),
      'Custom clip',
    );
    await tester.enterText(
      find.byKey(const Key('film-extra-type-aliases')),
      'NCOP',
    );
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    expect(find.text('识别别名重复或占用了通用特典名称'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('film-extra-type-aliases')),
      'CUSTOMCLIP',
    );
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    expect(
      store.extraRules.types.any((t) => t.label == 'Custom clip'),
      isFalse,
    );
    await tester.tap(find.text('保存'));
    await settleExtras(tester);
    expect(store.extraRules.types.any((t) => t.label == 'Custom clip'), isTrue);
    final field = tester.widget<SPDropdownButtonFormField<String>>(
      find.byType(SPDropdownButtonFormField<String>),
    );
    expect(field.items!.map((i) => i.value), ['', 'ncop', 'pv']);
    field.onChanged!('pv');
    expect(selected, 'pv');
    expect(resources.map((r) => r.extraKind).toSet(), {'ncop', 'pv'});
    await tester.runAsync(() async {
      await store.setExtraType(resources.first, null);
      resources = await store.resources();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FilmExtraFilter(
            store: store,
            resources: resources,
            selected: null,
            onChanged: (_) {},
          ),
        ),
      ),
    );
    final statusField = tester.widget<SPDropdownButtonFormField<String>>(
      find.byType(SPDropdownButtonFormField<String>),
    );
    expect(statusField.items!.map((i) => i.value), contains('@none'));
    expect(statusField.items!.map((i) => i.value), isNot(contains('other')));
    await tester.pumpWidget(const SizedBox.shrink());
    await settleExtras(tester);
  });
}

class _NoExtraCredentials extends TmdbCredentialStore {
  @override
  Future<String?> read() async => null;
}
