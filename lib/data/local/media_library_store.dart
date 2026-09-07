import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../../core/utils/app_paths.dart';
import '../models/media_library_config.dart';
import '../models/media_library_item.dart';

enum _MediaLibraryLoadState {
  notLoaded,
  writable,
  corrupt,
  readFailed,
  unsupportedVersion,
}

/// 收藏、最近目录和长期播放历史的单文件存储。
class MediaLibraryStore {
  MediaLibraryStore._(this._file, this._now);

  static const String fileName = 'media_library.json';
  static const int schemaVersion = 2;
  static const int maxRecentDirectories =
      MediaLibraryConfig.defaultMaxRecentDirectoriesPerSource;
  static const int maxPlaybackHistoryPerLane =
      MediaLibraryConfig.defaultMaxRecentPlaybackPerLane;

  final File _file;
  final DateTime Function() _now;
  Future<void> _pending = Future<void>.value();
  bool _loaded = false;
  _MediaLibraryLoadState _loadState = _MediaLibraryLoadState.notLoaded;
  List<int>? _corruptOriginalBytes;
  int? _unsupportedVersion;
  bool _loadHadCorruption = false;
  List<MediaLibraryRecord> _favorites = const [];
  List<MediaLibraryRecord> _recentDirectories = const [];
  List<MediaLibraryRecord> _videoHistory = const [];
  List<MediaLibraryRecord> _audioHistory = const [];
  List<MediaLibraryRecord> _isoHistory = const [];
  MediaLibraryConfig _config = const MediaLibraryConfig();
  final Set<void Function()> _listeners = {};

  /// 监听收藏、目录或长期播放历史的成功变更。
  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  static Future<MediaLibraryStore> create() async {
    final directory = await AppPaths.libraryDirectory();
    final store = forPath(p.join(directory.path, fileName));
    await store.load();
    return store;
  }

  @visibleForTesting
  static MediaLibraryStore forPath(String path, {DateTime Function()? now}) =>
      MediaLibraryStore._(File(path), now ?? DateTime.now);

  Future<void> load() => _enqueue(_load);

  MediaLibraryConfig get config => _config;

  /// 应用统一配置中的容量限制，并立即淘汰各来源超出上限的旧记录。
  Future<void> applyConfig(MediaLibraryConfig config) => _enqueue(() async {
    await _load();
    final normalized = config.normalized;
    _config = normalized;
    final favorites = _boundAllSources(
      _favorites,
      normalized.maxFavoritesPerSource,
    );
    final recentDirectories = _boundAllSources(
      _recentDirectories,
      normalized.maxRecentDirectoriesPerSource,
    );
    final videoHistory = _boundAllSources(
      _videoHistory,
      normalized.maxRecentPlaybackPerLane,
    );
    final audioHistory = _boundAllSources(
      _audioHistory,
      normalized.maxRecentPlaybackPerLane,
    );
    final isoHistory = _boundAllSources(
      _isoHistory,
      normalized.maxRecentPlaybackPerLane,
    );
    final changed =
        favorites.length != _favorites.length ||
        recentDirectories.length != _recentDirectories.length ||
        videoHistory.length != _videoHistory.length ||
        audioHistory.length != _audioHistory.length ||
        isoHistory.length != _isoHistory.length;
    if (!changed) return;
    await _write(
      favorites: favorites,
      recentDirectories: recentDirectories,
      videoHistory: videoHistory,
      audioHistory: audioHistory,
      isoHistory: isoHistory,
    );
    _favorites = favorites;
    _recentDirectories = recentDirectories;
    _videoHistory = videoHistory;
    _audioHistory = audioHistory;
    _isoHistory = isoHistory;
    _notifyChanged();
  });

  Future<void> _load() async {
    if (_loaded) return;
    if (!await _file.exists()) {
      _loadState = _MediaLibraryLoadState.writable;
      _loaded = true;
      return;
    }

    late List<int> originalBytes;
    try {
      originalBytes = await _file.readAsBytes();
    } catch (_) {
      _clearLoadedRecords();
      _loadState = _MediaLibraryLoadState.readFailed;
      _loaded = true;
      return;
    }

    try {
      final rawDecoded = jsonDecode(utf8.decode(originalBytes));
      if (rawDecoded is! Map) {
        throw const FormatException('媒体库根节点无效');
      }
      final decoded = Map<String, dynamic>.from(rawDecoded);
      final version = decoded['version'];
      final unsupportedVersion = version is int && version > schemaVersion;
      _loadHadCorruption = version != 1 && version != schemaVersion;
      _favorites = _readRecords(decoded['favorites']);
      _recentDirectories = _readRecords(decoded['recentDirectories']);
      _videoHistory = _readRecords(decoded['videoHistory']);
      _audioHistory = _readRecords(decoded['audioHistory']);
      _isoHistory = version == schemaVersion
          ? _readRecords(decoded['isoHistory'])
          : const [];
      if (unsupportedVersion) {
        _unsupportedVersion = version;
        _loadState = _MediaLibraryLoadState.unsupportedVersion;
      } else if (_loadHadCorruption) {
        _corruptOriginalBytes = List<int>.unmodifiable(originalBytes);
        _loadState = _MediaLibraryLoadState.corrupt;
      } else {
        _loadState = _MediaLibraryLoadState.writable;
      }
    } catch (_) {
      // 损坏文件原样保留，单个个人资产文件不得阻止应用启动。
      _clearLoadedRecords();
      _corruptOriginalBytes = List<int>.unmodifiable(originalBytes);
      _loadState = _MediaLibraryLoadState.corrupt;
    }
    _loaded = true;
  }

  void _clearLoadedRecords() {
    _favorites = const [];
    _recentDirectories = const [];
    _videoHistory = const [];
    _audioHistory = const [];
    _isoHistory = const [];
  }

  Future<List<MediaLibraryRecord>> favorites(String sourceId) =>
      _enqueue(() async {
        await _load();
        return _forSource(_favorites, sourceId);
      });

  Future<List<MediaLibraryRecord>> recentDirectories(String sourceId) =>
      _enqueue(() async {
        await _load();
        return _forSource(_recentDirectories, sourceId);
      });

  Future<List<MediaLibraryRecord>> playbackHistory(
    String sourceId, {
    required bool audio,
    bool iso = false,
  }) => _enqueue(() async {
    assert(!audio || !iso);
    await _load();
    return _forSource(
      iso ? _isoHistory : (audio ? _audioHistory : _videoHistory),
      sourceId,
    );
  });

  Future<bool> toggleFavorite(MediaLibraryItem item) => _enqueue(() async {
    await _load();
    final records = [..._favorites];
    final index = _indexOf(records, item);
    final added = index < 0;
    if (added) {
      records.insert(0, MediaLibraryRecord(item: item, updatedAt: _now()));
    } else {
      records.removeAt(index);
    }
    final bounded = _boundPerSource(
      records,
      item.sourceId,
      _config.maxFavoritesPerSource,
    );
    await _write(favorites: bounded);
    _favorites = bounded;
    _notifyChanged();
    return added;
  });

  Future<void> recordRecentDirectory(MediaLibraryItem item) =>
      _enqueue(() async {
        if (item.kind != MediaLibraryKind.directory) return;
        await _load();
        final records = _upsert(_recentDirectories, item);
        final bounded = _boundPerSource(
          records,
          item.sourceId,
          _config.maxRecentDirectoriesPerSource,
        );
        await _write(recentDirectories: bounded);
        _recentDirectories = bounded;
        _notifyChanged();
      });

  Future<void> recordPlayback(
    MediaLibraryItem item, {
    String? playbackSessionId,
    LocalDiscSessionSnapshot? localDiscSession,
  }) => _enqueue(() async {
    if (!item.kind.isMedia) return;
    await _load();
    final audio = item.kind == MediaLibraryKind.audio;
    final iso = item.kind == MediaLibraryKind.iso;
    final source = iso ? _isoHistory : (audio ? _audioHistory : _videoHistory);
    final records = playbackSessionId == null || playbackSessionId.isEmpty
        ? _upsert(source, item)
        : _upsertPlaybackSession(
            source,
            item,
            playbackSessionId,
            localDiscSession: localDiscSession,
          );
    final bounded = _boundPerSource(
      records,
      item.sourceId,
      _config.maxRecentPlaybackPerLane,
    );
    if (iso) {
      await _write(isoHistory: bounded);
      _isoHistory = bounded;
    } else if (audio) {
      await _write(audioHistory: bounded);
      _audioHistory = bounded;
    } else {
      await _write(videoHistory: bounded);
      _videoHistory = bounded;
    }
    _notifyChanged();
  });

  Future<void> removePlayback(MediaLibraryItem item) => _enqueue(() async {
    await _load();
    final audio = item.kind == MediaLibraryKind.audio;
    final iso = item.kind == MediaLibraryKind.iso;
    final source = iso ? _isoHistory : (audio ? _audioHistory : _videoHistory);
    final records = source
        .where((record) => !_sameItem(record.item, item))
        .toList();
    if (iso) {
      await _write(isoHistory: records);
      _isoHistory = records;
    } else if (audio) {
      await _write(audioHistory: records);
      _audioHistory = records;
    } else {
      await _write(videoHistory: records);
      _videoHistory = records;
    }
    _notifyChanged();
  });

  /// 删除一条明确的历史记录，不影响同一媒体所属的其他播放会话。
  Future<void> removePlaybackRecord(MediaLibraryRecord target) =>
      _enqueue(() async {
        await _load();
        final audio = target.item.kind == MediaLibraryKind.audio;
        final iso = target.item.kind == MediaLibraryKind.iso;
        final source = iso
            ? _isoHistory
            : (audio ? _audioHistory : _videoHistory);
        final records = source
            .where((record) => !_sameRecord(record, target))
            .toList();
        if (iso) {
          await _write(isoHistory: records);
          _isoHistory = records;
        } else if (audio) {
          await _write(audioHistory: records);
          _audioHistory = records;
        } else {
          await _write(videoHistory: records);
          _videoHistory = records;
        }
        _notifyChanged();
      });

  /// 只隐藏本地蓝光底栏，保留媒体中心历史、快照及续播入口。
  Future<void> dismissLocalDiscPlaybackBar(MediaLibraryRecord record) =>
      _enqueue(() async {
        await _load();
        final records = [
          for (final candidate in _isoHistory)
            _sameRecord(candidate, record)
                ? candidate.copyWith(playbackBarDismissed: true)
                : candidate,
        ];
        await _write(isoHistory: records);
        _isoHistory = records;
        _notifyChanged();
      });

  /// 保存本地蓝光会话当前可续播的 MPV edition。
  Future<bool> updateLocalDiscTitleContext({
    required String sourceId,
    required String playbackSessionId,
    required int currentEdition,
    required int editionCount,
  }) => _enqueue(() async {
    await _load();
    final index = _isoHistory.indexWhere(
      (record) =>
          record.item.sourceId == sourceId &&
          record.playbackSessionId == playbackSessionId &&
          record.localDiscSession != null,
    );
    if (index < 0) return false;
    final records = [..._isoHistory];
    final record = records[index];
    records[index] = record.copyWith(
      localDiscSession: record.localDiscSession!.copyWith(
        currentEdition: currentEdition,
        editionCount: editionCount,
      ),
    );
    await _write(isoHistory: records);
    _isoHistory = records;
    _notifyChanged();
    return true;
  });

  Future<void> clearPlaybackHistory(
    String sourceId, {
    required bool audio,
    bool iso = false,
  }) => _enqueue(() async {
    assert(!audio || !iso);
    await _load();
    final source = iso ? _isoHistory : (audio ? _audioHistory : _videoHistory);
    final records = source
        .where((record) => record.item.sourceId != sourceId)
        .toList();
    if (iso) {
      await _write(isoHistory: records);
      _isoHistory = records;
    } else if (audio) {
      await _write(audioHistory: records);
      _audioHistory = records;
    } else {
      await _write(videoHistory: records);
      _videoHistory = records;
    }
    _notifyChanged();
  });

  /// 清空当前来源的视频、音频与 ISO 最近播放记录，不删除实际播放进度。
  Future<void> clearAllPlaybackHistory(String sourceId) => _enqueue(() async {
    await _load();
    final video = _videoHistory
        .where((record) => record.item.sourceId != sourceId)
        .toList();
    final audio = _audioHistory
        .where((record) => record.item.sourceId != sourceId)
        .toList();
    final iso = _isoHistory
        .where((record) => record.item.sourceId != sourceId)
        .toList();
    await _write(videoHistory: video, audioHistory: audio, isoHistory: iso);
    _videoHistory = video;
    _audioHistory = audio;
    _isoHistory = iso;
    _notifyChanged();
  });

  /// 只隐藏当前来源已有的继续播放项，保留最近播放和底层续播点。
  Future<void> clearContinuePlayback(String sourceId) => _enqueue(() async {
    await _load();
    List<MediaLibraryRecord> dismiss(List<MediaLibraryRecord> source) => source
        .map(
          (record) => record.item.sourceId == sourceId
              ? record.copyWith(continueDismissed: true)
              : record,
        )
        .toList();

    final video = dismiss(_videoHistory);
    final audio = dismiss(_audioHistory);
    final iso = dismiss(_isoHistory);
    await _write(videoHistory: video, audioHistory: audio, isoHistory: iso);
    _videoHistory = video;
    _audioHistory = audio;
    _isoHistory = iso;
    _notifyChanged();
  });

  /// 清空当前来源的全部收藏，不影响最近目录和播放历史。
  Future<void> clearFavorites(String sourceId) => _enqueue(() async {
    await _load();
    final records = _favorites
        .where((record) => record.item.sourceId != sourceId)
        .toList();
    await _write(favorites: records);
    _favorites = records;
    _notifyChanged();
  });

  Future<void> removeRecentDirectory(MediaLibraryItem item) =>
      _enqueue(() async {
        await _load();
        final records = _recentDirectories
            .where((record) => !_sameItem(record.item, item))
            .toList();
        await _write(recentDirectories: records);
        _recentDirectories = records;
        _notifyChanged();
      });

  Future<void> clearRecentDirectories(String sourceId) => _enqueue(() async {
    await _load();
    final records = _recentDirectories
        .where((record) => record.item.sourceId != sourceId)
        .toList();
    await _write(recentDirectories: records);
    _recentDirectories = records;
    _notifyChanged();
  });

  List<MediaLibraryRecord> _readRecords(Object? raw) {
    if (raw is! List) {
      _loadHadCorruption = true;
      return const [];
    }
    final records = <MediaLibraryRecord>[];
    for (final value in raw) {
      if (value is! Map) {
        _loadHadCorruption = true;
        continue;
      }
      try {
        records.add(
          MediaLibraryRecord.fromJson(Map<String, dynamic>.from(value)),
        );
      } catch (_) {
        // 单条损坏记录跳过，其他个人资产继续可用。
        _loadHadCorruption = true;
      }
    }
    records.sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return records;
  }

  List<MediaLibraryRecord> _forSource(
    List<MediaLibraryRecord> records,
    String sourceId,
  ) => List.unmodifiable(
    records.where((record) => record.item.sourceId == sourceId),
  );

  List<MediaLibraryRecord> _upsert(
    List<MediaLibraryRecord> source,
    MediaLibraryItem item,
  ) {
    final records = [...source]
      ..removeWhere((record) => _sameItem(record.item, item));
    records.insert(0, MediaLibraryRecord(item: item, updatedAt: _now()));
    return records;
  }

  List<MediaLibraryRecord> _upsertPlaybackSession(
    List<MediaLibraryRecord> source,
    MediaLibraryItem item,
    String playbackSessionId, {
    LocalDiscSessionSnapshot? localDiscSession,
  }) {
    final records = [...source]
      ..removeWhere(
        (record) =>
            record.item.sourceId == item.sourceId &&
            record.playbackSessionId == playbackSessionId,
      );
    records.insert(
      0,
      MediaLibraryRecord(
        item: item,
        updatedAt: _now(),
        playbackSessionId: playbackSessionId,
        localDiscSession: localDiscSession,
      ),
    );
    return records;
  }

  List<MediaLibraryRecord> _boundPerSource(
    List<MediaLibraryRecord> source,
    String sourceId,
    int limit,
  ) {
    var retainedForSource = 0;
    return source.where((record) {
      if (record.item.sourceId != sourceId) return true;
      retainedForSource++;
      return retainedForSource <= limit;
    }).toList();
  }

  List<MediaLibraryRecord> _boundAllSources(
    List<MediaLibraryRecord> source,
    int limit,
  ) {
    final retained = <String, int>{};
    return source.where((record) {
      final sourceId = record.item.sourceId;
      final count = (retained[sourceId] ?? 0) + 1;
      retained[sourceId] = count;
      return count <= limit;
    }).toList();
  }

  int _indexOf(List<MediaLibraryRecord> records, MediaLibraryItem item) =>
      records.indexWhere((record) => _sameItem(record.item, item));

  bool _sameItem(MediaLibraryItem left, MediaLibraryItem right) =>
      left.sourceId == right.sourceId && left.stableKey == right.stableKey;

  bool _sameRecord(MediaLibraryRecord left, MediaLibraryRecord right) {
    final sessionId = right.playbackSessionId;
    if (sessionId != null) {
      return left.item.sourceId == right.item.sourceId &&
          left.item.kind == right.item.kind &&
          left.playbackSessionId == sessionId;
    }
    return left.playbackSessionId == null && _sameItem(left.item, right.item);
  }

  void _notifyChanged() {
    for (final listener in List<void Function()>.of(_listeners)) {
      try {
        listener();
      } catch (_) {
        // 界面监听异常不能回滚已经完成的个人资产写入。
      }
    }
  }

  Future<void> _write({
    List<MediaLibraryRecord>? favorites,
    List<MediaLibraryRecord>? recentDirectories,
    List<MediaLibraryRecord>? videoHistory,
    List<MediaLibraryRecord>? audioHistory,
    List<MediaLibraryRecord>? isoHistory,
  }) async {
    await _prepareForWrite();
    await _file.parent.create(recursive: true);
    final body = const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
      'version': schemaVersion,
      'favorites': (favorites ?? _favorites)
          .map((record) => record.toJson())
          .toList(),
      'recentDirectories': (recentDirectories ?? _recentDirectories)
          .map((record) => record.toJson())
          .toList(),
      'videoHistory': (videoHistory ?? _videoHistory)
          .map((record) => record.toJson())
          .toList(),
      'audioHistory': (audioHistory ?? _audioHistory)
          .map((record) => record.toJson())
          .toList(),
      'isoHistory': (isoHistory ?? _isoHistory)
          .map((record) => record.toJson())
          .toList(),
    });
    final temp = File('${_file.path}.tmp');
    await temp.writeAsString(body, flush: true);
    await temp.rename(_file.path);
  }

  Future<void> _prepareForWrite() async {
    switch (_loadState) {
      case _MediaLibraryLoadState.writable:
        return;
      case _MediaLibraryLoadState.corrupt:
        await _backupCorruptFile();
        _loadState = _MediaLibraryLoadState.writable;
        _corruptOriginalBytes = null;
        return;
      case _MediaLibraryLoadState.readFailed:
        throw FileSystemException('媒体库读取失败，本进程已禁止写入以保护原文件', _file.path);
      case _MediaLibraryLoadState.unsupportedVersion:
        throw FileSystemException(
          '媒体库版本 $_unsupportedVersion 高于当前支持版本 $schemaVersion，已禁止降级写入',
          _file.path,
        );
      case _MediaLibraryLoadState.notLoaded:
        throw StateError('媒体库尚未加载');
    }
  }

  Future<void> _backupCorruptFile() async {
    final originalBytes = _corruptOriginalBytes;
    if (originalBytes == null) {
      throw FileSystemException('缺少损坏媒体库的原始字节', _file.path);
    }

    late List<int> currentBytes;
    try {
      currentBytes = await _file.readAsBytes();
    } catch (_) {
      throw FileSystemException('无法复核损坏媒体库，已禁止写入', _file.path);
    }
    if (!_sameBytes(originalBytes, currentBytes)) {
      throw FileSystemException('媒体库加载后已发生变化，已禁止写入', _file.path);
    }

    final timestamp = _now().toUtc().microsecondsSinceEpoch;
    for (var index = 0; index < 1000; index++) {
      final suffix = index == 0 ? '' : '-$index';
      final backup = File('${_file.path}.corrupt-$timestamp$suffix.bak');
      try {
        await backup.create(exclusive: true);
      } on FileSystemException {
        if (await backup.exists()) continue;
        rethrow;
      }
      try {
        await backup.writeAsBytes(originalBytes, flush: true);
        final verified = await backup.readAsBytes();
        if (!_sameBytes(originalBytes, verified)) {
          throw FileSystemException('损坏媒体库备份校验失败', backup.path);
        }
        return;
      } catch (_) {
        throw FileSystemException('损坏媒体库备份失败', backup.path);
      }
    }
    throw FileSystemException('无法分配唯一的损坏媒体库备份名', _file.path);
  }

  bool _sameBytes(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final task = _pending.then((_) => action());
    _pending = task.then<void>((_) {}, onError: (_) {});
    return task;
  }
}
