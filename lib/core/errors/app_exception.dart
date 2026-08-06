/// StreamPath 统一异常体系。
///
/// 所有跨层错误都包装为 [AppException]，UI 层通过 `on AppException catch (e)`
/// 统一捕获并展示 [message]。内部按场景分为五类子异常，
/// 通过命名工厂便捷构造（如 `AppException.network(...)`）。
sealed class AppException implements Exception {
  const AppException(this.message, {this.cause});

  /// 面向用户的中文错误描述。
  final String message;

  /// 底层原始异常（用于日志/调试）。
  final Object? cause;

  // ── 命名工厂：按场景构造对应子类 ───────────────────────────

  /// 网络/认证错误：连接失败、超时、401/403 等。
  factory AppException.network(String message, [Object? cause]) =>
      NetworkException(message, cause: cause);

  /// 播放器配置缺失或损坏。
  factory AppException.config(String message, [Object? cause]) =>
      ConfigException(message, cause: cause);

  /// 本地存储（Hive/SQLite/配置文件）读写错误。
  factory AppException.storage(String message, [Object? cause]) =>
      StorageException(message, cause: cause);

  /// 外部播放器启动失败（路径无效、启动异常、进程退出等）。
  factory AppException.process(String message, [Object? cause]) =>
      PlayerLaunchException(message, cause: cause);

  /// PROPFIND 响应解析错误。
  factory AppException.parse(String message, [Object? cause]) =>
      ParseException(message, cause: cause);

  @override
  String toString() => '$runtimeType: $message${cause == null ? '' : ' ($cause)'}';
}

/// 网络/认证层错误。
final class NetworkException extends AppException {
  const NetworkException(super.message, {super.cause});
}

/// PROPFIND 响应解析错误。
final class ParseException extends AppException {
  const ParseException(super.message, {super.cause});
}

/// 播放器配置缺失或损坏。
final class ConfigException extends AppException {
  const ConfigException(super.message, {super.cause});
}

/// 外部播放器启动失败。
final class PlayerLaunchException extends AppException {
  const PlayerLaunchException(super.message, {super.cause});
}

/// 本地存储读写错误。
final class StorageException extends AppException {
  const StorageException(super.message, {super.cause});
}
