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
}
