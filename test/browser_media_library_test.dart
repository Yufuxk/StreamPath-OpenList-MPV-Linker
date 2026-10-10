import 'dart:async';
import 'dart:io';
import 'helpers/shell_test_app_state.dart';
import 'helpers/pump_until.dart';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/data/local/directory_cache.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/data/models/playback_history.dart';
import 'package:streampath/data/models/video_queue.dart';
import 'package:streampath/data/models/video_playlist_mode.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/data/models/special_playlist_mode.dart';
import 'package:streampath/data/models/server_profile.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/core/utils/app_paths.dart';
import 'package:streampath/domain/services/external_player_service.dart';
import 'package:streampath/presentation/pages/browser_page.dart';
import 'package:streampath/presentation/pages/media_library_page.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/pages/app_shell_page.dart';
import 'package:streampath/presentation/pages/network_storage_page.dart';
import 'package:streampath/presentation/widgets/directory_breadcrumbs.dart';
import 'package:streampath/presentation/controllers/directory_browser_controller.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/domain/services/special_video_playlist_collector.dart';
import 'package:streampath/domain/services/webdav_media_source_adapter.dart';

void main() {
  late Directory tempDir;
  late HttpServer server;
  late DirectoryCache directoryCache;
  late MediaLibraryStore libraryStore;
  late PlaybackProgressService progressService;
  late AppState appState;
  late _TransitionPlayer player;
  final statusFiles = <File>[];
  final requestedPaths = <String>[];

  setUpAll(() {
    sqfliteFfiInit();
    HttpOverrides.global = null;
  });

  setUp(() async {
    requestedPaths.clear();
    tempDir = Directory.systemTemp.createTempSync('browser_media_library_');
    Hive.init('${tempDir.path}${Platform.pathSeparator}hive');
    directoryCache = DirectoryCache(boxName: 'browser-media-library');
    await directoryCache.init();
    libraryStore = MediaLibraryStore.forPath(
      '${tempDir.path}${Platform.pathSeparator}media_library.json',
    );
    await libraryStore.load();
    progressService = await PlaybackProgressService.open(
      '${tempDir.path}${Platform.pathSeparator}progress.db',
      factory: databaseFactoryFfi,
    );
    final configStore = StreamPathConfigStore.forPath(
      '${tempDir.path}${Platform.pathSeparator}config.json',
    );
    await configStore.save(
      const StreamPathConfig(
        hiddenExtensionsEnabled: true,
        hiddenExtensions: ['.ass'],
        autoSeasonTransitionEnabled: false,
      ),
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requestedPaths.add(request.uri.path);
      request.response
        ..statusCode = HttpStatus.multiStatus
        ..headers.contentType = ContentType(
          'application',
          'xml',
          charset: 'utf-8',
        )
        ..write(_directoryXml(request.uri.path));
      await request.response.close();
    });
    player = _TransitionPlayer(configStore: configStore);
    appState = AppState(
      playerService: player,
      configStore: configStore,
      playbackHistoryStore: PlaybackHistoryStore.forPath(
        '${tempDir.path}${Platform.pathSeparator}history.json',
      ),
      progressService: progressService,
      mediaLibraryStore: libraryStore,
      directoryCache: directoryCache,
    );
    await appState.connect(
      baseUrl: 'http://${server.address.address}:${server.port}/dav',
      username: 'user',
      password: 'secret',
    );
  });

  tearDown(() async {
    appState.dispose();
    for (final file in statusFiles) {
      if (await file.exists()) await file.delete();
    }
    statusFiles.clear();
    await progressService.close();
    await directoryCache.close();
    await Hive.close();
    await server.close(force: true);
    for (var attempt = 0; attempt < 20 && tempDir.existsSync(); attempt++) {
      try {
        await tempDir.delete(recursive: true);
      } on FileSystemException {
        if (attempt == 19) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  Future<void> settleBrowser(WidgetTester tester) async {
    for (var index = 0; index < 4; index++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    }
  }

  Widget buildBrowser({
    AppLanguage language = AppLanguage.simplifiedChinese,
    LocalRootConfig? localRoot,
    Widget? home,
  }) => ChangeNotifierProvider<AppState>.value(
    value: appState,
    child: MaterialApp(
      locale: language.locale,
      supportedLocales: AppLanguage.values.map((value) => value.locale),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AppTheme.light(),
      home: home ?? BrowserPage(localRoot: localRoot),
    ),
  );

  for (final mediaType in ['local', 'video', 'strm']) {
    for (final scenario in [
      (pos: 1, position: 0, running: true, season: false),
      (pos: 0, position: 99, running: false, season: false),
      (pos: 1, position: 99, running: false, season: false),
      (pos: 0, position: 10, running: true, season: true),
    ]) {
      testWidgets('影视桥接复用切集、99% 与切季同步 $mediaType $scenario', (tester) async {
        final local = mediaType == 'local';
        final extension = mediaType == 'strm' ? 'strm' : 'mkv';
        final root = local
            ? LocalRootConfig(
                rootId: 'film-sync',
                displayName: 'Local',
                path: tempDir.path,
              )
            : null;
        final sourceId = root?.sourceId ?? appState.mediaSourceId!;
        final names = ['Show.S01E01.$extension', 'Show.S01E02.$extension'];
        final sessionId =
            'film-sync-${tempDir.path.split(Platform.pathSeparator).last}';
        final nextPlaylist = '${tempDir.path}${Platform.pathSeparator}next.m3u';
        final history = PlaybackHistory(
          sessionId: sessionId,
          sourceId: sourceId,
          dirCrumbs: const ['Season 01'],
          fileName: names.first,
          videoIndex: 0,
          playlistFileNames: names,
          playlistRelativePaths: [for (final name in names) 'Season 01/$name'],
          updatedAt: DateTime.now().subtract(const Duration(seconds: 2)),
          playerPid: 4242,
          ipcPipeName: 'test-film-sync',
          launchEpoch: 'film-sync',
          seasonPlaylistPath: scenario.season
              ? '${tempDir.path}/current.m3u'
              : null,
          nextSeasonRootPath: scenario.season ? 'Season 02' : null,
          nextSeasonFileNames: scenario.season
              ? ['Show.S02E01.$extension']
              : const [],
          nextSeasonRelativePaths: scenario.season
              ? ['Season 02/Show.S02E01.$extension']
              : const [],
          nextSeasonPlaylistPath: scenario.season ? nextPlaylist : null,
        );
        await tester.runAsync(() async {
          if (root != null) {
            await appState.configStore.save(
              appState.configStore.current.withLocalRoots([root]),
            );
          }
          await appState.initializeFilmPlayback();
          await appState.filmPlaybackHistoryStore.upsert(history);
          await appState.filmMediaLibraryStore!.recordPlayback(
            MediaLibraryItem(
              sourceId: sourceId,
              sourceKind: local
                  ? MediaSourceKind.local
                  : MediaSourceKind.webdav,
              parentPath: 'Season 01',
              name: names.first,
              kind: mediaType == 'strm'
                  ? MediaLibraryKind.strm
                  : MediaLibraryKind.video,
            ),
            playbackSessionId: sessionId,
            playlistIndex: 0,
            playlistCount: 2,
          );
          final cache = await AppPaths.cacheDirectory();
          final status = File(
            '${cache.path}${Platform.pathSeparator}${ExternalPlayerService.sessionStatusFileName(sessionId, launchEpoch: history.launchEpoch)}',
          );
          statusFiles.add(status);
          final lines = List<String>.filled(22, '');
          lines[0] = '${scenario.pos}';
          lines[1] = scenario.running
              ? 'https://example.test/film-current.mkv'
              : '';
          lines[2] = '0';
          lines[3] = '${scenario.position}';
          lines[4] = '100';
          if (scenario.season) lines[21] = nextPlaylist;
          await status.writeAsString('${lines.join('\n')}\n');
        });
        player.running = scenario.running;
        await tester.pumpWidget(
          buildBrowser(home: BrowserPage(localRoot: root, playbackOnly: true)),
        );
        final completed = !scenario.running && scenario.pos == 1;
        final expectedName = scenario.season
            ? 'Show.S02E01.$extension'
            : names.last;
        await pumpUntil(
          tester,
          () {
            final histories = appState.filmPlaybackHistoryStore.sessions;
            final records = appState.filmMediaLibraryStore!
                .playbackHistorySnapshot(sourceId, audio: false);
            return records.length == 1 &&
                (completed
                    ? histories.isEmpty && records.single.continueDismissed
                    : histories.length == 1 &&
                          histories.single.fileName == expectedName &&
                          records.single.item.name == expectedName &&
                          (mediaType != 'strm' ||
                              !scenario.running ||
                              records.single.strmPositionMs ==
                                  scenario.position * 1000) &&
                          (scenario.running ||
                              histories.single.playerPid == null));
          },
          frameDuration: const Duration(milliseconds: 700),
          reason: 'Film playback history and records must finish synchronizing',
        );
        final histories = appState.filmPlaybackHistoryStore.sessions;
        final records = appState.filmMediaLibraryStore!.playbackHistorySnapshot(
          sourceId,
          audio: false,
        );
        expect(records, hasLength(1));
        expect(records.single.playbackSessionId, sessionId);
        if (!scenario.running && scenario.pos == 1) {
          expect(histories, isEmpty);
          expect(records.single.continueDismissed, isTrue);
        } else {
          expect(histories.single.sessionId, sessionId);
          expect(
            histories.single.fileName,
            scenario.season ? 'Show.S02E01.$extension' : names.last,
          );
          expect(records.single.item.name, histories.single.fileName);
          expect(records.single.playlistIndex, scenario.season ? 0 : 1);
          expect(records.single.playlistCount, scenario.season ? 1 : 2);
          if (scenario.season) {
            expect(histories.single.dirCrumbs, ['Season 02']);
          }
        }
        expect(appState.playbackHistoryStore.sessions, isEmpty);
        expect(
          await tester.runAsync(
            () => libraryStore.playbackHistory(sourceId, audio: false),
          ),
          isEmpty,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await settleBrowser(tester);
        var recordsDrained = false;
        await tester.runAsync(() async {
          appState.filmMediaLibraryStore!
              .playbackHistory(sourceId, audio: false)
              .then((_) => recordsDrained = true);
        });
        await pumpUntil(
          tester,
          () => recordsDrained,
          reason: 'Unmounted playback must finish writing its film records',
        );
      });
    }
  }

  testWidgets('影视详情选择同一列表的另一集复用活动会话，控制失败保留原记录', (tester) async {
    final sourceId = appState.mediaSourceId!;
    final sessionId =
        'film-select-${tempDir.path.split(Platform.pathSeparator).last}';
    await tester.runAsync(() async {
      await appState.initializeFilmPlayback();
      await appState.filmPlaybackHistoryStore.upsert(
        PlaybackHistory(
          sessionId: sessionId,
          sourceId: sourceId,
          dirCrumbs: const [],
          fileName: '第一集.mkv',
          videoIndex: 0,
          playlistFileNames: const ['第一集.mkv', 'OVA02.mkv'],
          playlistRelativePaths: const ['第一集.mkv', 'Extras/OVA02.mkv'],
          updatedAt: DateTime.now(),
        ),
      );
    });
    final key = GlobalKey<BrowserPageState>();
    await tester.pumpWidget(
      buildBrowser(
        home: Scaffold(body: BrowserPage(key: key, playbackOnly: true)),
      ),
    );
    await settleBrowser(tester);
    player.running = true;
    for (final succeeds in [false, true]) {
      player.selectionSucceeds = succeeds;
      await tester.runAsync(
        () => key.currentState!.playLibraryItem(
          MediaLibraryItem(
            sourceId: sourceId,
            parentPath: 'Extras',
            name: 'OVA02.mkv',
            kind: MediaLibraryKind.video,
          ),
        ),
      );
      await tester.pump();
      expect(player.selectedSessionId, sessionId);
      expect(player.selectedIndex, 1);
      expect(appState.filmPlaybackHistoryStore.sessions, hasLength(1));
      expect(
        appState.filmPlaybackHistoryStore.sessions.single.fileName,
        '第一集.mkv',
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await settleBrowser(tester);
  });

  testWidgets('记忆目录首帧直接显示对应缓存列表', (tester) async {
    await tester.runAsync(() async {
      await appState.webDavService!.fetchDirectory('Extras');
      await appState.navigationLocations.remember(
        sourceId: appState.mediaSourceId!,
        kind: 'network',
        path: 'Extras',
      );
    });

    await tester.runAsync(() => tester.pumpWidget(buildBrowser()));

    expect(
      tester
          .widget<DirectoryBreadcrumbs>(find.byType(DirectoryBreadcrumbs))
          .crumbs,
      ['Extras'],
    );
    expect(find.text('OVA02.mkv'), findsOneWidget);
    expect(find.text('第一集.mkv'), findsNothing);
    expect(find.text('空目录'), findsNothing);
    await settleBrowser(tester);
    await tester.runAsync(
      () => libraryStore.recentDirectories(appState.mediaSourceId!),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final succeeds in [true, false]) {
    testWidgets('网络记忆目录等待激活后直接呈现，成功：$succeeds', (tester) async {
      final sourceId = appState.mediaSourceId!;
      late _RestoringAppState restoredApp;
      await tester.runAsync(() async {
        await appState.configStore.save(
          appState.configStore.current
              .upsertProfile(
                ServerProfile(
                  profileId: sourceId,
                  name: '记忆服务器',
                  serverUrl: appState.webDavService!.baseUrl,
                  username: 'user',
                  defaultDirectory: 'Default',
                ),
              )
              .withMountedProfileIds([sourceId]),
        );
        restoredApp = _RestoringAppState(
          configStore: appState.configStore,
          playbackHistoryStore: PlaybackHistoryStore.forPath(
            '${tempDir.path}${Platform.pathSeparator}restored-history.json',
          ),
          progressService: progressService,
          directoryCache: directoryCache,
        );
        await restoredApp.getFilmCatalog();
        await restoredApp.navigationLocations.remember(
          sourceId: sourceId,
          kind: 'network',
          path: 'Extras',
        );
        await restoredApp.activateMountedProfile(sourceId);
        await restoredApp.webDavService!.fetchDirectory('Extras');
        await directoryCache.close();
        await directoryCache.init();
        expect(restoredApp.webDavService!.cachedDirectory('Extras'), isNotNull);
      });
      addTearDown(() async {
        if (!restoredApp.activationGate!.isCompleted) {
          restoredApp.activationGate!.complete();
        }
        await settleBrowser(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(restoredApp.closeTestStores);
        restoredApp.dispose();
      });
      requestedPaths.clear();
      restoredApp.activationGate = Completer<void>();
      restoredApp.failActivation = !succeeds;

      final shell = ChangeNotifierProvider<AppState>.value(
        value: restoredApp,
        child: MaterialApp(theme: AppTheme.light(), home: const AppShellPage()),
      );
      await tester.pumpWidget(shell);
      await settleBrowser(tester);
      expect(find.byKey(const Key('sidebar-films')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sidebar-folders')));
      await settleBrowser(tester);
      await tester.tap(find.byKey(ValueKey('network-profile-$sourceId')));
      await tester.pump();
      expect(find.byType(NetworkStoragePage), findsOneWidget);
      expect(find.byType(BrowserPage), findsNothing);
      await tester.pump();
      expect(find.byType(NetworkStoragePage), findsOneWidget);

      restoredApp.activationGate!.complete();
      await settleBrowser(tester);
      if (succeeds) {
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.text('OVA02.mkv'), findsOneWidget);
        expect(find.byType(NetworkStoragePage), findsNothing);
        expect(
          requestedPaths.where((path) => path.contains('Default')),
          isEmpty,
        );
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.byType(NetworkStoragePage), findsOneWidget);
      } else {
        expect(find.byType(NetworkStoragePage), findsOneWidget);
        expect(find.byType(BrowserPage), findsNothing);
        expect(
          find.textContaining('Test restore connection failed'),
          findsOneWidget,
        );
        expect(restoredApp.navigationLocations.pathFor(sourceId), 'Extras');
      }
    });
  }

  for (final reportedIndex in [-1, 1]) {
    testWidgets('待播下一集未打开时退出保留同源续播（状态 $reportedIndex）', (tester) async {
      final sourceId = appState.mediaSourceId!;
      final history = PlaybackHistory(
        sessionId: 'pending-transition',
        sourceId: sourceId,
        dirCrumbs: const ['B'],
        fileName: '第一集.mkv',
        videoIndex: 0,
        pendingVideoIndex: 1,
        playlistFileNames: const ['第一集.mkv', '第二集.mkv'],
        playlistRelativePaths: const ['B/第一集.mkv', 'A/第二集.mkv'],
        queueItems: const [
          VideoQueueItem(
            versions: [
              VideoQueueVersion(path: 'B/第一集.mkv', name: '第一集.mkv', rootId: 2),
            ],
          ),
          VideoQueueItem(
            versions: [
              VideoQueueVersion(path: 'A/第二集.mkv', name: '第二集.mkv', rootId: 1),
              VideoQueueVersion(path: 'B/第二集.mkv', name: '第二集.mkv', rootId: 2),
            ],
          ),
        ],
        videoPlaylistMode: VideoPlaylistMode.implicit,
        updatedAt: DateTime.now().subtract(const Duration(seconds: 5)),
        playerPid: 4242,
        ipcPipeName: 'test-only',
        launchEpoch: 'pending',
      );
      await tester.runAsync(() async {
        await appState.playbackHistoryStore.upsert(history);
        await libraryStore.recordPlayback(
          MediaLibraryItem(
            sourceId: sourceId,
            parentPath: 'B',
            name: history.fileName,
            kind: MediaLibraryKind.video,
          ),
          playbackSessionId: history.sessionId,
          playlistIndex: 0,
          playlistCount: 2,
        );
        final cache = await AppPaths.cacheDirectory();
        final status = File(
          '${cache.path}${Platform.pathSeparator}${ExternalPlayerService.sessionStatusFileName(history.sessionId, launchEpoch: history.launchEpoch)}',
        );
        statusFiles.add(status);
        final lines = List<String>.filled(26, '-1');
        lines[0] = '$reportedIndex';
        lines[1] = '';
        lines[3] = reportedIndex == -1 ? '-1' : '119';
        lines[4] = reportedIndex == -1 ? '-1' : '120';
        lines[22] = '0';
        lines[25] = '0';
        await status.writeAsString(lines.join('\n'));
      });
      await tester.pumpWidget(buildBrowser());
      await pumpUntil(
        tester,
        () =>
            appState.playbackHistoryStore.sessions.isEmpty ||
            appState.playbackHistoryStore.sessions.single.playerPid == null,
        reason: 'Player exit must finish syncing',
      );
      final saved = appState.playbackHistoryStore.sessions.single;
      expect(saved.pendingVideoIndex, 1);
      expect(saved.videoIndex, 1);
      expect(saved.fileName, '第二集.mkv');
      expect(saved.playlistRelativePaths[1], 'B/第二集.mkv');
      final persisted = await tester.runAsync(
        () => PlaybackHistoryStore.forPath(
          '${tempDir.path}${Platform.pathSeparator}history.json',
        ).loadAll(),
      );
      expect(persisted!.single.pendingVideoIndex, 1);
      final records = await tester.runAsync(
        () => libraryStore.playbackHistory(sourceId, audio: false),
      );
      expect(records!.single.continueDismissed, false);
      expect(records.single.item.targetPath, 'B/第二集.mkv');
      expect(records.single.playlistIndex, 1);
      expect(records.single.playbackSessionId, history.sessionId);
      await tester.pumpWidget(const SizedBox.shrink());
      await settleBrowser(tester);
    });
  }

  for (final scenario in const [
    (position: 0.0, previousAtEnd: false, special: false),
    (position: 0.25, previousAtEnd: false, special: false),
    (position: 0.0, previousAtEnd: true, special: false),
    (position: 0.25, previousAtEnd: false, special: true),
  ]) {
    testWidgets(
      '切集退出同步第二集历史（${scenario.position} 秒，上一集片尾采样：${scenario.previousAtEnd}）',
      (tester) async {
        final sessionId =
            'transition-${tempDir.path.split(Platform.pathSeparator).last}';
        final sourceId = appState.mediaSourceId!;
        final created = DateTime.now().subtract(const Duration(seconds: 5));
        final history = PlaybackHistory(
          sessionId: sessionId,
          sourceId: sourceId,
          dirCrumbs: const [],
          fileName: '第一集.mkv',
          videoIndex: 0,
          playlistFileNames: [
            '第一集.mkv',
            scenario.special ? 'OVA02.mkv' : '第二集.mkv',
          ],
          playlistRelativePaths: scenario.special
              ? const ['第一集.mkv', 'Extras/OVA02.mkv']
              : const [],
          updatedAt: created,
          playerPid: 4242,
          ipcPipeName: 'test-only',
          launchEpoch: 'transition',
        );
        await tester.runAsync(() async {
          await appState.playbackHistoryStore.upsert(history);
          await libraryStore.recordPlayback(
            MediaLibraryItem(
              sourceId: sourceId,
              parentPath: '',
              name: history.fileName,
              kind: MediaLibraryKind.video,
            ),
            playbackSessionId: sessionId,
          );
          final cache = await AppPaths.cacheDirectory();
          final status = File(
            '${cache.path}${Platform.pathSeparator}${ExternalPlayerService.sessionStatusFileName(sessionId, launchEpoch: history.launchEpoch)}',
          );
          statusFiles.add(status);
          // MPV 退出时 path 已清空，但 playlist-pos 和最终采样仍有效。
          await status.writeAsString(
            scenario.previousAtEnd
                ? '0\nhttps://example.test/first.mkv\n0\n119\n120\n'
                : '1\n\n0\n${scenario.position}\n120\n',
          );
        });
        player.running = scenario.previousAtEnd;
        await tester.pumpWidget(buildBrowser());
        if (scenario.previousAtEnd) {
          for (var attempt = 0; attempt < 5; attempt++) {
            await settleBrowser(tester);
          }
          player.running = false;
          await tester.runAsync(
            () => statusFiles.single.writeAsString('1\n\n0\n0\n-1\n'),
          );
          await tester.pump(const Duration(seconds: 2));
        }
        for (var attempt = 0; attempt < 20; attempt++) {
          await tester.pump(const Duration(milliseconds: 700));
          await settleBrowser(tester);
          final sessions = appState.playbackHistoryStore.sessions;
          if (sessions.isEmpty || sessions.single.playerPid == null) break;
        }
        List<MediaLibraryRecord>? records;
        libraryStore
            .playbackHistory(sourceId, audio: false)
            .then((value) => records = value);
        for (var attempt = 0; attempt < 20 && records == null; attempt++) {
          await settleBrowser(tester);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await settleBrowser(tester);
        final histories = appState.playbackHistoryStore.sessions;
        expect(
          histories.single.fileName,
          scenario.special ? 'OVA02.mkv' : '第二集.mkv',
        );
        expect(histories.single.videoIndex, 1);
        expect(histories.single.playerPid, isNull);
        expect(records, isNotNull);
        expect(
          records!.single.item.name,
          scenario.special ? 'OVA02.mkv' : '第二集.mkv',
        );
        expect(
          records!.single.item.parentPath,
          scenario.special ? 'Extras' : '',
        );
        expect(records!.single.playbackSessionId, sessionId);
        expect(records!.single.playlistIndex, 1);
        expect(records!.single.playlistCount, 2);
      },
    );
  }

  for (final scenario in const [
    (count: 3, start: 1, exit: 1, position: 99, persisted: false),
    (count: 3, start: 1, exit: 1, position: 99, persisted: true),
    (count: 3, start: 1, exit: 2, position: 99, persisted: false),
    (count: 3, start: 2, exit: 1, position: 99, persisted: false),
    (count: 3, start: 2, exit: 2, position: 99, persisted: true),
    (count: 3, start: 2, exit: 2, position: 98, persisted: false),
    (count: 3, start: 0, exit: 0, position: 98, persisted: false),
    (count: 3, start: 0, exit: 0, position: 99, persisted: false),
    (count: 4, start: 0, exit: 0, position: 99, persisted: false),
    (count: 1, start: 0, exit: 0, position: 99, persisted: false),
  ]) {
    for (final mediaType in ['mkv', 'strm', 'local']) {
      final extension = mediaType == 'local' ? 'mkv' : mediaType;
      testWidgets(
        '99% 退出续播移到下一集或完成末集（${scenario.start}→${scenario.exit}/${scenario.count}，${scenario.position}%，进度库：${scenario.persisted}，$mediaType）',
        (tester) async {
          final sessionId =
              'completion-${tempDir.path.split(Platform.pathSeparator).last}';
          final localRoot = mediaType == 'local'
              ? LocalRootConfig(
                  rootId: 'completion-local',
                  displayName: '本地续播',
                  path: tempDir.path,
                )
              : null;
          final sourceId = localRoot?.sourceId ?? appState.mediaSourceId!;
          final names = List.generate(
            scenario.count,
            (index) => 'episode-$index.$extension',
          );
          final history = PlaybackHistory(
            sessionId: sessionId,
            sourceId: sourceId,
            dirCrumbs: const ['Completion'],
            fileName: names[scenario.start],
            videoIndex: scenario.start,
            playlistFileNames: names,
            updatedAt: DateTime.now().subtract(const Duration(seconds: 5)),
            playerPid: 4242,
            ipcPipeName: 'test-completion',
            launchEpoch: 'completion-test',
          );
          final baseUrl = appState.webDavService!.baseUrl;
          String targetUrl(int index) => localRoot == null
              ? '$baseUrl/Completion/${names[index]}'
              : '${localRoot.path}${Platform.pathSeparator}Completion${Platform.pathSeparator}${names[index]}';
          final url = targetUrl(scenario.exit);
          await tester.runAsync(() async {
            if (localRoot != null) {
              await appState.configStore.save(
                appState.configStore.current.withLocalRoots([localRoot]),
              );
              final directory = Directory(
                '${localRoot.path}${Platform.pathSeparator}Completion',
              )..createSync();
              for (final name in names) {
                File(
                  '${directory.path}${Platform.pathSeparator}$name',
                ).writeAsBytesSync([0]);
              }
            }
            await appState.playbackHistoryStore.upsert(history);
            if (scenario.count == 4) {
              // 下一集已有进度，另一个会话使监控继续运行。
              final siblingId = '$sessionId-sibling';
              player.runningSessionIds.add(siblingId);
              await appState.playbackHistoryStore.upsert(
                history.copyWith(
                  sessionId: siblingId,
                  fileName: names.last,
                  videoIndex: names.length - 1,
                ),
              );
              if (extension != 'strm') {
                await progressService.saveProgress(
                  url: targetUrl(scenario.exit + 1),
                  profileId: sourceId,
                  positionMs: 12500,
                  durationMs: 100000,
                );
              }
            }
            directoryCache.write(
              'completion-fixture',
              names
                  .map(
                    (name) => WebDavFile(
                      name: name,
                      href: '/dav/Completion/$name',
                      isDirectory: false,
                    ),
                  )
                  .toList(),
              sourceId: sourceId,
              path: 'Completion',
            );
            await directoryCache.close();
            await directoryCache.init();
            await libraryStore.recordPlayback(
              MediaLibraryItem(
                sourceId: sourceId,
                parentPath: 'Completion',
                name: history.fileName,
                kind: extension == 'strm'
                    ? MediaLibraryKind.strm
                    : MediaLibraryKind.video,
              ),
              playbackSessionId: sessionId,
              playlistIndex: scenario.start,
              playlistCount: scenario.count,
            );
            final cache = await AppPaths.cacheDirectory();
            final status = File(
              '${cache.path}${Platform.pathSeparator}${ExternalPlayerService.sessionStatusFileName(sessionId, launchEpoch: history.launchEpoch)}',
            );
            statusFiles.add(status);
            await status.writeAsString(
              '${scenario.exit}\n$url\n0\n'
              '${scenario.persisted ? '' : '${scenario.position}\n100\n'}',
            );
            if (scenario.persisted) {
              await progressService.saveProgress(
                url: url,
                profileId: sourceId,
                positionMs: scenario.position * 1000,
                durationMs: 100000,
              );
            }
          });
          await tester.pumpWidget(buildBrowser(localRoot: localRoot));
          await pumpUntil(
            tester,
            () {
              final current = appState.playbackHistoryStore.sessions
                  .where((history) => history.sessionId == sessionId)
                  .firstOrNull;
              return current == null || current.playerPid == null;
            },
            frameDuration: const Duration(milliseconds: 700),
            reason: 'Stopped playback must commit its final history state',
          );
          if (scenario.count == 4) {
            final stopped = appState.playbackHistoryStore.sessions.firstWhere(
              (history) => history.sessionId == sessionId,
            );
            for (var attempt = 0; attempt < 4; attempt++) {
              await tester.pump(const Duration(seconds: 1));
              await settleBrowser(tester);
            }
            expect(
              appState.playbackHistoryStore.sessions
                  .firstWhere((history) => history.sessionId == sessionId)
                  .updatedAt,
              stopped.updatedAt,
            );
          }
          List<MediaLibraryRecord>? records;
          libraryStore
              .playbackHistory(sourceId, audio: false)
              .then((value) => records = value);
          await pumpUntil(
            tester,
            () => records != null,
            reason: 'Final playback records must finish loading',
          );
          await tester.pumpWidget(const SizedBox.shrink());
          await settleBrowser(tester);
          final completed =
              scenario.exit == scenario.count - 1 && scenario.position >= 99;
          expect(records, isNotNull);
          expect(records!.single.continueDismissed, completed);
          final sessions = appState.playbackHistoryStore.sessions
              .where((history) => history.sessionId == sessionId)
              .toList();
          if (completed) {
            expect(sessions, isEmpty);
          } else {
            final expectedIndex = scenario.position >= 99
                ? scenario.exit + 1
                : scenario.exit;
            expect(sessions.single.fileName, names[expectedIndex]);
            expect(sessions.single.videoIndex, expectedIndex);
            expect(sessions.single.playerPid, isNull);
            expect(records!.single.item.name, names[expectedIndex]);
            expect(records!.single.playlistIndex, expectedIndex);
            expect(records!.single.playlistCount, scenario.count);
            if (scenario.position >= 99) {
              if (extension == 'strm') {
                expect(records!.single.strmPositionMs, 0);
                expect(records!.single.strmDurationMs, isNull);
              } else {
                final progress = await tester.runAsync(
                  () => progressService.getResumeProgress(
                    targetUrl(expectedIndex),
                    profileId: sourceId,
                  ),
                );
                expect(progress?.positionMs, scenario.count == 4 ? 12500 : 0);
              }
              await tester.pumpWidget(
                buildBrowser(
                  home: MediaLibraryPage(
                    sourceId: sourceId,
                    store: libraryStore,
                    directoryCache: directoryCache,
                    videoProgressService: progressService,
                    audioProgressService: null,
                    resolveUrl: appState.webDavService!.resolveUrl,
                    resolveDirectTarget: localRoot == null
                        ? null
                        : (item) => appState
                              .localMediaSource(localRoot)
                              .lexicalPath(item.targetPath),
                  ),
                ),
              );
              await settleBrowser(tester);
              await tester.tap(find.text('继续播放').first);
              await tester.pumpAndSettle();
              expect(find.text(names[expectedIndex]), findsOneWidget);
              expect(
                find.textContaining(
                  '第 ${expectedIndex + 1}/${scenario.count} 集',
                ),
                findsOneWidget,
              );
              expect(find.text(names[scenario.exit]), findsNothing);
              await tester.pumpWidget(const SizedBox.shrink());
              await settleBrowser(tester);
            }
          }
        },
      );
    }
  }

  testWidgets('STRM 切集清除旧时间，退出后使用精确进度更新显示快照', (tester) async {
    final sessionId = 'strm-${tempDir.path.split(Platform.pathSeparator).last}';
    final sourceId = appState.mediaSourceId!;
    final history = PlaybackHistory(
      sessionId: sessionId,
      sourceId: sourceId,
      dirCrumbs: const [],
      fileName: 'first.strm',
      videoIndex: 0,
      playlistFileNames: const ['first.strm', 'second.strm'],
      updatedAt: DateTime.now().subtract(const Duration(seconds: 2)),
      playerPid: 4242,
      ipcPipeName: 'test-strm',
      launchEpoch: 'strm-test',
    );
    late File status;
    const firstUrl = 'https://example.test/first.mkv';
    const secondUrl = 'https://example.test/second.mkv';
    await tester.runAsync(() async {
      await appState.playbackHistoryStore.upsert(history);
      await libraryStore.recordPlayback(
        MediaLibraryItem(
          sourceId: sourceId,
          parentPath: '',
          name: 'first.strm',
          kind: MediaLibraryKind.strm,
        ),
        playbackSessionId: sessionId,
        playlistIndex: 0,
        playlistCount: 2,
      );
      final cache = await AppPaths.cacheDirectory();
      status = File(
        '${cache.path}${Platform.pathSeparator}${ExternalPlayerService.sessionStatusFileName(sessionId, launchEpoch: history.launchEpoch)}',
      );
      statusFiles.add(status);
      await status.writeAsString('0\n$firstUrl\n0\n125\n600\n');
    });
    player.running = true;
    await tester.pumpWidget(buildBrowser());
    Future<MediaLibraryRecord> waitForSnapshot(int positionMs) async {
      MediaLibraryRecord? record;
      for (var attempt = 0; attempt < 20; attempt++) {
        await tester.pump(const Duration(milliseconds: 700));
        await settleBrowser(tester);
        libraryStore
            .playbackHistory(sourceId, audio: false)
            .then((records) => record = records.single);
        await settleBrowser(tester);
        if (record?.strmPositionMs == positionMs) {
          await settleBrowser(tester);
          return record!;
        }
      }
      expect(record!.strmPositionMs, positionMs);
      return record!;
    }

    await waitForSnapshot(125000);
    expect(find.textContaining('第 1/2 集  ·  已播放 02:05'), findsOneWidget);
    await tester.runAsync(
      () => status.writeAsString('1\n$secondUrl\n0\n0\n600\n'),
    );
    final changed = await waitForSnapshot(0);
    expect(changed.item.kind, MediaLibraryKind.strm);
    expect(changed.item.name, 'second.strm');
    expect(changed.playlistIndex, 1);
    expect(changed.playlistCount, 2);
    await pumpUntil(
      tester,
      () => find.textContaining('第 2/2 集').evaluate().isNotEmpty,
      reason: 'The synchronized STRM episode must reach the playback bar',
    );
    expect(find.textContaining('第 2/2 集'), findsOneWidget);
    expect(find.textContaining('已播放 02:05'), findsNothing);
    player.running = false;
    await tester.runAsync(() async {
      await progressService.saveProgress(
        url: secondUrl,
        positionMs: 133700,
        durationMs: 600000,
        profileId: sourceId,
      );
      await status.writeAsString('1\n\n0\n0\n-1\n');
    });
    await waitForSnapshot(133700);
    expect(find.textContaining('第 2/2 集  ·  已播放 02:13'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await settleBrowser(tester);
  });

  testWidgets('MPV 切季状态加载后更新同一底栏与媒体中心记录', (tester) async {
    final sessionId =
        'season-${tempDir.path.split(Platform.pathSeparator).last}';
    final sourceId = appState.mediaSourceId!;
    final playlistPath = '${tempDir.path}${Platform.pathSeparator}next.m3u';
    final history = PlaybackHistory(
      sessionId: sessionId,
      sourceId: sourceId,
      dirCrumbs: const ['1.《剧名》'],
      fileName: '剧名.S01E02.mkv',
      videoIndex: 1,
      playlistFileNames: const ['剧名.S01E01.mkv', '剧名.S01E02.mkv'],
      playlistRelativePaths: const [
        '1.《剧名》/剧名.S01E01.mkv',
        '1.《剧名》/剧名.S01E02.mkv',
      ],
      seasonPlaylistPath: '${tempDir.path}${Platform.pathSeparator}first.m3u',
      nextSeasonRootPath: '2.《剧名》',
      nextSeasonFileNames: const ['剧名.S02E01.mkv'],
      nextSeasonRelativePaths: const ['2.《剧名》/剧名.S02E01.mkv'],
      nextSeasonPlaylistPath: playlistPath,
      updatedAt: DateTime.now().subtract(const Duration(seconds: 2)),
      playerPid: 4242,
      ipcPipeName: 'test-only',
      launchEpoch: 'season-test',
    );
    await tester.runAsync(() async {
      await appState.playbackHistoryStore.upsert(history);
      final cache = await AppPaths.cacheDirectory();
      final status = File(
        '${cache.path}${Platform.pathSeparator}${ExternalPlayerService.sessionStatusFileName(sessionId, launchEpoch: history.launchEpoch)}',
      );
      statusFiles.add(status);
      final lines = List<String>.filled(22, '');
      lines[0] = '0';
      lines[1] = 'https://example.test/dav/season-two.mkv';
      lines[2] = '0';
      lines[3] = '10';
      lines[4] = '100';
      lines[21] = playlistPath;
      await status.writeAsString('${lines.join('\n')}\n');
      expect((await status.readAsLines())[21], playlistPath);
    });
    expect(
      appState.playbackHistoryStore.sessions.single.nextSeasonPlaylistPath,
      playlistPath,
    );
    player.running = true;
    await tester.pumpWidget(buildBrowser());
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump(const Duration(milliseconds: 700));
      await settleBrowser(tester);
      if (appState.playbackHistoryStore.sessions.single.fileName ==
          '剧名.S02E01.mkv') {
        break;
      }
    }
    final changed = appState.playbackHistoryStore.sessions.single;
    expect(changed.sessionId, sessionId);
    expect(changed.dirCrumbs, ['2.《剧名》']);
    expect(changed.playlistFileNames, ['剧名.S02E01.mkv']);
    expect(changed.nextSeasonPlaylistPath, isNull);
    expect(changed.playerPid, 4242);
    List<MediaLibraryRecord>? recent;
    libraryStore
        .playbackHistory(sourceId, audio: false)
        .then((value) => recent = value);
    for (var attempt = 0; attempt < 20 && recent == null; attempt++) {
      await settleBrowser(tester);
    }
    expect(recent, isNotNull);
    expect(recent!.single.item.name, '剧名.S02E01.mkv');
    expect(recent!.single.item.parentPath, '2.《剧名》');
    expect(recent!.single.playlistIndex, 0);
    expect(recent!.single.playlistCount, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await settleBrowser(tester);
  });

  testWidgets('跳过本季确认后请求同进程换表，取消时保持当前列表', (tester) async {
    final json = appState.configStore.current.toJson();
    json['autoSeasonTransitionEnabled'] = true;
    await tester.runAsync(
      () => appState.configStore.save(StreamPathConfig.fromJson(json)),
    );
    final sessionId =
        'manual-season-${tempDir.path.split(Platform.pathSeparator).last}';
    final current = '${tempDir.path}${Platform.pathSeparator}current.m3u';
    final next = '${tempDir.path}${Platform.pathSeparator}next.m3u';
    await tester.runAsync(() => File(next).writeAsString('#EXTM3U\n'));
    final history = PlaybackHistory(
      sessionId: sessionId,
      sourceId: appState.mediaSourceId!,
      dirCrumbs: const ['1.《剧名》'],
      fileName: '剧名.S01E01.mkv',
      videoIndex: 0,
      playlistFileNames: const ['剧名.S01E01.mkv'],
      playlistRelativePaths: const ['1.《剧名》/剧名.S01E01.mkv'],
      seasonPlaylistPath: current,
      nextSeasonRootPath: '2.《剧名》',
      nextSeasonFileNames: const ['剧名.S02E01.mkv'],
      nextSeasonRelativePaths: const ['2.《剧名》/剧名.S02E01.mkv'],
      nextSeasonPlaylistPath: next,
      updatedAt: DateTime.now().subtract(const Duration(seconds: 2)),
      playerPid: 4242,
      ipcPipeName: 'test-only',
      launchEpoch: 'manual-season',
    );
    await tester.runAsync(() async {
      await appState.playbackHistoryStore.upsert(history);
      final cache = await AppPaths.cacheDirectory();
      final status = File(
        '${cache.path}${Platform.pathSeparator}${ExternalPlayerService.sessionStatusFileName(sessionId, launchEpoch: history.launchEpoch)}',
      );
      statusFiles.add(status);
      final lines = List<String>.filled(22, '');
      lines[0] = '0';
      lines[1] = 'https://example.test/dav/season-one.mkv';
      lines[2] = '1';
      lines[3] = '10';
      lines[4] = '100';
      lines[21] = current;
      await status.writeAsString('${lines.join('\n')}\n');
    });
    player.running = true;
    await tester.pumpWidget(buildBrowser());
    await settleBrowser(tester);
    await tester.tap(find.byTooltip('跳过本季'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('跳过本季？'), findsOneWidget);
    await tester.tap(find.text('取消').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(player.skippedSeason, isFalse);
    expect(
      appState.playbackHistoryStore.sessions.single.fileName,
      '剧名.S01E01.mkv',
    );

    await tester.tap(find.byTooltip('跳过本季'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('确认跳过'));
    await settleBrowser(tester);
    expect(player.skippedSeason, isTrue);
    expect(player.skippedFrom, current);
    expect(player.skippedTo, next);
    expect(
      appState.playbackHistoryStore.sessions.single.fileName,
      '剧名.S01E01.mkv',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await settleBrowser(tester);
  });

  testWidgets('跳过本季找不到下一季时保留当前列表', (tester) async {
    final json = appState.configStore.current.toJson();
    json['autoSeasonTransitionEnabled'] = true;
    await tester.runAsync(
      () => appState.configStore.save(StreamPathConfig.fromJson(json)),
    );
    final sessionId =
        'no-next-${tempDir.path.split(Platform.pathSeparator).last}';
    final current = '${tempDir.path}${Platform.pathSeparator}current.m3u';
    final history = PlaybackHistory(
      sessionId: sessionId,
      sourceId: appState.mediaSourceId!,
      dirCrumbs: const ['1.《剧名》'],
      fileName: '剧名.S01E01.mkv',
      videoIndex: 0,
      playlistFileNames: const ['剧名.S01E01.mkv'],
      playlistRelativePaths: const ['1.《剧名》/剧名.S01E01.mkv'],
      seasonPlaylistPath: current,
      updatedAt: DateTime.now().subtract(const Duration(seconds: 2)),
      playerPid: 4242,
      ipcPipeName: 'test-only',
      launchEpoch: 'no-next',
    );
    await tester.runAsync(() async {
      await appState.playbackHistoryStore.upsert(history);
      final cache = await AppPaths.cacheDirectory();
      final status = File(
        '${cache.path}${Platform.pathSeparator}${ExternalPlayerService.sessionStatusFileName(sessionId, launchEpoch: history.launchEpoch)}',
      );
      statusFiles.add(status);
      final lines = List<String>.filled(22, '');
      lines[0] = '0';
      lines[1] = 'https://example.test/dav/season-one.mkv';
      lines[2] = '1';
      lines[3] = '10';
      lines[4] = '100';
      lines[21] = current;
      await status.writeAsString('${lines.join('\n')}\n');
    });
    player.running = true;
    await tester.runAsync(
      () => appState.webDavService!.fetchDirectory('1.《剧名》'),
    );
    await tester.pumpWidget(buildBrowser());
    await settleBrowser(tester);
    await tester.tap(find.byTooltip('跳过本季'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('确认跳过'));
    for (var attempt = 0; attempt < 10; attempt++) {
      await settleBrowser(tester);
      if (find.text('未找到可用的下一季，当前季播放列表保持不变').evaluate().isNotEmpty) break;
    }
    expect(find.text('未找到可用的下一季，当前季播放列表保持不变'), findsOneWidget);
    expect(player.skippedSeason, isFalse);
    final unchanged = appState.playbackHistoryStore.sessions.single;
    expect(unchanged.seasonPlaylistPath, current);
    expect(unchanged.nextSeasonPlaylistPath, isNull);
    expect(unchanged.playerPid, 4242);
    await tester.pumpWidget(const SizedBox.shrink());
    await settleBrowser(tester);
  });

  test('WebDAV 特典目录只收取 OVA 视频并保留真实父路径', () async {
    final source = WebDavMediaSourceAdapter(appState.webDavService!);
    final root = await source.fetchDirectory('');
    expect(root.map((entry) => entry.name), contains('Extras'));
    final scan = await const SpecialVideoPlaylistCollector().collect(
      source: source,
      rootPath: '',
      rootEntries: root,
      mode: SpecialPlaylistMode.ovaOnly,
    );

    expect(scan.incomplete, isFalse);
    expect(scan.items.map((item) => item.entry.name), ['OVA02.mkv']);
    expect(scan.items.single.parentPath, 'Extras');
    expect(scan.items.single.path, 'Extras/OVA02.mkv');
  });

  test('WebDAV 视频目录可单独扫描同级特典目录', () async {
    final source = WebDavMediaSourceAdapter(appState.webDavService!);
    final root = await source.fetchDirectory('子目录');
    final scan = await const SpecialVideoPlaylistCollector().collect(
      source: source,
      rootPath: '子目录',
      rootEntries: root,
      mode: SpecialPlaylistMode.ovaOnly,
      scanChildFolders: false,
      scanSiblingFolders: true,
    );

    expect(scan.incomplete, isFalse);
    expect(scan.items.map((item) => item.path), ['Extras/OVA02.mkv']);
    expect(scan.items.single.parentPath, 'Extras');
  });

  testWidgets('目录搜索提示覆盖四语言且保留中文文件名', (tester) async {
    tester.view.physicalSize = const Size(1100, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final language in AppLanguage.values) {
      await tester.pumpWidget(buildBrowser(language: language));
      await settleBrowser(tester);
      expect(find.text('第一集.mkv'), findsOneWidget);
      await tester.tap(find.byKey(const Key('open-browser-directory-search')));
      await tester.pump();
      final l10n = AppLocalizations(language);
      await tester.tap(find.byKey(const Key('browser-search-scope')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate(
          (widget) =>
              widget is CheckedPopupMenuItem<DirectorySearchScope> &&
              widget.value == DirectorySearchScope.currentDirectory,
        ),
      );
      await tester.pump();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('browser-directory-search')),
            )
            .decoration!
            .hintText,
        l10n.text('搜索当前目录'),
      );
      await tester.tap(find.byKey(const Key('browser-search-scope')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate(
          (widget) =>
              widget is CheckedPopupMenuItem<DirectorySearchScope> &&
              widget.value == DirectorySearchScope.openListIndex,
        ),
      );
      await tester.pump();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('browser-directory-search')),
            )
            .decoration!
            .hintText,
        l10n.text('搜索全部索引（至少 2 个字符）'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('当前目录搜索、Win+V 菜单和收藏保持最小接入', (tester) async {
    tester.view.physicalSize = const Size(1100, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildBrowser());
    await settleBrowser(tester);

    expect(find.text('第一集.mkv'), findsOneWidget);
    expect(find.text('第一集.ass'), findsNothing);

    final favorite = MediaLibraryItem(
      sourceId: appState.mediaSourceId!,
      parentPath: '',
      name: '第一集.mkv',
      kind: MediaLibraryKind.video,
    );
    final favoriteButton = tester.widget<IconButton>(
      find.byKey(ValueKey<String>('favorite-${favorite.stableKey}')),
    );
    late List<MediaLibraryRecord> favorites;
    await tester.runAsync(() async {
      favoriteButton.onPressed!();
      favorites = await libraryStore.favorites(appState.mediaSourceId!);
    });
    await settleBrowser(tester);
    expect(favorites.map((record) => record.item.name), ['第一集.mkv']);

    await tester.tap(find.byKey(const Key('open-browser-directory-search')));
    await tester.pump();
    final search = tester.widget<TextField>(
      find.byKey(const Key('browser-directory-search')),
    );
    expect(search.contextMenuBuilder, isNotNull);
    await tester.tap(find.byKey(const Key('browser-search-scope')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget is CheckedPopupMenuItem<DirectorySearchScope> &&
            widget.value == DirectorySearchScope.currentDirectory,
      ),
    );
    await tester.pump();

    await tester.enterText(
      find.byKey(const Key('browser-directory-search')),
      '第一集',
    );
    await tester.pump();
    expect(find.text('第一集.mkv'), findsOneWidget);
    expect(find.text('说明.txt'), findsNothing);

    await tester.tap(find.byKey(const Key('close-browser-directory-search')));
    await tester.pump();
    expect(find.text('说明.txt'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

class _RestoringAppState extends ShellTestAppState {
  _RestoringAppState({
    required super.configStore,
    required super.playbackHistoryStore,
    required super.progressService,
    required super.directoryCache,
  });

  Completer<void>? activationGate;
  bool failActivation = false;

  @override
  Future<void> activateMountedProfile(String profileId) async {
    await activationGate?.future;
    if (failActivation) {
      throw AppException.network('Test restore connection failed');
    }
    await super.activateMountedProfile(profileId);
  }
}

class _TransitionPlayer extends ExternalPlayerService {
  _TransitionPlayer({required super.configStore});
  @override
  ExternalPlayerService forFilmLibrary(
    PlaybackProgressService progress,
    Directory watchLater,
  ) => this;
  String? selectedSessionId;
  int? selectedIndex;
  bool selectionSucceeds = true;
  @override
  Future<bool> selectPlaylistEntry(
    String sessionId,
    int index, {
    String? versionPath,
  }) async {
    selectedSessionId = sessionId;
    selectedIndex = index;
    return selectionSucceeds;
  }

  bool running = false;
  final runningSessionIds = <String>{};
  bool skippedSeason = false;
  String? skippedFrom;
  String? skippedTo;

  @override
  Future<bool> skipToNextSeason(
    String sessionId, {
    required String currentPlaylistPath,
    required String nextPlaylistPath,
  }) async {
    skippedSeason = true;
    skippedFrom = currentPlaylistPath;
    skippedTo = nextPlaylistPath;
    return true;
  }

  @override
  Future<void> captureOpenListProcessIdentity() async {}

  @override
  Future<void> restoreSession({
    required String sessionId,
    String? profileId,
    required int? pid,
    String? executablePath,
    int? creationTime,
    String? ipcPipeName,
    String? launchEpoch,
    String? currentSeasonPlaylistPath,
    int? currentStageLength,
  }) async {}

  @override
  Future<bool> isPlayerRunning([String? sessionId]) async =>
      running || runningSessionIds.contains(sessionId);

  @override
  Future<void> waitForExitSync(
    String sessionId, {
    Duration timeout = const Duration(seconds: 4),
  }) async {}
}

String _directoryXml(String requestPath) {
  if (requestPath.contains('/Extras')) {
    return '''
<d:multistatus xmlns:d="DAV:">
  ${_response('/dav/Extras/', 'Extras', directory: true)}
  ${_response('/dav/Extras/OVA02.mkv', 'OVA02.mkv')}
  ${_response('/dav/Extras/Trailer.mkv', 'Trailer.mkv')}
</d:multistatus>
''';
  }
  if (requestPath.contains(Uri.encodeComponent('子目录'))) {
    return '''
<d:multistatus xmlns:d="DAV:">
  ${_response('/dav/${Uri.encodeComponent('子目录')}/', '子目录', directory: true)}
  ${_response('/dav/${Uri.encodeComponent('子目录')}/child.mkv', 'child.mkv')}
</d:multistatus>
''';
  }
  return '''
<d:multistatus xmlns:d="DAV:">
  ${_response('/dav/', '返回上级', directory: true)}
  ${_response('/dav/${Uri.encodeComponent('子目录')}/', '子目录', directory: true)}
  ${_response('/dav/Extras/', 'Extras', directory: true)}
  ${_response('/dav/${Uri.encodeComponent('第一集.mkv')}', '第一集.mkv')}
  ${_response('/dav/${Uri.encodeComponent('第一集.ass')}', '第一集.ass')}
  ${_response('/dav/${Uri.encodeComponent('说明.txt')}', '说明.txt')}
</d:multistatus>
''';
}

String _response(String href, String name, {bool directory = false}) =>
    '''
<d:response>
  <d:href>$href</d:href>
  <d:propstat><d:prop>
    <d:displayname>$name</d:displayname>
    <d:resourcetype>${directory ? '<d:collection/>' : ''}</d:resourcetype>
    <d:getcontentlength>1024</d:getcontentlength>
  </d:prop></d:propstat>
</d:response>
''';
