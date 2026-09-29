import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/directory_cache.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/data/models/playback_history.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/data/models/special_playlist_mode.dart';
import 'package:streampath/core/utils/app_paths.dart';
import 'package:streampath/domain/services/external_player_service.dart';
import 'package:streampath/presentation/pages/browser_page.dart';
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

  setUpAll(() {
    sqfliteFfiInit();
    HttpOverrides.global = null;
  });

  setUp(() async {
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

  Widget buildBrowser() => ChangeNotifierProvider<AppState>.value(
    value: appState,
    child: MaterialApp(theme: AppTheme.light(), home: const BrowserPage()),
  );

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
      },
    );
  }

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

class _TransitionPlayer extends ExternalPlayerService {
  _TransitionPlayer({required super.configStore});
  bool running = false;
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
  Future<bool> isPlayerRunning([String? sessionId]) async => running;

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
