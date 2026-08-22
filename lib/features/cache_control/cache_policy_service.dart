import 'dart:async';

import 'engine/bitrate_estimator.dart';
import 'engine/cache_policy_engine.dart';
import 'intelligence/cache_intelligence_service.dart';
import 'models/cache_policy_config.dart';
import 'models/cache_policy_result.dart';
import 'models/cache_policy_session_state.dart';
import 'utils/container_rules.dart';
import 'models/media_metadata.dart';
import 'monitor/playback_monitor.dart';
import 'providers/media_probe.dart';
import 'providers/system_memory_provider.dart';
import 'store/cache_policy_config_store.dart';
import 'store/media_metadata_store.dart';

/// 缓存策略提供者门面接口（播放链路唯一依赖的抽象）。
///
/// 契约：任何情况下都不抛出异常；应跳过（系统关闭、用户已手动配置
/// 缓存参数且未开启覆盖、探测失败降级）时返回空列表。
abstract class CachePolicyProvider {
  /// 生成应注入 mpv 的缓存参数列表。
  ///
  /// [url] 为播放起点媒体地址（HEAD 探测用）；[authHeader] 为完整认证
  /// 头值（如 `Basic xxx`）；[userArgs] 为播放器参数模板（用于判断
  /// 用户是否已手动配置缓存参数）。
  /// 计算并返回本次播放应注入的缓存参数。
  ///
  /// [sessionId] 用于记录本次会话的策略状态（见 [sessionState]），
  /// 集成方据此决定是否启动播放中监控；
  /// 契约：不抛出，任何异常返回空列表（不阻断播放）。
  Future<List<String>> buildCacheArgs({
    required String sessionId,
    required String url,
    String? authHeader,
    List<String> userArgs = const [],
    bool runtimeTs = false,
  });

  /// 码率就绪回调（携带 **sessionId**：同 URL 多会话并发时，各会话
  /// 只收到自己的更新，杜绝单值 URL 映射的串线）。
  ///
  /// 首次播放时不阻塞启动（预算兜底注入），mpv 打开后经
  /// [recordDuration] 上报时长、缓存模块重算平均码率后触发，携带
  /// **重新计算后**的完整策略；集成方可在 mpv 运行中通过 IPC 推送
  /// `demuxer-max-bytes` / `cache-secs`。无更新需求时保持 null。
  void Function(String sessionId, String url, CachePolicyResult result)?
  onPolicyReady;

  /// 上报媒体时长（秒）：由集成方在 mpv 打开后从状态文件/播放器
  /// 读取并回调，缓存模块据此计算**平均码率**（大小 ÷ 时长，默认
  /// 算法，无需 ffprobe）→ 写入元数据缓存 → 动态更新本次播放。
  /// 码率就绪时同步更新**对应会话**的监控基准（多会话隔离）。
  /// 契约：不抛出；内部异常全部静默。
  void recordDuration(
    String sessionId,
    String url,
    double durationSec, {
    String? resolution,
  });

  /// 启动播放中动态监控（第二阶段：内存压力/网络异常/卡顿记录）。
  ///
  /// 由集成方在播放器启动并注册会话后调用；[sessionId] 标识会话，
  /// 多会话各自独立监控（互不干扰；同会话重复启动自动替换）。
  /// [statusFilePath] 为 mpv 十三行状态文件路径，包含播放位置、缓冲、
  /// 缓存边界、网络速度与分辨率；旧版缺失字段按未知值降级。
  /// [initialDemuxerMaxBytes]/[initialCacheSecs] 为本次注入的策略初值，
  /// [bitrateMbps] 为决策码率；未知时使用保守的绝对速度阈值。
  /// [onAdjustment]/[onWarning] 由集成方提供（IPC 推送/用户提示）。
  /// 契约：不抛出；内部异常全部静默。
  void startMonitor({
    required String sessionId,
    required String url,
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
  });

  /// 停止指定会话的播放中动态监控（幂等；不影响其他会话）。
  void stopMonitor(String sessionId, {bool clearSession = false});

  /// 本次播放会话的策略状态（按 sessionId）；未启动过返回 null。
  ///
  /// 集成方用 [CachePolicySessionState.shouldMonitor] 判断是否启动
  /// 播放中监控（正常注入且非 TS 直链），不再依赖 URL 历史结果。
  CachePolicySessionState? sessionState(String sessionId);

  /// 运行态诊断快照（只读，问题排查用；不含敏感信息）。
  ///
  /// 返回结构：`activeSessions`（监控中的会话）、`monitorUrls`、
  /// `sessionStates`（各会话注入状态摘要）。
  Map<String, Object?> diagnosticsSnapshot();
}

/// 缓存策略服务（模块门面，模块对外唯一入口）。
///
/// 流程：读配置 → 判断是否跳过（关闭/用户已配置）→ HEAD 探测媒体
/// 大小 → 读取系统可用内存 → 四层引擎生成参数。
///
/// 容错：整个流程被最终防线包裹，任何异常都吞掉并返回空列表，
/// 保证播放链路零影响（增强层原则）。
///
/// 诊断：播放时通过 [logger] 输出 `[SPCacheSystem]` 前缀的结构化日志
/// （StreamPathCacheSystem 缩略；摘要、注入参数、动态保护调整），
/// 默认输出到控制台（print），便于在 `flutter run` 终端实时查看缓存策略。
class CachePolicyService implements CachePolicyProvider {
  /// 智能层不属于起播必要条件。超过该时间立即使用原策略，避免磁盘异常
  /// 或未来模型实现拖慢播放器启动。
  static const Duration intelligenceAdviceTimeout = Duration(milliseconds: 250);

  CachePolicyService({
    required CachePolicyConfigStore store,
    MediaProbe? mediaProbe,
    SystemMemoryProvider? memoryProvider,
    CachePolicyEngine? engine,
    MediaMetadataStore? metadataStore,
    BitrateEstimator? estimator,
    void Function(String message)? logger,
    PlaybackMonitor Function()? monitorFactory,
    CacheIntelligenceProvider? intelligence,
  }) : _store = store, // ignore: prefer_initializing_formals
       _mediaProbe = mediaProbe ?? HttpMediaProbe(),
       _memoryProvider = memoryProvider ?? platformMemoryProvider(),
       _engine = engine ?? const CachePolicyEngine(),
       _metadataStore = metadataStore, // ignore: prefer_initializing_formals
       _estimator = estimator ?? const BitrateEstimator(),
       _logger = logger ?? _defaultLogger,
       _monitorFactory = monitorFactory, // ignore: prefer_initializing_formals
       _intelligence = intelligence; // ignore: prefer_initializing_formals

  final CachePolicyConfigStore _store;
  final MediaProbe _mediaProbe;
  final SystemMemoryProvider _memoryProvider;
  final CachePolicyEngine _engine;
  final CacheIntelligenceProvider? _intelligence;

  /// 媒体元数据缓存（码率 Level 1/2/3 来源）；null 时不启用码率算法。
  final MediaMetadataStore? _metadataStore;

  /// 三级码率估算器（纯算法）。
  final BitrateEstimator _estimator;

  /// 诊断日志输出（默认控制台）。
  final void Function(String message) _logger;

  /// 后台码率探测完成后的回调（动态更新本次播放，见接口注释）。
  /// 码率就绪回调（携带 **sessionId**：同 URL 多会话并发时，各会话
  /// 只收到自己的更新，杜绝单值 URL 映射的串线）。
  @override
  void Function(String sessionId, String url, CachePolicyResult result)?
  onPolicyReady;

  /// 本次会话 HEAD 探测到的文件大小（按 url_hash 记录，供
  /// [recordDuration] 计算平均码率；播放链路内的轻量内存缓存）。
  final Map<String, int> _knownSizes = {};
  final Map<String, MediaProbeResult> _knownProbes = {};

  /// 时长异步回填必须沿用本会话原始配置与认证，不能在回调阶段退化为
  /// “无用户状态、无 Authorization”的另一条策略链。
  final Map<String, CachePolicyConfig> _sessionConfigs = {};
  final Map<String, String?> _sessionAuthHeaders = {};

  /// 默认日志输出：控制台（`flutter run` 终端可见）。
  // ignore: avoid_print — 诊断日志按用户要求直接输出到控制台。
  static void _defaultLogger(String message) => print(message);

  /// 输出一行 `[SPCacheSystem]` 前缀的诊断日志（StreamPathCacheSystem 缩略）。
  void _log(String message) {
    try {
      _logger('[SPCacheSystem] $message');
    } catch (_) {
      // 日志输出失败绝不影响策略计算。
    }
  }

  /// 字节数格式化（诊断展示用）。
  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GiB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MiB';
    }
    return '$bytes B';
  }

  String _formatTargetSummary(CachePolicyResult result) {
    if (result.fullCache) {
      return 'cache target=full-file, cache-secs=${result.cacheSecs}, '
          'byte-cap=${_formatBytes(result.demuxerMaxBytes)} '
          '(${result.demuxerMaxBytes}B)';
    }
    final reachable = _engine.estimateReachableCacheSecs(
      demuxerMaxBytes: result.demuxerMaxBytes,
      bitrateMbps: result.bitrateMbps,
    );
    final required = _engine.estimateRequiredCacheBytes(
      cacheSecs: result.cacheSecs,
      bitrateMbps: result.bitrateMbps,
    );
    if (reachable == null || required == null) {
      return 'cache target requested=${result.cacheSecs}s, '
          'estimated-reachable=unknown (bitrate unknown), '
          'byte-cap=${_formatBytes(result.demuxerMaxBytes)} '
          '(${result.demuxerMaxBytes}B)';
    }
    final effective = reachable < result.cacheSecs
        ? reachable
        : result.cacheSecs;
    final limited = reachable < result.cacheSecs;
    return 'cache target requested=${result.cacheSecs}s, '
        'estimated-reachable=${effective}s, '
        'byte-cap=${_formatBytes(result.demuxerMaxBytes)} '
        '(${result.demuxerMaxBytes}B)'
        '${limited ? ', required=${_formatBytes(required)} (byte-cap limited)' : ''}';
  }

  /// 用户模板缓存参数族（结构化匹配**参数名**，不扫描参数值）：
  /// `--cache*` / `--demuxer-max-*` / `--demuxer-readahead-*` /
  /// `--demuxer-seekable-cache`。
  static final List<String> _cacheArgPrefixes = const [
    '--cache',
    '--demuxer-max-',
    '--demuxer-readahead-',
    '--demuxer-seekable-cache',
  ];

  /// 用户模板是否已包含缓存参数（仅匹配 `--` 开头的选项名；
  /// 参数值中出现缓存字样不会误判，嵌套值中的选项不误匹配）。
  static bool _hasUserCacheArgs(List<String> userArgs) {
    for (final arg in userArgs) {
      final trimmed = arg.trim();
      if (!trimmed.startsWith('--')) continue;
      final eq = trimmed.indexOf('=');
      var name = eq >= 0 ? trimmed.substring(0, eq) : trimmed;
      if (name.startsWith('--no-')) {
        name = '--${name.substring('--no-'.length)}';
      }
      for (final prefix in _cacheArgPrefixes) {
        if (name == prefix || name.startsWith(prefix)) return true;
      }
    }
    return false;
  }

  /// TS 类容器（m2ts/ts）：时长信息分布在数据流中，duration 探测需
  /// 读取大量数据（甚至整个文件）。跳过 HEAD/ffprobe 探测并注入
  /// `--demuxer-seekable-cache=no`（禁止 lavf 对缓存 seek 探测 duration，
  /// 打开时间回到直链水平；实测直链 5s vs 注入大缓存上限后 18s）。
  @override
  Future<List<String>> buildCacheArgs({
    required String sessionId,
    required String url,
    String? authHeader,
    List<String> userArgs = const [],
    bool runtimeTs = false,
  }) async {
    try {
      final config = await _store.load();
      _sessionConfigs[sessionId] = config;
      _sessionAuthHeaders[sessionId] = authHeader;
      if (!config.enabled) {
        _log('Cache system disabled (enabled=false)');
        _sessionStates[sessionId] = CachePolicySessionState(
          sessionId: sessionId,
          url: url,
          injected: false,
        );
        _recordSessionState(_sessionStates[sessionId]!);
        return const [];
      }
      // 用户已在播放器模板中手动配置缓存参数：尊重手动配置，跳过
      // 注入（除非显式开启 overrideUserCacheArgs 覆盖）。
      if (_hasUserCacheArgs(userArgs) && !config.overrideUserCacheArgs) {
        _log('Player template already has cache args; skipping injection');
        _sessionStates[sessionId] = CachePolicySessionState(
          sessionId: sessionId,
          url: url,
          injected: false,
        );
        _recordSessionState(_sessionStates[sessionId]!);
        return const [];
      }
      final isTsContainer = isTsContainerUrl(url);
      if (isTsContainer) {
        if (runtimeTs) {
          final memory = await _memoryProvider.availableMemoryBytes();
          final result = _engine.buildTsRuntimePolicy(
            config: config,
            availableMemoryBytes: memory,
          );
          final state = CachePolicySessionState(
            sessionId: sessionId,
            url: url,
            injected: true,
            result: result,
          );
          _sessionStates[sessionId] = state;
          _recordSessionState(state);
          _log(
            'TS runtime cache enabled after stable playback: ${result.args.join(' ')}',
          );
          return result.args;
        }
        // TS 容器：完全不注入缓存参数（等同直链环境，起播最快）。
        // 注入缓存目标（--cache-secs）会让 mpv 全力预取整个文件，
        // 与打开读取竞争服务器连接，实测起播被拖慢 7s（直链 5s →
        // 注入后 12s）；仅保留 --demuxer-seekable-cache=no 防御
        // lavf 为探测 duration 读取大量数据。
        const tsArgs = ['--cache=no', '--demuxer-seekable-cache=no'];
        _log('TS startup phase: cache disabled; seekable cache disabled');
        _sessionStates[sessionId] = CachePolicySessionState(
          sessionId: sessionId,
          url: url,
          injected: true,
          tsOnly: true,
        );
        _recordSessionState(_sessionStates[sessionId]!);
        return tsArgs;
      }
      final result = await buildPolicy(
        url: url,
        authHeader: authHeader,
        config: config,
      );
      if (result.skipped) {
        _log('Skipped: policy result is skipped');
        _sessionStates[sessionId] = CachePolicySessionState(
          sessionId: sessionId,
          url: url,
          injected: false,
        );
        _recordSessionState(_sessionStates[sessionId]!);
        return const [];
      }
      // 精简摘要：一行输入决策 + 一行最终参数。
      final sizeText = result.fileSizeBytes != null
          ? _formatBytes(result.fileSizeBytes!)
          : 'size unknown';
      final bitrateText = result.bitrateMbps != null && result.bitrateMbps! > 0
          ? 'bitrate ${result.bitrateMbps!.toStringAsFixed(1)}Mbps'
                ' (${result.bitrateSource ?? 'known'})'
          : 'bitrate unknown';
      final policyText = _formatTargetSummary(result);
      _log('Cache: $sizeText | $bitrateText -> $policyText');
      _log('Injected: ${result.args.join(' ')}');
      _sessionStates[sessionId] = CachePolicySessionState(
        sessionId: sessionId,
        url: url,
        injected: true,
        result: result,
      );
      _recordSessionState(_sessionStates[sessionId]!);
      return result.args;
    } catch (e) {
      // 最终防线：增强层异常绝不向播放链路传播。
      _log('Degraded: $e (skip injection, playback unaffected)');
      _sessionStates[sessionId] = CachePolicySessionState(
        sessionId: sessionId,
        url: url,
        injected: false,
      );
      _recordSessionState(_sessionStates[sessionId]!);
      return const [];
    }
  }

  /// 完整策略计算（供测试与诊断；[buildCacheArgs] 内部复用）。
  ///
  /// [knownFileSizeBytes]：已知文件大小（如元数据），避免 HEAD 探测；
  /// [bitrateMbps]/[tier]：显式码率/档位（显式码率优先级最高，其次
  /// 按设计文档三级降级：metadata bit_rate → 大小÷时长 → 分辨率估算）。
  Future<CachePolicyResult> buildPolicy({
    required String url,
    String? authHeader,
    CachePolicyConfig? config,
    int? knownFileSizeBytes,
    double? bitrateMbps,
    MediaTier? tier,
    String? resolution,
    double? durationSec,
  }) async {
    final cfg = config ?? await _store.load();
    int? size = knownFileSizeBytes;
    MediaProbeResult? currentProbe;
    if (size == null) {
      final probe = await _mediaProbe.probeContentLength(
        url: url,
        authHeader: authHeader,
      );
      currentProbe = probe;
      size = probe.ok ? probe.contentLengthBytes : null;
    }
    final hash = MediaMetadataStore.urlHashOf(url);
    currentProbe ??= _knownProbes[hash];
    if (size != null) {
      // 记录本次探测的大小，供 [recordDuration] 计算平均码率。
      // 上限保护：超过 200 条清空重建（播放会话有限，防长期累积）。
      if (_knownSizes.length >= 200) {
        _knownSizes.clear();
        _knownProbes.clear();
      }
      _knownSizes[hash] = size;
      if (currentProbe != null) _knownProbes[hash] = currentProbe;
    }

    // ── 码率获取（设计文档三级策略，**逐级推进、命中即止**） ──
    // 优先级（文档第 10 节推荐）：Level 2 平均码率（大小÷时长）优先
    // ——性能开销最低、涵盖视频+音频+容器、适合大量媒体库；
    // 行不通再逐级尝试 Level 1（metadata bit_rate）→ Level 3（分辨率）。
    // 显式 bitrateMbps（测试/未来直供）优先级最高。
    double? effectiveBitrate = bitrateMbps;
    String? bitrateSource = bitrateMbps != null ? 'explicit' : null;
    MediaMetadata? meta;
    // 当前播放刚上报的 duration 与本次探测 size 是最新且同一会话的
    // Level 2 证据，优先于磁盘旧 metadata。这样即使 duration 恰好在
    // 首次 HEAD 完成前到达，随后补探测到大小也能立即算出平均码率。
    if (effectiveBitrate == null && durationSec != null) {
      effectiveBitrate = _estimator.estimateFromSizeAndDuration(
        fileSizeBytes: size,
        durationSec: durationSec,
      );
      if (effectiveBitrate != null) bitrateSource = 'Level2 avg bitrate';
    }
    if (effectiveBitrate == null && _metadataStore != null) {
      meta = await _metadataStore.read(hash);
      final validatorMatches = meta == null || currentProbe == null
          ? true
          : (meta.etag == null ||
                    currentProbe.etag == null ||
                    meta.etag == currentProbe.etag) &&
                (meta.lastModified == null ||
                    currentProbe.lastModified == null ||
                    meta.lastModified == currentProbe.lastModified);
      final metaUsable =
          meta != null &&
          // 当前大小已知：只接受**精确匹配**（旧大小为空说明首次 HEAD
          // 失败时写入的，可能已跨文件替换，不得当作已验证数据）；
          // 当前大小未知：要求旧大小也为空（大小不可比时保守采用）。
          (size == null ? meta.fileSize == null : meta.fileSize == size) &&
          validatorMatches;
      if (metaUsable) {
        // Level 2（优先）：平均码率 = 大小 × 8 ÷ 时长。
        effectiveBitrate = _estimator.estimateFromSizeAndDuration(
          fileSizeBytes: size ?? meta.fileSize,
          durationSec: meta.durationSec,
        );
        if (effectiveBitrate != null) {
          bitrateSource = 'Level2 avg bitrate';
        } else {
          // Level 1：metadata bit_rate（ffprobe format.bit_rate）。
          effectiveBitrate = _estimator.estimateFromBitrateBps(meta.bitrateBps);
          if (effectiveBitrate != null) {
            bitrateSource = 'Level1 metadata bit_rate';
          } else {
            // Level 3：分辨率估算。
            effectiveBitrate = _estimator.estimateFromResolution(
              meta.resolution,
            );
            if (effectiveBitrate != null) {
              bitrateSource = 'Level3 resolution estimate';
            }
          }
        }
      }
    }
    var effectiveConfig = cfg;
    final intelligence = _intelligence;
    if (intelligence != null) {
      try {
        final advice = await intelligence
            .advise(
              url: url,
              baseCacheSecs: cfg.baseCacheSecs,
              fileSizeBytes: size,
              currentBitrateMbps: effectiveBitrate,
              resolution: resolution ?? meta?.resolution,
            )
            .timeout(intelligenceAdviceTimeout);
        if (advice.enabled) {
          final mode = advice.applyOptimizations ? 'applied' : 'shadow';
          final prediction = advice.predictedBitrateMbps;
          _log(
            'Intelligence: mode=$mode, storage=${advice.storageType.jsonValue}, '
            'base=${cfg.baseCacheSecs}s, suggested=${advice.suggestedBaseCacheSecs}s, '
            'confidence=${advice.confidence.toStringAsFixed(2)}, '
            'predicted-bitrate=${prediction?.toStringAsFixed(1) ?? 'none'}Mbps, '
            'reasons=${advice.reasonCodes.join('+')}',
          );
          if (advice.applyOptimizations) {
            effectiveConfig = cfg.copyWith(
              baseCacheSecs: advice.suggestedBaseCacheSecs,
            );
            if (effectiveBitrate == null &&
                prediction != null &&
                prediction > 0) {
              effectiveBitrate = prediction;
              bitrateSource = 'Level4 history prediction';
            }
          }
        }
      } catch (e) {
        _log('Intelligence degraded: $e (original policy retained)');
      }
    }

    final memory = await _memoryProvider.availableMemoryBytes();
    return _engine.buildPolicy(
      config: effectiveConfig,
      fileSizeBytes: size,
      bitrateMbps: effectiveBitrate,
      bitrateSource: bitrateSource,
      tier: tier,
      resolution: resolution ?? meta?.resolution,
      durationSec: durationSec ?? meta?.durationSec,
      availableMemoryBytes: memory,
    );
  }

  /// 上报媒体时长：写入元数据缓存 → 重算平均码率 → 动态更新本次播放。
  ///
  /// 由集成方在 mpv 打开后从状态文件读取 duration 并调用（默认码率
  /// 算法 = 平均码率 = 大小 ÷ 时长，无需 ffprobe，零额外读取成本）。
  /// [sessionId] 用于把码率基准更新路由到对应会话的监控（多会话隔离）。
  @override
  void recordDuration(
    String sessionId,
    String url,
    double durationSec, {
    String? resolution,
  }) {
    if (!durationSec.isFinite || durationSec <= 0) return;
    final expectedState = _sessionStates[sessionId];
    // 手动参数、配置关闭和 TS 启动直链分支不得触发自动策略回写。
    // 对象身份还能防止同 sessionId、同 URL 快速重启形成 ABA。
    if (expectedState == null ||
        !expectedState.shouldMonitor ||
        !_sameUrl(expectedState.url, url)) {
      return;
    }
    final config = _sessionConfigs[sessionId];
    final authHeader = _sessionAuthHeaders[sessionId];
    unawaited(
      _recordDurationAsync(
        sessionId,
        url,
        durationSec,
        expectedState,
        config: config,
        authHeader: authHeader,
        resolution: resolution,
      ),
    );
  }

  Future<void> _recordDurationAsync(
    String sessionId,
    String url,
    double durationSec,
    CachePolicySessionState expectedState, {
    required CachePolicyConfig? config,
    required String? authHeader,
    String? resolution,
  }) async {
    try {
      final store = _metadataStore;
      if (store == null) return;
      final hash = MediaMetadataStore.urlHashOf(url);
      final existing = await store.read(hash);
      if (!identical(_sessionStates[sessionId], expectedState)) return;
      // 文件替换失效判定：本次探测大小与已存大小不一致 → 文件已变更，
      // 旧时长/旧码率不再适用，必须重建（保留仍然有效的分辨率）。
      // 当前大小已知时要求**精确匹配**：旧大小为空（首次 HEAD 失败
      // 写入）不得视为同一文件——已可能跨文件替换，需重写补全大小。
      // 当前大小**未知**（本次 HEAD 失败）：无法比较，视为同一文件，
      // 保留已验证数据（避免把旧大小/码率一并清空的误伤）。
      final currentSize = _knownSizes[hash];
      final probe = _knownProbes[hash];
      final sameValidator = existing == null || probe == null
          ? true
          : (existing.etag == null ||
                    probe.etag == null ||
                    existing.etag == probe.etag) &&
                (existing.lastModified == null ||
                    probe.lastModified == null ||
                    existing.lastModified == probe.lastModified);
      final sameFile = currentSize == null
          ? true
          : existing?.fileSize == currentSize && sameValidator;
      final resolutionChanged =
          resolution != null &&
          resolution.isNotEmpty &&
          resolution != existing?.resolution;
      final durationUnchanged =
          existing?.durationSec != null &&
          (existing!.durationSec! - durationSec).abs() <= 0.5;
      if (existing != null &&
          existing.hasDuration &&
          sameFile &&
          durationUnchanged &&
          !resolutionChanged) {
        return;
      }
      // 重算策略（Level 2 平均码率命中）→ 通知集成方动态更新本次播放。
      final updated = await buildPolicy(
        url: url,
        authHeader: authHeader,
        config: config,
        knownFileSizeBytes: currentSize ?? existing?.fileSize,
        resolution: resolution ?? existing?.resolution,
        durationSec: durationSec,
      );
      if (updated.skipped) return;
      // 只允许仍属于本次 buildCacheArgs 的策略状态产生运行态副作用。
      if (!identical(_sessionStates[sessionId], expectedState)) return;
      final effectiveSize =
          updated.fileSizeBytes ?? currentSize ?? existing?.fileSize;
      final refreshedProbe = _knownProbes[hash] ?? probe;
      final effectiveValidatorMatches =
          existing == null ||
          refreshedProbe == null ||
          ((existing.etag == null ||
                  refreshedProbe.etag == null ||
                  existing.etag == refreshedProbe.etag) &&
              (existing.lastModified == null ||
                  refreshedProbe.lastModified == null ||
                  existing.lastModified == refreshedProbe.lastModified));
      final strongValidatorMatch =
          existing != null &&
          refreshedProbe != null &&
          ((existing.etag != null &&
                  refreshedProbe.etag != null &&
                  existing.etag == refreshedProbe.etag) ||
              (existing.lastModified != null &&
                  refreshedProbe.lastModified != null &&
                  existing.lastModified == refreshedProbe.lastModified));
      final effectiveSameFile = effectiveSize == null
          ? true
          : existing?.fileSize == effectiveSize &&
                effectiveValidatorMatches &&
                (durationUnchanged || strongValidatorMatch);
      await store.write(
        MediaMetadata(
          urlHash: hash,
          fileSize: effectiveSize,
          durationSec: durationSec,
          // 文件已替换：旧文件的码率、分辨率与验证器都不再适用。
          bitrateBps: effectiveSameFile ? existing?.bitrateBps : null,
          resolution:
              resolution ?? (effectiveSameFile ? existing?.resolution : null),
          etag:
              refreshedProbe?.etag ??
              (effectiveSameFile ? existing?.etag : null),
          lastModified:
              refreshedProbe?.lastModified ??
              (effectiveSameFile ? existing?.lastModified : null),
          durationSource: 'mpv',
          bitrateSource: 'average',
          updatedAt: DateTime.now(),
        ),
      );
      final learnedBitrate = updated.bitrateMbps;
      final intelligence = _intelligence;
      if (intelligence != null &&
          learnedBitrate != null &&
          learnedBitrate > 0 &&
          updated.bitrateSource == 'Level2 avg bitrate') {
        unawaited(
          intelligence.observeBitrate(
            url: url,
            bitrateMbps: learnedBitrate,
            fileSizeBytes: effectiveSize,
            resolution: resolution ?? existing?.resolution,
          ),
        );
      }
      if (!identical(_sessionStates[sessionId], expectedState)) return;
      final refreshedState = CachePolicySessionState(
        sessionId: sessionId,
        url: url,
        injected: true,
        result: updated,
      );
      _sessionStates[sessionId] = refreshedState;
      _recordSessionState(refreshedState);
      // 码率就绪：同步给**本会话**的播放中监控（从绝对阈值兜底切换
      // 到相对码率判定）；其他会话不受影响。
      _monitors[sessionId]?.updatePolicy(
        demuxerMaxBytes: updated.demuxerMaxBytes,
        cacheSecs: updated.cacheSecs,
        memoryBudgetBytes: updated.memoryBudgetBytes,
        minCacheSecs: updated.minCacheSecs,
        maxCacheSecs: updated.maxCacheSecs,
        fullCache: updated.fullCache,
        fileSizeBytes: updated.fileSizeBytes,
        bitrateMbps: updated.bitrateMbps,
      );
      _log(
        'Bitrate updated: '
        '${updated.bitrateMbps != null && updated.bitrateMbps! > 0 ? '${updated.bitrateMbps!.toStringAsFixed(1)}Mbps | ' : ''}'
        '${_formatTargetSummary(updated)} | policy ready for IPC',
      );
      onPolicyReady?.call(sessionId, url, updated);
    } catch (_) {
      // 增强层：上报失败静默，不影响播放。
    }
  }

  // ── 播放中动态监控（第二阶段：内存压力/网络异常/卡顿记录） ──

  /// 监控工厂（测试注入：每会话一个实例；null 时用真实实现）。
  final PlaybackMonitor Function()? _monitorFactory;

  /// 本次播放会话的策略状态（按 sessionId；见 [CachePolicySessionState]）。
  final Map<String, CachePolicySessionState> _sessionStates = {};

  /// 播放中动态监控（按会话隔离；null 表示未启动）。
  final Map<String, PlaybackMonitor> _monitors = {};

  /// 各会话监控对应的曲目 URL（会话 → url，诊断用）。
  final Map<String, String> _monitorUrls = {};

  static bool _sameUrl(String a, String b) {
    if (a == b) return true;
    try {
      return Uri.decodeFull(a) == Uri.decodeFull(b);
    } catch (_) {
      return false;
    }
  }

  /// [_sessionStates] 容量上限（超出淘汰最久未用的会话条目）。
  static const int _sessionStatesLimit = 200;

  @override
  CachePolicySessionState? sessionState(String sessionId) {
    final value = _sessionStates.remove(sessionId);
    if (value != null) _sessionStates[sessionId] = value; // 移到末尾（LRU）。
    return value;
  }

  @override
  Map<String, Object?> diagnosticsSnapshot() => <String, Object?>{
    'activeSessions': _monitors.keys.toList(),
    'monitorUrls': {
      for (final sid in _monitors.keys) sid: _redactUrl(_monitorUrls[sid]),
    },
    'sessionStates': _sessionStates.map(
      (sessionId, state) => MapEntry(sessionId, <String, Object?>{
        // URL 脱敏：仅保留 scheme://host/path，去掉 query（可能
        // 含签名 token 等敏感参数）与凭据。
        'url': _redactUrl(state.url),
        'injected': state.injected,
        'tsOnly': state.tsOnly,
        if (state.result != null) ...<String, Object?>{
          'maxBytes': state.result!.demuxerMaxBytes,
          'cacheSecs': state.result!.cacheSecs,
          'bitrateMbps': state.result!.bitrateMbps,
          'fullCache': state.result!.fullCache,
        },
      }),
    ),
  };

  /// 诊断用 URL 脱敏：仅保留 `scheme://host[:port]/path`，
  /// 去掉 query/fragment（可能含签名 token）与 userinfo 凭据。
  static String _redactUrl(String? value) {
    if (value == null) return '';
    final uri = Uri.tryParse(value);
    if (uri == null) return '<unparseable>';
    final buffer = StringBuffer()
      ..write(uri.scheme)
      ..write('://')
      ..write(uri.host);
    if (uri.hasPort) {
      buffer
        ..write(':')
        ..write(uri.port);
    }
    buffer.write(uri.path.isEmpty ? '/' : uri.path);
    return buffer.toString();
  }

  @override
  void startMonitor({
    required String sessionId,
    required String url,
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
    try {
      // 同会话重复启动：先停止该会话旧实例；其他会话不受影响。
      final previous = _monitors.remove(sessionId);
      final previousUrl = _monitorUrls.remove(sessionId);
      _learnFromMonitor(previousUrl, previous);
      previous?.stop();
      final monitor =
          _monitorFactory?.call() ??
          PlaybackMonitor(
            memoryProvider: _memoryProvider,
            logger: (message) => _log(message),
          );
      _monitors[sessionId] = monitor;
      _monitorUrls[sessionId] = url;
      monitor.start(
        statusFilePath: statusFilePath,
        initialDemuxerMaxBytes: initialDemuxerMaxBytes,
        initialCacheSecs: initialCacheSecs,
        fileSizeBytes: fileSizeBytes,
        bitrateMbps: bitrateMbps,
        memoryBudgetBytes: memoryBudgetBytes,
        minCacheSecs: minCacheSecs,
        maxCacheSecs: maxCacheSecs,
        fullCache: fullCache,
        onAdjustment: onAdjustment,
        onWarning: onWarning,
      );
      _rebalanceMonitors();
    } catch (_) {
      // 增强层：监控启动失败静默，不影响播放。
    }
  }

  @override
  void stopMonitor(String sessionId, {bool clearSession = false}) {
    final monitor = _monitors.remove(sessionId);
    final url = _monitorUrls.remove(sessionId);
    _learnFromMonitor(url, monitor);
    monitor?.stop();
    if (clearSession) {
      _sessionStates.remove(sessionId);
      _sessionConfigs.remove(sessionId);
      _sessionAuthHeaders.remove(sessionId);
    }
    _rebalanceMonitors();
  }

  void _learnFromMonitor(String? url, PlaybackMonitor? monitor) {
    final intelligence = _intelligence;
    if (url == null || monitor == null || intelligence == null) return;
    final outcome = monitor.snapshotOutcome();
    if (!outcome.hasUsefulSamples) return;
    unawaited(intelligence.observeSession(url: url, outcome: outcome));
  }

  void _rebalanceMonitors() {
    final count = _monitors.length;
    for (final monitor in _monitors.values) {
      monitor.updateActiveSessionCount(count);
    }
  }

  /// 清空本次进程内的策略结果、媒体探测和会话状态。
  ///
  /// 设置页只会在播放器全部退出后调用，因此这里直接停止残留监控，
  /// 不再把旧会话样本写回刚清空的学习数据。
  void clearRuntimeCache() {
    for (final monitor in _monitors.values) {
      monitor.stop();
    }
    _monitors.clear();
    _monitorUrls.clear();
    _knownSizes.clear();
    _knownProbes.clear();
    _sessionStates.clear();
    _sessionConfigs.clear();
    _sessionAuthHeaders.clear();
  }

  /// 记录会话策略状态（LRU 上限：超出淘汰最久未用的会话条目）。
  void _recordSessionState(CachePolicySessionState state) {
    _sessionStates[state.sessionId] = state;
    if (_sessionStates.length > _sessionStatesLimit) {
      final evicted = _sessionStates.keys.first;
      _sessionStates.remove(evicted);
      _sessionConfigs.remove(evicted);
      _sessionAuthHeaders.remove(evicted);
    }
  }
}
