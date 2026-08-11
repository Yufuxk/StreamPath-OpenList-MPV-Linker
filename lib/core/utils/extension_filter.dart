/// 文件后缀解析/格式化工具（文件浏览页「隐藏后缀」过滤器）。
library;

import '../../data/models/web_dav_file.dart';

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

/// 解析用户输入的后缀列表（宽松格式），返回规范化结果（小写、含点、去重）。
///
/// 支持的输入形式：
/// ```
/// {".ass", ".mp4", ".mp3"}    ← 推荐：花括号 + 逗号 + 引号
/// .ass .mp4 mp3               ← 无花括号/引号/点均可
/// .ASS, .MP4                  ← 大小写不敏感
/// ```
/// 解析失败抛 [FormatException]（信息含出错 token）。
List<String> parseHiddenExtensions(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return const [];

  // 去掉整体花括号：{".ass", ".mp4"}
  if (s.startsWith('{') && s.endsWith('}')) {
    s = s.substring(1, s.length - 1);
  }

  // 按逗号分割；无逗号时按空白分割。
  final parts = s.contains(',') ? s.split(',') : s.split(RegExp(r'\s+'));

  final result = <String>[];
  for (final part in parts) {
    var token = part.trim();
    if (token.isEmpty) continue;
    // 去掉包裹引号。
    token = token.replaceAll(RegExp("^[\"']+|[\"']+\$"), '');
    final ext = normalizeExtension(token);
    if (ext == null) {
      throw FormatException('无法识别的文件后缀：「$token」（示例：{".ass", ".mp4"}）');
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
bool shouldHideFile(WebDavFile file, Set<String> hiddenExtensions) {
  if (file.isDirectory || file.isSelfEntry) return false;
  return hiddenExtensions.contains(file.extension);
}

/// 把后缀列表格式化为设置页回显形式：`{".ass", ".mp4", ".mp3"}`。
String formatHiddenExtensions(List<String> extensions) =>
    extensions.isEmpty ? '' : '{${extensions.map((e) => '"$e"').join(', ')}}';
