import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/core/utils/extension_filter.dart';
import 'package:streampath/core/utils/file_sort.dart';
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/domain/services/openlist_api_client.dart';
import 'package:streampath/features/cache_control/models/cache_policy_config.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/localization/app_translation_catalog.dart';
import 'package:streampath/presentation/widgets/playback_bar.dart';

void main() {
  test('三种目标语言目录键、模板参数一致且英文无中文残留', () {
    final placeholders = RegExp(r'\{(\w+)\}');
    for (final catalog in [
      englishTranslations,
      japaneseTranslations,
      traditionalChineseTranslations,
    ]) {
      expect(catalog.keys.toSet(), englishTranslations.keys.toSet());
      for (final entry in catalog.entries) {
        expect(entry.value, isNotEmpty, reason: entry.key);
        expect(
          placeholders.allMatches(entry.value).map((m) => m[1]).toSet(),
          placeholders.allMatches(entry.key).map((m) => m[1]).toSet(),
          reason: entry.key,
        );
      }
    }
    for (final entry in englishTranslations.entries) {
      expect(
        entry.value,
        isNot(contains(RegExp(r'[\u4e00-\u9fff]'))),
        reason: entry.key,
      );
    }
  });

  test('真实后台能力提示的版本与端点保留且四语言覆盖', () {
    for (final version in [null, '4.1.9']) {
      final capabilities = OpenListCapabilities.unknown(version: version);
      for (final feature in ['索引搜索', '索引状态', '索引增量更新', '存储恢复']) {
        final source = capabilities.unavailableMessage(
          feature,
          '/api/fs/search',
        );
        for (final language in AppLanguage.values) {
          final translated = AppLocalizations(language).text(source);
          expect(translated, contains('/api/fs/search'));
          if (version != null) expect(translated, contains(version));
          if (language == AppLanguage.english) {
            expect(translated, isNot(contains(RegExp(r'[\u4e00-\u9fff]'))));
          }
        }
      }
    }
  });

  test('排序与缓存模式的实际枚举标签均可翻译', () {
    for (final language in [
      AppLanguage.traditionalChinese,
      AppLanguage.japanese,
      AppLanguage.english,
    ]) {
      final l10n = AppLocalizations(language);
      for (final source in [
        ...FileSortMode.values.map((v) => v.label),
        ...FileSortDirection.values.map((v) => v.label),
        ...CachePolicyMode.values.map((v) => v.label),
      ]) {
        expect(
          l10n.text(source),
          isNot(source),
          reason: '${language.name}: $source',
        );
      }
    }
  });

  test('真实后缀校验错误覆盖四语言并保留用户输入', () {
    for (final input in ['.ass，.mkv', '{.ass}', '.ass,,.mkv', '.原版字幕']) {
      String? source;
      try {
        parseHiddenExtensions(input);
      } on FormatException catch (error) {
        source = error.message;
      }
      expect(source, isNotNull);
      for (final language in AppLanguage.values) {
        final result = AppLocalizations(language).text(source!);
        if (language == AppLanguage.simplifiedChinese) {
          expect(result, source);
        }
        if (language == AppLanguage.english) {
          expect(result, isNot(source));
          if (input == '.原版字幕') expect(result, contains('.原版字幕'));
        }
      }
    }
  });

  test('运行时完整模板与嵌套应用错误保留参数', () {
    const templates = <String>[
      "保存浏览位置失败：{error}",
      "无法识别的文件后缀：「{extension}」（请使用英文逗号分隔，例如：.ass, .mkv）",
      "媒体库版本 {version} 高于当前支持版本 {supported}，已禁止降级写入",
      "初始化播放进度数据库失败：{error}",
      "保存播放进度失败：{error}",
      "读取播放进度失败：{error}",
      "保存临时播放点失败：{error}",
      "读取临时播放点失败：{error}",
      "删除播放进度失败：{error}",
      "删除临时播放点失败：{error}",
      "清空播放进度失败：{error}",
      "清理过期播放进度失败：{error}",
      "SQLite 完整性检查失败：{error}",
      "SQLite 非破坏性维护失败：{error}",
      "{error}；恢复备份也不可用：{backupError}",
      "配置版本 {version} 高于当前支持版本 {supported}",
      "配置版本 {version} 高于当前支持版本",
      "配置文件损坏：{error}",
      "读取配置文件失败：{error}",
      "配置字段值无效：{error}",
      "保存配置文件失败：{error}",
      "重置配置文件失败：{error}",
      "文件内容超过 {limit} 字节限制",
      "不支持的网络协议：{scheme}",
      "服务器重定向次数超过 {count} 次",
      "连接服务器超时（{timeout}）",
      "无法连接到服务器：{error}",
      "认证失败：请检查账号与密码（HTTP {code}）",
      "服务器返回错误（HTTP {code}）",
      "网络请求失败：{error}",
      "服务器响应不是有效的 XML：{error}",
      "拒绝清理非应用数据目录：{path}",
      "拒绝清理无效目录：{path}",
      "缓存目录不在应用数据目录内：{path}",
      "拒绝删除缓存目录外的目标：{path}",
      "拒绝删除重解析点：{path}",
      "拒绝删除包含重解析点的目录：{path}",
      "播放器启动失败：{error}（请检查可执行文件与系统 PATH）",
      "文件不存在：{path}",
      "[会话 {sessionId}] {message}",
      "检测到 MPV 播放失败，正在恢复链接（{attempt}/3）…",
      "第三次自动恢复失败：{message}，已保留继续播放记录",
      "{message}，已停止自动恢复并保留继续播放记录",
      "链接已恢复，但重新启动播放器失败：{message}",
      "mpv IPC 请求超时: {command}",
      "mpv IPC 写入失败: {error}",
      "{command} 失败: Windows error {code}",
      "mpv IPC 响应缺少 request_id={requestId}",
      "mpv 错误: {error}",
      "OpenList/AList 存储刷新失败：{error}",
      "网络带宽不足以流畅播放（持续缓冲：缓存跟不上播放速度，实时速度 {speed}KB/s）。已加大缓冲目标，若仍卡顿请降低画质或检查网络。",
      "网络带宽不足以流畅播放（实时速度 {speed}KB/s，需要 {required}KB/s 以上）。已加大缓冲，若持续卡顿请降低画质或检查网络。",
      "FormatException: {message}",
      "NetworkException: {message}",
      "ParseException: {message}",
      "ConfigException: {message}",
      "PlayerLaunchException: {message}",
      "StorageException: {message}",
    ];
    const arguments = <String, Object?>{
      'error': '播放器路径不能为空',
      'backupError': '配置根节点必须是 JSON 对象',
      'message': '服务器证书不受信任',
      'extension': '.原版字幕',
      'version': 99,
      'supported': 12,
      'limit': 1024,
      'count': 5,
      'scheme': 'ftp',
      'timeout': '0:00:10.000000',
      'code': 401,
      'path': r'C:\字幕：原版\影片 第 2 次.mkv',
      'sessionId': 'session-42',
      'attempt': 2,
      'command': 'get_property',
      'requestId': 7,
      'speed': 1000,
      'required': 4883,
    };
    for (final language in AppLanguage.values) {
      final l10n = AppLocalizations(language);
      final values = {
        ...arguments,
        for (final name in ['error', 'backupError', 'message'])
          name: l10n.text(arguments[name]! as String),
      };
      for (final template in templates) {
        final source = const AppLocalizations(
          AppLanguage.simplifiedChinese,
        ).format(template, arguments);
        expect(
          l10n.text(source),
          l10n.format(template, values),
          reason: '${language.name}: $template',
        );
      }
      final source = '[会话 session-42] 第三次自动恢复失败：服务器证书不受信任，已保留继续播放记录';
      final result = l10n.text(source);
      expect(result, contains('session-42'));
      if (language == AppLanguage.english) {
        expect(
          result,
          '[Session session-42] The third automatic recovery attempt failed: The server certificate is not trusted. Resume history was retained',
        );
      }
      const detail = 'Remote server detail: 原始内容';
      expect(l10n.text('网络请求失败：$detail'), contains(detail));
      expect(l10n.text(r'C:\原版\影片 第 2 次.mkv'), r'C:\原版\影片 第 2 次.mkv');
    }
  });

  testWidgets('播放栏在切换语言后翻译播放与暂停悬浮提示', (tester) async {
    for (final language in AppLanguage.values) {
      final l10n = AppLocalizations(language);
      for (final tooltip in ['继续播放', '暂停']) {
        await tester.pumpWidget(
          MaterialApp(
            locale: language.locale,
            supportedLocales: AppLanguage.values.map((v) => v.locale),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: Scaffold(
              body: PlaybackBar(
                title: 'DISC.mkv',
                dirLabel: 'Media',
                icon: Icons.play_arrow,
                tooltip: tooltip,
                deleting: false,
                onPressed: () {},
                onDelete: () {},
                onSecondaryTapDown: (_) {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byTooltip(l10n.text(tooltip)), findsOneWidget);
      }
    }
  });
}
