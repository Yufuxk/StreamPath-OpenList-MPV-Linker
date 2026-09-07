import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../../domain/services/mpv_session_controller.dart';
import '../../domain/services/iso_access_provider.dart';
import 'cache_policy_service.dart';
import 'engine/cache_policy_engine.dart';
import 'intelligence/cache_intelligence_service.dart';
import 'models/cache_learning_data.dart';
import 'models/cache_policy_result.dart';
import 'monitor/playback_monitor.dart';
import 'providers/system_memory_provider.dart';

/// ISO Title 的缓存决策输入，不包含 loopback 地址或认证信息。
class IsoCacheTitleContext {
  const IsoCacheTitleContext({
    required this.mplsId,
    required this.streamSize,
    required this.duration,
  });

  final String mplsId;
  final int streamSize;
  final Duration duration;
}

/// 单个 ISO Title 的 MPV 缓存计划。
class IsoTitleCachePlan {
  const IsoTitleCachePlan({
    required this.mplsId,
    required this.cacheSecs,
    required this.mpvMaxBytes,
    required this.memoryBudgetBytes,
    required this.minCacheSecs,
    required this.maxCacheSecs,
    required this.bitrateMbps,
    required this.fileSizeBytes,
    required this.prefetchBlocks,
  });

  final String mplsId;
  final int cacheSecs;
  final int mpvMaxBytes;
  final int memoryBudgetBytes;
  final int minCacheSecs;
  final int maxCacheSecs;
  final double bitrateMbps;
  final int fileSizeBytes;
  final int prefetchBlocks;
}

/// 一次 ISO 播放会话的双层缓存预算。
class IsoCacheSessionPlan {
  IsoCacheSessionPlan({
    required this.bridgeBlockCount,
    required this.prefetchBlocks,
    required Map<String, IsoTitleCachePlan> titlePlans,
  }) : titlePlans = Map<String, IsoTitleCachePlan>.unmodifiable(titlePlans);

  final int bridgeBlockCount;
  final int prefetchBlocks;
  final Map<String, IsoTitleCachePlan> titlePlans;

  int get bridgeBytes => bridgeBlockCount * CachePolicyEngine.isoBlockSizeBytes;

  IsoTitleCachePlan planFor(String mplsId) => titlePlans[mplsId]!;
}

/// ISO 独占缓存控制器：共享普通缓存的策略/学习，但只写 ISO MPV。
class IsoCacheCoordinator {
  IsoCacheCoordinator({
    required CachePolicyService policyService,
    CacheIntelligenceProvider? intelligence,
    SystemMemoryProvider? memoryProvider,
    PlaybackMonitor Function()? monitorFactory,
    void Function(String message)? logger,
  }) : // 对外保留可读的命名参数，私有字段不能用 initializing formal 暴露。
       // ignore: prefer_initializing_formals
       _policyService = policyService,
       // ignore: prefer_initializing_formals
       _intelligence = intelligence,
       _memoryProvider = memoryProvider ?? platformMemoryProvider(),
       // ignore: prefer_initializing_formals
       _monitorFactory = monitorFactory,
       _logger = logger ?? _defaultLogger;

  static const int _fallbackCacheSecs = 60;
  static const int _fallbackMpvMaxBytes = 512 * 1024 * 1024;
  static const int _minimumBridgeBlocks = 4;
  static const int _maximumBridgeBlocks = 16;
  static const int _minimumPrefetchBlocks = 4;
  static const int _maximumPrefetchBlocks = 12;

  final CachePolicyService _policyService;
  final CacheIntelligenceProvider? _intelligence;
  final SystemMemoryProvider _memoryProvider;
  final PlaybackMonitor Function()? _monitorFactory;
  final void Function(String message) _logger;
  final Map<String, _IsoCacheRuntime> _runtimes = {};

  // ignore: avoid_print
  static void _defaultLogger(String message) => print(message);

  void _log(String message) {
    try {
      _logger('[SPCacheSystem][ISO] $message');
    } catch (_) {
      // 诊断输出失败不影响播放。
    }
  }

  /// 导航模式的预读放在 ISO 层，保留四分之一容量用于已播放内容。
  Future<({int bridgeBlockCount, int prefetchBlocks, int cacheSecs})>
  buildMenuPlan({
    required String logicalSourceUrl,
    required int totalBytes,
  }) async {
    CachePolicyResult result;
    try {
      result = await _policyService.buildPolicy(
        url: logicalSourceUrl,
        knownFileSizeBytes: totalBytes,
      );
    } catch (error) {
      _log('Menu policy calculation failed; retaining base ISO cache '
          '(error-type=${error.runtimeType})');
      return (bridgeBlockCount: 128, prefetchBlocks: 96, cacheSecs: 60);
    }
    if (result.skipped) {
      return (bridgeBlockCount: 12, prefetchBlocks: 4, cacheSecs: 0);
    }
    const mpvBytes = 16 * 1024 * 1024;
    final budget = math.min(
      CachePolicyEngine.fallbackMemoryBudgetBytes,
      math.min(result.demuxerMaxBytes, result.memoryBudgetBytes - mpvBytes),
    );
    final blocks = (budget ~/ CachePolicyEngine.isoBlockSizeBytes)
        .clamp(4, 256);
    final prefetch = math.max(4, blocks * 3 ~/ 4);
    final seconds = result.cacheSecs.clamp(10, 600);
    _log(
      'Menu plan ready: bridge=${blocks * 4}MiB, '
      'prefetch-cap=${prefetch * 4}MiB, target=${seconds}s',
    );
    return (
      bridgeBlockCount: blocks,
      prefetchBlocks: prefetch,
      cacheSecs: seconds,
    );
  }

  Future<IsoCacheSessionPlan> buildSessionPlan({
    required String logicalSourceUrl,
    required List<IsoCacheTitleContext> titles,
  }) async {
    if (titles.isEmpty) {
      throw ArgumentError.value(titles, 'titles', 'ISO Title 列表不能为空');
    }
    final rawPlans = <String, (IsoCacheTitleContext, CachePolicyResult)>{};
    var maximumPrefetch = _minimumPrefetchBlocks;
    for (final title in titles) {
      if (title.streamSize <= 0 || title.duration.inMilliseconds <= 0) {
        throw ArgumentError('ISO Title 大小和时长必须为正数');
      }
      final bitrateMbps =
          title.streamSize *
          8 /
          (title.duration.inMilliseconds / 1000) /
          1000000;
      final prefetchBlocks = _prefetchBlocks(title);
      maximumPrefetch = math.max(maximumPrefetch, prefetchBlocks);
      CachePolicyResult result;
      try {
        result = await _policyService.buildPolicy(
          url: logicalSourceUrl,
          knownFileSizeBytes: title.streamSize,
          durationSec: title.duration.inMilliseconds / 1000,
          bitrateMbps: bitrateMbps,
        );
      } catch (error) {
        _log(
          'Policy calculation failed; retaining base ISO cache '
          '(error-type=${error.runtimeType})',
        );
        result = const CachePolicyResult(skipped: true);
      }
      rawPlans[title.mplsId] = (title, result);
      final intelligence = _intelligence;
      if (intelligence != null) {
        unawaited(
          intelligence
              .observeBitrate(
                url: logicalSourceUrl,
                bitrateMbps: bitrateMbps,
                fileSizeBytes: title.streamSize,
              )
              .catchError((Object error) {
                _log(
                  'Bitrate learning write failed; continuing with the base '
                  'policy (error-type=${error.runtimeType})',
                );
              }),
        );
      }
    }

    final bridgeBlockCount = (maximumPrefetch + 2)
        .clamp(_minimumBridgeBlocks, _maximumBridgeBlocks)
        .toInt();
    final bridgeBytes = bridgeBlockCount * CachePolicyEngine.isoBlockSizeBytes;
    final plans = <String, IsoTitleCachePlan>{};
    for (final entry in rawPlans.entries) {
      final title = entry.value.$1;
      final result = entry.value.$2;
      final fallback = result.skipped;
      final memoryBudget = fallback
          ? CachePolicyEngine.fallbackMemoryBudgetBytes
          : result.memoryBudgetBytes;
      final availableForMpv = math.max(1, memoryBudget - bridgeBytes);
      final requestedMpv = fallback
          ? _fallbackMpvMaxBytes
          : result.demuxerMaxBytes;
      final mpvMaxBytes = math.min(
        _fallbackMpvMaxBytes,
        math.min(requestedMpv, availableForMpv),
      );
      final bitrateMbps =
          title.streamSize *
          8 /
          (title.duration.inMilliseconds / 1000) /
          1000000;
      plans[entry.key] = IsoTitleCachePlan(
        mplsId: entry.key,
        cacheSecs: fallback ? _fallbackCacheSecs : result.cacheSecs,
        mpvMaxBytes: mpvMaxBytes,
        memoryBudgetBytes: memoryBudget,
        minCacheSecs: fallback ? 10 : result.minCacheSecs,
        maxCacheSecs: fallback ? 600 : result.maxCacheSecs,
        bitrateMbps: bitrateMbps,
        fileSizeBytes: title.streamSize,
        prefetchBlocks: _prefetchBlocks(title),
      );
    }
    _log(
      'Plan ready: bridge=${bridgeBlockCount * 4}MiB, '
      'prefetch=$maximumPrefetch blocks, titles=${plans.length}',
    );
    return IsoCacheSessionPlan(
      bridgeBlockCount: bridgeBlockCount,
      prefetchBlocks: maximumPrefetch,
      titlePlans: plans,
    );
  }

  static int _prefetchBlocks(IsoCacheTitleContext title) {
    final bytesPerSecond =
        title.streamSize / (title.duration.inMilliseconds / 1000);
    return (bytesPerSecond * 8 / CachePolicyEngine.isoBlockSizeBytes)
        .ceil()
        .clamp(_minimumPrefetchBlocks, _maximumPrefetchBlocks)
        .toInt();
  }

  void startSession({
    required String sessionId,
    required String logicalSourceUrl,
    required String statusFilePath,
    required String metricsFilePath,
    required String ipcPipeName,
    required List<String> orderedMplsIds,
    required IsoCacheSessionPlan plan,
  }) {
    unawaited(stopSession(sessionId));
    final runtime = _IsoCacheRuntime(
      sessionId: sessionId,
      logicalSourceUrl: logicalSourceUrl,
      statusFilePath: statusFilePath,
      metricsFilePath: metricsFilePath,
      orderedMplsIds: List<String>.unmodifiable(orderedMplsIds),
      plan: plan,
      controller: MpvSessionController(pipeName: ipcPipeName),
    );
    _runtimes[sessionId] = runtime;
    unawaited(_initializeRuntime(runtime));
  }

  Future<void> _initializeRuntime(_IsoCacheRuntime runtime) async {
    bool connected;
    try {
      connected = await runtime.controller.connect();
    } catch (error) {
      _log(
        'MPV IPC initialization failed; retaining startup cache parameters '
        '(error-type=${error.runtimeType})',
      );
      return;
    }
    if (!identical(_runtimes[runtime.sessionId], runtime)) {
      await runtime.controller.dispose();
      return;
    }
    if (!connected) {
      _log(
        'MPV IPC connection unavailable; retaining startup cache parameters '
        '(session=${runtime.sessionId})',
      );
      return;
    }
    runtime.timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_pollRuntime(runtime)),
    );
    await _pollRuntime(runtime);
  }

  Future<void> _pollRuntime(_IsoCacheRuntime runtime) async {
    if (runtime.polling || !identical(_runtimes[runtime.sessionId], runtime)) {
      return;
    }
    runtime.polling = true;
    try {
      final lines = await File(runtime.statusFilePath).readAsLines();
      if (lines.length < 16) return;
      final playlistPos = int.tryParse(lines[0].trim());
      final timePos = double.tryParse(lines[3].trim());
      final seeking = lines[13].trim() == '1';
      final restartSerial = int.tryParse(lines[14].trim()) ?? 0;
      final cacheDuration = double.tryParse(lines[15].trim());
      if (playlistPos == null ||
          playlistPos < 0 ||
          playlistPos >= runtime.orderedMplsIds.length) {
        return;
      }
      if (runtime.activePlaylistPos != null &&
          runtime.activePlaylistPos != playlistPos) {
        _closeMonitor(runtime);
        runtime.activePlaylistPos = null;
      }
      if (runtime.stableCandidatePlaylistPos != playlistPos) {
        runtime.stableCandidatePlaylistPos = playlistPos;
        runtime.lastStablePosition = null;
      }
      if (seeking || restartSerial <= 0 || timePos == null || timePos < 0) {
        runtime.lastStablePosition = null;
        return;
      }
      if (runtime.activePlaylistPos == playlistPos) return;
      final previousPosition = runtime.lastStablePosition;
      final positionAdvanced =
          previousPosition != null && timePos > previousPosition + 0.05;
      runtime.lastStablePosition = timePos;
      if ((cacheDuration == null || cacheDuration <= 0) && !positionAdvanced) {
        return;
      }
      final mplsId = runtime.orderedMplsIds[playlistPos];
      final titlePlan = runtime.plan.planFor(mplsId);
      await runtime.controller.setProperty(
        'demuxer-max-bytes',
        titlePlan.mpvMaxBytes,
      );
      await runtime.controller.setProperty('cache-secs', titlePlan.cacheSecs);
      if (!identical(_runtimes[runtime.sessionId], runtime)) return;
      runtime.activePlaylistPos = playlistPos;
      final monitor =
          _monitorFactory?.call() ??
          PlaybackMonitor(
            memoryProvider: _memoryProvider,
            logger: (message) => _log(message),
          );
      runtime.monitor = monitor;
      monitor.start(
        statusFilePath: runtime.statusFilePath,
        initialDemuxerMaxBytes: titlePlan.mpvMaxBytes,
        initialCacheSecs: titlePlan.cacheSecs,
        fileSizeBytes: titlePlan.fileSizeBytes,
        bitrateMbps: titlePlan.bitrateMbps,
        memoryBudgetBytes: titlePlan.mpvMaxBytes,
        minCacheSecs: titlePlan.minCacheSecs,
        maxCacheSecs: titlePlan.maxCacheSecs,
        onAdjustment: (adjustment) =>
            unawaited(_applyAdjustment(runtime, titlePlan, adjustment)),
      );
      _log(
        'Title $mplsId entered dynamic monitoring: '
        'cache=${titlePlan.cacheSecs}s, '
        'mpv=${(titlePlan.mpvMaxBytes / (1024 * 1024)).round()}MiB',
      );
    } on FileSystemException {
      // 状态文件尚未创建或正被原子替换，下一轮继续读取。
    } catch (error) {
      _log(
        'Runtime sampling failed; retaining the last confirmed cache '
        'parameters (error-type=${error.runtimeType})',
      );
    } finally {
      runtime.polling = false;
    }
  }

  Future<void> _applyAdjustment(
    _IsoCacheRuntime runtime,
    IsoTitleCachePlan plan,
    CacheAdjustment adjustment,
  ) async {
    if (!identical(_runtimes[runtime.sessionId], runtime)) return;
    try {
      final bytes = adjustment.demuxerMaxBytes;
      if (bytes != null) {
        await runtime.controller.setProperty(
          'demuxer-max-bytes',
          math.min(bytes, plan.mpvMaxBytes),
        );
      }
      final seconds = adjustment.cacheSecs;
      if (seconds != null) {
        await runtime.controller.setProperty(
          'cache-secs',
          seconds.clamp(plan.minCacheSecs, plan.maxCacheSecs),
        );
      }
    } catch (error) {
      _log(
        'Dynamic MPV adjustment failed; retaining the last confirmed values '
        '(error-type=${error.runtimeType})',
      );
    }
  }

  Future<void> stopSession(String sessionId) async {
    final runtime = _runtimes.remove(sessionId);
    if (runtime == null) return;
    runtime.timer?.cancel();
    _closeMonitor(runtime);
    await runtime.controller.dispose();
    final outcome = await _buildOutcome(runtime);
    final intelligence = _intelligence;
    if (intelligence != null && outcome.hasUsefulSamples) {
      try {
        await intelligence.observeSession(
          url: runtime.logicalSourceUrl,
          outcome: outcome,
        );
      } catch (error) {
        _log(
          'Session learning write failed; ISO cleanup continues '
          '(error-type=${error.runtimeType})',
        );
      }
    }
  }

  void _closeMonitor(_IsoCacheRuntime runtime) {
    final monitor = runtime.monitor;
    if (monitor == null) return;
    runtime.outcomes.add(monitor.snapshotOutcome());
    monitor.stop();
    runtime.monitor = null;
  }

  Future<PlaybackSessionOutcome> _buildOutcome(_IsoCacheRuntime runtime) async {
    var sampleCount = 0;
    var stallCount = 0;
    var forwardSeekCount = 0;
    var backwardSeekCount = 0;
    var pausedSampleCount = 0;
    double? lastPosition;
    double? duration;
    var completed = false;
    for (final outcome in runtime.outcomes) {
      sampleCount += outcome.sampleCount;
      stallCount += outcome.stallCount;
      forwardSeekCount += outcome.forwardSeekCount;
      backwardSeekCount += outcome.backwardSeekCount;
      pausedSampleCount += outcome.pausedSampleCount;
      lastPosition = outcome.lastPositionSec ?? lastPosition;
      duration = outcome.durationSec ?? duration;
      completed = completed || outcome.completed;
    }
    double? upstreamSpeed;
    try {
      final raw = jsonDecode(
        await File(runtime.metricsFilePath).readAsString(),
      );
      final metrics = IsoBridgeMetricsSnapshot.tryParse(raw);
      final bytes = metrics?.remoteBodyBytes?.toDouble();
      final micros = metrics?.remoteTransferActiveMicroseconds?.toDouble();
      if (bytes != null && bytes > 0 && micros != null && micros > 0) {
        upstreamSpeed = bytes * 1000000 / micros;
      }
    } on FileSystemException {
      // helper 未能写出最终指标时仍保留 MPV 卡顿与拖动样本。
    } on FormatException {
      // 损坏指标不写入吞吐画像。
    }
    return PlaybackSessionOutcome(
      sampleCount: sampleCount,
      stallCount: stallCount,
      forwardSeekCount: forwardSeekCount,
      backwardSeekCount: backwardSeekCount,
      pausedSampleCount: pausedSampleCount,
      meanNetworkSpeedBps: upstreamSpeed,
      lastPositionSec: lastPosition,
      durationSec: duration,
      completed: completed,
    );
  }

  void dispose() {
    for (final sessionId in _runtimes.keys.toList(growable: false)) {
      unawaited(stopSession(sessionId));
    }
  }
}

class _IsoCacheRuntime {
  _IsoCacheRuntime({
    required this.sessionId,
    required this.logicalSourceUrl,
    required this.statusFilePath,
    required this.metricsFilePath,
    required this.orderedMplsIds,
    required this.plan,
    required this.controller,
  });

  final String sessionId;
  final String logicalSourceUrl;
  final String statusFilePath;
  final String metricsFilePath;
  final List<String> orderedMplsIds;
  final IsoCacheSessionPlan plan;
  final MpvSessionController controller;
  final List<PlaybackSessionOutcome> outcomes = [];
  Timer? timer;
  PlaybackMonitor? monitor;
  int? activePlaylistPos;
  int? stableCandidatePlaylistPos;
  double? lastStablePosition;
  bool polling = false;
}
