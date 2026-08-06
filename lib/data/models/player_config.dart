/// 外部播放器配置模型（JSON 持久化，见 [ConfigManager]）。
library;

import '../../core/constants.dart';
import '../../core/utils/extension_filter.dart';
import '../../core/utils/file_sort.dart';

///
/// `args` 为启动参数模板列表，每项支持占位符：
/// - `{url}`     视频流地址（必填，模板缺失时自动追加到末尾）；
/// - `{subfile}` 匹配到的字幕地址（无字幕时该参数项被移除）；
/// - `{start}`   续播秒数（无进度时该参数项被移除）。
///
/// 示例 JSON：
/// ```json
/// {
///   "name": "mpv",
///   "executable": "mpv",
///   "args": ["--sub-file={subfile}", "{url}", "--start={start}"],
///   "subtitleInjectionEnabled": true,
///   "subtitleAutoSelectEnabled": true,
///   "resumeEnabled": true,
///   "playerStartupTimeoutSeconds": 60
/// }
/// ```
class PlayerConfig {
  const PlayerConfig({
    required this.name,
    required this.executable,
    this.args = const [],
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

  /// 播放器显示名。
  final String name;

  /// 可执行文件路径（绝对路径或 PATH 中的命令名，如 `mpv`）。
  final String executable;

  /// 启动参数模板列表（每项一行，可含占位符）。
  final List<String> args;

  /// 是否自动匹配并注入同级目录外挂字幕。
  final bool subtitleInjectionEnabled;

  /// 是否在注入后自动选择外挂字幕。
  ///
  /// 只有 [subtitleInjectionEnabled] 开启时才生效；关闭时保留 MPV
  /// 在注入前已选择的内封字幕或无字幕状态。
  final bool subtitleAutoSelectEnabled;

  /// 旧代码兼容访问器；旧总开关语义等于“注入并自动选择”。
  @Deprecated('请分别使用 subtitleInjectionEnabled 与 subtitleAutoSelectEnabled')
  bool get subtitleEnabled =>
      subtitleInjectionEnabled && subtitleAutoSelectEnabled;

  /// 是否自动注入续播参数（`{start}`）。
  final bool resumeEnabled;

  /// 文件浏览页隐藏的后缀（规范化：小写、含点，如 `['.ass']`）。
  ///
  /// 仅 UI 层隐藏：软件后台仍持有完整文件引用，字幕自动匹配、
  /// 播放列表切集等均不受影响（隐藏 .ass 不妨碍外挂字幕加载）。
  final List<String> hiddenExtensions;

  /// 文件浏览页启动时使用的默认排序方式。
  final FileSortMode defaultSortMode;

  /// 文件浏览页启动时使用的默认排序顺序。
  final FileSortDirection defaultSortDirection;

  /// 新启动的 MPV 等待首个有效播放状态的最长时间（秒）。
  final int playerStartupTimeoutSeconds;

  /// 模板中是否包含字幕占位符。
  bool get hasSubtitlePlaceholder => args.any((a) => a.contains('{subfile}'));

  /// 模板中是否包含续播占位符。
  bool get hasStartPlaceholder => args.any((a) => a.contains('{start}'));

  /// 内置默认配置：mpv（走系统 PATH，无需绝对路径）。
  static PlayerConfig defaultMpv() => const PlayerConfig(
    name: 'mpv',
    executable: 'mpv',
    args: ['--sub-file={subfile}', '{url}', '--start={start}'],
    subtitleInjectionEnabled: true,
    subtitleAutoSelectEnabled: true,
    resumeEnabled: true,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'executable': executable,
    'args': args,
    'subtitleInjectionEnabled': subtitleInjectionEnabled,
    'subtitleAutoSelectEnabled': subtitleAutoSelectEnabled,
    'resumeEnabled': resumeEnabled,
    'hiddenExtensions': hiddenExtensions,
    'defaultSortMode': defaultSortMode.jsonValue,
    'defaultSortDirection': defaultSortDirection.jsonValue,
    'playerStartupTimeoutSeconds': playerStartupTimeoutSeconds,
  };

  factory PlayerConfig.fromJson(Map<String, dynamic> json) {
    final legacyEnabled = json['subtitleEnabled'] as bool?;
    final injectionEnabled =
        (json['subtitleInjectionEnabled'] as bool?) ?? legacyEnabled ?? true;
    final autoSelectEnabled =
        injectionEnabled &&
        ((json['subtitleAutoSelectEnabled'] as bool?) ?? legacyEnabled ?? true);
    return PlayerConfig(
      name: (json['name'] as String?) ?? '播放器',
      executable: (json['executable'] as String?) ?? '',
      args: (json['args'] as List?)?.whereType<String>().toList() ?? const [],
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

/// 读取用户可手工编辑的启动等待秒数，并限制在安全范围内。
int playerStartupTimeoutSecondsFromJson(Object? value) {
  final parsed = value is num
      ? value.toInt()
      : int.tryParse(value?.toString().trim() ?? '');
  return (parsed ?? AppConstants.defaultPlayerStartupTimeoutSeconds)
      .clamp(
        AppConstants.minPlayerStartupTimeoutSeconds,
        AppConstants.maxPlayerStartupTimeoutSeconds,
      )
      .toInt();
}
