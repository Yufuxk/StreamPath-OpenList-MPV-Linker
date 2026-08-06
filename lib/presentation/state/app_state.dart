import 'package:flutter/foundation.dart';

import '../../data/local/playback_history_store.dart';
import '../../data/local/stream_path_config_store.dart';
import '../../data/local/directory_cache.dart';
import '../../data/local/playback_progress_db.dart';
import '../../data/remote/webdav_client.dart';
import '../../domain/services/external_player_service.dart';
import '../../domain/services/subtitle_matcher.dart';
import '../../domain/services/webdav_service.dart';

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
  })  : _configStore = configStore,
        // ignore: prefer_initializing_formals
        _playbackHistoryStore = playbackHistoryStore,
        _progressService = progressService,
        _directoryCache = directoryCache ?? DirectoryCache(),
        _playerService = playerService ??
            ExternalPlayerService(
              configStore: configStore,
              progressService: progressService,
            ),
        _subtitleMatcher = subtitleMatcher ?? const SubtitleMatcher();

  final StreamPathConfigStore _configStore;
  final PlaybackHistoryStore _playbackHistoryStore;
  final PlaybackProgressService _progressService;
  final DirectoryCache _directoryCache;
  final ExternalPlayerService _playerService;
  final SubtitleMatcher _subtitleMatcher;

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

  StreamPathConfigStore get configStore => _configStore;
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

    // 连接验证：请求根目录，失败即认证/网络问题。
    await service.fetchDirectory('');

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
