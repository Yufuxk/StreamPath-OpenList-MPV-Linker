import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/local/playback_history_store.dart';
import '../../data/local/audio_playback_history_store.dart';
import '../../data/local/stream_path_config_store.dart';
import '../../data/local/directory_cache.dart';
import '../../data/local/playback_progress_db.dart';
import '../../data/remote/webdav_client.dart';
import '../../domain/services/external_player_service.dart';
import '../../domain/services/audio_companion_matcher.dart';
import '../../domain/services/audio_player_service.dart';
import '../../domain/services/cache_cleanup_service.dart';
import '../../domain/services/subtitle_matcher.dart';
import '../../domain/services/webdav_service.dart';
import '../../features/cache_control/cache_policy_service.dart';
import '../../features/cache_control/store/cache_intelligence_config_store.dart';
import '../../features/cache_control/store/cache_policy_config_store.dart';
import '../../features/cache_expiration/store/cache_expiration_config_store.dart';

/// 应用全局状态（provider 单例）。
///
/// 持有所有核心服务实例与当前连接信息；页面通过
/// `context.read<AppState>()` 获取，通过 [ChangeNotifier] 感知变化。
class AppState extends ChangeNotifier {
  AppState({
    required StreamPathConfigStore configStore,
    required PlaybackHistoryStore playbackHistoryStore,
    required PlaybackProgressService progressService,
    AudioPlaybackHistoryStore? audioPlaybackHistoryStore,
    PlaybackProgressService? audioProgressService,
    DirectoryCache? directoryCache,
    ExternalPlayerService? playerService,
    AudioPlayerService? audioPlayerService,
    SubtitleMatcher? subtitleMatcher,
    CachePolicyProvider? cachePolicy,
    CachePolicyConfigStore? cachePolicyConfigStore,
    CacheIntelligenceConfigStore? cacheIntelligenceConfigStore,
    CacheExpirationConfigStore? cacheExpirationConfigStore,
    CacheCleaner? cacheCleaner,
    CacheCleaner? learningDataCleaner,
  }) : _configStore = configStore,
       // ignore: prefer_initializing_formals
       _cachePolicyConfigStore = cachePolicyConfigStore,
       // ignore: prefer_initializing_formals
       _cacheIntelligenceConfigStore = cacheIntelligenceConfigStore,
       // ignore: prefer_initializing_formals
       _cacheExpirationConfigStore = cacheExpirationConfigStore,
       // ignore: prefer_initializing_formals
       _playbackHistoryStore = playbackHistoryStore,
       _progressService = progressService,
       // ignore: prefer_initializing_formals
       _audioPlaybackHistoryStore = audioPlaybackHistoryStore,
       _audioProgressService = audioProgressService,
       _directoryCache = directoryCache ?? DirectoryCache(),
       // ignore: prefer_initializing_formals
       _cacheCleaner = cacheCleaner,
       // ignore: prefer_initializing_formals
       _learningDataCleaner = learningDataCleaner,
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
    _audioPlayerService =
        audioPlayerService ??
        (audioProgressService == null
            ? null
            : AudioPlayerService(
                configStore: configStore,
                progressService: audioProgressService,
              ));
  }

  final StreamPathConfigStore _configStore;
  final CachePolicyConfigStore? _cachePolicyConfigStore;
  final CacheIntelligenceConfigStore? _cacheIntelligenceConfigStore;
  final CacheExpirationConfigStore? _cacheExpirationConfigStore;
  final PlaybackHistoryStore _playbackHistoryStore;
  final PlaybackProgressService _progressService;
  final AudioPlaybackHistoryStore? _audioPlaybackHistoryStore;
  final PlaybackProgressService? _audioProgressService;
  final DirectoryCache _directoryCache;
  final CacheCleaner? _cacheCleaner;
  final CacheCleaner? _learningDataCleaner;
  late final ExternalPlayerService _playerService;
  late final AudioPlayerService? _audioPlayerService;
  final SubtitleMatcher _subtitleMatcher;
  final AudioCompanionMatcher _audioCompanionMatcher =
      const AudioCompanionMatcher();

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
  CacheExpirationConfigStore? get cacheExpirationConfigStore =>
      _cacheExpirationConfigStore;
  PlaybackHistoryStore get playbackHistoryStore => _playbackHistoryStore;
  PlaybackProgressService get progressService => _progressService;
  AudioPlaybackHistoryStore? get audioPlaybackHistoryStore =>
      _audioPlaybackHistoryStore;
  PlaybackProgressService? get audioProgressService => _audioProgressService;
  ExternalPlayerService get playerService => _playerService;
  AudioPlayerService? get audioPlayerService => _audioPlayerService;
  SubtitleMatcher get subtitleMatcher => _subtitleMatcher;
  AudioCompanionMatcher get audioCompanionMatcher => _audioCompanionMatcher;
  bool get canClearCache => _cacheCleaner != null;
  bool get canClearLearningData => _learningDataCleaner != null;

  /// 清空缓存前确认没有播放器进程仍在使用会话文件。
  Future<CacheCleanupResult> clearCache() async {
    final cleaner = _cacheCleaner;
    if (cleaner == null) {
      throw const CacheCleanupException('缓存清理服务尚未初始化');
    }
    if (await _hasRunningPlayback()) {
      throw const CacheCleanupBlockedException('请先关闭正在运行的播放器，再清理缓存');
    }
    await _releaseStoppedPlaybackSessions();
    final result = await cleaner.clear();
    notifyListeners();
    return result;
  }

  /// 只清空本地智能缓存的匿名聚合学习数据。
  Future<CacheCleanupResult> clearLearningData() async {
    final cleaner = _learningDataCleaner;
    if (cleaner == null) {
      throw const CacheCleanupException('学习数据清理服务尚未初始化');
    }
    if (await _hasRunningPlayback()) {
      throw const CacheCleanupBlockedException('请先关闭正在运行的播放器，再清理学习数据');
    }
    final result = await cleaner.clear();
    notifyListeners();
    return result;
  }

  Future<bool> _hasRunningPlayback() async {
    if (await _playerService.isPlayerRunning()) return true;
    final videoHistories = await _playbackHistoryStore.loadAll();
    for (final history in videoHistories) {
      await _playerService.restoreSession(
        sessionId: history.sessionId,
        pid: history.playerPid,
        ipcPipeName: history.ipcPipeName,
      );
      if (await _playerService.isPlayerRunning(history.sessionId)) return true;
    }

    final audioService = _audioPlayerService;
    final audioStore = _audioPlaybackHistoryStore;
    if (audioService == null || audioStore == null) return false;
    final audioHistories = await audioStore.loadAll();
    for (final history in audioHistories) {
      await audioService.restoreSession(
        sessionId: history.sessionId,
        pid: history.playerPid,
        ipcPipeName: history.ipcPipeName,
      );
      if (await audioService.isPlayerRunning(history.sessionId)) return true;
    }
    return false;
  }

  Future<void> _releaseStoppedPlaybackSessions() async {
    final videoHistories = await _playbackHistoryStore.loadAll();
    for (final history in videoHistories) {
      _playerService.releaseSession(history.sessionId);
    }
    final audioService = _audioPlayerService;
    final audioStore = _audioPlaybackHistoryStore;
    if (audioService == null || audioStore == null) return;
    final audioHistories = await audioStore.loadAll();
    for (final history in audioHistories) {
      audioService.releaseSession(history.sessionId);
    }
  }

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
