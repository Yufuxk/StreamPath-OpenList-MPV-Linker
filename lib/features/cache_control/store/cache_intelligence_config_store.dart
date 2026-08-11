import 'dart:convert';
import 'dart:io';

import '../models/cache_intelligence_config.dart';

/// 第三阶段智能缓存配置存储。
///
/// 每次 [load] 都重读文件，使设置页和用户手工编辑保持同步。失败时回退
/// 默认影子模式，任何异常都不进入播放链路。
class CacheIntelligenceConfigStore {
  CacheIntelligenceConfigStore._(this._file);

  static const String configFileName = 'cache_intelligence.json';

  final File _file;
  CacheIntelligenceConfig? _cached;

  static CacheIntelligenceConfigStore forPath(String path) =>
      CacheIntelligenceConfigStore._(File(path));

  CacheIntelligenceConfig get current =>
      _cached ?? CacheIntelligenceConfig.defaults();

  Future<CacheIntelligenceConfig> load() async {
    _cached = await _read();
    return _cached!;
  }

  Future<CacheIntelligenceConfig> _read() async {
    if (!_file.existsSync()) return CacheIntelligenceConfig.defaults();
    try {
      final decoded = jsonDecode(await _file.readAsString());
      if (decoded is Map<String, dynamic>) {
        return CacheIntelligenceConfig.fromJson(decoded);
      }
    } catch (_) {}
    return CacheIntelligenceConfig.defaults();
  }

  Future<void> ensureDefault() async {
    try {
      if (!_file.existsSync()) await save(CacheIntelligenceConfig.defaults());
    } catch (_) {}
  }

  Future<bool> save(CacheIntelligenceConfig config) async {
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
