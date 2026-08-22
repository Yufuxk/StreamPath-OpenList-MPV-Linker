import 'dart:convert';
import 'dart:io';

import '../../data/local/playback_progress_db.dart';
import '../../data/models/playback_media_entry.dart';
import '../../core/utils/url_utils.dart';
import 'mpv_watch_later_sync.dart';

enum MpvProgressOutcome { position, completed }

enum MpvTemporaryProgressOutcome { checkpoint, cleared }

/// MPV 明确报告的媒体加载/读取失败。
///
/// 与进度记录共用 JSONL 文件，但只接受 `reason=error`；自然 EOF、用户
/// 关闭、手动切集和恢复流程主动结束播放器均不会触发自动恢复。
class MpvPlaybackFailureRecord {
  const MpvPlaybackFailureRecord({
    required this.playlistPos,
    required this.path,
    required this.positionSeconds,
    required this.durationSeconds,
    required this.error,
    this.epoch,
  });

  final int? playlistPos;
  final String path;
  final double? positionSeconds;
  final double? durationSeconds;
  final String error;
  final String? epoch;

  static MpvPlaybackFailureRecord? tryParse(
    String line, {
    String? expectedEpoch,
  }) {
    if (line.trim().isEmpty) return null;
    try {
      final value = jsonDecode(line);
      if (value is! Map<String, dynamic> || value['reason'] != 'error') {
        return null;
      }
      final epoch = value['epoch'] as String?;
      if (expectedEpoch != null && epoch != expectedEpoch) return null;
      return MpvPlaybackFailureRecord(
        playlistPos: (value['playlist_pos'] as num?)?.toInt(),
        path: value['path'] is String ? value['path'] as String : '',
        positionSeconds: (value['position'] as num?)?.toDouble(),
        durationSeconds: (value['duration'] as num?)?.toDouble(),
        error: value['file_error']?.toString().trim().isNotEmpty == true
            ? value['file_error'].toString().trim()
            : 'unknown',
        epoch: epoch,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}

/// MPV Lua 退出日志中的一条媒体结果。
class MpvProgressJournalRecord {
  const MpvProgressJournalRecord({
    required this.outcome,
    required this.playlistPos,
    required this.path,
    required this.positionSeconds,
    required this.durationSeconds,
    this.epoch,
  });

  final MpvProgressOutcome outcome;
  final int? playlistPos;
  final String path;
  final double? positionSeconds;
  final double? durationSeconds;
  final String? epoch;

  static MpvProgressJournalRecord? tryParse(
    String line, {
    String? expectedEpoch,
  }) {
    if (line.trim().isEmpty) return null;
    try {
      final value = jsonDecode(line);
      if (value is! Map<String, dynamic>) return null;
      final epoch = value['epoch'] as String?;
      if (expectedEpoch != null && epoch != expectedEpoch) return null;
      final outcome = switch (value['outcome']) {
        'position' => MpvProgressOutcome.position,
        'completed' => MpvProgressOutcome.completed,
        _ => null,
      };
      if (outcome == null) return null;
      return MpvProgressJournalRecord(
        outcome: outcome,
        playlistPos: (value['playlist_pos'] as num?)?.toInt(),
        path: value['path'] is String ? value['path'] as String : '',
        positionSeconds: (value['position'] as num?)?.toDouble(),
        durationSeconds: (value['duration'] as num?)?.toDouble(),
        epoch: epoch,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}

/// MPV 缓冲状态生成的临时播放点事件。
class MpvTemporaryProgressRecord {
  const MpvTemporaryProgressRecord({
    required this.outcome,
    required this.playlistPos,
    required this.path,
    required this.positionSeconds,
    required this.durationSeconds,
    this.epoch,
  });

  final MpvTemporaryProgressOutcome outcome;
  final int? playlistPos;
  final String path;
  final double? positionSeconds;
  final double? durationSeconds;
  final String? epoch;

  static MpvTemporaryProgressRecord? tryParse(
    String line, {
    String? expectedEpoch,
  }) {
    if (line.trim().isEmpty) return null;
    try {
      final value = jsonDecode(line);
      if (value is! Map<String, dynamic>) return null;
      final epoch = value['epoch'] as String?;
      if (expectedEpoch != null && epoch != expectedEpoch) return null;
      final outcome = switch (value['outcome']) {
        'temporary_checkpoint' => MpvTemporaryProgressOutcome.checkpoint,
        'temporary_cleared' => MpvTemporaryProgressOutcome.cleared,
        _ => null,
      };
      if (outcome == null) return null;
      return MpvTemporaryProgressRecord(
        outcome: outcome,
        playlistPos: (value['playlist_pos'] as num?)?.toInt(),
        path: value['path'] is String ? value['path'] as String : '',
        positionSeconds: (value['position'] as num?)?.toDouble(),
        durationSeconds: (value['duration'] as num?)?.toDouble(),
        epoch: epoch,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}

class MpvCompleteJsonlChunk {
  const MpvCompleteJsonlChunk({required this.lines, required this.nextOffset});

  final List<String> lines;
  final int nextOffset;
}

/// 只提交到最后一个完整换行的 JSONL 字节读取器。
class MpvCompleteJsonlReader {
  const MpvCompleteJsonlReader();

  Future<MpvCompleteJsonlChunk> read(File file, {int startOffset = 0}) async {
    RandomAccessFile? handle;
    try {
      if (!await file.exists()) {
        return MpvCompleteJsonlChunk(lines: const [], nextOffset: startOffset);
      }
      handle = await file.open(mode: FileMode.read);
      final length = await handle.length();
      var start = startOffset;
      if (start < 0 || start > length) start = 0;
      await handle.setPosition(start);
      final bytes = await handle.read(length - start);
      var lastNewline = -1;
      for (var index = bytes.length - 1; index >= 0; index--) {
        if (bytes[index] == 10) {
          lastNewline = index;
          break;
        }
      }
      if (lastNewline < 0) {
        return MpvCompleteJsonlChunk(lines: const [], nextOffset: start);
      }
      final text = utf8.decode(
        bytes.sublist(0, lastNewline + 1),
        allowMalformed: true,
      );
      final completeLines = text.split('\n')..removeLast();
      final lines = completeLines
          .map(
            (line) =>
                line.endsWith('\r') ? line.substring(0, line.length - 1) : line,
          )
          .toList(growable: false);
      return MpvCompleteJsonlChunk(
        lines: lines,
        nextOffset: start + lastNewline + 1,
      );
    } on FileSystemException {
      return MpvCompleteJsonlChunk(lines: const [], nextOffset: startOffset);
    } finally {
      await handle?.close();
    }
  }
}

/// 合并 MPV 事件日志、watch_later 与 SQLite 播放进度。
///
/// 事件日志负责表达 `0 秒` 和 `completed` 这两个 watch_later 无法稳定
/// 表达的状态；正数位置仍允许 watch_later 以更精确的最终值覆盖日志采样。
class MpvPlaybackProgressSynchronizer {
  const MpvPlaybackProgressSynchronizer({
    this.watchLaterSync = const MpvWatchLaterSync(),
  });

  final MpvWatchLaterSync watchLaterSync;

  Future<void> sync({
    required PlaybackProgressService progressService,
    String? profileId,
    required Directory watchLaterDirectory,
    required List<PlaybackMediaEntry> entries,
    List<String> watchLaterUrls = const [],
    File? journalFile,
    String? expectedEpoch,
  }) async {
    final indexedUrls = <String>{};
    for (var index = 0; index < entries.length; index++) {
      indexedUrls.add(entries[index].url);
      if (index < watchLaterUrls.length) indexedUrls.add(watchLaterUrls[index]);
    }
    final watchLaterIndex = await watchLaterSync.buildIndex(
      watchLaterDirectory,
      indexedUrls,
      maxAge: progressService.retention,
    );
    await syncTemporaryCheckpoints(
      progressService: progressService,
      profileId: profileId,
      entries: entries,
      journalFile: journalFile,
      expectedEpoch: expectedEpoch,
    );
    final latestJournalRecords = <int, MpvProgressJournalRecord>{};
    if (journalFile != null) {
      for (final record in await _readJournal(
        journalFile,
        expectedEpoch: expectedEpoch,
      )) {
        final index = _entryIndexFor(record, entries);
        if (index == null) continue;
        latestJournalRecords[index] = record;
        final entry = entries[index];
        final watchLaterUrl = index < watchLaterUrls.length
            ? watchLaterUrls[index]
            : entry.url;
        final cleanUrl = stripUserInfo(entry.url);
        if (record.outcome == MpvProgressOutcome.completed) {
          await progressService.deleteProgress(cleanUrl, profileId: profileId);
          await progressService.deleteTemporaryProgress(
            cleanUrl,
            profileId: profileId,
          );
          await _deleteWatchLater(watchLaterIndex, watchLaterUrl, entry.url);
          continue;
        }

        final position = record.positionSeconds;
        if (position == null || position < 0) continue;
        await progressService.saveProgress(
          url: cleanUrl,
          positionMs: (position * 1000).round(),
          durationMs: _durationMs(record.durationSeconds),
          profileId: profileId,
        );
        if (position == 0) {
          await _deleteWatchLater(watchLaterIndex, watchLaterUrl, entry.url);
        } else if (_hasReachedCompletion(position, record.durationSeconds)) {
          await progressService.deleteTemporaryProgress(
            cleanUrl,
            profileId: profileId,
          );
        }
      }
    }

    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      final watchLaterUrl = index < watchLaterUrls.length
          ? watchLaterUrls[index]
          : entry.url;
      final journal = latestJournalRecords[index];
      final journalPosition = journal?.positionSeconds;
      if (journal?.outcome == MpvProgressOutcome.completed ||
          (journal?.outcome == MpvProgressOutcome.position &&
              journalPosition != null &&
              journalPosition <= 0)) {
        continue;
      }

      var record = watchLaterIndex.recordFor(watchLaterUrl);
      if (record?.startSeconds == null && watchLaterUrl != entry.url) {
        record = watchLaterIndex.recordFor(entry.url);
      }
      final start = record?.startSeconds;
      if (start == null) continue;
      final watchLaterDuration = record?.durationSeconds;
      await progressService.saveProgress(
        url: stripUserInfo(entry.url),
        positionMs: (start * 1000).round(),
        durationMs: _durationMs(watchLaterDuration ?? journal?.durationSeconds),
        profileId: profileId,
      );
      if (start == 0) {
        await _deleteWatchLater(watchLaterIndex, watchLaterUrl, entry.url);
      }
    }
  }

  /// 增量应用缓冲临时播放点事件，返回当前日志总行数。
  Future<int> syncTemporaryCheckpoints({
    required PlaybackProgressService progressService,
    String? profileId,
    required List<PlaybackMediaEntry> entries,
    File? journalFile,
    int startLine = 0,
    String? expectedEpoch,
  }) async {
    if (journalFile == null) return startLine;
    final chunk = await const MpvCompleteJsonlReader().read(
      journalFile,
      startOffset: startLine,
    );
    for (final line in chunk.lines) {
      final record = MpvTemporaryProgressRecord.tryParse(
        line,
        expectedEpoch: expectedEpoch,
      );
      if (record == null) continue;
      final entryIndex = _entryIndexForValues(
        record.playlistPos,
        record.path,
        entries,
      );
      if (entryIndex == null) continue;
      final cleanUrl = stripUserInfo(entries[entryIndex].url);
      if (record.outcome == MpvTemporaryProgressOutcome.cleared) {
        await progressService.deleteTemporaryProgress(
          cleanUrl,
          profileId: profileId,
        );
        continue;
      }
      final position = record.positionSeconds;
      if (position == null || position <= 0) continue;
      if (_hasReachedCompletion(position, record.durationSeconds)) {
        await progressService.deleteTemporaryProgress(
          cleanUrl,
          profileId: profileId,
        );
        continue;
      }
      await progressService.saveTemporaryProgress(
        url: cleanUrl,
        positionMs: (position * 1000).round(),
        durationMs: _durationMs(record.durationSeconds),
        profileId: profileId,
      );
    }
    return chunk.nextOffset;
  }

  Future<void> _deleteWatchLater(
    MpvWatchLaterIndex index,
    String playbackUrl,
    String cleanUrl,
  ) async {
    await index.deleteRecord(playbackUrl);
    if (cleanUrl != playbackUrl) {
      await index.deleteRecord(cleanUrl);
    }
  }

  Future<List<MpvProgressJournalRecord>> _readJournal(
    File file, {
    String? expectedEpoch,
  }) async {
    return (await _readLines(file))
        .map(
          (line) => MpvProgressJournalRecord.tryParse(
            line,
            expectedEpoch: expectedEpoch,
          ),
        )
        .whereType<MpvProgressJournalRecord>()
        .toList(growable: false);
  }

  Future<List<String>> _readLines(File file) async {
    return (await const MpvCompleteJsonlReader().read(file)).lines;
  }

  int? _entryIndexFor(
    MpvProgressJournalRecord record,
    List<PlaybackMediaEntry> entries,
  ) => _entryIndexForValues(record.playlistPos, record.path, entries);

  int? _entryIndexForValues(
    int? playlistPos,
    String path,
    List<PlaybackMediaEntry> entries,
  ) {
    if (playlistPos != null &&
        playlistPos >= 0 &&
        playlistPos < entries.length &&
        (path.isEmpty || _sameTrack(path, entries[playlistPos].url))) {
      return playlistPos;
    }
    if (path.isNotEmpty) {
      for (var index = 0; index < entries.length; index++) {
        if (_sameTrack(path, entries[index].url)) return index;
      }
    }
    return null;
  }

  bool _sameTrack(String a, String b) {
    final cleanA = stripUserInfo(a);
    final cleanB = stripUserInfo(b);
    if (cleanA == cleanB) return true;
    try {
      return Uri.decodeFull(cleanA) == Uri.decodeFull(cleanB);
    } catch (_) {
      return false;
    }
  }

  int? _durationMs(double? seconds) =>
      seconds != null && seconds > 0 ? (seconds * 1000).round() : null;

  bool _hasReachedCompletion(double position, double? duration) =>
      duration != null && duration > 0 && position / duration >= 0.99;
}
