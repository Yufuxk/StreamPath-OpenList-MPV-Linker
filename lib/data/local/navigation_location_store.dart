import 'dart:convert';
import 'dart:io';

import '../models/appearance_config.dart';

/// 各挂载最后成功打开的相对目录；临时模式只使用内存。
class NavigationLocationStore {
  NavigationLocationStore(this.file, {required this.mode});

  final File file;
  DirectoryMemoryMode mode;
  final Map<String, String> _paths = {};
  final Map<String, String> _lastSources = {};
  Future<void> _tail = Future<void>.value();

  String? pathFor(String sourceId) => _paths[sourceId];
  String? lastSource(String kind) => _lastSources[kind];

  Future<void> load() async {
    if (mode != DirectoryMemoryMode.persistent || !await file.exists()) return;
    final json = jsonDecode(await file.readAsString());
    if (json is! Map) {
      throw const FormatException('Invalid navigation location record');
    }
    final paths = json['paths'];
    final sources = json['lastSources'];
    if (paths is Map) {
      for (final entry in paths.entries) {
        if (entry.key is String && entry.value is String) {
          _paths[entry.key as String] = entry.value as String;
        }
      }
    }
    if (sources is Map) {
      for (final entry in sources.entries) {
        if (entry.key is String && entry.value is String) {
          _lastSources[entry.key as String] = entry.value as String;
        }
      }
    }
  }

  Future<void> remember({
    required String sourceId,
    required String kind,
    required String path,
  }) async {
    _paths[sourceId] = path;
    _lastSources[kind] = sourceId;
    if (mode == DirectoryMemoryMode.persistent) await _save();
  }

  Future<void> forget(String sourceId) async {
    _paths.remove(sourceId);
    _lastSources.removeWhere((_, value) => value == sourceId);
    if (mode == DirectoryMemoryMode.persistent) await _save();
  }

  Future<void> setMode(DirectoryMemoryMode next) async {
    if (next == mode) return;
    mode = next;
    if (next == DirectoryMemoryMode.temporary) {
      await _enqueue(() async {
        if (await file.exists()) await file.delete();
      });
    } else {
      await _save();
    }
  }

  Future<void> _save() => _enqueue(() async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      jsonEncode({'paths': _paths, 'lastSources': _lastSources}),
      flush: true,
    );
    await temp.rename(file.path);
  });

  Future<void> _enqueue(Future<void> Function() action) {
    final operation = _tail.then((_) => action());
    _tail = operation.catchError((Object _) {});
    return operation;
  }
}
