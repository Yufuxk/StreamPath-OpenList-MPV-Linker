import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/data/remote/webdav_xml_parser.dart';

void main() {
  const parser = WebDavXmlParser();

  group('WebDavXmlParser 解析', () {
    test('标准 DAV: 命名空间响应解析文件与目录', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/movies/</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>movies</d:displayname>
        <d:resourcetype><d:collection/></d:resourcetype>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/movies/movie.mp4</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>movie.mp4</d:displayname>
        <d:getcontentlength>1073741824</d:getcontentlength>
        <d:getlastmodified>Wed, 26 Jun 2024 12:00:00 GMT</d:getlastmodified>
        <d:getcontenttype>video/mp4</d:getcontenttype>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>''';

      final files = parser.parse(xml, requestUrl: 'http://host/dav/movies');
      expect(files, hasLength(2));

      // 目录优先排序
      expect(files.first.isDirectory, isTrue);
      expect(files.first.name, 'movies');
      expect(files.first.size, 0);

      final video = files.last;
      expect(video.name, 'movie.mp4');
      expect(video.isVideo, isTrue);
      expect(video.size, 1073741824);
      expect(video.modified, DateTime.utc(2024, 6, 26, 12));
      expect(video.contentType, 'video/mp4');
    });

    test('非标准命名空间前缀（D:）与大小写不敏感匹配', () {
      const xml = '''
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/a.mp4</D:href>
    <D:propstat><D:prop>
      <D:displayname>a.mp4</D:displayname>
      <D:getcontentlength>100</D:getcontentlength>
    </D:prop></D:propstat>
  </D:response>
</D:multistatus>''';
      final files = parser.parse(xml, requestUrl: 'http://host/dav');
      expect(files.single.name, 'a.mp4');
    });

    test('displayname 缺失时从 href 末段解码名称', () {
      const xml = '''
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/my%20movie%20(1).mp4</d:href>
    <d:propstat><d:prop><d:getcontentlength>5</d:getcontentlength></d:prop></d:propstat>
  </d:response>
</d:multistatus>''';
      final files = parser.parse(xml, requestUrl: 'http://host/dav');
      expect(files.single.name, 'my movie (1).mp4');
    });

    test('AList 中文长目录同时保留子目录与视频文件', () {
      const xml = '''
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/QuarkFilmsData_BASE/0.MoviesData/2013%20-%E3%80%8A%E5%89%A7%E5%9C%BA%E7%89%88%20%E6%88%91%E4%BB%AC%E4%BB%8D%E6%9C%AA%E7%9F%A5%E9%81%93%E9%82%A3%E5%A4%A9%E6%89%80%E7%9C%8B%E8%A7%81%E7%9A%84%E8%8A%B1%E7%9A%84%E5%90%8D%E5%AD%97%E3%80%82%E3%80%8B/</D:href>
    <D:propstat><D:prop>
      <D:resourcetype><D:collection/></D:resourcetype>
      <D:displayname>2013 -《剧场版 我们仍未知道那天所看见的花的名字。》</D:displayname>
    </D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/QuarkFilmsData_BASE/0.MoviesData/2013%20-%E3%80%8A%E5%89%A7%E5%9C%BA%E7%89%88%20%E6%88%91%E4%BB%AC%E4%BB%8D%E6%9C%AA%E7%9F%A5%E9%81%93%E9%82%A3%E5%A4%A9%E6%89%80%E7%9C%8B%E8%A7%81%E7%9A%84%E8%8A%B1%E7%9A%84%E5%90%8D%E5%AD%97%E3%80%82%E3%80%8B/%E3%80%8ASpecials%E3%80%8B/</D:href>
    <D:propstat><D:prop>
      <D:resourcetype><D:collection/></D:resourcetype>
      <D:displayname>《Specials》</D:displayname>
    </D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/QuarkFilmsData_BASE/0.MoviesData/2013%20-%E3%80%8A%E5%89%A7%E5%9C%BA%E7%89%88%20%E6%88%91%E4%BB%AC%E4%BB%8D%E6%9C%AA%E7%9F%A5%E9%81%93%E9%82%A3%E5%A4%A9%E6%89%80%E7%9C%8B%E8%A7%81%E7%9A%84%E8%8A%B1%E7%9A%84%E5%90%8D%E5%AD%97%E3%80%82%E3%80%8B/movie.mkv</D:href>
    <D:propstat><D:prop>
      <D:displayname>movie.mkv</D:displayname>
      <D:getcontentlength>1</D:getcontentlength>
    </D:prop></D:propstat>
  </D:response>
</D:multistatus>''';

      final files = parser.parse(
        xml,
        requestUrl:
            'http://host/dav/QuarkFilmsData_BASE/0.MoviesData/'
            '2013%20-%E3%80%8A%E5%89%A7%E5%9C%BA%E7%89%88%20'
            '%E6%88%91%E4%BB%AC%E4%BB%8D%E6%9C%AA%E7%9F%A5%E9%81%93'
            '%E9%82%A3%E5%A4%A9%E6%89%80%E7%9C%8B%E8%A7%81%E7%9A%84'
            '%E8%8A%B1%E7%9A%84%E5%90%8D%E5%AD%97%E3%80%82%E3%80%8B',
      );

      expect(files, hasLength(3));
      expect(files[0].isSelfEntry, isTrue);
      expect(files[1].name, '《Specials》');
      expect(files[1].isDirectory, isTrue);
      expect(files[2].name, 'movie.mkv');
      expect(files[2].isVideo, isTrue);
    });

    test('无 prop 的 404 响应兜底生成条目', () {
      const xml = '''
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/lost/</d:href>
    <d:status>HTTP/1.1 404 Not Found</d:status>
  </d:response>
</d:multistatus>''';
      final files = parser.parse(xml, requestUrl: 'http://host/dav');
      expect(files.single.isDirectory, isTrue);
      expect(files.single.name, 'lost');
    });

    test('ISO8601 日期兼容', () {
      const xml = '''
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/b.mp4</d:href>
    <d:propstat><d:prop>
      <d:displayname>b.mp4</d:displayname>
      <d:getlastmodified>2024-01-02T03:04:05Z</d:getlastmodified>
    </d:prop></d:propstat>
  </d:response>
</d:multistatus>''';
      final files = parser.parse(xml, requestUrl: 'http://host/dav');
      expect(files.single.modified, DateTime.utc(2024, 1, 2, 3, 4, 5));
    });

    test('文件名使用自然排序而非普通字符串排序', () {
      const xml = '''
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/dav/S1E10.mkv</d:href><d:propstat><d:prop><d:displayname>S1E10.mkv</d:displayname></d:prop></d:propstat></d:response>
  <d:response><d:href>/dav/S1E2.mkv</d:href><d:propstat><d:prop><d:displayname>S1E2.mkv</d:displayname></d:prop></d:propstat></d:response>
  <d:response><d:href>/dav/S1E1.mkv</d:href><d:propstat><d:prop><d:displayname>S1E1.mkv</d:displayname></d:prop></d:propstat></d:response>
</d:multistatus>''';
      final files = parser.parse(xml, requestUrl: 'http://host/dav');
      expect(files.map((file) => file.name), [
        'S1E1.mkv',
        'S1E2.mkv',
        'S1E10.mkv',
      ]);
    });

    test('非法 XML 抛 AppException.network', () {
      expect(
        () => parser.parse('<oops', requestUrl: 'http://host/dav'),
        throwsA(isA<AppException>()),
      );
    });

    test('空响应返回空列表', () {
      expect(parser.parse('', requestUrl: 'http://host/dav'), isEmpty);
    });
  });
}
