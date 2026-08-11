import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/models/media_entry.dart';
import 'package:streampath/domain/services/mpv_playback_progress_sync.dart';
import 'package:streampath/domain/services/mpv_watch_later_sync.dart';

void main() {
  late PlaybackProgressService progressService;
  late Directory dir;
  late Directory watchLaterDir;
  late File journalFile;

  setUp(() async {
    progressService = await PlaybackProgressService.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    dir = Directory.systemTemp.createTempSync('mpv_progress_sync_');
    watchLaterDir = Directory('${dir.path}${Platform.pathSeparator}watch_later')
      ..createSync();
    journalFile = File('${dir.path}${Platform.pathSeparator}progress.jsonl');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> writeJournal(List<Map<String, Object?>> records) =>
      journalFile.writeAsString(records.map(jsonEncode).join('\n'));

  File watchLaterFile(String url) => File(
    '${watchLaterDir.path}${Platform.pathSeparator}'
    '${MpvWatchLaterSync.md5FileName(url)}',
  );

  const synchronizer = MpvPlaybackProgressSynchronizer();

  test('失败记录只接受 end-file reason=error 并兼容空 path', () {
    final failure = MpvPlaybackFailureRecord.tryParse(
      jsonEncode({
        'outcome': 'position',
        'playlist_pos': 2,
        'path': '',
        'position': 91.5,
        'duration': 120,
        'reason': 'error',
        'file_error': 'loading failed',
      }),
    );
    expect(failure, isNotNull);
    expect(failure!.playlistPos, 2);
    expect(failure.path, isEmpty);
    expect(failure.positionSeconds, 91.5);
    expect(failure.error, 'loading failed');
    expect(
      MpvPlaybackFailureRecord.tryParse(
        jsonEncode({'reason': 'eof', 'playlist_pos': 0}),
      ),
      isNull,
      reason: '自然 EOF 不得触发自动恢复',
    );
    expect(
      MpvPlaybackFailureRecord.tryParse(
        jsonEncode({'reason': 'quit', 'playlist_pos': 0}),
      ),
      isNull,
      reason: '用户关闭播放器不得触发自动恢复',
    );
  });

  test('自然播放完成会删除 SQLite 与残留 watch_later', () async {
    const url = 'http://host/dav/done.mp4';
    await progressService.saveProgress(url: url, positionMs: 90000);
    final watchLater = watchLaterFile(url)..writeAsStringSync('start=90\n');
    await writeJournal([
      {
        'outcome': 'completed',
        'playlist_pos': 0,
        'path': url,
        'position': 120,
        'duration': 120,
      },
    ]);

    await synchronizer.sync(
      progressService: progressService,
      watchLaterDirectory: watchLaterDir,
      entries: const [MediaEntry(url: url)],
      journalFile: journalFile,
    );

    expect(await progressService.getProgress(url), isNull);
    expect(watchLater.existsSync(), isFalse);
  });

  test('主动跳回 0 秒会覆盖旧进度并删除恢复文件', () async {
    const url = 'http://host/dav/reset.mp4';
    await progressService.saveProgress(url: url, positionMs: 90000);
    final watchLater = watchLaterFile(url)..writeAsStringSync('start=90\n');
    await writeJournal([
      {
        'outcome': 'position',
        'playlist_pos': 0,
        'path': url,
        'position': 0,
        'duration': 120,
      },
    ]);

    await synchronizer.sync(
      progressService: progressService,
      watchLaterDirectory: watchLaterDir,
      entries: const [MediaEntry(url: url)],
      journalFile: journalFile,
    );

    final progress = await progressService.getProgress(url);
    expect(progress!.positionMs, 0);
    expect(progress.durationMs, 120000);
    expect(progress.resumeSeconds, isNull);
    expect(watchLater.existsSync(), isFalse);
  });

  test('普通退出以 watch_later 精确位置覆盖日志采样并保留日志时长', () async {
    const url = 'http://host/dav/resume.mp4';
    watchLaterFile(url).writeAsStringSync('start=91.234\n');
    await writeJournal([
      {
        'outcome': 'position',
        'playlist_pos': 0,
        'path': url,
        'position': 90.5,
        'duration': 7200,
      },
    ]);

    await synchronizer.sync(
      progressService: progressService,
      watchLaterDirectory: watchLaterDir,
      entries: const [MediaEntry(url: url)],
      journalFile: journalFile,
    );

    final progress = await progressService.getProgress(url);
    expect(progress!.positionMs, 91234);
    expect(progress.durationMs, 7200000);
  });

  test('认证播放 URL 的 watch_later 位置写回无凭据的数据库键', () async {
    const cleanUrl = 'http://host/dav/auth.mp4';
    const playbackUrl = 'http://viewer@host/dav/auth.mp4';
    watchLaterFile(playbackUrl).writeAsStringSync('start=12.5\n');

    await synchronizer.sync(
      progressService: progressService,
      watchLaterDirectory: watchLaterDir,
      entries: const [MediaEntry(url: cleanUrl)],
      watchLaterUrls: const [playbackUrl],
    );

    expect((await progressService.getProgress(cleanUrl))!.positionMs, 12500);
    expect(await progressService.getProgress(playbackUrl), isNull);
  });

  test('认证 URL 缺少记录时兼容读取旧版无凭据 watch_later', () async {
    const cleanUrl = 'http://host/dav/legacy.mp4';
    const playbackUrl = 'http://viewer@host/dav/legacy.mp4';
    watchLaterFile(cleanUrl).writeAsStringSync('start=8\n');

    await synchronizer.sync(
      progressService: progressService,
      watchLaterDirectory: watchLaterDir,
      entries: const [MediaEntry(url: cleanUrl)],
      watchLaterUrls: const [playbackUrl],
    );

    expect((await progressService.getProgress(cleanUrl))!.positionMs, 8000);
  });

  test('播放列表逐集完成记录分别清除，不串到同会话其他 URL', () async {
    const first = 'http://host/dav/01.mp4';
    const second = 'http://host/dav/02.mp4';
    await progressService.saveProgress(url: first, positionMs: 30000);
    await progressService.saveProgress(url: second, positionMs: 40000);
    await writeJournal([
      {
        'outcome': 'completed',
        'playlist_pos': 0,
        'path': first,
        'position': 100,
        'duration': 100,
      },
      {
        'outcome': 'position',
        'playlist_pos': 1,
        'path': second,
        'position': 45,
        'duration': 200,
      },
    ]);

    await synchronizer.sync(
      progressService: progressService,
      watchLaterDirectory: watchLaterDir,
      entries: const [
        MediaEntry(url: first),
        MediaEntry(url: second),
      ],
      journalFile: journalFile,
    );

    expect(await progressService.getProgress(first), isNull);
    expect((await progressService.getProgress(second))!.positionMs, 45000);
  });

  test('播放列表含相同 URL 时以 playlist-pos 保留最后一个条目的 0 秒状态', () async {
    const url = 'http://host/dav/repeated.mp4';
    await progressService.saveProgress(url: url, positionMs: 30000);
    final watchLater = watchLaterFile(url)..writeAsStringSync('start=90\n');
    await writeJournal([
      {
        'outcome': 'completed',
        'playlist_pos': 0,
        'path': url,
        'position': 100,
        'duration': 100,
      },
      {
        'outcome': 'position',
        'playlist_pos': 1,
        'path': url,
        'position': 0,
        'duration': 100,
      },
    ]);

    await synchronizer.sync(
      progressService: progressService,
      watchLaterDirectory: watchLaterDir,
      entries: const [
        MediaEntry(url: url),
        MediaEntry(url: url),
      ],
      journalFile: journalFile,
    );

    expect((await progressService.getProgress(url))!.positionMs, 0);
    expect(watchLater.existsSync(), isFalse);
  });

  test('日志与 watch_later 都无有效状态时保留旧进度', () async {
    const url = 'http://host/dav/unavailable.mp4';
    await progressService.saveProgress(url: url, positionMs: 30000);

    await synchronizer.sync(
      progressService: progressService,
      watchLaterDirectory: watchLaterDir,
      entries: const [MediaEntry(url: url)],
      journalFile: journalFile,
    );

    expect((await progressService.getProgress(url))!.positionMs, 30000);
  });
}
