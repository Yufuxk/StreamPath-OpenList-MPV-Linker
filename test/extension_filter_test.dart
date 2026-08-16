import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/core/utils/extension_filter.dart';
import 'package:streampath/data/models/web_dav_file.dart';

/// 隐藏后缀解析/格式化工具测试。
void main() {
  group('parseHiddenExtensions 解析', () {
    test('标准格式使用英文逗号分隔', () {
      expect(parseHiddenExtensions('.ass, .mp4, .mp3'), [
        '.ass',
        '.mp4',
        '.mp3',
      ]);
    });

    test('英文逗号两侧允许空白且后缀可省略点', () {
      expect(parseHiddenExtensions('  .ass,  .mp4  ,mp3 '), [
        '.ass',
        '.mp4',
        '.mp3',
      ]);
    });

    test('大小写不敏感，统一转为小写', () {
      expect(parseHiddenExtensions('.ASS, .Mp4'), ['.ass', '.mp4']);
    });

    test('重复项去重', () {
      expect(parseHiddenExtensions('.ass, .ass, ass'), ['.ass']);
    });

    test('空输入返回空列表', () {
      expect(parseHiddenExtensions(''), isEmpty);
      expect(parseHiddenExtensions('   '), isEmpty);
    });

    test('中文逗号、空格分隔和旧花括号格式均拒绝', () {
      expect(() => parseHiddenExtensions('.ass，.mkv'), throwsFormatException);
      expect(() => parseHiddenExtensions('.ass .mkv'), throwsFormatException);
      expect(
        () => parseHiddenExtensions('{".ass", ".mkv"}'),
        throwsFormatException,
      );
    });

    test('非法 token 抛 FormatException（含 token 信息）', () {
      expect(
        () => parseHiddenExtensions('.ass, bad/token'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('bad/token'),
          ),
        ),
      );
    });
  });

  group('normalizeExtension 规范化', () {
    test('补点与小写化', () {
      expect(normalizeExtension('MP4'), '.mp4');
      expect(normalizeExtension('.MKV'), '.mkv');
    });

    test('非法输入返回 null', () {
      expect(normalizeExtension(''), isNull);
      expect(normalizeExtension('  '), isNull);
      expect(normalizeExtension('a/b'), isNull);
      expect(normalizeExtension('.a ss'), isNull, reason: '含内部空白非法');
      expect(normalizeExtension('.a.b'), isNull, reason: r'点号不在 \w 内');
    });
  });

  group('formatHiddenExtensions 格式化', () {
    test('空列表返回空字符串', () {
      expect(formatHiddenExtensions(const []), '');
    });

    test('非空列表格式化为英文逗号分隔文本', () {
      expect(formatHiddenExtensions(const ['.ass', '.mp4']), '.ass, .mp4');
    });

    test('parse ↔ format 往返一致', () {
      const exts = ['.ass', '.mp4', '.mp3'];
      expect(parseHiddenExtensions(formatHiddenExtensions(exts)), exts);
    });
  });

  group('shouldHideFile 过滤判定', () {
    WebDavFile file(String name, {bool isDirectory = false}) =>
        WebDavFile(name: name, href: '/dav/$name', isDirectory: isDirectory);

    test('普通文件后缀命中即隐藏', () {
      expect(shouldHideFile(file('01.ass'), {'.ass'}), isTrue);
      expect(
        shouldHideFile(file('01.SRT'), {'.srt'}),
        isTrue,
        reason: '大小写不敏感',
      );
    });

    test('未命中的后缀不隐藏', () {
      expect(shouldHideFile(file('01.ass'), {'.mp4'}), isFalse);
      expect(shouldHideFile(file('01.ass'), {}), isFalse);
    });

    test('功能关闭时保留规则但不隐藏文件', () {
      expect(shouldHideFile(file('01.ass'), {'.ass'}, enabled: false), isFalse);
    });

    test('目录永不过滤（即使目录名含点）', () {
      // 目录名含点很常见：1.EpisodeData / Star.Wars.2005
      expect(
        shouldHideFile(
          WebDavFile(
            name: '1.EpisodeData',
            href: '/dav/1.EpisodeData',
            isDirectory: true,
          ),
          {'.episodedata'},
        ),
        isFalse,
      );
      expect(
        shouldHideFile(
          WebDavFile(
            name: 'Star.Wars.2005',
            href: '/dav/Star.Wars.2005',
            isDirectory: true,
          ),
          {'.2005'},
        ),
        isFalse,
      );
    });

    test('「返回上级」条目永不过滤', () {
      expect(
        shouldHideFile(
          WebDavFile(
            name: '.',
            href: '/dav/',
            isDirectory: true,
            isSelfEntry: true,
          ),
          {'.'},
        ),
        isFalse,
      );
    });
  });
}
