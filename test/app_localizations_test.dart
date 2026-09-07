import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/localization/app_text.dart';

void main() {
  test('四种语言使用稳定 Locale 与原生选项名称', () {
    expect(AppLanguage.simplifiedChinese.locale.toLanguageTag(), 'zh-Hans-CN');
    expect(AppLanguage.traditionalChinese.locale.toLanguageTag(), 'zh-Hant-TW');
    expect(AppLanguage.japanese.locale.toLanguageTag(), 'ja-JP');
    expect(AppLanguage.english.locale.toLanguageTag(), 'en-US');
    expect(AppLanguage.values.map((language) => language.nativeLabel), [
      '简体中文',
      '繁體中文',
      '日本語',
      'English',
    ]);
  });

  testWidgets('项目文案与 Flutter 内置控件同时切换为英文', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('en', 'US'),
        supportedLocales: [Locale('zh', 'CN'), Locale('en', 'US')],
        localizationsDelegates: [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(body: AppText('基础设置')),
      ),
    );

    expect(find.text('Basic settings'), findsOneWidget);
    final context = tester.element(find.byType(Scaffold));
    expect(MaterialLocalizations.of(context).okButtonLabel, 'OK');
  });

  test('动态状态前缀可在保留文件名时翻译', () {
    const english = AppLocalizations(AppLanguage.english);
    expect(english.text('正在播放：movie.mkv'), 'Playing: movie.mkv');
  });

  test('OpenList 动态能力摘要按模板翻译且保留版本与状态', () {
    const template =
        '后台 {version} 能力：基础 WebDAV {webDav}；索引搜索 {indexSearch}；索引更新 {indexUpdate}；存储恢复 {storageRecovery}。尚不可证明的功能会按端点响应失败关闭。';
    const english = AppLocalizations(AppLanguage.english);

    expect(
      english.format(template, {
        'version': 'v4.1.4',
        'webDav': english.text('可用'),
        'indexSearch': english.text('可用'),
        'indexUpdate': english.text('不可用'),
        'storageRecovery': english.text('尚不可证明'),
      }),
      'Backend v4.1.4 capabilities: Basic WebDAV available; index search '
      'available; index update unavailable; storage recovery unconfirmed. '
      'Features that cannot be confirmed are disabled when their endpoints '
      'fail to respond.',
    );
  });

  test('动态设置状态与数值模板可切换四种语言', () {
    const english = AppLocalizations(AppLanguage.english);
    const japanese = AppLocalizations(AppLanguage.japanese);
    const traditional = AppLocalizations(AppLanguage.traditionalChinese);

    expect(
      english.format('状态：{status}', {'status': english.text('正在更新')}),
      'Status: Updating',
    );
    expect(japanese.format('已处理条目：{count}', {'count': 42}), '処理済み項目：42');
    expect(
      traditional.format('上次更新时间：{time}', {'time': '2026-08-24'}),
      '上次更新時間：2026-08-24',
    );
  });

  test('英文动态界面文案不残留简体中文固定文本', () {
    const english = AppLocalizations(AppLanguage.english);
    final samples = <String>[
      english.text('保存收藏失败：disk error'),
      english.text('音频已暂停：song.flac'),
      english.text('继续播放 ISO：DISC.iso'),
      english.text('当前最多同时保留 4 个音频会话，请先关闭或删除一个音频下边栏后再播放。'),
      english.text('数据库维护完成，已创建 2 个备份'),
      english.format('排序：{mode} · {direction}', {
        'mode': english.text('名称'),
        'direction': english.text('升序'),
      }),
      english.format('Windows {major}.{minor}（内部版本 {build}）', {
        'major': 10,
        'minor': 0,
        'build': 26100,
      }),
      english.format('未在当前服务器目录中找到「{name}」', {'name': 'movie.mkv'}),
    ];

    expect(samples, everyElement(isNot(contains(RegExp(r'[一-龥]')))));
  });

  test('ISO 流式播放进度、取消与错误文案覆盖四种语言', () {
    const expectedTitles = <AppLanguage, String>{
      AppLanguage.simplifiedChinese: 'ISO 远程播放测试',
      AppLanguage.traditionalChinese: 'ISO 遠端播放測試',
      AppLanguage.japanese: 'ISO リモート再生テスト',
      AppLanguage.english: 'ISO remote playback test',
    };
    const expectedCancelling = <AppLanguage, String>{
      AppLanguage.simplifiedChinese: '正在取消…',
      AppLanguage.traditionalChinese: '正在取消…',
      AppLanguage.japanese: 'キャンセルしています…',
      AppLanguage.english: 'Cancelling…',
    };

    for (final language in AppLanguage.values) {
      final localizations = AppLocalizations(language);
      expect(localizations.text('ISO 远程播放测试'), expectedTitles[language]);
      expect(localizations.text('正在取消…'), expectedCancelling[language]);
      expect(localizations.text('正在启动 ISO Bridge…'), isNotEmpty);
      expect(localizations.text('正在探测 ISO 流式读取…'), isNotEmpty);
      expect(localizations.text('已取消 ISO 播放'), isNotEmpty);
      expect(localizations.text('ISO 流式播放失败：{message}'), isNotEmpty);
      expect(localizations.text('ISO 播放流提前结束'), isNotEmpty);
      expect(
        localizations.format(
          '{path}  ·  第 {episode}/{total} 集  ·  已播放 {duration}',
          {'path': 'BD', 'episode': 2, 'total': 4, 'duration': '02:03'},
        ),
        contains('2'),
      );
      expect(localizations.text('还没有收藏 ISO'), isNotEmpty);
      final rangeError = localizations.text('当前 WebDAV 源不支持 ISO 流式随机读取');
      if (language != AppLanguage.simplifiedChinese) {
        expect(rangeError, isNot('当前 WebDAV 源不支持 ISO 流式随机读取'));
      }
    }
  });

  test('本地存储与蓝光菜单新增文案覆盖四种语言', () {
    const sources = <String>[
      '网络存储',
      '本地存储',
      '添加本地文件夹',
      '选择本地文件夹',
      '本地蓝光菜单需要使用 MPV 播放器',
      '请选择本地 Blu-ray 的播放方式。菜单失败时不会自动切换模式。',
      '蓝光菜单播放',
      '主标题模式',
      '本地蓝光路径不存在或不可访问',
    ];

    for (final language in AppLanguage.values) {
      final localizations = AppLocalizations(language);
      for (final source in sources) {
        final translated = localizations.text(source);
        expect(translated, isNotEmpty);
        if (language != AppLanguage.simplifiedChinese) {
          expect(translated, isNot(source));
        }
      }
    }
    expect(
      const AppLocalizations(
        AppLanguage.english,
      ).format('已挂载 {count} 个本地文件夹', {'count': 2}),
      '2 local folders mounted',
    );
  });
}
