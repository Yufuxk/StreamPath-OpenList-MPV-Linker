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
    return _supplementalTranslations[language]?[source] ??
        translations?[source] ??
        _translateDynamic(source, translations);
  }

  String format(String source, Map<String, Object?> arguments) {
    var result = text(source);
    for (final argument in arguments.entries) {
      result = result.replaceAll(
        '{${argument.key}}',
        '${argument.value ?? ''}',
      );
    }
    return result;
  }

  String _translateDynamic(String source, Map<String, String>? translations) {
    if (translations == null) return source;
    var result = source;
    for (final fragment in _dynamicFragments) {
      final translated =
          _supplementalTranslations[language]?[fragment] ??
          translations[fragment];
      if (translated != null && result.contains(fragment)) {
        result = result.replaceAll(fragment, translated);
      }
    }
    return result;
  }

  static const List<String> _dynamicFragments = <String>[
    '请先关闭或删除一个音频下边栏后再播放。',
    '请先关闭或删除一个下边栏后再播放。',
    '」：strm 内容无效或读取失败',
    '当前最多同时保留 ',
    ' 个音频会话，',
    ' 个播放会话，',
    '已启动音频播放器（',
    '已启动播放器（',
    '数据库维护完成，已创建 ',
    ' 个备份',
    '无法播放「',
    '诊断执行失败：',
    '导出诊断包失败：',
    '脱敏诊断包已导出：',
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
    'Windows 外观能力检测失败：',
    '上次更新时间：',
    '上次错误：',
    '已处理条目：',
    '应用窗口外观失败：',
    '重置设置失败：',
    '正在播放：',
    '正在播放音频：',
    '正在打开：',
    '正在打开音频：',
    '正在恢复：',
    '继续播放：',
    '继续播放音频：',
    '音频已暂停：',
    '已暂停：',
    '字幕：',
    '封面：',
    '歌词：',
    '状态：',
    '续播于 ',
    ' 集）',
    ' 首）',
    '已播放 ',
  ];

  static const Map<AppLanguage, Map<String, String>>
  _supplementalTranslations = <AppLanguage, Map<String, String>>{
    AppLanguage.traditionalChinese: <String, String>{
      '语言': '語言',
      '界面语言': '介面語言',
      '选择软件使用的显示语言；保存全部配置后立即切换。': '選擇軟體使用的顯示語言；儲存全部設定後立即切換。',
      '连接失败：': '連線失敗：',
      '保存收藏失败：': '儲存收藏失敗：',
      '保存最近播放失败：': '儲存最近播放失敗：',
      '保存最近目录失败：': '儲存最近目錄失敗：',
      '读取媒体资产失败：': '讀取媒體資產失敗：',
      '清空最近播放失败：': '清空最近播放失敗：',
      '清空最近目录失败：': '清空最近目錄失敗：',
      '删除最近播放失败：': '刪除最近播放失敗：',
      '删除最近目录失败：': '刪除最近目錄失敗：',
      '刷新媒体资产失败：': '重新整理媒體資產失敗：',
      '清理缓存失败：': '清理快取失敗：',
      '清理媒体中心记录失败：': '清理媒體中心記錄失敗：',
      '清理学习数据失败：': '清理學習資料失敗：',
      '索引更新失败：': '索引更新失敗：',
      'Windows 外观能力检测失败：': 'Windows 外觀能力偵測失敗：',
      '应用窗口外观失败：': '套用視窗外觀失敗：',
      '重置设置失败：': '重設設定失敗：',
      '诊断执行失败：': '執行診斷失敗：',
      '导出诊断包失败：': '匯出診斷包失敗：',
      '脱敏诊断包已导出：': '已匯出去識別化診斷包：',
      '正在播放：': '正在播放：',
      '正在播放音频：': '正在播放音訊：',
      '正在打开：': '正在開啟：',
      '正在打开音频：': '正在開啟音訊：',
      '正在恢复：': '正在復原：',
      '继续播放：': '繼續播放：',
      '继续播放音频：': '繼續播放音訊：',
      '已暂停：': '已暫停：',
      '音频已暂停：': '音訊已暫停：',
      '字幕：': '字幕：',
      '封面：': '封面：',
      '歌词：': '歌詞：',
      '状态：': '狀態：',
      '上次更新时间：': '上次更新時間：',
      '上次错误：': '上次錯誤：',
      '已处理条目：': '已處理項目：',
      '续播于 ': '續播於 ',
      '已播放 ': '已播放 ',
      '当前最多同时保留 ': '目前最多同時保留 ',
      ' 个播放会话，': ' 個播放工作階段，',
      ' 个音频会话，': ' 個音訊工作階段，',
      '请先关闭或删除一个下边栏后再播放。': '請先關閉或刪除一個下方播放列後再播放。',
      '请先关闭或删除一个音频下边栏后再播放。': '請先關閉或刪除一個音訊播放列後再播放。',
      '无法播放「': '無法播放「',
      '」：strm 内容无效或读取失败': '」：strm 內容無效或讀取失敗',
      '已启动播放器（': '已啟動播放器（',
      '已启动音频播放器（': '已啟動音訊播放器（',
      ' 集）': ' 集）',
      ' 首）': ' 首）',
      '数据库维护完成，已创建 ': '資料庫維護完成，已建立 ',
      ' 个备份': ' 個備份',
      '尚不可证明': '無法確認',
      '不可用': '不可用',
      '可用': '可用',
      '请输入 {min}～{max} {unit}': '請輸入 {min}～{max} {unit}',
      '状态：{status}': '狀態：{status}',
      '已处理条目：{count}': '已處理項目：{count}',
      '上次更新时间：{time}': '上次更新時間：{time}',
      '上次错误：{error}': '上次錯誤：{error}',
      '目录、视频、STRM 和音频合计；系统最高 {max} 条': '目錄、影片、STRM 和音訊合計；系統最高 {max} 條',
      '视频、音频各自计算；系统最高 {max} 条': '影片、音訊分別計算；系統最高 {max} 條',
      '当前来源单独计算；系统最高 {max} 条': '目前來源單獨計算；系統最高 {max} 條',
      'Windows {major}.{minor}（内部版本 {build}）':
          'Windows {major}.{minor}（內部版本 {build}）',
      '透明效果：{transparency} · 高对比度：{contrast}':
          '透明效果：{transparency} · 高對比度：{contrast}',
      '排序：{mode} · {direction}': '排序：{mode} · {direction}',
      '未在当前服务器目录中找到「{name}」': '在目前伺服器目錄中找不到「{name}」',
      '{path}  ·  已播放 {duration}': '{path}  ·  已播放 {duration}',
      '已开启': '已開啟',
      '已关闭': '已關閉',
      '未开启': '未開啟',
      '尚未读取': '尚未讀取',
      '空闲': '閒置',
      '正在更新': '正在更新',
      '音乐': '音樂',
      '升序': '升冪',
      '降序': '降冪',
    },
    AppLanguage.japanese: <String, String>{
      '语言': '言語',
      '界面语言': '表示言語',
      '选择软件使用的显示语言；保存全部配置后立即切换。': 'ソフトウェアの表示言語を選択します。すべての設定を保存するとすぐに切り替わります。',
      '连接失败：': '接続に失敗しました：',
      '保存收藏失败：': 'お気に入りの保存に失敗しました：',
      '保存最近播放失败：': '最近の再生履歴の保存に失敗しました：',
      '保存最近目录失败：': '最近のフォルダーの保存に失敗しました：',
      '读取媒体资产失败：': 'メディア項目の読み込みに失敗しました：',
      '清空最近播放失败：': '最近の再生履歴の消去に失敗しました：',
      '清空最近目录失败：': '最近のフォルダーの消去に失敗しました：',
      '删除最近播放失败：': '最近の再生履歴の削除に失敗しました：',
      '删除最近目录失败：': '最近のフォルダーの削除に失敗しました：',
      '刷新媒体资产失败：': 'メディア項目の更新に失敗しました：',
      '清理缓存失败：': 'キャッシュの削除に失敗しました：',
      '清理媒体中心记录失败：': 'メディアセンター履歴の削除に失敗しました：',
      '清理学习数据失败：': '学習データの削除に失敗しました：',
      '索引更新失败：': 'インデックスの更新に失敗しました：',
      'Windows 外观能力检测失败：': 'Windows 外観機能の検出に失敗しました：',
      '应用窗口外观失败：': 'ウィンドウ外観の適用に失敗しました：',
      '重置设置失败：': '設定のリセットに失敗しました：',
      '诊断执行失败：': '診断の実行に失敗しました：',
      '导出诊断包失败：': '診断パッケージのエクスポートに失敗しました：',
      '脱敏诊断包已导出：': '匿名化した診断パッケージをエクスポートしました：',
      '正在播放：': '再生中：',
      '正在播放音频：': '音声を再生中：',
      '正在打开：': '開いています：',
      '正在打开音频：': '音声を開いています：',
      '正在恢复：': '復元中：',
      '继续播放：': '再生を再開：',
      '继续播放音频：': '音声の再生を再開：',
      '已暂停：': '一時停止中：',
      '音频已暂停：': '音声を一時停止中：',
      '字幕：': '字幕：',
      '封面：': 'カバー：',
      '歌词：': '歌詞：',
      '状态：': '状態：',
      '上次更新时间：': '最終更新日時：',
      '上次错误：': '前回のエラー：',
      '已处理条目：': '処理済み項目：',
      '续播于 ': '再開位置：',
      '已播放 ': '再生済み ',
      '当前最多同时保留 ': '同時に保持できるのは最大 ',
      ' 个播放会话，': ' 件の再生セッションです。',
      ' 个音频会话，': ' 件の音声セッションです。',
      '请先关闭或删除一个下边栏后再播放。': '再生する前に下部バーを閉じるか削除してください。',
      '请先关闭或删除一个音频下边栏后再播放。': '再生する前に音声バーを閉じるか削除してください。',
      '无法播放「': '「',
      '」：strm 内容无效或读取失败': '」を再生できません：strm の内容が無効か、読み込みに失敗しました',
      '已启动播放器（': 'プレーヤーを起動しました（',
      '已启动音频播放器（': '音声プレーヤーを起動しました（',
      ' 集）': ' 話）',
      ' 首）': ' 曲）',
      '数据库维护完成，已创建 ': 'データベースのメンテナンスが完了し、',
      ' 个备份': ' 個のバックアップを作成しました',
      '尚不可证明': '未確認',
      '不可用': '利用不可',
      '可用': '利用可能',
      '请输入 {min}～{max} {unit}': '{min}～{max} {unit}の範囲で入力してください',
      '状态：{status}': '状態：{status}',
      '已处理条目：{count}': '処理済み項目：{count}',
      '上次更新时间：{time}': '最終更新日時：{time}',
      '上次错误：{error}': '前回のエラー：{error}',
      '目录、视频、STRM 和音频合计；系统最高 {max} 条': 'フォルダー、動画、STRM、音声の合計。システム上限は {max} 件です',
      '视频、音频各自计算；系统最高 {max} 条': '動画と音声を個別に集計。システム上限は {max} 件です',
      '当前来源单独计算；系统最高 {max} 条': '現在のソースごとに集計。システム上限は {max} 件です',
      'Windows {major}.{minor}（内部版本 {build}）':
          'Windows {major}.{minor}（ビルド {build}）',
      '透明效果：{transparency} · 高对比度：{contrast}':
          '透明効果：{transparency} · ハイコントラスト：{contrast}',
      '排序：{mode} · {direction}': '並べ替え：{mode} · {direction}',
      '未在当前服务器目录中找到「{name}」': '現在のサーバーフォルダーに「{name}」が見つかりません',
      '{path}  ·  已播放 {duration}': '{path}  ·  再生済み {duration}',
      '已开启': 'オン',
      '已关闭': 'オフ',
      '未开启': 'オフ',
      '尚未读取': '未取得',
      '空闲': '待機中',
      '正在更新': '更新中',
      '音乐': '音楽',
      '升序': '昇順',
      '降序': '降順',
    },
    AppLanguage.english: <String, String>{
      '语言': 'Language',
      '界面语言': 'Display language',
      '选择软件使用的显示语言；保存全部配置后立即切换。':
          'Choose the display language. It changes after all settings are saved.',
      '连接失败：': 'Connection failed: ',
      '保存收藏失败：': 'Failed to save favorite: ',
      '保存最近播放失败：': 'Failed to save recent playback: ',
      '保存最近目录失败：': 'Failed to save recent directory: ',
      '读取媒体资产失败：': 'Failed to load media items: ',
      '清空最近播放失败：': 'Failed to clear recent playback: ',
      '清空最近目录失败：': 'Failed to clear recent directories: ',
      '删除最近播放失败：': 'Failed to delete recent playback: ',
      '删除最近目录失败：': 'Failed to delete recent directory: ',
      '刷新媒体资产失败：': 'Failed to refresh media items: ',
      '清理缓存失败：': 'Failed to clear cache: ',
      '清理媒体中心记录失败：': 'Failed to clear media center records: ',
      '清理学习数据失败：': 'Failed to clear learning data: ',
      '索引更新失败：': 'Failed to update index: ',
      'Windows 外观能力检测失败：': 'Failed to detect Windows appearance capabilities: ',
      '应用窗口外观失败：': 'Failed to apply window appearance: ',
      '重置设置失败：': 'Failed to reset settings: ',
      '诊断执行失败：': 'Failed to run diagnostics: ',
      '导出诊断包失败：': 'Failed to export diagnostics package: ',
      '脱敏诊断包已导出：': 'Redacted diagnostics package exported: ',
      '正在播放：': 'Playing: ',
      '正在播放音频：': 'Playing audio: ',
      '正在打开：': 'Opening: ',
      '正在打开音频：': 'Opening audio: ',
      '正在恢复：': 'Recovering: ',
      '继续播放：': 'Resume: ',
      '继续播放音频：': 'Resume audio: ',
      '已暂停：': 'Paused: ',
      '音频已暂停：': 'Audio paused: ',
      '字幕：': 'Subtitle: ',
      '封面：': 'Cover: ',
      '歌词：': 'Lyrics: ',
      '状态：': 'Status: ',
      '上次更新时间：': 'Last updated: ',
      '上次错误：': 'Last error: ',
      '已处理条目：': 'Processed items: ',
      '续播于 ': 'Resume at ',
      '已播放 ': 'Played ',
      '当前最多同时保留 ': 'You can keep up to ',
      ' 个播放会话，': ' playback sessions at once. ',
      ' 个音频会话，': ' audio sessions at once. ',
      '请先关闭或删除一个下边栏后再播放。':
          'Close or delete a playback bar before playing another item.',
      '请先关闭或删除一个音频下边栏后再播放。':
          'Close or delete an audio bar before playing another item.',
      '无法播放「': 'Unable to play "',
      '」：strm 内容无效或读取失败': '": the strm content is invalid or could not be read',
      '已启动播放器（': 'Player started (',
      '已启动音频播放器（': 'Audio player started (',
      ' 集）': ' episodes)',
      ' 首）': ' tracks)',
      '数据库维护完成，已创建 ': 'Database maintenance completed; created ',
      ' 个备份': ' backups',
      '尚不可证明': 'unconfirmed',
      '不可用': 'unavailable',
      '可用': 'available',
      '请输入 {min}～{max} {unit}': 'Enter a value from {min} to {max} {unit}',
      '状态：{status}': 'Status: {status}',
      '已处理条目：{count}': 'Processed items: {count}',
      '上次更新时间：{time}': 'Last updated: {time}',
      '上次错误：{error}': 'Last error: {error}',
      '目录、视频、STRM 和音频合计；系统最高 {max} 条':
          'Combined folders, videos, STRM files, and audio; system maximum: {max}',
      '视频、音频各自计算；系统最高 {max} 条':
          'Calculated separately for video and audio; system maximum: {max}',
      '当前来源单独计算；系统最高 {max} 条': 'Calculated per source; system maximum: {max}',
      'Windows {major}.{minor}（内部版本 {build}）':
          'Windows {major}.{minor} (build {build})',
      '透明效果：{transparency} · 高对比度：{contrast}':
          'Transparency: {transparency} · High contrast: {contrast}',
      '排序：{mode} · {direction}': 'Sort: {mode} · {direction}',
      '未在当前服务器目录中找到「{name}」':
          'Could not find "{name}" in the current server directory',
      '{path}  ·  已播放 {duration}': '{path}  ·  Played {duration}',
      '已开启': 'On',
      '已关闭': 'Off',
      '未开启': 'Off',
      '尚未读取': 'Not loaded',
      '空闲': 'Idle',
      '正在更新': 'Updating',
      '音乐': 'Music',
      '升序': 'Ascending',
      '降序': 'Descending',
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
