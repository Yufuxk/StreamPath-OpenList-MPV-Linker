import 'dart:convert';
import 'dart:io';

import '../models/cache_policy_config.dart';

/// 缓存策略配置管理（JSON 文件读写 + 内存缓存，模块内自包含）。
///
/// 配置文件：数据目录 `cache_policy.json`，与主配置
/// `stream_path_config.json` 完全独立。本模块不依赖项目其他模块：
/// 文件路径由集成方（[CachePolicyConfigStore.forPath]）显式传入，
/// 不自行定位数据目录。
///
/// 容错原则：本模块是 MPV 启动链路上的**增强层**，任何配置损坏、
/// 读写失败都静默回退默认配置，绝不向调用方抛异常（save 以返回值
/// 报告失败），保证缓存系统异常时播放链路完全不受影响。
class CachePolicyConfigStore {
  CachePolicyConfigStore._(this._configFile);

  final File _configFile;

  /// 配置文件固定文件名（位于数据目录下）。
  static const String configFileName = 'cache_policy.json';

  CachePolicyConfig? _cached;

  /// 以指定配置文件路径创建（集成方传入完整路径）。
  static CachePolicyConfigStore forPath(String configFilePath) =>
      CachePolicyConfigStore._(File(configFilePath));

  /// 当前配置（内存缓存）；未加载过时返回默认配置。
  CachePolicyConfig get current => _cached ?? CachePolicyConfig.defaults();

  /// 加载配置。
  ///
  /// 文件不存在 / JSON 损坏 / 根节点非法 / IO 失败：一律回退默认配置，
  /// 不抛出异常。
  Future<CachePolicyConfig> load() async {
    // 文件很小且每次播放只读取一次；始终重读，确保用户按文档直接编辑
    // 后“重新播放”即可生效，而不必重启整个应用。
    _cached = await _read();
    return _cached!;
  }

  Future<CachePolicyConfig> _read() async {
    if (!_configFile.existsSync()) return CachePolicyConfig.defaults();
    try {
      final raw = await _configFile.readAsString();
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return CachePolicyConfig.defaults();
      return CachePolicyConfig.fromJson(json);
    } catch (_) {
      // 解析/IO 异常一律回退默认，不阻断调用方。
      return CachePolicyConfig.defaults();
    }
  }

  /// 确保配置文件存在：不存在时写入默认配置（用户可在数据目录
  /// 找到并编辑 `cache_policy.json`），已存在（含损坏）不覆盖。
  ///
  /// 集成方在应用启动装配时调用一次；失败静默（不影响播放）。
  Future<void> ensureDefault() async {
    try {
      if (!_configFile.existsSync()) {
        await save(CachePolicyConfig.defaults());
      }
    } catch (_) {
      // 增强层：创建失败静默，load 仍会回退默认。
    }
  }

  /// 保存配置并更新内存缓存；成功返回 true，失败返回 false（不抛出）。
  Future<bool> save(CachePolicyConfig config) async {
    try {
      await _configFile.parent.create(recursive: true);
      final body = const JsonEncoder.withIndent('  ').convert(config.toJson());
      final temp = File('${_configFile.path}.tmp');
      await temp.writeAsString(body, flush: true);
      await temp.rename(_configFile.path);
      _cached = config;
      return true;
    } catch (_) {
      return false;
    }
  }
}
