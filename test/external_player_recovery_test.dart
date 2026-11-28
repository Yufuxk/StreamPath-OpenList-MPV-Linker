import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/profile_credential_store.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/connection_config.dart';
import 'package:streampath/data/models/episode_network_failure_mode.dart';
import 'package:streampath/data/models/video_queue.dart';
import 'package:streampath/data/models/media_entry.dart';
import 'package:streampath/data/models/openlist_recovery_config.dart';
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/data/models/server_profile.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/domain/services/external_player_service.dart';
import 'package:streampath/domain/services/openlist_process_restart_service.dart';
import 'package:streampath/domain/services/openlist_recovery_service.dart';
import 'package:streampath/domain/services/player_process_controller.dart';

class _RecoveryCall {
  const _RecoveryCall({
    required this.config,
    required this.mediaUrl,
    required this.webDavUsername,
    required this.webDavPassword,
    required this.forceStorageReload,
    required this.serverRestarted,
  });

  final OpenListRecoveryConfig config;
  final String mediaUrl;
  final String? webDavUsername;
  final String? webDavPassword;
  final bool forceStorageReload;
  final bool serverRestarted;
}

class _SequenceRecoveryProvider implements PlaybackLinkRecoveryProvider {
  _SequenceRecoveryProvider(this.results);

  final List<OpenListRecoveryResult> results;
  final List<_RecoveryCall> calls = [];
  int _index = 0;

  @override
  Future<OpenListRecoveryResult> prepare({
    required OpenListRecoveryConfig config,
    required String mediaUrl,
    String? webDavUsername,
    String? webDavPassword,
    bool forceStorageReload = false,
    bool serverRestarted = false,
  }) async {
    calls.add(
      _RecoveryCall(
        config: config,
        mediaUrl: mediaUrl,
        webDavUsername: webDavUsername,
        webDavPassword: webDavPassword,
        forceStorageReload: forceStorageReload,
        serverRestarted: serverRestarted,
      ),
    );
    final result = results[_index.clamp(0, results.length - 1)];
    _index++;
    return result;
  }
}

class _BlockingRecoveryProvider implements PlaybackLinkRecoveryProvider {
  final Completer<void> started = Completer<void>();
  final Completer<OpenListRecoveryResult> response =
      Completer<OpenListRecoveryResult>();

  @override
  Future<OpenListRecoveryResult> prepare({
    required OpenListRecoveryConfig config,
    required String mediaUrl,
    String? webDavUsername,
    String? webDavPassword,
    bool forceStorageReload = false,
    bool serverRestarted = false,
  }) {
    if (!started.isCompleted) started.complete();
    return response.future;
  }
}

class _RecordingRestarter implements PlaybackServerRestarter {
  final List<String> capturedBaseUrls = [];
  final List<String> restartedBaseUrls = [];
  final List<OpenListRestartDirectory> restartedDirectories = [];

  @override
  Future<bool> capture(String baseUrl) async {
    capturedBaseUrls.add(baseUrl);
    return true;
  }

  @override
  Future<OpenListProcessRestartResult> restart(
    String baseUrl, {
    OpenListRestartDirectory directory = OpenListRestartDirectory.userProfile,
  }) async {
    restartedBaseUrls.add(baseUrl);
    restartedDirectories.add(directory);
    return const OpenListProcessRestartResult(
      success: false,
      message: '测试禁止进入本机服务重启',
    );
  }
}

class _FakePlayerProcessController extends PlayerProcessController {
  _FakePlayerProcessController();

  final List<int> capturedPids = [];
  final List<int> terminationPids = [];

  @override
  Future<PlayerProcessIdentity?> capture(int pid) async {
    capturedPids.add(pid);
    return PlayerProcessIdentity(
      pid: pid,
      executablePath: r'C:\test\mpv-recovery-test.exe',
      creationTime: pid + 1,
    );
  }

  @override
  Future<PlayerProcessLiveness> probeOwned(
    PlayerProcessIdentity? expected,
  ) async {
    if (expected == null) return PlayerProcessLiveness.unknown;
    return terminationPids.contains(expected.pid)
        ? PlayerProcessLiveness.exited
        : PlayerProcessLiveness.alive;
  }

  @override
  Future<PlayerTerminationOutcome> terminateIfOwned({
    required int pid,
    required PlayerProcessIdentity? expected,
    String? ipcPipeName,
    required bool requirePipeOwner,
  }) async {
    expect(expected, isNotNull);
    expect(expected!.pid, pid);
    expect(requirePipeOwner, isTrue);
    expect(ipcPipeName, isNotNull);
    terminationPids.add(pid);
    return PlayerTerminationOutcome.alreadyExited;
  }
}

void main() {
  sqfliteFfiInit();

  const mediaUrl = 'http://a.test/dav/movie.mkv';
  const recoveryA = OpenListRecoveryConfig(
    enabled: true,
    baseUrl: 'http://127.0.0.1:5244',
    token: 'token-a',
    restartDirectory: OpenListRestartDirectory.installation,
  );
  const recoveryB = OpenListRecoveryConfig(
    enabled: true,
    baseUrl: 'http://127.0.0.1:6244',
    token: 'token-b',
  );

  Future<String> createLongRunningFakeMpv(Directory directory) async {
    final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final source = File(p.join(systemRoot, 'System32', 'cmd.exe'));
    final target = File(p.join(directory.path, 'mpv-recovery-test.exe'));
    await source.copy(target.path);
    return target.path;
  }

  PlayerConfig playerConfig(String executable, String marker) => PlayerConfig(
    name: 'mpv-$marker',
    executable: executable,
    args: <String>[
      '/d',
      '/s',
      '/c',
      'ping -n 8 127.0.0.1 >nul & rem {url}',
      '--launch-context=$marker',
    ],
    subtitleInjectionEnabled: false,
    subtitleAutoSelectEnabled: false,
    resumeEnabled: false,
    autoSeasonTransitionEnabled: false,
  );

  StreamPathConfig configFor({
    required PlayerConfig player,
    required String activeProfileId,
  }) {
    const profileA = ServerProfile(
      profileId: 'profile-a',
      name: 'A',
      serverUrl: 'http://a.test/dav',
      username: 'a-user',
      password: 'a-pass',
      openListRecovery: recoveryA,
    );
    const profileB = ServerProfile(
      profileId: 'profile-b',
      name: 'B',
      serverUrl: 'http://b.test/dav',
      username: 'b-user',
      password: 'b-pass',
      openListRecovery: recoveryB,
    );
    final active = activeProfileId == profileA.profileId ? profileA : profileB;
    return StreamPathConfig.fromParts(
      player,
      ConnectionConfig(
        baseUrl: active.serverUrl,
        username: active.username,
        password: active.password,
      ),
      openListRecovery: active.openListRecovery,
      profiles: const [profileA, profileB],
      activeProfileId: activeProfileId,
      credentialStorageMode: CredentialStorageMode.portablePlaintext,
    );
  }

  Future<void> writeFailure(
    String path,
    String epoch,
  ) => File(path).writeAsString(
    '${jsonEncode(<String, Object?>{'epoch': epoch, 'outcome': 'position', 'playlist_pos': 0, 'path': mediaUrl, 'position': 12.0, 'duration': 120.0, 'reason': 'error', 'file_error': 'simulated read failure'})}\n',
    flush: true,
  );

  final realMpv = Platform.environment['STREAMPATH_PATH_MPV'];
  for (final implicit in [false, true]) {
    for (final scenario in ['stop', 'autoSkip', 'truncated']) {
      final mode = scenario == 'autoSkip'
          ? EpisodeNetworkFailureMode.autoSkip
          : EpisodeNetworkFailureMode.stop;
      test(
        'real MPV episode network failure: ${implicit ? 'implicit' : 'legacy'} $scenario',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'sp_episode_failure_',
          );
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final origin = 'http://127.0.0.1:${server.port}';
          final progress = await PlaybackProgressService.open(
            inMemoryDatabasePath,
            factory: databaseFactoryFfi,
          );
          final store = StreamPathConfigStore.forPath(
            p.join(directory.path, 'config.json'),
            credentialStore: MemoryProfileCredentialStore({}),
          );
          final recovery = _RecordingRestarter();
          final events = <PlaybackRecoveryEvent>[];
          final updates = <VideoProgressUpdate>[];
          final activated = <int>[];
          final requests = <String>{};
          final id = 'episode-${implicit ? 'implicit' : 'legacy'}-$scenario';
          const profile = 'profile-a';
          const tracks = ['first.mkv', 'second.mkv', 'third.mkv'];
          MediaEntry entry(String path) =>
              MediaEntry(url: '$origin/$path', catalogPath: path);
          ExternalPlayerService? player;
          try {
            final clip = File(p.join(directory.path, 'sample.mkv'));
            final encode = await Process.run('ffmpeg', [
              '-loglevel',
              'error',
              '-f',
              'lavfi',
              '-i',
              'color=s=160x90:r=12',
              '-f',
              'lavfi',
              '-i',
              'anullsrc=r=48000:cl=mono',
              '-t',
              '5',
              '-c:v',
              'libx264',
              '-c:a',
              'pcm_s16le',
              clip.path,
            ]);
            expect(encode.exitCode, 0, reason: '${encode.stderr}');
            final bytes = await clip.readAsBytes();
            server.listen((request) async {
              final path = request.uri.path;
              requests.add(path);
              if (scenario == 'truncated' && path == '/first.mkv') {
                final socket = await request.response.detachSocket(
                  writeHeaders: false,
                );
                socket.write(
                  'HTTP/1.1 200 OK\r\nContent-Length: ${bytes.length}\r\n'
                  'Connection: close\r\n\r\n',
                );
                socket.add(bytes.sublist(0, bytes.length ~/ 2));
                await socket.flush();
                await socket.close();
                return;
              }
              if (path != '/third.mkv') {
                request.response.statusCode = HttpStatus.serviceUnavailable;
              } else {
                request.response.contentLength = bytes.length;
                request.response.add(bytes);
              }
              await request.response.close();
            });
            final config = configFor(
              player: PlayerConfig(
                name: 'MPV',
                executable: realMpv!,
                args: const [
                  '--no-config',
                  '--no-ytdl',
                  '--vo=null',
                  '--ao=null',
                  '--force-window=no',
                  '--keep-open=no',
                  '--cache=no',
                  '{url}',
                ],
                episodeNetworkFailureMode: mode,
                subtitleInjectionEnabled: false,
                autoSeasonTransitionEnabled: false,
              ),
              activeProfileId: profile,
            );
            await store.save(config);
            final previous = entry(tracks.first).url;
            if (scenario == 'stop') {
              await progress.saveProgress(
                url: previous,
                positionMs: 4321,
                durationMs: 120000,
                profileId: profile,
              );
            }
            player = ExternalPlayerService(
              configStore: store,
              progressService: progress,
              watchLaterDir: Directory(p.join(directory.path, 'watch-later')),
              onPlaybackRecovery: events.add,
              onVideoProgress: (update) async => updates.add(update),
              serverRestarter: recovery,
            );
            final plan = implicit
                ? ImplicitVideoPlan(
                    items: [
                      for (final track in tracks)
                        VideoQueueItem(
                          versions: [
                            VideoQueueVersion(path: track, name: track),
                          ],
                        ),
                    ],
                    index: 0,
                    prepare: (version) async =>
                        PreparedVideoItem(entry: entry(version.path)),
                    activated: (index, _) async => activated.add(index),
                  )
                : null;
            final launch = await player.launch(
              entries: implicit
                  ? [entry(tracks.first)]
                  : tracks.map(entry).toList(),
              sessionId: id,
              resumeSeconds: scenario == 'stop' ? 4 : null,
              webDavSourceUrl: origin,
              webDavSourceId: profile,
              implicitPlan: plan,
            );
            await player.waitForExitSync(
              id,
              timeout: const Duration(seconds: 22),
            );
            expect(await player.isPlayerRunning(id), isFalse);
            final failure = player.videoExitNetworkFailure(
              id,
              launchEpoch: launch.launchEpoch,
            );
            final position = await progress.getResumeProgress(
              previous,
              profileId: profile,
            );
            if (mode == EpisodeNetworkFailureMode.stop) {
              expect(requests, {'/first.mkv'});
              expect(failure?.networkAction, EpisodeNetworkFailureMode.stop);
              expect(events.map((event) => event.stage), [
                PlaybackRecoveryStage.networkStopped,
              ]);
              if (scenario == 'stop') {
                expect(failure?.positionSeconds, isNull);
                expect(position?.positionMs, 4321);
                expect(position?.durationMs, 120000);
                expect(updates, isEmpty);
                if (!implicit) {
                  await player.refreshPlaybackStatus(id);
                  expect(events, hasLength(1));
                }
              } else {
                expect(failure?.positionSeconds, inInclusiveRange(1, 4));
                expect(position?.positionMs, inInclusiveRange(1000, 4000));
                expect(updates, isNotEmpty);
                expect(updates.every((update) => !update.completed), isTrue);
              }
            } else {
              expect(requests.toList(), [
                '/first.mkv',
                '/second.mkv',
                '/third.mkv',
              ]);
              expect(events, isEmpty);
              expect(failure, isNull);
              if (implicit) expect(activated, [2]);
              expect(
                player.videoExitEofIndex(
                  id,
                  launchEpoch: launch.launchEpoch,
                  playlistPaths: tracks,
                  playlistLength: tracks.length,
                ),
                2,
              );
            }
            expect(recovery.restartedBaseUrls, isEmpty);
          } finally {
            await player?.terminateSession(id);
            await server.close(force: true);
            await progress.close();
            await directory.delete(recursive: true);
          }
        },
        skip: !Platform.isWindows || realMpv == null,
      );
    }
  }
  for (final failurePath in [
    '/first.mkv',
    '/middle.mkv',
    '/last.mkv',
    '/next.mkv',
  ]) {
    test(
      'real MPV recovers $failurePath and reaches final EOF',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'sp_http_recovery_',
        );
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final progress = await PlaybackProgressService.open(
          inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        final provider = _BlockingRecoveryProvider();
        final relaunched = Completer<PlayerLaunchResult>();
        final origin = 'http://127.0.0.1:${server.port}';
        const currentPaths = ['/first.mkv', '/middle.mkv', '/last.mkv'];
        const nextPath = '/next.mkv';
        final nextUrl = '$origin$nextPath';
        var ready = false;
        var failures = 0;
        final reads = <String>{};
        ExternalPlayerService? player;
        try {
          final clip = File(p.join(directory.path, 'sample.mkv'));
          final ffmpeg = await Process.run('ffmpeg', [
            '-loglevel',
            'error',
            '-f',
            'lavfi',
            '-i',
            'color=s=160x90:r=12',
            '-t',
            '3',
            '-c:v',
            'libx264',
            clip.path,
          ]);
          expect(ffmpeg.exitCode, 0, reason: '${ffmpeg.stderr}');
          final bytes = await clip.readAsBytes();
          server.listen((request) async {
            if (!ready && request.uri.path == failurePath) {
              failures++;
              request.response.statusCode = HttpStatus.notFound;
            } else {
              reads.add(request.uri.path);
              request.response.headers.contentType = ContentType(
                'video',
                'x-matroska',
              );
              request.response.contentLength = bytes.length;
              request.response.add(bytes);
            }
            await request.response.close();
          });
          final store = StreamPathConfigStore.forPath(
            p.join(directory.path, 'config.json'),
            credentialStore: MemoryProfileCredentialStore({}),
          );
          await store.save(
            configFor(
              player: PlayerConfig(
                name: 'MPV',
                executable: realMpv!,
                args: const [
                  '--no-config',
                  '--vo=null',
                  '--ao=null',
                  '--force-window=no',
                  '--keep-open=no',
                  '{url}',
                ],
                subtitleInjectionEnabled: false,
                autoSeasonTransitionEnabled: true,
              ),
              activeProfileId: 'profile-a',
            ),
          );
          player = ExternalPlayerService(
            configStore: store,
            progressService: progress,
            watchLaterDir: Directory(p.join(directory.path, 'watch-later')),
            linkRecoveryProvider: provider,
            serverRestarter: _RecordingRestarter(),
            onPlaybackRecovery: (event) {
              if (event.stage == PlaybackRecoveryStage.relaunched) {
                relaunched.complete(event.launchResult!);
              } else if (event.stage == PlaybackRecoveryStage.failed) {
                relaunched.completeError(StateError(event.message));
              }
            },
          );
          const id = 'real-http-recovery';
          final first = await player.launch(
            entries: [
              for (final track in currentPaths)
                MediaEntry(
                  url: '$origin$track',
                  catalogPath: track.substring(1),
                ),
            ],
            sessionId: id,
            username: 'fixture',
            password: 'fixture',
            webDavSourceUrl: origin,
            webDavSourceId: 'profile-a',
            nextSeason: SeasonPlaybackEntries(
              entries: [MediaEntry(url: nextUrl, catalogPath: 'next.mkv')],
            ),
          );
          await provider.started.future.timeout(const Duration(seconds: 25));
          expect(failures, greaterThan(0));
          reads.clear();
          ready = true;
          provider.response.complete(
            const OpenListRecoveryResult(
              outcome: OpenListRecoveryOutcome.ready,
              storageReloaded: false,
              message: 'HTTP fixture is ready',
            ),
          );
          final replacement = await relaunched.future.timeout(
            const Duration(seconds: 15),
          );
          expect(replacement.launchEpoch, isNot(first.launchEpoch));
          if (failurePath == nextPath) {
            expect(replacement.nextSeasonPlaylistPath, isNull);
          } else {
            expect(replacement.nextSeasonPlaylistPath, isNotNull);
            expect(
              replacement.nextSeasonPlaylistPath,
              isNot(first.nextSeasonPlaylistPath),
            );
          }
          await player.waitForExitSync(
            id,
            timeout: const Duration(seconds: 20),
          );
          final expectedReads = failurePath == nextPath
              ? [nextPath]
              : [
                  ...currentPaths.skip(currentPaths.indexOf(failurePath)),
                  nextPath,
                ];
          expect(reads.toList(), expectedReads);
          expect(
            player.videoExitEofIndex(
              id,
              launchEpoch: replacement.launchEpoch,
              playlistPaths: const ['next.mkv'],
              playlistLength: 1,
            ),
            0,
          );
          expect(
            player.videoExitEofIndex(
              id,
              launchEpoch: first.launchEpoch,
              playlistPaths: const ['first.mkv', 'middle.mkv', 'last.mkv'],
              playlistLength: currentPaths.length,
            ),
            isNull,
          );
          expect(
            await progress.getResumeProgress(
              '$origin$failurePath',
              profileId: 'profile-a',
            ),
            isNull,
          );
          expect(
            await progress.getResumeProgress(nextUrl, profileId: 'profile-a'),
            isNull,
          );
        } finally {
          await player?.terminateSession('real-http-recovery');
          await server.close(force: true);
          await progress.close();
          await directory.delete(recursive: true);
        }
      },
      skip: !Platform.isWindows || realMpv == null,
    );
  }

  test('连接成功后的识别不依赖恢复开关，未填后台时使用 WebDAV 地址', () async {
    final directory = Directory.systemTemp.createTempSync(
      'capture_after_connect_',
    );
    final store = StreamPathConfigStore.forPath(
      p.join(directory.path, 'config.json'),
      credentialStore: MemoryProfileCredentialStore({}),
    );
    final restarter = _RecordingRestarter();
    final service = ExternalPlayerService(
      configStore: store,
      serverRestarter: restarter,
    );
    try {
      await store.save(
        const StreamPathConfig(serverUrl: 'http://127.0.0.1:5244/dav'),
      );
      await service.captureOpenListProcessIdentity();
      expect(restarter.capturedBaseUrls, ['http://127.0.0.1:5244/dav']);
      expect(restarter.restartedBaseUrls, isEmpty);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('A 档案启动后切换 B，自动恢复仍完整使用 A 启动快照', () async {
    final directory = Directory.systemTemp.createTempSync(
      'streampath_recovery_snapshot_',
    );
    final processes = <Process>[];
    final progress = await PlaybackProgressService.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    ExternalPlayerService? service;
    try {
      final executable = await createLongRunningFakeMpv(directory);
      final store = StreamPathConfigStore.forPath(
        p.join(directory.path, 'config.json'),
        credentialStore: MemoryProfileCredentialStore({}),
      );
      await store.save(
        configFor(
          player: playerConfig(executable, 'A'),
          activeProfileId: 'profile-a',
        ),
      );
      final provider = _SequenceRecoveryProvider([
        const OpenListRecoveryResult(
          outcome: OpenListRecoveryOutcome.ready,
          storageReloaded: false,
          message: 'A 链接已恢复',
        ),
      ]);
      final restarter = _RecordingRestarter();
      final processController = _FakePlayerProcessController();
      final terminalEvent = Completer<PlaybackRecoveryEvent>();
      service = ExternalPlayerService(
        configStore: store,
        progressService: progress,
        watchLaterDir: Directory(p.join(directory.path, 'watch-later')),
        linkRecoveryProvider: provider,
        serverRestarter: restarter,
        processController: processController,
        onPlaybackRecovery: (event) {
          if (event.stage == PlaybackRecoveryStage.relaunched ||
              event.stage == PlaybackRecoveryStage.failed) {
            if (!terminalEvent.isCompleted) terminalEvent.complete(event);
          }
        },
      );

      final initial = await service.launch(
        entries: const [MediaEntry(url: mediaUrl, title: 'movie.mkv')],
        sessionId: 'snapshot-session',
        username: 'a-user',
        password: 'a-pass',
      );
      processes.add(initial.process);
      await store.save(
        configFor(
          player: playerConfig(executable, 'B'),
          activeProfileId: 'profile-b',
        ),
      );
      await writeFailure(initial.progressFilePath!, initial.launchEpoch);

      final event = await terminalEvent.future.timeout(
        const Duration(seconds: 12),
      );
      expect(event.stage, PlaybackRecoveryStage.relaunched);
      final relaunched = event.launchResult!;
      processes.add(relaunched.process);
      expect(provider.calls, hasLength(1));
      expect(provider.calls.single.config.baseUrl, recoveryA.baseUrl);
      expect(provider.calls.single.webDavUsername, 'a-user');
      expect(provider.calls.single.webDavPassword, 'a-pass');
      expect(relaunched.args, contains('--launch-context=A'));
      expect(relaunched.args, isNot(contains('--launch-context=B')));
      expect(
        relaunched.args.any(
          (argument) => argument.contains('http://a-user:a-pass@a.test/'),
        ),
        isTrue,
      );

      await File(relaunched.progressFilePath!).writeAsString(
        '${jsonEncode(<String, Object?>{'epoch': relaunched.launchEpoch, 'outcome': 'position', 'playlist_pos': 0, 'path': mediaUrl, 'position': 42.0, 'duration': 120.0, 'reason': 'quit'})}\n',
        flush: true,
      );
      await service.syncActiveProgress('snapshot-session');
      final progressA = await progress.getProgress(
        mediaUrl,
        profileId: 'profile-a',
      );
      final progressB = await progress.getProgress(
        mediaUrl,
        profileId: 'profile-b',
      );
      expect(progressA?.positionMs, 42000);
      expect(progressB, isNull);
      expect(restarter.restartedBaseUrls, isEmpty);
      expect(
        provider.calls.single.config.restartDirectory,
        OpenListRestartDirectory.installation,
      );
      expect(restarter.capturedBaseUrls, isNot(contains(recoveryB.baseUrl)));
    } finally {
      for (final process in processes) {
        process.kill();
      }
      await service?.waitForExitSync(
        'snapshot-session',
        timeout: const Duration(seconds: 5),
      );
      await service?.terminateSession('snapshot-session');
      await progress.close();
      try {
        await directory.delete(recursive: true);
      } catch (_) {}
    }
  }, skip: !Platform.isWindows);

  test('第三次重启使用启动快照中的目录模式', () async {
    final directory = Directory.systemTemp.createTempSync(
      'streampath_recovery_snapshot_',
    );
    final processes = <Process>[];
    final progress = await PlaybackProgressService.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    ExternalPlayerService? service;
    try {
      final executable = await createLongRunningFakeMpv(directory);
      final store = StreamPathConfigStore.forPath(
        p.join(directory.path, 'config.json'),
        credentialStore: MemoryProfileCredentialStore({}),
      );
      await store.save(
        configFor(
          player: playerConfig(executable, 'A'),
          activeProfileId: 'profile-a',
        ),
      );
      final provider = _SequenceRecoveryProvider([
        for (var i = 0; i < 2; i++)
          const OpenListRecoveryResult(
            outcome: OpenListRecoveryOutcome.retryableFailure,
            storageReloaded: false,
            message: 'simulated failure',
          ),
      ]);
      final restarter = _RecordingRestarter();
      final processController = _FakePlayerProcessController();
      final terminalEvent = Completer<PlaybackRecoveryEvent>();
      service = ExternalPlayerService(
        configStore: store,
        progressService: progress,
        watchLaterDir: Directory(p.join(directory.path, 'watch-later')),
        linkRecoveryProvider: provider,
        serverRestarter: restarter,
        processController: processController,
        onPlaybackRecovery: (event) {
          if (event.stage == PlaybackRecoveryStage.relaunched ||
              event.stage == PlaybackRecoveryStage.failed) {
            if (!terminalEvent.isCompleted) terminalEvent.complete(event);
          }
        },
      );

      final initial = await service.launch(
        entries: const [MediaEntry(url: mediaUrl, title: 'movie.mkv')],
        sessionId: 'snapshot-session',
        username: 'a-user',
        password: 'a-pass',
      );
      processes.add(initial.process);
      await store.save(
        configFor(
          player: playerConfig(executable, 'B'),
          activeProfileId: 'profile-b',
        ),
      );
      await writeFailure(initial.progressFilePath!, initial.launchEpoch);

      final event = await terminalEvent.future.timeout(
        const Duration(seconds: 12),
      );
      expect(event.stage, PlaybackRecoveryStage.failed);
      expect(restarter.restartedBaseUrls, [recoveryA.baseUrl]);
      expect(restarter.restartedDirectories, [
        OpenListRestartDirectory.installation,
      ]);
    } finally {
      for (final process in processes) {
        process.kill();
      }
      await service?.waitForExitSync(
        'snapshot-session',
        timeout: const Duration(seconds: 5),
      );
      await service?.terminateSession('snapshot-session');
      await progress.close();
      try {
        await directory.delete(recursive: true);
      } catch (_) {}
    }
  }, skip: !Platform.isWindows);

  test('第二次判定媒体可读时停止恢复且不进入第三次本机重启', () async {
    final directory = Directory.systemTemp.createTempSync(
      'streampath_recovery_terminal_',
    );
    final processes = <Process>[];
    ExternalPlayerService? service;
    try {
      final executable = await createLongRunningFakeMpv(directory);
      final store = StreamPathConfigStore.forPath(
        p.join(directory.path, 'config.json'),
        credentialStore: MemoryProfileCredentialStore({}),
      );
      await store.save(
        configFor(
          player: playerConfig(executable, 'A'),
          activeProfileId: 'profile-a',
        ),
      );
      final provider = _SequenceRecoveryProvider([
        const OpenListRecoveryResult(
          outcome: OpenListRecoveryOutcome.retryableFailure,
          storageReloaded: false,
          message: '第一次取链仍失败',
        ),
        const OpenListRecoveryResult(
          outcome: OpenListRecoveryOutcome.terminalNotLinkFailure,
          storageReloaded: false,
          message: '媒体已可读取，错误不属于链接失效',
        ),
      ]);
      final restarter = _RecordingRestarter();
      final terminalEvent = Completer<PlaybackRecoveryEvent>();
      service = ExternalPlayerService(
        configStore: store,
        linkRecoveryProvider: provider,
        serverRestarter: restarter,
        processController: _FakePlayerProcessController(),
        onPlaybackRecovery: (event) {
          if (event.stage == PlaybackRecoveryStage.failed &&
              !terminalEvent.isCompleted) {
            terminalEvent.complete(event);
          }
        },
      );

      final initial = await service.launch(
        entries: const [MediaEntry(url: mediaUrl, title: 'movie.mkv')],
        sessionId: 'terminal-session',
        username: 'a-user',
        password: 'a-pass',
      );
      processes.add(initial.process);
      await writeFailure(initial.progressFilePath!, initial.launchEpoch);

      final event = await terminalEvent.future.timeout(
        const Duration(seconds: 12),
      );
      expect(provider.calls, hasLength(2));
      expect(provider.calls[0].forceStorageReload, isFalse);
      expect(provider.calls[1].forceStorageReload, isTrue);
      expect(restarter.restartedBaseUrls, isEmpty);
      expect(event.message, contains('不属于链接失效'));
    } finally {
      await service?.terminateSession('terminal-session');
      for (final process in processes) {
        process.kill();
      }
      try {
        await directory.delete(recursive: true);
      } catch (_) {}
    }
  }, skip: !Platform.isWindows);

  test('旧恢复等待取链时同 session 手动新启动不会被旧结果覆盖', () async {
    final directory = Directory.systemTemp.createTempSync(
      'streampath_recovery_ownership_',
    );
    final processes = <Process>[];
    ExternalPlayerService? service;
    final provider = _BlockingRecoveryProvider();
    try {
      final executable = await createLongRunningFakeMpv(directory);
      final store = StreamPathConfigStore.forPath(
        p.join(directory.path, 'config.json'),
        credentialStore: MemoryProfileCredentialStore({}),
      );
      await store.save(
        configFor(
          player: playerConfig(executable, 'A'),
          activeProfileId: 'profile-a',
        ),
      );
      final controller = _FakePlayerProcessController();
      final recoveryEvents = <PlaybackRecoveryEvent>[];
      service = ExternalPlayerService(
        configStore: store,
        linkRecoveryProvider: provider,
        serverRestarter: _RecordingRestarter(),
        processController: controller,
        onPlaybackRecovery: recoveryEvents.add,
      );
      final initial = await service.launch(
        entries: const [MediaEntry(url: mediaUrl, title: 'movie.mkv')],
        sessionId: 'ownership-session',
      );
      processes.add(initial.process);
      await writeFailure(initial.progressFilePath!, initial.launchEpoch);
      await provider.started.future.timeout(const Duration(seconds: 12));

      final manual = await service.launch(
        entries: const [MediaEntry(url: mediaUrl, title: 'movie.mkv')],
        sessionId: 'ownership-session',
      );
      processes.add(manual.process);
      provider.response.complete(
        const OpenListRecoveryResult(
          outcome: OpenListRecoveryOutcome.ready,
          storageReloaded: false,
          message: '旧取链结果',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(controller.capturedPids, hasLength(2), reason: '旧恢复不得再启动第三个进程');
      expect(
        recoveryEvents.where(
          (event) => event.stage == PlaybackRecoveryStage.relaunched,
        ),
        isEmpty,
      );
      await service.sendPause('ownership-session');
      expect(await File(manual.commandFilePath!).readAsString(), 'pause');
      expect(manual.launchEpoch, isNot(initial.launchEpoch));
    } finally {
      if (!provider.response.isCompleted) {
        provider.response.complete(
          const OpenListRecoveryResult(
            outcome: OpenListRecoveryOutcome.terminalNotLinkFailure,
            storageReloaded: false,
            message: '测试结束',
          ),
        );
      }
      await service?.terminateSession('ownership-session');
      for (final process in processes) {
        process.kill();
      }
      try {
        await directory.delete(recursive: true);
      } catch (_) {}
    }
  }, skip: !Platform.isWindows);
}
