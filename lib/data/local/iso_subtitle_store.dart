import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// ISO 用户绑定独立于可重建缓存；null 表示明确禁用该节目外挂。
class IsoSubtitleStore {
  IsoSubtitleStore(this.directory);

  final Directory directory;
  static Future<void> _writes = Future<void>.value();

  Future<({Map<String, String?> bindings, bool changed})> load(
    String key,
    String revision,
  ) async {
    final file = _file(key);
    if (!await file.exists()) {
      return (bindings: <String, String?>{}, changed: false);
    }
    final raw = jsonDecode(await file.readAsString());
    if (raw is! Map ||
        raw['version'] != 1 ||
        raw['revision'] is! String ||
        raw['bindings'] is! Map) {
      throw const FormatException('Invalid ISO subtitle map');
    }
    final bindings = <String, String?>{};
    for (final entry in (raw['bindings'] as Map).entries) {
      if (entry.key is! String ||
          !RegExp(r'^\d{5}$').hasMatch(entry.key) ||
          (entry.value != null &&
              (entry.value is! String || !_validPath(entry.value)))) {
        throw const FormatException('Invalid ISO subtitle binding');
      }
      bindings[entry.key as String] = entry.value as String?;
    }
    return (
      bindings: bindings,
      changed: revision.isEmpty || raw['revision'] != revision,
    );
  }

  Future<Map<String, String?>> update(
    String key,
    String revision,
    String id,
    String? path, {
    bool automatic = false,
  }) {
    if (!RegExp(r'^\d{5}$').hasMatch(id) ||
        (path != null && !_validPath(path))) {
      throw ArgumentError('Invalid ISO subtitle binding');
    }
    final result = _writes.then((_) async {
      // 保存前也验证已有文件，禁止覆盖损坏或未来版本。
      final saved = await load(key, revision);
      final snapshot = saved.changed ? <String, String?>{} : saved.bindings;
      if (automatic) {
        snapshot.remove(id);
      } else {
        snapshot[id] = path;
      }
      await directory.create(recursive: true);
      final file = _file(key);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({'version': 1, 'revision': revision, 'bindings': snapshot}),
        flush: true,
      );
      await temporary.rename(file.path);
      return snapshot;
    });
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  File _file(String key) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) {
      throw ArgumentError.value(key, 'key');
    }
    return File(p.join(directory.path, '$key.json'));
  }

  static bool _validPath(String value) =>
      value.isNotEmpty &&
      !value.contains('\\') &&
      !value.contains(':') &&
      !value.contains('?') &&
      !value.contains('#') &&
      !value.startsWith('/') &&
      !value
          .split('/')
          .any((part) => part.isEmpty || part == '.' || part == '..');
}
