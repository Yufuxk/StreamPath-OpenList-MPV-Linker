import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'core/utils/app_paths.dart';
import 'core/utils/clipboard_history_fix.dart';
import 'data/local/stream_path_config_store.dart';
import 'data/local/directory_cache.dart';
import 'data/local/playback_history_store.dart';
import 'data/local/playback_progress_db.dart';
import 'features/cache_control/cache_policy_service.dart';
import 'features/cache_control/intelligence/cache_intelligence_service.dart';
import 'features/cache_control/store/cache_intelligence_config_store.dart';
import 'features/cache_control/store/cache_intelligence_learning_store.dart';
import 'features/cache_control/store/cache_policy_config_store.dart';
import 'features/cache_control/store/media_metadata_store.dart';
import 'presentation/pages/auto_connect_gate.dart';
import 'presentation/pages/home_page.dart';
import 'presentation/state/app_state.dart';

/// StreamPath 应用入口。
///
/// 先迁移数据布局，再并行初始化缓存、进度、配置和历史，最后进入 UI。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 数据迁移必须早于任何日志或数据库写入。
  await AppPaths.migrateLegacyLayout();
  final clipboardInstall = ClipboardHistoryFix.install();

  // 目录缓存与配置均位于便携数据目录。
  final directories = await Future.wait([
    AppPaths.cacheDirectory(),
    AppPaths.configDirectory(),
  ]);
  final cacheDir = directories[0];
  final configDir = directories[1];
  Hive.init(cacheDir.path);
  final directoryCache = DirectoryCache();

  // 互不依赖的本地存储并行初始化。
  final directoryCacheInit = directoryCache.init();
  final progressServiceFuture = PlaybackProgressService.create();
  final configStoreFuture = StreamPathConfigStore.create().then((store) async {
    await store.loadForStartup();
    return store;
  });
  final playbackHistoryStoreFuture = PlaybackHistoryStore.create();

  await directoryCacheInit;
  final progressService = await progressServiceFuture;
  final configStore = await configStoreFuture;
  final playbackHistoryStore = await playbackHistoryStoreFuture;
  await clipboardInstall;

  // 缓存策略是独立增强层，初始化失败不得改变基础播放链路。
  final cachePolicyStore = CachePolicyConfigStore.forPath(
    p.join(configDir.path, CachePolicyConfigStore.configFileName),
  );
  final cacheIntelligenceStore = CacheIntelligenceConfigStore.forPath(
    p.join(configDir.path, CacheIntelligenceConfigStore.configFileName),
  );
  await Future.wait<void>([
    cachePolicyStore.ensureDefault(),
    cacheIntelligenceStore.ensureDefault(),
  ]);
  final cacheIntelligence = LocalCacheIntelligenceService(
    configStore: cacheIntelligenceStore,
    learningStore: CacheIntelligenceLearningStore.forPath(
      p.join(cacheDir.path, CacheIntelligenceLearningStore.fileName),
    ),
  );
  final cachePolicy = CachePolicyService(
    store: cachePolicyStore,
    metadataStore: MediaMetadataStore.forPath(
      p.join(cacheDir.path, MediaMetadataStore.fileName),
    ),
    intelligence: cacheIntelligence,
  );

  // 组装 WebDAV、播放器、缓存与界面状态。
  final appState = AppState(
    configStore: configStore,
    playbackHistoryStore: playbackHistoryStore,
    progressService: progressService,
    directoryCache: directoryCache,
    cachePolicy: cachePolicy,
    cachePolicyConfigStore: cachePolicyStore,
    cacheIntelligenceConfigStore: cacheIntelligenceStore,
  );

  // 地址与用户名完整时直接尝试自动连接，密码允许为空。
  final autoConnect = configStore.current.isConnectionComplete;
  runApp(StreamPathApp(appState: appState, autoConnect: autoConnect));
}

/// 应用根组件：注入全局状态 + 主题。
class StreamPathApp extends StatelessWidget {
  const StreamPathApp({
    super.key,
    required this.appState,
    required this.autoConnect,
  });

  final AppState appState;

  /// 是否跳过登录页并自动尝试连接。
  final bool autoConnect;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: appState,
      child: MaterialApp(
        title: 'StreamPath — WebDAV 浏览器',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF1565C0),
          brightness: Brightness.light,
        ),
        darkTheme: ThemeData(
          colorSchemeSeed: const Color(0xFF1565C0),
          brightness: Brightness.dark,
        ),
        home: autoConnect ? const AutoConnectGate() : const HomePage(),
      ),
    );
  }
}
