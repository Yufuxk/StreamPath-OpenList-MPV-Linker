import 'dart:convert';
import 'dart:io';

import '../models/cache_expiration_config.dart';

/// 独立缓存过期配置存储；损坏或读写失败时回退安全默认值。
class CacheExpirationConfigStore {
  CacheExpirationConfigStore._(this._file);

  static const String configFileName = 'cache_expiration.json';

  final File _file;
  CacheExpirationConfig? _cached;

  static CacheExpirationConfigStore forPath(String path) =>
      CacheExpirationConfigStore._(File(path));

  CacheExpirationConfig get current =>
      _cached ?? CacheExpirationConfig.defaults();

  Future<CacheExpirationConfig> load() async {
    _cached = await _read();
    return _cached!;
  }

  Future<CacheExpirationConfig> _read() async {
    if (!_file.existsSync()) return CacheExpirationConfig.defaults();
    try {
      final decoded = jsonDecode(await _file.readAsString());
      if (decoded is Map<String, dynamic>) {
        return CacheExpirationConfig.fromJson(decoded);
      }
    } catch (_) {}
    return CacheExpirationConfig.defaults();
  }

  Future<void> ensureDefault() async {
    try {
      if (!_file.existsSync()) await save(CacheExpirationConfig.defaults());
    } catch (_) {}
  }

  Future<bool> save(CacheExpirationConfig config) async {
    try {
      await _file.parent.create(recursive: true);
      final body = const JsonEncoder.withIndent('  ').convert(config.toJson());
      final temp = File('${_file.path}.tmp');
      await temp.writeAsString(body, flush: true);
      await temp.rename(_file.path);
      _cached = config;
      return true;
    } catch (_) {
      return false;
    }
  }
}
