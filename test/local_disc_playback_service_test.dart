import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/domain/services/local_disc_playback_service.dart';

void main() {
  late PlaybackProgressService progressService;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    progressService = await PlaybackProgressService.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
  });

  tearDown(() => progressService.close());

  const config = PlayerConfig(
    name: 'mpv',
    executable: 'mpv',
    args: [
      '--profile=gpu-next',
      '--audio-spdif=ac3,dts',
      '--bluray-device=C:\\wrong.iso',
      '--input-ipc-server=wrong',
      '--idle=yes',
      '--keep-open=yes',
      '--script=C:\\user.lua',
      '--config-dir=C:\\mpv-config',
      'bd://7',
      '{url}',
    ],
  );

  test('菜单模式固定设备、入口、IPC 和退出语义', () {
    final args = LocalDiscPlaybackService.buildMpvArgs(
      config,
      devicePath: r'C:\Media\disc.iso',
      mode: LocalDiscLaunchMode.menu,
      ipcPipeName: r'\\.\pipe\controlled',
      progressScriptPath: r'C:\StreamPath\progress.lua',
      resumeSeconds: 125,
      resumeEdition: 1,
    );

    expect(args, contains('--profile=gpu-next'));
    expect(args, contains('--audio-spdif=ac3,dts'));
    expect(args, isNot(contains('--no-config')));
    expect(args, contains('--idle=no'));
    expect(args, contains('--keep-open=no'));
    expect(args, contains(r'--input-ipc-server=\\.\pipe\controlled'));
    expect(args, contains(r'--bluray-device=C:\Media\disc.iso'));
    expect(args, contains(r'--script=C:\StreamPath\progress.lua'));
    expect(args, contains('--start=125'));
    expect(args, contains('--edition=1'));
    expect(args.last, 'bd://menu');
    expect(
      args.where((arg) => arg.startsWith('--bluray-device=')),
      hasLength(1),
    );
    expect(
      args.where((arg) => arg.startsWith('--input-ipc-server=')),
      hasLength(1),
    );
    expect(args, isNot(contains('bd://7')));
    expect(args, contains(r'--script=C:\user.lua'));
    expect(args, contains(r'--config-dir=C:\mpv-config'));
    expect(args.any((arg) => arg.contains('{url}')), isFalse);
  });

  test('主标题模式使用独立的 bd longest 入口', () {
    final args = LocalDiscPlaybackService.buildMpvArgs(
      config,
      devicePath: r'C:\Media\BDMV',
      mode: LocalDiscLaunchMode.longestTitle,
      ipcPipeName: r'\\.\pipe\controlled',
    );

    expect(args.last, 'bd://longest');
    expect(args, isNot(contains('bd://menu')));
  });

  test('服务释放后拒绝启动新的本地蓝光会话', () async {
    final service = LocalDiscPlaybackService(
      configStore: StreamPathConfigStore.forPath('unused-config.json'),
      progressService: progressService,
    );
    service.dispose();

    await expectLater(
      service.launch(
        rootId: 'root',
        relativePath: 'disc.iso',
        devicePath: r'C:\disc.iso',
        mode: LocalDiscLaunchMode.menu,
      ),
      throwsA(isA<AppException>()),
    );
  });

  test('媒体中心可读取本地蓝光续播进度并忽略接近播完的记录', () async {
    final service = LocalDiscPlaybackService(
      configStore: StreamPathConfigStore.forPath('unused-config.json'),
      progressService: progressService,
    );
    addTearDown(service.dispose);
    const path = r'C:\Media\disc.iso';

    await progressService.saveProgress(
      url: path,
      positionMs: 125000,
      durationMs: 600000,
      profileId: 'local:root',
    );
    final progress = await service.getLibraryProgress(
      profileId: 'local:root',
      resolvedUrl: path,
    );

    expect(progress?.episodeNumber, 1);
    expect(progress?.episodeCount, 1);
    expect(progress?.position, const Duration(seconds: 125));

    await progressService.saveProgress(
      url: path,
      positionMs: 599000,
      durationMs: 600000,
      profileId: 'local:root',
    );
    expect(
      await service.getLibraryProgress(
        profileId: 'local:root',
        resolvedUrl: path,
      ),
      isNull,
    );
  });

  test('普通本地视频进度不会触发蓝光媒体中心刷新', () async {
    final service = LocalDiscPlaybackService(
      configStore: StreamPathConfigStore.forPath('unused-config.json'),
      progressService: progressService,
    );
    addTearDown(service.dispose);
    var notifications = 0;
    service.addLibraryProgressListener(() => notifications++);

    await progressService.saveProgress(
      url: r'C:\Media\video.mkv',
      positionMs: 26000,
      durationMs: 600000,
      profileId: 'local:root',
    );

    expect(notifications, 0);
    await progressService.clearAll();
    expect(notifications, 1);
  });

  test('显式 MPV 路径无效时在启动前返回配置错误', () {
    const invalid = PlayerConfig(
      name: 'mpv',
      executable: r'C:\missing\mpv.exe',
    );

    expect(
      LocalDiscPlaybackService.validateExecutable(invalid),
      contains('播放器文件不存在'),
    );
  });

  test('菜单模式只在离开初始片头或菜单后记录稳定 Title', () {
    expect(
      LocalDiscPlaybackService.isStableDiscTitle(
        mode: LocalDiscLaunchMode.menu,
        currentEdition: 0,
        initialEdition: 0,
        menuObserved: false,
        allowInitialEditionProgress: false,
      ),
      isFalse,
    );
    expect(
      LocalDiscPlaybackService.isStableDiscTitle(
        mode: LocalDiscLaunchMode.menu,
        currentEdition: 1,
        initialEdition: 0,
        menuObserved: false,
        allowInitialEditionProgress: false,
      ),
      isTrue,
    );
    expect(
      LocalDiscPlaybackService.isStableDiscTitle(
        mode: LocalDiscLaunchMode.menu,
        currentEdition: 0,
        initialEdition: 0,
        menuObserved: true,
        allowInitialEditionProgress: false,
      ),
      isTrue,
    );
  });

  test('本地蓝光内容被替换后旧快照失效', () async {
    final directory = await Directory.systemTemp.createTemp(
      'streampath_local_disc_snapshot_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final iso = File(p.join(directory.path, 'disc.iso'));
    await iso.writeAsBytes([1, 2, 3]);
    final stat = await iso.stat();
    final relativePath = 'disc.iso';
    final fingerprint = sha256
        .convert(
          utf8.encode(
            '$relativePath\n${stat.size}\n'
            '${stat.modified.millisecondsSinceEpoch}',
          ),
        )
        .toString();
    final snapshot = LocalDiscSessionSnapshot(
      rootId: 'root',
      relativePath: relativePath,
      size: stat.size,
      modified: stat.modified,
      fingerprint: fingerprint,
    );

    expect(
      await LocalDiscPlaybackService.matchesSnapshot(
        snapshot: snapshot,
        devicePath: iso.path,
      ),
      isTrue,
    );

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await iso.writeAsBytes([1, 2, 3, 4]);
    expect(
      await LocalDiscPlaybackService.matchesSnapshot(
        snapshot: snapshot,
        devicePath: iso.path,
      ),
      isFalse,
    );
  });
}
