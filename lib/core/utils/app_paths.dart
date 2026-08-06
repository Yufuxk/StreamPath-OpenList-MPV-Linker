import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 应用数据路径：**集中存放**配置、缓存、日志、数据库，追求高便携性。
///
/// 数据目录 = 项目根文件夹下的 `stream_path_data/`：
/// ```
/// <项目根>/stream_path_data/
///   ├── stream_path_config.json   ← 用户配置（连接 + 播放器 + 隐藏后缀）
///   ├── playback_history.json     ← 上次播放记录（动态）
///   ├── streampath.db             ← 播放进度
///   ├── directory_cache/          ← 目录元数据缓存（Hive）
///   └── clipboard_history_fix.log ← 剪贴板诊断日志
/// ```
/// 项目根由可执行文件路径推算（`<项目根>/build/windows/x64/runner/...`，
/// 取 `build` 段之前的部分）；推算失败（如安装到任意目录）时回退到
/// 应用支持目录，保证应用始终可用且数据仍集中在单个文件夹。
class AppPaths {
  AppPaths._();

  /// 数据文件夹名。
  static const String dataDirName = 'stream_path_data';

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

  /// 定位项目根目录。
  ///
  /// 从可执行文件路径推算（`<项目根>/build/windows/x64/runner/<Debug|Release>/`
  /// 或 Linux 的 `build/linux/x64/...`，取 `build` 段之前的部分）；
  /// 推算失败时回退当前工作目录。
  static String projectRoot() {
    final exe = Platform.resolvedExecutable;
    final parts = p.split(exe);
    final buildIndex = parts.indexWhere((s) => s.toLowerCase() == 'build');
    if (buildIndex > 0) {
      return p.joinAll(parts.sublist(0, buildIndex));
    }
    return Directory.current.path;
  }
}
