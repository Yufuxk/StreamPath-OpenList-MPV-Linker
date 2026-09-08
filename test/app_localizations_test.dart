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
      AppLanguage.simplifiedChinese: 'ISO 远程播放系统',
      AppLanguage.traditionalChinese: 'ISO 遠端播放系統',
      AppLanguage.japanese: 'ISO リモート再生システム',
      AppLanguage.english: 'ISO remote playback system',
    };
    const expectedCancelling = <AppLanguage, String>{
      AppLanguage.simplifiedChinese: '正在取消…',
      AppLanguage.traditionalChinese: '正在取消…',
      AppLanguage.japanese: 'キャンセルしています…',
      AppLanguage.english: 'Cancelling…',
    };

    for (final language in AppLanguage.values) {
      final localizations = AppLocalizations(language);
      expect(localizations.text('ISO 远程播放系统'), expectedTitles[language]);
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

  test('本地蓝光续播、诊断与索引运行时文案覆盖四种语言', () {
    const exactSources = <String>[
      '本地蓝光内容已变更，已忽略旧续播位置',
      '可继续上次播放的 Title，也可以从头打开菜单或主标题。',
      '从头打开菜单',
      '继续上次标题',
      '无法确认对应蓝光播放器进程，未删除播放会话',
      '本地蓝光播放服务已关闭',
      '本地蓝光内容已变更，请从头播放',
      '未配置播放器路径，请先在「设置」中配置',
      '公开设置接口可访问',
      '公开设置接口未返回 OpenList/AList JSON envelope',
      '视频 SQLite',
      '音频 SQLite',
      '音频进度数据库未初始化',
      '目录缓存',
      'Hive 已打开',
      'Hive 尚未初始化',
      '当前未连接，未执行网络检查',
      '根目录认证请求成功',
      '播放器路径',
      '播放器文件不存在',
      '播放器文件存在',
      '播放器可从 PATH 解析',
      'PATH 中未找到播放器',
      '无法完成 PATH 解析检查',
      '没有活动 MPV 会话',
      '只读属性查询成功',
      '活动会话的 IPC 查询失败',
      '自动恢复未启用',
      '后台地址无效',
      '数据目录写入',
      '创建、刷新与删除测试文件成功',
      'PRAGMA quick_check 通过',
      '完整性检查报告异常',
      '配置与迁移',
      '配置版本、迁移记录或凭据存在异常',
      '配置版本有效，迁移与凭据状态正常',
      '请先配置有效的 OpenList/AList 后台地址',
      '普通用户 Token 无效，请填写具有搜索权限的最小权限 Token',
      'OpenList/AList 返回了无法识别的索引状态',
      '索引能力探测异常，请检查后台地址和网络连接',
      '索引更新请求正在处理，请勿重复提交',
      'OpenList/AList 正在更新索引，本次请求已跳过',
      '索引更新已提交，OpenList/AList 将在后台执行',
      '索引更新请求异常，请检查后台地址和网络连接',
      '无法解析服务端最大索引深度；已禁止提交索引更新',
      '未配置普通用户账号密码',
      '未配置管理员账号密码',
      '登录成功',
      '普通用户账号启用了 2FA，请填写独立的普通用户 Token',
      '管理员账号启用了 2FA，请填写独立的管理员 Token',
      '普通用户登录请求超过总时间限制',
      '管理员登录请求超过总时间限制',
    ];
    const dynamicSources = <String>[
      '读取本地蓝光续播记录失败：disk error',
      '本地蓝光已暂停：DISC.iso',
      '正在播放本地蓝光：DISC.iso',
      '继续播放本地蓝光：DISC.iso',
      '重新连接失败：network error',
      '无法启动播放器「mpv.exe」：文件不存在或路径错误',
      '播放器启动失败：process error',
      '播放器文件不存在：mpv.exe',
      '公开设置接口返回 code 500：backend error',
      '公开设置接口返回 HTTP 500',
      '认证或网络请求失败：network error',
      '公开设置接口请求失败：network error',
      '写入检查失败：access denied',
      '索引搜索失败：backend error',
      '索引状态不可用：当前后台缺少 /api/admin/index/progress 端点',
      '读取索引状态失败：backend error',
      '无法读取索引状态：backend error',
      '索引增量更新不可用：当前后台缺少 /api/admin/index/update 端点；不会回退为全量构建',
      '索引更新未启动：backend error',
      '无法读取当前用户根路径：backend error',
      '无法读取最大索引深度：backend error；已禁止提交索引更新',
      '读取 OpenList/AList 能力失败：backend error',
      '普通用户登录请求异常：backend error',
      '管理员登录请求异常：backend error',
      '普通用户登录失败：bad credentials',
      '管理员登录失败：bad credentials',
    ];

    for (final language in const [AppLanguage.japanese, AppLanguage.english]) {
      final localizations = AppLocalizations(language);
      for (final source in [...exactSources, ...dynamicSources]) {
        expect(
          localizations.text(source),
          isNot(source),
          reason: '${language.name}: $source',
        );
      }
    }

    const english = AppLocalizations(AppLanguage.english);
    for (final source in [...exactSources, ...dynamicSources]) {
      expect(
        english.text(source),
        isNot(contains(RegExp(r'[一-龥]'))),
        reason: source,
      );
    }
  });
}
