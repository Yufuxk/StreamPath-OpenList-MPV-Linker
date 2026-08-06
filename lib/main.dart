import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import 'core/utils/app_paths.dart';
import 'core/utils/clipboard_history_fix.dart';
import 'data/local/stream_path_config_store.dart';
import 'data/local/directory_cache.dart';
import 'data/local/playback_history_store.dart';
import 'data/local/playback_progress_db.dart';
import 'presentation/pages/auto_connect_gate.dart';
import 'presentation/pages/home_page.dart';
import 'presentation/state/app_state.dart';

/// StreamPath 应用入口。
///
/// 启动流程（全部异步初始化，完成后进入 UI）：
///  1. Hive：目录元数据缓存（秒开基石）；
///  2. SQLite：播放进度库（sqflite_common_ffi 桌面实现）；
///  3. 配置：外部播放器 JSON 配置；
///  4. 上次播放记录（继续播放入口）；
///  5. 组装 AppState 并注入全局 provider。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 0. 剪贴板历史修复：Win11 的 Win+V 剪贴板历史注入序列缺 V 键，
  //    导致 Flutter 的 Ctrl+V 快捷键不触发（上游 #143997），
  //    此处改写为合法 Ctrl+V（仅 Windows 生效）。
  //    诊断日志：应用支持目录/clipboard_history_fix.log。
  await ClipboardHistoryFix.install();

  // 1. Hive 目录缓存（存储 PROPFIND 元数据，TTL 内目录秒开）。
  //    数据集中存放在项目根/stream_path_data（便携）。
  final dataDir = await AppPaths.dataDirectory();
  Hive.init(dataDir.path);
  final directoryCache = DirectoryCache();
  await directoryCache.init();

  // 2. 播放进度 SQLite 库。
  final progressService = await PlaybackProgressService.create();

  // 3. 统一配置（连接信息 + 播放器 + 隐藏后缀，集中一个文件）。
  final configStore = await StreamPathConfigStore.create();
  await configStore.load(); // 提前加载：判断是否可自动连接。

  // 4. 上次播放记录（继续播放入口）。
  final playbackHistoryStore = await PlaybackHistoryStore.create();

  // 5. 全局状态（含 WebDAV/播放器/字幕服务）。
  final appState = AppState(
    configStore: configStore,
    playbackHistoryStore: playbackHistoryStore,
    progressService: progressService,
    directoryCache: directoryCache,
  );

  // 已保存完整登录信息 → 直接自动连接（不渲染登录页，避免闪现）。
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

  /// 是否自动连接（有完整登录信息时跳过登录页）。
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
