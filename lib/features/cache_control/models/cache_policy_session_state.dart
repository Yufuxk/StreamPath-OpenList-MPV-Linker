import 'cache_policy_result.dart';

/// 一次播放会话的缓存策略状态（不可变）。
///
/// 用于让集成方区分「本次会话到底发生了什么」，而不是从 URL 历史
/// 结果推断：配置关闭、用户手动参数跳过、TS 直链、正常注入四种
/// 分支各自记录明确状态，避免旧结果污染本次决策。
class CachePolicySessionState {
  const CachePolicySessionState({
    required this.sessionId,
    required this.url,
    required this.injected,
    this.result,
    this.tsOnly = false,
  });

  /// 会话标识（与播放器会话一一对应）。
  final String sessionId;

  /// 本次播放的媒体 URL。
  final String url;

  /// 是否注入了缓存参数（false = 配置关闭/用户手动参数跳过）。
  final bool injected;

  /// 正常策略注入时的完整结果；[injected] 为 true 时非 null。
  final CachePolicyResult? result;

  /// 仅注入 TS 防护参数（--demuxer-seekable-cache=no）的直链分支：
  /// 有注入，但不启动普通缓存监控。
  final bool tsOnly;

  /// 是否应启动播放中动态监控（正常注入且非 TS 直链）。
  bool get shouldMonitor => injected && !tsOnly && result != null;
}
