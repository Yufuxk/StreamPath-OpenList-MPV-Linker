import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/constants.dart';
import '../../core/utils/cache_expiration.dart';

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
  Future<double?> readStartSeconds(
    Directory dir,
    String url, {
    Duration maxAge = AppConstants.playbackCacheRetention,
    DateTime? now,
  }) async {
    final (:file, :expired) = await _findFile(
      dir,
      url,
      maxAge: maxAge,
      now: now ?? DateTime.now(),
    );
    if (expired) return null;
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
  /// 返回 null，调用方不得仅凭时长缺失判定已经播放完成。
  Future<double?> readDurationSeconds(
    Directory dir,
    String url, {
    Duration maxAge = AppConstants.playbackCacheRetention,
    DateTime? now,
  }) async {
    final (:file, :expired) = await _findFile(
      dir,
      url,
      maxAge: maxAge,
      now: now ?? DateTime.now(),
    );
    if (expired) return null;
    if (file == null) return null;
    try {
      return parseDuration(await file.readAsString());
    } on FileSystemException {
      return null;
    }
  }

  /// 删除 [url] 对应的恢复记录。
  ///
  /// 同时兼容默认 MD5 文件名与开启
  /// `--write-filename-in-watch-later-config` 后的注释匹配文件名。
  Future<void> deleteRecord(Directory dir, String url) async {
    final direct = File(p.join(dir.path, md5FileName(url)));
    try {
      if (await direct.exists()) await direct.delete();
    } on FileSystemException {
      // 继续扫描注释匹配文件。
    }

    final Iterable<File> files;
    try {
      files = dir.listSync().whereType<File>();
    } on FileSystemException {
      return;
    }
    for (final file in files) {
      final String content;
      try {
        content = await file.readAsString();
      } on FileSystemException {
        continue;
      }
      if (!_referencesUrl(content, url)) continue;
      try {
        await file.delete();
      } on FileSystemException {
        // 单个文件删除失败不影响其他候选。
      }
    }
  }

  /// 删除指定 URL 集合中已经超过续播保留期的记录。
  Future<int> purgeExpiredRecords(
    Directory dir,
    Iterable<String> urls, {
    Duration maxAge = AppConstants.playbackCacheRetention,
    DateTime? now,
  }) async {
    var removed = 0;
    final pendingUrls = urls.toSet();
    if (pendingUrls.isEmpty) return 0;
    final checkedAt = now ?? DateTime.now();

    final directNames = <String>{};
    for (final url in pendingUrls.toList(growable: false)) {
      final directName = md5FileName(url);
      directNames.add(directName);
      final direct = File(p.join(dir.path, directName));
      if (!await direct.exists()) continue;
      pendingUrls.remove(url);
      if (await _deleteIfExpired(direct, maxAge, checkedAt)) removed++;
    }
    if (pendingUrls.isEmpty) return removed;

    final Iterable<File> files;
    try {
      files = dir.listSync().whereType<File>();
    } on FileSystemException {
      return removed;
    }
    for (final file in files) {
      if (directNames.contains(p.basename(file.path))) continue;
      final String content;
      try {
        content = await file.readAsString();
      } on FileSystemException {
        continue;
      }
      String? matched;
      for (final referencedUrl in _referencedUrls(content)) {
        if (pendingUrls.contains(referencedUrl)) {
          matched = referencedUrl;
          break;
        }
      }
      if (matched == null) continue;
      pendingUrls.remove(matched);
      if (await _deleteIfExpired(file, maxAge, checkedAt)) removed++;
      if (pendingUrls.isEmpty) break;
    }
    return removed;
  }

  /// 扫描目录并删除全部过期的 watch_later 记录。
  ///
  /// 仅处理 MD5 命名或内容可识别为进度记录的文件，避免误删同目录中的
  /// 播放列表、Lua 脚本等会话产物。新鲜文件只做一次 stat，不读取内容。
  Future<int> purgeExpiredFiles(
    Directory dir, {
    Duration maxAge = AppConstants.playbackCacheRetention,
    DateTime? now,
  }) async {
    final Iterable<File> files;
    try {
      files = dir.listSync().whereType<File>();
    } on FileSystemException {
      return 0;
    }
    final checkedAt = now ?? DateTime.now();
    final md5Name = RegExp(r'^[0-9a-f]{32}$', caseSensitive: false);
    var removed = 0;
    for (final file in files) {
      final FileStat stat;
      try {
        stat = await file.stat();
      } on FileSystemException {
        continue;
      }
      if (stat.type != FileSystemEntityType.file) continue;
      if (!CacheExpiration.isExpired(
        lastUsedAt: stat.modified,
        retention: maxAge,
        now: checkedAt,
      )) {
        continue;
      }

      var isWatchLater = md5Name.hasMatch(p.basename(file.path));
      if (!isWatchLater) {
        try {
          final content = await file.readAsString();
          isWatchLater = parseStart(content) != null;
        } on FileSystemException {
          continue;
        }
      }
      if (isWatchLater && await _deleteIfExpired(file, maxAge, checkedAt)) {
        removed++;
      }
    }
    return removed;
  }

  /// 定位 [url] 对应的 watch_later 文件（MD5 直查 → 目录扫描兜底）。
  Future<({File? file, bool expired})> _findFile(
    Directory dir,
    String url, {
    required Duration maxAge,
    required DateTime now,
  }) async {
    // ── 1. MD5 文件名直查（主通道） ──────────────────────────
    final direct = File(p.join(dir.path, md5FileName(url)));
    if (await direct.exists()) {
      final expired = await _deleteIfExpired(direct, maxAge, now);
      return (file: expired ? null : direct, expired: expired);
    }

    // ── 2. 目录扫描 + 注释行匹配（兜底） ─────────────────────
    final Iterable<File> files;
    try {
      files = dir.listSync().whereType<File>();
    } on FileSystemException {
      return (file: null, expired: false); // 目录不存在等：视为无记录。
    }

    for (final f in files) {
      final String content;
      try {
        content = await f.readAsString();
      } on FileSystemException {
        continue; // 单个文件读取失败（被占用/删除）跳过。
      }
      if (_referencesUrl(content, url)) {
        final expired = await _deleteIfExpired(f, maxAge, now);
        return (file: expired ? null : f, expired: expired);
      }
    }
    return (file: null, expired: false);
  }

  Future<bool> _deleteIfExpired(
    File file,
    Duration maxAge,
    DateTime now,
  ) async {
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) return false;
      final modifiedAt = stat.modified;
      if (!CacheExpiration.isExpired(
        lastUsedAt: modifiedAt,
        retention: maxAge,
        now: now,
      )) {
        return false;
      }
      try {
        await file.delete();
      } on FileSystemException {
        // 删除失败仍按过期处理，避免旧进度重新写回数据库。
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// 内容中的注释行（`# ...`）是否引用了 [url]。
  static bool _referencesUrl(String content, String url) {
    return _referencedUrls(content).contains(url);
  }

  static Iterable<String> _referencedUrls(String content) sync* {
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
      yield unquoted;
    }
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
    // 0 是有效的“明确从头播放”状态，不能与缺失/解析失败混为一谈。
    return (value != null && value >= 0) ? value : null;
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
