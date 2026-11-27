import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../../domain/services/iso_access_provider.dart';
import '../../domain/services/mpv_session_controller.dart';
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
    required this.programmeId,
    required this.streamSize,
    required this.duration,
  });

  final String programmeId;
  final int streamSize;
  final Duration duration;
}

/// 单个 ISO Title 的 MPV 缓存计划。
class IsoTitleCachePlan {
  const IsoTitleCachePlan({
    required this.programmeId,
    required this.cacheSecs,
    required this.mpvMaxBytes,
    required this.memoryBudgetBytes,
    required this.minCacheSecs,
    required this.maxCacheSecs,
    required this.bitrateMbps,
    required this.fileSizeBytes,
    required this.prefetchBlocks,
    this.forwardCapacityTarget,
  });

  final String programmeId;
  final int cacheSecs;
  final int mpvMaxBytes;
  final int memoryBudgetBytes;
  final int minCacheSecs;
  final int maxCacheSecs;
  final double bitrateMbps;
  final int fileSizeBytes;
  final int prefetchBlocks;
  final int? forwardCapacityTarget;
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
    MpvSessionController Function(String pipeName)? controllerFactory,
    void Function(String message)? logger,
    String verifiedUhdDiscKey = '',
  }) : // 对外保留可读的命名参数，私有字段不能用 initializing formal 暴露。
       // ignore: prefer_initializing_formals
       _policyService = policyService,
       // ignore: prefer_initializing_formals
       _intelligence = intelligence,
       _memoryProvider = memoryProvider ?? platformMemoryProvider(),
       // ignore: prefer_initializing_formals
       _monitorFactory = monitorFactory,
       // ignore: prefer_initializing_formals
       _controllerFactory = controllerFactory,
       // ignore: prefer_initializing_formals
       _verifiedUhdDiscKey = verifiedUhdDiscKey,
       _logger = logger ?? _defaultLogger;

  static const int _fallbackCacheSecs = 60;
  static const int _mib = 1024 * 1024;
  static const int _fallbackMpvMaxBytes = 512 * _mib;
  static const int _uhdForwardTarget = 640 * _mib;
  // Bridge 的缓存槽位已计入预算，这里只留一个最大 Range 的临时余量。
  static const int _bridgeTransferAllowance = 32 * _mib;
  static const int _nearForwardLimit = _fallbackMpvMaxBytes * 97 ~/ 100;
  static const _freshness = Duration(milliseconds: 2500);
  static const int _minimumBridgeBlocks = 4;
  static const int _maximumBridgeBlocks = 16;
  static const int _minimumPrefetchBlocks = 4;
  static const int _maximumPrefetchBlocks = 12;

  final CachePolicyService _policyService;
  IsoCacheCoordinator forFilmLibrary() => IsoCacheCoordinator(
    policyService: _policyService,
    intelligence: _intelligence,
    memoryProvider: _memoryProvider,
    monitorFactory: _monitorFactory,
    controllerFactory: _controllerFactory,
    logger: _logger,
    verifiedUhdDiscKey: _verifiedUhdDiscKey,
  );
  final CacheIntelligenceProvider? _intelligence;
  final SystemMemoryProvider _memoryProvider;
  final PlaybackMonitor Function()? _monitorFactory;
  final MpvSessionController Function(String)? _controllerFactory;
  final String _verifiedUhdDiscKey;
  final void Function(String message) _logger;
  final Map<String, _IsoCacheRuntime> _runtimes = {};
  static final _sharedRuntimes = Expando<Set<_IsoCacheRuntime>>(
    'ISO playback runtimes',
  );
  Set<_IsoCacheRuntime> get _playing =>
      _sharedRuntimes[_policyService] ??= <_IsoCacheRuntime>{};

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
      _log(
        'Menu policy calculation failed; retaining base ISO cache '
        '(error-type=${error.runtimeType})',
      );
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
    final blocks = (budget ~/ CachePolicyEngine.isoBlockSizeBytes).clamp(
      4,
      256,
    );
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
    String? remoteSingleDiscKey,
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
      rawPlans[title.programmeId] = (title, result);
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
      final pilotEligible =
          _verifiedUhdDiscKey.isNotEmpty &&
          remoteSingleDiscKey == _verifiedUhdDiscKey &&
          titles.length == 1 &&
          bitrateMbps * CachePolicyEngine.bytesPerSecondPerMbps >= 8 * _mib &&
          !fallback &&
          mpvMaxBytes == _fallbackMpvMaxBytes &&
          requestedMpv >= _uhdForwardTarget &&
          memoryBudget >=
              _uhdForwardTarget + bridgeBytes + _bridgeTransferAllowance;
      plans[entry.key] = IsoTitleCachePlan(
        programmeId: entry.key,
        cacheSecs: fallback ? _fallbackCacheSecs : result.cacheSecs,
        mpvMaxBytes: mpvMaxBytes,
        memoryBudgetBytes: memoryBudget,
        minCacheSecs: fallback ? 10 : result.minCacheSecs,
        maxCacheSecs: fallback ? 600 : result.maxCacheSecs,
        bitrateMbps: bitrateMbps,
        fileSizeBytes: title.streamSize,
        prefetchBlocks: _prefetchBlocks(title),
        forwardCapacityTarget: pilotEligible ? _uhdForwardTarget : null,
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
    required List<String> orderedProgrammeIds,
    required IsoCacheSessionPlan plan,
    Future<void> Function(Map<String, Object?>)? onCapacityDecision,
    bool Function()? hasOtherDiscPlayback,
  }) {
    unawaited(stopSession(sessionId));
    final runtime = _IsoCacheRuntime(
      sessionId: sessionId,
      logicalSourceUrl: logicalSourceUrl,
      statusFilePath: statusFilePath,
      metricsFilePath: metricsFilePath,
      orderedProgrammeIds: List<String>.unmodifiable(orderedProgrammeIds),
      plan: plan,
      controller:
          _controllerFactory?.call(ipcPipeName) ??
          MpvSessionController(pipeName: ipcPipeName),
      onCapacityDecision: onCapacityDecision,
      hasOtherDiscPlayback: hasOtherDiscPlayback,
    );
    _runtimes[sessionId] = runtime;
    _playing.add(runtime);
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
      if (lines.length < 16 || !_isCurrent(runtime)) return;
      final playlistPos = int.tryParse(lines[0].trim());
      final timePos = double.tryParse(lines[3].trim());
      final seeking = lines[13].trim() == '1';
      final restartSerial = int.tryParse(lines[14].trim()) ?? 0;
      final cacheDuration = double.tryParse(lines[15].trim());
      if (playlistPos == null ||
          playlistPos < 0 ||
          playlistPos >= runtime.orderedProgrammeIds.length) {
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
        runtime.resetCapacitySamples();
        return;
      }
      final previousPosition = runtime.lastStablePosition;
      final positionAdvanced =
          previousPosition != null && timePos > previousPosition + 0.05;
      if (runtime.activePlaylistPos == playlistPos) {
        final monitor = runtime.monitor!;
        if (runtime.forwardTarget != null) {
          runtime.lastStablePosition = timePos;
          await _sampleForwardCapacity(
            runtime,
            monitor,
            lines,
            playlistPos,
            restartSerial,
            positionAdvanced,
          );
        }
        return;
      }
      runtime.lastStablePosition = timePos;
      if ((cacheDuration == null || cacheDuration <= 0) && !positionAdvanced) {
        return;
      }
      final mplsId = runtime.orderedProgrammeIds[playlistPos];
      final titlePlan = runtime.plan.planFor(mplsId);
      if (!_isCurrent(runtime) || runtime.adjustment != null) return;
      await runtime.controller.setProperty(
        'demuxer-max-bytes',
        titlePlan.mpvMaxBytes,
      );
      if (!_isCurrent(runtime)) return;
      await runtime.controller.setProperty('cache-secs', titlePlan.cacheSecs);
      if (!_isCurrent(runtime)) return;
      runtime.activePlaylistPos = playlistPos;
      runtime.forwardTarget = titlePlan.forwardCapacityTarget;
      runtime.forwardBudget = titlePlan.mpvMaxBytes;
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
        onAdjustment: (adjustment) {
          final previous = runtime.adjustment;
          late final Future<void> operation;
          operation = (previous ?? Future<void>.value()).then((_) async {
            try {
              await _applyAdjustment(runtime, monitor, titlePlan, adjustment);
            } finally {
              if (identical(runtime.adjustment, operation)) {
                runtime.adjustment = null;
              }
            }
          });
          runtime.adjustment = operation;
          unawaited(operation);
        },
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

  bool _isCurrent(_IsoCacheRuntime runtime, [PlaybackMonitor? monitor]) =>
      identical(_runtimes[runtime.sessionId], runtime) &&
      (monitor == null || identical(runtime.monitor, monitor));

  bool _hasSharedPlayback(_IsoCacheRuntime runtime) =>
      _playing.length != 1 ||
      runtime.hasOtherDiscPlayback?.call() == true ||
      _policyService.hasActiveMonitors;

  Future<void> _sampleForwardCapacity(
    _IsoCacheRuntime runtime,
    PlaybackMonitor monitor,
    List<String> lines,
    int playlistPos,
    int restartSerial,
    bool positionAdvanced,
  ) async {
    if (runtime.adjustment != null || !_isCurrent(runtime, monitor)) return;
    if (runtime.capacityUnconfirmed) {
      if (runtime.reconcileOnStableSample &&
          positionAdvanced &&
          _playingStatus(lines)) {
        runtime.reconcileOnStableSample = false;
        monitor.deferSample = true;
        try {
          await _reconcileForwardCapacity(runtime, monitor);
        } finally {
          monitor.deferSample = false;
        }
      }
      return;
    }
    if (runtime.capacityAttempted) return;
    final forward = lines.length < 18 ? null : int.tryParse(lines[16]);
    final total = lines.length < 18 ? null : int.tryParse(lines[17]);
    final duration = double.tryParse(lines[15]);
    final statusTime = await File(runtime.statusFilePath).lastModified();
    if (!_playingStatus(lines) ||
        !_fresh(statusTime) ||
        forward == null ||
        forward < 0 ||
        duration == null ||
        !duration.isFinite ||
        duration <= 0) {
      runtime.resetCapacitySamples();
      return;
    }
    if (runtime.capacityRestart != restartSerial) {
      runtime.resetCapacitySamples();
      runtime.capacityRestart = restartSerial;
    }
    if (runtime.lastCapacityStatus == statusTime) return;
    if (!positionAdvanced) {
      runtime.resetCapacitySamples();
      return;
    }
    final plan = runtime.plan.planFor(runtime.orderedProgrammeIds[playlistPos]);
    final belowLimit = forward < _nearForwardLimit;
    await _sampleUpstream(
      runtime,
      demand: belowLimit && lines[7].trim() == '0',
      requiredBytesPerSecond:
          plan.bitrateMbps * CachePolicyEngine.bytesPerSecondPerMbps * 1.2,
    );
    runtime.lastCapacityStatus = statusTime;
    runtime.highSamples = belowLimit ? 0 : runtime.highSamples + 1;
    final sourceWindow = runtime.healthyUpstream;
    if (runtime.highSamples < 2 ||
        sourceWindow == null ||
        !_fresh(sourceWindow.time, maxAge: const Duration(seconds: 8)) ||
        runtime.adjustment != null ||
        !_isCurrent(runtime, monitor) ||
        _hasSharedPlayback(runtime) ||
        (runtime.lastCapacityProbe != null &&
            _fresh(
              runtime.lastCapacityProbe!,
              maxAge: const Duration(seconds: 5),
            )) ||
        monitor.currentDemuxerMaxBytes != _fallbackMpvMaxBytes) {
      return;
    }

    runtime.lastCapacityProbe = DateTime.now();
    monitor.deferSample = true;
    final target = runtime.forwardTarget!;
    int? effective;
    int? backward;
    int? available;
    int? requiredBudget;
    num? targetSeconds;
    String? reason;
    try {
      effective = await _readForwardLimit(runtime);
      if (effective != _fallbackMpvMaxBytes) {
        reason = 'unexpected-forward-limit';
        return;
      }
      final back = await runtime.controller.getProperty(
        'options/demuxer-max-back-bytes',
      );
      backward = back is int && back >= 0 ? back : null;
      if (backward == null) {
        reason = 'unknown-backward-limit';
        return;
      }
      final seconds = await runtime.controller.getProperty(
        'options/cache-secs',
      );
      targetSeconds = seconds is num ? seconds : null;
      if (targetSeconds == null ||
          !targetSeconds.isFinite ||
          targetSeconds < duration * target / forward) {
        reason = 'cache-seconds-limited';
        return;
      }
      requiredBudget =
          target +
          backward +
          runtime.plan.bridgeBytes +
          _bridgeTransferAllowance;
      available = await _memoryProvider.availableMemoryBytes();
      if (requiredBudget > plan.memoryBudgetBytes ||
          available == null ||
          available < requiredBudget * monitor.memoryPressureFactor) {
        reason = 'memory-budget';
        return;
      }
      if (_hasSharedPlayback(runtime) ||
          !await _samePlayingGeneration(
            runtime,
            monitor,
            playlistPos,
            restartSerial,
            requireHighWater: true,
          ) ||
          _hasSharedPlayback(runtime)) {
        return;
      }
      runtime.capacityAttempted = true;
      runtime.capacityUnconfirmed = true;
      runtime.reconcileOnStableSample = true;
      effective = null;
      await runtime.controller.setProperty('demuxer-max-bytes', target);
      effective = await _readForwardLimit(runtime);
      if (!await _samePlayingGeneration(
        runtime,
        monitor,
        playlistPos,
        restartSerial,
      )) {
        reason = 'generation-changed';
        return;
      }
      _confirmForwardCapacity(runtime, monitor, effective);
      reason = effective == target ? 'promoted' : 'readback-mismatch';
    } on Object catch (error) {
      reason = runtime.capacityAttempted
          ? 'write-or-readback-failed'
          : 'option-unavailable';
      if (runtime.capacityUnconfirmed) {
        effective = await _reconcileForwardCapacity(runtime, monitor);
      } else if (error is TimeoutException || !runtime.controller.isConnected) {
        await _reconnectForCapacity(runtime, monitor);
      }
    } finally {
      monitor.deferSample = false;
      if (reason != null && _isCurrent(runtime, monitor)) {
        if (reason == 'option-unavailable' ||
            reason == 'unknown-backward-limit' ||
            reason == 'unexpected-forward-limit') {
          runtime.capacityAttempted = true;
        }
        if (runtime.capacityReasons.add(reason)) {
          _log(
            'Forward capacity: $reason, target=$target, effective=$effective',
          );
          await runtime.onCapacityDecision?.call(<String, Object?>{
            'reason': reason,
            'playlist_pos': playlistPos,
            'restart_serial': restartSerial,
            'target_bytes': target,
            'effective_bytes': effective,
            'forward_bytes': forward,
            'total_bytes': total != null && total >= 0 ? total : null,
            'backward_limit_bytes': backward,
            'bridge_budget_bytes': runtime.plan.bridgeBytes,
            'upstream_bytes_per_second': sourceWindow.bytesPerSecond.round(),
            'upstream_window_ms': sourceWindow.windowMs,
            'policy_budget_bytes': plan.memoryBudgetBytes,
            'required_budget_bytes': requiredBudget,
            'available_memory_bytes': available,
            'cache_seconds': targetSeconds,
          });
        }
      }
    }
  }

  static bool _fresh(DateTime time, {Duration maxAge = _freshness}) {
    final age = DateTime.now().difference(time);
    return !age.isNegative && age <= maxAge;
  }

  static bool _playingStatus(List<String> lines) {
    final position = double.tryParse(lines[3]);
    final length = double.tryParse(lines[4]);
    return lines[2].trim() == '0' &&
        lines[9].trim() == '0' &&
        lines[11].trim() == '0' &&
        lines[13].trim() == '0' &&
        position != null &&
        position >= 0 &&
        length != null &&
        position < length - 5;
  }

  Future<bool> _samePlayingGeneration(
    _IsoCacheRuntime runtime,
    PlaybackMonitor monitor,
    int playlistPos,
    int restartSerial, {
    bool requireHighWater = false,
  }) async {
    if (!_isCurrent(runtime, monitor)) return false;
    final file = File(runtime.statusFilePath);
    try {
      final modified = await file.lastModified();
      final lines = await file.readAsLines();
      return await file.lastModified() == modified &&
          _isCurrent(runtime, monitor) &&
          lines.length >= 18 &&
          int.tryParse(lines[0]) == playlistPos &&
          int.tryParse(lines[14]) == restartSerial &&
          _playingStatus(lines) &&
          (!requireHighWater ||
              (int.tryParse(lines[16]) ?? -1) >= _nearForwardLimit) &&
          _fresh(modified);
    } on FileSystemException {
      return false;
    }
  }

  Future<void> _sampleUpstream(
    _IsoCacheRuntime runtime, {
    required bool demand,
    required double requiredBytesPerSecond,
  }) async {
    final file = File(runtime.metricsFilePath);
    try {
      final timestamp = await file.lastModified();
      if (!_fresh(timestamp)) {
        runtime.lastUpstream = null;
        runtime.upstreamStreak = 0;
        runtime.healthyUpstream = null;
        return;
      }
      final previous = runtime.lastUpstream;
      if (previous?.time == timestamp) return;
      final snapshot = IsoBridgeMetricsSnapshot.tryParse(
        jsonDecode(await file.readAsString()),
      );
      if (await file.lastModified() != timestamp) return;
      final bytes = snapshot?.playbackNetwork?.remoteBodyBytes;
      if (bytes == null || snapshot?.finalSnapshot == true) {
        runtime.lastUpstream = null;
        runtime.upstreamStreak = 0;
        runtime.healthyUpstream = null;
        return;
      }
      runtime.lastUpstream = (time: timestamp, bytes: bytes, demand: demand);
      // 满水位及停读期间的差分不说明来源的可用吞吐。
      if (previous != null && demand && previous.demand) {
        final windowMs = timestamp.difference(previous.time).inMilliseconds;
        final bps = windowMs > 0
            ? (bytes - previous.bytes) * 1000 / windowMs
            : 0.0;
        if (windowMs >= 500 &&
            windowMs <= 2500 &&
            bps >= requiredBytesPerSecond) {
          runtime.upstreamStreak++;
          if (runtime.upstreamStreak >= 2) {
            runtime.healthyUpstream = (
              time: timestamp,
              bytesPerSecond: bps,
              windowMs: windowMs,
            );
          }
        } else {
          runtime.upstreamStreak = 0;
          runtime.healthyUpstream = null;
        }
      } else {
        runtime.upstreamStreak = 0;
      }
    } on FileSystemException {
      runtime.lastUpstream = null;
      runtime.upstreamStreak = 0;
      runtime.healthyUpstream = null;
    } on FormatException {
      runtime.lastUpstream = null;
      runtime.upstreamStreak = 0;
      runtime.healthyUpstream = null;
    }
  }

  Future<int?> _readForwardLimit(_IsoCacheRuntime runtime) async {
    final value = await runtime.controller.getProperty(
      'options/demuxer-max-bytes',
    );
    return value is int && value > 0 ? value : null;
  }

  Future<bool> _reconnectForCapacity(
    _IsoCacheRuntime runtime,
    PlaybackMonitor monitor,
  ) async {
    if (!_isCurrent(runtime, monitor)) return false;
    if (runtime.controller.isConnected) return true;
    return await runtime.controller.connect(
          timeout: const Duration(seconds: 1),
        ) &&
        _isCurrent(runtime, monitor);
  }

  Future<int?> _reconcileForwardCapacity(
    _IsoCacheRuntime runtime,
    PlaybackMonitor monitor,
  ) async {
    if (runtime.reconciling) return null;
    runtime.reconciling = true;
    try {
      if (!await _reconnectForCapacity(runtime, monitor)) return null;
      final confirmed = await _readForwardLimit(runtime);
      if (_isCurrent(runtime, monitor)) {
        _confirmForwardCapacity(runtime, monitor, confirmed);
        return confirmed;
      }
    } on TimeoutException {
      // 连接恢复后由下一次调整重新确认。
    } on StateError {
      // MPV 退出或属性不可用时维持未确认状态。
    } finally {
      runtime.reconciling = false;
    }
    return null;
  }

  void _confirmForwardCapacity(
    _IsoCacheRuntime runtime,
    PlaybackMonitor monitor,
    int? effective,
  ) {
    if (effective == null) return;
    runtime.capacityUnconfirmed = false;
    runtime.reconcileOnStableSample = false;
    if (effective == runtime.forwardTarget) runtime.forwardBudget = effective;
    monitor.confirmDemuxerBudget(
      demuxerMaxBytes: effective,
      memoryBudgetBytes: runtime.forwardBudget!,
    );
  }

  Future<void> _applyAdjustment(
    _IsoCacheRuntime runtime,
    PlaybackMonitor monitor,
    IsoTitleCachePlan plan,
    CacheAdjustment adjustment,
  ) async {
    if (!_isCurrent(runtime, monitor)) return;
    try {
      final reconciling = runtime.capacityUnconfirmed;
      if (reconciling) {
        await _reconcileForwardCapacity(runtime, monitor);
      }
      if (!_isCurrent(runtime, monitor)) return;
      final bytes = adjustment.demuxerMaxBytes;
      if (bytes != null) {
        final capped = math.min(bytes, runtime.forwardBudget!);
        await runtime.controller.setProperty('demuxer-max-bytes', capped);
        if (reconciling && _isCurrent(runtime, monitor)) {
          final confirmed = await _readForwardLimit(runtime);
          if (_isCurrent(runtime, monitor)) {
            _confirmForwardCapacity(runtime, monitor, confirmed);
          }
        }
      }
      if (!_isCurrent(runtime, monitor)) return;
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
    _playing.remove(runtime);
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
    required this.orderedProgrammeIds,
    required this.plan,
    required this.controller,
    this.onCapacityDecision,
    this.hasOtherDiscPlayback,
  });

  final String sessionId;
  final String logicalSourceUrl;
  final String statusFilePath;
  final String metricsFilePath;
  final List<String> orderedProgrammeIds;
  final IsoCacheSessionPlan plan;
  final MpvSessionController controller;
  final Future<void> Function(Map<String, Object?>)? onCapacityDecision;
  final bool Function()? hasOtherDiscPlayback;
  final List<PlaybackSessionOutcome> outcomes = [];
  Timer? timer;
  PlaybackMonitor? monitor;
  int? activePlaylistPos;
  int? stableCandidatePlaylistPos;
  double? lastStablePosition;
  bool polling = false;
  Future<void>? adjustment;
  int? forwardTarget;
  int? forwardBudget;
  bool capacityAttempted = false;
  bool capacityUnconfirmed = false;
  bool reconcileOnStableSample = false;
  bool reconciling = false;
  int? capacityRestart;
  int highSamples = 0;
  DateTime? lastCapacityStatus;
  DateTime? lastCapacityProbe;
  ({DateTime time, int bytes, bool demand})? lastUpstream;
  int upstreamStreak = 0;
  ({DateTime time, double bytesPerSecond, int windowMs})? healthyUpstream;
  final Set<String> capacityReasons = {};

  void resetCapacitySamples() {
    highSamples = 0;
    lastCapacityStatus = null;
    lastUpstream = null;
    upstreamStreak = 0;
    healthyUpstream = null;
  }
}
