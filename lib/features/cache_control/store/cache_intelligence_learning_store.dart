import 'dart:convert';
import 'dart:io';

import '../models/cache_learning_data.dart';

/// 匿名聚合学习数据存储；所有读改写通过队列串行化。
class CacheIntelligenceLearningStore {
  CacheIntelligenceLearningStore._(this._file);

  static const String fileName = 'cache_intelligence_learning.json';
  static const int maxBitrateBuckets = 256;
  static const int maxSourceProfiles = 128;

  final File _file;
  CacheLearningData? _cached;
  Future<void> _pending = Future<void>.value();

  static CacheIntelligenceLearningStore forPath(String path) =>
      CacheIntelligenceLearningStore._(File(path));

  Future<T> read<T>(T Function(CacheLearningData data) reader) =>
      _enqueue(() async => reader(await _load()));

  Future<bool> update(void Function(CacheLearningData data) mutation) =>
      _enqueue(() async {
        try {
          final data = await _load();
          mutation(data);
          _trim(data);
          await _save(data);
          return true;
        } catch (_) {
          return false;
        }
      });

  /// 清空聚合学习数据和内存副本。
  Future<bool> clear() => _enqueue(() async {
    try {
      for (final file in [_file, File('${_file.path}.tmp')]) {
        if (await file.exists()) await file.delete();
      }
      _cached = CacheLearningData();
      return true;
    } catch (_) {
      return false;
    }
  });

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final task = _pending.then((_) => action());
    _pending = task.then<void>((_) {}, onError: (_) {});
    return task;
  }

  Future<CacheLearningData> _load() async {
    final cached = _cached;
    if (cached != null) return cached;
    try {
      if (_file.existsSync()) {
        final decoded = jsonDecode(await _file.readAsString());
        if (decoded is Map<String, dynamic>) {
          _cached = CacheLearningData.fromJson(decoded);
          return _cached!;
        }
      }
    } catch (_) {}
    _cached = CacheLearningData();
    return _cached!;
  }

  Future<void> _save(CacheLearningData data) async {
    await _file.parent.create(recursive: true);
    final body = const JsonEncoder.withIndent('  ').convert(data.toJson());
    final temp = File('${_file.path}.tmp');
    await temp.writeAsString(body, flush: true);
    await temp.rename(_file.path);
  }

  static void _trim(CacheLearningData data) {
    if (data.bitrateBuckets.length > maxBitrateBuckets) {
      final keys = data.bitrateBuckets.keys.toList();
      for (final key in keys.take(keys.length - maxBitrateBuckets)) {
        data.bitrateBuckets.remove(key);
      }
    }
    if (data.sourceProfiles.length > maxSourceProfiles) {
      final entries = data.sourceProfiles.entries.toList()
        ..sort(
          (a, b) =>
              a.value.updatedAtEpochMs.compareTo(b.value.updatedAtEpochMs),
        );
      for (final entry in entries.take(entries.length - maxSourceProfiles)) {
        data.sourceProfiles.remove(entry.key);
      }
    }
  }
}
