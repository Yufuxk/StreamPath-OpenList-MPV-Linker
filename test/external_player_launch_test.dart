import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/core/utils/app_paths.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/connection_config.dart';
import 'package:streampath/data/models/media_entry.dart';
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/data/models/subtitle_item.dart';
import 'package:streampath/domain/services/external_player_service.dart';
import 'package:streampath/domain/services/mpv_watch_later_sync.dart';
import 'package:streampath/domain/services/player_process_controller.dart';
import 'package:streampath/domain/services/webdav_font_matcher.dart';

class _SharedProbeController extends PlayerProcessController {
  final probeStarted = Completer<void>();
  final releaseProbe = Completer<PlayerProcessLiveness>();
  int probeCalls = 0;
  int terminateCalls = 0;

  @override
  Future<PlayerProcessIdentity?> capture(int pid) async =>
      PlayerProcessIdentity(
        pid: pid,
        executablePath: r'C:\TestMPV\mpv.exe',
        creationTime: pid + 9000,
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

/// launch 集成测试：mpv 字幕注入脚本 + 多集续播（预写 watch_later）。
///
/// 背景（实测确认）：
/// - mpv 的 `--{ ... --}` per-file 作用域对全局选项（--sub-file/--start）
///   不生效，多集字幕改由 sub-add 脚本按 playlist-pos 注入；
/// - 多集续播改由预写首集 watch_later 文件（mpv 原生恢复）；
/// - 单集和多集字幕统一由 sub-add 脚本注入；
/// - 多集每次 `file-loaded` 都按当前 `playlist-pos` 注入对应集字幕；
/// - 自动注入开启时关闭 mpv 自身跨目录字幕搜索，自动选择可独立关闭。
void main() {
  // 用「存在且立即退出」的程序替代真实 mpv，避免测试真启动播放器。
  final exe = Platform.isWindows
      ? r'C:\Windows\System32\where.exe'
      : '/bin/true';

  const sub = SubtitleItem(
    name: '01.srt',
    url: 'http://h/dav/01.srt',
    language: SubtitleLanguage.exact,
  );
  const subZh = SubtitleItem(
    name: '02.chs.srt',
    url: 'http://h/dav/02.chs.srt',
    language: SubtitleLanguage.chinese,
  );

  Future<String> createFakeMpv(Directory dir) async {
    final fakeMpv = File(
      '${dir.path}${Platform.pathSeparator}'
      'mpv-test${Platform.isWindows ? '.exe' : ''}',
    );
    await File(exe).copy(fakeMpv.path);
    return fakeMpv.path;
  }

  Future<(ExternalPlayerService, Directory)> makeService({
    String executable = 'mpv',
    bool subtitleInjectionEnabled = true,
    bool subtitleAutoSelectEnabled = true,
    bool resumeEnabled = true,
    PlayerProcessController? processController,
    bool useDefaultWatchLaterDirectory = false,
  }) async {
    final dir = Directory.systemTemp.createTempSync('sp_launch_');
    var resolvedExecutable = executable;
    if (executable == 'mpv') {
      resolvedExecutable = await createFakeMpv(dir);
    }
    final cfg = StreamPathConfigStore.forPath(
      '${dir.path}${Platform.pathSeparator}cfg.json',
    );
    await cfg.save(
      StreamPathConfig.fromParts(
        PlayerConfig(
          name: 'mpv',
          executable: resolvedExecutable,
          args: const ['--sub-file={subfile}', '{url}', '--start={start}'],
          subtitleInjectionEnabled: subtitleInjectionEnabled,
          subtitleAutoSelectEnabled: subtitleAutoSelectEnabled,
          resumeEnabled: resumeEnabled,
        ),
        const ConnectionConfig(baseUrl: 'http://h/dav'),
      ),
    );
    return (
      ExternalPlayerService(
        configStore: cfg,
        watchLaterDir: useDefaultWatchLaterDirectory
            ? null
            : Directory('${dir.path}${Platform.pathSeparator}wl'),
        processController: processController,
      ),
      dir,
    );
  }

  test('视频 runtime 的 watcher 与 isPlayerRunning 共享同一探活查询', () async {
    final controller = _SharedProbeController();
    final (service, dir) = await makeService(processController: controller);
    addTearDown(() async {
      if (!controller.releaseProbe.isCompleted) {
        controller.releaseProbe.complete(PlayerProcessLiveness.exited);
      }
      await service.terminateSession('shared-liveness');
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    await service.launch(
      entries: const [MediaEntry(url: 'http://h/dav/01.mp4')],
      sessionId: 'shared-liveness',
    );
    await controller.probeStarted.future;

    final running = service.isPlayerRunning('shared-liveness');
    await Future<void>.delayed(Duration.zero);
    expect(controller.probeCalls, 1);

    controller.releaseProbe.complete(PlayerProcessLiveness.alive);
    expect(await running, isTrue);
    expect(
      await service.terminateSession('shared-liveness'),
      PlayerTerminationOutcome.terminated,
    );
    expect(controller.terminateCalls, 1);
  });

  /// 取字幕脚本（single-subtitle / playlist-subtitles）；current.lua
  /// 状态上报脚本不算（单集模式也注入）。
  String? scriptArgOf(List<String> args) {
    for (final a in args) {
      if (!a.startsWith('--script=')) continue;
      final path = a.substring('--script='.length);
      final name = p.basename(path);
      if (!name.startsWith('streampath-current-') &&
          !name.startsWith('streampath-titles-')) {
        return path;
      }
    }
    return null;
  }

  /// 取 current.lua 状态上报脚本路径（单集/多集均注入）。
  String? currentScriptOf(List<String> args) {
    for (final a in args) {
      if (!a.startsWith('--script=')) continue;
      final path = a.substring('--script='.length);
      if (p.basename(path).startsWith('streampath-current-')) return path;
    }
    return null;
  }

  group('launch 单集：外挂字幕注入与自动选择', () {
    test('WebDAV 字体落入隔离目录并由会话脚本注入', () async {
      final (service, dir) = await makeService();
      addTearDown(() async {
        await service.terminateSession('webdav-fonts');
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      var loadCount = 0;
      const fonts = WebDavFontDirectory(
        name: 'Fonts',
        requestPath: 'Series/Fonts',
        entryKey: 'http://h/dav/Series/Fonts/',
        files: [
          WebDavFontFile(
            name: 'subtitle.ttf',
            url: 'http://h/dav/Series/Fonts/subtitle.ttf',
            size: 4,
          ),
        ],
      );

      final result = await service.launch(
        entries: const [MediaEntry(url: 'http://h/dav/Series/01.mp4')],
        sessionId: 'webdav-fonts',
        webDavFonts: fonts,
        webDavFontLoader: (url, {required maxBytes, required timeout}) async {
          loadCount++;
          return [0, 1, 2, 3];
        },
      );

      final fontScriptPath = result.args
          .where((arg) => arg.startsWith('--script='))
          .map((arg) => arg.substring('--script='.length))
          .firstWhere(
            (path) => p.basename(path).startsWith('streampath-font-directory-'),
          );
      final script = await File(fontScriptPath).readAsString();
      final fontDirectoryPath = result.artifactPaths.firstWhere(
        (path) => p.basename(path).startsWith('streampath-fonts-'),
      );

      expect(loadCount, 1);
      expect(script, contains('mp.add_hook("on_load", 5'));
      expect(
        script,
        contains('mp.set_property("file-local-options/" .. OPTION, FONT_DIR)'),
      );
      expect(script, contains(fontDirectoryPath.replaceAll('\\', '\\\\')));
      expect(
        result.args.any((arg) => arg.startsWith('--sub-fonts-dir=')),
        isFalse,
        reason: '旧版 MPV 不得因未知命令行选项启动失败',
      );
      expect(
        Directory(
          fontDirectoryPath,
        ).listSync().whereType<File>().single.readAsBytesSync(),
        [0, 1, 2, 3],
      );
      await service.terminateSession('webdav-fonts');
      expect(await Directory(fontDirectoryPath).exists(), isFalse);
    });

    test('自动注入关闭时不读取或注入 WebDAV 字体', () async {
      final (service, dir) = await makeService(subtitleInjectionEnabled: false);
      addTearDown(() async {
        await service.terminateSession('webdav-fonts-disabled');
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      var loadCount = 0;
      const fonts = WebDavFontDirectory(
        name: 'Fonts',
        requestPath: 'Fonts',
        entryKey: 'http://h/dav/Fonts/',
        files: [
          WebDavFontFile(
            name: 'subtitle.ttf',
            url: 'http://h/dav/Fonts/subtitle.ttf',
            size: 1,
          ),
        ],
      );

      final result = await service.launch(
        entries: const [MediaEntry(url: 'http://h/dav/01.mp4')],
        sessionId: 'webdav-fonts-disabled',
        webDavFonts: fonts,
        webDavFontLoader: (url, {required maxBytes, required timeout}) async {
          loadCount++;
          return [1];
        },
      );

      expect(loadCount, 0);
      expect(
        result.args.any((arg) => arg.contains('streampath-font-directory-')),
        isFalse,
      );
    });

    test('MPV 仅向同源 URL 内嵌空密码凭据且不使用全局认证头', () async {
      final (service, _) = await makeService();
      final result = await service.launch(
        entries: [MediaEntry(url: 'http://h/dav/01.mp4', subtitle: sub)],
        username: 'guest',
        password: '',
      );

      expect(result.args, contains('http://guest:@h/dav/01.mp4'));
      expect(
        result.args.any((arg) => arg.startsWith('--http-header-fields=')),
        isFalse,
      );
      final subtitleScript = await File(
        scriptArgOf(result.args)!,
      ).readAsString();
      expect(subtitleScript, contains('http://guest:@h/dav/01.srt'));
    });

    test('自动注入和自动选择开启时以 select 模式加入匹配字幕', () async {
      final (service, _) = await makeService();
      final result = await service.launch(
        entries: [MediaEntry(url: 'http://h/dav/01.mp4', subtitle: sub)],
      );
      final scriptPath = scriptArgOf(result.args);
      expect(scriptPath, isNotNull, reason: '应注入 --script= 参数');
      final file = File(scriptPath!);
      expect(file.existsSync(), isTrue, reason: '脚本文件应已写入');
      final content = await file.readAsString();
      expect(content, contains('file-loaded'));
      expect(content, contains('local MODE = "select"'));
      expect(
        content,
        contains('mp.commandv("sub-add", URL, MODE, TITLE, LANG)'),
      );
      expect(content, contains('http://h/dav/01.srt'));
      expect(content, contains('01.srt'));
      expect(result.args, contains('--sub-auto=no'));
      expect(result.args.any((a) => a.startsWith('--sub-file=')), isFalse);
      // mpv 注入 named pipe IPC 参数（实时状态/进度通道；pipe 名唯一）。
      expect(
        result.args.any(
          (a) =>
              a.startsWith('--input-ipc-server=') &&
              a.contains(r'\\.\pipe\mpvsocket_'),
        ),
        isTrue,
        reason: '应注入唯一的 mpv IPC pipe 参数',
      );
    });

    test('两次 launch 生成不同的 IPC pipe 名（防串台）', () async {
      final (service, _) = await makeService();
      String? pipeOf(PlayerLaunchResult r) {
        for (final a in r.args) {
          if (a.startsWith('--input-ipc-server=')) {
            return a.substring('--input-ipc-server='.length);
          }
        }
        return null;
      }

      final first = await service.launch(
        entries: const [MediaEntry(url: 'http://h/dav/01.mp4')],
      );
      final second = await service.launch(
        entries: const [MediaEntry(url: 'http://h/dav/01.mp4')],
      );
      final p1 = pipeOf(first);
      final p2 = pipeOf(second);
      expect(p1, isNotNull);
      expect(p2, isNotNull);
      expect(p1, isNot(p2), reason: '每次播放 pipe 名应唯一');
      expect(
        p1,
        matches(RegExp(r'^\\\\.\\pipe\\mpvsocket_\d+_\d+$')),
        reason: 'pipe 名应包含进程时间 nonce 与单调序号，避免应用重启后复用',
      );
    });

    test('同一 sessionId 重启时所有磁盘工件使用新 epoch', () async {
      var currentPid = 0;
      final controller = PlayerProcessController(
        snapshotLoader: (pid) async {
          currentPid = pid;
          return PlayerProcessLookupResult.found(
            PlayerProcessIdentity(
              pid: pid,
              executablePath: r'C:\TestMPV\mpv.exe',
              creationTime: pid + 1000,
            ),
          );
        },
        pipeServerPidLoader: (_) async => currentPid,
        processTreeTerminator: (_) async => true,
      );
      final (service, dir) = await makeService(processController: controller);
      addTearDown(() async {
        await service.terminateSession('stable-session');
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });

      final first = await service.launch(
        entries: const [MediaEntry(url: 'http://h/dav/01.mp4')],
        sessionId: 'stable-session',
      );
      expect(
        await service.terminateSession('stable-session'),
        PlayerTerminationOutcome.terminated,
      );
      await File(first.statusFilePath!).writeAsString('0\nold-url\n1\n');
      await File(first.commandFilePath!).writeAsString('pause');
      await File(
        first.progressFilePath!,
      ).writeAsString('{"outcome":"position","reason":"error"}\n');

      final second = await service.launch(
        entries: const [MediaEntry(url: 'http://h/dav/01.mp4')],
        sessionId: 'stable-session',
      );

      expect(second.statusFilePath, isNot(first.statusFilePath));
      expect(second.commandFilePath, isNot(first.commandFilePath));
      expect(second.progressFilePath, isNot(first.progressFilePath));
      final firstScripts = first.args
          .where((arg) => arg.startsWith('--script='))
          .toSet();
      final secondScripts = second.args
          .where((arg) => arg.startsWith('--script='))
          .toSet();
      expect(firstScripts.intersection(secondScripts), isEmpty);
      expect(await File(first.commandFilePath!).readAsString(), 'pause');
    });

    test('Process.start 失败后清理本次已生成的视频脚本工件', () async {
      final missing = p.join(
        Directory.systemTemp.path,
        'missing-mpv-${DateTime.now().microsecondsSinceEpoch}.exe',
      );
      final (service, dir) = await makeService(executable: missing);
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });

      await expectLater(
        service.launch(
          entries: const [MediaEntry(url: 'http://h/dav/01.mp4')],
          sessionId: 'failed-launch',
        ),
        throwsA(isA<Exception>()),
      );

      final watchLater = Directory(p.join(dir.path, 'wl'));
      final artifacts = watchLater.existsSync()
          ? watchLater
                .listSync()
                .whereType<File>()
                .map((file) => p.basename(file.path))
                .where((name) => name.startsWith('streampath-'))
                .toList()
          : const <String>[];
      expect(artifacts, isEmpty);
    });

    test('默认目录多集续播启动失败会清理 cache 与 watch_later 的本代工件', () async {
      final nonce = DateTime.now().microsecondsSinceEpoch;
      final sessionId = 'default-base-leak-$nonce';
      final missing = p.join(
        Directory.systemTemp.path,
        'missing-mpv-default-base-$nonce.exe',
      );
      final (service, dir) = await makeService(
        executable: missing,
        useDefaultWatchLaterDirectory: true,
      );
      final cache = await AppPaths.cacheDirectory();
      final watchLater = Directory(p.join(cache.path, 'mpv-watch-later'));

      Iterable<File> ownedArtifacts() sync* {
        for (final base in [cache, watchLater]) {
          if (!base.existsSync()) continue;
          yield* base.listSync().whereType<File>().where(
            (file) => p.basename(file.path).contains(sessionId),
          );
        }
      }

      addTearDown(() async {
        for (final file in ownedArtifacts().toList()) {
          try {
            await file.delete();
          } catch (_) {}
        }
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });

      await expectLater(
        service.launch(
          entries: const [
            MediaEntry(url: 'http://h/dav/01.mp4'),
            MediaEntry(url: 'http://h/dav/02.mp4'),
          ],
          sessionId: sessionId,
          resumeSeconds: 30,
          username: 'guest',
          password: '',
        ),
        throwsA(isA<Exception>()),
      );

      expect(ownedArtifacts(), isEmpty);
    });

    test('终止只经过注入的完整进程身份边界，不调用真实 taskkill', () async {
      var currentPid = 0;
      var terminateCalls = 0;
      final controller = PlayerProcessController(
        snapshotLoader: (pid) async {
          currentPid = pid;
          return PlayerProcessLookupResult.found(
            PlayerProcessIdentity(
              pid: pid,
              executablePath: r'C:\TestMPV\mpv.exe',
              creationTime: 133700000000000010,
            ),
          );
        },
        pipeServerPidLoader: (_) async => currentPid,
        processTreeTerminator: (_) async {
          terminateCalls++;
          return true;
        },
      );
      final (service, _) = await makeService(processController: controller);

      final result = await service.launch(
        entries: const [MediaEntry(url: 'http://h/dav/01.mp4')],
        sessionId: 'safe-process',
      );
      expect(result.processIdentity?.pid, result.process.pid);
      expect(result.processIdentity?.executablePath, r'C:\TestMPV\mpv.exe');
      expect(result.processIdentity?.creationTime, 133700000000000010);

      final outcome = await service.terminateSession('safe-process');

      expect(outcome, PlayerTerminationOutcome.terminated);
      expect(terminateCalls, 1);
    });

    test('并发终止保持同一 runtime 并只执行一次身份终止', () async {
      var currentPid = 0;
      var terminateCalls = 0;
      final allowTermination = Completer<bool>();
      final controller = PlayerProcessController(
        snapshotLoader: (pid) async {
          currentPid = pid;
          return PlayerProcessLookupResult.found(
            PlayerProcessIdentity(
              pid: pid,
              executablePath: r'C:\TestMPV\mpv.exe',
              creationTime: 133700000000000012,
            ),
          );
        },
        pipeServerPidLoader: (_) async => currentPid,
        processTreeTerminator: (_) async {
          terminateCalls++;
          return allowTermination.future;
        },
      );
      final (service, dir) = await makeService(processController: controller);
      addTearDown(() async {
        if (!allowTermination.isCompleted) allowTermination.complete(true);
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      await service.launch(
        entries: const [MediaEntry(url: 'http://h/dav/01.mp4')],
        sessionId: 'coalesced-termination',
      );

      final first = service.terminateSession('coalesced-termination');
      final second = service.terminateSession('coalesced-termination');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(terminateCalls, 1);
      allowTermination.complete(true);

      expect(await first, PlayerTerminationOutcome.terminated);
      expect(await second, PlayerTerminationOutcome.terminated);
      expect(terminateCalls, 1);
    });

    test('同 session 双启动在旧探活阻塞时由后进入请求保持所有权', () async {
      const legacyPid = 41001;
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
                creationTime: pid + 7000,
              ),
            ),
          );
        },
        pipeServerPidLoader: (_) async => latestPid,
        processTreeTerminator: (_) async => true,
      );
      final (service, dir) = await makeService(processController: controller);
      addTearDown(() async {
        if (!releaseProbe.isCompleted) {
          releaseProbe.complete(const PlayerProcessLookupResult.notFound());
        }
        await service.terminateSession('launch-race');
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      await service.restoreSession(
        sessionId: 'launch-race',
        pid: legacyPid,
        executablePath: r'C:\TestMPV\legacy.exe',
        creationTime: 70001,
        ipcPipeName: r'\\.\pipe\legacy-launch-race',
      );

      final stale = service.launch(
        entries: const [MediaEntry(url: 'http://h/dav/old.mp4')],
        sessionId: 'launch-race',
      );
      await probeStarted.future;
      final current = await service.launch(
        entries: const [MediaEntry(url: 'http://h/dav/new.mp4')],
        sessionId: 'launch-race',
      );
      releaseProbe.complete(const PlayerProcessLookupResult.notFound());

      await expectLater(stale, throwsA(isA<Exception>()));
      expect(current.sessionId, 'launch-race');
    });

    test('launch 探活阻塞期间 terminate 会取消尚未注册的启动', () async {
      const legacyPid = 41002;
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
      final (service, dir) = await makeService(processController: controller);
      addTearDown(() async {
        if (!releaseProbe.isCompleted) {
          releaseProbe.complete(const PlayerProcessLookupResult.notFound());
        }
        await service.terminateSession('terminate-during-launch');
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      await service.restoreSession(
        sessionId: 'terminate-during-launch',
        pid: legacyPid,
        executablePath: r'C:\TestMPV\legacy.exe',
        creationTime: 70002,
        ipcPipeName: r'\\.\pipe\legacy-terminate-launch',
      );

      final pending = service.launch(
        entries: const [MediaEntry(url: 'http://h/dav/new.mp4')],
        sessionId: 'terminate-during-launch',
      );
      await probeStarted.future;
      await service.terminateSession('terminate-during-launch');
      releaseProbe.complete(const PlayerProcessLookupResult.notFound());

      await expectLater(pending, throwsA(isA<Exception>()));
    });

    test('旧持久会话只有 PID 和 pipe 时拒绝终止', () async {
      var terminateCalls = 0;
      final controller = PlayerProcessController(
        snapshotLoader: (pid) async => PlayerProcessLookupResult.found(
          PlayerProcessIdentity(
            pid: pid,
            executablePath: r'C:\TestMPV\mpv.exe',
            creationTime: 133700000000000011,
          ),
        ),
        pipeServerPidLoader: (_) async => 12121,
        processTreeTerminator: (_) async {
          terminateCalls++;
          return true;
        },
      );
      final (service, _) = await makeService(processController: controller);
      await service.restoreSession(
        sessionId: 'legacy-process',
        pid: 12121,
        ipcPipeName: r'\\.\pipe\legacy-process',
      );

      expect(await service.isPlayerRunning('legacy-process'), isTrue);
      final outcome = await service.terminateSession('legacy-process');

      expect(outcome, PlayerTerminationOutcome.refused);
      expect(terminateCalls, 0);
    });

    test('MPV 已关闭并重启后，无 PID 的继续播放会话可直接再次启动', () async {
      // 回归：用户关闭 MPV 后监控收敛会清空历史的 pid/pipe 但保留记录；
      // 应用重启后该历史被 restoreSession 恢复为无 PID 的幽灵会话。
      // 点击继续播放必须直接放行，而不是提示「该播放会话仍在运行」。
      var lookups = 0;
      final controller = PlayerProcessController(
        snapshotLoader: (pid) async {
          lookups++;
          return lookups == 1
              ? PlayerProcessLookupResult.found(
                  PlayerProcessIdentity(
                    pid: pid,
                    executablePath: r'C:\TestMPV\mpv.exe',
                    creationTime: pid + 9600,
                  ),
                )
              : const PlayerProcessLookupResult.notFound();
        },
        pipeServerPidLoader: (_) async => null,
        processTreeTerminator: (_) async => true,
      );
      final (service, dir) = await makeService(processController: controller);
      addTearDown(() async {
        await service.terminateSession('resume-after-restart');
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      await service.restoreSession(
        sessionId: 'resume-after-restart',
        pid: null,
        executablePath: null,
        creationTime: null,
        ipcPipeName: null,
        launchEpoch: 'stale-epoch',
      );

      final result = await service.launch(
        entries: const [MediaEntry(url: 'http://h/dav/01.mp4')],
        sessionId: 'resume-after-restart',
      );

      expect(result.sessionId, 'resume-after-restart');
      expect(result.launchEpoch, isNot('stale-epoch'));

      // 幽灵会话已被释放并替换：再次点击继续播放同样直接放行。
      final second = await service.launch(
        entries: const [MediaEntry(url: 'http://h/dav/02.mp4')],
        sessionId: 'resume-after-restart',
      );
      expect(second.launchEpoch, isNot(result.launchEpoch));
    });

    test('两个显式会话使用完全独立的 IPC、状态文件和播放列表资源', () async {
      final (service, _) = await makeService();
      const entries = [
        MediaEntry(url: 'http://h/dav/01.mp4', title: 'S01E01.mkv'),
        MediaEntry(url: 'http://h/dav/02.mp4', title: 'S01E02.mkv'),
      ];

      final first = await service.launch(
        entries: entries,
        sessionId: 'first-session',
      );
      final second = await service.launch(
        entries: entries,
        sessionId: 'second-session',
      );

      expect(first.sessionId, 'first-session');
      expect(second.sessionId, 'second-session');
      expect(first.ipcPipeName, isNot(second.ipcPipeName));
      expect(first.statusFilePath, isNot(second.statusFilePath));
      expect(first.commandFilePath, isNot(second.commandFilePath));
      expect(first.progressFilePath, isNot(second.progressFilePath));
      expect(first.progressFilePath, contains('first-session'));
      expect(second.progressFilePath, contains('second-session'));

      String playlistPath(PlayerLaunchResult result) => result.args
          .firstWhere((arg) => arg.startsWith('--playlist='))
          .substring('--playlist='.length);
      expect(playlistPath(first), contains('first-session'));
      expect(playlistPath(second), contains('second-session'));
      expect(playlistPath(first), isNot(playlistPath(second)));

      final firstScripts = first.args
          .where((arg) => arg.startsWith('--script='))
          .toList();
      final secondScripts = second.args
          .where((arg) => arg.startsWith('--script='))
          .toList();
      expect(firstScripts, isNotEmpty);
      expect(secondScripts, isNotEmpty);
      expect(
        firstScripts.every((arg) => arg.contains('first-session')),
        isTrue,
      );
      expect(
        secondScripts.every((arg) => arg.contains('second-session')),
        isTrue,
      );
      expect(firstScripts.toSet().intersection(secondScripts.toSet()), isEmpty);
    });

    test('mpv 无字幕时不注入字幕脚本（但注入状态上报脚本）', () async {
      final (service, _) = await makeService();
      final result = await service.launch(
        entries: const [MediaEntry(url: 'http://h/dav/01.mp4')],
      );
      expect(scriptArgOf(result.args), isNull, reason: '无字幕脚本');
      final currentPath = currentScriptOf(result.args);
      expect(currentPath, isNotNull, reason: '单集也注入 current.lua（暂停/开始状态同步）');
      // 关键防回归：idle-active 写 -1 播完标记必须受 has_loaded 约束，
      // 防止启动瞬间（未加载文件）误写 -1 导致 UI 误清「继续播放」历史。
      final content = await File(currentPath!).readAsString();
      expect(content, contains('has_loaded'));
      expect(content, contains('if val and has_loaded then'));
      expect(content, contains('local PROGRESS ='));
      expect(content, contains('mp.register_event("end-file"'));
    });

    test('自动注入开启但自动选择关闭时以 auto 模式加入并恢复原字幕轨道', () async {
      final (service, _) = await makeService(subtitleAutoSelectEnabled: false);
      final result = await service.launch(
        entries: [MediaEntry(url: 'http://h/dav/01.mp4', subtitle: sub)],
      );
      final scriptPath = scriptArgOf(result.args);
      expect(scriptPath, isNotNull);
      final content = await File(scriptPath!).readAsString();
      expect(content, contains('local MODE = "auto"'));
      expect(
        content,
        contains('mp.commandv("sub-add", URL, MODE, TITLE, LANG)'),
      );
      expect(
        content,
        contains('local previous_sid = mp.get_property("sid", "no")'),
      );
      expect(content, contains('mp.set_property("sid", previous_sid)'));
      expect(content, isNot(contains('local MODE = "select"')));
      expect(result.args, contains('--sub-auto=no'));
      expect(result.args.any((a) => a.startsWith('--sub-file=')), isFalse);
    });

    test('自动注入关闭时不注入字幕参数、脚本或 mpv 自动搜索限制', () async {
      final (service, _) = await makeService(subtitleInjectionEnabled: false);
      final result = await service.launch(
        entries: [MediaEntry(url: 'http://h/dav/01.mp4', subtitle: sub)],
      );
      expect(scriptArgOf(result.args), isNull);
      expect(result.args.any((a) => a.startsWith('--sub-file=')), isFalse);
      expect(result.args, isNot(contains('--sub-auto=no')));
    });

    test('非 mpv 播放器不注入脚本', () async {
      final (service, _) = await makeService(executable: exe);
      final result = await service.launch(
        entries: [MediaEntry(url: 'http://h/dav/01.mp4', subtitle: sub)],
      );
      expect(scriptArgOf(result.args), isNull);
    });

    test('clearStaleFinishedMark：残留 -1 标记清除、正常状态保留', () async {
      final dir = Directory.systemTemp.createTempSync('sp_stale_');

      // 残留「已播完」标记（首行 -1）→ 应删除。
      final stale = File('${dir.path}${Platform.pathSeparator}stale.txt');
      stale.writeAsStringSync('-1\n\n');
      expect(await ExternalPlayerService.clearStaleFinishedMark(stale), isTrue);
      expect(stale.existsSync(), isFalse);

      // 正常状态文件（首行非 -1）→ 保留。
      final normal = File('${dir.path}${Platform.pathSeparator}normal.txt');
      normal.writeAsStringSync('0\nhttp://h/dav/01.mp4\n1');
      expect(
        await ExternalPlayerService.clearStaleFinishedMark(normal),
        isFalse,
      );
      expect(normal.existsSync(), isTrue);

      // 文件不存在 → 无操作。
      final missing = File('${dir.path}${Platform.pathSeparator}missing.txt');
      expect(
        await ExternalPlayerService.clearStaleFinishedMark(missing),
        isFalse,
      );
    });

    test('mpv 单集模板含 subfile 占位符时仍统一使用脚本注入', () async {
      final dir = Directory.systemTemp.createTempSync('sp_launch_');
      final cfg = StreamPathConfigStore.forPath(
        '${dir.path}${Platform.pathSeparator}cfg.json',
      );
      await cfg.save(
        StreamPathConfig.fromParts(
          PlayerConfig(
            name: 'mpv',
            executable: await createFakeMpv(dir),
            args: const ['--sub-file={subfile} --start={start}', '{url}'],
          ),
          const ConnectionConfig(),
        ),
      );
      final service = ExternalPlayerService(
        configStore: cfg,
        watchLaterDir: Directory('${dir.path}${Platform.pathSeparator}wl'),
      );
      final result = await service.launch(
        entries: [MediaEntry(url: 'http://h/dav/01.mp4', subtitle: sub)],
        resumeSeconds: null, // 无进度
      );
      expect(result.args.any((a) => a.startsWith('--sub-file=')), isFalse);
      expect(scriptArgOf(result.args), isNotNull, reason: '外挂字幕应由 Lua 脚本注入');
      // 无进度时禁用恢复并强制从头播放，而非沿用模板的空 --start=。
      expect(result.args, contains('--no-resume-playback'));
      expect(result.args, contains('--start=0'));
    });
  });

  group('launch 标题：mpv 显示当前集文件名而非长 URL', () {
    test('单集注入 --force-media-title 且 URL 原样保留', () async {
      final (service, _) = await makeService();
      final result = await service.launch(
        entries: const [
          MediaEntry(
            url: 'http://h/dav/1.EpisodeData/01.mp4',
            title: 'AIR －S01E01－微风~breeze~.mkv',
          ),
        ],
      );
      expect(
        result.args,
        contains('--force-media-title=AIR －S01E01－微风~breeze~.mkv'),
      );
      expect(
        result.args,
        contains('http://h/dav/1.EpisodeData/01.mp4'),
        reason: '直链播放地址必须保持不变',
      );
    });

    test('单集 title 缺省时回退 URL 末段文件名', () async {
      final (service, _) = await makeService();
      final result = await service.launch(
        entries: const [MediaEntry(url: 'http://h/dav/01.mp4')],
      );
      expect(result.args, contains('--force-media-title=01.mp4'));
    });

    test('非 mpv 播放器不注入标题参数', () async {
      final (service, _) = await makeService(executable: exe);
      final result = await service.launch(
        entries: const [
          MediaEntry(url: 'http://h/dav/01.mp4', title: '01.mp4'),
        ],
      );
      expect(
        result.args.any((a) => a.contains('--force-media-title')),
        isFalse,
      );
    });
  });

  group('TS 时间轴与续播（不复现 1.084s 起点）', () {
    test('TS 无进度时只重定位时间轴，不注入 --start=0 seek', () async {
      final (service, _) = await makeService();
      final result = await service.launch(
        entries: const [MediaEntry(url: 'http://h/dav/movie.m2ts')],
        resumeSeconds: null,
      );

      expect(result.args, contains('--rebase-start-time=yes'));
      expect(result.args, contains('--no-resume-playback'));
      expect(result.args, isNot(contains('--start=0')));
    });

    test('TS 单集上次进度仍按重定位后的相对秒数恢复', () async {
      final (service, _) = await makeService();
      final result = await service.launch(
        entries: const [MediaEntry(url: 'http://h/dav/movie.ts')],
        resumeSeconds: 90,
      );

      expect(result.args, contains('--rebase-start-time=yes'));
      expect(result.args, contains('--start=90'));
      expect(result.args, isNot(contains('--start=0')));
    });

    test('TS 多集上次进度写入起点集 watch_later', () async {
      final (service, dir) = await makeService();
      const startUrl = 'http://h/dav/02.m2ts';
      final result = await service.launch(
        entries: const [
          MediaEntry(url: 'http://h/dav/01.m2ts'),
          MediaEntry(url: startUrl),
        ],
        playlistStart: 1,
        resumeSeconds: 90,
      );

      final watchLater = File(
        '${dir.path}${Platform.pathSeparator}wl'
        '${Platform.pathSeparator}${MpvWatchLaterSync.md5FileName(startUrl)}',
      );
      expect(result.args, contains('--rebase-start-time=yes'));
      expect(result.args, isNot(contains('--start=0')));
      expect(await watchLater.readAsString(), contains('start=90'));
    });
  });

  group('launch 多集：m3u 播放列表 + sub-add 脚本 + 预写 watch_later 续播', () {
    test('多集生成 m3u（EXTINF 标题 + EXTVLCOPT + 直链 URL）并注入播放列表脚本', () async {
      final (service, dir) = await makeService();
      final result = await service.launch(
        entries: const [
          MediaEntry(
            url: 'http://h/dav/1.EpisodeData/01.mp4',
            title: 'AIR S01E01.mkv',
            subtitle: sub,
          ),
          MediaEntry(url: 'http://h/dav/1.EpisodeData/02.mp4'),
          MediaEntry(url: 'http://h/dav/1.EpisodeData/03.mp4', subtitle: subZh),
        ],
      );
      // m3u：播放列表标题 + per-file 窗口标题 + 直链 URL（原样保留）。
      final m3u = File(
        result.args
            .singleWhere((argument) => argument.startsWith('--playlist='))
            .substring('--playlist='.length),
      );
      expect(m3u.existsSync(), isTrue, reason: '应生成 m3u 播放列表');
      final content = await m3u.readAsString();
      expect(content, startsWith('#EXTM3U'));
      expect(content, contains('#EXTINF:0,AIR S01E01.mkv'));
      expect(content, contains('#EXTVLCOPT:force-media-title=AIR S01E01.mkv'));
      expect(
        content,
        contains('#EXTINF:0,02.mp4'),
        reason: '无 title 的集回退 URL 末段文件名',
      );
      expect(content, contains('http://h/dav/1.EpisodeData/01.mp4'));
      expect(content, contains('http://h/dav/1.EpisodeData/02.mp4'));
      expect(content, contains('http://h/dav/1.EpisodeData/03.mp4'));
      // 参数：--playlist 指向 m3u，不再逐集传 URL。
      expect(result.args, contains('--playlist=${m3u.path}'));
      expect(result.args.any((a) => a.contains('http://h/')), isFalse);
      expect(result.args.any((a) => a.contains('--{')), isFalse);
      // 字幕脚本仍按 playlist-pos 注入（含每集字幕映射）。
      final scriptPath = scriptArgOf(result.args);
      expect(scriptPath, isNotNull);
      final subScript = await File(scriptPath!).readAsString();
      expect(subScript, contains('SUBS[0] = "http://h/dav/01.srt"'));
      expect(subScript, contains('SUBS[2] = "http://h/dav/02.chs.srt"'));
      expect(subScript, contains('local MODE = "select"'));
      expect(subScript, contains('register_event("file-loaded"'));
      expect(subScript, contains('get_property_number("playlist-pos", -1)'));
      expect(subScript, contains('local url = SUBS[pos]'));
      expect(
        subScript,
        contains('mp.commandv("sub-add", url, MODE, TITLES[pos], LANGS[pos])'),
      );
      expect(
        subScript,
        contains('if MODE == "auto" then'),
        reason: '自动选择开启时恢复 sid 的分支存在但不会执行',
      );
      expect(subScript, isNot(contains('SUBS[1]')));
      expect(result.args, contains('--sub-auto=no'));
      expect(result.args.any((a) => a.contains('--sub-file')), isFalse);
      // 无进度时禁用恢复并强制从头；不出现其他 --start 值。
      expect(result.args, contains('--no-resume-playback'));
      expect(result.args.where((a) => a.contains('--start=')).toList(), [
        '--start=0',
      ]);
    });

    test('关闭自动选择后，自动切集仍按 playlist-pos 逐集注入匹配字幕', () async {
      final (service, _) = await makeService(subtitleAutoSelectEnabled: false);
      final result = await service.launch(
        entries: const [
          MediaEntry(url: 'http://h/dav/S01E01.mkv', subtitle: sub),
          MediaEntry(url: 'http://h/dav/S01E02.mkv', subtitle: subZh),
        ],
      );
      final scriptPath = scriptArgOf(result.args);
      expect(scriptPath, isNotNull);
      final content = await File(scriptPath!).readAsString();
      expect(content, contains('local MODE = "auto"'));
      expect(content, contains('SUBS[0] = "http://h/dav/01.srt"'));
      expect(content, contains('SUBS[1] = "http://h/dav/02.chs.srt"'));
      expect(content, contains('register_event("file-loaded"'));
      expect(content, contains('get_property_number("playlist-pos", -1)'));
      expect(content, contains('local url = SUBS[pos]'));
      expect(
        content,
        contains('mp.commandv("sub-add", url, MODE, TITLES[pos], LANGS[pos])'),
      );
      expect(content, contains('mp.set_property("sid", previous_sid)'));
    });

    test('多集注入标题兜底脚本（老版本 mpv 用）', () async {
      final (service, _) = await makeService();
      final result = await service.launch(
        entries: const [
          MediaEntry(
            url: 'http://h/dav/1.EpisodeData/AIR S01E01.mkv',
            title: 'AIR S01E01.mkv',
          ),
          MediaEntry(url: 'http://h/dav/1.EpisodeData/02.mp4'),
        ],
      );
      String? titlesScript;
      for (final a in result.args) {
        if (!a.startsWith('--script=')) continue;
        final path = a.substring('--script='.length);
        if (!p.basename(path).startsWith('streampath-titles-')) continue;
        titlesScript = path;
        break;
      }
      expect(titlesScript, isNotNull, reason: '应注入标题兜底脚本');
      final content = await File(titlesScript!).readAsString();
      // 自动切集检测上报脚本也应注入（多集模式）。
      String? currentScript;
      for (final a in result.args) {
        if (!a.startsWith('--script=')) continue;
        final path = a.substring('--script='.length);
        if (!p.basename(path).startsWith('streampath-current-')) continue;
        currentScript = path;
        break;
      }
      expect(currentScript, isNotNull, reason: '应注入当前播放状态上报脚本');
      final currentContent = await File(currentScript!).readAsString();
      expect(currentContent, contains('playlist-pos'));
      expect(currentContent, contains('file-loaded'));
      expect(currentContent, contains('mpv-current-'));
      // 下边栏同步：暂停状态上报 + 命令执行 + 退出/空闲复位。
      expect(currentContent, contains('observe_property("pause"'));
      expect(currentContent, contains('mpv-command-'));
      expect(currentContent, contains('add_periodic_timer'));
      expect(currentContent, contains('set_property_bool("pause", true)'));
      expect(currentContent, contains('set_property_bool("pause", false)'));
      expect(currentContent, contains('get_property_number("time-pos"'));
      expect(currentContent, contains('get_property_number("duration"'));
      expect(currentContent, contains('register_event("shutdown"'));
      expect(currentContent, contains('idle-active'));
      // 播放列表播完（最后一个视频结束）时写 pos=-1 标记，
      // 软件据此清除「继续播放」历史。
      expect(currentContent, contains('-1'));
      expect(content, contains('TITLES[0] = "AIR S01E01.mkv"'));
      expect(
        content,
        contains('TITLES[1] = "02.mp4"'),
        reason: '无 title 的集回退 URL 末段文件名',
      );
      expect(content, contains('force-media-title'));
      expect(content, contains('file-loaded'));
    });

    test('多集且首集有进度时预写 watch_later 文件（mpv 原生恢复续播）', () async {
      final (service, dir) = await makeService();
      const url = 'http://h/dav/01.mp4';
      await service.launch(
        entries: const [
          MediaEntry(url: url),
          MediaEntry(url: 'http://h/dav/02.mp4'),
        ],
        resumeSeconds: 90,
      );
      final wlFile = File(
        '${dir.path}${Platform.pathSeparator}wl'
        '${Platform.pathSeparator}${MpvWatchLaterSync.md5FileName(url)}',
      );
      expect(wlFile.existsSync(), isTrue, reason: '应预写首集 watch_later');
      expect(await wlFile.readAsString(), contains('start=90'));
    });

    test('playlistStart>0 时续播预写的是播放起点集的 watch_later', () async {
      final (service, dir) = await makeService();
      const firstUrl = 'http://h/dav/01.mp4';
      const startUrl = 'http://h/dav/02.mp4';
      await service.launch(
        entries: const [
          MediaEntry(url: firstUrl),
          MediaEntry(url: startUrl),
          MediaEntry(url: 'http://h/dav/03.mp4'),
        ],
        playlistStart: 1,
        resumeSeconds: 90,
      );
      // 起点集(第 2 集)的 watch_later 被预写,第 1 集不受影响。
      final startWl = File(
        '${dir.path}${Platform.pathSeparator}wl'
        '${Platform.pathSeparator}${MpvWatchLaterSync.md5FileName(startUrl)}',
      );
      expect(startWl.existsSync(), isTrue);
      expect(await startWl.readAsString(), contains('start=90'));
      final firstWl = File(
        '${dir.path}${Platform.pathSeparator}wl'
        '${Platform.pathSeparator}${MpvWatchLaterSync.md5FileName(firstUrl)}',
      );
      expect(firstWl.existsSync(), isFalse);
    });

    test('无续播进度时清除起点集旧 watch_later（已看完的集从头播）', () async {
      final (service, dir) = await makeService();
      const startUrl = 'http://h/dav/02.mp4';
      final wlDir = Directory('${dir.path}${Platform.pathSeparator}wl');
      wlDir.createSync(recursive: true);
      // 模拟旧 watch_later：位置在片尾（会导致 mpv 秒切下一集）。
      final wlFile = File(
        '${wlDir.path}${Platform.pathSeparator}${MpvWatchLaterSync.md5FileName(startUrl)}',
      );
      wlFile.writeAsStringSync('start=3599');

      await service.launch(
        entries: const [
          MediaEntry(url: 'http://h/dav/01.mp4'),
          MediaEntry(url: startUrl),
        ],
        playlistStart: 1,
        resumeSeconds: null, // 已看完 → 从头播
      );
      expect(
        wlFile.existsSync(),
        isFalse,
        reason: '旧 watch_later 应被清除,mpv 从头播放该集',
      );
    });

    test('清除 watch_later 兼容 sanitize 命名（注释行匹配兜底）', () async {
      final (service, dir) = await makeService();
      const startUrl = 'http://h/dav/02.mp4';
      final wlDir = Directory('${dir.path}${Platform.pathSeparator}wl');
      wlDir.createSync(recursive: true);
      // 文件名不是 MD5（模拟 --write-filename-in-watch-later-config），
      // 但首行注释引用了该 URL。
      File(
        '${wlDir.path}${Platform.pathSeparator}wl_02.mp4',
      ).writeAsStringSync('# $startUrl\nstart=3599\n');

      await service.launch(
        entries: const [
          MediaEntry(url: 'http://h/dav/01.mp4'),
          MediaEntry(url: startUrl),
        ],
        playlistStart: 1,
        resumeSeconds: null,
      );
      expect(
        File('${wlDir.path}${Platform.pathSeparator}wl_02.mp4').existsSync(),
        isFalse,
        reason: '扫描兜底应删除注释匹配的旧 watch_later',
      );
    });

    test('多集无进度时不写 watch_later 且强制 --start=0（第一次点击即从头播）', () async {
      final (service, dir) = await makeService();
      const url = 'http://h/dav/01.mp4';
      final result = await service.launch(
        entries: const [
          MediaEntry(url: url),
          MediaEntry(url: 'http://h/dav/02.mp4'),
        ],
        resumeSeconds: null,
      );
      expect(
        result.args,
        contains('--no-resume-playback'),
        reason: '禁用 watch_later 恢复,即使旧记录残留也从头播放',
      );
      expect(result.args, contains('--start=0'));
      final wlFile = File(
        '${dir.path}${Platform.pathSeparator}wl'
        '${Platform.pathSeparator}${MpvWatchLaterSync.md5FileName(url)}',
      );
      expect(wlFile.existsSync(), isFalse);
    });

    test('预写 watch_later 保留已有记录并更新 start 行', () async {
      final (service, dir) = await makeService();
      const url = 'http://h/dav/01.mp4';
      final wlDir = Directory('${dir.path}${Platform.pathSeparator}wl');
      wlDir.createSync(recursive: true);
      final wlFile = File(
        '${wlDir.path}${Platform.pathSeparator}${MpvWatchLaterSync.md5FileName(url)}',
      );
      wlFile.writeAsStringSync('sid=1\nstart=30\n');

      await service.launch(
        entries: const [
          MediaEntry(url: url),
          MediaEntry(url: 'http://h/dav/02.mp4'),
        ],
        resumeSeconds: 120,
      );
      final content = await wlFile.readAsString();
      expect(content, contains('sid=1'), reason: '其他记录应保留');
      expect(content, contains('start=120'), reason: 'start 行应更新');
      expect(content.contains('start=30'), isFalse);
    });
  });
}
