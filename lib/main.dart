import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'core/utils/app_paths.dart';
import 'core/utils/clipboard_history_fix.dart';
import 'data/local/stream_path_config_store.dart';
import 'data/local/directory_cache.dart';
import 'data/local/playback_history_store.dart';
import 'data/local/audio_playback_history_store.dart';
import 'data/local/playback_progress_db.dart';
import 'data/local/media_library_store.dart';
import 'data/models/app_language.dart';
import 'domain/services/cache_cleanup_service.dart';
import 'domain/services/iso_playback_service.dart';
import 'domain/services/mpv_watch_later_sync.dart';
import 'features/cache_control/cache_policy_service.dart';
import 'features/cache_control/iso_cache_coordinator.dart';
import 'features/cache_control/intelligence/cache_intelligence_service.dart';
import 'features/cache_control/store/cache_intelligence_config_store.dart';
import 'features/cache_control/store/cache_intelligence_learning_store.dart';
import 'features/cache_control/store/cache_policy_config_store.dart';
import 'features/cache_control/store/media_metadata_store.dart';
import 'features/cache_expiration/store/cache_expiration_config_store.dart';
import 'presentation/pages/auto_connect_gate.dart';
import 'presentation/pages/storage_root_page.dart';
import 'presentation/localization/app_localizations.dart';
import 'presentation/state/app_state.dart';
import 'presentation/theme/app_theme.dart';
import 'presentation/theme/appearance_controller.dart';
import 'presentation/widgets/window_title_bar.dart';

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
  final cacheExpirationStore = CacheExpirationConfigStore.forPath(
    p.join(configDir.path, CacheExpirationConfigStore.configFileName),
  );
  await cacheExpirationStore.ensureDefault();
  await cacheExpirationStore.load();
  retentionPolicyProvider() => cacheExpirationStore.current;
  Hive.init(cacheDir.path);
  final directoryCache = DirectoryCache(
    policyProvider: retentionPolicyProvider,
  );

  // 全局清理从未再次打开的 MPV 续播文件；扫描不阻塞应用启动。
  const watchLaterSync = MpvWatchLaterSync();
  unawaited(
    Future.wait<int>([
      watchLaterSync.purgeExpiredFiles(
        Directory(p.join(cacheDir.path, 'mpv-watch-later')),
        maxAge: retentionPolicyProvider().playbackRetention,
      ),
      watchLaterSync.purgeExpiredFiles(
        Directory(p.join(cacheDir.path, 'mpv-audio-watch-later')),
        maxAge: retentionPolicyProvider().playbackRetention,
      ),
    ]).then<void>((_) {}),
  );

  // 配置先于 SQLite 加载，使旧进度迁移能绑定到稳定 profileId。
  final configStore = await StreamPathConfigStore.create();
  await configStore.loadForStartup();

  // 其余互不依赖的本地存储并行初始化。
  final directoryCacheInit = directoryCache.init();
  final progressServiceFuture = PlaybackProgressService.create(
    policyProvider: retentionPolicyProvider,
    legacyProfileId: configStore.current.profileId,
  );
  final audioProgressServiceFuture =
      PlaybackProgressService.createAudio(
            policyProvider: retentionPolicyProvider,
            legacyProfileId: configStore.current.profileId,
          )
          .then<PlaybackProgressService?>((service) => service)
          .catchError((_) => null);
  final playbackHistoryStoreFuture = PlaybackHistoryStore.create(
    policyProvider: retentionPolicyProvider,
  );
  final audioPlaybackHistoryStoreFuture = AudioPlaybackHistoryStore.create(
    policyProvider: retentionPolicyProvider,
  ).then<AudioPlaybackHistoryStore?>((store) => store).catchError((_) => null);
  final mediaLibraryStoreFuture = MediaLibraryStore.create()
      .then<MediaLibraryStore?>((store) => store)
      .catchError((_) => null);

  await directoryCacheInit;
  final progressService = await progressServiceFuture;
  final audioProgressService = await audioProgressServiceFuture;
  final playbackHistoryStore = await playbackHistoryStoreFuture;
  final audioPlaybackHistoryStore = await audioPlaybackHistoryStoreFuture;
  final mediaLibraryStore = await mediaLibraryStoreFuture;
  if (mediaLibraryStore != null) {
    try {
      await mediaLibraryStore.applyConfig(configStore.current.mediaLibrary);
    } catch (_) {
      // 个人资产容量应用失败不阻止应用启动，后续写入仍使用已加载限制。
    }
  }
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
  final learningStore = CacheIntelligenceLearningStore.forPath(
    p.join(cacheDir.path, CacheIntelligenceLearningStore.fileName),
  );
  final metadataStore = MediaMetadataStore.forPath(
    p.join(cacheDir.path, MediaMetadataStore.fileName),
    policyProvider: retentionPolicyProvider,
  );
  // 媒体元数据在自己的串行队列中后台过期；学习数据不接入自动清理。
  unawaited(metadataStore.purgeExpired());
  final cacheIntelligence = LocalCacheIntelligenceService(
    configStore: cacheIntelligenceStore,
    learningStore: learningStore,
  );
  final cachePolicy = CachePolicyService(
    store: cachePolicyStore,
    metadataStore: metadataStore,
    intelligence: cacheIntelligence,
  );
  final cacheCleaner = CacheCleanupService(
    preservedCacheNames: {CacheIntelligenceLearningStore.fileName},
    storeClearers: [
      () async => cachePolicy.clearRuntimeCache(),
      directoryCache.clear,
      progressService.clearAll,
      if (audioProgressService != null) audioProgressService.clearAll,
      playbackHistoryStore.clear,
      if (audioPlaybackHistoryStore != null) audioPlaybackHistoryStore.clear,
      () async {
        if (!await metadataStore.clear()) {
          throw const CacheCleanupException('清空媒体元数据失败');
        }
      },
    ],
  );
  final learningDataCleaner = CacheCleanupService(
    deleteRuntimeFiles: false,
    storeClearers: [
      () async {
        if (!await learningStore.clear()) {
          throw const CacheCleanupException('清空缓存学习数据失败');
        }
      },
    ],
  );

  IsoPlaybackService? isoPlaybackService;
  final isoService = IsoPlaybackService(
    configStore: configStore,
    cacheCoordinator: IsoCacheCoordinator(
      policyService: cachePolicy,
      intelligence: cacheIntelligence,
    ),
  );
  try {
    await isoService.initialize();
    isoPlaybackService = isoService;
  } on FileSystemException {
    // ISO 远程播放模块初始化失败不影响既有浏览、视频和音频功能。
    isoService.dispose();
  }

  // 组装 WebDAV、播放器、缓存与界面状态。
  final appState = AppState(
    configStore: configStore,
    playbackHistoryStore: playbackHistoryStore,
    progressService: progressService,
    audioPlaybackHistoryStore: audioPlaybackHistoryStore,
    audioProgressService: audioProgressService,
    mediaLibraryStore: mediaLibraryStore,
    directoryCache: directoryCache,
    cachePolicy: cachePolicy,
    cachePolicyConfigStore: cachePolicyStore,
    cacheIntelligenceConfigStore: cacheIntelligenceStore,
    cacheExpirationConfigStore: cacheExpirationStore,
    cacheCleaner: cacheCleaner,
    learningDataCleaner: learningDataCleaner,
    isoPlaybackService: isoPlaybackService,
  );

  // 地址与用户名完整时直接尝试自动连接，密码允许为空。
  final autoConnect = configStore.current.isConnectionComplete;
  final appearanceController = AppearanceController(
    initialConfig: configStore.current.appearance,
  );
  // 持久化为磨砂样式时先完成窗口合成，再绘制首帧，避免窗口先黑后亮。
  await appearanceController.restoreForStartup();
  runApp(
    StreamPathApp(
      appState: appState,
      appearanceController: appearanceController,
      autoConnect: autoConnect,
    ),
  );
}

/// 应用根组件：注入全局状态 + 主题。
class StreamPathApp extends StatelessWidget {
  const StreamPathApp({
    super.key,
    required this.appState,
    required this.appearanceController,
    required this.autoConnect,
  });

  final AppState appState;
  final AppearanceController appearanceController;

  /// 是否跳过登录页并自动尝试连接。
  final bool autoConnect;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appState),
        ChangeNotifierProvider.value(value: appearanceController),
      ],
      child: AnimatedBuilder(
        animation: Listenable.merge([appearanceController, appState]),
        builder: (context, child) {
          final appearance = appearanceController.config;
          final glass = appearanceController.glassActive;
          final actualBackdrop =
              appearanceController.lastResult?.actualBackdrop ??
              WindowBackdropType.none;
          return MaterialApp(
            onGenerateTitle: (context) =>
                context.l10n.text('StreamPath — WebDAV 浏览器'),
            debugShowCheckedModeBanner: false,
            locale: appState.language.locale,
            supportedLocales: AppLanguage.values.map(
              (language) => language.locale,
            ),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            color: glass ? Colors.transparent : null,
            theme: AppTheme.light(
              glass: glass,
              glassOpacity: appearance.glassOpacity,
              windowBackdrop: actualBackdrop,
            ),
            darkTheme: AppTheme.dark(
              glass: glass,
              glassOpacity: appearance.glassOpacity,
              windowBackdrop: actualBackdrop,
            ),
            builder: (context, navigator) => _buildWindowChrome(navigator),
            home: child,
          );
        },
        child: autoConnect ? const AutoConnectGate() : const StorageRootPage(),
      ),
    );
  }

  /// Windows 下用自绘标题栏替换系统标题栏：应用标识与最小化/最大化/关闭
  /// 按钮由 [WindowTitleBar] 提供，其背景取当前主题 surface 色，与页面
  /// AppBar 无缝衔接；非 Windows 构建保留系统窗口装饰。
  ///
  /// 标题栏位于 Navigator 之上，而 Overlay 在 Navigator 内部，因此把标题栏
  /// 和页面内容整体放入一个 OverlayEntry，为标题栏按钮的 Tooltip 提供
  /// Overlay 挂载点。
  Widget _buildWindowChrome(Widget? navigator) {
    final content = navigator ?? const SizedBox.shrink();
    if (kIsWeb || !Platform.isWindows) {
      return content;
    }
    return Overlay(
      initialEntries: [
        OverlayEntry(
          builder: (context) => Column(
            children: [
              const WindowTitleBar(),
              Expanded(child: content),
            ],
          ),
        ),
      ],
    );
  }
}
