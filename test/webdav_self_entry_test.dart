import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/data/remote/webdav_xml_parser.dart';

/// 「当前目录自身」条目标记与置顶排序（返回上级入口）。
void main() {
  const parser = WebDavXmlParser();

  const xml = '''
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/movies/</d:href>
    <d:propstat><d:prop>
      <d:displayname>movies</d:displayname>
      <d:resourcetype><d:collection/></d:resourcetype>
    </d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/movies/zdir/</d:href>
    <d:propstat><d:prop>
      <d:displayname>zdir</d:displayname>
      <d:resourcetype><d:collection/></d:resourcetype>
    </d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/movies/01.mp4</d:href>
    <d:propstat><d:prop>
      <d:displayname>01.mp4</d:displayname>
      <d:getcontentlength>100</d:getcontentlength>
    </d:prop></d:propstat>
  </d:response>
</d:multistatus>''';

  test('自身条目标记 isSelfEntry，且始终置顶（优先于其他目录）', () {
    final files = parser.parse(xml, requestUrl: 'http://host/dav/movies');
    expect(files, hasLength(3));

    // 排序：自身条目 → 目录 → 文件。
    expect(files[0].isSelfEntry, isTrue);
    expect(files[0].name, 'movies');
    expect(files[0].isDirectory, isTrue);

    expect(files[1].isSelfEntry, isFalse);
    expect(files[1].name, 'zdir');
    expect(files[1].isDirectory, isTrue);

    expect(files[2].name, '01.mp4');
  });

  test('子目录的自身条目不会被误标（请求根目录时 movies 不是自身）', () {
    final files = parser.parse(xml, requestUrl: 'http://host/dav');
    expect(files.every((f) => !f.isSelfEntry), isTrue);
    // 此时排序：目录在前（movies、zdir），文件在后。
    expect(files[0].name, 'movies');
  });

  test('文件条目不会误标为自身', () {
    const fileXml = '''
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/movies/01.mp4</d:href>
    <d:propstat><d:prop>
      <d:displayname>01.mp4</d:displayname>
      <d:getcontentlength>100</d:getcontentlength>
    </d:prop></d:propstat>
  </d:response>
</d:multistatus>''';
    final files = parser.parse(fileXml, requestUrl: 'http://host/dav/movies');
    expect(files.single.isSelfEntry, isFalse);
  });

  test('Hive 缓存序列化保留 isSelfEntry', () {
    final f = parser.parse(xml, requestUrl: 'http://host/dav/movies').first;
    final restored = WebDavFile.fromCacheMap(f.toCacheMap());
    expect(restored.isSelfEntry, isTrue);
  });
}
