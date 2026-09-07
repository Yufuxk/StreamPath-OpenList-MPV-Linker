import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/data/remote/webdav_client.dart';
import 'package:streampath/domain/services/iso_access_provider.dart';
import 'package:streampath/domain/services/iso_playback_service.dart';
import 'package:streampath/domain/services/player_process_controller.dart';
import 'package:streampath/domain/services/webdav_service.dart';
import 'package:streampath/domain/services/remote_menu_playback_service.dart';
import 'package:streampath/domain/services/mpv_watch_later_sync.dart';
import 'package:streampath/data/models/media_source.dart';

final _helperIdentity = PlayerProcessIdentity(
  pid: 3131,
  executablePath: r'C:\App\streampath_iso_bridge.exe',
  creationTime: 111111,
);

class _FakeIsoHandle implements IsoAccessHandle {
  _FakeIsoHandle(this.sessionDirectory, {this.beforeCleanup});

  @override
  final Directory sessionDirectory;
  final Future<void> Function()? beforeCleanup;
  @override
  PlayerProcessIdentity get helperIdentity => _helperIdentity;
  @override
  int get totalBytes => 1024 * 1024 * 1024;
  @override
  List<IsoBridgeTitle> get titles => const [
    IsoBridgeTitle(
      titleIndex: 0,
      mplsId: '00001',
      duration: Duration(minutes: 24),
      streamSize: 1000,
      chapters: [
        IsoBridgeChapter(
          start: Duration.zero,
          duration: Duration(minutes: 12),
          name: 'Chapter 1',
        ),
      ],
    ),
    IsoBridgeTitle(
      titleIndex: 1,
      mplsId: '00002',
      duration: Duration(minutes: 23),
      streamSize: 900,
      chapters: [],
    ),
  ];

  int? attachedPid;
  int? configuredBlockCount;
  int? configuredPrefetchBlocks;
  int? configuredCacheSecs;
  bool cleaned = false;

  @override
  Uri playbackUri(String mplsId) => Uri.parse(
    'http://127.0.0.1:49152/0123456789abcdef0123456789abcdef/title/$mplsId.m2ts',
  );

  @override
  Future<void> attachPlayer(int pid) async => attachedPid = pid;

  @override
  Future<void> configureCache({
    required int blockCount,
    required int prefetchBlocks,
    int? cacheSecs,
  }) async {
    configuredBlockCount = blockCount;
    configuredPrefetchBlocks = prefetchBlocks;
    configuredCacheSecs = cacheSecs;
  }

  @override
  Future<void> cleanup() async {
    final callback = beforeCleanup;
    if (callback != null) await callback();
    cleaned = true;
    if (await sessionDirectory.exists()) {
      await sessionDirectory.delete(recursive: true);
    }
  }
}

class _FakeRemoteHandle extends _FakeIsoHandle
    implements RemoteDiscAccessHandle {
  _FakeRemoteHandle(super.sessionDirectory);
  @override
  Uri get discUri =>
      Uri.file('${sessionDirectory.path}\\disc\\disc.iso', windows: true);
  @override
  List<IsoBridgeTitle> get titles => const [];
}

class _FakeMenuService extends RemoteMenuPlaybackService {
  _FakeMenuService({this.onReady})
    : super(
        configLoader: () async =>
            const PlayerConfig(name: 'MPV', executable: 'mpv'),
      );
  final void Function()? onReady;
  @override
  Future<String> requireCapability({PlayerConfig? config}) async =>
      r'C:\Menu\mpv.exe';
  @override
  Future<void> waitUntilReady({
    required Directory sessionDirectory,
    required Duration timeout,
    required Future<bool> Function() playerExited,
    required bool Function() cancelled,
  }) async {
    onReady?.call();
  }
}

class _FakeIsoAccessProvider implements IsoAccessProvider {
  _FakeIsoAccessProvider({this.handleFactory});

  final _FakeIsoHandle Function(Directory sessionDirectory)? handleFactory;
  bool prepareCalled = false;
  bool cancelCalled = false;
  _FakeIsoHandle? handle;
  String? structureCachePath;

  @override
  Future<IsoAccessHandle> prepare({
    required WebDAVService webDavService,
    required WebDavFile file,
    required Directory sessionDirectory,
    required String structureCachePath,
    void Function(IsoAccessPhase phase)? onPhase,
    Future<void> Function(PlayerProcessIdentity identity)? onHelperStarted,
  }) async {
    prepareCalled = true;
    this.structureCachePath = structureCachePath;
    await sessionDirectory.create(recursive: true);
    onPhase?.call(IsoAccessPhase.startingBridge);
    await onHelperStarted?.call(_helperIdentity);
    onPhase?.call(IsoAccessPhase.probingStream);
    onPhase?.call(IsoAccessPhase.parsingTitles);
    return handle =
        handleFactory?.call(sessionDirectory) ??
        _FakeIsoHandle(sessionDirectory);
  }

  @override
  void cancel() => cancelCalled = true;
}

class _BlockingIsoAccessProvider implements IsoAccessProvider {
  final Completer<void> entered = Completer<void>();
  final Completer<IsoAccessHandle> completed = Completer<IsoAccessHandle>();
  bool cancelCalled = false;

  @override
  Future<IsoAccessHandle> prepare({
    required WebDAVService webDavService,
    required WebDavFile file,
    required Directory sessionDirectory,
    required String structureCachePath,
    void Function(IsoAccessPhase phase)? onPhase,
    Future<void> Function(PlayerProcessIdentity identity)? onHelperStarted,
  }) async {
    await onHelperStarted?.call(_helperIdentity);
    entered.complete();
    return completed.future;
  }

  @override
  void cancel() {
    cancelCalled = true;
    if (!completed.isCompleted) {
      completed.completeError(AppException.network('ISO 流式播放已取消'));
    }
  }
}

class _FailingIsoAccessProvider implements IsoAccessProvider {
  @override
  Future<IsoAccessHandle> prepare({
    required WebDAVService webDavService,
    required WebDavFile file,
    required Directory sessionDirectory,
    required String structureCachePath,
    void Function(IsoAccessPhase phase)? onPhase,
    Future<void> Function(PlayerProcessIdentity identity)? onHelperStarted,
  }) async {
    onPhase?.call(IsoAccessPhase.startingBridge);
    throw StateError('unsendable isolate context');
  }

  @override
  void cancel() {}
}

void main() {
  late Directory tempDirectory;
  late StreamPathConfigStore configStore;
  late WebDAVService webDavService;
  late Map<int, bool> alive;
  late PlayerProcessController processController;

  final playerIdentity = PlayerProcessIdentity(
    pid: 4242,
    executablePath: r'C:\Tools\mpv.exe',
    creationTime: 222222,
  );
  final ownerIdentity = PlayerProcessIdentity(
    pid: 2026,
    executablePath: r'C:\App\streampath.exe',
    creationTime: 333333,
  );
  const isoFile = WebDavFile(
    name: 'DISC.iso',
    href: 'https://dav.example/media/DISC.iso?token=secret',
    isDirectory: false,
    size: 3,
  );

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'streampath_iso_service_',
    );
    configStore = StreamPathConfigStore.forPath(
      p.join(tempDirectory.path, 'config.json'),
    );
    webDavService = WebDAVService(
      client: WebDavClient(baseUrl: 'https://dav.example'),
    );
    alive = {
      playerIdentity.pid: true,
      _helperIdentity.pid: true,
      ownerIdentity.pid: true,
    };
    processController = PlayerProcessController(
      snapshotLoader: (pid) async {
        final identity = pid == playerIdentity.pid
            ? playerIdentity
            : pid == _helperIdentity.pid
            ? _helperIdentity
            : pid == ownerIdentity.pid
            ? ownerIdentity
            : null;
        return identity != null && alive[pid] == true
            ? PlayerProcessLookupResult.found(identity)
            : const PlayerProcessLookupResult.notFound();
      },
      processTreeTerminator: (pid) async {
        alive[pid] = false;
        return true;
      },
    );
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  IsoPlaybackService buildService(
    IsoAccessProvider provider, {
    IsoAccessProvider? remoteProvider,
    RemoteMenuPlaybackService? menuService,
    void Function(List<String>)? onLaunch,
    bool shareMenuProgress = false,
  }) => IsoPlaybackService(
    configStore: configStore,
    accessProvider: provider,
    remoteMenuAccessProvider: remoteProvider,
    remoteMenuService: menuService,
    processController: processController,
    configLoader: () async =>
        PlayerConfig(name: 'MPV', executable: r'C:\Tools\mpv.exe',
            menuProgressSharingEnabled: shareMenuProgress),
    processStarter: (_, args) async {
      onLaunch?.call(args);
      return playerIdentity.pid;
    },
    ownerIdentityLoader: () async => ownerIdentity,
    tempRootProvider: () async => Directory(
      p.join(tempDirectory.path, IsoPlaybackService.tempDirectoryName),
    ),
  );

  test('菜单使用独立 provider、模式与会话键，复用暂停和清理', () async {
    final legacy = _FakeIsoAccessProvider();
    final remote = _FakeIsoAccessProvider(handleFactory: _FakeRemoteHandle.new);
    final service = buildService(
      legacy,
      remoteProvider: remote,
      menuService: _FakeMenuService(),
    );
    addTearDown(service.dispose);
    final launch = (await service.startRemoteMenu(
      webDavService: webDavService,
      file: isoFile,
    ))!;
    expect(legacy.prepareCalled, isFalse);
    expect(launch.playbackMode, PlaybackMode.webdavHdmvMenu);
    expect(await File(p.join(launch.sessionDirectoryPath, 'menu-progress.lua')).exists(), isFalse);
    expect(launch.args.any((arg) => arg.contains('streampath-menu-position')), isFalse);
    expect(remote.handle!.configuredBlockCount, 128);
    expect(remote.handle!.configuredPrefetchBlocks, 96);
    expect(remote.handle!.configuredCacheSecs, 60);
    expect(remote.handle!.attachedPid, playerIdentity.pid);
    final manifest =
        jsonDecode(
              await File(
                p.join(
                  launch.sessionDirectoryPath,
                  IsoPlaybackService.manifestFileName,
                ),
              ).readAsString(),
            )
            as Map;
    expect(manifest['playbackMode'], 'webdavHdmvMenu');
    expect(manifest['transport'], 'winfsp');
    expect(jsonEncode(manifest), isNot(contains('dav.example')));
    await service.sendPause(launch.sessionDirectoryPath);
    expect(
      await File(
        p.join(launch.sessionDirectoryPath, IsoPlaybackService.commandFileName),
      ).readAsString(),
      'pause',
    );
    await expectLater(
      service.startRemoteMenu(webDavService: webDavService, file: isoFile),
      throwsA(isA<AppException>()),
    );
    alive[playerIdentity.pid] = false;
    alive[_helperIdentity.pid] = false;
    await service.sessionSnapshot(launch.sessionDirectoryPath);
    expect(remote.handle!.cleaned, isTrue);
    expect(await service.getLibraryProgressByKey(launch.isoKey), isNull);
  });

  test('共享菜单记录 MPLS 进度供标题使用，但菜单重新启动不跳转', () async {
    final remote = _FakeIsoAccessProvider(handleFactory: _FakeRemoteHandle.new);
    var launchedArgs = <String>[];
    final service = buildService(
      _FakeIsoAccessProvider(),
      remoteProvider: remote,
      menuService: _FakeMenuService(),
      onLaunch: (args) => launchedArgs = args,
      shareMenuProgress: true,
    );
    addTearDown(service.dispose);
    final launch = (await service.startRemoteMenu(
      webDavService: webDavService,
      file: isoFile,
    ))!;
    await File(p.join(launch.sessionDirectoryPath, 'menu-progress.jsonl'))
        .writeAsString('${jsonEncode({
          'edition': 1, 'editions': 4, 'mplsId': '00002', 'position': 123.5,
          'duration': 1500.0, 'completed': false,
        })}\n');
    alive[playerIdentity.pid] = false;
    alive[_helperIdentity.pid] = false;
    await service.sessionSnapshot(launch.sessionDirectoryPath);
    final progress = await service.getLibraryProgressByKey(
      launch.isoKey, playbackMode: PlaybackMode.webdavHdmvMenu,
    );
    expect(progress, isNotNull);
    expect(progress!.position.inMilliseconds, 123500);
    expect(progress.episodeNumber, 2);
    expect(progress.episodeCount, 4);
    final recovered = buildService(_FakeIsoAccessProvider());
    addTearDown(recovered.dispose);
    expect((await recovered.getLibraryProgressByKey(
      launch.isoKey, playbackMode: PlaybackMode.webdavHdmvMenu,
    ))?.position, progress.position);
    expect(await service.getLibraryProgress(
      profileId: webDavService.sourceId,
      resolvedUrl: webDavService.resolveUrl(isoFile.href),
      playbackMode: PlaybackMode.webdavHdmvMenu,
    ), isNotNull);
    expect(await service.getLibraryProgress(
      profileId: webDavService.sourceId,
      resolvedUrl: webDavService.resolveUrl(isoFile.href),
    ), isNull);
    alive[playerIdentity.pid] = true;
    alive[_helperIdentity.pid] = true;
    final titleLaunch = (await service.start(
      webDavService: webDavService, file: isoFile,
      selectTitles: (request) async {
        expect(request.resumeByMplsId['00002']?.position,
            const Duration(milliseconds: 123500));
        expect(request.resumeByMplsId.containsKey('00001'), isFalse);
        expect(request.lastMplsId, '00002');
        return IsoTitleSelection.all(request.titles);
      },
    ))!;
    expect(titleLaunch.args, contains('--playlist-start=1'));
    alive[playerIdentity.pid] = false;
    alive[_helperIdentity.pid] = false;
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    await service.sessionSnapshot(titleLaunch.sessionDirectoryPath);
    alive[playerIdentity.pid] = true;
    alive[_helperIdentity.pid] = true;
    final second = (await service.startRemoteMenu(
      webDavService: webDavService, file: isoFile,
    ))!;
    expect(launchedArgs.any((arg) => arg.contains('streampath-menu-edition') ||
        arg.contains('streampath-menu-position')), isFalse);
    expect(launchedArgs.any((arg) => arg.startsWith('--edition=')), isFalse);
    await File(p.join(second.sessionDirectoryPath, 'menu-progress.jsonl'))
        .writeAsString('${jsonEncode({
          'edition': 1, 'editions': 4, 'mplsId': '00002', 'position': 1490.0,
          'duration': 1500.0, 'completed': false,
        })}\n{"partial":');
    alive[playerIdentity.pid] = false;
    alive[_helperIdentity.pid] = false;
    await service.sessionSnapshot(second.sessionDirectoryPath);
    expect(await service.getLibraryProgressByKey(
      second.isoKey, playbackMode: PlaybackMode.webdavHdmvMenu,
    ), isNull);
    expect(await service.getLibraryProgress(
      profileId: webDavService.sourceId,
      resolvedUrl: webDavService.resolveUrl(isoFile.href),
    ), isNull);
  });

  test('共享菜单跨应用重启恢复，逐 MPLS 保留最后进度并清除零位置', () async {
    final service = buildService(_FakeIsoAccessProvider(),
      remoteProvider: _FakeIsoAccessProvider(handleFactory: _FakeRemoteHandle.new),
      menuService: _FakeMenuService(), shareMenuProgress: true);
    final launch = (await service.startRemoteMenu(webDavService: webDavService, file: isoFile))!;
    final manifest = jsonDecode(await File(p.join(launch.sessionDirectoryPath,
        IsoPlaybackService.manifestFileName)).readAsString()) as Map;
    final titleKey = manifest['sharedResumeKey'] as String;
    service.dispose();
    final records = [
      {'edition': 3, 'editions': 5, 'mplsId': '00001', 'position': 200.0, 'duration': 1440.0, 'completed': false},
      {'edition': 1, 'editions': 5, 'mplsId': '00002', 'position': 120.0, 'duration': 1380.0, 'completed': false},
      {'edition': 3, 'editions': 5, 'mplsId': '00001', 'position': 0.0, 'duration': 1440.0, 'completed': false},
    ];
    await File(p.join(launch.sessionDirectoryPath, 'menu-progress.jsonl'))
        .writeAsString('${records.map(jsonEncode).join('\n')}\n{"partial":');
    alive[playerIdentity.pid] = false;
    alive[_helperIdentity.pid] = false;
    final restored = buildService(_FakeIsoAccessProvider(), menuService: _FakeMenuService());
    addTearDown(restored.dispose);
    await restored.initialize();
    expect(await Directory(launch.sessionDirectoryPath).exists(), isFalse);
    final directory = Directory(p.join(tempDirectory.path, 'iso_watch_later', titleKey));
    final index = await const MpvWatchLaterSync().buildIndex(directory,
        ['bd://mpls/00001', 'bd://mpls/00002']);
    expect(index.recordFor('bd://mpls/00001'), isNull);
    expect(index.recordFor('bd://mpls/00002')?.startSeconds, 120);

  });

  test('菜单启动等待阶段取消会定向关闭播放器并清理本次会话', () async {
    final remote = _FakeIsoAccessProvider(handleFactory: _FakeRemoteHandle.new);
    late final IsoPlaybackService service;
    service = buildService(
      _FakeIsoAccessProvider(),
      remoteProvider: remote,
      menuService: _FakeMenuService(onReady: () => service.cancel()),
    );
    addTearDown(service.dispose);
    expect(
      await service.startRemoteMenu(
        webDavService: webDavService,
        file: isoFile,
      ),
      isNull,
    );
    expect(remote.handle!.cleaned, isTrue);
    expect(alive[playerIdentity.pid], isFalse);
    expect(service.isBusy, isFalse);
  });

  test('非 MPV 配置在启动 Bridge 前失败', () async {
    final provider = _FakeIsoAccessProvider();
    final service = IsoPlaybackService(
      configStore: configStore,
      accessProvider: provider,
      configLoader: () async =>
          const PlayerConfig(name: 'VLC', executable: r'C:\Tools\vlc.exe'),
      tempRootProvider: () async => Directory(tempDirectory.path),
    );

    await expectLater(
      service.start(webDavService: webDavService, file: isoFile),
      throwsA(isA<ConfigException>()),
    );
    expect(provider.prepareCalled, isFalse);
    service.dispose();
  });

  test('MPV 参数禁用跨 Title 预取并完整接管 ISO 缓存参数', () {
    final args = IsoPlaybackService.buildMpvArgs(
      config: const PlayerConfig(
        name: 'MPV',
        executable: 'mpv',
        args: [
          '--hwdec=auto',
          '--http-header-fields=Authorization: Basic secret',
          '--cookies-file',
          r'C:\secret-cookies.txt',
          '--referrer=https://dav.example/secret',
          '--http-proxy=http://user:pass@proxy',
          r'--bluray-device=C:\old.iso',
          '--load-unsafe-playlists=yes',
          '--resume-playback=yes',
          '--save-position-on-quit',
          '--idle=yes',
          '--keep-open',
          '--cache=no',
          '--cache-secs=1',
          '--cache-on-disk=yes',
          '--cache-pause-wait=1',
          '--demuxer-cache-wait=yes',
          '--demuxer-max-bytes=5GiB',
          '--demuxer-readahead-secs=120',
          '--demuxer-hysteresis-secs=20',
          '--rebase-start-time=no',
          '--demuxer-lavf-linearize-timestamps=yes',
          '--demuxer-lavf-o-add=correct_ts_overflow=0',
          r'--input-ipc-server=\\.\pipe\old_iso_pipe',
          '--prefetch-playlist=yes',
          '{url}',
        ],
      ),
      title: 'DISC\u0000\nTITLE',
      playlistPath: r'C:\Temp\iso-playlist.m3u8',
      playlistStart: 1,
      progressScriptPath: r'C:\Temp\iso-progress.lua',
      ipcPipeName: r'\\.\pipe\streampath_iso_test',
    );
    final joined = args.join('\n');

    expect(args, contains('--hwdec=auto'));
    expect(args, contains('--resume-playback=no'));
    expect(args, contains('--save-position-on-quit=no'));
    expect(args, contains('--idle=no'));
    expect(args, contains('--keep-open=no'));
    expect(args, contains('--cookies=no'));
    expect(args, contains('--http-proxy='));
    expect(args, contains('--rebase-start-time=yes'));
    expect(args, contains('--demuxer-lavf-linearize-timestamps=no'));
    expect(args, contains('--demuxer-lavf-o-add=correct_ts_overflow=1'));
    expect(args, contains('--cache=yes'));
    expect(args, contains('--cache-secs=60'));
    expect(args, contains('--cache-on-disk=no'));
    expect(args, contains('--cache-pause=yes'));
    expect(args, contains('--cache-pause-initial=yes'));
    expect(args, contains('--cache-pause-wait=3'));
    expect(args, contains('--demuxer-cache-wait=no'));
    expect(args, contains('--demuxer-max-bytes=512MiB'));
    expect(args, contains('--demuxer-readahead-secs=60'));
    expect(args, contains('--prefetch-playlist=no'));
    expect(joined, isNot(contains('--cache=no')));
    expect(joined, isNot(contains('--idle=yes')));
    expect(joined, isNot(contains('--keep-open=yes')));
    expect(args.where((arg) => arg == '--keep-open'), isEmpty);
    expect(joined, isNot(contains('--cache-secs=1')));
    expect(joined, isNot(contains('--cache-on-disk=yes')));
    expect(joined, isNot(contains('--cache-pause-wait=1')));
    expect(joined, isNot(contains('--demuxer-cache-wait=yes')));
    expect(joined, isNot(contains('--demuxer-max-bytes=5GiB')));
    expect(joined, isNot(contains('--demuxer-readahead-secs=120')));
    expect(joined, isNot(contains('--demuxer-hysteresis-secs=20')));
    expect(joined, isNot(contains('--rebase-start-time=no')));
    expect(joined, isNot(contains('--demuxer-lavf-linearize-timestamps=yes')));
    expect(
      args.lastIndexOf('--demuxer-lavf-o-add=correct_ts_overflow=1'),
      greaterThan(
        args.lastIndexOf('--demuxer-lavf-o-add=correct_ts_overflow=0'),
      ),
    );
    expect(args, contains(r'--input-ipc-server=\\.\pipe\streampath_iso_test'));
    expect(joined, isNot(contains('old_iso_pipe')));
    expect(joined, isNot(contains('--prefetch-playlist=yes')));
    expect(joined, isNot(contains('Authorization')));
    expect(joined, isNot(contains('secret-cookies')));
    expect(joined, isNot(contains('dav.example')));
    expect(joined, isNot(contains('bluray-device')));
    expect(joined, isNot(contains('load-unsafe')));
    expect(joined, isNot(contains('\u0000')));
  });

  test('单任务互斥，取消会终止当前 Bridge 准备', () async {
    final provider = _BlockingIsoAccessProvider();
    final service = IsoPlaybackService(
      configStore: configStore,
      accessProvider: provider,
      configLoader: () async =>
          const PlayerConfig(name: 'MPV', executable: r'C:\Tools\mpv.exe'),
      ownerIdentityLoader: () async => ownerIdentity,
      tempRootProvider: () async => Directory(tempDirectory.path),
    );
    final first = service.start(webDavService: webDavService, file: isoFile);
    await provider.entered.future;
    final session = await tempDirectory
        .list()
        .where((entity) => entity is Directory)
        .cast<Directory>()
        .single;
    final manifest =
        jsonDecode(
              await File(
                p.join(session.path, IsoPlaybackService.manifestFileName),
              ).readAsString(),
            )
            as Map<String, dynamic>;

    expect(manifest['state'], 'bridge-starting');
    expect(manifest['ownerPid'], ownerIdentity.pid);
    expect(manifest['ownerExecutablePath'], ownerIdentity.executablePath);
    expect(manifest['ownerCreationTime'], ownerIdentity.creationTime);
    expect(manifest['helperPid'], _helperIdentity.pid);
    expect(manifest['helperExecutablePath'], _helperIdentity.executablePath);
    expect(manifest['helperCreationTime'], _helperIdentity.creationTime);

    await expectLater(
      service.start(webDavService: webDavService, file: isoFile),
      throwsA(isA<PlayerLaunchException>()),
    );
    service.cancel();

    expect(await first, isNull);
    expect(provider.cancelCalled, isTrue);
    expect(service.isBusy, isFalse);
    service.dispose();
  });

  test('Bridge 未知启动异常转换为统一错误并清理会话', () async {
    final service = buildService(_FailingIsoAccessProvider());

    await expectLater(
      service.start(webDavService: webDavService, file: isoFile),
      throwsA(
        isA<PlayerLaunchException>()
            .having((error) => error.message, 'message', 'ISO Bridge 启动失败')
            .having((error) => error.cause, 'cause', isA<StateError>()),
      ),
    );

    final root = Directory(
      p.join(tempDirectory.path, IsoPlaybackService.tempDirectoryName),
    );
    expect(service.isBusy, isFalse);
    expect(await root.list().isEmpty, isTrue);
    service.dispose();
  });

  test('启动写入脱敏 v2 双进程清单，播放列表只含 loopback URI', () async {
    final provider = _FakeIsoAccessProvider();
    final service = buildService(provider);

    final launch = await service.start(
      webDavService: webDavService,
      file: isoFile,
      selectTitles: (request) async => IsoTitleSelection(
        orderedTitles: [request.titles[1], request.titles[0]],
        selectedMplsIds: {'00001', '00002'},
      ),
    );
    final session = Directory(launch!.sessionDirectoryPath);
    final playlist = await File(
      p.join(session.path, 'iso-playlist.m3u8'),
    ).readAsString();
    final manifest = await File(
      p.join(session.path, IsoPlaybackService.manifestFileName),
    ).readAsString();
    final manifestJson = jsonDecode(manifest) as Map<String, dynamic>;

    expect(provider.handle!.attachedPid, playerIdentity.pid);
    expect(playlist, contains('http://127.0.0.1:49152/'));
    expect(
      playlist.indexOf('00002.m2ts'),
      lessThan(playlist.indexOf('00001.m2ts')),
    );
    expect(await File(p.join(session.path, 'disc.iso')).exists(), isFalse);
    expect(manifestJson['version'], 2);
    expect(manifestJson['transport'], 'loopback-http');
    expect(manifestJson['playerPid'], playerIdentity.pid);
    expect(manifestJson['helperPid'], _helperIdentity.pid);
    expect(manifest, isNot(contains('dav.example')));
    expect(manifest, isNot(contains('secret')));
    expect(manifest, isNot(contains('49152')));
    expect(manifest, isNot(contains('0123456789abcdef')));
    expect(
      provider.structureCachePath,
      p.join(
        tempDirectory.path,
        IsoPlaybackService.structureCacheDirectoryName,
        '${launch.isoKey}.cache',
      ),
    );
    expect(provider.structureCachePath, isNot(contains('secret')));

    alive.updateAll((_, _) => false);
    expect(await service.hasActivePlayback(), isFalse);
    expect(await session.exists(), isFalse);
    service.dispose();
  });

  test('Structure Cache 路径忽略签名参数并按 profile 隔离', () async {
    WebDAVService serviceFor(String profileId) => WebDAVService(
      client: WebDavClient(baseUrl: 'https://dav.example'),
      profileId: profileId,
    );

    const firstFile = WebDavFile(
      name: 'DISC.iso',
      href: 'https://dav.example/media/DISC.iso?signature=one',
      isDirectory: false,
      size: 3,
    );
    const secondFile = WebDavFile(
      name: 'DISC.iso',
      href: 'https://dav.example/media/DISC.iso?signature=two',
      isDirectory: false,
      size: 3,
    );
    final firstProvider = _FakeIsoAccessProvider();
    final secondProvider = _FakeIsoAccessProvider();
    final otherProfileProvider = _FakeIsoAccessProvider();
    final firstService = buildService(firstProvider);
    final secondService = buildService(secondProvider);
    final otherProfileService = buildService(otherProfileProvider);

    final first = await firstService.start(
      webDavService: serviceFor('profile-a'),
      file: firstFile,
    );
    final second = await secondService.start(
      webDavService: serviceFor('profile-a'),
      file: secondFile,
    );
    final otherProfile = await otherProfileService.start(
      webDavService: serviceFor('profile-b'),
      file: firstFile,
    );

    expect(second!.isoKey, first!.isoKey);
    expect(secondProvider.structureCachePath, firstProvider.structureCachePath);
    expect(otherProfile!.isoKey, isNot(first.isoKey));
    expect(
      otherProfileProvider.structureCachePath,
      isNot(firstProvider.structureCachePath),
    );
    for (final path in [
      firstProvider.structureCachePath!,
      secondProvider.structureCachePath!,
      otherProfileProvider.structureCachePath!,
    ]) {
      expect(
        p.basenameWithoutExtension(path),
        matches(RegExp(r'^[0-9a-f]{64}$')),
      );
      expect(p.basename(p.dirname(path)), 'iso_structure');
      expect(path, isNot(contains('signature')));
    }

    alive.updateAll((_, _) => false);
    await firstService.hasActivePlayback();
    await secondService.hasActivePlayback();
    await otherProfileService.hasActivePlayback();
    firstService.dispose();
    secondService.dispose();
    otherProfileService.dispose();
  });

  test('Lua 注入章节与独立续播，退出后恢复 MPLS 进度', () async {
    final firstService = buildService(_FakeIsoAccessProvider());
    final firstLaunch = await firstService.start(
      webDavService: webDavService,
      file: isoFile,
    );
    final firstSession = Directory(firstLaunch!.sessionDirectoryPath);
    final script = await File(
      p.join(firstSession.path, 'iso-progress.lua'),
    ).readAsString();
    expect(script, contains('chapter-list'));
    expect(script, contains('absolute+exact'));
    expect(script, contains('resume_pending'));
    expect(script, contains('resume_inflight'));
    expect(script, contains('resume_seek_issued'));
    expect(script, contains('resume_restart_floor'));
    expect(script, contains('resume_restart_seen'));
    expect(script, contains('restart_serial > resume_restart_floor'));
    expect(script, contains('math.abs(position - resume_target) > 2.0'));
    expect(
      script.indexOf('resume_seek_issued = true'),
      lessThan(script.indexOf('mp.commandv("seek", target, "absolute+exact")')),
    );
    expect(script, contains('mp.register_event("playback-restart"'));
    expect(script, contains('iso-performance-events.jsonl'));
    expect(script, contains('append_performance_event("seek-start")'));
    expect(script, contains('not was_seeking and not resume_inflight'));
    expect(script, contains('append_performance_event("stable-playback")'));
    expect(script, contains('append_performance_event("cache-pause-start")'));
    expect(script, contains('append_performance_event("cache-pause-end")'));
    expect(script, contains('record["position"] = event_position'));
    expect(
      script,
      contains(
        'reason == "eof" and position >= 0 and duration > 0 and\n'
        '        position / duration >= 0.99',
      ),
    );
    expect(script, contains('completed and "title-eof" or "end-file"'));
    expect(script, contains('completed and "completed" or "position"'));
    expect(script, contains('mp.get_time()'));
    expect('absolute+exact'.allMatches(script), hasLength(1));
    expect(script, contains('mp.commandv("stop")'));
    expect(script, contains('event["error"] or event["file_error"]'));
    expect(script, contains('record["end_reason"]'));
    expect(script, contains('record["file_error_category"]'));
    expect(script, contains('append_performance_event("shutdown")'));
    expect(script, contains('iso-bridge|-1|'));
    expect(script, contains('|resume|'));
    expect(script, contains(IsoPlaybackService.statusFileName));
    expect(script, contains(IsoPlaybackService.commandFileName));
    expect(firstLaunch.playerIdentity.matches(playerIdentity), isTrue);
    expect(firstLaunch.isoKey, isNotEmpty);
    await File(
      p.join(firstSession.path, IsoPlaybackService.statusFileName),
    ).writeAsString(
      '1\nhttp://127.0.0.1/title/00002.m2ts\n1\n125.5\n1380.0\n'
      '100\n-1\n0\niso-bridge|-1|cache-idle|no\n0\n0\n0\n'
      '1920x1080\n0\n2\n30.0\n',
      flush: true,
    );
    final snapshot = await firstService.sessionSnapshot(firstSession.path);
    expect(snapshot.liveness, PlayerProcessLiveness.alive);
    expect(snapshot.paused, isTrue);
    final activeProgress = await firstService.getLibraryProgressByKey(
      firstLaunch.isoKey,
    );
    expect(activeProgress!.episodeNumber, 2);
    expect(activeProgress.episodeCount, 2);
    expect(activeProgress.position, const Duration(milliseconds: 125500));
    await firstService.sendResume(firstSession.path);
    expect(
      await File(
        p.join(firstSession.path, IsoPlaybackService.commandFileName),
      ).readAsString(),
      'resume',
    );
    await File(p.join(firstSession.path, 'iso-progress.jsonl')).writeAsString(
      '${jsonEncode({'outcome': 'position', 'playlist_pos': 1, 'path': 'http://127.0.0.1/token', 'position': 123.5, 'duration': 1380.0})}\n',
      flush: true,
    );
    alive.updateAll((_, _) => false);
    expect(await firstService.hasActivePlayback(), isFalse);
    final persistedProgress = await firstService.getLibraryProgressByKey(
      firstLaunch.isoKey,
    );
    expect(persistedProgress!.episodeNumber, 2);
    expect(persistedProgress.position, const Duration(milliseconds: 123500));
    firstService.dispose();

    alive.updateAll((_, _) => true);
    final interruptedService = buildService(_FakeIsoAccessProvider());
    final interruptedLaunch = await interruptedService.start(
      webDavService: webDavService,
      file: isoFile,
    );
    final interruptedSession = Directory(
      interruptedLaunch!.sessionDirectoryPath,
    );
    await File(
      p.join(interruptedSession.path, 'iso-progress.jsonl'),
    ).writeAsString(
      '${jsonEncode({'outcome': 'position', 'playlist_pos': 1, 'path': 'http://127.0.0.1/truncated'})}\n',
      flush: true,
    );
    alive.updateAll((_, _) => false);
    expect(await interruptedService.hasActivePlayback(), isFalse);
    interruptedService.dispose();

    alive.updateAll((_, _) => true);
    IsoTitleSelectionRequest? request;
    final secondService = buildService(_FakeIsoAccessProvider());
    final result = await secondService.start(
      webDavService: webDavService,
      file: isoFile,
      selectTitles: (value) async {
        request = value;
        return null;
      },
    );
    expect(result, isNull);
    expect(request!.lastMplsId, '00002');
    expect(
      request!.resumeByMplsId['00002']!.position,
      const Duration(milliseconds: 123500),
    );
    secondService.dispose();
  });

  test('提前 EOF 作为明确终止错误上报', () async {
    alive.updateAll((_, _) => true);
    final service = buildService(_FakeIsoAccessProvider());
    final launch = await service.start(
      webDavService: webDavService,
      file: isoFile,
    );
    final session = Directory(launch!.sessionDirectoryPath);
    await File(p.join(session.path, 'iso-progress.jsonl')).writeAsString(
      '${jsonEncode({'outcome': 'position', 'playlist_pos': 0, 'path': 'http://127.0.0.1/truncated', 'position': 10.0, 'duration': 100.0, 'reason': 'eof'})}\n',
      flush: true,
    );
    alive.updateAll((_, _) => false);
    expect(await service.hasActivePlayback(), isFalse);
    expect(
      (await service.sessionSnapshot(session.path)).failureMessage,
      'ISO 播放流提前结束',
    );
    service.dispose();
  });

  test('并发探活必须等待同一 ISO 会话完成收尾', () async {
    final cleanupEntered = Completer<void>();
    final allowCleanup = Completer<void>();
    final provider = _FakeIsoAccessProvider(
      handleFactory: (sessionDirectory) => _FakeIsoHandle(
        sessionDirectory,
        beforeCleanup: () async {
          if (!cleanupEntered.isCompleted) cleanupEntered.complete();
          await allowCleanup.future;
        },
      ),
    );
    final playerExited = Completer<PlayerProcessLookupResult>();
    final helperProbeStarted = Completer<void>();
    final helperExited = Completer<PlayerProcessLookupResult>();
    var playerLookups = 0;
    final raceController = PlayerProcessController(
      snapshotLoader: (pid) {
        if (pid == playerIdentity.pid) {
          playerLookups++;
          if (playerLookups == 1) {
            return Future.value(
              PlayerProcessLookupResult.found(playerIdentity),
            );
          }
          return playerExited.future;
        }
        if (pid == _helperIdentity.pid) {
          if (!helperProbeStarted.isCompleted) helperProbeStarted.complete();
          return helperExited.future;
        }
        if (pid == ownerIdentity.pid) {
          return Future.value(PlayerProcessLookupResult.found(ownerIdentity));
        }
        return Future.value(const PlayerProcessLookupResult.notFound());
      },
    );
    final service = IsoPlaybackService(
      configStore: configStore,
      accessProvider: provider,
      processController: raceController,
      configLoader: () async =>
          const PlayerConfig(name: 'MPV', executable: r'C:\Tools\mpv.exe'),
      processStarter: (_, _) async => playerIdentity.pid,
      ownerIdentityLoader: () async => ownerIdentity,
      tempRootProvider: () async => Directory(
        p.join(tempDirectory.path, IsoPlaybackService.tempDirectoryName),
      ),
    );

    final launch = await service.start(
      webDavService: webDavService,
      file: isoFile,
    );
    expect(launch, isNotNull);
    playerExited.complete(const PlayerProcessLookupResult.notFound());
    await helperProbeStarted.future;

    var probeCompleted = false;
    final activeProbe = service.hasActivePlayback().then((value) {
      probeCompleted = true;
      return value;
    });
    helperExited.complete(const PlayerProcessLookupResult.notFound());
    await cleanupEntered.future;
    await Future<void>.delayed(Duration.zero);
    final completedBeforeCleanup = probeCompleted;
    allowCleanup.complete();

    expect(await activeProbe, isFalse);
    expect(completedBeforeCleanup, isFalse, reason: '并发调用必须复用并等待正在执行的会话收尾任务');
    service.dispose();
  });

  test('性能快照归档匿名指标并计算 Seek 与切集耗时', () async {
    final service = buildService(_FakeIsoAccessProvider());
    final launch = await service.start(
      webDavService: webDavService,
      file: isoFile,
    );
    final session = Directory(launch!.sessionDirectoryPath);
    await File(p.join(session.path, 'iso-bridge-metrics.json')).writeAsString(
      jsonEncode({
        'version': 2,
        'network': {
          'remoteBodyBytes': 1000,
          'responseBodyActiveUsTotal': 100,
          'requestContextCreatedCount': 20,
          'requestContextClosedCount': 20,
          'requestContextLive': 0,
          'requestContextPeak': 2,
        },
        'cache': {'consumerBytesDelivered': 900},
        'bluray': {
          'titleEnumerationUs': 50,
          'mediaFailureCount': 1,
          'lastMediaFailureSequence': 12,
          'lastMediaFailureGeneration': 4,
          'lastMediaFailureStatusCategory': 'transport_or_bridge',
          'terminalRejectedMediaGetCount': 1,
        },
        'bridge': {
          'firstMediaResponseReadyUs': 25,
          'final': true,
          'timeSeekRedirectEnabled': false,
          'demandBlockBytes': 262144,
        },
        'remoteTransferActiveMicroseconds': 125,
        'lastErrorCode': 'network_error',
      }),
      flush: true,
    );
    final events = <Map<String, Object>>[
      {
        'event': 'stable-playback',
        'time': 1.0,
        'playlist_pos': 0,
        'restart_serial': 1,
      },
      {
        'event': 'seek-start',
        'time': 2.0,
        'playlist_pos': 0,
        'restart_serial': 1,
        'position': 70.0,
      },
      {
        'event': 'stable-playback',
        'time': 2.5,
        'playlist_pos': 0,
        'restart_serial': 2,
        'position': 70.1,
      },
      {
        'event': 'cache-pause-start',
        'time': 2.6,
        'playlist_pos': 0,
        'restart_serial': 2,
        'position': 70.2,
      },
      {
        'event': 'cache-pause-end',
        'time': 2.9,
        'playlist_pos': 0,
        'restart_serial': 2,
        'position': 70.3,
      },
      {
        'event': 'title-eof',
        'time': 3.0,
        'playlist_pos': 0,
        'restart_serial': 2,
      },
      {
        'event': 'stable-playback',
        'time': 4.25,
        'playlist_pos': 1,
        'restart_serial': 1,
      },
      {
        'event': 'end-file',
        'time': 5.0,
        'playlist_pos': 1,
        'restart_serial': 1,
      },
      {
        'event': 'start-file',
        'time': 5.1,
        'playlist_pos': 2,
        'restart_serial': 0,
      },
      {
        'event': 'end-file',
        'time': 5.5,
        'playlist_pos': 2,
        'restart_serial': 0,
        'end_reason': 'eof',
        'position': 10.0,
        'duration': 100.0,
        'file_error_category': 'other',
      },
      {
        'event': 'shutdown',
        'time': 5.6,
        'playlist_pos': 2,
        'restart_serial': 0,
      },
    ];
    await File(
      p.join(session.path, IsoPlaybackService.performanceEventsFileName),
    ).writeAsString('${events.map(jsonEncode).join('\n')}\n', flush: true);

    alive.updateAll((_, _) => false);
    expect(await service.hasActivePlayback(), isFalse);

    final archive = Directory(
      p.join(
        tempDirectory.path,
        IsoPlaybackService.performanceArchiveDirectoryName,
        p.basename(session.path),
      ),
    );
    final summaryText = await File(
      p.join(archive.path, IsoPlaybackService.performanceSummaryFileName),
    ).readAsString();
    final summary = jsonDecode(summaryText) as Map<String, dynamic>;
    final timings = summary['timings'] as Map<String, dynamic>;
    expect(summary['status'], 'complete');
    expect(timings['openToProbeMs'], isA<int>());
    expect(timings['probeToTitlesMs'], isA<int>());
    expect(timings['selectionToLoopbackReadyMs'], isA<int>());
    expect(timings['selectionToStablePlaybackMs'], isA<int>());
    expect(timings['mpvLaunchToStablePlaybackMs'], isA<int>());
    expect(summary['seekRecoveryMs'], [500]);
    expect(summary['seekSamples'], [
      {
        'playlist': '00001',
        'startPositionMs': 70000,
        'endPositionMs': 70100,
        'recoveryMs': 500,
      },
    ]);
    expect(summary['titleSwitchGapMs'], [1250]);
    expect(summary['pausedForCacheCount'], 1);
    expect(summary['pausedForCacheDurationMs'], 300);
    expect(summary['rapidEndFileCascadeCount'], 1);
    expect(summary['terminalClassification'], 'premature_eof');
    expect(summary['terminalEndReason'], 'eof');
    expect(summary['terminalPositionMs'], 10000);
    expect(summary['terminalDurationMs'], 100000);
    expect(summary['terminalPlaylistPos'], 2);
    expect(summary['terminalFileErrorCategory'], 'other');
    expect(summary['shutdownObserved'], isTrue);
    expect(await session.exists(), isFalse);
    final failureSnapshot = await service.sessionSnapshot(session.path);
    expect(failureSnapshot.liveness, PlayerProcessLiveness.exited);
    expect(failureSnapshot.failureMessage, 'ISO Bridge 远端读取失败');
    expect(
      (await service.sessionSnapshot(session.path)).failureMessage,
      isNull,
      reason: '终态错误只向界面消费一次',
    );
    expect(summaryText, isNot(contains('dav.example')));
    expect(summaryText, isNot(contains('secret')));
    expect(summaryText, isNot(contains('DISC.iso')));
    service.dispose();
  });

  test('重启遇到 v2 任一身份未知时保留会话并失败关闭', () async {
    final root = Directory(
      p.join(tempDirectory.path, IsoPlaybackService.tempDirectoryName),
    );
    final session = Directory(p.join(root.path, 'iso_unknown'));
    await session.create(recursive: true);
    await File(
      p.join(session.path, IsoPlaybackService.manifestFileName),
    ).writeAsString(
      jsonEncode({
        'version': 2,
        'transport': 'loopback-http',
        'state': 'playing',
        'playerPid': playerIdentity.pid,
        'playerExecutablePath': playerIdentity.executablePath,
        'playerCreationTime': playerIdentity.creationTime,
      }),
    );
    final service = IsoPlaybackService(
      configStore: configStore,
      processController: processController,
      tempRootProvider: () async => root,
    );

    await service.initialize();

    expect(service.isBusy, isTrue);
    expect(await service.hasActivePlayback(), isTrue);
    expect(await session.exists(), isTrue);
    service.dispose();
  });

  for (final transport in ['loopback-http', 'winfsp']) {
    test('重启时确认启动会话 owner 已退出后终止精确 helper 并清理残留 ($transport)', () async {
      final root = Directory(
        p.join(tempDirectory.path, IsoPlaybackService.tempDirectoryName),
      );
      final session = Directory(p.join(root.path, 'iso_bridge_starting'));
      await session.create(recursive: true);
      await File(
        p.join(session.path, IsoPlaybackService.manifestFileName),
      ).writeAsString(
        jsonEncode({
          'version': 2,
          'transport': transport,
          'state': 'bridge-starting',
          'ownerPid': ownerIdentity.pid,
          'ownerExecutablePath': ownerIdentity.executablePath,
          'ownerCreationTime': ownerIdentity.creationTime,
          'helperPid': _helperIdentity.pid,
          'helperExecutablePath': _helperIdentity.executablePath,
          'helperCreationTime': _helperIdentity.creationTime,
        }),
      );
      alive[ownerIdentity.pid] = false;
      final service = IsoPlaybackService(
        configStore: configStore,
        processController: processController,
        tempRootProvider: () async => root,
      );

      await service.initialize();

      expect(alive[_helperIdentity.pid], isFalse);
      expect(service.isBusy, isFalse);
      expect(await service.hasActivePlayback(), isFalse);
      expect(await session.exists(), isFalse);
      service.dispose();
    });
  }

  test('重启时 owner 已退出且 helper 尚未启动则清理空会话', () async {
    final root = Directory(
      p.join(tempDirectory.path, IsoPlaybackService.tempDirectoryName),
    );
    final session = Directory(p.join(root.path, 'iso_before_helper'));
    await session.create(recursive: true);
    await File(
      p.join(session.path, IsoPlaybackService.manifestFileName),
    ).writeAsString(
      jsonEncode({
        'version': 2,
        'transport': 'loopback-http',
        'state': 'bridge-starting',
        'ownerPid': ownerIdentity.pid,
        'ownerExecutablePath': ownerIdentity.executablePath,
        'ownerCreationTime': ownerIdentity.creationTime,
      }),
    );
    alive[ownerIdentity.pid] = false;
    final service = IsoPlaybackService(
      configStore: configStore,
      processController: processController,
      tempRootProvider: () async => root,
    );

    await service.initialize();

    expect(service.isBusy, isFalse);
    expect(await session.exists(), isFalse);
    service.dispose();
  });

  test('重启时启动会话 owner 仍存活则保留残留并阻止并发播放', () async {
    final root = Directory(
      p.join(tempDirectory.path, IsoPlaybackService.tempDirectoryName),
    );
    final session = Directory(p.join(root.path, 'iso_owner_alive'));
    await session.create(recursive: true);
    await File(
      p.join(session.path, IsoPlaybackService.manifestFileName),
    ).writeAsString(
      jsonEncode({
        'version': 2,
        'transport': 'loopback-http',
        'state': 'launching',
        'ownerPid': ownerIdentity.pid,
        'ownerExecutablePath': ownerIdentity.executablePath,
        'ownerCreationTime': ownerIdentity.creationTime,
        'helperPid': _helperIdentity.pid,
        'helperExecutablePath': _helperIdentity.executablePath,
        'helperCreationTime': _helperIdentity.creationTime,
      }),
    );
    final service = IsoPlaybackService(
      configStore: configStore,
      processController: processController,
      tempRootProvider: () async => root,
    );

    await service.initialize();

    expect(alive[_helperIdentity.pid], isTrue);
    expect(service.isBusy, isTrue);
    expect(await service.hasActivePlayback(), isTrue);
    expect(await session.exists(), isTrue);
    service.dispose();
  });

  test('旧 v1 活动下载会话仅作安全恢复并在播放器退出后清理', () async {
    final root = Directory(
      p.join(tempDirectory.path, IsoPlaybackService.tempDirectoryName),
    );
    final session = Directory(p.join(root.path, 'iso_legacy'));
    await session.create(recursive: true);
    await File(p.join(session.path, 'disc.iso')).writeAsBytes(const [1]);
    await File(
      p.join(session.path, IsoPlaybackService.manifestFileName),
    ).writeAsString(
      jsonEncode({
        'version': 1,
        'state': 'playing',
        'pid': playerIdentity.pid,
        'executablePath': playerIdentity.executablePath,
        'creationTime': playerIdentity.creationTime,
      }),
    );
    alive[_helperIdentity.pid] = false;
    final service = IsoPlaybackService(
      configStore: configStore,
      processController: processController,
      tempRootProvider: () async => root,
    );
    await service.initialize();
    expect(service.isBusy, isTrue);

    alive[playerIdentity.pid] = false;
    expect(await service.hasActivePlayback(), isFalse);
    expect(await session.exists(), isFalse);
    service.dispose();
  });
}
