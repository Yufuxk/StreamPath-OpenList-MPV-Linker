/// OpenList / AList 播放失败自动恢复配置。
///
/// 默认关闭，确保升级后不改变既有播放器、WebDAV、字幕和续播行为。
/// 后台地址应指向站点根地址（可包含反向代理子路径），不要填写媒体文件
/// 地址；如果误填以 `/dav` 结尾的 WebDAV 地址，兼容层会自动去掉该段。
class OpenListRecoveryConfig {
  const OpenListRecoveryConfig({
    this.enabled = false,
    this.baseUrl = '',
    this.username = '',
    this.password = '',
    this.token = '',
  });

  /// 是否在 MPV 明确报告媒体加载/读取失败后尝试自动恢复。
  final bool enabled;

  /// OpenList / AList 后台根地址，如 `https://pan.example.com`。
  final String baseUrl;

  /// 后台管理员用户名；使用 [token] 时可留空。
  final String username;

  /// 后台管理员密码；使用 [token] 时可留空。
  final String password;

  /// 可选管理员 Token。非空时优先使用，兼容启用了 2FA 的账号。
  final String token;

  bool get hasCredentials =>
      token.trim().isNotEmpty ||
      (username.trim().isNotEmpty && password.isNotEmpty);

  bool get isUsable => enabled && baseUrl.trim().isNotEmpty && hasCredentials;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'enabled': enabled,
    'baseUrl': baseUrl,
    'username': username,
    'password': password,
    'token': token,
  };

  factory OpenListRecoveryConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const OpenListRecoveryConfig();
    return OpenListRecoveryConfig(
      enabled: json['enabled'] as bool? ?? false,
      baseUrl: json['baseUrl'] as String? ?? '',
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
      token: json['token'] as String? ?? '',
    );
  }
}
