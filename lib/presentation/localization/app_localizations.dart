import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../data/models/app_language.dart';
import 'app_translation_catalog.dart';

/// StreamPath 项目文案的本地化入口。
class AppLocalizations {
  const AppLocalizations(this.language);

  final AppLanguage language;

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  static AppLocalizations of(BuildContext context) =>
      Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      const AppLocalizations(AppLanguage.simplifiedChinese);

  String text(String source) {
    final translations = switch (language) {
      AppLanguage.simplifiedChinese => null,
      AppLanguage.traditionalChinese => traditionalChineseTranslations,
      AppLanguage.japanese => japaneseTranslations,
      AppLanguage.english => englishTranslations,
    };
    return translations?[source] ??
        _supplementalTranslations[language]?[source] ??
        _translateDynamic(source, translations);
  }

  String _translateDynamic(String source, Map<String, String>? translations) {
    if (translations == null) return source;
    var result = source;
    for (final fragment in _dynamicFragments) {
      final translated =
          translations[fragment] ??
          _supplementalTranslations[language]?[fragment];
      if (translated != null && result.contains(fragment)) {
        result = result.replaceAll(fragment, translated);
      }
    }
    return result;
  }

  static const List<String> _dynamicFragments = <String>[
    '保存收藏失败：',
    '保存最近播放失败：',
    '保存最近目录失败：',
    '读取媒体资产失败：',
    '连接失败：',
    '清空最近播放失败：',
    '清空最近目录失败：',
    '清理缓存失败：',
    '清理媒体中心记录失败：',
    '清理学习数据失败：',
    '删除最近播放失败：',
    '删除最近目录失败：',
    '刷新媒体资产失败：',
    '索引更新失败：',
    '应用窗口外观失败：',
    '重置设置失败：',
    '正在播放：',
    '正在播放音频：',
    '正在打开：',
    '正在打开音频：',
    '正在恢复：',
    '继续播放：',
    '继续播放音频：',
    '已暂停：',
    '音频已暂停：',
    '字幕：',
    '封面：',
    '歌词：',
    '状态：',
    '已播放 ',
  ];

  static const Map<AppLanguage, Map<String, String>>
  _supplementalTranslations = <AppLanguage, Map<String, String>>{
    AppLanguage.traditionalChinese: <String, String>{
      '语言': '語言',
      '界面语言': '介面語言',
      '选择软件使用的显示语言；保存全部配置后立即切换。': '選擇軟體使用的顯示語言；儲存全部設定後立即切換。',
      '连接失败：': '連線失敗：',
      '清理缓存失败：': '清理快取失敗：',
      '正在播放：': '正在播放：',
      '正在播放音频：': '正在播放音訊：',
      '状态：': '狀態：',
    },
    AppLanguage.japanese: <String, String>{
      '语言': '言語',
      '界面语言': '表示言語',
      '选择软件使用的显示语言；保存全部配置后立即切换。': 'ソフトウェアの表示言語を選択します。すべての設定を保存するとすぐに切り替わります。',
      '连接失败：': '接続に失敗しました：',
      '清理缓存失败：': 'キャッシュの削除に失敗しました：',
      '正在播放：': '再生中：',
      '正在播放音频：': '音声を再生中：',
      '状态：': '状態：',
    },
    AppLanguage.english: <String, String>{
      '语言': 'Language',
      '界面语言': 'Display language',
      '选择软件使用的显示语言；保存全部配置后立即切换。':
          'Choose the display language. It changes after all settings are saved.',
      '连接失败：': 'Connection failed: ',
      '清理缓存失败：': 'Failed to clear cache: ',
      '正在播放：': 'Playing: ',
      '正在播放音频：': 'Playing audio: ',
      '状态：': 'Status: ',
    },
  };
}

extension AppLanguagePresentation on AppLanguage {
  Locale get locale => switch (this) {
    AppLanguage.simplifiedChinese => const Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hans',
      countryCode: 'CN',
    ),
    AppLanguage.traditionalChinese => const Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hant',
      countryCode: 'TW',
    ),
    AppLanguage.japanese => const Locale('ja', 'JP'),
    AppLanguage.english => const Locale('en', 'US'),
  };

  String get nativeLabel => switch (this) {
    AppLanguage.simplifiedChinese => '简体中文',
    AppLanguage.traditionalChinese => '繁體中文',
    AppLanguage.japanese => '日本語',
    AppLanguage.english => 'English',
  };
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) =>
      const {'zh', 'ja', 'en'}.contains(locale.languageCode);

  @override
  Future<AppLocalizations> load(Locale locale) => SynchronousFuture(
    AppLocalizations(switch (locale.languageCode) {
      'ja' => AppLanguage.japanese,
      'en' => AppLanguage.english,
      'zh' when locale.scriptCode == 'Hant' || locale.countryCode == 'TW' =>
        AppLanguage.traditionalChinese,
      _ => AppLanguage.simplifiedChinese,
    }),
  );

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

extension AppLocalizationsContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
