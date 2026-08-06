import '../../core/utils/extension_filter.dart';
import '../../core/utils/file_sort.dart';
import '../../core/constants.dart';
import 'connection_config.dart';
import 'player_config.dart';

/// StreamPath 统一用户配置（平铺结构，集中存放，用户可自行编辑）。
///
/// 存储于数据目录 `stream_path_config.json`：
/// ```json
/// {
///   "serverUrl": "http://192.168.2.124:5244/dav",
///   "username": "user",
///   "password": "pass",
///   "playerName": "mpv",
///   "playerExecutable": "mpv",
///   "playerArgs": ["--sub-file={subfile}", "{url}", "--start={start}"],
///   "subtitleInjectionEnabled": true,
///   "subtitleAutoSelectEnabled": true,
///   "resumeEnabled": true,
///   "hiddenExtensions": [".ass"],
///   "defaultSortMode": "name",
///   "defaultSortDirection": "ascending",
///   "playerStartupTimeoutSeconds": 60
/// }
/// ```
/// 由 [StreamPathConfigStore] 读写；兼容旧的 player_config.json 与
/// connection_config.json（首次启动自动迁移合并）。
class StreamPathConfig {
  const StreamPathConfig({
    this.serverUrl = '',
    this.username = '',
    this.password = '',
    this.playerName = 'mpv',
    this.playerExecutable = 'mpv',
    this.playerArgs = const [
      '--sub-file={subfile}',
      '{url}',
      '--start={start}',
    ],
    bool subtitleInjectionEnabled = true,
    bool subtitleAutoSelectEnabled = true,
    bool? subtitleEnabled,
    this.resumeEnabled = true,
    this.hiddenExtensions = const [],
    this.defaultSortMode = FileSortMode.name,
    this.defaultSortDirection = FileSortDirection.ascending,
    this.playerStartupTimeoutSeconds =
        AppConstants.defaultPlayerStartupTimeoutSeconds,
  }) : subtitleInjectionEnabled = subtitleEnabled ?? subtitleInjectionEnabled,
       subtitleAutoSelectEnabled =
           (subtitleEnabled ?? subtitleInjectionEnabled) &&
           (subtitleEnabled ?? subtitleAutoSelectEnabled);

  // ── 连接信息 ─────────────────────────────────────────────────
  final String serverUrl;
  final String username;
  final String password;

  // ── 播放器配置 ───────────────────────────────────────────────
  final String playerName;
  final String playerExecutable;
  final List<String> playerArgs;

  /// 自动匹配并注入同级目录外挂字幕。
  final bool subtitleInjectionEnabled;

  /// 注入后自动选择外挂字幕；依赖 [subtitleInjectionEnabled]。
  final bool subtitleAutoSelectEnabled;

  /// 旧代码兼容访问器；旧总开关语义等于“注入并自动选择”。
  @Deprecated('请分别使用 subtitleInjectionEnabled 与 subtitleAutoSelectEnabled')
  bool get subtitleEnabled =>
      subtitleInjectionEnabled && subtitleAutoSelectEnabled;
  final bool resumeEnabled;

  // ── 文件浏览 ─────────────────────────────────────────────────
  final List<String> hiddenExtensions;

  /// 文件浏览页启动时使用的默认排序方式。
  final FileSortMode defaultSortMode;

  /// 文件浏览页启动时使用的默认排序顺序。
  final FileSortDirection defaultSortDirection;

  /// 新启动的 MPV 等待首个有效播放状态的最长时间（秒）。
  final int playerStartupTimeoutSeconds;

  /// 是否包含完整连接信息（可自动连接）。
  bool get isConnectionComplete =>
      serverUrl.trim().isNotEmpty &&
      username.trim().isNotEmpty &&
      password.isNotEmpty;

  /// 转 [ConnectionConfig]（供连接逻辑使用）。
  ConnectionConfig toConnectionConfig() => ConnectionConfig(
    baseUrl: serverUrl,
    username: username,
    password: password,
  );

  /// 转 [PlayerConfig]（供播放器服务使用）。
  PlayerConfig toPlayerConfig() => PlayerConfig(
    name: playerName,
    executable: playerExecutable,
    args: playerArgs,
    subtitleInjectionEnabled: subtitleInjectionEnabled,
    subtitleAutoSelectEnabled: subtitleAutoSelectEnabled,
    resumeEnabled: resumeEnabled,
    hiddenExtensions: hiddenExtensions,
    defaultSortMode: defaultSortMode,
    defaultSortDirection: defaultSortDirection,
    playerStartupTimeoutSeconds: playerStartupTimeoutSeconds,
  );

  /// 由 [PlayerConfig] + [ConnectionConfig] 组合（兼容旧代码路径）。
  factory StreamPathConfig.fromParts(
    PlayerConfig player,
    ConnectionConfig connection,
  ) {
    return StreamPathConfig(
      serverUrl: connection.baseUrl,
      username: connection.username,
      password: connection.password,
      playerName: player.name,
      playerExecutable: player.executable,
      playerArgs: player.args,
      subtitleInjectionEnabled: player.subtitleInjectionEnabled,
      subtitleAutoSelectEnabled: player.subtitleAutoSelectEnabled,
      resumeEnabled: player.resumeEnabled,
      hiddenExtensions: player.hiddenExtensions,
      defaultSortMode: player.defaultSortMode,
      defaultSortDirection: player.defaultSortDirection,
      playerStartupTimeoutSeconds: player.playerStartupTimeoutSeconds,
    );
  }

  /// 内置默认配置（mpv）。
  static StreamPathConfig defaults() => const StreamPathConfig();

  Map<String, dynamic> toJson() => <String, dynamic>{
    'serverUrl': serverUrl,
    'username': username,
    'password': password,
    'playerName': playerName,
    'playerExecutable': playerExecutable,
    'playerArgs': playerArgs,
    'subtitleInjectionEnabled': subtitleInjectionEnabled,
    'subtitleAutoSelectEnabled': subtitleAutoSelectEnabled,
    'resumeEnabled': resumeEnabled,
    'hiddenExtensions': hiddenExtensions,
    'defaultSortMode': defaultSortMode.jsonValue,
    'defaultSortDirection': defaultSortDirection.jsonValue,
    'playerStartupTimeoutSeconds': playerStartupTimeoutSeconds,
  };

  factory StreamPathConfig.fromJson(Map<String, dynamic> json) {
    final legacyEnabled = json['subtitleEnabled'] as bool?;
    final injectionEnabled =
        (json['subtitleInjectionEnabled'] as bool?) ?? legacyEnabled ?? true;
    final autoSelectEnabled =
        injectionEnabled &&
        ((json['subtitleAutoSelectEnabled'] as bool?) ?? legacyEnabled ?? true);
    return StreamPathConfig(
      serverUrl: (json['serverUrl'] as String?) ?? '',
      username: (json['username'] as String?) ?? '',
      password: (json['password'] as String?) ?? '',
      playerName: (json['playerName'] as String?) ?? '播放器',
      playerExecutable: (json['playerExecutable'] as String?) ?? '',
      playerArgs:
          (json['playerArgs'] as List?)?.whereType<String>().toList() ??
          const [],
      subtitleInjectionEnabled: injectionEnabled,
      subtitleAutoSelectEnabled: autoSelectEnabled,
      resumeEnabled: (json['resumeEnabled'] as bool?) ?? true,
      hiddenExtensions:
          (json['hiddenExtensions'] as List?)
              ?.whereType<String>()
              .map(normalizeExtension)
              .whereType<String>()
              .toList() ??
          const [],
      defaultSortMode: fileSortModeFromJson(json['defaultSortMode']),
      defaultSortDirection: fileSortDirectionFromJson(
        json['defaultSortDirection'],
      ),
      playerStartupTimeoutSeconds: playerStartupTimeoutSecondsFromJson(
        json['playerStartupTimeoutSeconds'],
      ),
    );
  }
}
