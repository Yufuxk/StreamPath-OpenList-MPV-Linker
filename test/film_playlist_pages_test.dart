import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/film_playlist.dart';
import 'package:streampath/data/models/film_watch_state.dart';
import 'package:streampath/data/models/media_connection.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_entry.dart';
import 'package:streampath/data/models/playback_history.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/data/models/video_playlist_mode.dart';
import 'package:streampath/data/models/video_queue.dart';
import 'package:streampath/domain/services/external_player_service.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/pages/browser_page.dart';
import 'package:streampath/presentation/pages/film_playlist_page.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/directory_scroll_view.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';
import 'package:streampath/presentation/widgets/film_playlist_dialog.dart';
import 'package:streampath/presentation/widgets/sp_menu.dart';
import 'package:streampath/presentation/widgets/sp_reorderable.dart';

import 'helpers/pump_until.dart';

Future<
  (
    _App,
    FilmCatalogController,
    String,
    Directory,
    _Player,
    PlaybackProgressService,
  )
>
_fixture({TmdbMetadataService? metadata}) async {
  final dir = await Directory.systemTemp.createTemp('playlist_ui_');
  final config = StreamPathConfigStore.forPath('${dir.path}/config.json');
  final local = LocalRootConfig(
    rootId: 'fixture',
    displayName: 'Source',
    path: dir.path,
  );
  await config.save(
    StreamPathConfig(
      localRoots: [local],
      playerExecutable: 'fake_mpv.exe',
      videoPlaylistMode: VideoPlaylistMode.legacy,
      subtitleInjectionEnabled: false,
      sharePlaylistFonts: false,
    ),
  );
  final store = await FilmCatalogStore.open('${dir.path}/catalog.db');
  final progress = await PlaybackProgressService.open(
    '${dir.path}/progress.db',
  );
  for (final (path, type) in [
    ('Shows', FilmMediaType.tv),
    ('Movies', FilmMediaType.movie),
  ]) {
    await Directory('${dir.path}/$path').create();
    final root = (await store.root(
      await store.addRoot(
        sourceId: local.sourceId,
        kind: MediaSourceKind.local,
        path: path,
        type: type,
        name: 'Source',
      ),
    ))!;
    final names = type == FilmMediaType.tv ? ['A.mkv', 'B.mkv'] : ['Movie.mkv'];
    for (final name in names) {
      await File('${dir.path}/$path/$name').writeAsBytes([]);
    }
    final generation = await store.beginScan(root.id);
    await store.stage(root, generation, [
      for (final name in names)
        FilmScanEntry(
          path: '$path/$name',
          parentPath: path,
          name: name,
          mediaKind: 'video',
        ),
    ]);
    await store.commitScan(root.id, generation, cancelled: () => false);
    await store.bind(
      await store.resources(rootId: root.id),
      FilmWork(
        type: type,
        tmdbId: root.id,
        title: type == FilmMediaType.tv ? 'Series' : 'Movie',
        originalTitle: path,
        overview: '',
        language: 'en',
        year: 2024,
      ),
    );
    if (type == FilmMediaType.tv) {
      final rows = await store.resources(rootId: root.id);
      await store.mapEpisodes({rows[0]: (1, 1), rows[1]: (1, 2)});
    }
  }
  final tv = (await store.resources()).firstWhere(
    (r) => r.type == FilmMediaType.tv,
  );
  final movie = (await store.resources()).firstWhere(
    (r) => r.type == FilmMediaType.movie,
  );
  final id = await store.createPlaylist(
    'Watch',
    local.sourceId,
    MediaSourceKind.local,
    'Source',
    FilmPlaylistScope.work(tv.workId!),
  );
  await store.addPlaylistScope(
    id,
    local.sourceId,
    FilmPlaylistScope.work(movie.workId!),
  );
  final tmdb = metadata ?? TmdbMetadataService(credentials: _Credentials());
  final catalog = FilmCatalogController(
    store: store,
    tmdb: tmdb,
    images: FilmCatalogImageCache(Directory('${dir.path}/images'), tmdb),
    sourceFor: (_) => throw StateError('Unexpected source access'),
  );
  final player = _Player(configStore: config);
  final app = _App(
    catalog,
    configStore: config,
    playbackHistoryStore: PlaybackHistoryStore.forPath(
      '${dir.path}/history.json',
    ),
    progressService: progress,
    playerService: player,
    mediaLibraryStore: MediaLibraryStore.forPath('${dir.path}/records.json'),
  );
  return (app, catalog, id, dir, player, progress);
}

Widget _frame(
  _App app,
  Widget child, {
  Locale locale = const Locale('zh', 'CN'),
  double scale = 1,
}) => ChangeNotifierProvider<AppState>.value(
  value: app,
  child: MaterialApp(
    theme: AppTheme.dark(),
    locale: locale,
    supportedLocales: const [
      Locale('zh', 'CN'),
      Locale('zh', 'TW'),
      Locale('ja'),
      Locale('en'),
    ],
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: child,
  ),
);
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 45; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  setUpAll(sqfliteFfiInit);
  for (final mode in ['legacy', 'implicit', 'custom']) {
    testWidgets('continue uses the advanced history target for $mode', (
      tester,
    ) async {
      final (app, catalog, id, dir, player, progress) = (await tester.runAsync(
        _fixture,
      ))!;
      try {
        final snapshot = (await tester.runAsync(
          () => catalog.store.playlistSnapshot(id),
        ))!;
        final entries = mode == 'custom'
            ? snapshot.entries
            : snapshot.entries.take(2).toList();
        final history = PlaybackHistory(
          dirCrumbs: const ['Shows'],
          fileName: 'A.mkv',
          videoIndex: 0,
          updatedAt: DateTime.now(),
          sessionId: 'advance',
          sourceId: 'local:fixture',
          playlistFileNames: entries.map((e) => e.resource!.name).toList(),
          playlistRelativePaths: entries.map((e) => e.resource!.path).toList(),
          videoPlaylistMode: mode == 'legacy'
              ? VideoPlaylistMode.legacy
              : VideoPlaylistMode.implicit,
          queueItems: mode == 'legacy'
              ? const []
              : snapshot.queueItems.take(entries.length).toList(),
          filmPlaylistId: mode == 'custom' ? id : null,
          filmPlaylistEntryIds: mode == 'custom'
              ? entries.map((e) => e.id).toList()
              : const [],
        );
        await tester.runAsync(() async {
          await app.configStore.save(
            StreamPathConfig.fromJson({
              ...app.configStore.current.toJson(),
              'videoPlaylistMode': history.videoPlaylistMode.name,
            }),
          );
          await app.filmPlaybackHistoryStore.upsert(history);
          await app.filmMediaLibraryStore!.recordPlayback(
            entries.first.resource!.playbackItem,
            playbackSessionId: history.sessionId,
            playlistIndex: 0,
            playlistCount: entries.length,
          );
          await app.initializeFilmPlayback();
          await app.filmProgressService.saveProgress(
            url: '${dir.path}/Shows/A.mkv',
            profileId: history.sourceId,
            positionMs: 20000,
            durationMs: 600000,
          );
        });
        final key = GlobalKey<BrowserPageState>();
        await tester.pumpWidget(
          _frame(
            app,
            Scaffold(
              body: BrowserPage(
                key: key,
                localRoot: app.localRoots.single,
                playbackOnly: true,
              ),
            ),
          ),
        );
        await _settle(tester);
        late Future<void> marking;
        await tester.runAsync(() async {
          marking = app.markFilmWatched([entries.first.resource!], true);
        });
        await _settle(tester);
        await tester.runAsync(
          () => marking.timeout(const Duration(seconds: 5)),
        );
        if (mode == 'custom') {
          await tester.runAsync(() => catalog.store.deletePlaylist(id));
        }
        final next = (await tester.runAsync(
          () => app.filmMediaLibraryStore!.playbackHistory(
            'local:fixture',
            audio: false,
          ),
        ))!.single;
        expect(next.item.name, 'B.mkv');
        expect(next.playbackSessionId, history.sessionId);
        Future<void>? resumed;
        await tester.runAsync(() async {
          resumed = key.currentState!.playLibraryItem(
            next.item,
            resumeSessionId: next.playbackSessionId,
          );
        });
        for (var i = 0; i < 10 && player.plans.isEmpty; i++) {
          await _settle(tester);
        }
        await tester.runAsync(() => resumed!);
        expect(player.launchedNames.single, 'B.mkv');
        expect(player.launchedSessionIds.single, history.sessionId);
        if (mode == 'legacy') {
          expect(player.starts.single, 1);
        } else {
          expect(player.plans.single!.index, 1);
          expect(
            player.plans.single!.items.map((i) => i.versions.single.path),
            history.playlistRelativePaths,
          );
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        await tester.runAsync(() async {
          app.dispose();
          await catalog.close();
          await progress.close();
          await dir.delete(recursive: true);
        });
      }
    });
  }
  testWidgets(
    'outer cover menu refreshes each work once, marks only members and copies current order',
    (tester) async {
      final tmdb = _Metadata();
      final (app, catalog, id, dir, _, progress) = (await tester.runAsync(
        () => _fixture(metadata: tmdb),
      ))!;
      try {
        final snapshot = (await tester.runAsync(
          () => catalog.store.playlistSnapshot(id),
        ))!;
        await tester.runAsync(() async {
          await catalog.store.removePlaylistEntry(id, snapshot.entries[1].id);
          await catalog.store.reorderPlaylist(id, [
            snapshot.entries.last.id,
            snapshot.entries.first.id,
          ]);
        });
        await tester.pumpWidget(
          _frame(
            app,
            FilmPlaylistPage(catalog: catalog, onPlay: (_, _) async {}),
          ),
        );
        await _settle(tester);
        Future<void> menu() async {
          await tester.tapAt(
            tester.getTopLeft(find.byKey(ValueKey(id))) + const Offset(64, 32),
            buttons: kSecondaryMouseButton,
          );
          await _settle(tester);
        }

        await menu();
        for (final label in [
          '刷新元数据',
          '标记已看完',
          '标记未看完',
          '加入播放列表…',
          '以本列表创建播放列表',
          '重命名',
          '删除播放列表',
        ]) {
          expect(find.text(label), findsOneWidget);
        }
        expect(find.text('以本集创建播放列表'), findsNothing);
        await tester.tap(find.text('刷新元数据'));
        await _settle(tester);
        expect(catalog.error, isNull);
        expect(tmdb.works.length, 2);
        expect(tmdb.works.map((w) => w.$1).toSet(), {
          FilmMediaType.tv,
          FilmMediaType.movie,
        });
        expect(tmdb.seasons.length, 1);
        await menu();
        await tester.tap(find.text('标记已看完'));
        await _settle(tester);
        expect(
          (await tester.runAsync(
            () => catalog.store.resourceWatchState(
              snapshot.entries.first.resource!,
            ),
          ))!.status,
          FilmWatchStatus.watched,
        );
        expect(
          (await tester.runAsync(
            () =>
                catalog.store.resourceWatchState(snapshot.entries[1].resource!),
          ))!.status,
          FilmWatchStatus.unwatched,
        );
        expect(
          (await tester.runAsync(
            () => catalog.store.resourceWatchState(
              snapshot.entries.last.resource!,
            ),
          ))!.status,
          FilmWatchStatus.watched,
        );
        await menu();
        await tester.tap(find.text('标记未看完'));
        await _settle(tester);
        expect(
          (await tester.runAsync(
            () => catalog.store.resourceWatchState(
              snapshot.entries.first.resource!,
            ),
          ))!.status,
          FilmWatchStatus.unwatched,
        );
        await menu();
        await tester.tap(find.text('以本列表创建播放列表'));
        await _settle(tester);
        expect(find.text('保留所选条目及版本设定，不自动追加'), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'From list');
        await tester.tap(find.widgetWithText(FilledButton, '创建播放列表'));
        await _settle(tester);
        final lists = (await tester.runAsync(() => catalog.store.playlists()))!;
        final copy = (await tester.runAsync(
          () => catalog.store.playlistSnapshot(
            lists.firstWhere((l) => l.name == 'From list').id,
          ),
        ))!;
        expect(copy.entries.map((e) => e.title), ['Movie', 'Series']);
        expect(
          copy.entries
              .map((e) => e.id)
              .toSet()
              .intersection(snapshot.entries.map((e) => e.id).toSet()),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        await tester.runAsync(() async {
          app.dispose();
          await catalog.close();
          await progress.close();
          await dir.delete(recursive: true);
        });
      }
    },
  );
  testWidgets('inner cover menu marks and copies only its selected episode', (
    tester,
  ) async {
    final (app, catalog, id, dir, _, progress) = (await tester.runAsync(
      _fixture,
    ))!;
    try {
      final snapshot = (await tester.runAsync(
        () => catalog.store.playlistSnapshot(id),
      ))!;
      final target = (await tester.runAsync(
        () => catalog.store.copyPlaylist(
          id,
          'Episode target',
          entryId: snapshot.entries.last.id,
        ),
      ))!;
      await tester.pumpWidget(
        _frame(
          app,
          FilmPlaylistPage(
            catalog: catalog,
            playlistId: id,
            onPlay: (_, _) async {},
          ),
        ),
      );
      await _settle(tester);
      Future<void> menu() async {
        await pumpUntil(
          tester,
          () => tester
              .widget<SPReorderHandle>(
                find.descendant(
                  of: find.byKey(ValueKey(snapshot.entries[1].id)),
                  matching: find.byType(SPReorderHandle),
                ),
              )
              .enabled,
          reason:
              'Playlist member actions must finish before reopening the menu',
        );
        await tester.tapAt(
          tester.getTopLeft(find.byKey(ValueKey(snapshot.entries[1].id))) +
              const Offset(64, 32),
          buttons: kSecondaryMouseButton,
        );
        await pumpUntil(
          tester,
          () => find.text('加入播放列表…').evaluate().isNotEmpty,
          reason: 'The member snapshot must load before checking its menu',
        );
        await tester.pumpAndSettle();
      }

      await menu();
      for (final label in [
        '刷新元数据',
        '标记已看完',
        '标记未看完',
        '加入播放列表…',
        '以本集创建播放列表',
        '移除成员',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('以本列表创建播放列表'), findsNothing);
      await tester.tap(find.text('标记已看完'));
      await _settle(tester);
      for (var i = 0; i < snapshot.entries.length; i++) {
        expect(
          (await tester.runAsync(
            () =>
                catalog.store.resourceWatchState(snapshot.entries[i].resource!),
          ))!.status,
          i == 1 ? FilmWatchStatus.watched : FilmWatchStatus.unwatched,
        );
      }
      await menu();
      await tester.tap(find.text('加入播放列表…'));
      await _settle(tester);
      await tester.tap(find.text('Episode target'));
      await _settle(tester);
      final added = (await tester.runAsync(
        () => catalog.store.playlistSnapshot(target),
      ))!;
      expect(added.entries.map((e) => e.title), ['Movie', 'Series']);
      expect(added.entries.map((e) => e.episode), [null, 2]);
      await menu();
      await tester.tap(find.text('以本集创建播放列表'));
      await _settle(tester);
      await tester.enterText(find.byType(TextField), 'From episode');
      await tester.tap(find.widgetWithText(FilledButton, '创建播放列表'));
      await _settle(tester);
      final lists = (await tester.runAsync(() => catalog.store.playlists()))!;
      final copy = (await tester.runAsync(
        () => catalog.store.playlistSnapshot(
          lists.firstWhere((l) => l.name == 'From episode').id,
        ),
      ))!;
      expect(copy.entries.single.episode, 2);
      expect(copy.entries.single.pinnedPath, isNull);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      await tester.runAsync(() async {
        app.dispose();
        await catalog.close();
        await progress.close();
        await dir.delete(recursive: true);
      });
    }
  });
  testWidgets(
    'outer cover adds current members to a same-source list in the shown order',
    (tester) async {
      final (app, catalog, id, dir, _, progress) = (await tester.runAsync(
        _fixture,
      ))!;
      try {
        final original = (await tester.runAsync(
          () => catalog.store.playlistSnapshot(id),
        ))!;
        final target = (await tester.runAsync(
          () => catalog.store.copyPlaylist(
            id,
            'Target',
            entryId: original.entries.last.id,
          ),
        ))!;
        await tester.pumpWidget(
          _frame(
            app,
            FilmPlaylistPage(catalog: catalog, onPlay: (_, _) async {}),
          ),
        );
        await _settle(tester);
        await tester.tapAt(
          tester.getTopLeft(find.byKey(ValueKey(id))) + const Offset(64, 32),
          buttons: kSecondaryMouseButton,
        );
        await _settle(tester);
        await tester.tap(find.text('加入播放列表…'));
        await _settle(tester);
        final dialog = find.byType(TextField).evaluate().single;
        final dialogView = find
            .ancestor(
              of: find.byWidget(dialog.widget),
              matching: find.byType(DirectoryScrollView),
            )
            .first;
        expect(
          find.descendant(
            of: dialogView,
            matching: find.widgetWithText(ListTile, 'Watch'),
          ),
          findsNothing,
        );
        await tester.tap(
          find.descendant(of: dialogView, matching: find.text('Target')),
        );
        await _settle(tester);
        final result = (await tester.runAsync(
          () => catalog.store.playlistSnapshot(target),
        ))!;
        expect(result.entries.map((e) => e.title), [
          'Movie',
          'Series',
          'Series',
        ]);
        expect(result.entries.map((e) => e.episode), [null, 1, 2]);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        await tester.runAsync(() async {
          app.dispose();
          await catalog.close();
          await progress.close();
          await dir.delete(recursive: true);
        });
      }
    },
  );
  for (final members in [false, true]) {
    testWidgets(
      'mirror cover menu offers local list actions without editing the mirror members=$members',
      (tester) async {
        final (app, catalog, _, dir, _, progress) = (await tester.runAsync(
          _fixture,
        ))!;
        try {
          const config = MediaConnection(
            id: 'server',
            kind: MediaSourceKind.jellyfin,
            name: 'Server',
            url: 'http://localhost:8096',
          );
          await tester.runAsync(() async {
            await catalog.store.rememberServerIdentity(config.id, 'host:user');
            await catalog.store.saveServerPlaylist(
              config,
              'host:user',
              {'Id': 'p', 'Name': 'Remote'},
              [
                {'Id': 'a', 'Name': 'A'},
              ],
            );
          });
          final mirror = (await tester.runAsync(
            () => catalog.store.playlistSnapshot('server:host:user:server:p'),
          ))!;
          await tester.pumpWidget(
            _frame(
              app,
              FilmPlaylistPage(
                catalog: catalog,
                playlistId: members ? mirror.playlist.id : null,
                onPlay: (_, _) async {},
              ),
            ),
          );
          await _settle(tester);
          await tester.tapAt(
            tester.getTopLeft(
                  find.byKey(
                    ValueKey(
                      members ? mirror.entries.single.id : mirror.playlist.id,
                    ),
                  ),
                ) +
                const Offset(64, 32),
            buttons: kSecondaryMouseButton,
          );
          await _settle(tester);
          expect(
            find.text(members ? '以本集创建播放列表' : '以本列表创建播放列表'),
            findsOneWidget,
          );
          expect(find.text('加入播放列表…'), findsOneWidget);
          expect(find.text('移除成员'), findsNothing);
          expect(find.text('重命名'), findsNothing);
          expect(find.text('删除播放列表'), findsNothing);
          final watched = tester.widget<PopupMenuItem<String>>(
            find.widgetWithText(PopupMenuItem<String>, '标记已看完'),
          );
          expect(watched.enabled, isFalse);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await _settle(tester);
          await tester.runAsync(() async {
            app.dispose();
            await catalog.close();
            await progress.close();
            await dir.delete(recursive: true);
          });
        }
      },
    );
  }
  for (final members in [false, true]) {
    testWidgets(
      'playlist cover clips blur and unwatched corner members=$members',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final (app, catalog, id, dir, _, progress) = (await tester.runAsync(
          _fixture,
        ))!;
        try {
          await tester.runAsync(() async {
            final recorder = ui.PictureRecorder();
            final canvas = Canvas(recorder);
            canvas.drawPaint(Paint()..color = Colors.green);
            canvas.drawRect(
              const Rect.fromLTWH(48, 0, 48, 54),
              Paint()..color = Colors.red,
            );
            final picture = recorder.endRecording();
            final image = await picture.toImage(96, 54);
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!.buffer.asUint8List();
            image.dispose();
            picture.dispose();
            final tv = (await catalog.store.resources()).firstWhere(
              (r) => r.type == FilmMediaType.tv,
            );
            await catalog.store.saveSeason(tv.workId!, 1, 'en', {
              'episodes': [
                for (final number in [1, 2])
                  {'episode_number': number, 'still_path': '/clip.png'},
              ],
            });
            await catalog.store.playlistSnapshot(id);
            await catalog.store.setPreference('spoiler_protection', false);
            await catalog.images.directory.create(recursive: true);
            await File(
              '${catalog.images.directory.path}/${FilmCatalogImageCache.cacheKey('/clip.png', 'w300')}.img',
            ).writeAsBytes(bytes);
          });
          await tester.pumpWidget(
            RepaintBoundary(
              key: const Key('playlist-cover-render'),
              child: _frame(
                app,
                FilmPlaylistPage(
                  catalog: catalog,
                  playlistId: members ? id : null,
                  onPlay: (_, _) async {},
                ),
              ),
            ),
          );
          await _settle(tester);
          await tester.pumpAndSettle();
          final rect = tester.getRect(find.byType(FilmArtwork).first);
          Future<List<int>> pixels() async => (await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const Key('playlist-cover-render')),
            );
            final image = await boundary.toImage();
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            image.dispose();
            return bytes.toList();
          }))!;
          List<int> pixel(List<int> bytes, Offset point) {
            final start = (point.dy.floor() * 1280 + point.dx.floor()) * 4;
            return bytes.sublist(start, start + 4);
          }

          final clear = await pixels();
          expect(
            pixel(clear, Offset(rect.right - 1, rect.top + 1)),
            pixel(clear, Offset(rect.right + 2, rect.top + 1)),
            reason: 'Unwatched corner must follow the cover radius',
          );
          await tester.runAsync(
            () => catalog.store.setPreference('spoiler_protection', true),
          );
          await _settle(tester);
          await tester.pumpAndSettle();
          final blurred = await pixels();
          for (final point in [
            Offset(rect.left - 3, rect.center.dy),
            Offset(rect.right + 3, rect.center.dy),
            Offset(rect.center.dx, rect.top - 3),
            Offset(rect.center.dx, rect.bottom + 3),
            Offset(rect.left + 1, rect.top + 1),
            Offset(rect.right - 1, rect.top + 1),
          ]) {
            expect(
              pixel(blurred, point),
              pixel(clear, point),
              reason: 'Blur must stay inside the rounded cover at $point',
            );
          }
          expect(
            pixel(blurred, rect.center - const Offset(6, 0)),
            isNot(pixel(clear, rect.center - const Offset(6, 0))),
          );
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await _settle(tester);
          await tester.runAsync(() async {
            app.dispose();
            await catalog.close();
            await progress.close();
            await dir.delete(recursive: true);
          });
        }
      },
    );
  }
  testWidgets('playlist member menu opens on the first frame after a click', (
    tester,
  ) async {
    final played = <int>[];
    final (app, catalog, id, dir, _, progress) = (await tester.runAsync(
      _fixture,
    ))!;
    try {
      await tester.pumpWidget(
        _frame(
          app,
          FilmPlaylistPage(
            catalog: catalog,
            playlistId: id,
            onPlay: (_, index) async => played.add(index),
          ),
        ),
      );
      await _settle(tester);
      final menu = find
          .descendant(
            of: find.byType(ReorderableListView),
            matching: find.byType(SPPopupMenuButton<String>),
          )
          .first;
      await tester.tap(menu);
      await tester.pump();
      expect(find.byType(SPMenuSurface), findsOneWidget);
      expect(find.text('移除成员'), findsOneWidget);
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(SPMenuSurface))).pop();
      await tester.pumpAndSettle();

      final title = find.text('Series').first;
      await tester.tap(title);
      await tester.pump(const Duration(milliseconds: 350));
      final row = find
          .ancestor(of: title, matching: find.byType(Material))
          .first;
      expect(
        tester.widget<Material>(row).color,
        AppTheme.dark().colorScheme.primary.withValues(alpha: .12),
      );
      await tester.tap(title);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(title);
      await _settle(tester);
      expect(played, [0]);

      await tester.tap(
        find
            .descendant(
              of: find.byType(ReorderableListView),
              matching: find.byTooltip('播放此文件'),
            )
            .first,
      );
      await _settle(tester);
      expect(played, [0, 0]);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      await tester.runAsync(() async {
        app.dispose();
        await catalog.close();
        await progress.close();
        await dir.delete(recursive: true);
      });
    }
  });
  for (final locale in [
    const Locale('zh', 'CN'),
    const Locale('zh', 'TW'),
    const Locale('ja'),
    const Locale('en'),
  ]) {
    testWidgets(
      'playlist rows and creation dialog fit a narrow window with doubled text $locale',
      (tester) async {
        tester.view.physicalSize = const Size(640, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final (app, catalog, id, dir, _, progress) = (await tester.runAsync(
          _fixture,
        ))!;
        try {
          await tester.pumpWidget(
            _frame(
              app,
              FilmPlaylistPage(
                catalog: catalog,
                playlistId: id,
                sidebarInset: 48,
                onPlay: (_, _) async {},
              ),
              locale: locale,
              scale: 2,
            ),
          );
          await _settle(tester);
          expect(find.byType(FilmArtwork), findsNWidgets(3));
          for (final artwork in tester.widgetList<FilmArtwork>(
            find.byType(FilmArtwork),
          )) {
            expect(artwork.width, 96);
            expect(artwork.height, 54);
          }
          final view = tester.widget<ReorderableListView>(
            find.byType(ReorderableListView),
          );
          final scroll = tester.widget<DirectoryScrollView>(
            find.byType(DirectoryScrollView),
          );
          expect(view.scrollController, same(scroll.controller));
          expect(find.textContaining('S01E01'), findsOneWidget);
          expect(tester.takeException(), isNull);
          final context = tester.element(find.byType(FilmPlaylistPage));
          await tester.tap(
            find.byType(FilmArtwork).first,
            buttons: kSecondaryMouseButton,
          );
          await _settle(tester);
          for (final label in [
            '刷新元数据',
            '标记已看完',
            '标记未看完',
            '加入播放列表…',
            '以本集创建播放列表',
          ]) {
            expect(find.text(context.l10n.text(label)), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
          Navigator.of(tester.element(find.byType(SPMenuSurface))).pop();
          await tester.pumpAndSettle();
          final resources = (await tester.runAsync(
            () => catalog.store.resources(),
          ))!;
          final dialog = showFilmPlaylistDialog(
            context,
            catalog,
            FilmPlaylistScope.work(
              resources.firstWhere((r) => r.type == FilmMediaType.tv).workId!,
            ),
            create: true,
            title: 'New',
          );
          await _settle(tester);
          expect(find.byType(TextField), findsOneWidget);
          expect(tester.takeException(), isNull);
          Navigator.of(tester.element(find.byType(TextField))).pop();
          await dialog;
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await _settle(tester);
          await tester.runAsync(() async {
            app.dispose();
            await catalog.close();
            await progress.close();
            await dir.delete(recursive: true);
          });
        }
      },
    );
  }
  testWidgets(
    'playlist reorder persists; failed save rolls back; playback uses original snapshot after deletion',
    (tester) async {
      final (app, catalog, id, dir, player, progress) = (await tester.runAsync(
        _fixture,
      ))!;
      try {
        final initial = (await tester.runAsync(
          () => catalog.store.playlistSnapshot(id),
        ))!;
        await tester.pumpWidget(
          _frame(
            app,
            FilmPlaylistPage(
              catalog: catalog,
              playlistId: id,
              onPlay: (_, _) async {},
            ),
          ),
        );
        await _settle(tester);
        final handle = find.byType(ReorderableDragStartListener).first;
        final drag = await tester.startGesture(tester.getCenter(handle));
        await drag.moveBy(const Offset(0, 20));
        await tester.pump(const Duration(milliseconds: 250));
        await drag.moveBy(const Offset(0, 200));
        await tester.pump(const Duration(milliseconds: 500));
        await drag.up();
        await _settle(tester);
        expect(
          (await tester.runAsync(
            () => catalog.store.playlistSnapshot(id),
          ))!.entries.map((e) => e.title),
          ['Series', 'Movie', 'Series'],
        );
        final db = await tester.runAsync(
          () => databaseFactoryFfi.openDatabase(catalog.store.path),
        );
        await tester.runAsync(
          () => db!.execute(
            "CREATE TRIGGER fail_playlist_reorder BEFORE UPDATE OF position ON film_playlist_items BEGIN SELECT RAISE(ABORT,'fixture'); END",
          ),
        );
        final view = tester.widget<ReorderableListView>(
          find.byType(ReorderableListView),
        );
        await tester.runAsync(() async {
          view.onReorderItem!(0, 2);
        });
        await _settle(tester);
        final first = initial.entries[1].id;
        expect(
          tester.getTopLeft(find.byKey(ValueKey(first))).dy,
          lessThan(
            tester.getTopLeft(find.byKey(ValueKey(initial.entries[0].id))).dy,
          ),
        );
        await tester.runAsync(() async {
          await db!.execute('DROP TRIGGER fail_playlist_reorder');
        });
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        await tester.runAsync(() async {
          await Directory('${dir.path}/Shows/fonts').create();
          await File('${dir.path}/Shows/fonts/fixture.ttf').writeAsBytes([0]);
          await app.configStore.save(
            StreamPathConfig.fromJson({
              ...app.configStore.current.toJson(),
              'subtitleInjectionEnabled': true,
              'sharePlaylistFonts': true,
            }),
          );
        });
        await tester.runAsync(app.initializeFilmPlayback);
        final key = GlobalKey<BrowserPageState>();
        await tester.pumpWidget(
          _frame(
            app,
            Scaffold(
              body: BrowserPage(
                key: key,
                localRoot: app.configStore.current.localRoots.single,
                playbackOnly: true,
              ),
            ),
          ),
        );
        await _settle(tester);
        Future<void>? launch;
        await tester.runAsync(() async {
          launch = key.currentState!.playFilmPlaylist(initial, 0);
        });
        for (var i = 0; i < 30 && player.plans.isEmpty; i++) {
          await _settle(tester);
        }
        expect(player.plans.length, 1);
        await tester.runAsync(() => launch!);
        expect(player.plans.single!.items.map((i) => i.versions.single.name), [
          'A.mkv',
          'B.mkv',
          'Movie.mkv',
        ]);
        final movie = await tester.runAsync(
          () => player.plans.single!.prepare(
            player.plans.single!.items.last.versions.single,
          ),
        );
        expect(
          movie!.entry.url.replaceAll('\\', '/'),
          endsWith('/Movies/Movie.mkv'),
        );
        expect(movie.localFontDirectory, isNull);
        final episode = await tester.runAsync(
          () => player.plans.single!.prepare(
            player.plans.single!.items.first.versions.single,
          ),
        );
        expect(
          episode!.localFontDirectory!.replaceAll('\\', '/'),
          endsWith('/Shows/fonts'),
        );
        final histories = (await tester.runAsync(
          () => app.filmPlaybackHistoryStore.loadAll(),
        ))!;
        expect(histories.single.filmPlaylistId, id);
        expect(histories.single.videoPlaylistMode, VideoPlaylistMode.implicit);
        await tester.runAsync(() => catalog.store.deletePlaylist(id));
        Future<void>? resumed;
        await tester.runAsync(() async {
          resumed = key.currentState!.playLibraryItem(
            initial.entries.first.resource!.playbackItem,
            resumeSessionId: histories.single.sessionId,
          );
        });
        for (var i = 0; i < 30 && player.plans.length < 2; i++) {
          await _settle(tester);
        }
        expect(player.plans.length, 2);
        await tester.runAsync(() => resumed!);
        expect(player.plans.length, 2);
        expect(player.plans.last!.items.map((i) => i.versions.single.name), [
          'A.mkv',
          'B.mkv',
          'Movie.mkv',
        ]);
        expect(
          (await tester.runAsync(
            () => app.filmPlaybackHistoryStore.loadAll(),
          ))!.single.filmPlaylistEntryIds,
          initial.entries.map((e) => e.id),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        await tester.runAsync(() async {
          app.dispose();
          await catalog.close();
          await progress.close();
          await dir.delete(recursive: true);
        });
      }
    },
  );
}

class _Credentials extends TmdbCredentialStore {
  @override
  Future<String?> read() async => null;
}

class _Metadata extends TmdbMetadataService {
  _Metadata() : super(credentials: _Credentials());
  final works = <(FilmMediaType, int)>[];
  final seasons = <(int, int)>[];
  @override
  Future<FilmWork> details(FilmMediaType type, int id, String language) async {
    works.add((type, id));
    return FilmWork(
      type: type,
      tmdbId: id,
      title: type == FilmMediaType.tv ? 'Series' : 'Movie',
      originalTitle: type == FilmMediaType.tv ? 'Series' : 'Movie',
      overview: 'Refreshed',
      language: language,
      year: 2024,
    );
  }

  @override
  Future<Map<String, dynamic>> season(
    int id,
    int number,
    String language,
  ) async {
    seasons.add((id, number));
    return {'season_number': number, 'episodes': <Map<String, dynamic>>[]};
  }
}

class _App extends AppState {
  _App(
    this.catalog, {
    required super.configStore,
    required super.playbackHistoryStore,
    required super.progressService,
    required super.playerService,
    super.mediaLibraryStore,
  });
  final FilmCatalogController catalog;
  @override
  Future<FilmCatalogController> getFilmCatalog() async => catalog;
  @override
  Future<FilmCatalogStore> getFilmCatalogStore() async => catalog.store;
}

class _Player extends ExternalPlayerService {
  _Player({required super.configStore});
  final plans = <ImplicitVideoPlan?>[];
  final launchedNames = <String>[];
  final launchedSessionIds = <String?>[];
  final starts = <int>[];
  @override
  ExternalPlayerService forFilmLibrary(
    PlaybackProgressService progress,
    Directory watchLater,
  ) => this;
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
    plans.add(implicitPlan);
    launchedNames.add(
      entries[playlistStart].url.replaceAll('\\', '/').split('/').last,
    );
    launchedSessionIds.add(sessionId);
    starts.add(playlistStart);
    throw AppException.process('Test player stopped');
  }
}
