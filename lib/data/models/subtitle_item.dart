/// 字幕语言分类（`SubtitleMatcher` 匹配结果）。
enum SubtitleLanguage {
  /// 完全同名：`movie.mkv` ↔ `movie.srt`（最高优先级）。
  exact,

  /// 中文标签后缀：zh / chs / sc / zh-Hans / zh-hant 等。
  chinese,

  /// 其他语言后缀：en / ja / ko 等。
  other,
}

/// 字幕文件条目（匹配结果，可直接注入播放器）。
class SubtitleItem {
  const SubtitleItem({
    required this.name,
    required this.url,
    required this.language,
    this.score = 0,
  });

  /// 字幕文件名（显示用）。
  final String name;

  /// 字幕地址（服务器 href，可被 `WebDAVService.resolveUrl` 补全）。
  final String url;

  /// 语言分类。
  final SubtitleLanguage language;

  /// 匹配优先级分数（越高越优先，排序用）。
  final int score;

  @override
  String toString() => 'SubtitleItem($name [$language])';
}
