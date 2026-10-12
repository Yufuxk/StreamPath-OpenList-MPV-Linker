import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/core/utils/app_paths.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/video_queue.dart';
import 'package:streampath/domain/services/external_player_service.dart';
import 'package:streampath/domain/services/player_process_controller.dart';
import 'package:streampath/presentation/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('关闭等待保留已结束的滚动队列，不向空 IPC 发送消息', () async {
    final fixture = await _ClosedQueueFixture.create();
    try {
      await expectLater(fixture.app.prepareForClose(), completes);
      await expectLater(fixture.app.prepareForClose(), completes);
      expect(await fixture.queue.readAsString(), fixture.queueContents);
      expect(await fixture.entries.exists(), isTrue);
    } finally {
      await fixture.close();
    }
  });

  test('恢复已结束的滚动队列不接管播放或准备下一集', () async {
    final fixture = await _ClosedQueueFixture.create();
    var prepared = false;
    var activated = false;
    try {
      await expectLater(
        fixture.app.playerService.attachImplicitPlan(
          fixture.sessionId,
          ImplicitVideoPlan(
            items: const [
              VideoQueueItem(
                versions: [
                  VideoQueueVersion(path: 'Show/E1.mkv', name: 'E1.mkv'),
                ],
              ),
            ],
            index: 0,
            prepare: (_) async {
              prepared = true;
              throw StateError('Closed session must not prepare media');
            },
            activated: (_, _) async => activated = true,
          ),
        ),
        completes,
      );
      expect(prepared, isFalse);
      expect(activated, isFalse);
      expect(await fixture.queue.readAsString(), fixture.queueContents);
      await expectLater(fixture.app.prepareForClose(), completes);
    } finally {
      await fixture.close();
    }
  });

  test('已退出进程残留 IPC 名称时关闭不等待连接超时', () async {
    final fixture = await _ClosedQueueFixture.create(stalePipe: true);
    try {
      final watch = Stopwatch()..start();
      await fixture.app.prepareForClose();
      watch.stop();
      expect(watch.elapsedMilliseconds, lessThan(1000));
      expect(await fixture.queue.readAsString(), fixture.queueContents);
    } finally {
      await fixture.close();
    }
  });

  test('刚结束的播放器不沿用缓存的存活状态等待 IPC', () async {
    var exited = false;
    final fixture = await _ClosedQueueFixture.create(
      stalePipe: true,
      snapshotLoader: (_) async => exited
          ? const PlayerProcessLookupResult.notFound()
          : PlayerProcessLookupResult.found(
              PlayerProcessIdentity(
                pid: 2147483640,
                executablePath: r'C:\fixtures\ended-mpv.exe',
                creationTime: 1,
              ),
            ),
    );
    try {
      expect(
        await fixture.app.playerService.isPlayerRunning(fixture.sessionId),
        isTrue,
      );
      exited = true;
      final watch = Stopwatch()..start();
      await fixture.app.prepareForClose();
      expect(watch.elapsedMilliseconds, lessThan(1000));
      expect(await fixture.queue.readAsString(), fixture.queueContents);
    } finally {
      await fixture.close();
    }
  });
}

class _ClosedQueueFixture {
  _ClosedQueueFixture(
    this.app,
    this.progress,
    this.directory,
    this.entries,
    this.queue,
    this.sessionId,
    this.queueContents,
  );

  final AppState app;
  final PlaybackProgressService progress;
  final Directory directory;
  final File entries, queue;
  final String sessionId, queueContents;

  static Future<_ClosedQueueFixture> create({
    bool stalePipe = false,
    PlayerProcessSnapshotLoader? snapshotLoader,
  }) async {
    final directory = await Directory.systemTemp.createTemp('closed_queue_');
    final cache = await AppPaths.cacheDirectory();
    expect(
      p.equals(
        cache.path,
        p.join(Directory.current.path, 'stream_path_data', 'cache'),
      ),
      isFalse,
    );
    final sessionId = 'closed-test-${DateTime.now().microsecondsSinceEpoch}';
    final queue = File(p.join(directory.path, 'queue.json'));
    final queueContents = jsonEncode({
      'version': 2,
      'generation': 1,
      'serial': 1,
      'entries': [
        {
          'index': 0,
          'generation': 1,
          'catalog_path': 'Show/E1.mkv',
          'url': 'fixture://E1',
          'playlist': 'fixture.m3u',
          'initial_ids': <int>[],
          'check_before_load': false,
          'entry_id': 1,
        },
      ],
    });
    await queue.writeAsString(queueContents);
    final entries = File(
      p.join(cache.path, 'mpv-season-entries-$sessionId.json'),
    );
    await entries.writeAsString(
      jsonEncode({
        'entries': [
          {'url': 'fixture://E1', 'catalogPath': 'Show/E1.mkv'},
        ],
        'queueFile': queue.path,
        'queueGeneration': 1,
      }),
    );
    final progress = await PlaybackProgressService.open(
      p.join(directory.path, 'progress.db'),
    );
    final app = AppState(
      configStore: StreamPathConfigStore.forPath(
        p.join(directory.path, 'config.json'),
      ),
      playbackHistoryStore: PlaybackHistoryStore.forPath(
        p.join(directory.path, 'history.json'),
      ),
      progressService: progress,
      playerService: stalePipe
          ? ExternalPlayerService(
              configStore: StreamPathConfigStore.forPath(
                p.join(directory.path, 'config.json'),
              ),
              progressService: progress,
              processController: PlayerProcessController(
                snapshotLoader:
                    snapshotLoader ??
                    (_) async => const PlayerProcessLookupResult.notFound(),
              ),
            )
          : null,
    );
    await app.playerService.restoreSession(
      sessionId: sessionId,
      profileId: 'fixture',
      pid: stalePipe ? 2147483640 : null,
      executablePath: stalePipe ? r'C:\fixtures\ended-mpv.exe' : null,
      creationTime: stalePipe ? 1 : null,
      ipcPipeName: stalePipe ? 'streampath-ended-$sessionId' : null,
    );
    return _ClosedQueueFixture(
      app,
      progress,
      directory,
      entries,
      queue,
      sessionId,
      queueContents,
    );
  }

  Future<void> close() async {
    app.playerService.releaseSession(sessionId);
    app.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await progress.close();
    if (await entries.exists()) await entries.delete();
    await directory.delete(recursive: true);
  }
}
