/// 容器/URL 规则工具（缓存模块与播放器集成层共用，单一来源）。
library;

/// TS 类容器（m2ts/ts）判定：基于 **URI path** 而非完整 URL，兼容：
/// - 查询参数（`video.ts?token=abc`）
/// - 片段（`video.ts#part`）
/// - 大小写扩展名（`MOVIE.M2TS`）
/// - URL 编码路径（`video%2Ets`）
/// - 无法解析的 URL（回退按原始字符串匹配）
bool isTsContainerUrl(String value) {
  final uri = Uri.tryParse(value);
  final path = uri?.path ?? value;
  return _tsPathPattern.hasMatch(path);
}

final RegExp _tsPathPattern = RegExp(r'\.(m2ts|ts)$', caseSensitive: false);
