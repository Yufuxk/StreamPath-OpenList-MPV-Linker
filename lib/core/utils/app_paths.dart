import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 应用数据路径：**集中存放**配置、缓存、日志、数据库，追求高便携性。
///
/// 数据目录 = 项目根文件夹下的 `stream_path_data/`，内部按用途分三个
/// 子目录（英文命名）：
/// ```
/// <项目根>/stream_path_data/
///   ├── config/                    ← 用户配置文件
///   │   ├── stream_path_config.json  （连接 + 播放器 + 隐藏后缀）
///   │   ├── cache_policy.json        （基础缓存策略，常驻可编辑）
///   │   └── cache_intelligence.json  （第三阶段本地智能优化配置）
///   ├── library/                   ← 收藏、最近目录和长期播放历史
///   └── cache/                     ← 运行时缓存数据
///       ├── directory_cache/          （目录元数据缓存 Hive）
///       ├── mpv-watch-later/          （mpv 续播进度）
///       ├── streampath.db             （播放进度 SQLite）
///       ├── playback_history.json     （上次播放记录）
///       ├── audio_streampath.db       （音频播放进度 SQLite）
///       ├── audio_playback_history.json（音频播放记录）
///       ├── media_metadata.json       （缓存系统媒体元数据）
///       ├── cache_intelligence_learning.json（匿名聚合学习数据）
///       ├── mpv-current-*.txt         （mpv 状态上报）
///       ├── mpv-command-*.txt         （mpv 命令通道）
///       ├── mpv.log / *.lua / *.m3u   （日志与脚本产物）
///       └── clipboard_history_fix.log （剪贴板诊断日志）
/// ```
/// 项目根由可执行文件路径推算（`<项目根>/build/windows/x64/runner/...`，
/// 取 `build` 段之前的部分）；推算失败（便携版安装到任意目录）时回退
/// **可执行文件所在目录**（`stream_path_data/` 生成在便携文件夹内）；
/// exe 目录不可写时回退应用支持目录，保证应用始终可用且数据仍集中
/// 在单个文件夹。
///
/// 旧版平铺布局（文件直接放 `stream_path_data/` 根下）在启动时经
/// [migrateLegacyLayout] 自动迁移到新子目录，用户数据不丢失。
class AppPaths {
  AppPaths._();

  /// 数据文件夹名。
  static const String dataDirName = 'stream_path_data';

  /// 配置文件子目录名。
  static const String configDirName = 'config';

  /// 缓存数据子目录名。
  static const String cacheDirName = 'cache';

  /// 个人媒体资产子目录名。
  static const String libraryDirName = 'library';

  /// 数据目录（不存在时自动创建）。
  static Future<Directory> dataDirectory() async {
    final root = projectRoot();
    final dir = Directory(p.join(root, dataDirName));
    try {
      await dir.create(recursive: true);
      return dir;
    } on FileSystemException {
      // 项目根不可写：回退应用支持目录（便携性降级，数据仍集中）。
      final fallback = await getApplicationSupportDirectory();
      final dir2 = Directory(p.join(fallback.path, dataDirName));
      await dir2.create(recursive: true);
      return dir2;
    }
  }

  /// 用户配置文件目录（`stream_path_data/config/`，自动创建）。
  static Future<Directory> configDirectory() async {
    final dataDir = await dataDirectory();
    final dir = Directory(p.join(dataDir.path, configDirName));
    await dir.create(recursive: true);
    return dir;
  }

  /// 缓存数据目录（`stream_path_data/cache/`，自动创建）。
  static Future<Directory> cacheDirectory() async {
    final dataDir = await dataDirectory();
    final dir = Directory(p.join(dataDir.path, cacheDirName));
    await dir.create(recursive: true);
    return dir;
  }

  /// 个人媒体资产目录（`stream_path_data/library/`）。
  ///
  /// 该目录不属于可重建缓存，普通缓存清理不会删除其中数据。
  static Future<Directory> libraryDirectory() async {
    final dataDir = await dataDirectory();
    final dir = Directory(p.join(dataDir.path, libraryDirName));
    await dir.create(recursive: true);
    return dir;
  }

  /// 旧版平铺布局迁移：把 `stream_path_data/` 根下的已知文件/目录
  /// 移动到对应的 `config/` 或 `cache/` 子目录。
  ///
  /// 规则：目标已存在不覆盖；单个失败静默跳过（数据留在原处，下次
  /// 启动重试）；集成方在应用启动早期（各 store 初始化前）调用一次。
  /// [dataDir] 仅测试注入用（默认取真实数据目录）。
  static Future<void> migrateLegacyLayout({Directory? dataDir}) async {
    final root = dataDir ?? await dataDirectory();
    final cacheDir = Directory(p.join(root.path, cacheDirName));
    final configDir = Directory(p.join(root.path, configDirName));
    await cacheDir.create(recursive: true);
    await configDir.create(recursive: true);

    // 配置文件（config/）。
    for (final name in const [
      'stream_path_config.json',
      'cache_policy.json',
      'cache_intelligence.json',
    ]) {
      await _moveIfPresent(
        File(p.join(root.path, name)),
        File(p.join(configDir.path, name)),
      );
    }

    // 缓存文件（cache/）：固定名 + 会话/播放列表前缀通配。
    for (final name in const [
      'streampath.db',
      'playback_history.json',
      'audio_streampath.db',
      'audio_playback_history.json',
      'media_metadata.json',
      'cache_intelligence_learning.json',
      'mpv-current.txt',
      'mpv-command.txt',
      'mpv.log',
      'clipboard_history_fix.log',
      'directory_cache.hive',
      'directory_cache.lock',
    ]) {
      await _moveIfPresent(
        File(p.join(root.path, name)),
        File(p.join(cacheDir.path, name)),
      );
    }
    // 会话状态、进度、播放列表和 Lua 产物。
    try {
      final entries = root.listSync(followLinks: false);
      for (final e in entries) {
        final name = p.basename(e.path);
        final isSessionFile =
            name.startsWith('mpv-current-') ||
            name.startsWith('mpv-command-') ||
            name.startsWith('mpv-progress-') ||
            name.startsWith('mpv-audio-current-') ||
            name.startsWith('mpv-audio-command-') ||
            name.startsWith('mpv-audio-progress-') ||
            name.startsWith('streampath-playlist-') ||
            name.startsWith('streampath-audio-') ||
            name.endsWith('.lua');
        if (isSessionFile && e is File) {
          await _moveIfPresent(e, File(p.join(cacheDir.path, name)));
        }
      }
    } catch (_) {
      // 枚举失败静默。
    }

    // 缓存目录：mpv-watch-later/、mpv-scripts/。
    for (final name in const [
      'mpv-watch-later',
      'mpv-audio-watch-later',
      'mpv-scripts',
    ]) {
      final src = Directory(p.join(root.path, name));
      if (await src.exists()) {
        final dst = Directory(p.join(cacheDir.path, name));
        if (!await dst.exists()) {
          try {
            await src.rename(dst.path);
          } catch (_) {
            // 占用/权限失败静默，数据留在原处。
          }
        }
      }
    }
  }

  static Future<void> _moveIfPresent(File src, File dst) async {
    try {
      if (await src.exists() && !await dst.exists()) {
        await src.rename(dst.path);
      }
    } catch (_) {
      // 迁移失败静默：数据留在原处，不丢失。
    }
  }

  /// 定位项目根目录。
  ///
  /// 从可执行文件路径推算（`<项目根>/build/windows/x64/runner/<Debug|Release>/`，
  /// 取 `build` 段之前的部分）；推算失败（如便携版安装到任意目录）时
  /// 回退**可执行文件所在目录**——数据目录始终跟随程序位置，便携版
  /// 的 `stream_path_data/` 生成在便携文件夹内（与开发版行为一致）。
  /// 不用 `Directory.current` 回退：桌面双击/快捷方式启动时工作目录
  /// 可能落在用户主目录，导致 `stream_path_data` 写到无关位置。
  static String projectRoot() {
    final exe = Platform.resolvedExecutable;
    final parts = p.split(exe);
    final buildIndex = parts.indexWhere((s) => s.toLowerCase() == 'build');
    if (buildIndex > 0) {
      return p.joinAll(parts.sublist(0, buildIndex));
    }
    return p.dirname(exe);
  }
}
