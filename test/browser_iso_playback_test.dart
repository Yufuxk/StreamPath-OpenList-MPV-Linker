import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/directory_cache.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/data/models/playback_history.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/domain/services/iso_access_provider.dart';
import 'package:streampath/domain/services/remote_menu_playback_service.dart';
import 'package:streampath/domain/services/iso_playback_service.dart';
import 'package:streampath/domain/services/player_process_controller.dart';
import 'package:streampath/domain/services/webdav_service.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/pages/browser_page.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/theme/app_theme.dart';

final _widgetPlayerIdentity = PlayerProcessIdentity(
  pid: 4242,
  executablePath: r'C:\Tools\mpv.exe',
  creationTime: 222222,
);
final _widgetHelperIdentity = PlayerProcessIdentity(
  pid: 3131,
  executablePath: r'C:\App\streampath_iso_bridge.exe',
  creationTime: 111111,
);
final _widgetOwnerIdentity = PlayerProcessIdentity(
  pid: 2026,
  executablePath: r'C:\App\streampath.exe',
  creationTime: 333333,
);

class _BlockingIsoProvider implements IsoAccessProvider {
  Completer<void> entered = Completer<void>();
  Completer<IsoAccessHandle>? _completed;
  Directory? _sessionDirectory;
  bool completeImmediately = false;
  bool remoteMenu = false;
  Object? prepareError;

  @override
  Future<IsoAccessHandle> prepare({
    required WebDAVService webDavService,
    required WebDavFile file,
    required Directory sessionDirectory,
    required String structureCachePath,
    void Function(IsoAccessPhase phase)? onPhase,
    Future<void> Function(PlayerProcessIdentity identity)? onHelperStarted,
  }) async {
    _sessionDirectory = sessionDirectory;
    final error = prepareError;
    if (error != null) {
      onPhase?.call(IsoAccessPhase.startingBridge);
      return Future<IsoAccessHandle>.error(error);
    }
    _completed = Completer<IsoAccessHandle>();
    await onHelperStarted?.call(_widgetHelperIdentity);
    onPhase?.call(IsoAccessPhase.probingStream);
    if (!entered.isCompleted) entered.complete();
    if (completeImmediately) {
      sessionDirectory.createSync(recursive: true);
      return remoteMenu ? _WidgetRemoteHandle(sessionDirectory) : _WidgetIsoHandle(sessionDirectory);
    }
    return _completed!.future;
  }

  @override
  void cancel() {
    final completed = _completed;
    if (completed != null && !completed.isCompleted) {
      completed.completeError(Exception('cancelled'));
    }
  }

  Future<void> completeBridge() async {
    final completed = _completed;
    if (completed == null || completed.isCompleted) return;
    final session = _sessionDirectory!;
    await session.create(recursive: true);
    completed.complete(_WidgetIsoHandle(session));
  }

  void resetEntered() {
    entered = Completer<void>();
  }
}

class _WidgetMenuService extends RemoteMenuPlaybackService {
  _WidgetMenuService(this.provider)
      : super(configLoader: () async => const PlayerConfig(name: 'MPV', executable: 'mpv'));
  final _BlockingIsoProvider provider;
  @override
  Future<String?> unavailableReason() async => provider.remoteMenu ? null : 'unavailable';
  @override
  Future<String> requireCapability({PlayerConfig? config}) async => r'C:\Tools\mpv.exe';
  @override
  Future<void> waitUntilReady({required Directory sessionDirectory,
    required Duration timeout, required Future<bool> Function() playerExited,
    required bool Function() cancelled}) async {}
}

class _WidgetRemoteHandle extends _WidgetIsoHandle implements RemoteDiscAccessHandle {
  _WidgetRemoteHandle(super.sessionDirectory);
  @override
  Uri get discUri => Uri.file('${sessionDirectory.path}\\disc\\disc.iso', windows: true);
  @override
  List<IsoBridgeTitle> get titles => const [];
}

class _WidgetIsoHandle implements IsoAccessHandle {
  _WidgetIsoHandle(this.sessionDirectory);

  @override
  final Directory sessionDirectory;
  @override
  PlayerProcessIdentity get helperIdentity => _widgetHelperIdentity;
  @override
  int get totalBytes => 1024;
  @override
  List<IsoBridgeTitle> get titles => const [
    IsoBridgeTitle(
      titleIndex: 0,
      mplsId: '00001',
      duration: Duration(minutes: 24),
      streamSize: 1000,
      chapters: [],
    ),
    IsoBridgeTitle(
      titleIndex: 1,
      mplsId: '00002',
      duration: Duration(minutes: 23),
      streamSize: 900,
      chapters: [],
    ),
  ];

  @override
  Uri playbackUri(String mplsId) => Uri.parse(
    'http://127.0.0.1:49152/0123456789abcdef0123456789abcdef/title/$mplsId.m2ts',
  );

  @override
  Future<void> attachPlayer(int pid) async {}

  @override
  Future<void> configureCache({
    required int blockCount,
    required int prefetchBlocks,
    int? cacheSecs,
  }) async {}

  @override
  Future<void> cleanup() async {
    if (await sessionDirectory.exists()) {
      await sessionDirectory.delete(recursive: true);
    }
  }
}

void main() {
  late Directory tempDirectory;
  late HttpServer server;
  late DirectoryCache directoryCache;
  late PlaybackProgressService progressService;
  late AppState appState;
  late IsoPlaybackService isoPlaybackService;
  late _BlockingIsoProvider isoProvider;
  late Map<int, bool> processAlive;

  setUpAll(() {
    sqfliteFfiInit();
    HttpOverrides.global = null;
  });

  setUp(() async {
    tempDirectory = Directory.systemTemp.createTempSync(
      'browser_iso_playback_',
    );
    Hive.init(p.join(tempDirectory.path, 'hive'));
    directoryCache = DirectoryCache(boxName: 'browser-iso-playback');
    await directoryCache.init();
    progressService = await PlaybackProgressService.open(
      p.join(tempDirectory.path, 'progress.db'),
      factory: databaseFactoryFfi,
    );
    final configStore = StreamPathConfigStore.forPath(
      p.join(tempDirectory.path, 'config.json'),
    );
    isoProvider = _BlockingIsoProvider();
    processAlive = {
      _widgetPlayerIdentity.pid: true,
      _widgetHelperIdentity.pid: true,
      _widgetOwnerIdentity.pid: true,
    };
    isoPlaybackService = IsoPlaybackService(
      configStore: configStore,
      accessProvider: isoProvider,
      remoteMenuAccessProvider: isoProvider,
      remoteMenuService: _WidgetMenuService(isoProvider),
      processController: PlayerProcessController(
        snapshotLoader: (pid) async {
          final identity = pid == _widgetPlayerIdentity.pid
              ? _widgetPlayerIdentity
              : pid == _widgetHelperIdentity.pid
              ? _widgetHelperIdentity
              : pid == _widgetOwnerIdentity.pid
              ? _widgetOwnerIdentity
              : null;
          return identity != null && processAlive[pid] == true
              ? PlayerProcessLookupResult.found(identity)
              : const PlayerProcessLookupResult.notFound();
        },
        processTreeTerminator: (pid) async {
          processAlive[pid] = false;
          return true;
        },
      ),
      configLoader: () async =>
          const PlayerConfig(name: 'MPV', executable: r'C:\Tools\mpv.exe'),
      processStarter: (_, _) async => _widgetPlayerIdentity.pid,
      ownerIdentityLoader: () async => _widgetOwnerIdentity,
      tempRootProvider: () async => Directory(
        p.join(tempDirectory.path, IsoPlaybackService.tempDirectoryName),
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
        ..write(_directoryXml());
      await request.response.close();
    });
    appState = AppState(
      configStore: configStore,
      playbackHistoryStore: PlaybackHistoryStore.forPath(
        p.join(tempDirectory.path, 'history.json'),
      ),
      progressService: progressService,
      directoryCache: directoryCache,
      isoPlaybackService: isoPlaybackService,
    );
    await appState.connect(
      baseUrl: 'http://${server.address.address}:${server.port}/dav',
      username: 'user',
      password: 'secret',
    );
  });

  tearDown(() async {
    appState.dispose();
    await progressService.close();
    await directoryCache.close();
    await Hive.close();
    await server.close(force: true);
    for (
      var attempt = 0;
      attempt < 20 && tempDirectory.existsSync();
      attempt++
    ) {
      try {
        await tempDirectory.delete(recursive: true);
      } on FileSystemException {
        if (attempt == 19) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  Future<void> settleBrowser(WidgetTester tester) async {
    for (var index = 0; index < 5; index++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    }
  }

  Future<void> waitForWidget(WidgetTester tester, Finder finder) async {
    for (var index = 0; index < 160; index++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
      if (finder.evaluate().isNotEmpty) return;
    }
  }

  Widget buildBrowser({AppLanguage language = AppLanguage.simplifiedChinese}) =>
      ChangeNotifierProvider<AppState>.value(
        value: appState,
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: language.locale,
          supportedLocales: AppLanguage.values
              .map((item) => item.locale)
              .toList(),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const BrowserPage(),
        ),
      );

  testWidgets('ISO 远程播放直接显示 Bridge 进度并可取消', (tester) async {
    tester.view.physicalSize = const Size(1100, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildBrowser());
    await settleBrowser(tester);
    await tester.tap(find.text('DISC.iso'));
    await waitForWidget(tester, find.byKey(const Key('iso-streaming-dialog')));
    await waitForWidget(tester, find.text('正在探测 ISO 流式读取…'));

    expect(find.byKey(const Key('iso-streaming-dialog')), findsOneWidget);
    expect(find.text('正在探测 ISO 流式读取…'), findsOneWidget);
    expect(find.textContaining('仅支持未加密 Blu-ray ISO'), findsOneWidget);

    await tester.tap(find.byKey(const Key('iso-streaming-cancel')));
    await settleBrowser(tester);

    expect(find.byKey(const Key('iso-streaming-dialog')), findsNothing);
    expect(find.text('已取消 ISO 播放'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('ISO 服务繁忙时不再打开流式播放弹窗', (tester) async {
    tester.view.physicalSize = const Size(1100, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildBrowser());
    await settleBrowser(tester);
    late Future<IsoPlaybackLaunchResult?> pending;
    await tester.runAsync(() async {
      pending = isoPlaybackService.start(
        webDavService: appState.webDavService!,
        file: const WebDavFile(
          name: 'DISC.iso',
          href: '/dav/DISC.iso',
          isDirectory: false,
          size: 1024,
        ),
      );
      await isoProvider.entered.future.timeout(const Duration(seconds: 2));
    });

    await tester.tap(find.text('DISC.iso'));
    await tester.pump();

    expect(find.text('ISO 远程播放测试模块正在执行其他任务'), findsOneWidget);
    expect(find.byKey(const Key('iso-streaming-dialog')), findsNothing);

    await tester.runAsync(() async {
      isoPlaybackService.cancel();
      await pending;
    });
    expect(isoPlaybackService.isBusy, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('Bridge 未知启动异常会关闭进度弹窗并完成清理', (tester) async {
    tester.view.physicalSize = const Size(1100, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    isoProvider.prepareError = StateError('unsendable isolate context');

    await tester.pumpWidget(buildBrowser());
    await settleBrowser(tester);
    await tester.tap(find.text('DISC.iso'));
    await waitForWidget(tester, find.textContaining('ISO 流式播放失败'));

    expect(find.byKey(const Key('iso-streaming-dialog')), findsNothing);
    expect(find.textContaining('ISO Bridge 启动失败'), findsOneWidget);
    expect(isoPlaybackService.isBusy, isFalse);
    final isoRoot = Directory(
      p.join(tempDirectory.path, IsoPlaybackService.tempDirectoryName),
    );
    final isoRootIsEmpty = await tester.runAsync(() => isoRoot.list().isEmpty);
    expect(isoRootIsEmpty, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('Bridge 解析后可选择 Title、调整顺序并取消清理', (tester) async {
    tester.view.physicalSize = const Size(1100, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildBrowser());
    await settleBrowser(tester);
    isoProvider.completeImmediately = true;
    await tester.tap(find.text('DISC.iso'));
    await waitForWidget(
      tester,
      find.byKey(const Key('iso-title-selection-dialog')),
    );

    expect(find.byKey(const Key('iso-title-selection-dialog')), findsOneWidget);
    expect(find.text('Title 0'), findsOneWidget);
    expect(find.text('Title 1'), findsOneWidget);
    expect(find.textContaining('00001.mpls'), findsOneWidget);

    final firstBefore = tester.getTopLeft(find.text('Title 0')).dy;
    final secondBefore = tester.getTopLeft(find.text('Title 1')).dy;
    expect(firstBefore, lessThan(secondBefore));
    await tester.tap(find.byKey(const Key('iso-title-up-00002')));
    await tester.pump();
    expect(
      tester.getTopLeft(find.text('Title 1')).dy,
      lessThan(tester.getTopLeft(find.text('Title 0')).dy),
    );

    await tester.tap(find.widgetWithText(TextButton, '取消播放'));
    await settleBrowser(tester);

    expect(find.byKey(const Key('iso-title-selection-dialog')), findsNothing);
    expect(find.text('已取消 ISO 播放'), findsOneWidget);
    final isoRoot = Directory(
      p.join(tempDirectory.path, IsoPlaybackService.tempDirectoryName),
    );
    final isoRootIsEmpty = await tester.runAsync(() => isoRoot.list().isEmpty);
    expect(isoRootIsEmpty, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('独立菜单没有进度也保留底栏，重新打开仍可选菜单', (tester) async {
    tester.view.physicalSize = const Size(1100, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    isoProvider.completeImmediately = true;
    isoProvider.remoteMenu = true;
    await tester.pumpWidget(buildBrowser());
    await settleBrowser(tester);
    await tester.tap(find.text('DISC.iso'));
    await waitForWidget(tester, find.text('蓝光菜单播放'));
    await tester.tap(find.text('蓝光菜单播放'));
    await waitForWidget(tester, find.text('正在播放 ISO：DISC.iso'));
    await waitForWidget(tester, find.text('ISO 播放器已启动，关闭 MPV 后将清理会话文件'));
    await settleBrowser(tester);
    final histories = (await tester.runAsync(() => appState.playbackHistoryStore.loadAll()))!;
    final history = histories.single;
    final path = history.isoSessionDirectoryPath!;
    await tester.runAsync(() async {
      expect(await File(p.join(path, 'menu-progress.lua')).exists(), isFalse);
      processAlive.updateAll((_, _) => false);
      await Future<void>.delayed(const Duration(milliseconds: 2100));
    });
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 700));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    }
    await waitForWidget(tester, find.text('继续播放 ISO：DISC.iso'));
    expect(find.text('继续播放 ISO：DISC.iso'), findsOneWidget);
    final bar = find.byKey(ValueKey<String>('iso-playback-bar-${history.sessionId}'));
    expect(bar, findsOneWidget);
    final saved = (await tester.runAsync(() => appState.playbackHistoryStore.loadAll()))!;
    expect(saved.single.isoSessionDirectoryPath, isNull);
    await tester.tap(find.descendant(of: bar, matching: find.byIcon(Icons.play_arrow)));
    await waitForWidget(tester, find.text('蓝光菜单播放'));
    expect(find.text('蓝光菜单播放'), findsOneWidget);
    await tester.tap(find.text('取消').last);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('ISO 启动后写入共用视频底栏并在中断后保留继续播放', (tester) async {
    tester.view.physicalSize = const Size(1100, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    isoProvider.completeImmediately = true;

    await tester.pumpWidget(buildBrowser());
    await settleBrowser(tester);
    await tester.tap(find.text('DISC.iso'));
    await waitForWidget(
      tester,
      find.byKey(const Key('iso-title-selection-dialog')),
    );
    await tester.tap(find.widgetWithText(FilledButton, '播放所选标题'));
    await waitForWidget(tester, find.text('正在播放 ISO：DISC.iso'));
    await waitForWidget(tester, find.text('ISO 播放器已启动，关闭 MPV 后将清理会话文件'));

    var histories = await tester.runAsync(
      () => appState.playbackHistoryStore.loadAll(),
    );
    expect(histories, hasLength(1));
    expect(histories!.single.kind, PlaybackHistoryKind.iso);
    final sessionPath = histories.single.isoSessionDirectoryPath!;
    await tester.runAsync(() async {
      await File(
        p.join(sessionPath, IsoPlaybackService.statusFileName),
      ).writeAsString(
        '0\nhttp://127.0.0.1/title/00001.m2ts\n1\n120.0\n1440.0\n'
        '-1\n-1\n-1\niso-bridge|-1\n0\n-1\n-1\n-1x-1\n0\n2\n0\n',
        flush: true,
      );
    });
    await tester.pump(const Duration(milliseconds: 700));
    await waitForWidget(tester, find.text('ISO 已暂停：DISC.iso'));
    expect(find.text('ISO 已暂停：DISC.iso'), findsOneWidget);

    final bar = find.byKey(
      ValueKey<String>('iso-playback-bar-${histories.single.sessionId}'),
    );
    final resumeButton = tester.widget<IconButton>(
      find.ancestor(
        of: find.descendant(of: bar, matching: find.byIcon(Icons.play_arrow)),
        matching: find.byType(IconButton),
      ),
    );
    resumeButton.onPressed!();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
    final command = await tester.runAsync(() async {
      final file = File(
        p.join(sessionPath, IsoPlaybackService.commandFileName),
      );
      for (var attempt = 0; attempt < 20; attempt++) {
        final value = await file.readAsString();
        if (value == 'resume') return value;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return file.readAsString();
    });
    expect(command, 'resume');

    await tester.runAsync(() async {
      await File(p.join(sessionPath, 'iso-progress.jsonl')).writeAsString(
        '{"outcome":"position","playlist_pos":0,"position":120.0,"duration":1440.0}\n',
        flush: true,
      );
      processAlive.updateAll((_, _) => false);
    });
    for (var attempt = 0; attempt < 4; attempt++) {
      await tester.pump(const Duration(milliseconds: 700));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    }
    await waitForWidget(tester, find.text('继续播放 ISO：DISC.iso'));
    expect(find.text('继续播放 ISO：DISC.iso'), findsOneWidget);
    histories = await tester.runAsync(
      () => appState.playbackHistoryStore.loadAll(),
    );
    expect(histories!.single.kind, PlaybackHistoryKind.iso);
    expect(histories.single.playerPid, isNull);
    expect(histories.single.isoSessionDirectoryPath, isNull);
  });

  testWidgets('ISO 流式播放弹窗在四种语言下使用本地化文案', (tester) async {
    tester.view.physicalSize = const Size(1100, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final language in AppLanguage.values) {
      isoProvider.resetEntered();
      final localizations = AppLocalizations(language);
      await tester.pumpWidget(buildBrowser(language: language));
      await settleBrowser(tester);
      await tester.tap(find.text('DISC.iso'));
      await waitForWidget(
        tester,
        find.byKey(const Key('iso-streaming-dialog')),
      );
      await waitForWidget(
        tester,
        find.text(localizations.text('正在探测 ISO 流式读取…')),
      );
      expect(find.text(localizations.text('ISO 远程播放测试')), findsOneWidget);
      expect(find.text(localizations.text('正在探测 ISO 流式读取…')), findsOneWidget);

      await tester.tap(find.byKey(const Key('iso-streaming-cancel')));
      await settleBrowser(tester);
      expect(find.byKey(const Key('iso-streaming-dialog')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });
}

String _directoryXml() => '''
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/</d:href>
    <d:propstat><d:prop>
      <d:displayname>返回上级</d:displayname>
      <d:resourcetype><d:collection/></d:resourcetype>
      <d:getcontentlength>0</d:getcontentlength>
    </d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/DISC.iso</d:href>
    <d:propstat><d:prop>
      <d:displayname>DISC.iso</d:displayname>
      <d:resourcetype></d:resourcetype>
      <d:getcontentlength>1024</d:getcontentlength>
    </d:prop></d:propstat>
  </d:response>
</d:multistatus>
''';
