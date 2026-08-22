/// StreamPath 支持的界面语言。
enum AppLanguage {
  simplifiedChinese('zh-CN'),
  traditionalChinese('zh-TW'),
  japanese('ja'),
  english('en');

  const AppLanguage(this.configValue);

  /// 配置文件中使用的稳定值。
  final String configValue;

  /// 配置缺失或值无效时继续使用简体中文。
  static AppLanguage fromJson(Object? value) {
    final normalized = value?.toString().trim().toLowerCase();
    return switch (normalized) {
      'zh-tw' || 'zh_tw' || 'zh-hant' => traditionalChinese,
      'ja' || 'ja-jp' || 'ja_jp' => japanese,
      'en' || 'en-us' || 'en_us' => english,
      _ => simplifiedChinese,
    };
  }
}
