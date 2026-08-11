import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/core/utils/url_utils.dart';

void main() {
  group('joinUrl / cacheKeyFor / resolveHref', () {
    test('joinUrl 拼接并编码路径段', () {
      expect(
        joinUrl('http://h:5244/dav', '电影/动作'),
        'http://h:5244/dav/%E7%94%B5%E5%BD%B1/%E5%8A%A8%E4%BD%9C',
      );
      expect(joinUrl('http://h', ''), 'http://h');
      expect(joinUrl('http://h/', '/a b.mp4'), 'http://h/a%20b.mp4');
    });

    test('cacheKeyFor 去尾部斜杠', () {
      expect(
        cacheKeyFor(baseUrl: 'http://h/dav', path: '电影/'),
        'http://h/dav/%E7%94%B5%E5%BD%B1',
      );
    });

    test('cacheKeyFor 长中文路径使用固定长度键且保持稳定', () {
      const path =
          'QuarkFilmsData_BASE/0.MoviesData/'
          '2013 -《剧场版 我们仍未知道那天所看见的花的名字。》';
      final key = cacheKeyFor(
        baseUrl: 'http://192.168.2.124:5244/dav',
        path: path,
      );
      final sameKey = cacheKeyFor(
        baseUrl: 'http://192.168.2.124:5244/dav',
        path: path,
      );
      final otherKey = cacheKeyFor(
        baseUrl: 'http://192.168.2.124:5244/dav',
        path: '$path/《Specials》',
      );

      expect(key, startsWith('sha256:'));
      expect(key.length, lessThanOrEqualTo(255));
      expect(sameKey, key);
      expect(otherKey, isNot(key));
    });

    test('cacheKeyFor 按账号命名空间隔离且不暴露用户名', () {
      final alice = cacheKeyFor(
        baseUrl: 'http://h/dav',
        path: 'movies',
        namespace: 'alice',
      );
      final bob = cacheKeyFor(
        baseUrl: 'http://h/dav',
        path: 'movies',
        namespace: 'bob',
      );

      expect(alice, startsWith('sha256:'));
      expect(bob, startsWith('sha256:'));
      expect(alice, isNot(bob));
      expect(alice, isNot(contains('alice')));
    });

    test('resolveHref 相对补全、绝对保留、编码不二次编码', () {
      expect(
        resolveHref('http://h:5244/dav', '/dav/a%20b.mp4'),
        'http://h:5244/dav/a%20b.mp4',
      );
      expect(
        resolveHref('http://h:5244/dav', 'folder/a%20b.mp4'),
        'http://h:5244/dav/folder/a%20b.mp4',
      );
      expect(
        resolveHref('http://h', 'http://other/x.mp4'),
        'http://other/x.mp4',
      );
    });
  });

  group('embedCredentials URL 内嵌凭据', () {
    test('普通账号密码', () {
      expect(
        embedCredentials('http://h:5244/dav/a.mp4', 'alice', 'secret'),
        'http://alice:secret@h:5244/dav/a.mp4',
      );
    });

    test('特殊字符百分号编码（@ : #）', () {
      expect(
        embedCredentials('http://h/a.mp4', 'user@x.com', 'p@ss:word#1'),
        'http://user%40x.com:p%40ss%3Aword%231@h/a.mp4',
      );
    });

    test('空密码保留用户名后的冒号以兼容旧版 MPV', () {
      expect(
        embedCredentials('http://h/a.mp4', 'guest', ''),
        'http://guest:@h/a.mp4',
      );
    });

    test('已含凭据或地址非法时原样返回', () {
      expect(
        embedCredentials('http://old:pw@h/a.mp4', 'new', 'pw2'),
        'http://old:pw@h/a.mp4',
      );
      expect(embedCredentials('not-a-url', 'u', 'p'), 'not-a-url');
    });
  });

  group('stripUserInfo', () {
    test('剥离凭据', () {
      expect(
        stripUserInfo('http://u:p@h:5244/dav/a.mp4'),
        'http://h:5244/dav/a.mp4',
      );
    });

    test('无凭据时原样', () {
      expect(
        stripUserInfo('http://h:5244/dav/a.mp4'),
        'http://h:5244/dav/a.mp4',
      );
    });
  });
  group('isSameOrigin 同源判定', () {
    test('同源（scheme/host/port 一致）为 true', () {
      expect(
        isSameOrigin(
          'http://nas.example.com:5244/dav',
          'http://nas.example.com:5244/dav/movie.mkv',
        ),
        isTrue,
      );
      expect(
        isSameOrigin(
          'https://nas.example.com/dav',
          'https://nas.example.com/other.mkv',
        ),
        isTrue,
      );
    });

    test('默认端口归一（无显式端口 vs 默认端口）为 true', () {
      expect(
        isSameOrigin(
          'http://nas.example.com/dav',
          'http://nas.example.com:80/v.mkv',
        ),
        isTrue,
      );
      expect(
        isSameOrigin(
          'https://nas.example.com/dav',
          'https://nas.example.com:443/v.mkv',
        ),
        isTrue,
      );
    });

    test('不同 host / scheme / port 为 false', () {
      expect(
        isSameOrigin(
          'http://nas.example.com/dav',
          'http://evil.example.com/v.mkv',
        ),
        isFalse,
      );
      expect(
        isSameOrigin(
          'http://nas.example.com/dav',
          'https://nas.example.com/v.mkv',
        ),
        isFalse,
      );
      expect(
        isSameOrigin(
          'http://nas.example.com:5244/dav',
          'http://nas.example.com:8080/v.mkv',
        ),
        isFalse,
      );
      expect(
        isSameOrigin('http://nas.example.com/dav', 'file:///C:/secret.mkv'),
        isFalse,
      );
    });
  });
}
