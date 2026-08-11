import 'dart:convert';
import 'dart:io';

import '../../data/local/playback_progress_db.dart';
import '../../data/models/media_entry.dart';
import '../../core/utils/url_utils.dart';
import 'mpv_watch_later_sync.dart';

enum MpvProgressOutcome { position, completed }

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
  });

  final int? playlistPos;
  final String path;
  final double? positionSeconds;
  final double? durationSeconds;
  final String error;

  static MpvPlaybackFailureRecord? tryParse(String line) {
    if (line.trim().isEmpty) return null;
    try {
      final value = jsonDecode(line);
      if (value is! Map<String, dynamic> || value['reason'] != 'error') {
        return null;
      }
      return MpvPlaybackFailureRecord(
        playlistPos: (value['playlist_pos'] as num?)?.toInt(),
        path: value['path'] is String ? value['path'] as String : '',
        positionSeconds: (value['position'] as num?)?.toDouble(),
        durationSeconds: (value['duration'] as num?)?.toDouble(),
        error: value['file_error']?.toString().trim().isNotEmpty == true
            ? value['file_error'].toString().trim()
            : 'unknown',
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
  });

  final MpvProgressOutcome outcome;
  final int? playlistPos;
  final String path;
  final double? positionSeconds;
  final double? durationSeconds;

  static MpvProgressJournalRecord? tryParse(String line) {
    if (line.trim().isEmpty) return null;
    try {
      final value = jsonDecode(line);
      if (value is! Map<String, dynamic>) return null;
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
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
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
    required Directory watchLaterDirectory,
    required List<MediaEntry> entries,
    List<String> watchLaterUrls = const [],
    File? journalFile,
  }) async {
    final latestJournalRecords = <int, MpvProgressJournalRecord>{};
    if (journalFile != null) {
      for (final record in await _readJournal(journalFile)) {
        final index = _entryIndexFor(record, entries);
        if (index == null) continue;
        latestJournalRecords[index] = record;
        final entry = entries[index];
        final watchLaterUrl = index < watchLaterUrls.length
            ? watchLaterUrls[index]
            : entry.url;
        final cleanUrl = stripUserInfo(entry.url);
        if (record.outcome == MpvProgressOutcome.completed) {
          await progressService.deleteProgress(cleanUrl);
          await _deleteWatchLater(
            watchLaterDirectory,
            watchLaterUrl,
            entry.url,
          );
          continue;
        }

        final position = record.positionSeconds;
        if (position == null || position < 0) continue;
        await progressService.saveProgress(
          url: cleanUrl,
          positionMs: (position * 1000).round(),
          durationMs: _durationMs(record.durationSeconds),
        );
        if (position == 0) {
          await _deleteWatchLater(
            watchLaterDirectory,
            watchLaterUrl,
            entry.url,
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

      var matchedWatchLaterUrl = watchLaterUrl;
      var start = await watchLaterSync.readStartSeconds(
        watchLaterDirectory,
        watchLaterUrl,
      );
      if (start == null && watchLaterUrl != entry.url) {
        matchedWatchLaterUrl = entry.url;
        start = await watchLaterSync.readStartSeconds(
          watchLaterDirectory,
          entry.url,
        );
      }
      if (start == null) continue;
      final watchLaterDuration = await watchLaterSync.readDurationSeconds(
        watchLaterDirectory,
        matchedWatchLaterUrl,
      );
      await progressService.saveProgress(
        url: stripUserInfo(entry.url),
        positionMs: (start * 1000).round(),
        durationMs: _durationMs(watchLaterDuration ?? journal?.durationSeconds),
      );
      if (start == 0) {
        await _deleteWatchLater(watchLaterDirectory, watchLaterUrl, entry.url);
      }
    }
  }

  Future<void> _deleteWatchLater(
    Directory directory,
    String playbackUrl,
    String cleanUrl,
  ) async {
    await watchLaterSync.deleteRecord(directory, playbackUrl);
    if (cleanUrl != playbackUrl) {
      await watchLaterSync.deleteRecord(directory, cleanUrl);
    }
  }

  Future<List<MpvProgressJournalRecord>> _readJournal(File file) async {
    try {
      if (!await file.exists()) return const [];
      return (await file.readAsLines())
          .map(MpvProgressJournalRecord.tryParse)
          .whereType<MpvProgressJournalRecord>()
          .toList(growable: false);
    } on FileSystemException {
      return const [];
    }
  }

  int? _entryIndexFor(
    MpvProgressJournalRecord record,
    List<MediaEntry> entries,
  ) {
    final playlistPos = record.playlistPos;
    if (playlistPos != null &&
        playlistPos >= 0 &&
        playlistPos < entries.length &&
        (record.path.isEmpty ||
            _sameTrack(record.path, entries[playlistPos].url))) {
      return playlistPos;
    }
    if (record.path.isNotEmpty) {
      for (var index = 0; index < entries.length; index++) {
        if (_sameTrack(record.path, entries[index].url)) return index;
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
}
