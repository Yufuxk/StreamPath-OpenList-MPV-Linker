/// 文件后缀解析/格式化工具（文件浏览页「隐藏后缀」过滤器）。
library;

import '../../data/models/media_directory_entry.dart';

/// 规范化单个后缀：小写、确保以 `.` 开头。
///
/// 非法输入（空、含空白/路径分隔符等）返回 null。
String? normalizeExtension(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return null;
  if (!s.startsWith('.')) s = '.$s';
  s = s.toLowerCase();
  return RegExp(r'^\.\w+$').hasMatch(s) ? s : null;
}

/// 解析用户输入的后缀列表，返回规范化结果（小写、含点、去重）。
///
/// 输入使用英文逗号分隔：
/// ```
/// .ass, .mp4, .mp3
/// ```
/// 解析失败抛 [FormatException]（信息含出错 token）。
List<String> parseHiddenExtensions(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return const [];

  if (RegExp(r'[，、；;]').hasMatch(s)) {
    throw const FormatException('请使用英文逗号「,」分隔文件后缀（示例：.ass, .mkv）');
  }
  if (RegExp(r'''[{}"']''').hasMatch(s)) {
    throw const FormatException('请直接输入文件后缀，不要使用花括号或引号（示例：.ass, .mkv）');
  }

  final parts = s.split(',');

  final result = <String>[];
  for (final part in parts) {
    final token = part.trim();
    if (token.isEmpty) {
      throw const FormatException('英文逗号之间必须填写文件后缀（示例：.ass, .mkv）');
    }
    final ext = normalizeExtension(token);
    if (ext == null) {
      throw FormatException('无法识别的文件后缀：「$token」（请使用英文逗号分隔，例如：.ass, .mkv）');
    }
    if (!result.contains(ext)) result.add(ext);
  }
  return result;
}

/// 判断文件是否应在浏览页隐藏。
///
/// 目录与「返回上级」条目**永不过滤**——目录名可能含点
/// （如 `1.EpisodeData`、`Star.Wars.2005`），不能按扩展名规则隐藏；
/// 仅普通文件按 [WebDavFile.extension] 匹配。
bool shouldHideFile(
  MediaDirectoryEntry file,
  Set<String> hiddenExtensions, {
  bool enabled = true,
}) {
  if (!enabled) return false;
  if (file.isDirectory || file.isSelfEntry) return false;
  return hiddenExtensions.contains(file.extension);
}

/// 把后缀列表格式化为设置页回显形式：`.ass, .mp4, .mp3`。
String formatHiddenExtensions(List<String> extensions) => extensions.join(', ');
