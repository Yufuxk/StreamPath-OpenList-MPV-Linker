import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/features/cache_control/models/media_metadata.dart';
import 'package:streampath/features/cache_control/store/media_metadata_store.dart';

/// 媒体元数据缓存测试（对应文档「Metadata 缓存结构」）。
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('sp_meta_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  MediaMetadataStore storeFor(String name) => MediaMetadataStore.forPath(
    '${tempDir.path}${Platform.pathSeparator}$name',
  );

  group('urlHash', () {
    test('同一 URL 哈希稳定且不同 URL 不同', () {
      final a = MediaMetadataStore.urlHashOf('http://h/dav/1.mkv');
      final b = MediaMetadataStore.urlHashOf('http://h/dav/1.mkv');
      final c = MediaMetadataStore.urlHashOf('http://h/dav/2.mkv');
      expect(a, b);
      expect(a, isNot(c));
      expect(a.length, 64); // SHA-256 hex
    });

    test('签名参数变化仍命中同一媒体，稳定业务参数仍区分', () {
      final a = MediaMetadataStore.urlHashOf(
        'https://user:pw@h/dav/1.mkv?quality=4k&token=old&X-Amz-Signature=a',
      );
      final b = MediaMetadataStore.urlHashOf(
        'https://h/dav/1.mkv?quality=4k&token=new&X-Amz-Signature=b',
      );
      final c = MediaMetadataStore.urlHashOf(
        'https://h/dav/1.mkv?quality=1080p&token=new',
      );
      expect(a, b);
      expect(a, isNot(c));
    });
  });

  group('MediaMetadata 模型', () {
    test('JSON 往返', () {
      final meta = MediaMetadata(
        urlHash: 'abc',
        fileSize: 7400000000,
        durationSec: 7200,
        bitrateBps: 8200000,
        resolution: '1920x1080',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(123456789),
      );
      final restored = MediaMetadata.fromJson(meta.toJson());
      expect(restored.urlHash, 'abc');
      expect(restored.fileSize, 7400000000);
      expect(restored.durationSec, 7200);
      expect(restored.bitrateBps, 8200000);
      expect(restored.resolution, '1920x1080');
      expect(restored.updatedAt.millisecondsSinceEpoch, 123456789);
    });

    test('无效时长/码率收敛为 null', () {
      final meta = MediaMetadata.fromJson(const {
        'url_hash': 'x',
        'duration': 0,
        'bitrate': -1,
      });
      expect(meta.hasDuration, isFalse);
      expect(meta.hasBitrate, isFalse);
    });

    test('parseResolution 支持 x/X/× 分隔', () {
      expect(MediaMetadata.parseResolution('1920x1080'), (1920, 1080));
      expect(MediaMetadata.parseResolution('3840X2160'), (3840, 2160));
      expect(MediaMetadata.parseResolution('1920×1080'), (1920, 1080));
      expect(MediaMetadata.parseResolution('bad'), isNull);
    });
  });

  group('MediaMetadataStore 读写', () {
    test('写入后读取一致', () async {
      final store = storeFor('meta.json');
      final meta = MediaMetadata(
        urlHash: MediaMetadataStore.urlHashOf('http://h/dav/1.mkv'),
        fileSize: 7400000000,
        durationSec: 7200,
        bitrateBps: 8200000,
        resolution: '1920x1080',
        updatedAt: DateTime.now(),
      );
      expect(await store.write(meta), isTrue);

      final fresh = storeFor('meta.json');
      final loaded = await fresh.read(meta.urlHash);
      expect(loaded, isNotNull);
      expect(loaded!.fileSize, 7400000000);
      expect(loaded.durationSec, 7200);
      expect(loaded.bitrateBps, 8200000);
      expect(loaded.resolution, '1920x1080');
    });

    test('未命中返回 null', () async {
      final store = storeFor('empty.json');
      expect(
        await store.read(MediaMetadataStore.urlHashOf('http://h/none.mkv')),
        isNull,
      );
    });

    test('损坏 JSON 视为空缓存不抛出', () async {
      final path = '${tempDir.path}${Platform.pathSeparator}broken.json';
      File(path).writeAsStringSync('{oops');
      final store = MediaMetadataStore.forPath(path);
      expect(await store.read('x'), isNull);
      // 写入仍可工作（覆盖损坏文件）。
      final meta = MediaMetadata(
        urlHash: 'x',
        fileSize: 1,
        updatedAt: DateTime.now(),
      );
      expect(await store.write(meta), isTrue);
      expect((await store.read('x'))!.fileSize, 1);
    });

    test('多条目共存', () async {
      final store = storeFor('multi.json');
      final m1 = MediaMetadata(
        urlHash: 'a',
        fileSize: 1,
        updatedAt: DateTime.now(),
      );
      final m2 = MediaMetadata(
        urlHash: 'b',
        durationSec: 99,
        updatedAt: DateTime.now(),
      );
      await store.write(m1);
      await store.write(m2);
      final fresh = storeFor('multi.json');
      expect((await fresh.read('a'))!.fileSize, 1);
      expect((await fresh.read('b'))!.durationSec, 99);
    });

    test('首次加载时并发 read/write 不丢更新，写入文件保持有效 JSON', () async {
      final path = '${tempDir.path}${Platform.pathSeparator}concurrent.json';
      final seed = MediaMetadata(
        urlHash: 'seed',
        fileSize: 1,
        updatedAt: DateTime.now(),
      );
      await storeFor('concurrent.json').write(seed);
      final store = MediaMetadataStore.forPath(path);
      final writes = <Future<Object?>>[
        store.read('seed'),
        for (var i = 0; i < 20; i++)
          store.write(
            MediaMetadata(
              urlHash: 'item_$i',
              fileSize: i + 2,
              updatedAt: DateTime.now(),
            ),
          ),
      ];
      await Future.wait(writes);

      final fresh = MediaMetadataStore.forPath(path);
      expect((await fresh.read('seed'))!.fileSize, 1);
      for (var i = 0; i < 20; i++) {
        expect((await fresh.read('item_$i'))!.fileSize, i + 2);
      }
      expect(File('$path.tmp').existsSync(), isFalse);
    });
  });
}
