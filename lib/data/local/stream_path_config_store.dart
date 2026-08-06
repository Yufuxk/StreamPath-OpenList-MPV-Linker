import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/app_paths.dart';
import '../models/connection_config.dart';
import '../models/player_config.dart';
import '../models/stream_path_config.dart';

/// StreamPath 统一配置管理（JSON 文件读写 + 内存缓存）。
///
/// 配置文件：数据目录 `stream_path_config.json`（集中存放，见 [AppPaths]）。
/// 首次启动自动迁移旧的 `player_config.json` + `connection_config.json`
/// （位于应用支持目录）合并写入新文件后删除旧文件。
class StreamPathConfigStore {
  StreamPathConfigStore._(this._configFile);

  final File _configFile;

  /// 最近一次成功加载的配置（内存缓存，避免重复读盘）。
  StreamPathConfig? _cached;

  /// 创建配置管理器：定位到数据目录下的配置文件。
  static Future<StreamPathConfigStore> create() async {
    final dir = await AppPaths.dataDirectory();
    return forPath(p.join(dir.path, AppConstants.configFileName));
  }

  /// 以指定配置文件路径创建（测试注入临时目录用）。
  @visibleForTesting
  static StreamPathConfigStore forPath(String configFilePath) =>
      StreamPathConfigStore._(File(configFilePath));

  /// 当前配置（内存缓存）；未加载过时返回默认配置。
  StreamPathConfig get current => _cached ?? StreamPathConfig.defaults();

  /// 加载配置。
  ///
  ///  - 文件不存在 → 尝试迁移旧配置文件，否则返回默认配置；
  ///  - JSON 损坏 / 结构非法 → 抛 [AppException.config]。
  Future<StreamPathConfig> load() async {
    if (_cached != null) return _cached!;

    if (!_configFile.existsSync()) {
      await migrateLegacyFiles();
      if (!_configFile.existsSync()) {
        _cached = StreamPathConfig.defaults();
        return _cached!;
      }
    }

    try {
      final raw = await _configFile.readAsString();
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) {
        throw const FormatException('配置根节点必须是 JSON 对象');
      }
      _cached = StreamPathConfig.fromJson(json);
      return _cached!;
    } on FormatException catch (e) {
      throw AppException.config('配置文件损坏：${e.message}', e);
    } on FileSystemException catch (e) {
      throw AppException.storage('读取配置文件失败：${e.message}', e);
    }
  }

  /// 保存配置到 JSON 文件并更新内存缓存。
  Future<void> save(StreamPathConfig config) async {
    try {
      await _configFile.parent.create(recursive: true);
      final body = const JsonEncoder.withIndent('  ').convert(config.toJson());
      await _configFile.writeAsString(body, flush: true);
      _cached = config;
    } on FileSystemException catch (e) {
      throw AppException.storage('保存配置文件失败：${e.message}', e);
    }
  }

  // ── 便捷访问（兼容旧 ConfigManager / ConnectionConfigStore 用法） ──

  /// 播放器部分配置。
  Future<PlayerConfig> loadPlayer() async =>
      (await load()).toPlayerConfig();

  /// 连接部分配置。
  Future<ConnectionConfig> loadConnection() async =>
      (await load()).toConnectionConfig();

  /// 仅更新连接部分（其余字段保持不变）。
  Future<void> saveConnection(ConnectionConfig connection) async {
    final config = await load();
    await save(StreamPathConfig.fromParts(config.toPlayerConfig(), connection));
  }

  // ── 旧配置迁移 ────────────────────────────────────────────────

  /// 迁移旧的 player_config.json / connection_config.json：合并写入
  /// 新配置文件后删除旧文件。旧文件不存在时无操作。
  ///
  /// [legacyDir] 仅在测试中注入（默认应用支持目录）。
  @visibleForTesting
  Future<void> migrateLegacyFiles({Directory? legacyDir}) async {
    final Directory supportDir;
    try {
      supportDir = legacyDir ?? await getApplicationSupportDirectory();
    } catch (_) {
      return;
    }
    final oldPlayer =
        File(p.join(supportDir.path, AppConstants.playerConfigFileName));
    final oldConnection =
        File(p.join(supportDir.path, AppConstants.connectionConfigFileName));
    if (!oldPlayer.existsSync() && !oldConnection.existsSync()) return;

    StreamPathConfig merged = StreamPathConfig.defaults();
    try {
      if (oldPlayer.existsSync()) {
        final player = PlayerConfig.fromJson(
            jsonDecode(await oldPlayer.readAsString()) as Map<String, dynamic>);
        merged = StreamPathConfig.fromParts(player, merged.toConnectionConfig());
      }
      if (oldConnection.existsSync()) {
        final connection = ConnectionConfig.fromJson(
            jsonDecode(await oldConnection.readAsString())
                as Map<String, dynamic>);
        merged =
            StreamPathConfig.fromParts(merged.toPlayerConfig(), connection);
      }
      await save(merged);
      // 迁移成功后删除旧文件。
      for (final f in [oldPlayer, oldConnection]) {
        if (f.existsSync()) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
    } on FormatException {
      // 旧文件损坏：保留旧文件，新文件不落盘（不阻塞启动）。
    }
  }
}
