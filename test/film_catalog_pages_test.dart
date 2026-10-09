import 'package:streampath/presentation/widgets/sp_menu.dart';
import 'package:streampath/data/models/video_queue.dart';
import 'dart:async';

import 'helpers/pump_until.dart';

import 'package:streampath/data/models/playback_history.dart';
import 'package:streampath/data/models/server_profile.dart';
import 'package:streampath/data/remote/webdav_client.dart';
import 'package:streampath/domain/services/webdav_service.dart';
import 'package:streampath/presentation/widgets/playback_bar.dart';
import 'package:streampath/presentation/widgets/directory_breadcrumbs.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';
import 'package:streampath/presentation/pages/film_library_shell.dart';
import 'package:streampath/domain/services/external_player_service.dart';
import 'package:streampath/data/models/media_entry.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/core/errors/app_exception.dart';
import 'package:flutter/gestures.dart';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/video_playback_scope.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/pages/film_detail_page.dart';
import 'package:streampath/presentation/pages/film_library_manage_page.dart';
import 'package:streampath/presentation/pages/film_library_page.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/film_match_dialog.dart';
import 'package:streampath/presentation/widgets/settings_group_card.dart';
import 'package:streampath/presentation/widgets/film_shelf.dart';
import 'package:streampath/presentation/widgets/film_favorites_wall.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  testWidgets('保存凭据后清空输入仍可验证，重进页面保留状态', (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('film_token_ui_');
      final store = await FilmCatalogStore.open(
        p.join(temp.path, 'catalog.db'),
      );
      final credentials = _SavedCredentials();
      final requests = <RequestOptions>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests.add(options);
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: <String, dynamic>{'images': <String, dynamic>{}},
                ),
              );
            },
          ),
        );
      final tmdb = TmdbMetadataService(credentials: credentials, dio: dio);
      final c = FilmCatalogController(
        store: store,
        tmdb: tmdb,
        images: FilmCatalogImageCache(
          Directory(p.join(temp.path, 'images')),
          tmdb,
        ),
        sourceFor: (_) => throw const FilmCatalogException('sourceUnavailable'),
      );
      return (temp, c, credentials, requests);
    });
    final (temp, c, credentials, requests) = fixture!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await c.close();
        await temp.delete(recursive: true);
      });
    });
    Widget frame() => MaterialApp(
      theme: AppTheme.dark(),
      home: FilmLibraryManagePage(catalog: c),
    );
    Future<void> settle() async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.pumpWidget(frame());
    await settle();
    expect(find.byType(SettingsGroupCard), findsWidgets);
    expect(find.byType(SettingsProgressPanel), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('探测模式'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester
          .widget<SPDropdownButtonFormField<String>>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is SPDropdownButtonFormField<String> &&
                  widget.initialValue == 'playback',
            ),
          )
          .borderRadius,
      AppTheme.dropdownBorderRadius,
    );
    await tester.scrollUntilVisible(
      find.text('保存凭据'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存凭据'))
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byType(TextField), 'test-read-access-token');
    await tester.pump();
    await tester.tap(find.text('保存凭据'));
    await settle();
    expect(credentials.token, 'test-read-access-token');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(find.text('保存后输入框会清空；验证使用已保存的凭据'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '验证凭据'))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.text('验证凭据'));
    await settle();
    expect(
      requests.single.headers['Authorization'],
      'Bearer test-read-access-token',
    );
    expect(find.text('TMDB 凭据验证通过'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(frame());
    await settle();
    await tester.scrollUntilVisible(
      find.text('已保存 TMDB 凭据'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('已保存 TMDB 凭据'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('全部与三个同源目录独立筛选，卡片右键查看来源，影视库内起播和续播', (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('film_phase2_ui_');
      final media = Directory(p.join(temp.path, 'Media'));
      await Directory(p.join(media.path, 'Movies')).create(recursive: true);
      const filename = 'Movie.2020.PROPER.1080p.mkv';
      await File(p.join(media.path, 'Movies', filename)).writeAsBytes([0]);
      final config = StreamPathConfigStore.forPath(
        p.join(temp.path, 'config.json'),
      );
      await config.save(
        StreamPathConfig(
          credentialStorageMode: CredentialStorageMode.portablePlaintext,
          localRoots: [
            LocalRootConfig(
              rootId: 'ui',
              displayName: 'Local',
              path: media.path,
            ),
          ],
        ),
      );
      final store = await FilmCatalogStore.open(
        p.join(temp.path, 'catalog.db'),
      );
      final rootIds = <int>[];
      for (final name in ['Movies', 'Movies2', 'TV']) {
        rootIds.add(
          await store.addRoot(
            sourceId: 'local:ui',
            kind: MediaSourceKind.local,
            path: name,
            type: name == 'TV' ? FilmMediaType.tv : FilmMediaType.movie,
            name: name,
          ),
        );
      }
      final workIds = <int>[];
      for (final id in [rootIds.first, rootIds.last]) {
        final root = (await store.root(id))!;
        final generation = await store.beginScan(id);
        final file = root.type == FilmMediaType.movie
            ? filename
            : 'Show.S00E01.mkv';
        await store.stage(root, generation, [
          FilmScanEntry(
            path: '${root.path}/$file',
            parentPath: root.path,
            name: file,
            mediaKind: 'video',
          ),
          if (root.type == FilmMediaType.tv)
            const FilmScanEntry(
              path: 'TV/Show.S00E41.INFO.mkv',
              parentPath: 'TV',
              name: 'Show.S00E41.INFO.mkv',
              mediaKind: 'video',
            ),
          if (root.type == FilmMediaType.tv)
            const FilmScanEntry(
              path: 'TV/Show.S01E01.mkv',
              parentPath: 'TV',
              name: 'Show.S01E01.mkv',
              mediaKind: 'video',
            ),
        ]);
        await store.commitScan(id, generation, cancelled: () => false);
        await store.bind(
          await store.resources(rootId: id),
          FilmWork(
            type: root.type,
            tmdbId: id,
            title: root.type == FilmMediaType.movie ? '电影作品' : '剧集作品',
            originalTitle: root.path,
            overview: 'Overview',
            backdropPath: '/backdrop.jpg',
            language: 'zh-CN',
          ),
        );
        final resources = await store.resources(rootId: id);
        final resource = resources.first;
        workIds.add(resource.workId!);
        if (root.type == FilmMediaType.tv) {
          await store.saveSeason(resource.workId!, 0, 'zh-CN', {
            'season_number': 0,
            'episodes': [
              {
                'episode_number': 1,
                'name': '特别篇第一集',
                'still_path': '/still.jpg',
                'overview': 'Episode overview',
                'air_date': '2020-01-01',
                'runtime': 24,
              },
            ],
          });
          await store.saveSeason(resource.workId!, 1, 'zh-CN', {
            'season_number': 1,
            'poster_path': '/season.jpg',
            'episodes': [
              {
                'episode_number': 1,
                'name': '常规第一集',
                'still_path': '/regular.jpg',
              },
            ],
          });
          await store.mapEpisodes({
            resource: (0, 1),
            resources[1]: (0, 41),
            resources.last: (1, 1),
          });
        }
      }
      final tmdb = TmdbMetadataService(credentials: _NoCredentials());
      final c = FilmCatalogController(
        store: store,
        tmdb: tmdb,
        images: FilmCatalogImageCache(
          Directory(p.join(temp.path, 'images')),
          tmdb,
        ),
        sourceFor: (_) => throw const FilmCatalogException('sourceUnavailable'),
      );
      final progress = await PlaybackProgressService.open(
        inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      final player = _LibraryPlayer(configStore: config);
      final app = _FilmApp(
        c,
        configStore: config,
        playerService: player,
        playbackHistoryStore: PlaybackHistoryStore.forPath(
          p.join(temp.path, 'history.json'),
        ),
        progressService: progress,
      );
      await c.refresh();
      return (temp, c, progress, app, player, rootIds, workIds);
    });
    final (temp, c, progress, app, player, rootIds, workIds) = fixture!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        app.dispose();
        await c.close();
        await progress.close();
        await temp.delete(recursive: true);
      });
    });
    Widget frame(Widget page) => ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    );
    Future<void> settle() async {
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.pumpWidget(frame(FilmLibraryPage(onOpenItem: (_) async {})));
    await settle();
    final movieCard = find
        .byWidgetPredicate(
          (w) => w is FilmWorkCard && w.work.id == workIds.first,
        )
        .first;
    await tester.tap(movieCard, buttons: kSecondaryMouseButton);
    await settle();
    expect(find.byWidgetPredicate((w) => w is PopupMenuItem), findsNWidgets(8));
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('刷新元数据'), findsOneWidget);
    await tester.tap(find.text('收藏'));
    await settle();
    expect(
      await tester.runAsync(() => c.store.isFavorite(workIds.first)),
      isTrue,
    );
    final filter = tester.widget<SPDropdownButtonFormField<int>>(
      find.byWidgetPredicate(
        (widget) => widget is SPDropdownButtonFormField<int>,
      ),
    );
    final dropdown = filter;
    expect(dropdown.items!.map((i) => i.value), [0, ...rootIds]);
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate((w) => w is FilmShelf && w.title == '最近添加'),
        matching: find.text('查看全部'),
      ),
    );
    await settle();
    expect(c.works, hasLength(2));
    await tester.tap(movieCard, buttons: kSecondaryMouseButton);
    await settle();
    expect(find.text('取消收藏'), findsOneWidget);
    await tester.tapAt(const Offset(1100, 700));
    await tester.pumpAndSettle();
    filter.onChanged!(rootIds.last);
    await settle();
    expect(c.works.single.title, '剧集作品');
    c.rootId = null;
    await tester.runAsync(() => c.refresh());
    await tester.pumpWidget(
      frame(
        FilmFavoritesWall(loadCatalog: () async => c, onOpenItem: (_) async {}),
      ),
    );
    await settle();
    await tester.tap(movieCard, buttons: kSecondaryMouseButton);
    await settle();
    await tester.tap(find.text('取消收藏'));
    await pumpUntil(
      tester,
      () => find.text('还没有收藏媒体').evaluate().isNotEmpty,
      reason: 'Favorites must refresh after the removal is committed',
    );
    expect(find.text('还没有收藏媒体'), findsOneWidget);
    expect(
      await tester.runAsync(() => c.store.isFavorite(workIds.first)),
      isFalse,
    );
    MediaLibraryItem? opened;
    await tester.pumpWidget(
      frame(
        FilmDetailPage(
          catalog: c,
          workId: workIds.last,
          onOpenItem: (item) async {
            opened = item;
          },
        ),
      ),
    );
    await settle();
    expect(find.byType(AppBar), findsNothing);
    expect(find.byKey(const Key('film-detail-back')), findsOneWidget);
    expect(find.text('刷新元数据'), findsNothing);
    await tester.tap(
      find.byKey(const Key('film-detail-poster')),
      buttons: kSecondaryMouseButton,
    );
    await settle();
    await tester.pumpAndSettle();
    expect(find.text('刷新元数据'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is PopupMenuItem), findsNWidgets(8));
    expect(find.text('标记已看完'), findsOneWidget);
    expect(find.text('标记未观看'), findsOneWidget);
    await tester.tapAt(const Offset(1100, 700));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('film-season-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('film-season-1')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('1. 常规第一集'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('1. 常规第一集'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('film-season-0')));
    await tester.tap(
      find.byKey(const ValueKey('film-season-0')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.byWidgetPredicate((w) => w is PopupMenuItem), findsNWidgets(4));
    expect(find.text('季观看状态'), findsNothing);
    expect(find.byType(Dialog), findsNothing);
    await tester.tapAt(const Offset(1100, 700));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('film-season-0')));
    await tester.pump();
    expect(find.text('特别篇'), findsWidgets);
    expect(find.text('1. 特别篇第一集'), findsOneWidget);
    expect(find.text('41. 剧集作品'), findsOneWidget);
    expect(find.byKey(const ValueKey('film-season-unmapped')), findsNothing);
    expect(
      await tester.runAsync(() => c.store.pendingCount(rootId: rootIds.last)),
      0,
    );
    final generic = tester
        .widgetList<FilmEpisodeCard>(find.byType(FilmEpisodeCard))
        .singleWhere((card) => card.resource.episode == 41);
    expect(generic.episode, isNull);
    expect(generic.displayTitle, '剧集作品');
    final genericArtwork = tester.widget<FilmArtwork>(
      find.descendant(
        of: find.byKey(ValueKey('film-resource-${generic.resource.id}')),
        matching: find.byType(FilmArtwork),
      ),
    );
    expect(genericArtwork.path, '/backdrop.jpg');
    expect(genericArtwork.target, 'w780');
    expect(find.text('Show.S00E41.INFO.mkv'), findsNothing);
    expect(find.text('Show.S00E01.mkv'), findsNothing);
    expect(find.text('调整季集'), findsNothing);
    expect(find.byKey(const Key('film-detail-backdrop')), findsOneWidget);
    final backdrop = tester.widget<FilmArtwork>(
      find.byKey(const Key('film-detail-backdrop')),
    );
    expect(backdrop.target, 'original');
    expect(backdrop.backdrop, isTrue);
    expect(
      tester.getSize(find.byKey(const Key('film-detail-backdrop'))).height,
      greaterThan(620),
    );
    final still = tester
        .widgetList<FilmArtwork>(find.byType(FilmArtwork))
        .where((w) => w.target == 'w300')
        .single;
    expect(still.path, '/still.jpg');
    final officialCard = find.byKey(
      ValueKey(
        'film-resource-${tester.widgetList<FilmEpisodeCard>(find.byType(FilmEpisodeCard)).singleWhere((card) => card.resource.episode == 1).resource.id}',
      ),
    );
    await tester.ensureVisible(officialCard);
    await tester.tap(officialCard);
    expect(opened!.playbackScope, VideoPlaybackScope.directory);
    await tester.tap(officialCard, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('调整季集'), findsOneWidget);
    await tester.tap(find.text('查看来源信息'));
    await settle();
    await tester.pumpAndSettle();
    expect(find.text('Show.S00E01.mkv'), findsOneWidget);
    expect(find.text('TV/Show.S00E01.mkv'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    await tester.runAsync(
      () => app.playbackHistoryStore.upsert(
        PlaybackHistory(
          sessionId: 'browser-only',
          sourceId: app.localRoots.single.sourceId,
          dirCrumbs: const [],
          fileName: 'BrowserOnly.mkv',
          videoIndex: 0,
          updatedAt: DateTime.now(),
        ),
      ),
    );
    await tester.pumpWidget(frame(const FilmLibraryShell()));
    await settle();
    await tester.tap(find.text('电影作品').first);
    await settle();
    expect(find.text('Movie.2020.PROPER.1080p.mkv'), findsNothing);
    expect(find.text('纠正作品匹配'), findsNothing);
    await tester.ensureVisible(find.text('播放此文件').first);
    await tester.tap(find.text('播放此文件').first);
    await settle();
    for (var i = 0; i < 60 && player.calls == 0; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(PlaybackBar), findsNothing);
    expect(find.byType(PlaybackBar, skipOffstage: false), findsOneWidget);
    expect(player.calls, 1);
    expect(
      (await tester.runAsync(
        () => app.playbackHistoryStore.loadAll(),
      ))!.single.fileName,
      'BrowserOnly.mkv',
    );
    expect(
      await tester.runAsync(() => app.filmPlaybackHistoryStore.loadAll()),
      hasLength(1),
    );
    expect(player.entries, hasLength(1));
    expect(find.byType(FilmDetailPage), findsOneWidget);
    expect(find.byType(DirectoryBreadcrumbs), findsNothing);
    expect(find.byType(PlaybackBar), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(frame(const FilmLibraryShell()));
    await settle();
    expect(find.byType(PlaybackBar, skipOffstage: false), findsOneWidget);
    final hostBar = tester.widget<PlaybackBar>(
      find.byType(PlaybackBar, skipOffstage: false),
    );
    hostBar.onPressed?.call();
    await settle();
    for (var i = 0; i < 60 && player.calls < 2; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(player.calls, 2);
    expect(find.byType(FilmLibraryPage), findsOneWidget);
    expect(find.byType(DirectoryBreadcrumbs), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await settle();
    const sourceId = 'film-network-ui';
    await tester.runAsync(() async {
      await app.configStore.save(
        app.configStore.current
            .upsertProfile(
              const ServerProfile(
                profileId: sourceId,
                name: 'Network fixture',
                serverUrl: 'https://film-ui.invalid',
              ),
            )
            .withMountedProfileIds([sourceId]),
      );
    });
    final saved = app.filmPlaybackHistoryStore.upsert(
      PlaybackHistory(
        sessionId: 'network-single',
        sourceId: sourceId,
        dirCrumbs: const ['Movies'],
        fileName: 'Network.2020.mkv',
        videoIndex: 0,
        updatedAt: DateTime.now(),
        playlistFileNames: const ['Network.2020.mkv'],
        playbackScope: VideoPlaybackScope.singleItem,
      ),
    );
    await settle();
    await saved;
    final restored = Completer<void>();
    app.restoreSources = () async {
      await restored.future;
      app.restoredServices[sourceId] = WebDAVService(
        client: WebDavClient(baseUrl: 'https://film-ui.invalid'),
        profileId: sourceId,
      );
    };
    await tester.pumpWidget(frame(const FilmLibraryShell()));
    await settle();
    expect(find.byType(PlaybackBar, skipOffstage: false), findsOneWidget);
    restored.complete();
    await settle();
    expect(app.restoredServices.containsKey(sourceId), isTrue);
    expect(find.byType(PlaybackBar, skipOffstage: false), findsNWidgets(2));
    expect(find.byType(DirectoryBreadcrumbs), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await settle();
    app.dispose();
  });

  testWidgets('海报墙提前自动加载、窗口补足、数据刷新保留范围且筛选重置分页', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('film_prefetch_ui_');
      final store = await FilmCatalogStore.open(
        p.join(temp.path, 'catalog.db'),
      );
      final rootId = await store.addRoot(
        sourceId: 'local:offline',
        kind: MediaSourceKind.local,
        path: 'Films',
        type: FilmMediaType.movie,
        name: 'Films',
      );
      final root = (await store.root(rootId))!;
      final generation = await store.beginScan(root.id);
      final entries = [
        for (var i = 0; i < 140; i++)
          FilmScanEntry(
            path: 'Films/Title${i.toString().padLeft(3, '0')}.2021.mkv',
            parentPath: 'Films',
            name: 'Title${i.toString().padLeft(3, '0')}.2021.mkv',
            mediaKind: 'video',
          ),
      ];
      await store.stage(root, generation, entries);
      await store.commitScan(root.id, generation, cancelled: () => false);
      await store.applyMetadata(root.id, {
        for (var i = 0; i < entries.length; i++)
          filmPathKey(entries[i].path, root.sourceKind): FilmScanMatch(
            work: FilmWork(
              type: FilmMediaType.movie,
              tmdbId: 1000 + i,
              title: 'Title${i.toString().padLeft(3, '0')}',
              originalTitle: 'Title${i.toString().padLeft(3, '0')}',
              overview: '',
              language: 'zh-CN',
              metadata: {},
            ),
            origin: 'search',
            bindingVersion: 0,
          ),
      });
      final tmdb = TmdbMetadataService(credentials: _NoCredentials());
      final c = FilmCatalogController(
        store: store,
        tmdb: tmdb,
        images: FilmCatalogImageCache(
          Directory(p.join(temp.path, 'images')),
          tmdb,
        ),
        sourceFor: (_) => throw StateError('Unexpected source access'),
      );
      final progress = await PlaybackProgressService.open(
        inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      final app = _FilmApp(
        c,
        configStore: StreamPathConfigStore.forPath(
          p.join(temp.path, 'config.json'),
        ),
        playbackHistoryStore: PlaybackHistoryStore.forPath(
          p.join(temp.path, 'history.json'),
        ),
        progressService: progress,
      );
      return (temp, c, progress, app);
    });
    final (temp, c, progress, app) = fixture!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        app.dispose();
        await c.close();
        await progress.close();
        await temp.delete(recursive: true);
      });
    });
    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: FilmLibraryPage(onOpenItem: (_) async {}),
        ),
      ),
    );
    await settle();
    expect(c.works, hasLength(60));
    final homeScroll = tester
        .widgetList<ListView>(find.byType(ListView))
        .firstWhere((view) => view.padding == const EdgeInsets.all(20))
        .controller!;
    for (
      var i = 0;
      i < 15 &&
          find
              .byWidgetPredicate((w) => w is FilmShelf && w.title == '最近添加')
              .evaluate()
              .isEmpty;
      i++
    ) {
      homeScroll.jumpTo(
        (homeScroll.offset + 240).clamp(0, homeScroll.position.maxScrollExtent),
      );
      await tester.pump();
    }
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate((w) => w is FilmShelf && w.title == '最近添加'),
        matching: find.text('查看全部'),
      ),
    );
    await settle();
    expect(find.text('加载更多'), findsNothing);
    final scroll = tester.widget<GridView>(find.byType(GridView)).controller!;
    final firstEnd = scroll.position.maxScrollExtent;
    scroll.jumpTo(firstEnd - 900);
    expect(scroll.position.extentAfter, greaterThan(0));
    await settle();
    expect(c.works, hasLength(120));
    expect(c.works.map((w) => w.id).toSet(), hasLength(120));
    expect(scroll.position.pixels, lessThan(firstEnd));
    final position = scroll.position.pixels;
    await tester.runAsync(() => c.store.setLanguage('en-US'));
    await settle();
    expect(c.works, hasLength(120));
    expect(scroll.position.pixels, position);
    scroll.jumpTo(scroll.position.maxScrollExtent - 900);
    await settle();
    expect(c.works, hasLength(140));
    expect(c.hasMore, isFalse);
    expect(c.works.map((w) => w.id).toSet(), hasLength(140));
    c.query = 'Title139';
    await tester.runAsync(() => c.refresh());
    await settle();
    expect(c.works.single.title, 'Title139');
    expect(c.hasMore, isFalse);
    tester.view.physicalSize = const Size(2400, 1800);
    c.query = '';
    await tester.runAsync(() => c.refresh());
    await settle();
    expect(c.works, hasLength(140));
    expect(find.text('加载更多'), findsNothing);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: FilmLibraryManagePage(catalog: c, directories: true),
        ),
      ),
    );
    await settle();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '增量扫描'))
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '增量刮削'))
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
    app.dispose();
  });

  for (final language in AppLanguage.values) {
    for (final scale in [1.0, 1.5, 2.0]) {
      for (final dark in [false, true]) {
        testWidgets('影视页四语言/明暗/文字缩放 $language $scale $dark', (tester) async {
          tester.view.physicalSize = const Size(1280, 720);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final fixture = await tester.runAsync(() async {
            final temp = await Directory.systemTemp.createTemp('film_ui_');
            final store = await FilmCatalogStore.open(
              p.join(temp.path, 'catalog.db'),
            );
            final rootId = await store.addRoot(
              sourceId: 'local:offline',
              kind: MediaSourceKind.local,
              path: 'Films',
              type: FilmMediaType.tv,
              name: '离线来源 / Offline source',
            );
            final root = (await store.root(rootId))!;
            final generation = await store.beginScan(root.id);
            await store.stage(root, generation, const [
              FilmScanEntry(
                path: 'Films/Series.S01E01.mkv',
                parentPath: 'Films',
                name: 'Series.S01E01.mkv',
                mediaKind: 'video',
              ),
              FilmScanEntry(
                path: 'Films/Series.S01E02.mkv',
                parentPath: 'Films',
                name: 'Series.S01E02.mkv',
                mediaKind: 'video',
              ),
            ]);
            await store.commitScan(root.id, generation, cancelled: () => false);
            await store.bind(
              [(await store.resources()).first],
              const FilmWork(
                type: FilmMediaType.tv,
                tmdbId: 10,
                title: '长标题作品 / Long title / 長いタイトル',
                originalTitle: 'Long original title',
                overview: 'Cached overview available offline.',
                language: 'zh-CN',
                metadata: {
                  'genres': ['Drama'],
                  'vote_average': 8.5,
                  'vote_count': 100,
                  'credits': {
                    'cast': [
                      {'name': '神木隆之介', 'character': '立花泷'},
                      {'name': '上白石萌音', 'character': '宫水三叶'},
                    ],
                    'crew': [
                      {'name': '新海诚', 'job': 'Director'},
                    ],
                  },
                },
              ),
            );
            final work = (await store.works(type: FilmMediaType.tv)).single;
            final tmdb = TmdbMetadataService(credentials: _NoCredentials());
            final c = FilmCatalogController(
              store: store,
              tmdb: tmdb,
              images: FilmCatalogImageCache(
                Directory(p.join(temp.path, 'images')),
                tmdb,
              ),
              sourceFor: (_) =>
                  throw const FilmCatalogException('sourceUnavailable'),
            );
            final progress = await PlaybackProgressService.open(
              inMemoryDatabasePath,
              factory: databaseFactoryFfi,
            );
            final app = _FilmApp(
              c,
              configStore: StreamPathConfigStore.forPath(
                p.join(temp.path, 'config.json'),
              ),
              playbackHistoryStore: PlaybackHistoryStore.forPath(
                p.join(temp.path, 'history.json'),
              ),
              progressService: progress,
            );
            c.type = FilmMediaType.tv;
            await c.refresh();
            return (temp, c, progress, app, work.id);
          });
          final (temp, c, progress, app, workId) = fixture!;
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(() async {
              app.dispose();
              await c.close();
              await progress.close();
              await temp.delete(recursive: true);
            });
          });
          MediaLibraryItem? opened;
          Future<void> open(MediaLibraryItem item) async {
            opened = item;
          }

          Widget frame(Widget page) => ChangeNotifierProvider<AppState>.value(
            value: app,
            child: MaterialApp(
              locale: language.locale,
              supportedLocales: AppLanguage.values.map((l) => l.locale),
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              theme: dark ? AppTheme.dark() : AppTheme.light(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: page,
            ),
          );
          Future<void> settle() async {
            for (var i = 0; i < 8; i++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 10)),
              );
              await tester.pump(const Duration(milliseconds: 100));
            }
          }

          for (final page in <Widget>[
            FilmLibraryPage(onOpenItem: open),
            FilmLibraryManagePage(catalog: c),
            FilmLibraryManagePage(catalog: c, directories: true),
            FilmDetailPage(catalog: c, workId: workId, onOpenItem: open),
            FilmPendingPage(catalog: c, onOpenItem: open),
          ]) {
            await tester.pumpWidget(frame(page));
            await settle();
            expect(tester.takeException(), isNull);
            if (page is FilmDetailPage) {
              final creditsTitle = find.text(
                AppLocalizations(language).text('演职人员'),
              );
              await tester.ensureVisible(creditsTitle);
              await tester.pump();
              expect(find.text('神木隆之介'), findsOneWidget);
              expect(find.text('新海诚'), findsOneWidget);
              expect(tester.takeException(), isNull);
            }
            if (page is FilmLibraryManagePage && page.directories) {
              final l10n = AppLocalizations(language);
              expect(find.text(l10n.text('增量扫描')), findsOneWidget);
              expect(find.text(l10n.text('增量刮削')), findsOneWidget);
              expect(
                tester
                    .widget<TextButton>(
                      find.widgetWithText(TextButton, l10n.text('增量刮削')),
                    )
                    .onPressed,
                isNotNull,
              );
              final add = find.ancestor(
                of: find.text(AppLocalizations(language).text('添加影视目录')),
                matching: find.byWidgetPredicate(
                  (widget) => widget is FilledButton,
                ),
              );
              expect(
                tester.getTopLeft(find.byType(Card).first).dy -
                    tester.getBottomLeft(add).dy,
                greaterThanOrEqualTo(16),
              );
            }
          }
          final play = find.text(AppLocalizations(language).text('播放此文件'));
          await tester.ensureVisible(play.first);
          await tester.tap(play.first);
          await tester.pump();
          expect(opened!.playbackScope, VideoPlaybackScope.directory);
          expect(opened!.sourceId, 'local:offline');
          final resource = await tester.runAsync(
            () async => (await c.store.resources()).last,
          );
          await tester.pumpWidget(
            frame(
              Scaffold(
                body: Center(
                  child: FilmMatchDialog(catalog: c, resource: resource!),
                ),
              ),
            ),
          );
          await settle();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await settle();
          app.dispose();
        });
      }
    }
  }
}

class _NoCredentials extends TmdbCredentialStore {
  @override
  Future<String?> read() async => null;
}

class _SavedCredentials extends TmdbCredentialStore {
  String? token;
  @override
  Future<String?> read() async => token;
  @override
  Future<void> write(String value) async => token = value;
}

class _FilmApp extends AppState {
  _FilmApp(
    this.catalog, {
    required super.configStore,
    required super.playbackHistoryStore,
    required super.progressService,
    super.playerService,
  });
  final FilmCatalogController catalog;
  bool disposed = false;
  @override
  void dispose() {
    if (disposed) return;
    disposed = true;
    super.dispose();
  }

  final restoredServices = <String, WebDAVService>{};
  Future<void> Function()? restoreSources;
  @override
  WebDAVService? mountedService(String profileId) =>
      restoredServices[profileId] ?? super.mountedService(profileId);
  @override
  Future<void> restoreMountedProfiles() =>
      restoreSources?.call() ?? super.restoreMountedProfiles();
  @override
  Future<FilmCatalogController> getFilmCatalog() async => catalog;
  @override
  Future<FilmCatalogStore> getFilmCatalogStore() async => catalog.store;
}

class _LibraryPlayer extends ExternalPlayerService {
  _LibraryPlayer({required super.configStore});
  @override
  ExternalPlayerService forFilmLibrary(
    PlaybackProgressService progress,
    Directory watchLater,
  ) => this;
  int calls = 0;
  List<MediaEntry>? entries;
  @override
  Future<PlayerLaunchResult> launchLocal({
    ImplicitVideoPlan? implicitPlan,
    required List<MediaEntry> entries,
    required String sourceId,
    String? sessionId,
    int playlistStart = 0,
    int? resumeSeconds,
    List<String?>? localFontDirectories,
    SeasonPlaybackEntries? nextSeason,
  }) async {
    this.entries = entries;
    calls++;
    throw AppException.process('Test player stopped');
  }
}
