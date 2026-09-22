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
import 'package:streampath/core/utils/app_paths.dart';
import 'package:streampath/domain/services/external_player_service.dart';
import 'package:streampath/presentation/pages/browser_page.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/theme/app_theme.dart';

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
    (position: 0.0, previousAtEnd: false),
    (position: 0.25, previousAtEnd: false),
    (position: 0.0, previousAtEnd: true),
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
          playlistFileNames: const ['第一集.mkv', '第二集.mkv'],
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
        expect(histories.single.fileName, '第二集.mkv');
        expect(histories.single.videoIndex, 1);
        expect(histories.single.playerPid, isNull);
        expect(records, isNotNull);
        expect(records!.single.item.name, '第二集.mkv');
        expect(records!.single.playbackSessionId, sessionId);
      },
    );
  }

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
