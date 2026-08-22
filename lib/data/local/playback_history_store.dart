import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../../core/cache/cache_retention_policy.dart';
import '../../core/constants.dart';
import '../../core/utils/app_paths.dart';
import '../../core/utils/cache_expiration.dart';
import '../models/playback_history.dart';

/// 播放会话记录管理（JSON 读写 + 内存缓存）。
///
/// 文件位于数据目录 `playback_history.json`。新格式保存会话列表，读取时
/// 兼容旧版单对象结构并自动作为 `legacy` 会话载入。
class PlaybackHistoryStore {
  PlaybackHistoryStore._(this._configFile, this._now, this._policyProvider);

  final File _configFile;
  final DateTime Function() _now;
  final CacheRetentionPolicyProvider _policyProvider;

  List<PlaybackHistory> _cached = const [];
  bool _loaded = false;
  DateTime? _legacyFallbackAt;
  Future<void> _pending = Future<void>.value();

  /// 创建：定位到数据目录下的记录文件。
  static Future<PlaybackHistoryStore> create({
    CacheRetentionPolicyProvider? policyProvider,
  }) async {
    final dir = await AppPaths.cacheDirectory(); // playback_history.json
    return forPath(
      p.join(dir.path, AppConstants.playbackHistoryFileName),
      policyProvider: policyProvider,
    );
  }

  /// 以指定路径创建（测试注入用）。
  @visibleForTesting
  static PlaybackHistoryStore forPath(
    String path, {
    DateTime Function()? now,
    CacheRetentionPolicyProvider? policyProvider,
  }) => PlaybackHistoryStore._(
    File(path),
    now ?? DateTime.now,
    policyProvider ?? _defaultPolicyProvider,
  );

  /// 当前全部会话（最早创建在前）。
  List<PlaybackHistory> get sessions => List.unmodifiable(_cached);

  /// 加载全部播放会话（最早创建在前）。
  Future<List<PlaybackHistory>> loadAll() => _enqueue(_loadAll);

  Future<List<PlaybackHistory>> _loadAll() async {
    if (_loaded) {
      await _pruneExpired(_cached, legacyFallback: _legacyFallbackAt);
      return sessions;
    }
    if (!_configFile.existsSync()) {
      _loaded = true;
      return const [];
    }
    try {
      final fileModifiedAt = await _configFile.lastModified();
      _legacyFallbackAt = fileModifiedAt;
      final json = jsonDecode(await _configFile.readAsString());
      final records = <PlaybackHistory>[];
      if (json is Map<String, dynamic> && json['sessions'] is List) {
        for (final item in json['sessions'] as List) {
          if (item is Map) {
            records.add(
              PlaybackHistory.fromJson(Map<String, dynamic>.from(item)),
            );
          }
        }
      } else if (json is Map<String, dynamic>) {
        records.add(PlaybackHistory.fromJson(json));
      }
      records.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      _cached = records;
      _loaded = true;
      await _pruneExpired(_cached, legacyFallback: fileModifiedAt);
      return sessions;
    } catch (_) {
      _cached = const [];
      _loaded = true;
      return const [];
    }
  }

  Future<void> _pruneExpired(
    List<PlaybackHistory> records, {
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
        if (await _configFile.exists()) await _configFile.delete();
      } else {
        await _write(retained);
      }
    } on FileSystemException {
      // 自动过期落盘失败不影响当前内存结果。
    }
  }

  /// 新增或更新一个会话。达到上限且 [history] 是新 ID 时返回 false。
  Future<bool> upsert(PlaybackHistory history) => _enqueue(() async {
    await _loadAll();
    final record = PlaybackHistory(
      sessionId: history.sessionId,
      dirCrumbs: history.dirCrumbs,
      fileName: history.fileName,
      videoIndex: history.videoIndex,
      updatedAt: _now(),
      createdAt: history.createdAt,
      playlistFileNames: history.playlistFileNames,
      playerPid: history.playerPid,
      playerExecutablePath: history.playerExecutablePath,
      playerCreationTime: history.playerCreationTime,
      ipcPipeName: history.ipcPipeName,
      launchEpoch: history.launchEpoch,
    );
    final records = [..._cached];
    final index = records.indexWhere((e) => e.sessionId == record.sessionId);
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
      // 记录失败不阻塞播放。
    }
    return true;
  });

  /// 删除指定会话；其余会话保持不变。
  Future<void> remove(String sessionId) => _enqueue(() async {
    await _loadAll();
    final records = _cached.where((e) => e.sessionId != sessionId).toList();
    _cached = records;
    _loaded = true;
    try {
      if (records.isEmpty) {
        if (await _configFile.exists()) await _configFile.delete();
      } else {
        await _write(records);
      }
    } on FileSystemException {
      // 删除失败不阻塞界面移除。
    }
  });

  /// 清空全部继续播放记录。
  Future<void> clear() => _enqueue(() async {
    if (await _configFile.exists()) await _configFile.delete();
    _cached = const [];
    _loaded = true;
  });

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final task = _pending.then((_) => action());
    _pending = task.then<void>((_) {}, onError: (_) {});
    return task;
  }

  Future<void> _write(List<PlaybackHistory> records) async {
    await _configFile.parent.create(recursive: true);
    final body = const JsonEncoder.withIndent('  ').convert({
      'version': 2,
      'sessions': records.map((e) => e.toJson()).toList(),
    });
    final temp = File('${_configFile.path}.tmp');
    await temp.writeAsString(body, flush: true);
    await temp.rename(_configFile.path);
  }

  static CacheRetentionPolicy _defaultPolicyProvider() =>
      const DefaultCacheRetentionPolicy();
}
