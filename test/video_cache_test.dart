import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/media_connection.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/data/remote/webdav_client.dart';
import 'package:streampath/domain/services/webdav_service.dart';
import 'package:streampath/domain/services/webdav_media_source_adapter.dart';
import 'package:streampath/features/video_cache/video_cache_planner.dart';
import 'package:streampath/data/models/video_queue.dart';
import 'package:streampath/domain/services/video_entry_preparer.dart';
import 'package:streampath/domain/services/subtitle_matcher.dart';
import 'package:streampath/domain/services/webdav_font_matcher.dart';
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/features/video_cache/video_cache_models.dart';
import 'package:streampath/features/video_cache/video_cache_service.dart';
import 'package:streampath/features/video_cache/video_cache_source.dart';

Map<String, dynamic> _noSpace(String _) => {
  'available': 0,
  'volume': 'test-volume',
  'fat32': false,
};
Map<String, dynamic> _space(String _) => {
  'available': 1024 * 1024 * 1024,
  'volume': 'test-volume',
  'fat32': false,
};
Map<String, dynamic> _limitedSpace(String _) => {
  'available': 262 * 1024 * 1024,
  'volume': 'test-volume',
  'fat32': false,
};
Map<String, dynamic> _fat32(String _) => {
  'available': 16 * 1024 * 1024 * 1024,
  'volume': 'test-volume',
  'fat32': true,
};
Map<String, dynamic> _fallingSpace(String path) => {
  'available': File(p.join(path, '.low-space')).existsSync()
      ? 0
      : 1024 * 1024 * 1024,
  'volume': 'test-volume',
  'fat32': false,
};

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Cache state did not settle');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class _Source {
  final bytes = Uint8List.fromList(
    List.generate(4 * 1024 * 1024, (i) => i % 251),
  );
  late HttpServer server;
  final offsets = <int>[];
  String version = '"v1"';
  bool slow = false, ignoreRange = false, invalidRange = false, weak = false;
  int disconnects = 0;
  int expiredLinks = 0;
  bool stallMetadata = false;
  int delayMs = 15;
  String get base => 'http://127.0.0.1:${server.port}/';
  Future<void> open() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final match = RegExp(
        r'^bytes=(\d+)-(\d+)$',
      ).firstMatch(request.headers.value('range') ?? '');
      final start = int.parse(match![1]!), end = int.parse(match[2]!);
      offsets.add(start);
      if (stallMetadata && end == 0) return;
      if (end > 1 && expiredLinks > 0) {
        expiredLinks--;
        request.response.statusCode = 403;
        await request.response.close();
        return;
      }
      if (disconnects > 0 && end > 1) {
        disconnects--;
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.write(
          'HTTP/1.1 206 Partial Content\r\nContent-Range: bytes $start-$end/${bytes.length}\r\nETag: $version\r\nContent-Length: ${end - start + 1}\r\nConnection: close\r\n\r\n',
        );
        socket.add(
          bytes.sublist(start, (start + 256 * 1024).clamp(0, end + 1)),
        );
        await socket.flush();
        socket.destroy();
        return;
      }
      final response = request.response;
      response.statusCode = ignoreRange ? 200 : 206;
      response.headers.set('etag', weak ? 'W/"v1"' : version);
      response.headers.set(
        'content-range',
        'bytes ${invalidRange ? start + 1 : start}-$end/${bytes.length}',
      );
      response.contentLength = end - start + 1;
      try {
        for (var offset = start; offset <= end; offset += 64 * 1024) {
          final limit = (offset + 64 * 1024).clamp(0, end + 1);
          response.add(bytes.sublist(offset, limit));
          await response.flush();
          if (slow && end > 1) {
            await Future<void>.delayed(Duration(milliseconds: delayMs));
          }
        }
        await response.close();
      } on SocketException {
        response.close();
      } on HttpException {
        response.close();
      } on StateError {
        /* 客户端暂停后关闭测试响应。 */
      }
    });
  }
}

class _PlannerDirectory extends WebDAVService {
  _PlannerDirectory(this.fileName)
    : super(
        client: WebDavClient(baseUrl: 'https://fixture.invalid/dav'),
        profileId: 'source-a',
      );
  final String fileName;
  @override
  Future<List<WebDavFile>> fetchDirectory(
    String path, {
    bool forceRefresh = false,
  }) async => [
    const WebDavFile(
      name: 'Show Folder',
      href: 'https://fixture.invalid/dav/Show%20Folder/',
      isDirectory: true,
      isSelfEntry: true,
    ),
    WebDavFile(
      name: fileName,
      href:
          'https://fixture.invalid/dav/Show%20Folder/${Uri.encodeComponent(fileName)}',
      isDirectory: false,
    ),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Source source;
  VideoCacheService? cache;
  Future<Map<String, dynamic>> resolve(
    String _,
    String path,
    bool strm,
  ) async => {
    'kind': 'http',
    'url': '${source.base}$path',
    'origin': source.base,
    'headers': <String, String>{},
    'identity': 'account-a',
    'progress': 'https://nas.invalid/$path',
  };
  Future<VideoCacheService> open({bool noSpace = false}) async =>
      cache = await VideoCacheService.open(
        resolveTransfer: resolve,
        dataDirectory: root,
        diskSpaceProvider: noSpace ? _noSpace : _space,
      );
  Future<VideoCachePlan> plan(VideoCacheService service) async {
    final info = await service.probe('source-a', 'show/video.mkv');
    final folder = p.join(root.path, 'video_cache');
    final destination = p.join(
      folder,
      'StreamPathCache',
      'account-a',
      'show',
      'video.mkv',
    );
    final file = VideoCacheFile({
      'id': 'file-a',
      'source': 'source-a',
      'path': 'show/video.mkv',
      'root': folder,
      'destination': destination,
      'identity': 'account-a',
      'strm': false,
      ...info,
    });
    return VideoCachePlan(
      bundle: {
        'id': 'bundle-a',
        'source': 'source-a',
        'sourceKind': 'webdav',
        'identity': 'account-a',
        'path': 'show/video.mkv',
        'name': 'video.mkv',
        'kind': 'video',
        'main': file.id,
        'files': [file.id],
        'root': folder,
        'tree': p.dirname(destination),
        'progress': 'https://nas.invalid/show/video.mkv',
        'fonts': <String>[],
        'audio': <String>[],
        'subtitle': null,
        'subtitleLanguage': 'exact',
        'directories': {
          'show': [
            {
              'name': 'video.mkv',
              'path': 'show/video.mkv',
              'directory': false,
              'size': source.bytes.length,
              'modified': null,
            },
          ],
        },
      },
      files: [file],
    );
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'streampath-video-cache-test-',
    );
    source = _Source();
    await source.open();
  });
  tearDown(() async {
    await cache?.close();
    cache = null;
    await source.server.close(force: true);
    await root.delete(recursive: true);
  });

  test('拒绝危险路径并保留扩展名', () {
    expect(videoCachePath('show/E01.mkv'), 'show/E01.mkv');
    for (final path in [
      '../x',
      '/x',
      'a/../x',
      'C:/x',
      'a/con.mkv',
      'a\\x',
      'x.',
    ]) {
      expect(() => videoCachePath(path), throwsA(isA<VideoCacheException>()));
    }
  });
  test('范围预检拒绝 200、错误范围和弱验证器', () async {
    final service = await open();
    for (var mode = 0; mode < 3; mode++) {
      source.ignoreRange = mode == 0;
      source.invalidRange = mode == 1;
      source.weak = mode == 2;
      await expectLater(
        service.probe('source-a', 'show/video.mkv'),
        throwsA(isA<VideoCacheException>()),
      );
    }
    expect(service.files, isEmpty);
  });
  test('关闭取消进行中的网络探测并结束等待', () async {
    source.stallMetadata = true;
    final service = await open();
    final result = expectLater(
      service.probe('source-a', 'show/video.mkv'),
      throwsA(isA<VideoCacheException>()),
    );
    await _until(() => source.offsets.isNotEmpty);
    final clock = Stopwatch()..start();
    await service.close();
    cache = null;
    await result;
    expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
  });
  test('空间不足整批不入队且不创建 partial', () async {
    final service = await open(noSpace: true);
    final selection = await plan(service);
    await expectLater(
      service.enqueue([selection]),
      throwsA(isA<VideoCacheException>()),
    );
    expect(service.files, isEmpty);
    expect(source.offsets, [0]);
    expect(
      await File('${selection.files.first.destination}.partial').exists(),
      isFalse,
    );
  });
  test('WebDAV 自身目录条目不阻止中文普通视频和 STRM 清单', () async {
    final service = await open();
    for (final extension in ['mkv', 'strm']) {
      final name = '爱丽丝和特蕾丝的梦幻工厂 2023.$extension';
      final path = 'Show Folder/$name';
      final resource = FilmResource.fromRow({
        'id': 1,
        'root_id': 1,
        'source_id': 'source-a',
        'source_kind': 'webdav',
        'media_type': 'movie',
        'root_path': 'Show Folder',
        'display_name': 'Fixture',
        'relative_path': path,
        'path_key': path,
        'parent_path': 'Show Folder',
        'name': name,
        'media_kind': extension == 'strm' ? 'strm' : 'video',
        'availability': 'present',
        'binding_origin': 'explicit',
        'binding_version': 0,
        'episode_mapping_origin': 'none',
      });
      final planner = VideoCachePlanner(
        service,
        WebDavMediaSourceAdapter(_PlannerDirectory(name)),
        const PlayerConfig(
          name: 'mpv',
          executable: 'mpv',
          subtitleInjectionEnabled: false,
        ),
        const SubtitleMatcher(),
        const WebDavFontMatcher(),
      );
      final selection = await planner.plan(resource, service.targetDirectory);
      expect(selection.files.single.path, path);
      expect(selection.size, source.bytes.length);
    }
  });
  test('完整成品逐字节一致，缓存命中不访问远端并保留逻辑进度', () async {
    final service = await open();
    final selection = await plan(service);
    await service.enqueue([selection]);
    await service.setPlaybackSuspended(false);
    await _until(() => service.files['file-a']?.complete == true);
    expect(
      await File(selection.files.first.destination).readAsBytes(),
      source.bytes,
    );
    final requests = source.offsets.length;
    final hit = await service.lookup(
      'source-a',
      'show/video.mkv',
      identity: 'account-a',
    );
    expect(
      hit!.prepared().entry.progressTarget,
      'https://nas.invalid/show/video.mkv',
    );
    expect(
      service.progressTargetFor('source-a', hit.path),
      'https://nas.invalid/show/video.mkv',
    );
    expect(
      service.progressTargetFor('source-a', Uri.file(hit.path).toString()),
      'https://nas.invalid/show/video.mkv',
    );
    expect(service.progressTargetFor('other-source', hit.path), isNull);
    final offline = VideoCacheSource(
      service,
      const MediaSourceDescriptor(
        sourceId: 'source-a',
        kind: MediaSourceKind.webdav,
        displayName: 'test',
      ),
      identity: 'account-a',
      baseUrl: source.base,
      persistent: (path) => 'https://nas.invalid/$path',
      remote: () async =>
          throw StateError('Offline cache must not resolve remote source'),
    );
    final preparer = VideoEntryPreparer(
      source: offline,
      config: const PlayerConfig(name: 'mpv', executable: 'mpv'),
      subtitleMatcher: const SubtitleMatcher(),
      fontMatcher: const WebDavFontMatcher(),
      titles: const {},
      cached: (path) async => (await service.lookup(
        'source-a',
        path,
        identity: 'account-a',
      ))?.prepared(),
    );
    final prepared = await preparer.prepare(
      const VideoQueueVersion(path: 'show/video.mkv', name: 'video.mkv'),
    );
    await preparer.prepareSharedFonts(
      'unavailable-parent',
      startPath: 'show/video.mkv',
    );
    expect(prepared.entry.url, selection.files.first.destination);
    expect((await offline.fetchDirectory('show')).single.name, 'video.mkv');
    expect(source.offsets.length, requests);
    expect(
      await service.lookup(
        'source-a',
        'show/video.mkv',
        identity: 'other-account',
      ),
      isNull,
    );
    await expectLater(
      service.delete('bundle-a', protectedPaths: {hit.path}),
      throwsA(isA<VideoCacheException>()),
    );
    await service.delete('bundle-a');
    expect(await File(hit.path).exists(), isFalse);
  });
  test('ISO 自选目录保存到索引，切换默认目录并重启后仍可离线命中', () async {
    var service = await open();
    final selected = await Directory(p.join(root.path, 'selected')).create();
    final resource = FilmResource.fromRow({
      'id': 1,
      'root_id': 1,
      'source_id': 'source-a',
      'source_kind': 'webdav',
      'media_type': 'movie',
      'root_path': 'Show Folder',
      'display_name': 'Fixture',
      'relative_path': 'Show Folder/缓存光盘.iso',
      'path_key': 'Show Folder/缓存光盘.iso',
      'parent_path': 'Show Folder',
      'name': '缓存光盘.iso',
      'media_kind': 'iso',
      'availability': 'present',
      'binding_origin': 'explicit',
      'binding_version': 0,
      'episode_mapping_origin': 'none',
    });
    final selection = await VideoCachePlanner(
      service,
      WebDavMediaSourceAdapter(_PlannerDirectory(resource.name)),
      const PlayerConfig(name: 'mpv', executable: 'mpv'),
      const SubtitleMatcher(),
      const WebDavFontMatcher(),
      identity: 'account-a',
    ).plan(resource, selected.path);
    await service.enqueue([selection]);
    await service.setPlaybackSuspended(false);
    await _until(() => service.complete(selection.bundle));
    final path = (await service.lookup('source-a', resource.path))!.discPath;
    expect(p.isWithin(selected.path, path), isTrue);
    expect(await File(path).readAsBytes(), source.bytes);
    await service.saveDirectory(root.path);
    await service.close();
    cache = null;
    service = await open();
    expect(service.targetDirectory, root.path);
    final requests = source.offsets.length;
    final offline = VideoCacheSource(
      service,
      const MediaSourceDescriptor(
        sourceId: 'source-a',
        kind: MediaSourceKind.webdav,
        displayName: 'Fixture',
      ),
      identity: 'account-a',
      baseUrl: 'https://fixture.invalid/dav',
      persistent: (p) => p,
      remote: () async => throw StateError('Cached disc must stay offline'),
    );
    final file = (await offline.service.fetchDirectory('Show Folder')).single;
    expect(await offline.service.cachedDiscPath(file), path);
    expect(source.offsets.length, requests);
  });
  test('暂停与重开从已刷盘偏移续传，手动暂停保留', () async {
    source.slow = true;
    var service = await open();
    final selection = await plan(service);
    await service.enqueue([selection]);
    await service.setPlaybackSuspended(false);
    await _until(() => (service.files['file-a']?.received ?? 0) > 0);
    await service.pause('bundle-a');
    final checkpoint = service.files['file-a']!.committed;
    expect(checkpoint, greaterThan(0));
    expect(service.files['file-a']!.state, 'paused');
    await service.close();
    cache = null;
    service = await open();
    expect(service.files['file-a']!.state, 'paused');
    await service.setPlaybackSuspended(false);
    await service.resume('bundle-a');
    await _until(() => service.files['file-a']!.complete);
    expect(source.offsets, contains(checkpoint));
    expect(
      await File(selection.files.first.destination).readAsBytes(),
      source.bytes,
    );
  });
  test('断流自动续传不会从头重下', () async {
    source.disconnects = 1;
    final service = await open();
    final selection = await plan(service);
    await service.enqueue([selection]);
    await service.setPlaybackSuspended(false);
    await _until(() => service.files['file-a']!.complete);
    expect(source.offsets.where((n) => n > 0), isNotEmpty);
    expect(
      await File(selection.files.first.destination).readAsBytes(),
      source.bytes,
    );
  });
  test('暂停后源版本变化拒绝拼接，并保留原断点', () async {
    source.slow = true;
    final service = await open();
    final selection = await plan(service);
    await service.enqueue([selection]);
    await service.setPlaybackSuspended(false);
    await _until(() => (service.files['file-a']?.received ?? 0) > 0);
    await service.pause('bundle-a');
    final checkpoint = service.files['file-a']!.committed;
    source.version = '"v2"';
    await service.resume('bundle-a');
    await _until(() => service.files['file-a']!.state == 'failed');
    expect(service.files['file-a']!.committed, checkpoint);
    expect(await File(selection.files.first.destination).exists(), isFalse);
  });
  test('临时链接过期后重新解析并安全重试', () async {
    source.expiredLinks = 1;
    final service = await open();
    final selection = await plan(service);
    await service.enqueue([selection]);
    await service.setPlaybackSuspended(false);
    await _until(() => service.files['file-a']!.complete);
    expect(
      await File(selection.files.single.destination).readAsBytes(),
      source.bytes,
    );
    expect(source.expiredLinks, 0);
  });
  test('播放暂停完成后没有传输，解除暂停保留手动状态', () async {
    source.slow = true;
    final service = await open();
    final selection = await plan(service);
    await service.enqueue([selection]);
    await service.setPlaybackSuspended(false);
    await _until(() => (service.files['file-a']?.received ?? 0) > 0);
    await service.setPlaybackSuspended(true);
    final offset = service.files['file-a']!.committed;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(service.files['file-a']!.received, offset);
    await service.pause('bundle-a');
    await service.setPlaybackSuspended(false);
    expect(service.files['file-a']!.state, 'paused');
    await service.resume('bundle-a');
    await _until(() => service.files['file-a']!.complete);
  });
  test('重复提交只下载一次，共享文件按引用删除', () async {
    final service = await open();
    final selection = await plan(service);
    final second = VideoCachePlan(
      bundle: {...selection.bundle, 'id': 'bundle-b', 'path': 'show/alias.mkv'},
      files: selection.files,
    );
    await service.enqueue([selection, selection, second]);
    expect(service.files, hasLength(1));
    await service.setPlaybackSuspended(false);
    await _until(() => service.files['file-a']!.complete);
    await service.delete('bundle-a');
    expect(await File(selection.files.single.destination).exists(), isTrue);
    await service.delete('bundle-b');
    expect(await File(selection.files.single.destination).exists(), isFalse);
  });
  test('取消保留断点，重试继续下载；缺失成品可重新缓存', () async {
    source.slow = true;
    final service = await open();
    final selection = await plan(service);
    await service.enqueue([selection]);
    await service.setPlaybackSuspended(false);
    await _until(() => (service.files['file-a']?.received ?? 0) > 0);
    await service.cancel('bundle-a');
    expect(
      await File('${selection.files.single.destination}.partial').exists(),
      isTrue,
    );
    expect(service.files['file-a']!.state, 'cancelled');
    await service.resume('bundle-a');
    await _until(() => service.files['file-a']!.complete);
    await File(selection.files.single.destination).delete();
    expect(await service.lookup('source-a', 'show/video.mkv'), isNull);
    await service.enqueue([selection]);
    await _until(() => service.files['file-a']!.complete);
    expect(
      await File(selection.files.single.destination).readAsBytes(),
      source.bytes,
    );
  });
  test('同卷不同目录合并空间预留且超限整批拒绝', () async {
    final service = cache = await VideoCacheService.open(
      resolveTransfer: resolve,
      dataDirectory: root,
      diskSpaceProvider: _limitedSpace,
    );
    final first = await plan(service);
    final folder = await Directory(p.join(root.path, 'other')).create();
    final secondFile = VideoCacheFile({
      ...first.files.single.data,
      'id': 'file-b',
      'root': folder.path,
      'destination': p.join(folder.path, 'StreamPathCache', 'video.mkv'),
    });
    final second = VideoCachePlan(
      bundle: {
        ...first.bundle,
        'id': 'bundle-b',
        'files': ['file-b'],
        'main': 'file-b',
      },
      files: [secondFile],
    );
    await expectLater(
      service.enqueue([first, second]),
      throwsA(isA<VideoCacheException>()),
    );
    expect(service.files, isEmpty);
    expect(source.offsets, [0]);
    await service.enqueue([first]);
    await expectLater(
      service.enqueue([second]),
      throwsA(isA<VideoCacheException>()),
    );
    expect(service.files, hasLength(1));
  });
  test('FAT32 单文件上限在入队前拒绝', () async {
    final service = cache = await VideoCacheService.open(
      resolveTransfer: resolve,
      dataDirectory: root,
      diskSpaceProvider: _fat32,
    );
    final selection = await plan(service);
    selection.files.single.data['size'] = 0x100000000;
    await expectLater(
      service.enqueue([selection]),
      throwsA(isA<VideoCacheException>()),
    );
    expect(service.files, isEmpty);
  });
  test('运行中空间下降到余量以下停止并保留断点', () async {
    source.slow = true;
    source.delayMs = 50;
    final service = cache = await VideoCacheService.open(
      resolveTransfer: resolve,
      dataDirectory: root,
      diskSpaceProvider: _fallingSpace,
    );
    final selected = await plan(service);
    await service.enqueue([selected]);
    await service.setPlaybackSuspended(false);
    await _until(() => (service.files['file-a']?.received ?? 0) > 0);
    await File(
      p.join(service.targetDirectory, '.low-space'),
    ).writeAsString('full');
    await _until(() => service.files['file-a']!.state == 'failed');
    expect(service.files['file-a']!.committed, greaterThan(0));
    expect(await File(selected.files.single.destination).exists(), isFalse);
    expect(
      await File('${selected.files.single.destination}.partial').exists(),
      isTrue,
    );
  });
  test('写盘无权限停止任务并保留 partial', () async {
    final service = await open();
    final selected = await plan(service);
    await service.enqueue([selected]);
    final partial = File('${selected.files.single.destination}.partial');
    await partial.parent.create(recursive: true);
    await partial.writeAsBytes([]);
    final attributes = await Process.run('attrib', ['+R', partial.path]);
    expect(attributes.exitCode, 0);
    addTearDown(() => Process.run('attrib', ['-R', partial.path]));
    await service.setPlaybackSuspended(false);
    await _until(() => service.files['file-a']!.state == 'failed');
    expect(service.files['file-a']!.error, contains('缓存文件读写失败'));
    expect(await partial.exists(), isTrue);
  }, skip: !Platform.isWindows);
  test('索引写入失败停止传输并保留已写入文件', () async {
    source.slow = true;
    source.delayMs = 50;
    final service = await open();
    final selected = await plan(service);
    await service.enqueue([selected]);
    await service.setPlaybackSuspended(false);
    await _until(() => (service.files['file-a']?.received ?? 0) > 0);
    sqfliteFfiInit();
    final index = await databaseFactoryFfi.openDatabase(
      p.join(root.path, 'library', 'video_cache.db'),
    );
    await index.execute('DROP TABLE files');
    await index.close();
    await _until(() => service.files['file-a']!.state == 'failed');
    expect(service.files['file-a']!.error, contains('缓存索引写入失败'));
    expect(
      await File('${selected.files.single.destination}.partial').exists(),
      isTrue,
    );
    await expectLater(
      service.resume('bundle-a'),
      throwsA(isA<VideoCacheException>()),
    );
  });
  test(
    'FTP 连续传输支持原生 STRM 目标、暂停及重启续传',
    () async {
      final ftpRoot = await Directory(p.join(root.path, 'ftp')).create();
      await File(p.join(ftpRoot.path, 'probe.bin')).writeAsBytes(source.bytes);
      final fixture =
          await Process.start(Platform.environment['PHASE5_PYTHON']!, [
            'test/support/storage_ftp_fixture.py',
            ftpRoot.path,
            p.absolute('build/phase5-test-deps'),
            'cache',
          ]);
      fixture.stderr.drain<void>();
      addTearDown(() async {
        fixture.kill();
        await fixture.exitCode;
      });
      final ready = await fixture.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      final port = (jsonDecode(ready) as Map)['port'];
      final connection = MediaConnection(
        id: 'source-a',
        kind: MediaSourceKind.ftp,
        name: 'Fixture',
        url: 'ftp://127.0.0.1:$port/',
        username: 'fixture',
      );
      Future<Map<String, dynamic>> native(
        String _,
        String path,
        bool strm,
      ) async => {
        'kind': 'native',
        'config': connection.toJson(),
        'password': 'fixture',
        'identity': 'account-a',
        'nativePath': 'probe.bin',
        'library': p.absolute(
          'build/windows/x64/runner/Release/streampath_storage.dll',
        ),
        'progress': 'streampath://source/source-a/show/video.mkv',
      };
      Future<VideoCacheService> nativeCache() async =>
          cache = await VideoCacheService.open(
            resolveTransfer: native,
            dataDirectory: root,
            diskSpaceProvider: _space,
          );
      var service = await nativeCache();
      final selected = await plan(service);
      await service.enqueue([selected]);
      await service.setPlaybackSuspended(false);
      await _until(() => (service.files['file-a']?.received ?? 0) > 0);
      await service.pause('bundle-a');
      final offset = service.files['file-a']!.committed;
      expect(offset, greaterThan(0));
      await service.close();
      cache = null;
      service = await nativeCache();
      await service.setPlaybackSuspended(false);
      await service.resume('bundle-a');
      await _until(() => service.files['file-a']!.complete);
      expect(
        await File(selected.files.single.destination).readAsBytes(),
        source.bytes,
      );
    },
    skip: Platform.environment['PHASE5_PYTHON'] == null,
  );
}
