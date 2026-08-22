/// OpenList/AList 索引更新配置。
class OpenListIndexConfig {
  const OpenListIndexConfig({
    this.autoUpdateEnabled = false,
    this.updateIntervalMinutes = defaultUpdateIntervalMinutes,
    this.userToken = '',
  });

  static const int minUpdateIntervalMinutes = 5;
  static const int maxUpdateIntervalMinutes = 10080;
  static const int defaultUpdateIntervalMinutes = 60;

  final bool autoUpdateEnabled;
  final int updateIntervalMinutes;

  /// 只供普通用户索引搜索使用，不能复用管理员 Token。
  final String userToken;

  OpenListIndexConfig get normalized => OpenListIndexConfig(
    autoUpdateEnabled: autoUpdateEnabled,
    updateIntervalMinutes: updateIntervalMinutes.clamp(
      minUpdateIntervalMinutes,
      maxUpdateIntervalMinutes,
    ),
    userToken: userToken.trim(),
  );

  Map<String, dynamic> toJson({bool includeSecrets = true}) =>
      <String, dynamic>{
        'autoUpdateEnabled': autoUpdateEnabled,
        'updateIntervalMinutes': normalized.updateIntervalMinutes,
        if (includeSecrets) 'userToken': userToken.trim(),
      };

  factory OpenListIndexConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const OpenListIndexConfig();
    final rawInterval = json['updateIntervalMinutes'];
    final interval = rawInterval is num
        ? rawInterval.toInt()
        : int.tryParse(rawInterval?.toString() ?? '') ??
              defaultUpdateIntervalMinutes;
    return OpenListIndexConfig(
      autoUpdateEnabled: json['autoUpdateEnabled'] as bool? ?? false,
      updateIntervalMinutes: interval,
      userToken: (json['userToken'] as String?) ?? '',
    ).normalized;
  }
}
