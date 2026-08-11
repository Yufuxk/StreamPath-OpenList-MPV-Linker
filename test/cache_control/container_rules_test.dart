import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/features/cache_control/utils/container_rules.dart';

/// isTsContainerUrl 单元测试（阶段二：URL 兼容性）。
void main() {
  group('TS 容器判定（基于 URI path）', () {
    test('基础扩展名（大小写）', () {
      expect(isTsContainerUrl('http://h/dav/movie.ts'), isTrue);
      expect(isTsContainerUrl('http://h/dav/movie.m2ts'), isTrue);
      expect(isTsContainerUrl('http://h/dav/MOVIE.M2TS'), isTrue);
      expect(isTsContainerUrl('http://h/dav/movie.Ts'), isTrue);
    });

    test('查询参数与片段不干扰判定', () {
      expect(isTsContainerUrl('http://h/dav/video.ts?token=abc'), isTrue);
      expect(
        isTsContainerUrl('http://h/dav/video.m2ts?download=1&x=2'),
        isTrue,
      );
      expect(isTsContainerUrl('http://h/dav/video.ts#part2'), isTrue);
      expect(isTsContainerUrl('http://h/dav/video.ts?token=abc#frag'), isTrue);
    });

    test('URL 编码路径', () {
      // %2E 解码后为 '.'。
      expect(isTsContainerUrl('http://h/dav/video%2Ets'), isTrue);
      expect(isTsContainerUrl('http://h/dav/video%2em2ts?x=1'), isTrue);
    });

    test('非 TS 扩展名不误判', () {
      expect(isTsContainerUrl('http://h/dav/movie.mkv'), isFalse);
      expect(isTsContainerUrl('http://h/dav/movie.mp4'), isFalse);
      expect(isTsContainerUrl('http://h/dav/movie.txt'), isFalse);
      expect(isTsContainerUrl('http://h/dav/movie.tsx'), isFalse);
      // 目录名含 .ts 但不是文件扩展名。
      expect(isTsContainerUrl('http://h/dav/ts/readme.md'), isFalse);
    });

    test('无法解析的 URL 按原始字符串判定', () {
      expect(isTsContainerUrl('not a url.ts'), isTrue);
      expect(isTsContainerUrl('movie.m2ts'), isTrue);
      expect(isTsContainerUrl(''), isFalse);
    });
  });
}
