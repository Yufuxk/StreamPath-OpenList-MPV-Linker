/// .strm 流指针文件内容解析。
///
/// .strm 是 Kodi/Emby 等媒体库使用的流指针文件，内容为一行媒体
/// URL（可能带前导/尾随空白、空行或 `#` 注释行）。
library;

/// 从 .strm 文件内容中提取媒体 URL；无有效行返回 null。
String? parseStrmUrl(String content) {
  for (final line in content.split('\n')) {
    // 剥离 BOM（部分编辑器会写入 ﻿ 前缀）。
    final trimmed = line.replaceFirst('﻿', '').trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    return trimmed;
  }
  return null;
}
