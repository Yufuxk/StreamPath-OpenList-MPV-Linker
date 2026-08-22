class SessionProgressSyncCoordinator {
  final Map<String, _SessionProgressSyncState> _states = {};

  int claim(String sessionId) {
    final state = _states.putIfAbsent(sessionId, _SessionProgressSyncState.new);
    return ++state.generation;
  }

  /// 立即使旧代次失效，并在旧同步完全结束后返回新代次。
  ///
  /// 调用方必须等本 Future 完成后再注册新 runtime，避免未经过协调器的
  /// 实时进度写入与已经开始的旧同步交错。
  Future<int> claimAndDrain(String sessionId) {
    final state = _states.putIfAbsent(sessionId, _SessionProgressSyncState.new);
    final generation = ++state.generation;
    final pending = state.tail;
    return pending.then((_) => generation);
  }

  bool isCurrent(String sessionId, int generation) =>
      _states[sessionId]?.generation == generation;

  Future<T?> run<T>({
    required String sessionId,
    required int generation,
    required Future<T> Function() action,
  }) {
    final state = _states.putIfAbsent(sessionId, _SessionProgressSyncState.new);
    final task = state.tail.then<T?>((_) async {
      if (state.generation != generation) return null;
      return action();
    });
    state.tail = task.then<void>((_) {}, onError: (_) {});
    return task;
  }
}

class _SessionProgressSyncState {
  int generation = 0;
  Future<void> tail = Future<void>.value();
}
