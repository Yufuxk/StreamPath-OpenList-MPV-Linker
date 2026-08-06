/// WebDAV 连接配置（登录信息持久化 / 配置文件自动连接）。
///
/// 保存到应用支持目录 `connection_config.json`：
/// ```json
/// {
///   "baseUrl": "http://192.168.2.124:5244/dav",
///   "username": "user",
///   "password": "pass"
/// }
/// ```
/// 注意：密码以明文保存在本地配置文件中（本应用单机使用）。
class ConnectionConfig {
  const ConnectionConfig({
    this.baseUrl = '',
    this.username = '',
    this.password = '',
  });

  /// 服务器地址。
  final String baseUrl;

  /// 用户名。
  final String username;

  /// 密码。
  final String password;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'baseUrl': baseUrl,
        'username': username,
        'password': password,
      };

  factory ConnectionConfig.fromJson(Map<String, dynamic> json) =>
      ConnectionConfig(
        baseUrl: (json['baseUrl'] as String?) ?? '',
        username: (json['username'] as String?) ?? '',
        password: (json['password'] as String?) ?? '',
      );
}
