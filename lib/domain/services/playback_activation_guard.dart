/// 播放器启动保护状态。
///
/// 进程探测固定每 1 秒最多执行一次；新启动的 MPV 在收到首个有效
/// `file-loaded` 状态前保持等待。超过配置期限仍未激活时，由调用方
/// 终止对应进程并移除下边栏。
class PlaybackActivationGuard {
  static const Duration probeInterval = Duration(seconds: 1);

  DateTime? _deadline;
  DateTime? _nextProbeAt;
  bool? _lastKnownRunning;
  bool _activated = false;

  bool get isWaiting => _deadline != null && !_activated;
  bool get isActivated => _activated;
  bool? get lastKnownRunning => _lastKnownRunning;

  void reset() {
    _deadline = null;
    _nextProbeAt = null;
    _lastKnownRunning = null;
    _activated = false;
  }

  void start({required DateTime now, required Duration timeout}) {
    _deadline = now.add(timeout);
    _nextProbeAt = now;
    _lastKnownRunning = null;
    _activated = false;
  }

  bool shouldProbe(DateTime now) {
    final next = _nextProbeAt;
    return next == null || !now.isBefore(next);
  }

  void recordProbe({required DateTime now, required bool running}) {
    _lastKnownRunning = running;
    _nextProbeAt = now.add(probeInterval);
  }

  void confirmActivation() {
    _activated = true;
    _deadline = null;
  }

  bool hasTimedOut(DateTime now) {
    final deadline = _deadline;
    return isWaiting && deadline != null && !now.isBefore(deadline);
  }
}
