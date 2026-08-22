import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/data/local/directory_cache.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/data/remote/webdav_client.dart';
import 'package:streampath/domain/services/webdav_service.dart';

void main() {
  group('WebDAVService 强制刷新', () {
    test('连接验证忽略旧账号根目录缓存并真实请求服务器', () async {
      final oldEntries = [_file('旧账号缓存.mp4')];
      final cache = _MemoryDirectoryCache(entries: oldEntries);
      var requestCount = 0;
      final client = _FakeWebDavClient((_) async {
        requestCount++;
        throw AppException.network('认证失败');
      }, username: 'new-user');
      final service = WebDAVService(client: client, cache: cache);

      await expectLater(
        service.verifyConnection(),
        throwsA(isA<NetworkException>()),
      );

      expect(requestCount, 1);
      expect(cache.writeCount, 0);
      expect(cache.snapshot?.entries, oldEntries);
    });

    test('刷新失败时保留最后一次成功缓存', () async {
      final oldEntries = [_file('旧缓存.mp4')];
      final cache = _MemoryDirectoryCache(entries: oldEntries);
      final client = _FakeWebDavClient((_) async {
        throw AppException.network('刷新失败');
      });
      final service = WebDAVService(client: client, cache: cache);

      await expectLater(
        service.refreshDirectory('movies'),
        throwsA(isA<NetworkException>()),
      );

      expect(cache.writeCount, 0, reason: '刷新成功前不应把缓存清空');
      expect(cache.snapshot?.entries, oldEntries);
    });

    test('已有旧请求时等待其结束，再发起一次真正的网络刷新', () async {
      final firstResponse = Completer<String>();
      var requestCount = 0;
      final client = _FakeWebDavClient((_) {
        requestCount++;
        return requestCount == 1
            ? firstResponse.future
            : Future.value(_directoryXml('刷新结果.mp4'));
      });
      final cache = _MemoryDirectoryCache();
      final service = WebDAVService(client: client, cache: cache);

      final oldLoad = service.fetchDirectory('movies');
      final refresh = service.refreshDirectory('movies');
      expect(requestCount, 1, reason: '旧请求未结束前不并发重复请求');

      firstResponse.complete(_directoryXml('旧请求.mp4'));
      expect((await oldLoad).single.name, '旧请求.mp4');
      expect((await refresh).single.name, '刷新结果.mp4');
      expect(requestCount, 2, reason: '强制刷新必须真正再请求一次网络');
      expect(cache.snapshot?.entries.single.name, '刷新结果.mp4');
    });

    test('同目录的连续强制刷新合并为一个请求', () async {
      final response = Completer<String>();
      var requestCount = 0;
      final client = _FakeWebDavClient((_) {
        requestCount++;
        return response.future;
      });
      final service = WebDAVService(
        client: client,
        cache: _MemoryDirectoryCache(),
      );

      final first = service.refreshDirectory('movies');
      final second = service.refreshDirectory('movies');
      expect(requestCount, 1);

      response.complete(_directoryXml('仅请求一次.mp4'));
      expect((await first).single.name, '仅请求一次.mp4');
      expect((await second).single.name, '仅请求一次.mp4');
      expect(requestCount, 1);
    });

    test('profileId 同时隔离目录缓存键与访问型索引来源', () async {
      final cacheA = _MemoryDirectoryCache();
      final cacheB = _MemoryDirectoryCache();
      final client = _FakeWebDavClient(
        (_) async => _directoryXml('影片.mkv'),
        username: 'same-user',
      );

      await WebDAVService(
        client: client,
        profileId: 'profile-a',
        cache: cacheA,
      ).refreshDirectory('movies');
      await WebDAVService(
        client: client,
        profileId: 'profile-b',
        cache: cacheB,
      ).refreshDirectory('movies');

      expect(cacheA.lastKey, isNot(cacheB.lastKey));
      expect(cacheA.lastSourceId, 'profile-a');
      expect(cacheB.lastSourceId, 'profile-b');
    });
  });
}

class _FakeWebDavClient extends WebDavClient {
  _FakeWebDavClient(this._handler, {super.username})
    : super(baseUrl: 'http://host/dav');

  final Future<String> Function(String path) _handler;

  @override
  Future<String> propfind(String path) => _handler(path);
}

class _MemoryDirectoryCache extends DirectoryCache {
  _MemoryDirectoryCache({List<WebDavFile>? entries})
    : snapshot = entries == null
          ? null
          : CacheSnapshot(entries: entries, cachedAt: DateTime.now());

  CacheSnapshot? snapshot;
  int writeCount = 0;
  String? lastKey;
  String? lastSourceId;

  @override
  CacheSnapshot? read(String key) => snapshot;

  @override
  bool isFresh(CacheSnapshot snapshot) => true;

  @override
  void write(
    String key,
    List<WebDavFile> entries, {
    String? sourceId,
    String? path,
  }) {
    writeCount++;
    lastKey = key;
    lastSourceId = sourceId;
    snapshot = CacheSnapshot(
      entries: List<WebDavFile>.unmodifiable(entries),
      cachedAt: DateTime.now(),
    );
  }
}

WebDavFile _file(String name) => WebDavFile(
  name: name,
  href: '/dav/movies/${Uri.encodeComponent(name)}',
  isDirectory: false,
);

String _directoryXml(String name) =>
    '''
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/movies/${Uri.encodeComponent(name)}</d:href>
    <d:propstat><d:prop>
      <d:displayname>$name</d:displayname>
      <d:getcontentlength>1</d:getcontentlength>
    </d:prop></d:propstat>
  </d:response>
</d:multistatus>
''';
