import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:streampath/data/local/directory_cache.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/profile_credential_store.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/connection_config.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/film_watch_state.dart';
import 'package:streampath/data/models/media_entry.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/openlist_recovery_config.dart';
import 'package:streampath/data/models/playback_history.dart';
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/data/models/server_profile.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/data/models/video_playlist_mode.dart';
import 'package:streampath/data/models/video_queue.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/data/remote/webdav_client.dart';
import 'package:streampath/domain/services/external_player_service.dart';
import 'package:streampath/domain/services/mpv_watch_later_sync.dart';
import 'package:streampath/domain/services/openlist_recovery_service.dart';
import 'package:streampath/domain/services/player_process_controller.dart';
import 'package:streampath/domain/services/webdav_service.dart';
import 'package:streampath/presentation/pages/app_shell_page.dart';
import 'package:streampath/presentation/pages/browser_page.dart';
import 'package:streampath/presentation/pages/film_detail_page.dart';
import 'package:streampath/presentation/pages/global_media_library_page.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/widgets/film_continue_card.dart';

import 'helpers/pump_until.dart';
import 'helpers/shell_test_app_state.dart';

const _profile = 'recovery-source';
const _base = 'http://127.0.0.1:1/dav';
const _url = '$_base/Movie.mkv';
const _nextUrl = '$_base/Next.mkv';
const _id = 'recovery-movie';

class _Recovery implements PlaybackLinkRecoveryProvider {
  final requested = Completer<void>();
  final result = Completer<OpenListRecoveryResult>();

  @override
  Future<OpenListRecoveryResult> prepare({
    required OpenListRecoveryConfig config,
    required String mediaUrl,
    String? webDavUsername,
    String? webDavPassword,
    bool forceStorageReload = false,
    bool serverRestarted = false,
  }) {
    expect(mediaUrl, _url);
    requested.complete();
    return result.future;
  }

  void succeed() => result.complete(
    const OpenListRecoveryResult(
      outcome: OpenListRecoveryOutcome.ready,
      storageReloaded: false,
      message: 'Fixture link restored',
    ),
  );
}

class _Processes extends PlayerProcessController {
  final exited = <int>{};

  @override
  Future<PlayerProcessIdentity> capture(int pid) async => PlayerProcessIdentity(
    pid: pid,
    executablePath: 'fixture_mpv.exe',
    creationTime: pid,
  );

  @override
  Future<PlayerProcessLiveness> probeOwned(
    PlayerProcessIdentity? expected,
  ) async => exited.contains(expected!.pid)
      ? PlayerProcessLiveness.exited
      : PlayerProcessLiveness.alive;

  @override
  Future<PlayerTerminationOutcome> terminateIfOwned({
    required int pid,
    required PlayerProcessIdentity? expected,
    String? ipcPipeName,
    required bool requirePipeOwner,
  }) async {
    exited.add(pid);
    return PlayerTerminationOutcome.alreadyExited;
  }
}

class _Player extends ExternalPlayerService {
  _Player({
    required this.config,
    required this.processes,
    required this.recovery,
    required this.events,
    super.progressService,
    super.watchLaterDir,
    super.onVideoProgress,
    super.videoResetBefore,
  }) : super(
         configStore: config,
         processController: processes,
         linkRecoveryProvider: recovery,
         onPlaybackRecovery: events.add,
       );

  final StreamPathConfigStore config;
  final _Processes processes;
  final _Recovery recovery;
  final StreamController<PlaybackRecoveryEvent> events;
  Completer<bool>? delayedProbe;
  final probing = Completer<void>();

  @override
  ExternalPlayerService forFilmLibrary(
    PlaybackProgressService progress,
    Directory watchLater,
  ) => _Player(
    config: config,
    processes: processes,
    recovery: recovery,
    events: events,
    progressService: progress,
    watchLaterDir: watchLater,
    onVideoProgress: onVideoProgress,
    videoResetBefore: videoResetBefore,
  );

  @override
  Future<bool> isPlayerRunning([String? sessionId]) {
    final delayed = delayedProbe;
    if (delayed != null) {
      delayedProbe = null;
      probing.complete();
      return delayed.future;
    }
    return super.isPlayerRunning(sessionId);
  }
}

class _App extends ShellTestAppState {
  _App({
    required super.configStore,
    required super.playbackHistoryStore,
    required super.progressService,
    required super.mediaLibraryStore,
    required super.playerService,
    required super.directoryCache,
    required this.recoveryEvents,
  });

  final Stream<PlaybackRecoveryEvent> recoveryEvents;

  @override
  Stream<PlaybackRecoveryEvent> get playbackRecoveryEvents => recoveryEvents;

  @override
  bool isProfileConnected(String profileId) => profileId == _profile;
}

Future<void> _append(
  PlayerLaunchResult result, {
  required String reason,
  required num position,
  String? epoch,
  bool networkStop = false,
}) async {
  final record = {
    'epoch': epoch ?? result.launchEpoch,
    'outcome': reason == 'eof' ? 'completed' : 'position',
    'playlist_pos': 0,
    'path': _url,
    'position': position,
    'duration': 600,
    'reason': reason,
    if (networkStop) 'network_action': 'stop',
    'queue_generation': 0,
    'recorded_at': DateTime.now().millisecondsSinceEpoch,
  };
  await File(result.progressFilePath!).writeAsString(
    '${jsonEncode(record)}\n',
    mode: FileMode.append,
    flush: true,
  );
}

Future<T> _withFrames<T>(
  WidgetTester tester,
  Future<T> Function() action,
) async {
  late Future<T> operation;
  var done = false;
  await tester.runAsync(() async {
    operation = action().whenComplete(() => done = true);
  });
  await pumpUntil(tester, () => done, reason: 'Playback I/O settles');
  return (await tester.runAsync(() => operation)) as T;
}

void main() {
  testWidgets('应用外壳在当前页显示一次网络停止提示', (tester) async {
    final events = StreamController<PlaybackRecoveryEvent>.broadcast();
    final (directory, app) = (await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp(
        'sp_network_notice_',
      );
      final config = StreamPathConfigStore.forPath(
        p.join(directory.path, 'config.json'),
        credentialStore: MemoryProfileCredentialStore({}),
      );
      final app = _App(
        configStore: config,
        playbackHistoryStore: PlaybackHistoryStore.forPath(
          p.join(directory.path, 'history.json'),
        ),
        progressService: await PlaybackProgressService.open(
          p.join(directory.path, 'progress.db'),
        ),
        mediaLibraryStore: MediaLibraryStore.forPath(
          p.join(directory.path, 'records.json'),
        ),
        playerService: ExternalPlayerService(configStore: config),
        directoryCache: DirectoryCache(
          boxOpener: (name) => Hive.openBox<Map>(name, path: directory.path),
        ),
        recoveryEvents: events.stream,
      );
      await app.directoryCache.init();
      await app.getFilmCatalog();
      return (directory, app);
    }))!;
    try {
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: app,
          child: const MaterialApp(home: AppShellPage()),
        ),
      );
      await tester.pump();
      const message = '网络连接异常，播放已停止';
      events.add(
        PlaybackRecoveryEvent(
          player: app.playerService,
          sessionId: _id,
          launchEpoch: 'fixture',
          stage: PlaybackRecoveryStage.networkStopped,
          message: message,
        ),
      );
      await pumpUntil(
        tester,
        () => find.text(message).evaluate().length == 1,
        reason: 'The shell shows one network stop notice',
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text(message), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await events.close();
        app.dispose();
        await app.closeTestStores();
        await app.directoryCache.close();
        await app.progressService.close();
        await directory.delete(recursive: true);
      });
    }
  });

  for (final scenario in [
    'eof',
    'quit',
    'failed-recovery',
    'stop-at-98.9%',
    'stop-at-99%',
  ]) {
    final eof = scenario == 'eof';
    final networkStop = scenario.startsWith('stop-at-');
    final reachedThreshold = scenario == 'stop-at-99%';
    final implicit = scenario == 'quit' || reachedThreshold;
    testWidgets(
      'network movie keeps both pages consistent after $scenario',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final events = StreamController<PlaybackRecoveryEvent>.broadcast();
        final recovery = _Recovery();
        final processes = _Processes();
        PlayerLaunchResult? second;
        final eventSub = events.stream.listen((event) {
          if (event.stage == PlaybackRecoveryStage.relaunched) {
            second = event.launchResult;
          }
        });
        final (
          dir,
          app,
          catalog,
          resource,
          first,
          webdav,
        ) = (await tester.runAsync(() async {
          final dir = await Directory.systemTemp.createTemp(
            'sp_recovered_movie_',
          );
          final exe = await File(
            p.join(
              Platform.environment['SystemRoot'] ?? r'C:\Windows',
              'System32',
              'cmd.exe',
            ),
          ).copy(p.join(dir.path, 'fixture_mpv.exe'));
          final config = StreamPathConfigStore.forPath(
            p.join(dir.path, 'config.json'),
            credentialStore: MemoryProfileCredentialStore({}),
          );
          const recoveryConfig = OpenListRecoveryConfig(
            enabled: true,
            baseUrl: 'http://127.0.0.1:1',
            token: 'fixture',
          );
          await config.save(
            StreamPathConfig.fromParts(
              PlayerConfig(
                name: 'MPV',
                executable: exe.path,
                args: [
                  '/d',
                  '/s',
                  '/c',
                  'ping -n 50 127.0.0.1 >nul & rem {url}',
                ],
                subtitleInjectionEnabled: false,
                resumeEnabled: false,
                autoSeasonTransitionEnabled: false,
              ),
              const ConnectionConfig(
                baseUrl: _base,
                username: '',
                password: '',
              ),
              openListRecovery: recoveryConfig,
              activeProfileId: _profile,
              mountedProfileIds: const [_profile],
              profiles: const [
                ServerProfile(
                  profileId: _profile,
                  name: 'Fixture',
                  serverUrl: _base,
                  openListRecovery: recoveryConfig,
                ),
              ],
            ),
          );
          final player = eof
              ? _Player(
                  config: config,
                  processes: processes,
                  recovery: recovery,
                  events: events,
                )
              : ExternalPlayerService(
                  configStore: config,
                  processController: processes,
                  linkRecoveryProvider: recovery,
                  onPlaybackRecovery: events.add,
                );
          final directoryCache = DirectoryCache(
            boxOpener: (name) => Hive.openBox<Map>(name, path: dir.path),
          );
          await directoryCache.init();
          directoryCache.write(
            'fixture-root',
            [
              const WebDavFile(
                name: 'Movie.mkv',
                href: _url,
                isDirectory: false,
              ),
              if (networkStop)
                const WebDavFile(
                  name: 'Next.mkv',
                  href: _nextUrl,
                  isDirectory: false,
                ),
            ],
            sourceId: _profile,
            path: '',
          );
          final app = _App(
            configStore: config,
            playerService: player,
            recoveryEvents: events.stream,
            directoryCache: directoryCache,
            playbackHistoryStore: PlaybackHistoryStore.forPath(
              p.join(dir.path, 'history.json'),
            ),
            progressService: await PlaybackProgressService.open(
              p.join(dir.path, 'progress.db'),
            ),
            mediaLibraryStore: MediaLibraryStore.forPath(
              p.join(dir.path, 'records.json'),
            ),
          );
          final catalog = await app.getFilmCatalog();
          await app.initializeFilmPlayback();
          final rootId = await catalog.store.addRoot(
            sourceId: _profile,
            kind: MediaSourceKind.webdav,
            path: '',
            type: FilmMediaType.movie,
            name: 'Fixture',
          );
          final scan = await catalog.store.beginScan(rootId);
          await catalog.store
              .stage((await catalog.store.root(rootId))!, scan, const [
                FilmScanEntry(
                  path: 'Movie.mkv',
                  parentPath: '',
                  name: 'Movie.mkv',
                  mediaKind: 'video',
                ),
              ]);
          await catalog.store.commitScan(rootId, scan, cancelled: () => false);
          await catalog.store.bind(
            await catalog.store.resources(),
            const FilmWork(
              type: FilmMediaType.movie,
              tmdbId: 1,
              title: 'Movie',
              originalTitle: 'Movie',
              overview: '',
              language: 'en',
              metadata: {'presentation_version': 3},
            ),
          );
          final resource = (await catalog.store.resources()).single;
          final webdav = WebDAVService(
            client: WebDavClient(baseUrl: _base),
            profileId: _profile,
          );
          const entry = MediaEntry(
            url: _url,
            title: 'Movie.mkv',
            catalogPath: 'Movie.mkv',
          );
          const next = MediaEntry(url: _nextUrl, catalogPath: 'Next.mkv');
          final queue = [
            const VideoQueueItem(
              versions: [
                VideoQueueVersion(path: 'Movie.mkv', name: 'Movie.mkv'),
              ],
            ),
            if (networkStop)
              const VideoQueueItem(
                versions: [
                  VideoQueueVersion(path: 'Next.mkv', name: 'Next.mkv'),
                ],
              ),
          ];
          final playlist = ['Movie.mkv', if (networkStop) 'Next.mkv'];
          final first = await app.filmPlayerService.launch(
            entries: [entry, if (networkStop && !implicit) next],
            sessionId: _id,
            webDavSourceUrl: _base,
            webDavSourceId: _profile,
            implicitPlan: implicit
                ? ImplicitVideoPlan(
                    items: queue,
                    index: 0,
                    prepare: (version) async => PreparedVideoItem(
                      entry: version.path == next.catalogPath ? next : entry,
                    ),
                    activated: (_, _) async {},
                  )
                : null,
          );
          await app.filmPlaybackHistoryStore.upsert(
            PlaybackHistory(
              dirCrumbs: const [],
              fileName: 'Movie.mkv',
              videoIndex: 0,
              updatedAt: DateTime.now(),
              sessionId: _id,
              sourceId: _profile,
              playlistFileNames: playlist,
              playlistRelativePaths: playlist,
              playerPid: first.process.pid,
              ipcPipeName: first.ipcPipeName,
              playerExecutablePath: first.processIdentity!.executablePath,
              playerCreationTime: first.processIdentity!.creationTime,
              launchEpoch: first.launchEpoch,
              videoPlaylistMode: implicit
                  ? VideoPlaylistMode.implicit
                  : VideoPlaylistMode.legacy,
              queueItems: implicit ? queue : const [],
            ),
          );
          await app.filmMediaLibraryStore!.recordPlayback(
            resource.playbackItem,
            playbackSessionId: _id,
          );
          await app.filmProgressService.saveProgress(
            url: _url,
            profileId: _profile,
            positionMs: 10000,
            durationMs: 600000,
          );
          return (dir, app, catalog, resource, first, webdav);
        }))!;
        try {
          await tester.pumpWidget(
            ChangeNotifierProvider<AppState>.value(
              value: app,
              child: MaterialApp(
                home: Stack(
                  children: [
                    Offstage(
                      child: BrowserPage(
                        playbackOnly: true,
                        webDavSource: webdav,
                      ),
                    ),
                    Offstage(
                      child: GlobalMediaLibraryPage(
                        filmCatalog: catalog,
                        onOpenItem: (_) async {},
                      ),
                    ),
                    FilmDetailPage(
                      catalog: catalog,
                      workId: resource.workId!,
                      onOpenItem: (_) async {},
                    ),
                  ],
                ),
              ),
            ),
          );
          final homeCards = find.descendant(
            of: find.byType(GlobalMediaLibraryPage, skipOffstage: false),
            matching: find.byType(FilmContinueCard, skipOffstage: false),
            skipOffstage: false,
          );
          await pumpUntil(
            tester,
            () => homeCards.evaluate().length == 1,
            reason: 'Initial resume card is visible',
          );
          expect(find.text('继续播放'), findsOneWidget);
          if (networkStop) {
            final position = reachedThreshold ? 594.0 : 593.4;
            await tester.runAsync(() async {
              await _append(
                first,
                reason: 'error',
                position: position,
                networkStop: true,
              );
              processes.exited.add(first.process.pid);
            });
            await pumpUntil(
              tester,
              () =>
                  app.filmPlaybackHistoryStore.sessions.single.playerPid ==
                  null,
              reason: 'Network stop keeps the history and clears the player',
            );
            final (progress, records) = await _withFrames(
              tester,
              () async => (
                await app.filmProgressService.getResumeProgress(
                  _url,
                  profileId: _profile,
                ),
                await app.filmMediaLibraryStore!.playbackHistory(
                  _profile,
                  audio: false,
                ),
              ),
            );
            final history = app.filmPlaybackHistoryStore.sessions.single;
            expect(history.videoIndex, reachedThreshold ? 1 : 0);
            expect(
              history.fileName,
              reachedThreshold ? 'Next.mkv' : 'Movie.mkv',
            );
            expect(history.ipcPipeName, isNull);
            expect(progress?.positionMs, (position * 1000).round());
            expect(records.any((record) => record.continueCompleted), isFalse);
            expect(recovery.requested.isCompleted, isFalse);
            expect(second, isNull);
            expect(tester.takeException(), isNull);
            return;
          }
          final delayedProbe = Completer<bool>();
          if (eof) {
            final player = app.filmPlayerService as _Player;
            player.delayedProbe = delayedProbe;
            await pumpUntil(
              tester,
              () => player.probing.isCompleted,
              reason: 'The old browser probe is in flight before recovery',
            );
          }
          await tester.runAsync(() async {
            await _append(first, reason: 'error', position: 12);
            if (!eof) processes.exited.add(first.process.pid);
          });
          await pumpUntil(
            tester,
            () => recovery.requested.isCompleted,
            reason: 'MPV read error reaches link recovery',
          );
          if (scenario == 'failed-recovery') {
            recovery.result.complete(
              const OpenListRecoveryResult(
                outcome: OpenListRecoveryOutcome.terminalFailure,
                storageReloaded: false,
                message: 'Fixture link is unavailable',
              ),
            );
            await pumpUntil(
              tester,
              () =>
                  app.filmPlaybackHistoryStore.sessions.single.playerPid ==
                  null,
              reason: 'Failed recovery clears the exited player identity',
            );
            final (progress, records) = await _withFrames(
              tester,
              () async => (
                await app.filmProgressService.getResumeProgress(
                  _url,
                  profileId: _profile,
                ),
                await app.filmMediaLibraryStore!.playbackHistory(
                  _profile,
                  audio: false,
                ),
              ),
            );
            expect(second, isNull);
            expect(progress?.positionMs, 12000);
            expect(records.single.continueCompleted, isFalse);
            expect(find.text('继续播放'), findsOneWidget);
            expect(homeCards, findsOneWidget);
            return;
          }
          await tester.runAsync(() async => recovery.succeed());
          await pumpUntil(
            tester,
            () => second != null,
            reason: 'Service launches the replacement MPV',
          );
          final replacement = second!;
          expect(replacement.launchEpoch, isNot(first.launchEpoch));
          await pumpUntil(
            tester,
            () =>
                app
                    .filmPlaybackHistoryStore
                    .sessions
                    .singleOrNull
                    ?.launchEpoch ==
                replacement.launchEpoch,
            reason: 'The recovered launch identity reaches playback history',
          );
          final history = app.filmPlaybackHistoryStore.sessions.single;
          expect(history.playerPid, replacement.process.pid);
          expect(history.ipcPipeName, replacement.ipcPipeName);
          delayedProbe.complete(false);
          await tester.runAsync(() async {
            final lines = ['0', _url, '0', '125', '600'];
            if (implicit) {
              while (lines.length < 26) {
                lines.add('0');
              }
              lines[25] = '1';
            }
            await File(
              replacement.statusFilePath!,
            ).writeAsString(lines.join('\n'), flush: true);
          });
          await pumpUntil(
            tester,
            () =>
                homeCards.evaluate().length == 1 &&
                tester.widget<FilmContinueCard>(homeCards).positionMs == 125000,
            reason:
                'Replacement status file drives live progress on the home card',
          );
          await tester.runAsync(() async {
            final watchLater = await Directory(
              p.join(dir.path, 'film_mpv_watch_later'),
            ).create();
            final oldProgress = await File(
              p.join(watchLater.path, MpvWatchLaterSync.md5FileName(_url)),
            ).writeAsString('start=42\nduration=600\n');
            await oldProgress.setLastModified(
              DateTime.fromMicrosecondsSinceEpoch(
                int.parse(first.launchEpoch.split('_').first),
              ),
            );
            await _append(
              replacement,
              reason: 'eof',
              position: 600,
              epoch: first.launchEpoch,
            );
            await _append(
              replacement,
              reason: eof ? 'eof' : 'quit',
              position: eof ? 600 : 125,
            );
            processes.exited.add(replacement.process.pid);
          });
          await pumpUntil(
            tester,
            () =>
                app.filmPlaybackHistoryStore.sessions.singleOrNull?.playerPid ==
                null,
            reason: 'Current launch exit clears the active player identity',
          );
          final (watch, progress, normal, records) = await _withFrames(
            tester,
            () async => (
              (await catalog.store.resourceWatchStates([
                resource,
              ]))[resource.id],
              await app.filmProgressService.getResumeProgress(
                _url,
                profileId: _profile,
              ),
              await app.progressService.getResumeProgress(
                _url,
                profileId: _profile,
              ),
              await app.filmMediaLibraryStore!.playbackHistory(
                _profile,
                audio: false,
              ),
            ),
          );
          expect(
            watch!.status,
            eof ? FilmWatchStatus.watched : FilmWatchStatus.inProgress,
          );
          expect(progress?.positionMs, eof ? null : 125000);
          expect(normal, isNull);
          expect(records.single.continueCompleted, eof);
          await pumpUntil(
            tester,
            () =>
                (eof ? find.text('开始播放') : find.text('继续播放'))
                    .evaluate()
                    .length ==
                1,
            reason: 'The mounted detail page reflects the current exit',
          );
          expect(homeCards, eof ? findsNothing : findsOneWidget);
          expect(app.filmPlaybackHistoryStore.sessions, hasLength(eof ? 0 : 1));
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await _withFrames(tester, () async {
            if (!recovery.result.isCompleted) recovery.succeed();
            first.process.kill();
            second?.process.kill();
            await app.filmPlayerService.terminateSession(_id);
            await eventSub.cancel();
            await events.close();
            app.dispose();
            await app.closeTestStores();
            await app.directoryCache.close();
            await app.progressService.close();
            await dir.delete(recursive: true);
          });
        }
      },
      skip: !Platform.isWindows,
    );
  }
}
