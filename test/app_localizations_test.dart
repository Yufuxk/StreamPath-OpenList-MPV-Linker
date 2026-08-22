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
}
