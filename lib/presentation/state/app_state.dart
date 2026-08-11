import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/local/playback_history_store.dart';
import '../../data/local/stream_path_config_store.dart';
import '../../data/local/directory_cache.dart';
import '../../data/local/playback_progress_db.dart';
import '../../data/remote/webdav_client.dart';
import '../../domain/services/external_player_service.dart';
import '../../domain/services/subtitle_matcher.dart';
import '../../domain/services/webdav_service.dart';
import '../../features/cache_control/cache_policy_service.dart';
import '../../features/cache_control/store/cache_intelligence_config_store.dart';
import '../../features/cache_control/store/cache_policy_config_store.dart';

/// 应用全局状态（provider 单例）。
///
/// 持有所有核心服务实例与当前连接信息；页面通过
/// `context.read<AppState>()` 获取，通过 [ChangeNotifier] 感知变化。
class AppState extends ChangeNotifier {
  AppState({
    required StreamPathConfigStore configStore,
    required PlaybackHistoryStore playbackHistoryStore,
    required PlaybackProgressService progressService,
    DirectoryCache? directoryCache,
    ExternalPlayerService? playerService,
    SubtitleMatcher? subtitleMatcher,
    CachePolicyProvider? cachePolicy,
    CachePolicyConfigStore? cachePolicyConfigStore,
    CacheIntelligenceConfigStore? cacheIntelligenceConfigStore,
  }) : _configStore = configStore,
       // ignore: prefer_initializing_formals
       _cachePolicyConfigStore = cachePolicyConfigStore,
       // ignore: prefer_initializing_formals
       _cacheIntelligenceConfigStore = cacheIntelligenceConfigStore,
       // ignore: prefer_initializing_formals
       _playbackHistoryStore = playbackHistoryStore,
       _progressService = progressService,
       _directoryCache = directoryCache ?? DirectoryCache(),
       _subtitleMatcher = subtitleMatcher ?? const SubtitleMatcher() {
    // 警告流与播放器服务的警告接线放构造器 body（initializer 中
    // 不能引用 this 字段）。
    _cacheWarnings = StreamController<String>.broadcast();
    _playbackRecoveryEvents =
        StreamController<PlaybackRecoveryEvent>.broadcast();
    _playerService =
        playerService ??
        ExternalPlayerService(
          configStore: configStore,
          progressService: progressService,
          cachePolicy: cachePolicy,
          onCacheWarning: (message) => _cacheWarnings.add(message),
          onPlaybackRecovery: (event) => _playbackRecoveryEvents.add(event),
        );
  }

  final StreamPathConfigStore _configStore;
  final CachePolicyConfigStore? _cachePolicyConfigStore;
  final CacheIntelligenceConfigStore? _cacheIntelligenceConfigStore;
  final PlaybackHistoryStore _playbackHistoryStore;
  final PlaybackProgressService _progressService;
  final DirectoryCache _directoryCache;
  late final ExternalPlayerService _playerService;
  final SubtitleMatcher _subtitleMatcher;

  /// 播放中动态保护的用户警告（网络带宽持续不足等）；UI 订阅后
  /// 以 SnackBar 展示。
  late final StreamController<String> _cacheWarnings;
  late final StreamController<PlaybackRecoveryEvent> _playbackRecoveryEvents;

  /// 播放中动态保护警告流（如「网络带宽不足以流畅播放」）。
  Stream<String> get cacheWarnings => _cacheWarnings.stream;

  /// MPV 播放失败自动恢复状态（准备、重新启动或失败）。
  Stream<PlaybackRecoveryEvent> get playbackRecoveryEvents =>
      _playbackRecoveryEvents.stream;

  WebDAVService? _webDavService;
  String? _username;
  String? _password;

  // ── 对外访问 ─────────────────────────────────────────────────

  /// 当前 WebDAV 服务；未连接时为 null。
  WebDAVService? get webDavService => _webDavService;

  /// 已连接的用户名（显示用）。
  String? get username => _username;

  /// 已连接的密码（供外部播放器认证注入，仅内存持有）。
  String? get password => _password;

  @override
  void dispose() {
    _cacheWarnings.close();
    _playbackRecoveryEvents.close();
    super.dispose();
  }

  StreamPathConfigStore get configStore => _configStore;
  CachePolicyConfigStore? get cachePolicyConfigStore => _cachePolicyConfigStore;
  CacheIntelligenceConfigStore? get cacheIntelligenceConfigStore =>
      _cacheIntelligenceConfigStore;
  PlaybackHistoryStore get playbackHistoryStore => _playbackHistoryStore;
  PlaybackProgressService get progressService => _progressService;
  ExternalPlayerService get playerService => _playerService;
  SubtitleMatcher get subtitleMatcher => _subtitleMatcher;

  // ── 连接管理 ─────────────────────────────────────────────────

  /// 建立 WebDAV 连接：创建服务并验证（拉取根目录）。
  ///
  /// 验证失败（认证/网络等）时抛出 [AppException]，调用方负责提示。
  Future<void> connect({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    final client = WebDavClient(
      baseUrl: baseUrl,
      username: username,
      password: password,
    );
    // 复用全局缓存实例（main 中已 init），保证连接间缓存延续。
    final service = WebDAVService(client: client, cache: _directoryCache);

    // 登录必须真实访问服务器；旧账号的目录缓存不能充当认证结果。
    await service.verifyConnection();

    _webDavService = service;
    _username = username;
    _password = password;
    notifyListeners();
  }

  /// 断开连接并清空状态。
  void disconnect() {
    _webDavService = null;
    _username = null;
    _password = null;
    notifyListeners();
  }
}
