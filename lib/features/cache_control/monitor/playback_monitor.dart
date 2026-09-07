import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../engine/cache_policy_engine.dart';
import '../models/cache_learning_data.dart';
import '../providers/system_memory_provider.dart';

/// 播放中动态调整指令（部分字段为 null 表示该项不变）。
class CacheAdjustment {
  const CacheAdjustment({
    this.demuxerMaxBytes,
    this.cacheSecs,
    required this.reason,
  });

  /// 调整后的缓存字节上限（对应 mpv `--demuxer-max-bytes`）。
  final int? demuxerMaxBytes;

  /// 调整后的目标缓存秒数（对应 mpv `--cache-secs`）。
  final int? cacheSecs;

  /// 调整原因（诊断/日志）。
  final String reason;
}

/// 播放中一次周期采样（读取 mpv 状态文件 + 系统内存）。
class PlaybackSample {
  const PlaybackSample({
    this.timePosSec,
    this.paused,
    this.durationSec,
    this.bufferingState,
    this.networkSpeedBps,
    this.cacheIdle,
    this.pausedForCache,
    this.bofCached,
    this.eofCached,
    this.forwardCacheDurationSec,
    this.forwardCacheBytes,
    this.totalCacheBytes,
    this.availableMemoryBytes,
  });

  /// 当前播放位置（秒）；未知为 null。
  final double? timePosSec;

  /// 是否暂停；未知为 null。
  final bool? paused;

  /// 文件时长（秒）；未知为 null。
  final double? durationSec;

  /// mpv 缓冲百分比（0~100）。正常预取完成通常为 100，不能单独用来
  /// 判断卡顿；真值见 [pausedForCache]。
  final int? bufferingState;

  /// 实时下载速度（bytes/s）；未知为 null。
  final double? networkSpeedBps;

  /// mpv `cache-idle`（0.41+ 为 `demuxer-cache-idle`）：仅表示读取线程
  /// 当前没有读取，不能单独证明缓存已满或前向缓存充足。
  final bool? cacheIdle;

  /// mpv `paused-for-cache`：这是播放器是否因缓存不足而暂停的真值。
  final bool? pausedForCache;

  /// 当前可寻址缓存是否覆盖文件开头/结尾。
  final bool? bofCached;
  final bool? eofCached;

  /// 当前解码位置之后的可播放缓存时长。
  final double? forwardCacheDurationSec;

  /// 当前解码位置之后的包缓存字节数。
  final int? forwardCacheBytes;

  /// 包队列总字节数，包含可 seek 的历史范围。
  final int? totalCacheBytes;

  /// 系统可用内存（字节）；未知为 null。
  final int? availableMemoryBytes;

  /// 是否处于真卡顿。优先使用 mpv 的 `paused-for-cache`；旧版属性
  /// 缺失时才以 `cache-buffering-state < 100` 降级判断。
  bool get isStalling {
    if (pausedForCache != null) return pausedForCache!;
    final b = bufferingState;
    return b != null && b > 0 && b < 100;
  }

  /// 网络数据是否可用（状态文件含第 6~7 行且值有效）。
  bool get networkKnown =>
      networkSpeedBps != null &&
      networkSpeedBps!.isFinite &&
      networkSpeedBps! >= 0;

  /// 已播放到结尾（距结尾不足 5 秒）：此时速度为 0 是正常的
  /// （无更多数据可下），不应触发网络不足误报。
  bool get atEndOfPlayback =>
      durationSec != null &&
      durationSec! > 0 &&
      timePosSec != null &&
      timePosSec! >= 0 &&
      timePosSec! >= durationSec! - 5;
}

/// 播放中动态监控与保护（设计文档第 9 节：9.1 内存压力保护 /
/// 9.2 网络异常保护 / 卡顿记录）。
///
/// 周期性（默认 5 秒）读取 mpv 状态文件（含 paused-for-cache、前向缓存
/// 时长/字节和缓存范围状态）与系统可用内存，按纯算法输出：
/// - **内存压力**：可用内存 < 当前上限 × [memoryPressureFactor] 时
///   认为缓存占用威胁系统稳定，动态降低 `demuxer-max-bytes`
///   （连续压力持续减半，下限 [minDemuxerMaxBytes]）；
/// - **网络不足**：实时下载速度持续（≥[requiredStreak] 次采样）低于
///   码率需求（码率 × [networkPoorRatio]）时增大 `cache-secs`
///   （每次 +60s，上限 [maxCacheSecs]）；若速度持续低于
///   码率 × [networkCriticalRatio]，判定「长期带宽不足，缓存无法
///   解决」，触发 [onWarning]（60 秒内去重，避免刷屏）；
/// - **卡顿记录**：每段连续 paused-for-cache 计为一次卡顿事件。
///
/// 纯 Dart 可单测；任何读取失败按「未知」降级，不影响播放。
class PlaybackMonitor {
  PlaybackMonitor({
    required this.memoryProvider,
    this.engine = const CachePolicyEngine(),
    this.interval = const Duration(seconds: 5),
    this.baseCacheSecs = 120,
    this.maxCacheSecs = 300,
    this.minDemuxerMaxBytes = 64 * 1024 * 1024, // 64MiB
    this.memoryPressureFactor = 2.0,
    this.networkPoorRatio = 1.2,
    this.networkCriticalRatio = 0.3,
    this.networkPoorAbsoluteKbps = 512,
    this.networkCriticalAbsoluteKbps = 256,
    this.bufferingWarningStreak = 6,
    this.requiredStreak = 2,
    this.warningCooldown = const Duration(seconds: 60),
    this.recoveryStreak = 6,
    void Function(String message)? logger,
  }) : _logger = logger ?? _defaultLogger;

  final SystemMemoryProvider memoryProvider;

  /// 四层引擎（复用 Layer 3 网络系数规则，保持单一来源）。
  final CachePolicyEngine engine;

  /// 采样周期。
  final Duration interval;

  /// 基础目标缓存秒数（调整的起点/回落参考）。
  final int baseCacheSecs;

  /// 网络不足时 cache-secs 增档上限。
  final int maxCacheSecs;

  /// Layer 3 降档的下限（带宽充足时可低于基础秒数，但不过度）。
  static const int _minLayer3CacheSecs = 30;

  /// 内存压力降级的下限（demuxer-max-bytes 不再低于此值）。
  final int minDemuxerMaxBytes;

  /// 内存压力判定：可用内存 < 当前上限 × 该系数。
  final double memoryPressureFactor;

  /// 网络不足判定：速度 < 码率 × 该系数（持续 [requiredStreak] 次）。
  final double networkPoorRatio;

  /// 网络严重不足判定：速度 < 码率 × 该系数 → 用户警告。
  final double networkCriticalRatio;

  /// 码率未知时的绝对阈值（KB/s）：速度持续低于该值视为网络不足。
  /// 首次播放（码率未就绪）时仍能检测「网速过低」，不依赖码率基准。
  final double networkPoorAbsoluteKbps;

  /// 码率未知时的严重不足阈值（KB/s）→ 用户警告。
  final double networkCriticalAbsoluteKbps;

  /// 持续缓冲多少次采样（每 5s 一次）后向用户发出警告。
  final int bufferingWarningStreak;

  /// 判定所需的连续采样次数。
  final int requiredStreak;

  /// 同类警告的冷却时长（滞回：冷却期内不重复告警，默认 60s）。
  final Duration warningCooldown;

  /// 连续健康样本达到该值后逐步恢复先前因弱网/内存压力作出的降级。
  final int recoveryStreak;

  /// 诊断日志输出（默认控制台）。
  final void Function(String message) _logger;

  Timer? _timer;
  String? _statusFilePath;
  void Function(CacheAdjustment adjustment)? _onAdjustment;
  void Function(String message)? _onWarning;

  /// 当前缓存上限（字节）；启动时取策略初值，调整后更新。
  int _demuxerMaxBytes = 0;

  /// 当前目标缓存秒数。
  int _cacheSecs = 0;

  int _baselineCacheSecs = 0;
  int _dynamicMinCacheSecs = 10;
  int _dynamicMaxCacheSecs = 300;

  /// 原始策略内存预算与当前压力/多会话共同形成的动态内存上限。
  int _policyMemoryBudgetBytes = 0;
  int _memoryLimitBytes = 0;
  int _activeSessionCount = 1;
  bool _fullCache = false;

  /// 本次播放采用的码率（Mbps）；未知时使用绝对速度阈值。
  double? _bitrateMbps;

  /// 本次播放的文件大小（字节）；用于内存目标与学习结果，未知为 null。
  int? _fileSizeBytes;

  /// 实测带宽样本（KB/s）滑动窗口：仅收录「有效下载」样本（速度>0
  /// 且非缓冲中/暂停/结尾/全缓存），稳定后估算真实下行带宽。
  final List<double> _bandwidthSamples = [];

  /// Layer 3 网络系数是否已应用（一次性：带宽估计就绪后修正一次）。
  bool _layer3Applied = false;

  /// 采样进行中标志（串行化：防 Timer 重入）。
  bool _sampling = false;

  /// 速度数据不可用诊断是否已输出（只提示一次）。
  bool _speedUnavailableLogged = false;

  /// 代际令牌（start/stop 递增；迟到采样在评估前校验，不一致即丢弃）。
  int _generation = 0;

  /// 连续卡顿采样计数；优先依据 paused-for-cache，旧版回退缓冲进度。
  int _bufferingStreak = 0;

  /// 上次因持续缓冲执行增档时的 streak，用于节流；不能清零
  /// [_bufferingStreak]，否则持续卡顿永远达不到告警阈值。
  int _lastBufferAdjustmentStreak = 0;

  // 连续计数（网络不足 / 严重不足 / 内存压力）。
  int _poorStreak = 0;
  int _criticalStreak = 0;
  int _lowForwardIdleStreak = 0;
  int _memoryPressureStreak = 0;
  int _memoryHealthyStreak = 0;
  int _healthyNetworkStreak = 0;

  bool _wasStalling = false;

  /// 卡顿事件累计次数。
  int _stallCount = 0;

  // 第三阶段会话学习只维护聚合量，采样成本 O(1)，不保存逐秒轨迹。
  int _outcomeSampleCount = 0;
  int _pausedSampleCount = 0;
  int _forwardSeekCount = 0;
  int _backwardSeekCount = 0;
  double? _lastOutcomePositionSec;
  double? _lastOutcomeDurationSec;
  bool _outcomeCompleted = false;
  final RunningStatistics _outcomeSpeedBps = RunningStatistics();

  /// 上次警告时间（60 秒去重）。
  DateTime? _lastWarningAt;

  /// 启动监控（幂等：重复调用先停止再启动）。
  void start({
    required String statusFilePath,
    required int initialDemuxerMaxBytes,
    required int initialCacheSecs,
    int? fileSizeBytes,
    double? bitrateMbps,
    int? memoryBudgetBytes,
    int? minCacheSecs,
    int? maxCacheSecs,
    bool fullCache = false,
    void Function(CacheAdjustment adjustment)? onAdjustment,
    void Function(String message)? onWarning,
  }) {
    stop();
    _statusFilePath = statusFilePath;
    _demuxerMaxBytes = initialDemuxerMaxBytes > 0
        ? initialDemuxerMaxBytes
        : minDemuxerMaxBytes;
    _cacheSecs = initialCacheSecs > 0 ? initialCacheSecs : baseCacheSecs;
    _baselineCacheSecs = _cacheSecs;
    _dynamicMinCacheSecs =
        minCacheSecs ?? math.min(_cacheSecs, _minLayer3CacheSecs);
    _dynamicMaxCacheSecs = maxCacheSecs ?? this.maxCacheSecs;
    _policyMemoryBudgetBytes =
        memoryBudgetBytes != null && memoryBudgetBytes > 0
        ? memoryBudgetBytes
        : _demuxerMaxBytes;
    _memoryLimitBytes = _policyMemoryBudgetBytes;
    _activeSessionCount = 1;
    _fullCache = fullCache;
    _fileSizeBytes = fileSizeBytes;
    _bitrateMbps = bitrateMbps;
    _onAdjustment = onAdjustment;
    _onWarning = onWarning;
    _poorStreak = 0;
    _criticalStreak = 0;
    _lowForwardIdleStreak = 0;
    _memoryPressureStreak = 0;
    _bufferingStreak = 0;
    _lastBufferAdjustmentStreak = 0;
    _memoryHealthyStreak = 0;
    _healthyNetworkStreak = 0;
    _wasStalling = false;
    _stallCount = 0;
    _outcomeSampleCount = 0;
    _pausedSampleCount = 0;
    _forwardSeekCount = 0;
    _backwardSeekCount = 0;
    _lastOutcomePositionSec = null;
    _lastOutcomeDurationSec = null;
    _outcomeCompleted = false;
    _outcomeSpeedBps.reset();
    _bandwidthSamples.clear();
    _layer3Applied = false;
    // 代际令牌：新启动使旧采样失效（迟到回调不得修改新状态）。
    _generation++;
    _timer = Timer.periodic(interval, (_) => unawaited(_sampleGuarded()));
    _logger(
      'Monitor: started (interval ${interval.inSeconds}s, '
      'bitrate${_bitrateMbps != null ? ' ${_bitrateMbps!.toStringAsFixed(1)}Mbps' : ' unknown'})',
    );
  }

  /// 停止监控（幂等）。
  void stop() {
    // 代际令牌：停止后迟到的采样结果一律丢弃。
    _generation++;
    _timer?.cancel();
    _timer = null;
    _statusFilePath = null;
  }

  /// 码率就绪后更新判定基准（如 recordDuration 重算出平均码率后）。
  ///
  /// 从「绝对阈值兜底」切换到「相对码率判定」，并重置连续计数
  /// （基准变化后旧计数无意义）。
  void updateBitrate(double? bitrateMbps) {
    _bitrateMbps = bitrateMbps;
    _poorStreak = 0;
    _criticalStreak = 0;
    _bandwidthSamples.clear();
    _layer3Applied = false;
  }

  /// 码率/时长回填后的完整策略同步。播放器收到新策略的同时，监控器
  /// 必须原子更新全部基准，避免后续用旧上限把新策略反向改大。
  void updatePolicy({
    required int demuxerMaxBytes,
    required int cacheSecs,
    required int memoryBudgetBytes,
    required int minCacheSecs,
    required int maxCacheSecs,
    required bool fullCache,
    int? fileSizeBytes,
    double? bitrateMbps,
  }) {
    _demuxerMaxBytes = demuxerMaxBytes;
    _cacheSecs = cacheSecs;
    _baselineCacheSecs = cacheSecs;
    _policyMemoryBudgetBytes = memoryBudgetBytes > 0
        ? memoryBudgetBytes
        : demuxerMaxBytes;
    _memoryLimitBytes = math.min(_policyMemoryBudgetBytes, _sharedMemoryBudget);
    _dynamicMinCacheSecs = minCacheSecs;
    _dynamicMaxCacheSecs = math.max(maxCacheSecs, cacheSecs);
    _fullCache = fullCache;
    _fileSizeBytes = fileSizeBytes;
    updateBitrate(bitrateMbps);
    _memoryPressureStreak = 0;
    _memoryHealthyStreak = 0;
    _healthyNetworkStreak = 0;
  }

  /// 多会话共享同一内存预算；会话数变化时立即收敛到公平份额。
  void updateActiveSessionCount(int count) {
    final previousShared = _sharedMemoryBudget;
    _activeSessionCount = math.max(1, count);
    final shared = _sharedMemoryBudget;
    // 只在当前上限原本由“共享份额”限制时随会话减少立即恢复；若上限
    // 是内存压力主动降低的，则保留降级，交给健康样本的滞回恢复。
    if (_memoryLimitBytes >= previousShared) {
      _memoryLimitBytes = shared;
    } else if (_memoryLimitBytes > shared) {
      _memoryLimitBytes = shared;
    }
    final next = _computeByteCap(_cacheSecs);
    if (next != _demuxerMaxBytes) {
      _demuxerMaxBytes = next;
      _emitAdjustment(
        CacheAdjustment(
          demuxerMaxBytes: next,
          cacheSecs: _cacheSecs,
          reason:
              'Session memory rebalance: $_activeSessionCount active sessions',
        ),
      );
    }
  }

  int get _sharedMemoryBudget => math.max(
    1,
    (_policyMemoryBudgetBytes / math.max(1, _activeSessionCount)).floor(),
  );

  /// 卡顿累计次数（诊断）。
  int get stallCount => _stallCount;

  /// 当前缓存上限（字节，诊断）。
  int get currentDemuxerMaxBytes => _demuxerMaxBytes;

  /// 当前目标缓存秒数（诊断）。
  int get currentCacheSecs => _cacheSecs;

  /// 当前会话的匿名聚合结果。可在 [stop] 前后读取，不含 URL 和文件名。
  PlaybackSessionOutcome snapshotOutcome() => PlaybackSessionOutcome(
    sampleCount: _outcomeSampleCount,
    stallCount: _stallCount,
    forwardSeekCount: _forwardSeekCount,
    backwardSeekCount: _backwardSeekCount,
    pausedSampleCount: _pausedSampleCount,
    meanNetworkSpeedBps: _outcomeSpeedBps.count > 0
        ? _outcomeSpeedBps.mean
        : null,
    networkSpeedStdDevBps: _outcomeSpeedBps.count > 1
        ? _outcomeSpeedBps.standardDeviation
        : null,
    lastPositionSec: _lastOutcomePositionSec,
    durationSec: _lastOutcomeDurationSec,
    completed: _outcomeCompleted,
  );

  /// 一次采样（公开供测试直接驱动；同样走串行化+代际校验）。
  @visibleForTesting
  Future<void> sampleOnce() => _sampleGuarded();

  /// 采样串行化：Timer 触发的采样不得重入（前一轮未完成时跳过本轮），
  /// 并在评估前校验代际——stop/start 后旧采样结果被丢弃，防止
  /// 竞态修改新会话状态。
  Future<void> _sampleGuarded() async {
    if (_sampling) return;
    _sampling = true;
    try {
      final generation = _generation;
      final file = _statusFilePath;
      if (file == null) return;
      var sample = await _readStatus(file);
      final memory = await _safeMemory();
      if (generation != _generation) return; // 迟到采样：丢弃。
      sample = PlaybackSample(
        timePosSec: sample.timePosSec,
        paused: sample.paused,
        durationSec: sample.durationSec,
        bufferingState: sample.bufferingState,
        networkSpeedBps: sample.networkSpeedBps,
        cacheIdle: sample.cacheIdle,
        pausedForCache: sample.pausedForCache,
        bofCached: sample.bofCached,
        eofCached: sample.eofCached,
        forwardCacheDurationSec: sample.forwardCacheDurationSec,
        forwardCacheBytes: sample.forwardCacheBytes,
        totalCacheBytes: sample.totalCacheBytes,
        availableMemoryBytes: memory,
      );
      _evaluate(sample);
    } finally {
      _sampling = false;
    }
  }

  Future<PlaybackSample> _readStatus(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return const PlaybackSample();
      final lines = await file.readAsLines();
      if (lines.length < 5) return const PlaybackSample();
      double? parse(int index) {
        if (lines.length <= index) return null;
        final v = double.tryParse(lines[index].trim());
        return v;
      }

      final timePos = parse(3);
      final duration = parse(4);
      final buffering = parse(5)?.round().toInt();
      final speed = parse(6);
      final idleRaw = lines.length > 7 ? lines[7].trim() : '';
      final pausedForCacheRaw = lines.length > 9 ? lines[9].trim() : '';
      final bofCachedRaw = lines.length > 10 ? lines[10].trim() : '';
      final eofCachedRaw = lines.length > 11 ? lines[11].trim() : '';
      final pausedRaw = lines.length > 2 ? lines[2].trim() : '';
      final forwardCacheDuration = parse(15);
      final forwardCacheBytes = parse(16);
      final totalCacheBytes = parse(17);
      // 速度不可用时关闭速度判定，仅保留卡顿驱动；第九行记录
      // speed_src|speed|idle_src|idle_raw，便于定位属性版本差异。
      if ((speed == null || speed < 0) && !_speedUnavailableLogged) {
        _speedUnavailableLogged = true;
        final diagRaw = lines.length > 8 ? lines[8].trim() : '<none>';
        _logger(
          'Monitor: speed data unavailable (mpv demuxer-cache-state '
          'diagnostic: $diagRaw) -> network checks degraded to '
          'buffering-driven',
        );
      }
      return PlaybackSample(
        timePosSec: timePos != null && timePos >= 0 ? timePos : null,
        paused: pausedRaw == '1' ? true : (pausedRaw == '0' ? false : null),
        durationSec: duration != null && duration > 0 ? duration : null,
        bufferingState: buffering != null && buffering >= 0 ? buffering : null,
        networkSpeedBps: speed != null && speed >= 0 ? speed : null,
        cacheIdle: idleRaw == '1' ? true : (idleRaw == '0' ? false : null),
        pausedForCache: pausedForCacheRaw == '1'
            ? true
            : (pausedForCacheRaw == '0' ? false : null),
        bofCached: bofCachedRaw == '1'
            ? true
            : (bofCachedRaw == '0' ? false : null),
        eofCached: eofCachedRaw == '1'
            ? true
            : (eofCachedRaw == '0' ? false : null),
        forwardCacheDurationSec:
            forwardCacheDuration != null && forwardCacheDuration >= 0
            ? forwardCacheDuration
            : null,
        forwardCacheBytes: forwardCacheBytes != null && forwardCacheBytes >= 0
            ? forwardCacheBytes.round()
            : null,
        totalCacheBytes: totalCacheBytes != null && totalCacheBytes >= 0
            ? totalCacheBytes.round()
            : null,
      );
    } catch (_) {
      return const PlaybackSample();
    }
  }

  Future<int?> _safeMemory() async {
    try {
      return await memoryProvider.availableMemoryBytes();
    } catch (_) {
      return null;
    }
  }

  void _evaluate(PlaybackSample sample) {
    _trackOutcome(sample);
    // ── 前置：网络空闲状态判定（暂停/播完/全缓存/前向缓存充足） ──
    // 顺序在卡顿统计**之前**：暂停瞬间残留的 buffering 状态不得触发
    // 「持续缓冲」误报，速度为 0 属正常也不判网络不足。
    // cache-idle 仅表示读取线程当前没有读取，不能单独证明前向缓存充足。
    final fullyCached = sample.bofCached == true && sample.eofCached == true;
    final forwardSafetySecs = math.min(_cacheSecs, 30).toDouble();
    final forwardCacheKnown = sample.forwardCacheDurationSec != null;
    final forwardCacheSafe =
        sample.eofCached == true ||
        (forwardCacheKnown &&
            sample.forwardCacheDurationSec! >= forwardSafetySecs);
    final stalling = sample.paused != true && sample.isStalling;
    // 旧版 MPV 没有前向水位时保留原降级行为；新协议必须同时满足
    // EOF 或最小前向水位，idle 才能暂停网络判断。
    final cacheIdleSafe =
        sample.cacheIdle == true && (!forwardCacheKnown || forwardCacheSafe);
    final lowForwardIdle =
        sample.cacheIdle == true &&
        forwardCacheKnown &&
        !forwardCacheSafe &&
        sample.eofCached != true &&
        sample.paused != true &&
        !sample.atEndOfPlayback &&
        !stalling;
    final networkIdle =
        !stalling &&
        (sample.paused == true ||
            sample.atEndOfPlayback ||
            fullyCached ||
            cacheIdleSafe);
    if (networkIdle &&
        (_poorStreak > 0 || _criticalStreak > 0 || _bufferingStreak > 0)) {
      _poorStreak = 0;
      _criticalStreak = 0;
      _bufferingStreak = 0;
      _bandwidthSamples.clear();
      _healthyNetworkStreak = 0;
      final idleReasons = <String>[
        if (sample.paused == true) 'paused',
        if (sample.atEndOfPlayback) 'playback-end',
        if (fullyCached) 'fully-cached',
        if (cacheIdleSafe) 'cache-idle-safe',
      ];
      _logger(
        'Monitor: network check paused: reason=${idleReasons.join('+')} '
        '(paused=${sample.paused} end=${sample.atEndOfPlayback} '
        'fullyCached=$fullyCached cacheIdle=${sample.cacheIdle} '
        'forward=${sample.forwardCacheDurationSec?.toStringAsFixed(1) ?? 'unknown'}s '
        'required=${forwardSafetySecs.toStringAsFixed(0)}s)',
      );
    }

    // paused-for-cache 是卡顿真值；旧版属性缺失时才回退 0<buffering<100。
    // 连续卡顿直接驱动增档与警告，不依赖可能失真的缓存读取速度。
    if (stalling) {
      if (!_wasStalling) _stallCount++;
      _wasStalling = true;
      _bufferingStreak++;
      _logger(
        'Monitor: buffering detected (buffering=${sample.bufferingState})'
        '${sample.networkSpeedBps != null ? ', speed ${(sample.networkSpeedBps! / 1024).toStringAsFixed(0)}KB/s' : ''}',
      );
      if (_bufferingStreak >= requiredStreak &&
          _bufferingStreak - _lastBufferAdjustmentStreak >= requiredStreak &&
          _cacheSecs < _dynamicMaxCacheSecs &&
          !_fullCache) {
        _setCacheSecs(
          (_cacheSecs + 60).clamp(_baselineCacheSecs, _dynamicMaxCacheSecs),
          'Buffering: cache cannot keep up with playback',
        );
        _lastBufferAdjustmentStreak = _bufferingStreak;
      }
      if (_bufferingStreak >= bufferingWarningStreak) {
        final now = DateTime.now();
        final last = _lastWarningAt;
        if (last == null || now.difference(last) >= warningCooldown) {
          _lastWarningAt = now;
          _logger(
            'Monitor: sustained buffering ($_bufferingStreak samples, '
            'cache cannot keep up with playback)',
          );
          _onWarning?.call(
            // 文案以「网络带宽不足以流畅播放」开头（用户/UI 统一识别
            // 网络类警告）；速度数据不可用时这是唯一的网络告警信号。
            '网络带宽不足以流畅播放（持续缓冲：缓存跟不上播放速度'
            '${sample.networkSpeedBps != null ? '，实时速度 ${(sample.networkSpeedBps! / 1024).toStringAsFixed(0)}KB/s' : ''}）。'
            '已加大缓冲目标，若仍卡顿请降低画质或检查网络。',
          );
        }
      }
    } else {
      _bufferingStreak = 0;
      _lastBufferAdjustmentStreak = 0;
      _wasStalling = false;
    }

    // ── 9.1 内存压力保护 ─────────────────────────────────
    if (sample.availableMemoryBytes != null &&
        _demuxerMaxBytes > minDemuxerMaxBytes) {
      final pressure =
          sample.availableMemoryBytes! <
          (_demuxerMaxBytes * memoryPressureFactor).round();
      if (pressure) {
        _memoryHealthyStreak = 0;
        _memoryPressureStreak++;
        if (_memoryPressureStreak >= requiredStreak) {
          final nextLimit = (_memoryLimitBytes / 2).round().clamp(
            minDemuxerMaxBytes,
            _memoryLimitBytes,
          );
          _memoryLimitBytes = nextLimit;
          final next = _computeByteCap(_cacheSecs);
          if (next < _demuxerMaxBytes) {
            _demuxerMaxBytes = next;
            _memoryPressureStreak = 0;
            _emitAdjustment(
              CacheAdjustment(
                demuxerMaxBytes: _demuxerMaxBytes,
                reason:
                    'Memory pressure: available ${_fmt(sample.availableMemoryBytes!)}'
                    ' < cap x$memoryPressureFactor -> halving cache cap',
              ),
            );
          }
        }
      } else {
        _memoryPressureStreak = 0;
        if (sample.availableMemoryBytes! >
            (_memoryLimitBytes * memoryPressureFactor * 1.5).round()) {
          _memoryHealthyStreak++;
          if (_memoryHealthyStreak >= recoveryStreak &&
              _memoryLimitBytes < _sharedMemoryBudget) {
            _memoryLimitBytes = math.min(
              _sharedMemoryBudget,
              math.max(minDemuxerMaxBytes, _memoryLimitBytes * 2),
            );
            _memoryHealthyStreak = 0;
            final next = _computeByteCap(_cacheSecs);
            if (next > _demuxerMaxBytes) {
              _demuxerMaxBytes = next;
              _emitAdjustment(
                CacheAdjustment(
                  demuxerMaxBytes: next,
                  cacheSecs: _cacheSecs,
                  reason: 'Memory recovered: restoring cache cap',
                ),
              );
            }
          }
        } else {
          _memoryHealthyStreak = 0;
        }
      }
    }

    if (lowForwardIdle) {
      _lowForwardIdleStreak++;
      if (_lowForwardIdleStreak == 1) {
        _logger(
          'Monitor: cache reader idle with low forward buffer '
          '(forward=${sample.forwardCacheDurationSec!.toStringAsFixed(1)}s/'
          '${forwardSafetySecs.toStringAsFixed(0)}s, '
          'fw=${sample.forwardCacheBytes != null ? _fmt(sample.forwardCacheBytes!) : 'unknown'}, '
          'total=${sample.totalCacheBytes != null ? _fmt(sample.totalCacheBytes!) : 'unknown'})',
        );
      }
      if (_lowForwardIdleStreak >= requiredStreak &&
          _cacheSecs < _dynamicMaxCacheSecs &&
          !_fullCache) {
        _lowForwardIdleStreak = 0;
        _setCacheSecs(
          (_cacheSecs + 60).clamp(_baselineCacheSecs, _dynamicMaxCacheSecs),
          'Low forward buffer: cache reader remained idle',
        );
      }
    } else {
      _lowForwardIdleStreak = 0;
    }

    // 暂停、播完、全缓存、缓存空闲或正在真实卡顿时，不使用瞬时速度
    // 推断网络质量；真实卡顿已由上面的 paused-for-cache 分支处理。
    if (networkIdle || stalling || lowForwardIdle) return;

    // ── 9.2 网络异常保护（网络空闲时已在前置清零并跳过） ──
    final bitrate = _bitrateMbps;
    if (sample.networkKnown) {
      final speedBps = sample.networkSpeedBps!;
      final bitrateKnown = bitrate != null && bitrate > 0;
      // 码率需求：已知用相对判定（码率 × 系数）；未知（首次播放/
      // 未就绪）用绝对速度阈值兜底，保证「网速过低」仍能被检测。
      final poorThresholdBps = bitrateKnown
          ? bitrate * 125000 * networkPoorRatio
          : networkPoorAbsoluteKbps * 1024;
      final criticalThresholdBps = bitrateKnown
          ? bitrate * 125000 * networkCriticalRatio
          : networkCriticalAbsoluteKbps * 1024;
      final needText = bitrateKnown
          ? 'bitrate need x$networkPoorRatio'
          : 'absolute threshold ${networkPoorAbsoluteKbps.toStringAsFixed(0)}KB/s';
      final needKbpsText = bitrateKnown
          ? '${(bitrate * 125000 / 1024).toStringAsFixed(0)}KB/s 以上'
          : '${networkCriticalAbsoluteKbps.toStringAsFixed(0)}KB/s 以上';
      // 英文日志用纯英文数值（不混中文）。
      final needKbpsEn = bitrateKnown
          ? '${(bitrate * 125000 / 1024).toStringAsFixed(0)}KB/s'
          : '${networkCriticalAbsoluteKbps.toStringAsFixed(0)}KB/s';

      // ── 真实带宽测速 + Layer 3 网络系数（设计文档第 8 节） ──
      // 收集「有效下载」样本（速度 > 0 且非缓冲中），稳定后按
      // Factor = 带宽 ÷ 码率 修正缓存秒数（>3 降 20% / 1~3 保持 /
      // <1 增 50%），一次性应用并复用引擎规则（单一来源）。
      // Layer 3 需要码率基准，码率未知时跳过（绝对阈值已兜底）。
      if (bitrateKnown && speedBps > 0) {
        _bandwidthSamples.add(sample.networkSpeedBps! / 1024);
        if (_bandwidthSamples.length > 5) {
          _bandwidthSamples.removeAt(0);
        }
        if (!_layer3Applied && _bandwidthSamples.length >= 2) {
          final mean =
              _bandwidthSamples.reduce((a, b) => a + b) /
              _bandwidthSamples.length;
          final min = _bandwidthSamples.reduce((a, b) => a < b ? a : b);
          final max = _bandwidthSamples.reduce((a, b) => a > b ? a : b);
          if (mean > 0 && max <= min * 2) {
            _layer3Applied = true;
            final bandwidthMbps = mean * 8 / 1000;
            final factor = engine.networkFactor(
              assumedBandwidthMbps: bandwidthMbps,
              bitrateMbps: bitrate,
            );
            final adjusted = engine
                .adjustCacheSecsForNetwork(_cacheSecs, factor)
                .clamp(
                  math.max(_dynamicMinCacheSecs, _minLayer3CacheSecs),
                  _dynamicMaxCacheSecs,
                )
                .toInt();
            if (adjusted != _cacheSecs) {
              _setCacheSecs(
                adjusted,
                'Layer3 network factor: measured bandwidth '
                '${bandwidthMbps.toStringAsFixed(1)}Mbps / bitrate '
                '${bitrate.toStringAsFixed(1)}Mbps = '
                '${factor!.toStringAsFixed(2)}',
              );
            } else {
              _logger(
                'Layer3 network factor: measured bandwidth '
                '${bandwidthMbps.toStringAsFixed(1)}Mbps / bitrate '
                '${bitrate.toStringAsFixed(1)}Mbps = '
                '${factor!.toStringAsFixed(2)} (neutral, keep ${_cacheSecs}s)',
              );
            }
          }
        }
      }

      if (speedBps < poorThresholdBps) {
        _poorStreak++;
      } else {
        _poorStreak = 0;
      }
      if (speedBps < criticalThresholdBps) {
        _criticalStreak++;
      } else {
        _criticalStreak = 0;
      }
      // 持续不足 → 增大缓冲目标（缓存无法解决长期带宽不足，但可
      // 平滑短期波动；有上限，不无限增加）。
      if (_poorStreak >= requiredStreak &&
          _cacheSecs < _dynamicMaxCacheSecs &&
          !_fullCache) {
        final streak = _poorStreak;
        final next = (_cacheSecs + 60).clamp(
          _baselineCacheSecs,
          _dynamicMaxCacheSecs,
        );
        _poorStreak = 0;
        _setCacheSecs(
          next,
          'Slow network: speed ${_fmt(speedBps.round())} < $needText'
          ' (streak $streak)',
        );
      }
      if (speedBps >= poorThresholdBps) {
        _healthyNetworkStreak++;
        if (_healthyNetworkStreak >= recoveryStreak &&
            _cacheSecs > _baselineCacheSecs &&
            !_fullCache) {
          _healthyNetworkStreak = 0;
          _setCacheSecs(
            math.max(_baselineCacheSecs, _cacheSecs - 30),
            'Network recovered: reducing temporary buffer expansion',
          );
        }
      } else {
        _healthyNetworkStreak = 0;
      }
      // 严重不足 → 用户警告（60 秒去重；UI 消息中文，终端日志英文）。
      if (_criticalStreak >= requiredStreak) {
        final now = DateTime.now();
        final last = _lastWarningAt;
        if (last == null || now.difference(last) >= warningCooldown) {
          _lastWarningAt = now;
          _logger(
            'Monitor: critical bandwidth shortage (speed '
            '${(sample.networkSpeedBps! / 1024).toStringAsFixed(0)}KB/s, need '
            '$needKbpsEn, bitrate '
            '${bitrateKnown ? bitrate.toStringAsFixed(1) : 'unknown'})',
          );
          _onWarning?.call(
            '网络带宽不足以流畅播放（实时速度'
            ' ${(sample.networkSpeedBps! / 1024).toStringAsFixed(0)}KB/s，需要'
            ' $needKbpsText）。'
            '已加大缓冲，若持续卡顿请降低画质或检查网络。',
          );
        }
      }
    }
  }

  void _trackOutcome(PlaybackSample sample) {
    _outcomeSampleCount++;
    if (sample.paused == true) _pausedSampleCount++;
    final position = sample.timePosSec;
    final previous = _lastOutcomePositionSec;
    if (position != null && position >= 0) {
      if (previous != null) {
        final delta = position - previous;
        final forwardThreshold = math.max(15.0, interval.inSeconds * 3.0);
        if (delta > forwardThreshold) {
          _forwardSeekCount++;
        } else if (delta < -5) {
          _backwardSeekCount++;
        }
      }
      _lastOutcomePositionSec = position;
    }
    final duration = sample.durationSec;
    if (duration != null && duration > 0) _lastOutcomeDurationSec = duration;
    if (sample.atEndOfPlayback) _outcomeCompleted = true;
    final speed = sample.networkSpeedBps;
    if (speed != null &&
        speed > 0 &&
        sample.paused != true &&
        !sample.isStalling) {
      _outcomeSpeedBps.add(speed);
    }
  }

  int _computeByteCap(int cacheSecs) {
    final limit = math.min(_memoryLimitBytes, _sharedMemoryBudget);
    if (_fullCache && _fileSizeBytes != null && _fileSizeBytes! > 0) {
      return math.min(
        limit,
        (_fileSizeBytes! * CachePolicyEngine.fullCacheOverheadFactor).ceil(),
      );
    }
    final bitrate = _bitrateMbps;
    if (bitrate != null && bitrate > 0) {
      return math.min(
        limit,
        math.max(
          1,
          (bitrate *
                  cacheSecs *
                  CachePolicyEngine.bytesPerSecondPerMbps *
                  CachePolicyEngine.safetyFactor)
              .round(),
        ),
      );
    }
    return limit;
  }

  void _setCacheSecs(int value, String reason) {
    final nextSecs = value.clamp(_dynamicMinCacheSecs, _dynamicMaxCacheSecs);
    if (nextSecs == _cacheSecs) return;
    _cacheSecs = nextSecs;
    final nextBytes = _computeByteCap(nextSecs);
    final bytesChanged = nextBytes != _demuxerMaxBytes;
    _demuxerMaxBytes = nextBytes;
    _emitAdjustment(
      CacheAdjustment(
        cacheSecs: nextSecs,
        demuxerMaxBytes: bytesChanged ? nextBytes : null,
        reason: '$reason -> ${_cacheTargetSummary(nextSecs, nextBytes)}',
      ),
    );
  }

  String _cacheTargetSummary(int requestedSecs, int byteCap) {
    final reachable = engine.estimateReachableCacheSecs(
      demuxerMaxBytes: byteCap,
      bitrateMbps: _bitrateMbps,
    );
    final required = engine.estimateRequiredCacheBytes(
      cacheSecs: requestedSecs,
      bitrateMbps: _bitrateMbps,
    );
    if (reachable == null || required == null) {
      return 'cache target requested=${requestedSecs}s, '
          'estimated-reachable=unknown (bitrate unknown), '
          'byte-cap=${_fmtCapacity(byteCap)}';
    }
    final effective = math.min(requestedSecs, reachable);
    if (reachable < requestedSecs) {
      return 'cache target requested=${requestedSecs}s, '
          'estimated-reachable=${effective}s, '
          'byte-cap=${_fmtCapacity(byteCap)}, '
          'required=${_fmtCapacity(required)} '
          '(${_byteCapLimiter()} limited)';
    }
    return 'cache target requested=${requestedSecs}s, '
        'estimated-reachable=${effective}s, '
        'byte-cap=${_fmtCapacity(byteCap)}';
  }

  String _byteCapLimiter() {
    if (_memoryLimitBytes < _sharedMemoryBudget) return 'memory-pressure';
    if (_activeSessionCount > 1) return 'shared-session-budget';
    return 'policy-memory-budget';
  }

  void _emitAdjustment(CacheAdjustment adjustment) {
    _logger('Monitor: ${adjustment.reason}');
    _onAdjustment?.call(adjustment);
  }

  static String _fmt(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)}KB';
  }

  static String _fmtCapacity(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GiB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MiB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)}KiB';
    }
    return '${bytes}B';
  }

  static void _defaultLogger(String message) {
    // ignore: avoid_print
    print(message);
  }
}
