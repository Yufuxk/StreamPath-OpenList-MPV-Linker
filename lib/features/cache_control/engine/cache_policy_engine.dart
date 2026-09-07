import '../models/cache_policy_config.dart';
import '../models/cache_policy_result.dart';

/// MPV 智能缓存策略引擎（纯 Dart，四层递进式架构）。
///
/// 对应算法文档的运转模型：
/// ```text
/// 视频分析 → 基础缓存计算（Layer 2） → 内存安全限制（Layer 1）
///         → 网络风险修正（Layer 3） → Health Score 评分 → 生成 MPV 策略
/// ```
///
/// 本引擎无任何 IO 与外部依赖，输入（配置 + 媒体上下文）输出
/// （[CachePolicyResult]）皆为纯数据，便于单元测试与后续扩展
/// （第二阶段：播放中水位监控、网络趋势、PID 控制均可作为新层接入）。
class CachePolicyEngine {
  const CachePolicyEngine();

  // ── 常量 ─────────────────────────────────────────────────────

  /// 内存未知时的保守预算兜底（1GiB），避免无限制缓存。
  static const int fallbackMemoryBudgetBytes = 1024 * 1024 * 1024;

  /// Mbps → bytes/s 换算（1 Mbps = 125,000 bytes/s）。
  static const int bytesPerSecondPerMbps = 125000;

  /// 缓存容量安全系数（设计文档第 8 节推荐 1.3）：
  /// 上限 = 码率 × 目标秒数 × 该系数，为码率波动留出余量。
  static const double safetyFactor = 1.3;

  /// 全量缓存时为 demuxer 数据结构和容器包开销预留的空间。
  static const double fullCacheOverheadFactor = 1.10;

  /// 无法取得时长时使用足够大的预取时长，使字节上限成为真正限制。
  static const int fullCacheFallbackSecs = 3600000;

  /// 网络系数 > 该值时视为网络充足（适度降档）。
  static const double networkFactorRich = 3.0;

  /// 网络系数 < 该值时视为网络危险（主动增档）。
  static const double networkFactorPoor = 1.0;

  /// TS 已稳定起播后的轻量顺序预读上限。启动阶段不启用，避免与
  /// demuxer 打开争抢远端单连接。
  static const int tsRuntimeMaxBytes = 128 * 1024 * 1024;

  /// 普通网络媒体在打开文件或 seek 后恢复播放前建立的前向缓冲。
  static const int initialBufferWaitSecs = 10;

  /// TS/M2TS 保持较短等待，避免破坏现有快速起播路径。
  static const int tsInitialBufferWaitSecs = 5;

  /// ISO Bridge 的固定块粒度，供双层预算协调使用。
  static const int isoBlockSizeBytes = 4 * 1024 * 1024;

  /// 按当前码率与 1.3 安全系数估算字节上限真正能够覆盖的缓存秒数。
  ///
  /// 这是诊断用的保守估算值，不等同于 mpv 已经缓存的实际时长；
  /// 码率未知或输入无效时返回 null。
  int? estimateReachableCacheSecs({
    required int demuxerMaxBytes,
    double? bitrateMbps,
  }) {
    if (demuxerMaxBytes <= 0 ||
        bitrateMbps == null ||
        !bitrateMbps.isFinite ||
        bitrateMbps <= 0) {
      return null;
    }
    return (demuxerMaxBytes /
            (bitrateMbps * bytesPerSecondPerMbps * safetyFactor))
        .floor();
  }

  /// 估算达到目标缓存秒数需要的字节上限（包含 1.3 安全系数）。
  /// 码率未知或输入无效时返回 null。
  int? estimateRequiredCacheBytes({
    required int cacheSecs,
    double? bitrateMbps,
  }) {
    if (cacheSecs <= 0 ||
        bitrateMbps == null ||
        !bitrateMbps.isFinite ||
        bitrateMbps <= 0) {
      return null;
    }
    return (bitrateMbps * cacheSecs * bytesPerSecondPerMbps * safetyFactor)
        .round();
  }

  // ── 档位表（文档 4.1：720P 60s / 1080P 120s / 4K 180s / REMUX 180~300s）──
  //
  // 以配置的 baseCacheSecs（1080P 档）为基准按比例派生，保证用户调
  // 整基准档后全表等比变化。
  static double _tierRatio(MediaTier tier) => switch (tier) {
    MediaTier.hd720 => 0.5,
    MediaTier.hd1080 => 1.0,
    MediaTier.uhd4k => 1.5,
    MediaTier.remux => 2.0,
  };

  /// 从生产环境可获得的分辨率/平均码率推导档位。
  ///
  /// REMUX 优先按高码率识别；其次按分辨率识别 4K/720P。这样即使
  /// metadata 没有预先写入显式 tier，四档策略也能在真实播放链路生效。
  MediaTier classifyTier({
    CachePolicyMode mode = CachePolicyMode.auto,
    double? bitrateMbps,
    String? resolution,
  }) {
    if (mode == CachePolicyMode.remux ||
        (bitrateMbps != null && bitrateMbps >= 50)) {
      return MediaTier.remux;
    }
    final dims = _parseResolution(resolution);
    final height = dims?.$2;
    if ((height != null && height >= 1440) ||
        (bitrateMbps != null && bitrateMbps >= 20)) {
      return MediaTier.uhd4k;
    }
    if ((height != null && height <= 720) ||
        (bitrateMbps != null && bitrateMbps <= 6)) {
      return MediaTier.hd720;
    }
    return MediaTier.hd1080;
  }

  static (int, int)? _parseResolution(String? value) {
    if (value == null) return null;
    final parts = value.split(RegExp(r'[xX×]'));
    if (parts.length != 2) return null;
    final width = int.tryParse(parts[0].trim());
    final height = int.tryParse(parts[1].trim());
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    return (width, height);
  }

  /// 模式对内存预算比例的缩放。
  static double _modeBudgetRatioScale(CachePolicyMode mode) => switch (mode) {
    CachePolicyMode.economy => 0.6,
    CachePolicyMode.performance => 1.2,
    CachePolicyMode.remux => 1.2,
    CachePolicyMode.auto => 1.0,
  };

  /// 模式对缓存秒数的缩放。
  static double _modeSecsScale(CachePolicyMode mode) => switch (mode) {
    CachePolicyMode.economy => 0.6,
    CachePolicyMode.performance => 1.5,
    CachePolicyMode.remux => 1.25,
    CachePolicyMode.auto => 1.0,
  };

  // ── Layer 1：安全限制（内存预算） ────────────────────────────

  /// 内存预算 = 可用内存 × 安全比例。
  ///
  /// [availableMemoryBytes] 为 null（平台不支持/获取失败）时返回
  /// [fallbackMemoryBudgetBytes] 保守兜底，绝不放任无上限缓存。
  int computeMemoryBudget({
    required double budgetRatio,
    int? availableMemoryBytes,
  }) {
    if (availableMemoryBytes == null || availableMemoryBytes <= 0) {
      return fallbackMemoryBudgetBytes;
    }
    return (availableMemoryBytes * budgetRatio).round();
  }

  // ── Layer 2：规则策略（码率/时长档位） ───────────────────────

  /// 按档位派生基准缓存秒数（未指定档位时取基准档 1080P）。
  int pickBaseCacheSecs({
    required CachePolicyMode mode,
    required int baseCacheSecs,
    MediaTier? tier,
  }) {
    final ratio = _tierRatio(tier ?? MediaTier.hd1080);
    final secs = (baseCacheSecs * ratio * _modeSecsScale(mode)).round();
    return secs.clamp(
      CachePolicyConfig.minBaseCacheSecs,
      CachePolicyConfig.maxBaseCacheSecs,
    );
  }

  /// 模式缩放后的内存预算比例（clamp 到合法范围）。
  double effectiveBudgetRatio(CachePolicyConfig config) =>
      (config.memoryBudgetRatio * _modeBudgetRatioScale(config.mode)).clamp(
        CachePolicyConfig.minMemoryBudgetRatio,
        CachePolicyConfig.maxMemoryBudgetRatio,
      );

  // ── Layer 3：网络自适应（安全系数） ──────────────────────────

  /// 网络安全系数 = 下行带宽 / 视频码率；任一未知返回 null（中性）。
  ///
  /// 修正规则（文档 5.1）：>3 网络充足适度降档；1~3 保持默认；
  /// <1 危险状态主动增档。
  double? networkFactor({double? assumedBandwidthMbps, double? bitrateMbps}) {
    if (assumedBandwidthMbps == null ||
        !assumedBandwidthMbps.isFinite ||
        assumedBandwidthMbps <= 0 ||
        bitrateMbps == null ||
        !bitrateMbps.isFinite ||
        bitrateMbps <= 0) {
      return null;
    }
    return assumedBandwidthMbps / bitrateMbps;
  }

  /// 按网络系数修正缓存秒数：>3 降 20%；<1 增 50%；其余保持。
  int adjustCacheSecsForNetwork(int cacheSecs, double? factor) {
    if (factor == null) return cacheSecs;
    if (factor > networkFactorRich) {
      return (cacheSecs * 0.8).round().clamp(
        CachePolicyConfig.minBaseCacheSecs,
        CachePolicyConfig.maxBaseCacheSecs,
      );
    }
    if (factor < networkFactorPoor) {
      return (cacheSecs * 1.5).round().clamp(
        CachePolicyConfig.minBaseCacheSecs,
        CachePolicyConfig.maxBaseCacheSecs,
      );
    }
    return cacheSecs;
  }

  // ── Health Score：缓冲健康评分（文档 6.1，满分 100） ─────────

  /// 综合评分 = 网络(40) + 缓存(40) + 内存(20)。
  ///
  /// - 网络：factor ≥ 2 远高 40 / 1~2 接近 25 / <1 低于 10 / 未知 25；
  /// - 缓存：秒数 ≥ 180 充足 40 / 60~179 一般 25 / <60 不足 10；
  /// - 内存：可用 ≥ 8GB 健康 20 / 4~8GB 压力 10 / <4GB 危险 0。
  int computeHealthScore({
    double? networkFactor,
    required int cacheSecs,
    int? availableMemoryBytes,
    int? demuxerMaxBytes,
    double? bitrateMbps,
  }) {
    // 网络评分（40）。
    final int networkScore;
    if (networkFactor == null) {
      networkScore = 25;
    } else if (networkFactor >= 2.0) {
      networkScore = 40;
    } else if (networkFactor >= 1.0) {
      networkScore = 25;
    } else {
      networkScore = 10;
    }

    // 缓存评分（40）。
    final reachableSecs = demuxerMaxBytes == null
        ? cacheSecs
        : estimateReachableCacheSecs(
                demuxerMaxBytes: demuxerMaxBytes,
                bitrateMbps: bitrateMbps,
              ) ??
              cacheSecs;
    final effectiveCacheSecs = reachableSecs < cacheSecs
        ? reachableSecs
        : cacheSecs;
    final int bufferScore;
    if (effectiveCacheSecs >= 180) {
      bufferScore = 40;
    } else if (effectiveCacheSecs >= 60) {
      bufferScore = 25;
    } else {
      bufferScore = 10;
    }

    // 内存评分（20）。
    final int memoryScore;
    if (availableMemoryBytes == null) {
      // 未知不是健康：给中间分，避免遥测缺失被误报成满分。
      memoryScore = 10;
    } else if (availableMemoryBytes >= 8 * 1024 * 1024 * 1024) {
      memoryScore = 20;
    } else if (availableMemoryBytes >= 4 * 1024 * 1024 * 1024) {
      memoryScore = 10;
    } else {
      memoryScore = 0;
    }

    return networkScore + bufferScore + memoryScore;
  }

  // ── 综合编排 ─────────────────────────────────────────────────

  /// TS 容器稳定起播后的轻量策略。不探测时长、不做 seek，只启用小型
  /// 顺序预读；`demuxer-seekable-cache=no` 始终保留。
  CachePolicyResult buildTsRuntimePolicy({
    required CachePolicyConfig config,
    int? availableMemoryBytes,
  }) {
    if (!config.enabled) {
      return const CachePolicyResult(skipped: true);
    }
    final budget = computeMemoryBudget(
      budgetRatio: effectiveBudgetRatio(config),
      availableMemoryBytes: availableMemoryBytes,
    );
    final cacheSecs = (config.baseCacheSecs / 4).round().clamp(15, 60);
    final maxBytes = mathMin(budget, tsRuntimeMaxBytes);
    final health = computeHealthScore(
      cacheSecs: cacheSecs,
      availableMemoryBytes: availableMemoryBytes,
      demuxerMaxBytes: maxBytes,
    );
    return CachePolicyResult(
      skipped: false,
      cacheSecs: cacheSecs,
      demuxerMaxBytes: maxBytes,
      memoryBudgetBytes: budget,
      minCacheSecs: 15,
      maxCacheSecs: 120,
      healthScore: health,
      layers: const [
        'TS runtime phase: lightweight sequential read-ahead after playback started',
        'TS seekable cache disabled: no startup duration scan or cache seek',
      ],
      args: [
        '--cache=yes',
        '--cache-secs=$cacheSecs',
        '--demuxer-max-bytes=$maxBytes',
        '--demuxer-seekable-cache=no',
        '--cache-pause=yes',
        '--cache-pause-initial=yes',
        '--cache-pause-wait=$tsInitialBufferWaitSecs',
      ],
    );
  }

  static int mathMin(int a, int b) => a < b ? a : b;

  /// 生成完整缓存策略（四层递进）。
  ///
  /// [fileSizeBytes]：媒体文件大小（HEAD 探测/元数据），未知传 null；
  /// [bitrateMbps]：平均码率（第一版通常未知，走默认估算）；
  /// [tier]：码率档位（第一版通常未知，走基准档）；
  /// [availableMemoryBytes]：系统可用内存，未知传 null（保守兜底）。
  ///
  /// 返回结果恒为有效策略；[config.enabled] 为 false 时返回
  /// [CachePolicyResult.skipped] == true（args 为空）。
  CachePolicyResult buildPolicy({
    required CachePolicyConfig config,
    int? fileSizeBytes,
    double? bitrateMbps,
    String? bitrateSource,
    MediaTier? tier,
    String? resolution,
    double? durationSec,
    int? availableMemoryBytes,
  }) {
    if (!config.enabled) {
      return const CachePolicyResult(
        skipped: true,
        layers: ['Cache system disabled (enabled=false), skip injection'],
      );
    }

    final layers = <String>[];

    // ── Layer 1：内存预算（安全底线） ─────────────────────
    final budgetRatio = effectiveBudgetRatio(config);
    final budget = computeMemoryBudget(
      budgetRatio: budgetRatio,
      availableMemoryBytes: availableMemoryBytes,
    );
    layers.add(
      'Layer1 memory budget: ${availableMemoryBytes == null ? 'unknown(fallback 1GiB)' : '${(availableMemoryBytes / (1024 * 1024)).round()}MiB'} x ${(budgetRatio * 100).toStringAsFixed(0)}% = ${(budget / (1024 * 1024)).round()}MiB',
    );

    // ── Layer 2：基础缓存秒数（档位派生） ─────────────────
    final effectiveTier =
        tier ??
        classifyTier(
          mode: config.mode,
          bitrateMbps: bitrateMbps,
          resolution: resolution,
        );
    var cacheSecs = pickBaseCacheSecs(
      mode: config.mode,
      baseCacheSecs: config.baseCacheSecs,
      tier: effectiveTier,
    );
    layers.add('Layer2 base cache: ${effectiveTier.label} tier ${cacheSecs}s');

    // ── Layer 3：网络风险修正 ─────────────────────────────
    final factor = networkFactor(
      assumedBandwidthMbps: config.assumedBandwidthMbps,
      bitrateMbps: bitrateMbps,
    );
    cacheSecs = adjustCacheSecsForNetwork(cacheSecs, factor);
    layers.add(
      factor == null
          ? 'Layer3 network factor: unknown (no bandwidth/bitrate), neutral'
          : 'Layer3 network factor: ${factor.toStringAsFixed(2)} (${factor > networkFactorRich
                ? 'rich-downscale'
                : factor < networkFactorPoor
                ? 'poor-upscale'
                : 'normal-keep'}) -> ${cacheSecs}s',
    );

    // ── 小文件全量策略（文档 6.1） ────────────────────────
    // 文件小于「全量阈值」且小于内存预算 → 允许缓存整个文件，
    // 接近本地播放体验；同时受 fullCacheMaxBytes 兜底保护。
    final smallFileThresholdBytes = config.smallFileThresholdMB * 1024 * 1024;
    final fullCacheBytes = fileSizeBytes == null
        ? null
        : (fileSizeBytes * fullCacheOverheadFactor).ceil();
    final fullCache =
        fileSizeBytes != null &&
        fileSizeBytes > 0 &&
        fileSizeBytes <= smallFileThresholdBytes &&
        fullCacheBytes! <= budget &&
        fullCacheBytes <= CachePolicyResult.fullCacheMaxBytes;

    if (fullCache) {
      final estimatedDuration = durationSec != null && durationSec > 0
          ? durationSec
          : bitrateMbps != null && bitrateMbps > 0
          ? fileSizeBytes * 8 / (bitrateMbps * 1000000)
          : null;
      // 普通 120s 会先于字节上限停止预取，因此全量缓存必须同时解除
      // 时间限制。已知时长时只覆盖完整时长；未知时使用 mpv 的大上限。
      cacheSecs = estimatedDuration == null
          ? fullCacheFallbackSecs
          : estimatedDuration.ceil() + 30;
    }

    // ── 缓存字节上限 ─────────────────────────────────────────
    // 码率已知：上限 = min(码率 × 目标秒数, 内存预算)——精确匹配
    // 「缓存时长 = 码率 × 时间」的经典模型；
    // 码率未知：上限 = 内存预算——mpv 的 `--cache-secs` 会按**实时码率**
    // 自适配目标时长所需的字节：低码率视频只填充到目标秒数所需大小，
    // 高码率大文件（如 4K REMUX）由预算封顶。相比固定假设码率
    // （如 8Mbps）对小文件场景正确、对大文件严重低估（7GB 视频只能
    // 缓存 114MiB 导致卡顿），这是更优的兜底策略。
    int demuxerMaxBytes;
    if (fullCache) {
      demuxerMaxBytes = fullCacheBytes;
    } else if (bitrateMbps != null && bitrateMbps.isFinite && bitrateMbps > 0) {
      // Cache Size = bitrate × buffer_time ÷ 8 × safety_factor
      // （文档第 8 节；bytes = Mbps × secs × 125000）。
      demuxerMaxBytes = estimateRequiredCacheBytes(
        cacheSecs: cacheSecs,
        bitrateMbps: bitrateMbps,
      )!.clamp(1, budget);
    } else {
      demuxerMaxBytes = budget;
    }
    layers.add(
      fullCache
          ? 'Small-file policy: ${(fileSizeBytes / (1024 * 1024)).round()}MiB <= threshold ${config.smallFileThresholdMB}MiB and <= budget -> full cache'
          : bitrateMbps != null
          ? 'Layer2 cache cap: ${bitrateMbps}Mbps x ${cacheSecs}s x safety factor $safetyFactor = ${(demuxerMaxBytes / (1024 * 1024)).round()}MiB'
          : 'Layer2 cache cap: bitrate unknown -> use memory budget ${(demuxerMaxBytes / (1024 * 1024)).round()}MiB',
    );

    // ── Health Score（诊断展示） ──────────────────────────
    final health = computeHealthScore(
      networkFactor: factor,
      cacheSecs: cacheSecs,
      availableMemoryBytes: availableMemoryBytes,
      demuxerMaxBytes: demuxerMaxBytes,
      bitrateMbps: bitrateMbps,
    );
    layers.add('Health Score: $health/100');

    // ── 生成 MPV 参数 ─────────────────────────────────────
    final args = <String>[
      '--cache=yes',
      '--cache-secs=$cacheSecs',
      '--demuxer-max-bytes=$demuxerMaxBytes',
      '--cache-pause=yes',
      '--cache-pause-initial=yes',
      '--cache-pause-wait=$initialBufferWaitSecs',
    ];

    return CachePolicyResult(
      skipped: false,
      cacheSecs: cacheSecs,
      demuxerMaxBytes: demuxerMaxBytes,
      memoryBudgetBytes: budget,
      minCacheSecs: CachePolicyConfig.minBaseCacheSecs,
      maxCacheSecs: fullCache ? cacheSecs : CachePolicyConfig.maxBaseCacheSecs,
      fullCache: fullCache,
      fileSizeBytes: fileSizeBytes,
      bitrateMbps: bitrateMbps,
      bitrateSource: bitrateSource,
      networkFactor: factor,
      healthScore: health,
      layers: layers,
      args: args,
    );
  }
}
