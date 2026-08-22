import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/audio_media_entry.dart';
import 'package:streampath/data/models/connection_config.dart';
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/domain/services/audio_player_service.dart';
import 'package:streampath/domain/services/mpv_watch_later_sync.dart';
import 'package:streampath/domain/services/player_process_controller.dart';

class _SharedAudioProbeController extends PlayerProcessController {
  final probeStarted = Completer<void>();
  final releaseProbe = Completer<PlayerProcessLiveness>();
  int probeCalls = 0;
  int terminateCalls = 0;

  @override
  Future<PlayerProcessIdentity?> capture(int pid) async =>
      PlayerProcessIdentity(
        pid: pid,
        executablePath: r'C:\TestMPV\mpv.exe',
        creationTime: pid + 9100,
      );

  @override
  Future<PlayerProcessLiveness> probeOwned(PlayerProcessIdentity? expected) {
    probeCalls++;
    if (!probeStarted.isCompleted) probeStarted.complete();
    return releaseProbe.future;
  }

  @override
  Future<PlayerTerminationOutcome> terminateIfOwned({
    required int pid,
    required PlayerProcessIdentity? expected,
    String? ipcPipeName,
    required bool requirePipeOwner,
  }) async {
    terminateCalls++;
    return PlayerTerminationOutcome.terminated;
  }
}

void main() {
  Future<(AudioPlayerService, Directory, PlaybackProgressService)>
  makeEpochService({
    String? executablePath,
    PlayerProcessTreeTerminator? processTreeTerminator,
    PlayerProcessController? processController,
  }) async {
    sqfliteFfiInit();
    final directory = Directory.systemTemp.createTempSync('audio_epoch_');
    final executable = executablePath == null
        ? File('${directory.path}${Platform.pathSeparator}mpv-audio-epoch.exe')
        : File(executablePath);
    if (executablePath == null) {
      await File(r'C:\Windows\System32\where.exe').copy(executable.path);
    }
    final store = StreamPathConfigStore.forPath(
      '${directory.path}${Platform.pathSeparator}config.json',
    );
    await store.save(
      StreamPathConfig.fromParts(
        PlayerConfig(
          name: 'mpv',
          executable: executable.path,
          args: const ['{url}'],
        ),
        const ConnectionConfig(baseUrl: 'http://h/dav'),
      ),
    );
    final progress = await PlaybackProgressService.open(
      '${directory.path}${Platform.pathSeparator}audio.db',
      factory: databaseFactoryFfi,
      legacyProfileId: store.current.profileId,
    );
    var currentPid = 0;
    final service = AudioPlayerService(
      configStore: store,
      progressService: progress,
      watchLaterDirectory: Directory(
        '${directory.path}${Platform.pathSeparator}watch_later',
      ),
      processController:
          processController ??
          PlayerProcessController(
            snapshotLoader: (pid) async {
              currentPid = pid;
              return PlayerProcessLookupResult.found(
                PlayerProcessIdentity(
                  pid: pid,
                  executablePath: r'C:\TestMPV\mpv.exe',
                  creationTime: pid + 2000,
                ),
              );
            },
            pipeServerPidLoader: (_) async => currentPid,
            processTreeTerminator: processTreeTerminator ?? (_) async => true,
          ),
    );
    return (service, directory, progress);
  }

  test('音频 runtime 的 watcher 与 isPlayerRunning 共享同一探活查询', () async {
    final controller = _SharedAudioProbeController();
    final (service, directory, progress) = await makeEpochService(
      processController: controller,
    );
    addTearDown(() async {
      if (!controller.releaseProbe.isCompleted) {
        controller.releaseProbe.complete(PlayerProcessLiveness.exited);
      }
      await service.terminateSession('shared-audio-liveness');
      await progress.close();
      try {
        await directory.delete(recursive: true);
      } catch (_) {}
    });

    await service.launch(
      entries: const [
        AudioMediaEntry(url: 'http://h/dav/01.flac', title: '第一首'),
      ],
      sessionId: 'shared-audio-liveness',
    );
    await controller.probeStarted.future;

    final running = service.isPlayerRunning('shared-audio-liveness');
    await Future<void>.delayed(Duration.zero);
    expect(controller.probeCalls, 1);

    controller.releaseProbe.complete(PlayerProcessLiveness.alive);
    expect(await running, isTrue);
    expect(
      await service.terminateSession('shared-audio-liveness'),
      PlayerTerminationOutcome.terminated,
    );
    expect(controller.terminateCalls, 1);
  });

  test('缓存参数过滤覆盖应用缓存控制使用的 MPV 参数族', () {
    final filtered = AudioPlayerService.filterCacheArgs(const [
      '--profile=gpu --cache=yes --cache-secs=300',
      '--demuxer-max-bytes=1G',
      '--demuxer-max-back-bytes=100M',
      '--demuxer-seekable-cache=yes',
      '--cache-pause-wait=10',
      '--stream-buffer-size=4M',
      '--cache yes --cache-secs 90 --volume=60',
      '--demuxer-max-bytes 500M',
      '--demuxer-readahead-secs=45',
      '--demuxer-readahead-bytes 32M',
      '--demuxer-readahead-packets=yes',
      '--volume=70',
    ]);

    expect(filtered, ['--profile=gpu', '--volume=60', '--volume=70']);
  });

  test('同一音频 sessionId 重启时所有工件使用新 epoch', () async {
    final (service, directory, progress) = await makeEpochService();
    addTearDown(() async {
      await service.terminateSession('audio-stable');
      await progress.close();
      try {
        await directory.delete(recursive: true);
      } catch (_) {}
    });
    const entries = [
      AudioMediaEntry(url: 'http://h/dav/01.flac', title: '第一首'),
    ];

    final first = await service.launch(
      entries: entries,
      sessionId: 'audio-stable',
    );
    expect(
      await service.terminateSession('audio-stable'),
      PlayerTerminationOutcome.terminated,
    );
    await File(first.statusFilePath).writeAsString('0\nold-url\n1\n');
    await File(first.commandFilePath).writeAsString('pause');
    await File(
      first.progressFilePath,
    ).writeAsString('{"outcome":"position","reason":"error"}\n');

    final second = await service.launch(
      entries: entries,
      sessionId: 'audio-stable',
    );

    expect(second.statusFilePath, isNot(first.statusFilePath));
    expect(second.commandFilePath, isNot(first.commandFilePath));
    expect(second.progressFilePath, isNot(first.progressFilePath));
    expect(second.playlistFilePath, isNot(first.playlistFilePath));
    expect(await File(first.commandFilePath).readAsString(), 'pause');
  });

  test('Process.start 失败后清理本次已生成的音频工件', () async {
    final missing =
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'missing-audio-mpv-${DateTime.now().microsecondsSinceEpoch}.exe';
    final (service, directory, progress) = await makeEpochService(
      executablePath: missing,
    );
    addTearDown(() async {
      await progress.close();
      try {
        await directory.delete(recursive: true);
      } catch (_) {}
    });

    await expectLater(
      service.launch(
        entries: const [
          AudioMediaEntry(url: 'http://h/dav/01.flac', title: '第一首'),
        ],
        sessionId: 'audio-failed',
      ),
      throwsA(isA<Exception>()),
    );

    final base = Directory(
      '${directory.path}${Platform.pathSeparator}watch_later',
    );
    final artifacts = base.existsSync()
        ? base
              .listSync()
              .whereType<File>()
              .where(
                (file) => file.uri.pathSegments.last.startsWith('streampath-'),
              )
              .toList()
        : const <File>[];
    expect(artifacts, isEmpty);
  });

  test('并发终止音频时保持 runtime 并合并为一次身份终止', () async {
    var terminateCalls = 0;
    final allowTermination = Completer<bool>();
    final (service, directory, progress) = await makeEpochService(
      processTreeTerminator: (_) async {
        terminateCalls++;
        return allowTermination.future;
      },
    );
    addTearDown(() async {
      if (!allowTermination.isCompleted) allowTermination.complete(true);
      await progress.close();
      try {
        await directory.delete(recursive: true);
      } catch (_) {}
    });
    await service.launch(
      entries: const [
        AudioMediaEntry(url: 'http://h/dav/01.flac', title: '第一首'),
      ],
      sessionId: 'audio-coalesced-termination',
    );

    final first = service.terminateSession('audio-coalesced-termination');
    final second = service.terminateSession('audio-coalesced-termination');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(terminateCalls, 1);
    allowTermination.complete(true);

    expect(await first, PlayerTerminationOutcome.terminated);
    expect(await second, PlayerTerminationOutcome.terminated);
    expect(terminateCalls, 1);
  });

  test('同 session 双音频启动在旧探活阻塞时由后进入请求保持所有权', () async {
    const legacyPid = 42001;
    final probeStarted = Completer<void>();
    final releaseProbe = Completer<PlayerProcessLookupResult>();
    final lookups = <int, int>{};
    var latestPid = legacyPid;
    final controller = PlayerProcessController(
      snapshotLoader: (pid) {
        final count = lookups.update(
          pid,
          (value) => value + 1,
          ifAbsent: () => 1,
        );
        if (pid == legacyPid && count == 1) {
          probeStarted.complete();
          return releaseProbe.future;
        }
        if (pid == legacyPid || count > 1) {
          return Future.value(const PlayerProcessLookupResult.notFound());
        }
        latestPid = pid;
        return Future.value(
          PlayerProcessLookupResult.found(
            PlayerProcessIdentity(
              pid: pid,
              executablePath: r'C:\TestMPV\mpv.exe',
              creationTime: pid + 8000,
            ),
          ),
        );
      },
      pipeServerPidLoader: (_) async => latestPid,
      processTreeTerminator: (_) async => true,
    );
    final (service, directory, progress) = await makeEpochService(
      processController: controller,
    );
    addTearDown(() async {
      if (!releaseProbe.isCompleted) {
        releaseProbe.complete(const PlayerProcessLookupResult.notFound());
      }
      await service.terminateSession('audio-launch-race');
      await progress.close();
      try {
        await directory.delete(recursive: true);
      } catch (_) {}
    });
    await service.restoreSession(
      sessionId: 'audio-launch-race',
      pid: legacyPid,
      executablePath: r'C:\TestMPV\legacy.exe',
      creationTime: 80001,
      ipcPipeName: r'\\.\pipe\legacy-audio-launch-race',
    );

    final stale = service.launch(
      entries: const [
        AudioMediaEntry(url: 'http://h/dav/old.flac', title: '旧曲目'),
      ],
      sessionId: 'audio-launch-race',
    );
    await probeStarted.future;
    final current = await service.launch(
      entries: const [
        AudioMediaEntry(url: 'http://h/dav/new.flac', title: '新曲目'),
      ],
      sessionId: 'audio-launch-race',
    );
    releaseProbe.complete(const PlayerProcessLookupResult.notFound());

    await expectLater(stale, throwsA(isA<Exception>()));
    expect(current.sessionId, 'audio-launch-race');
  });

  test('音频 launch 探活阻塞期间 terminate 会取消尚未注册的启动', () async {
    const legacyPid = 42002;
    final probeStarted = Completer<void>();
    final releaseProbe = Completer<PlayerProcessLookupResult>();
    var legacyLookups = 0;
    final controller = PlayerProcessController(
      snapshotLoader: (pid) {
        if (pid == legacyPid && legacyLookups++ == 0) {
          probeStarted.complete();
          return releaseProbe.future;
        }
        return Future.value(const PlayerProcessLookupResult.notFound());
      },
      pipeServerPidLoader: (_) async => null,
      processTreeTerminator: (_) async => true,
    );
    final (service, directory, progress) = await makeEpochService(
      processController: controller,
    );
    addTearDown(() async {
      if (!releaseProbe.isCompleted) {
        releaseProbe.complete(const PlayerProcessLookupResult.notFound());
      }
      await service.terminateSession('audio-terminate-during-launch');
      await progress.close();
      try {
        await directory.delete(recursive: true);
      } catch (_) {}
    });
    await service.restoreSession(
      sessionId: 'audio-terminate-during-launch',
      pid: legacyPid,
      executablePath: r'C:\TestMPV\legacy.exe',
      creationTime: 80002,
      ipcPipeName: r'\\.\pipe\legacy-audio-terminate-launch',
    );

    final pending = service.launch(
      entries: const [
        AudioMediaEntry(url: 'http://h/dav/new.flac', title: '新曲目'),
      ],
      sessionId: 'audio-terminate-during-launch',
    );
    await probeStarted.future;
    await service.terminateSession('audio-terminate-during-launch');
    releaseProbe.complete(const PlayerProcessLookupResult.notFound());

    await expectLater(pending, throwsA(isA<Exception>()));
  });

  test('音频启动生成 M3U8、LRC/封面脚本且最终参数没有缓存覆盖', () async {
    sqfliteFfiInit();
    final directory = Directory.systemTemp.createTempSync('audio_launch_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final executable = File(
      '${directory.path}${Platform.pathSeparator}mpv-audio-test.exe',
    );
    await File(r'C:\Windows\System32\where.exe').copy(executable.path);
    final store = StreamPathConfigStore.forPath(
      '${directory.path}${Platform.pathSeparator}config.json',
    );
    await store.save(
      StreamPathConfig.fromParts(
        PlayerConfig(
          name: 'mpv',
          executable: executable.path,
          args: const [
            '--cache=yes',
            '--cache-secs=500',
            '--demuxer-max-bytes=2G',
            '{url}',
          ],
          subtitleAutoSelectEnabled: false,
        ),
        const ConnectionConfig(baseUrl: 'http://h/dav'),
      ),
    );
    final progress = await PlaybackProgressService.open(
      '${directory.path}${Platform.pathSeparator}audio.db',
      factory: databaseFactoryFfi,
      legacyProfileId: store.current.profileId,
    );
    addTearDown(progress.close);
    var currentPid = 0;
    var terminateCalls = 0;
    final processController = PlayerProcessController(
      snapshotLoader: (pid) async {
        currentPid = pid;
        return PlayerProcessLookupResult.found(
          PlayerProcessIdentity(
            pid: pid,
            executablePath: r'C:\TestMPV\mpv.exe',
            creationTime: 133700000000000020,
          ),
        );
      },
      pipeServerPidLoader: (_) async => currentPid,
      processTreeTerminator: (_) async {
        terminateCalls++;
        return true;
      },
    );
    final service = AudioPlayerService(
      configStore: store,
      progressService: progress,
      watchLaterDirectory: Directory(
        '${directory.path}${Platform.pathSeparator}watch_later',
      ),
      processController: processController,
    );

    final result = await service.launch(
      sessionId: 'audio-one',
      playlistStart: 1,
      entries: const [
        AudioMediaEntry(url: 'http://h/dav/01.flac', title: '第一首'),
        AudioMediaEntry(
          url: 'http://h/dav/02.flac',
          title: '第二首',
          lyrics: AudioCompanionFile(
            name: '02.lrc',
            url: 'http://h/dav/02.lrc',
          ),
          coverArt: AudioCompanionFile(
            name: '02.jpg',
            url: 'http://h/dav/02.jpg',
          ),
        ),
      ],
      username: 'guest',
      password: '',
      lyricsLoader: (url, {required maxBytes, required timeout}) async =>
          '[00:00.00]第二首'.codeUnits,
    );

    expect(result.playlistFilePath, endsWith('.m3u8'));
    expect(result.args, contains('--playlist-start=1'));
    expect(result.args, contains('--audio-display=embedded-first'));
    expect(result.args, contains('--cover-art-auto=no'));
    expect(
      result.args.any(
        (argument) =>
            argument.toLowerCase().contains('--cache') ||
            argument.toLowerCase().contains('--demuxer-max') ||
            argument.toLowerCase().contains('--stream-buffer-size'),
      ),
      isFalse,
    );
    final m3u8 = await File(result.playlistFilePath).readAsString();
    expect(m3u8, contains('#EXTINF:-1,第二首'));
    expect(m3u8, contains('http://guest:@h/dav/02.flac'));
    final companionPath = result.args
        .where((arg) => arg.contains('audio-companions'))
        .single
        .substring('--script='.length);
    final companion = await File(companionPath).readAsString();
    expect(companion, isNot(contains('http://guest:@h/dav/02.lrc')));
    expect(
      companion,
      contains(
        'streampath-audio-lyrics-audio-one__e${result.launchEpoch}-1.lrc',
      ),
    );
    expect(companion, contains('http://guest:@h/dav/02.jpg'));
    expect(companion, contains('local LYRIC_MODE = "auto"'));
    expect(companion, contains('mp.set_property("sid", previous_sid)'));
    expect(result.processIdentity?.pid, result.process.pid);
    expect(result.processIdentity?.creationTime, 133700000000000020);
    final outcome = await service.terminateSession('audio-one');
    expect(outcome, PlayerTerminationOutcome.terminated);
    expect(terminateCalls, 1);
  });

  test('关闭字幕注入与续播时音频不加载 LRC 且封面仍然生效', () async {
    sqfliteFfiInit();
    final directory = Directory.systemTemp.createTempSync(
      'audio_settings_off_',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final executable = File(
      '${directory.path}${Platform.pathSeparator}mpv-audio-test.exe',
    );
    await File(r'C:\Windows\System32\where.exe').copy(executable.path);
    final store = StreamPathConfigStore.forPath(
      '${directory.path}${Platform.pathSeparator}config.json',
    );
    await store.save(
      StreamPathConfig.fromParts(
        PlayerConfig(
          name: 'mpv',
          executable: executable.path,
          args: const ['{url}'],
          subtitleInjectionEnabled: false,
          subtitleAutoSelectEnabled: false,
          resumeEnabled: false,
        ),
        const ConnectionConfig(baseUrl: 'http://h/dav'),
      ),
    );
    final progress = await PlaybackProgressService.open(
      '${directory.path}${Platform.pathSeparator}audio.db',
      factory: databaseFactoryFfi,
    );
    addTearDown(progress.close);
    final service = AudioPlayerService(
      configStore: store,
      progressService: progress,
      watchLaterDirectory: Directory(
        '${directory.path}${Platform.pathSeparator}watch_later',
      ),
    );

    final result = await service.launch(
      sessionId: 'audio-off',
      playlistStart: 0,
      resumeSeconds: 88,
      entries: const [
        AudioMediaEntry(
          url: 'http://h/dav/song.flac',
          title: '歌曲',
          lyrics: AudioCompanionFile(
            name: 'song.lrc',
            url: 'http://h/dav/song.lrc',
          ),
          coverArt: AudioCompanionFile(
            name: 'song.jpg',
            url: 'http://h/dav/song.jpg',
          ),
        ),
      ],
    );

    expect(result.args, isNot(contains('--sub-auto=no')));
    expect(result.args, isNot(contains('--save-position-on-quit')));
    expect(
      result.args.any(
        (argument) => argument.startsWith('--watch-later-directory='),
      ),
      isFalse,
    );
    expect(result.args, isNot(contains('--start=88')));
    final companionPath = result.args
        .where((arg) => arg.contains('audio-companions'))
        .single
        .substring('--script='.length);
    final companion = await File(companionPath).readAsString();
    expect(companion, isNot(contains('song.lrc')));
    expect(companion, isNot(contains('sub-add')));
    expect(companion, contains('song.jpg'));
    expect(companion, contains('video-add'));
    await service.waitForExitSync('audio-off');
  });

  test('旧音频持久会话只有 PID 和 pipe 时拒绝终止', () async {
    sqfliteFfiInit();
    final directory = Directory.systemTemp.createTempSync(
      'audio_legacy_process_',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final store = StreamPathConfigStore.forPath(
      '${directory.path}${Platform.pathSeparator}config.json',
    );
    final progress = await PlaybackProgressService.open(
      '${directory.path}${Platform.pathSeparator}audio.db',
      factory: databaseFactoryFfi,
    );
    addTearDown(progress.close);
    var terminateCalls = 0;
    final service = AudioPlayerService(
      configStore: store,
      progressService: progress,
      watchLaterDirectory: Directory(
        '${directory.path}${Platform.pathSeparator}watch_later',
      ),
      processController: PlayerProcessController(
        snapshotLoader: (pid) async => PlayerProcessLookupResult.found(
          PlayerProcessIdentity(
            pid: pid,
            executablePath: r'C:\TestMPV\mpv.exe',
            creationTime: 133700000000000021,
          ),
        ),
        pipeServerPidLoader: (_) async => 13131,
        processTreeTerminator: (_) async {
          terminateCalls++;
          return true;
        },
      ),
    );
    await service.restoreSession(
      sessionId: 'audio-legacy-process',
      pid: 13131,
      ipcPipeName: r'\\.\pipe\audio-legacy-process',
    );

    expect(await service.isPlayerRunning('audio-legacy-process'), isTrue);
    final outcome = await service.terminateSession('audio-legacy-process');

    expect(outcome, PlayerTerminationOutcome.refused);
    expect(terminateCalls, 0);
  });

  test('应用重启后可从遗留 JSONL 与 watch_later 恢复音频进度', () async {
    sqfliteFfiInit();
    final directory = Directory.systemTemp.createTempSync('audio_resume_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final store = StreamPathConfigStore.forPath(
      '${directory.path}${Platform.pathSeparator}config.json',
    );
    await store.save(
      StreamPathConfig.fromParts(
        PlayerConfig.defaultMpv(),
        const ConnectionConfig(baseUrl: 'http://h/dav'),
      ),
    );
    final progress = await PlaybackProgressService.open(
      '${directory.path}${Platform.pathSeparator}audio.db',
      factory: databaseFactoryFfi,
      legacyProfileId: store.current.profileId,
    );
    addTearDown(progress.close);
    final watchLater = Directory(
      '${directory.path}${Platform.pathSeparator}watch_later',
    )..createSync();
    final service = AudioPlayerService(
      configStore: store,
      progressService: progress,
      watchLaterDirectory: watchLater,
    );
    const url = 'http://h/dav/song.flac';
    await File(
      '${watchLater.path}${Platform.pathSeparator}'
      '${MpvWatchLaterSync.md5FileName(url)}',
    ).writeAsString('start=123.5\nduration=300\n');
    final journal = File(
      '${directory.path}${Platform.pathSeparator}progress.jsonl',
    );
    await journal.writeAsString(
      '{"outcome":"position","playlist_pos":0,'
      '"path":"$url","position":120,"duration":300}\n',
    );

    await service.syncPersistedProgress(
      sessionId: 'audio-resume',
      entries: const [AudioMediaEntry(url: url, title: 'Song')],
      journalFile: journal,
    );

    expect((await progress.getProgress(url))?.positionMs, 123500);
  });
}
