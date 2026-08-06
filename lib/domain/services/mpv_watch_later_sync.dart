import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// mpv `watch_later` 文件的进度读取（播放进度写回闭环）。
///
/// mpv 在 `--save-position-on-quit` 且退出（quit_watch_later / 关闭窗口）时，
/// 会把播放位置写入 `--watch-later-directory` 下的一个文件，内容形如：
/// ```
/// start=123.456
/// aid=1
/// ```
/// 命名规则：
/// - 默认：文件名 = **MD5(播放 URL/路径) 的大写十六进制**（如
///   `3347FAA6E27536F7F05DD95A4E2B4668`）；
/// - 启用 `--write-filename-in-watch-later-config`：文件名 = sanitize 后的
///   URL，且首行有 `# <原始地址>` 注释（本地文件路径播放时也带注释行）。
///
/// 因此 [readStartSeconds] 采用双通道匹配：
/// 1. **MD5 文件名直查**（HTTP 流播放时无注释行，这是主通道）；
/// 2. **目录扫描 + 注释行匹配**（兜底兼容 sanitize 命名与本地文件记录）。
class MpvWatchLaterSync {
  const MpvWatchLaterSync();

  /// 计算 mpv watch_later 默认文件名：MD5(url) 大写 hex。
  static String md5FileName(String url) =>
      md5.convert(utf8.encode(url)).toString().toUpperCase();

  /// 在 watch_later 目录中读取 [url] 的已保存播放位置（秒）。
  ///
  /// 先按 MD5 文件名直查（O(1)）；未命中再扫描目录按首行注释匹配。
  /// 无匹配或解析失败返回 null。
  Future<double?> readStartSeconds(Directory dir, String url) async {
    final file = await _findFile(dir, url);
    if (file == null) return null;
    try {
      return parseStart(await file.readAsString());
    } on FileSystemException {
      return null;
    }
  }

  /// 在 watch_later 目录中读取 [url] 的已保存时长（秒）。
  ///
  /// mpv 0.36+ 会在 watch_later 文件写入 `duration=` 行；旧版本无此行时
  /// 返回 null（调用方应保守处理，如视为「已看完」从头播放）。
  Future<double?> readDurationSeconds(Directory dir, String url) async {
    final file = await _findFile(dir, url);
    if (file == null) return null;
    try {
      return parseDuration(await file.readAsString());
    } on FileSystemException {
      return null;
    }
  }

  /// 定位 [url] 对应的 watch_later 文件（MD5 直查 → 目录扫描兜底）。
  Future<File?> _findFile(Directory dir, String url) async {
    // ── 1. MD5 文件名直查（主通道） ──────────────────────────
    final direct = File(p.join(dir.path, md5FileName(url)));
    if (await direct.exists()) return direct;

    // ── 2. 目录扫描 + 注释行匹配（兜底） ─────────────────────
    final Iterable<File> files;
    try {
      files = dir.listSync().whereType<File>();
    } on FileSystemException {
      return null; // 目录不存在等：视为无记录。
    }

    for (final f in files) {
      final String content;
      try {
        content = await f.readAsString();
      } on FileSystemException {
        continue; // 单个文件读取失败（被占用/删除）跳过。
      }
      if (_referencesUrl(content, url)) return f;
    }
    return null;
  }

  /// 内容中的注释行（`# ...`）是否引用了 [url]。
  static bool _referencesUrl(String content, String url) {
    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('#')) continue;
      final ref = trimmed.substring(1).trim();
      // 兼容可能带引号的写法。
      final unquoted =
          ref.length >= 2 &&
              ((ref.startsWith('"') && ref.endsWith('"')) ||
                  (ref.startsWith("'") && ref.endsWith("'")))
          ? ref.substring(1, ref.length - 1)
          : ref;
      if (unquoted == url) return true;
    }
    return false;
  }

  /// 解析 watch_later 文件内容中的 `start=` 秒数；无记录返回 null。
  ///
  /// 兼容 mpv 实际输出（`start=123.456`）与容错格式（`start = 90.5`）。
  static double? parseStart(String content) {
    final match = RegExp(
      r'^\s*start\s*=\s*([0-9]*\.?[0-9]+)\s*$',
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(content);
    if (match == null) return null;
    final value = double.tryParse(match.group(1)!);
    return (value != null && value > 0) ? value : null;
  }

  /// 解析 watch_later 文件内容中的 `duration=` 秒数；无记录返回 null。
  static double? parseDuration(String content) {
    final match = RegExp(
      r'^\s*duration\s*=\s*([0-9]*\.?[0-9]+)\s*$',
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(content);
    if (match == null) return null;
    final value = double.tryParse(match.group(1)!);
    return (value != null && value > 0) ? value : null;
  }
}
