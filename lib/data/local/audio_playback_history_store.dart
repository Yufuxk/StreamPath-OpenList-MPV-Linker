import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../../core/cache/cache_retention_policy.dart';
import '../../core/constants.dart';
import '../../core/utils/app_paths.dart';
import '../../core/utils/cache_expiration.dart';
import '../models/audio_playback_history.dart';

/// 音频播放历史存储。独立文件和串行写队列可隔离视频历史故障。
class AudioPlaybackHistoryStore {
  AudioPlaybackHistoryStore._(this._file, this._now, this._policyProvider);

  final File _file;
  final DateTime Function() _now;
  final CacheRetentionPolicyProvider _policyProvider;
  List<AudioPlaybackHistory> _cached = const [];
  bool _loaded = false;
  DateTime? _legacyFallbackAt;
  Future<void> _pending = Future<void>.value();

  static Future<AudioPlaybackHistoryStore> create({
    CacheRetentionPolicyProvider? policyProvider,
  }) async {
    final dir = await AppPaths.cacheDirectory();
    return forPath(
      p.join(dir.path, AppConstants.audioPlaybackHistoryFileName),
      policyProvider: policyProvider,
    );
  }

  @visibleForTesting
  static AudioPlaybackHistoryStore forPath(
    String path, {
    DateTime Function()? now,
    CacheRetentionPolicyProvider? policyProvider,
  }) => AudioPlaybackHistoryStore._(
    File(path),
    now ?? DateTime.now,
    policyProvider ?? _defaultPolicyProvider,
  );

  Future<List<AudioPlaybackHistory>> loadAll() => _enqueue(_loadAll);

  Future<List<AudioPlaybackHistory>> _loadAll() async {
    if (_loaded) {
      await _pruneExpired(_cached, legacyFallback: _legacyFallbackAt);
      return List.unmodifiable(_cached);
    }
    if (!await _file.exists()) {
      _loaded = true;
      return const [];
    }
    try {
      final fileModifiedAt = await _file.lastModified();
      _legacyFallbackAt = fileModifiedAt;
      final value = jsonDecode(await _file.readAsString());
      final sessions = <AudioPlaybackHistory>[];
      if (value is Map<String, dynamic> && value['sessions'] is List) {
        for (final item in value['sessions'] as List) {
          if (item is Map) {
            sessions.add(
              AudioPlaybackHistory.fromJson(Map<String, dynamic>.from(item)),
            );
          }
        }
      }
      sessions.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      _cached = sessions;
      await _pruneExpired(_cached, legacyFallback: fileModifiedAt);
    } catch (_) {
      _cached = const [];
    }
    _loaded = true;
    return List.unmodifiable(_cached);
  }

  Future<void> _pruneExpired(
    List<AudioPlaybackHistory> records, {
    DateTime? legacyFallback,
  }) async {
    final now = _now();
    final retention = _policyProvider().playbackRetention;
    final retained = records
        .where((record) {
          if (record.playerPid != null || record.ipcPipeName != null) {
            return true;
          }
          final lastUsedAt = record.updatedAt.millisecondsSinceEpoch > 0
              ? record.updatedAt
              : legacyFallback ?? now;
          return !CacheExpiration.isExpired(
            lastUsedAt: lastUsedAt,
            retention: retention,
            now: now,
          );
        })
        .take(AppConstants.maxPlaybackSessions)
        .toList();
    if (retained.length == records.length) return;
    _cached = retained;
    try {
      if (retained.isEmpty) {
        if (await _file.exists()) await _file.delete();
      } else {
        await _write(retained);
      }
    } on FileSystemException {
      // 自动过期落盘失败不影响当前内存结果。
    }
  }

  Future<bool> upsert(AudioPlaybackHistory history) => _enqueue(() async {
    await _loadAll();
    final record = history.copyWith(updatedAt: _now());
    final records = [..._cached];
    final index = records.indexWhere(
      (item) => item.sessionId == record.sessionId,
    );
    if (index < 0 && records.length >= AppConstants.maxPlaybackSessions) {
      return false;
    }
    if (index < 0) {
      records.add(record);
    } else {
      records[index] = record;
    }
    records.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    try {
      await _write(records);
      _cached = records;
      _loaded = true;
    } on FileSystemException {
      // 历史写入失败不阻塞音频播放。
    }
    return true;
  });

  Future<void> remove(String sessionId) => _enqueue(() async {
    await _loadAll();
    final records = _cached
        .where((item) => item.sessionId != sessionId)
        .toList();
    _cached = records;
    _loaded = true;
    try {
      if (records.isEmpty) {
        if (await _file.exists()) await _file.delete();
      } else {
        await _write(records);
      }
    } on FileSystemException {
      // 删除失败不阻塞界面移除。
    }
  });

  /// 清空全部音频继续播放记录。
  Future<void> clear() => _enqueue(() async {
    if (await _file.exists()) await _file.delete();
    _cached = const [];
    _loaded = true;
  });

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final task = _pending.then((_) => action());
    _pending = task.then<void>((_) {}, onError: (_) {});
    return task;
  }

  Future<void> _write(List<AudioPlaybackHistory> records) async {
    await _file.parent.create(recursive: true);
    final body = const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'sessions': records.map((item) => item.toJson()).toList(),
    });
    final temp = File('${_file.path}.tmp');
    await temp.writeAsString(body, flush: true);
    await temp.rename(_file.path);
  }

  static CacheRetentionPolicy _defaultPolicyProvider() =>
      const DefaultCacheRetentionPolicy();
}
