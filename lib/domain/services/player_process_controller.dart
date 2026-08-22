import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

/// 外部播放器进程的不可变身份。
///
/// Windows PID 会复用，因此必须同时绑定可执行文件绝对路径和精确创建时间。
@immutable
class PlayerProcessIdentity {
  PlayerProcessIdentity({
    required this.pid,
    required String executablePath,
    required this.creationTime,
  }) : executablePath = _normalizeExecutablePath(executablePath);

  final int pid;
  final String executablePath;

  /// Windows FILETIME 原始 100ns 计数，不经过 DateTime 精度截断。
  final int creationTime;

  static PlayerProcessIdentity? fromStored({
    required int? pid,
    required String? executablePath,
    required int? creationTime,
  }) {
    if (pid == null ||
        pid <= 0 ||
        executablePath == null ||
        executablePath.trim().isEmpty ||
        creationTime == null ||
        creationTime <= 0) {
      return null;
    }
    final identity = PlayerProcessIdentity(
      pid: pid,
      executablePath: executablePath,
      creationTime: creationTime,
    );
    return identity.isComplete ? identity : null;
  }

  bool get isComplete =>
      pid > 0 && creationTime > 0 && p.windows.isAbsolute(executablePath);

  bool matches(PlayerProcessIdentity other) =>
      pid == other.pid &&
      creationTime == other.creationTime &&
      executablePath.toLowerCase() == other.executablePath.toLowerCase();

  static String _normalizeExecutablePath(String value) =>
      p.windows.normalize(value.trim().replaceAll('/', r'\'));
}

enum PlayerProcessLookupStatus { found, notFound, failed }

/// 绑定确切进程身份后的探活结果。
enum PlayerProcessLiveness { alive, exited, unknown }

typedef PlayerProcessLivenessCycle =
    Future<bool> Function(PlayerProcessLiveness status);
typedef PlayerProcessLivenessDelay = Future<void> Function(Duration duration);

@immutable
class PlayerProcessLookupResult {
  const PlayerProcessLookupResult.found(this.identity)
    : status = PlayerProcessLookupStatus.found;

  const PlayerProcessLookupResult.notFound()
    : status = PlayerProcessLookupStatus.notFound,
      identity = null;

  const PlayerProcessLookupResult.failed()
    : status = PlayerProcessLookupStatus.failed,
      identity = null;

  final PlayerProcessLookupStatus status;
  final PlayerProcessIdentity? identity;
}

typedef PlayerProcessLeaseRechecker =
    Future<PlayerProcessLookupResult> Function();
typedef PlayerProcessLeaseTerminator =
    Future<PlayerTerminationOutcome> Function();
typedef PlayerProcessLeaseCloser = void Function();

/// 在一次身份校验与终止操作之间持续持有的进程租约。
///
/// Windows 默认实现持有同一个进程句柄，直至终止命令返回后才释放；
/// 因此已校验 PID 不会在校验和终止之间被系统复用。
class PlayerProcessLease {
  factory PlayerProcessLease({
    required PlayerProcessIdentity identity,
    required PlayerProcessLeaseRechecker recheck,
    required PlayerProcessLeaseTerminator terminateTree,
    required PlayerProcessLeaseCloser close,
  }) => PlayerProcessLease._(identity, recheck, terminateTree, close);

  PlayerProcessLease._(
    this.identity,
    this._recheck,
    this._terminateTree,
    this._close,
  );

  final PlayerProcessIdentity identity;
  final PlayerProcessLeaseRechecker _recheck;
  final PlayerProcessLeaseTerminator _terminateTree;
  final PlayerProcessLeaseCloser _close;
  bool _closed = false;

  Future<PlayerProcessLookupResult> recheck() => _recheck();

  Future<PlayerTerminationOutcome> terminateTree() => _terminateTree();

  void close() {
    if (_closed) return;
    _closed = true;
    _close();
  }
}

@immutable
class PlayerProcessLeaseLookupResult {
  const PlayerProcessLeaseLookupResult.found(this.lease)
    : status = PlayerProcessLookupStatus.found;

  const PlayerProcessLeaseLookupResult.notFound()
    : status = PlayerProcessLookupStatus.notFound,
      lease = null;

  const PlayerProcessLeaseLookupResult.failed()
    : status = PlayerProcessLookupStatus.failed,
      lease = null;

  final PlayerProcessLookupStatus status;
  final PlayerProcessLease? lease;
}

enum PlayerTerminationOutcome { terminated, alreadyExited, refused, failed }

extension PlayerTerminationOutcomeX on PlayerTerminationOutcome {
  bool get isSafeToRelaunch =>
      this == PlayerTerminationOutcome.terminated ||
      this == PlayerTerminationOutcome.alreadyExited;
}

typedef PlayerProcessSnapshotLoader =
    Future<PlayerProcessLookupResult> Function(int pid);
typedef PlayerProcessLeaseLoader =
    Future<PlayerProcessLeaseLookupResult> Function(int pid);
typedef PlayerPipeServerPidLoader = Future<int?> Function(String pipeName);
typedef PlayerProcessTreeTerminator = Future<bool> Function(int pid);

/// 外部播放器进程身份校验与定向终止边界。
///
/// 业务服务只持有启动时快照；每次终止前由本类重新读取 PID、exe、创建
/// 时间，并在 MPV 会话中额外核对 named pipe 的服务 PID。证据不完整时
/// 失败关闭，不调用进程终止器。
class PlayerProcessController {
  PlayerProcessController({
    PlayerProcessLeaseLoader? leaseLoader,
    PlayerProcessSnapshotLoader? snapshotLoader,
    PlayerPipeServerPidLoader? pipeServerPidLoader,
    PlayerProcessTreeTerminator? processTreeTerminator,
  }) : _leaseLoader =
           leaseLoader ??
           _buildLeaseLoader(
             snapshotLoader: snapshotLoader,
             processTreeTerminator: processTreeTerminator,
           ),
       _pipeServerPidLoader = pipeServerPidLoader ?? _loadWindowsPipeServerPid,
       assert(
         leaseLoader == null || snapshotLoader == null,
         'leaseLoader 与 snapshotLoader 不能同时提供',
       );

  final PlayerProcessLeaseLoader _leaseLoader;
  final PlayerPipeServerPidLoader _pipeServerPidLoader;

  Future<PlayerProcessIdentity?> capture(int pid) async {
    final result = await _openLease(pid);
    final lease = result.lease;
    if (result.status != PlayerProcessLookupStatus.found || lease == null) {
      return null;
    }
    try {
      final identity = lease.identity;
      return identity.pid == pid && identity.isComplete ? identity : null;
    } finally {
      lease.close();
    }
  }

  /// 仅在 PID、可执行路径和创建时间全部匹配时确认进程存活。
  Future<PlayerProcessLiveness> probeOwned(
    PlayerProcessIdentity? expected,
  ) async {
    if (expected == null || !expected.isComplete) {
      return PlayerProcessLiveness.unknown;
    }
    final opened = await _openLease(expected.pid);
    switch (opened.status) {
      case PlayerProcessLookupStatus.notFound:
        return PlayerProcessLiveness.exited;
      case PlayerProcessLookupStatus.failed:
        return PlayerProcessLiveness.unknown;
      case PlayerProcessLookupStatus.found:
        final lease = opened.lease;
        if (lease == null) return PlayerProcessLiveness.unknown;
        try {
          // PID 已被其他进程复用时，原有且受本应用所有的进程视为已退出。
          return expected.matches(lease.identity)
              ? PlayerProcessLiveness.alive
              : PlayerProcessLiveness.exited;
        } finally {
          lease.close();
        }
    }
  }

  Future<PlayerTerminationOutcome> terminateIfOwned({
    required int pid,
    required PlayerProcessIdentity? expected,
    String? ipcPipeName,
    required bool requirePipeOwner,
  }) async {
    final opened = await _openLease(pid);
    if (opened.status == PlayerProcessLookupStatus.notFound) {
      return PlayerTerminationOutcome.alreadyExited;
    }
    if (opened.status == PlayerProcessLookupStatus.failed) {
      return PlayerTerminationOutcome.failed;
    }
    final lease = opened.lease;
    if (lease == null) return PlayerTerminationOutcome.failed;
    try {
      final current = lease.identity;
      if (expected == null ||
          !expected.isComplete ||
          expected.pid != pid ||
          !current.isComplete ||
          !expected.matches(current)) {
        return PlayerTerminationOutcome.refused;
      }

      if (requirePipeOwner) {
        final pipe = ipcPipeName?.trim();
        if (pipe == null || pipe.isEmpty) {
          return PlayerTerminationOutcome.refused;
        }
        final int? pipeOwner;
        try {
          pipeOwner = await _pipeServerPidLoader(pipe);
        } catch (_) {
          return PlayerTerminationOutcome.failed;
        }
        if (pipeOwner == null || pipeOwner != pid) {
          return PlayerTerminationOutcome.refused;
        }
      }

      // 复用同一租约复核身份；默认 Windows 实现此时仍持有原进程句柄。
      final second = await lease.recheck();
      if (second.status == PlayerProcessLookupStatus.notFound) {
        return PlayerTerminationOutcome.alreadyExited;
      }
      if (second.status == PlayerProcessLookupStatus.failed) {
        return PlayerTerminationOutcome.failed;
      }
      final rechecked = second.identity;
      if (rechecked == null || !expected.matches(rechecked)) {
        return PlayerTerminationOutcome.refused;
      }

      try {
        return await lease.terminateTree();
      } catch (_) {
        return PlayerTerminationOutcome.failed;
      }
    } finally {
      lease.close();
    }
  }

  Future<PlayerProcessLeaseLookupResult> _openLease(int pid) async {
    if (pid <= 0) return const PlayerProcessLeaseLookupResult.notFound();
    try {
      return await _leaseLoader(pid);
    } catch (_) {
      return const PlayerProcessLeaseLookupResult.failed();
    }
  }

  static PlayerProcessLeaseLoader _buildLeaseLoader({
    PlayerProcessSnapshotLoader? snapshotLoader,
    PlayerProcessTreeTerminator? processTreeTerminator,
  }) {
    final terminator = processTreeTerminator ?? _terminateWindowsProcessTree;
    if (snapshotLoader == null) {
      return (pid) => _openWindowsLease(pid, terminator);
    }
    return (pid) async {
      final first = await snapshotLoader(pid);
      switch (first.status) {
        case PlayerProcessLookupStatus.notFound:
          return const PlayerProcessLeaseLookupResult.notFound();
        case PlayerProcessLookupStatus.failed:
          return const PlayerProcessLeaseLookupResult.failed();
        case PlayerProcessLookupStatus.found:
          final identity = first.identity;
          if (identity == null) {
            return const PlayerProcessLeaseLookupResult.failed();
          }
          return PlayerProcessLeaseLookupResult.found(
            PlayerProcessLease(
              identity: identity,
              recheck: () => snapshotLoader(pid),
              terminateTree: () async {
                try {
                  return await terminator(pid)
                      ? PlayerTerminationOutcome.terminated
                      : PlayerTerminationOutcome.failed;
                } catch (_) {
                  return PlayerTerminationOutcome.failed;
                }
              },
              close: () {},
            ),
          );
      }
    };
  }

  static Future<PlayerProcessLeaseLookupResult> _openWindowsLease(
    int pid,
    PlayerProcessTreeTerminator terminator,
  ) async {
    if (!Platform.isWindows || pid <= 0) {
      return const PlayerProcessLeaseLookupResult.failed();
    }
    final handle = OpenProcess(
      PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
      FALSE,
      pid,
    );
    if (handle == 0) {
      return GetLastError() == ERROR_INVALID_PARAMETER
          ? const PlayerProcessLeaseLookupResult.notFound()
          : const PlayerProcessLeaseLookupResult.failed();
    }

    final first = _readWindowsIdentity(handle, pid);
    final identity = first.identity;
    if (first.status != PlayerProcessLookupStatus.found || identity == null) {
      CloseHandle(handle);
      return first.status == PlayerProcessLookupStatus.notFound
          ? const PlayerProcessLeaseLookupResult.notFound()
          : const PlayerProcessLeaseLookupResult.failed();
    }
    return PlayerProcessLeaseLookupResult.found(
      PlayerProcessLease(
        identity: identity,
        recheck: () async => _readWindowsIdentity(handle, pid),
        terminateTree: () => _terminateWhileHoldingHandle(
          pid: pid,
          handle: handle,
          terminator: terminator,
        ),
        close: () => CloseHandle(handle),
      ),
    );
  }

  static PlayerProcessLookupResult _readWindowsIdentity(int handle, int pid) {
    final creation = calloc<FILETIME>();
    final exit = calloc<FILETIME>();
    final kernel = calloc<FILETIME>();
    final user = calloc<FILETIME>();
    const pathCapacity = 32768;
    final pathBuffer = calloc<Uint16>(pathCapacity).cast<Utf16>();
    final pathLength = calloc<Uint32>()..value = pathCapacity;
    try {
      final waitResult = WaitForSingleObject(handle, 0);
      if (waitResult == WAIT_OBJECT_0) {
        return const PlayerProcessLookupResult.notFound();
      }
      if (waitResult == WAIT_FAILED ||
          GetProcessTimes(handle, creation, exit, kernel, user) == 0 ||
          QueryFullProcessImageName(handle, 0, pathBuffer, pathLength) == 0) {
        return const PlayerProcessLookupResult.failed();
      }
      final executablePath = pathBuffer.toDartString(length: pathLength.value);
      final creationTime =
          (creation.ref.dwHighDateTime << 32) | creation.ref.dwLowDateTime;
      final identity = PlayerProcessIdentity(
        pid: pid,
        executablePath: executablePath,
        creationTime: creationTime,
      );
      return identity.isComplete
          ? PlayerProcessLookupResult.found(identity)
          : const PlayerProcessLookupResult.failed();
    } finally {
      free(creation);
      free(exit);
      free(kernel);
      free(user);
      free(pathBuffer);
      free(pathLength);
    }
  }

  static Future<PlayerTerminationOutcome> _terminateWhileHoldingHandle({
    required int pid,
    required int handle,
    required PlayerProcessTreeTerminator terminator,
  }) async {
    final before = WaitForSingleObject(handle, 0);
    if (before == WAIT_OBJECT_0) {
      return PlayerTerminationOutcome.alreadyExited;
    }
    if (before == WAIT_FAILED) return PlayerTerminationOutcome.failed;
    try {
      if (await terminator(pid)) return PlayerTerminationOutcome.terminated;
    } catch (_) {
      return PlayerTerminationOutcome.failed;
    }
    // 进程可能在最终复核后自行退出；句柄仍持有时 PID 不会被复用。
    return WaitForSingleObject(handle, 0) == WAIT_OBJECT_0
        ? PlayerTerminationOutcome.alreadyExited
        : PlayerTerminationOutcome.failed;
  }

  static Future<int?> _loadWindowsPipeServerPid(String pipeName) async {
    if (!Platform.isWindows || pipeName.trim().isEmpty) return null;
    final name = pipeName.toNativeUtf16();
    final serverPid = calloc<Uint32>();
    var handle = INVALID_HANDLE_VALUE;
    try {
      handle = CreateFile(
        name,
        GENERIC_READ | GENERIC_WRITE,
        0,
        nullptr,
        OPEN_EXISTING,
        0,
        0,
      );
      if (handle == INVALID_HANDLE_VALUE) return null;
      final ok = _getNamedPipeServerProcessId(handle, serverPid);
      return ok == 0 || serverPid.value == 0 ? null : serverPid.value;
    } finally {
      if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
      free(name);
      free(serverPid);
    }
  }

  static Future<bool> _terminateWindowsProcessTree(int pid) async {
    if (!Platform.isWindows || pid <= 0) return false;
    final result = await Process.run('taskkill', ['/PID', '$pid', '/T', '/F']);
    return result.exitCode == 0;
  }
}

/// 单个播放会话的集中探活状态。
///
/// 并发消费者共享同一个在途查询；连续查询异常采用有限指数退避，达到
/// 上限后保持 unknown，不把查询失败误判为进程存活或退出。
class PlayerProcessLivenessTracker {
  PlayerProcessLivenessTracker({
    required this.controller,
    required this.expectedIdentity,
    this.healthyProbeInterval = const Duration(seconds: 2),
    this.unknownInitialDelay = const Duration(seconds: 2),
    this.unknownMaxDelay = const Duration(seconds: 16),
    this.maxConsecutiveUnknownProbes = 5,
    PlayerProcessLiveness initialStatus = PlayerProcessLiveness.unknown,
  }) : _status = initialStatus,
       assert(healthyProbeInterval > Duration.zero),
       assert(unknownInitialDelay > Duration.zero),
       assert(unknownMaxDelay >= unknownInitialDelay),
       assert(maxConsecutiveUnknownProbes > 0);

  final PlayerProcessController controller;
  final PlayerProcessIdentity? expectedIdentity;
  final Duration healthyProbeInterval;
  final Duration unknownInitialDelay;
  final Duration unknownMaxDelay;
  final int maxConsecutiveUnknownProbes;

  PlayerProcessLiveness _status;
  Future<PlayerProcessLiveness>? _inFlight;
  Future<PlayerProcessLiveness>? _watchFuture;
  DateTime? _lastSampleAt;
  DateTime? _nextScheduledSampleAt;
  int _consecutiveUnknownProbes = 0;
  int _probeCount = 0;
  bool _stopped = false;

  PlayerProcessLiveness get status => _status;
  int get probeCount => _probeCount;
  int get consecutiveUnknownProbes => _consecutiveUnknownProbes;
  bool get isConservativelyRunning => _status != PlayerProcessLiveness.exited;
  bool get unknownRetryExhausted =>
      _status == PlayerProcessLiveness.unknown &&
      _consecutiveUnknownProbes >= maxConsecutiveUnknownProbes;

  /// 当前是否已有探活查询在途。
  ///
  /// 终止路径在遇到在途的未知查询时必须立即拒绝，不能等待一个可能
  /// 长时间阻塞的系统查询，否则会把新的启动请求一并卡住。
  bool get hasInFlightProbe => _inFlight != null;

  Duration? get nextProbeDelay {
    if (_stopped || _status == PlayerProcessLiveness.exited) return null;
    if (_status == PlayerProcessLiveness.alive) return healthyProbeInterval;
    if (unknownRetryExhausted) return null;
    var delayMicros = unknownInitialDelay.inMicroseconds;
    final maximumMicros = unknownMaxDelay.inMicroseconds;
    for (var attempt = 1; attempt < _consecutiveUnknownProbes; attempt++) {
      final doubled = delayMicros * 2;
      delayMicros = doubled > maximumMicros ? maximumMicros : doubled;
    }
    return Duration(microseconds: delayMicros);
  }

  Future<PlayerProcessLiveness> probe() {
    if (_stopped ||
        _status == PlayerProcessLiveness.exited ||
        unknownRetryExhausted) {
      return Future.value(_status);
    }
    final pending = _inFlight;
    if (pending != null) return pending;
    return _startProbe();
  }

  Future<PlayerProcessLiveness> _startProbe() {
    late final Future<PlayerProcessLiveness> operation;
    operation = _performProbe().whenComplete(() {
      if (!identical(_inFlight, operation)) return;
      _inFlight = null;
      final sampledAt = DateTime.now();
      _lastSampleAt = sampledAt;
      if (_status == PlayerProcessLiveness.alive) {
        _nextScheduledSampleAt = sampledAt.add(healthyProbeInterval);
      } else if (_status == PlayerProcessLiveness.unknown) {
        final delay = nextProbeDelay;
        _nextScheduledSampleAt = delay == null ? null : sampledAt.add(delay);
      } else {
        _nextScheduledSampleAt = null;
      }
    });
    _inFlight = operation;
    return operation;
  }

  /// 面向生产消费者的采样入口。
  ///
  /// 与原始 [probe] 不同，本方法执行健康间隔和 unknown 退避，避免 UI、
  /// 退出 watcher 和诊断各自轮询同一个 PID。查询失败只返回 unknown，
  /// 不会把未知状态降级成“已退出”。
  Future<PlayerProcessLiveness> sample() {
    if (_stopped || _status == PlayerProcessLiveness.exited) {
      return Future.value(_status);
    }
    final now = DateTime.now();
    final last = _lastSampleAt;
    final next = _nextScheduledSampleAt;
    if (last != null && _status == PlayerProcessLiveness.alive) {
      final elapsed = now.difference(last);
      if (elapsed < healthyProbeInterval) return Future.value(_status);
    }
    if (_status == PlayerProcessLiveness.unknown &&
        next != null &&
        now.isBefore(next)) {
      return Future.value(_status);
    }
    final pending = _inFlight;
    if (pending != null) return pending;
    return _startProbe();
  }

  /// 启动本会话唯一的探活循环；重复调用共享同一个循环结果。
  Future<PlayerProcessLiveness> watch({
    PlayerProcessLivenessCycle? onCycle,
    PlayerProcessLivenessDelay delay = _delay,
  }) {
    final running = _watchFuture;
    if (running != null) return running;
    final operation = _watch(onCycle: onCycle, delay: delay);
    _watchFuture = operation;
    return operation;
  }

  Future<PlayerProcessLiveness> _watch({
    required PlayerProcessLivenessCycle? onCycle,
    required PlayerProcessLivenessDelay delay,
  }) async {
    while (!_stopped) {
      final sampled = await probe();
      if (_stopped) return _status;
      if (sampled == PlayerProcessLiveness.exited) {
        await onCycle?.call(sampled);
        return sampled;
      }
      final delayUntilNextProbe = nextProbeDelay;
      if (delayUntilNextProbe == null) return sampled;
      await delay(delayUntilNextProbe);
      if (_stopped) return _status;
      if (await onCycle?.call(sampled) == true) return sampled;
    }
    return _status;
  }

  Future<PlayerProcessLiveness> _performProbe() async {
    _probeCount++;
    PlayerProcessLiveness next;
    try {
      next = await controller.probeOwned(expectedIdentity);
    } catch (_) {
      next = PlayerProcessLiveness.unknown;
    }
    if (_stopped) return _status;
    _status = next;
    if (next == PlayerProcessLiveness.unknown) {
      _consecutiveUnknownProbes++;
    } else {
      _consecutiveUnknownProbes = 0;
    }
    return _status;
  }

  void stop() {
    _stopped = true;
  }

  static Future<void> _delay(Duration duration) =>
      Future<void>.delayed(duration);
}

typedef _GetNamedPipeServerProcessIdNative =
    Int32 Function(IntPtr pipe, Pointer<Uint32> serverProcessId);
typedef _GetNamedPipeServerProcessIdDart =
    int Function(int pipe, Pointer<Uint32> serverProcessId);

final _GetNamedPipeServerProcessIdDart _getNamedPipeServerProcessId =
    DynamicLibrary.open('kernel32.dll').lookupFunction<
      _GetNamedPipeServerProcessIdNative,
      _GetNamedPipeServerProcessIdDart
    >('GetNamedPipeServerProcessId');
