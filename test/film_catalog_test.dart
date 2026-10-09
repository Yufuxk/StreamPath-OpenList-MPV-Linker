import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/playback_history.dart';
import 'package:streampath/data/models/video_playback_scope.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/data/remote/webdav_client.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/cache_cleanup_service.dart';
import 'package:streampath/domain/services/film_catalog_matcher.dart';
import 'package:streampath/domain/services/film_catalog_scanner.dart';
import 'package:streampath/domain/services/local_media_source.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/domain/services/tmdb_http_client.dart';
import 'package:streampath/domain/services/webdav_media_source_adapter.dart';
import 'package:streampath/domain/services/webdav_service.dart';
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/localization/film_catalog_translations.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late Directory temp;
  late FilmCatalogStore store;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('film_catalog_test_');
    store = await FilmCatalogStore.open(p.join(temp.path, 'catalog.db'));
  });
  tearDown(() async {
    await store.close();
    await temp.delete(recursive: true);
  });

  test('TMDB Windows 手动代理选择 HTTPS 地址并遵守主机例外', () {
    final uri = Uri.parse('https://api.themoviedb.org/3/configuration');
    expect(
      tmdbProxyDirective(uri, proxy: '127.0.0.1:7897'),
      'PROXY 127.0.0.1:7897',
    );
    expect(
      tmdbProxyDirective(
        uri,
        proxy: 'http=localhost:8080;https=localhost:7897',
      ),
      'PROXY localhost:7897',
    );
    expect(tmdbProxyDirective(uri, proxy: 'http=localhost:8080'), 'DIRECT');
    expect(tmdbProxyDirective(uri, proxy: ''), 'DIRECT');
    expect(
      tmdbProxyDirective(
        uri,
        proxy: 'localhost:7897',
        bypass: '*.themoviedb.org',
      ),
      'DIRECT',
    );
    expect(
      tmdbProxyDirective(
        uri,
        proxy: 'localhost:7897',
        bypass: '<local>;localhost',
      ),
      'PROXY localhost:7897',
    );
  });

  for (final (type, code) in [
    (DioExceptionType.connectionError, 'metadataConnectionFailed'),
    (DioExceptionType.receiveTimeout, 'metadataTimeout'),
    (DioExceptionType.badCertificate, 'metadataTlsFailed'),
  ]) {
    test('TMDB 网络故障独立于认证错误 $type', () async {
      final credentials = _MemoryToken();
      final tmdb = TmdbMetadataService(
        credentials: credentials,
        dio: Dio()
          ..httpClientAdapter = _ApiAdapter((options) async {
            throw DioException(requestOptions: options, type: type);
          }),
      );
      addTearDown(tmdb.close);
      await expectLater(tmdb.verify(), throwsA(_code(code)));
      expect(await tmdb.hasToken(), isTrue);
      expect(credentials.token, 'fake-api-token');
    });
  }

  for (final type in [
    DioExceptionType.connectionError,
    DioExceptionType.connectionTimeout,
    DioExceptionType.sendTimeout,
    DioExceptionType.receiveTimeout,
  ]) {
    test('TMDB 连接失败切换固定备用域名并复用成功入口 $type', () async {
      var failingHost = 'api.themoviedb.org';
      final adapter = _ApiAdapter((options) async {
        if (options.uri.host == failingHost) {
          throw DioException(requestOptions: options, type: type);
        }
        return _imageConfig();
      });
      final tmdb = TmdbMetadataService(
        credentials: _MemoryToken(),
        dio: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(tmdb.close);
      await tmdb.verify();
      await tmdb.verify();
      failingHost = 'api.tmdb.org';
      await tmdb.verify();
      expect(adapter.requests.map((r) => r.uri.host), [
        'api.themoviedb.org',
        'api.tmdb.org',
        'api.tmdb.org',
        'api.tmdb.org',
        'api.themoviedb.org',
      ]);
      for (final request in adapter.requests) {
        expect(request.uri.scheme, 'https');
        expect(request.uri.path, '/3/configuration');
        expect(request.headers['Authorization'], 'Bearer fake-api-token');
        expect(request.followRedirects, isFalse);
      }
    });
  }

  test('TMDB 两个入口均失败时只尝试一次备用，取消与 TLS 错误不切换', () async {
    for (final (type, code, count) in [
      (DioExceptionType.connectionError, 'metadataConnectionFailed', 2),
      (DioExceptionType.receiveTimeout, 'metadataTimeout', 2),
      (DioExceptionType.badCertificate, 'metadataTlsFailed', 1),
      (DioExceptionType.cancel, 'metadataRequestFailed', 1),
    ]) {
      final adapter = _ApiAdapter((options) async {
        throw DioException(requestOptions: options, type: type);
      });
      final tmdb = TmdbMetadataService(
        credentials: _MemoryToken(),
        dio: Dio()..httpClientAdapter = adapter,
      );
      try {
        await expectLater(tmdb.verify(), throwsA(_code(code)));
        expect(adapter.requests.length, count);
      } finally {
        tmdb.close();
      }
    }
  });

  test('TMDB 在连接失败时取消服务不会发出备用请求', () async {
    late TmdbMetadataService tmdb;
    final adapter = _ApiAdapter((options) async {
      tmdb.close();
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
      );
    });
    tmdb = TmdbMetadataService(
      credentials: _MemoryToken(),
      dio: Dio()..httpClientAdapter = adapter,
    );
    await expectLater(tmdb.verify(), throwsA(_code('cancelled')));
    expect(adapter.requests.length, 1);
  });

  test('TMDB TLS 握手异常不作为连接故障切换域名', () async {
    final adapter = _ApiAdapter((options) async {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        error: const HandshakeException('fixture'),
      );
    });
    final tmdb = TmdbMetadataService(
      credentials: _MemoryToken(),
      dio: Dio()..httpClientAdapter = adapter,
    );
    addTearDown(tmdb.close);
    await expectLater(tmdb.verify(), throwsA(_code('metadataTlsFailed')));
    expect(adapter.requests.length, 1);
  });

  Future<FilmCatalogRoot> addRoot({
    String source = 'dav',
    String path = 'Movies',
    FilmMediaType type = FilmMediaType.movie,
    MediaSourceKind kind = MediaSourceKind.webdav,
  }) async {
    final id = await store.addRoot(
      sourceId: source,
      kind: kind,
      path: path,
      type: type,
      name: source,
    );
    return (await store.root(id))!;
  }

  Future<void> inventory(FilmCatalogRoot root, List<String> paths) async {
    final generation = await store.beginScan(root.id);
    await store.stage(root, generation, [
      for (final path in paths)
        FilmScanEntry(
          path: path,
          parentPath: p.posix.dirname(path) == '.' ? '' : p.posix.dirname(path),
          name: p.posix.basename(path),
          mediaKind: path.endsWith('.strm') ? 'strm' : 'video',
        ),
    ]);
    await store.commitScan(root.id, generation, cancelled: () => false);
  }

  test('通用缓存清理保留永久影视库并只删除可重建图片', () async {
    final data = Directory(p.join(temp.path, 'stream_path_data'));
    final library = Directory(p.join(data.path, 'library'));
    final artwork = Directory(p.join(data.path, 'cache', 'film_artwork'));
    await library.create(recursive: true);
    await artwork.create(recursive: true);
    final permanent = await FilmCatalogStore.open(
      p.join(library.path, 'film_catalog.db'),
    );
    try {
      await permanent.addRoot(
        sourceId: 'dav',
        kind: MediaSourceKind.webdav,
        path: 'Movies',
        type: FilmMediaType.movie,
        name: 'Movies',
      );
      await File(p.join(artwork.path, 'test.img')).writeAsBytes([1]);
      await CacheCleanupService(
        storeClearers: const [],
        dataDirectoryProvider: () async => data,
      ).clear();
      expect(await permanent.roots(), hasLength(1));
      expect(
        await File(p.join(library.path, 'film_catalog.db')).exists(),
        isTrue,
      );
      expect(await artwork.exists(), isFalse);
    } finally {
      await permanent.close();
    }
  });

  test('失败扫描已报告后关闭控制器正常释放数据库', () async {
    final lifetimeStore = await FilmCatalogStore.open(
      p.join(temp.path, 'lifetime.db'),
    );
    final id = await lifetimeStore.addRoot(
      sourceId: 'dav',
      kind: MediaSourceKind.webdav,
      path: 'Movies',
      type: FilmMediaType.movie,
      name: 'Movies',
    );
    final tmdb = TmdbMetadataService(credentials: _MemoryToken());
    final controller = FilmCatalogController(
      store: lifetimeStore,
      tmdb: tmdb,
      images: FilmCatalogImageCache(
        Directory(p.join(temp.path, 'lifetime_images')),
        tmdb,
      ),
      sourceFor: (_) => WebDavMediaSourceAdapter(
        _Dav((_) async => throw AppException.network('offline')),
      ),
    );
    await controller.scan((await lifetimeStore.root(id))!);
    expect(controller.error, 'directoryReadFailed');
    await controller.close();
    final reopened = await FilmCatalogStore.open(
      p.join(temp.path, 'lifetime.db'),
    );
    try {
      expect((await reopened.root(id))!.status, 'failed');
    } finally {
      await reopened.close();
    }
  });

  test('重扫保持资源 ID、人工匹配与季集；成功才标记 missing', () async {
    final root = await addRoot(path: 'TV', type: FilmMediaType.tv);
    await inventory(root, ['TV/Show.S01E01.mkv', 'TV/Show.S01E02.mkv']);
    final resource = (await store.resources(rootId: root.id)).first;
    await store.bind([resource], _work(FilmMediaType.tv, 10));
    final bound = (await store.resource(resource.id))!;
    await store.saveSeason(bound.workId!, 1, 'zh-CN', _season(1, [1, 2]));
    await store.mapEpisodes({bound: (1, 2)});
    await inventory(root, ['TV/Show.S01E01.mkv']);
    final after = (await store.resource(resource.id))!;
    expect(after.id, resource.id);
    expect(after.bindingOrigin, 'manual');
    expect(after.episode, 2);
    expect(after.mappingOrigin, 'manual');
    expect(
      (await store.resources(rootId: root.id)).last.availability,
      'missing',
    );
    expect((await store.root(root.id))!.status, 'completed');
    expect(await store.works(type: FilmMediaType.tv), hasLength(1));
  });

  test('取消完成事务回滚 missing 判定，保留旧记录与已发现资源', () async {
    final root = await addRoot();
    await inventory(root, ['Movies/old.mkv']);
    final generation = await store.beginScan(root.id);
    await store.stage(root, generation, [
      const FilmScanEntry(
        path: 'Movies/new.mkv',
        parentPath: 'Movies',
        name: 'new.mkv',
        mediaKind: 'video',
      ),
    ]);
    var checks = 0;
    await expectLater(
      store.commitScan(root.id, generation, cancelled: () => ++checks == 2),
      throwsA(_code('cancelled')),
    );
    await store.finishScan(root.id, generation, 'cancelled', 'cancelled');
    final resources = await store.resources(rootId: root.id);
    expect(
      resources.map((r) => r.name),
      unorderedEquals(['new.mkv', 'old.mkv']),
    );
    expect(resources.every((r) => r.availability == 'present'), isTrue);
  });

  test('删除根清理关联和 staging，过期提交不能重建根；保留作品缓存', () async {
    final root = await addRoot();
    await inventory(root, ['Movies/a.mkv']);
    await store.bind(
      await store.resources(rootId: root.id),
      _work(FilmMediaType.movie, 1),
    );
    final generation = await store.beginScan(root.id);
    await store.removeRoot(root.id);
    await expectLater(
      store.commitScan(root.id, generation, cancelled: () => false),
      throwsA(_code('staleScan')),
    );
    expect(await store.resources(), isEmpty);
    expect(await store.cachedWork(FilmMediaType.movie, 1), isNotNull);
    expect(await store.works(type: FilmMediaType.movie), isEmpty);
  });

  test('movie/tv ID 独立；同名跨来源资源隔离；来源筛选和参数化搜索', () async {
    final a = await addRoot(source: 'a');
    final b = await addRoot(source: 'b');
    final tv = await addRoot(source: 'c', type: FilmMediaType.tv);
    for (final root in [a, b, tv]) {
      await inventory(root, ['Movies/a.mkv']);
    }
    final movie = _work(FilmMediaType.movie, 99);
    await store.bind(await store.resources(rootId: a.id), movie);
    await store.bind(await store.resources(rootId: b.id), movie);
    await store.bind(
      await store.resources(rootId: tv.id),
      _work(FilmMediaType.tv, 99),
    );
    expect(
      (await store.works(type: FilmMediaType.movie)).single.resourceCount,
      2,
    );
    expect(
      (await store.works(
        type: FilmMediaType.movie,
        sourceId: 'a',
      )).single.resourceCount,
      1,
    );
    expect(
      (await store.works(type: FilmMediaType.tv)).single.id,
      isNot((await store.works(type: FilmMediaType.movie)).single.id),
    );
    expect(
      await store.works(type: FilmMediaType.movie, query: "' OR 1=1 --"),
      isEmpty,
    );
    await expectLater(
      store.bind(
        await store.resources(rootId: a.id),
        _work(FilmMediaType.tv, 1),
      ),
      throwsA(_code('wrongMediaType')),
    );
  });

  test('关联版本拒绝迟到响应，批量写入全部回滚', () async {
    final root = await addRoot();
    await inventory(root, ['Movies/a.mkv', 'Movies/b.mkv']);
    final snapshots = await store.resources(rootId: root.id);
    await store.bind([snapshots.last], _work(FilmMediaType.movie, 2));
    await expectLater(
      store.bind(snapshots, _work(FilmMediaType.movie, 1)),
      throwsA(_code('staleMatch')),
    );
    expect((await store.resource(snapshots.first.id))!.workId, isNull);
    expect((await store.resource(snapshots.last.id))!.bindingOrigin, 'manual');
  });

  test('根重叠与本地大小写按来源校验，WebDAV 保留大小写', () async {
    await addRoot(source: 'local:x', kind: MediaSourceKind.local);
    for (final path in ['movies', 'Movies/Child', '']) {
      await expectLater(
        addRoot(source: 'local:x', kind: MediaSourceKind.local, path: path),
        throwsA(_code('overlappingRoot')),
      );
    }
    await addRoot(path: 'Movies');
    await addRoot(path: 'movies');
    for (final path in [
      '../a',
      '/Movies',
      'A//B',
      'https://host/secret',
      'A/../B',
    ]) {
      await expectLater(
        addRoot(source: 'bad', path: path),
        throwsA(_code('invalidPath')),
      );
    }
  });

  test('应用重新打开清理中断 staging，正式清单仍在', () async {
    final root = await addRoot();
    await inventory(root, ['Movies/a.mkv']);
    await store.beginScan(root.id);
    await store.close();
    store = await FilmCatalogStore.open(p.join(temp.path, 'catalog.db'));
    expect((await store.root(root.id))!.lastError, 'interrupted');
    expect(
      (await store.resources(rootId: root.id)).single.availability,
      'present',
    );
  });

  test('WebDAV 扫描仅强制目录清单，编码路径、STRM 与特典递归', () async {
    final root = await addRoot(path: '影视');
    final dav = _Dav(
      (path) async => path == '影视'
          ? [
              _file('影视/电影 100%.mkv'),
              _file('影视/entry.strm'),
              _file('影视/disc.iso'),
              _file('影视/OVA', directory: true),
              _file('影视/Show', directory: true),
            ]
          : [_file('$path/E01.mkv')],
    );
    final scanner = FilmCatalogScanner(store, remoteInterval: Duration.zero);
    await scanner.scan(root, WebDavMediaSourceAdapter(dav));
    expect(dav.readPaths, ['影视', '影视/OVA', '影视/Show']);
    expect(dav.refreshes, everyElement(isTrue));
    expect(
      (await store.resources()).map((r) => r.path),
      containsAll([
        '影视/电影 100%.mkv',
        '影视/entry.strm',
        '影视/disc.iso',
        '影视/Show/E01.mkv',
        '影视/OVA/E01.mkv',
      ]),
    );
    expect(await store.resources(), hasLength(5));
    expect(
      (await store.resources())
          .singleWhere((r) => r.mediaKind == 'iso')
          .playbackItem
          .kind,
      MediaLibraryKind.iso,
    );
  });

  test('WebDAV 请求失败和跨源 href 不改变已入库可用性', () async {
    final root = await addRoot();
    await inventory(root, ['Movies/old.mkv']);
    for (final dav in [
      _Dav((_) async => throw AppException.network('Offline')),
      _Dav(
        (_) async => [
          const WebDavFile(
            name: 'bad.mkv',
            href: 'https://evil.example/a.mkv',
            isDirectory: false,
          ),
        ],
      ),
    ]) {
      await expectLater(
        FilmCatalogScanner(store).scan(root, WebDavMediaSourceAdapter(dav)),
        throwsA(isA<FilmCatalogException>()),
      );
      expect((await store.resources()).single.availability, 'present');
    }
  });

  test('取消待返回目录请求以及扫描期间移除根均拒绝提交', () async {
    final root = await addRoot();
    await inventory(root, ['Movies/old.mkv']);
    final pending = Completer<List<WebDavFile>>();
    final dav = _Dav((_) => pending.future);
    final scanner = FilmCatalogScanner(store);
    final scan = scanner.scan(root, WebDavMediaSourceAdapter(dav));
    while (dav.readPaths.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    scanner.cancel();
    pending.complete([_file('Movies/new.mkv')]);
    await expectLater(scan, throwsA(_code('cancelled')));
    expect((await store.resources()).single.name, 'old.mkv');
    final removed = Completer<List<WebDavFile>>();
    final second = _Dav((_) => removed.future);
    final scan2 = scanner.scan(root, WebDavMediaSourceAdapter(second));
    while (second.readPaths.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    await store.removeRoot(root.id);
    removed.complete([_file('Movies/new.mkv')]);
    await expectLater(scan2, throwsA(_code('staleScan')));
    expect(await store.resources(), isEmpty);
  });

  test('本地名称扫描收录 ISO 与整盘 BDMV，排除本地 STRM，不递归蓝光内部', () async {
    final media = Directory(p.join(temp.path, 'Media'))..createSync();
    for (final path in [
      'Movie/a.mkv',
      'entry.strm',
      'disc.iso',
      'OVA/b.mkv',
      'Nested/A/B/C/D/E/F/G/deep.mkv',
      'Disc/BDMV/STREAM/001.m2ts',
    ]) {
      final file = File(p.join(media.path, path));
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync([0]);
    }
    final local = LocalMediaSource(
      LocalRootConfig(rootId: 'scan', displayName: 'Local', path: media.path),
    );
    final root = await addRoot(
      source: 'local:scan',
      path: '',
      kind: MediaSourceKind.local,
    );
    await FilmCatalogScanner(store).scan(root, local);
    expect(
      (await store.resources()).map((r) => r.path),
      unorderedEquals([
        'Movie/a.mkv',
        'OVA/b.mkv',
        'Nested/A/B/C/D/E/F/G/deep.mkv',
        'Disc',
        'disc.iso',
      ]),
    );
    expect(local.cachedDirectory('Movie'), isNull);
  });

  test('明确 ID 在解析前提取，支持 S00，冲突、多集和绝对集号留待整理', () async {
    final root = await addRoot(type: FilmMediaType.tv, path: 'TV');
    final paths = [
      'TV/Show {tmdb-10}/Show.S01E01.[tmdbid-20].mkv',
      'TV/Show [TMDB-10]/Show.S01E01.mkv',
      'TV/S01E01-E02.mkv',
      'TV/S01E01E02.mkv',
      'TV/S01E01+E02.mkv',
      'TV/S01E01-03.mkv',
      'TV/S00E01.mkv',
      'TV/Show - 023.mkv',
    ];
    await inventory(root, paths);
    final resources = await store.resources(rootId: root.id);
    expect(
      FilmCatalogMatcher.hint(
        resources.firstWhere((r) => r.path == paths[0]),
      ).conflicting,
      isTrue,
    );
    final single = resources.firstWhere((r) => r.path == paths[1]);
    expect(FilmCatalogMatcher.hint(single).ids, {10});
    expect(FilmCatalogMatcher.hint(single).episode, (1, 1));
    expect(
      FilmCatalogMatcher.hint(
        resources.firstWhere((r) => r.path == 'TV/S00E01.mkv'),
      ).episode,
      (0, 1),
    );
    for (final path in paths.skip(2).where((p) => p != 'TV/S00E01.mkv')) {
      expect(
        FilmCatalogMatcher.hint(
          resources.firstWhere((r) => r.path == path),
        ).episode,
        isNull,
      );
    }
    await inventory(root, [
      'TV/Show.S01E01.1080p.mkv',
      'TV/Show.S01E02.10bit.mkv',
    ]);
    for (final resource in await store.resources(rootId: root.id)) {
      if (resource.availability != 'present') continue;
      expect(FilmCatalogMatcher.hint(resource).episode, (
        1,
        resource.name.contains('E01') ? 1 : 2,
      ));
    }
  });

  test('明确 ID 与目录继承复用作品/季，人工映射优先，新集不逐集搜索', () async {
    final root = await addRoot(type: FilmMediaType.tv, path: 'TV');
    await inventory(root, [
      'TV/Show [tmdb-10]/S01E01.mkv',
      'TV/Show [tmdb-10]/S01E02.mkv',
    ]);
    final adapter = _ApiAdapter(
      (options) async => options.path.contains('/season/')
          ? _season(1, [1, 2, 3])
          : _details(FilmMediaType.tv, 10),
    );
    final tmdb = TmdbMetadataService(
      credentials: _MemoryToken(),
      dio: Dio()..httpClientAdapter = adapter,
    );
    addTearDown(tmdb.close);
    final matcher = FilmCatalogMatcher(store, tmdb);
    await matcher.organize(root.id);
    expect(adapter.requests, hasLength(3));
    var resources = await store.resources(rootId: root.id);
    expect(resources.map((r) => r.episode), [1, 2]);
    final work = (await store.work(resources.first.workId!))!;
    await store.bind(resources, work, directoryPath: 'TV/Show [tmdb-10]');
    resources = await store.resources(rootId: root.id);
    await store.mapEpisodes({resources.first: (1, 3)});
    await inventory(root, [
      'TV/Show [tmdb-10]/S01E01.mkv',
      'TV/Show [tmdb-10]/S01E02.mkv',
      'TV/Show [tmdb-10]/S01E03.mkv',
      'TV/Show [tmdb-10]/S01E04.mkv',
    ]);
    await matcher.organize(root.id);
    resources = await store.resources(rootId: root.id);
    expect(resources.first.episode, 3);
    expect(resources[2].episode, 3);
    expect(resources.last.episode, 4);
    expect(adapter.requests, hasLength(3));
  });

  test('跨作品更换清除旧季集；无官方资料的集号可以保存', () async {
    final root = await addRoot(type: FilmMediaType.tv);
    await inventory(root, ['Movies/S01E01.mkv']);
    await store.bind(await store.resources(), _work(FilmMediaType.tv, 1));
    final resource = (await store.resources()).single;
    await store.saveSeason(resource.workId!, 1, 'zh-CN', _season(1, [1]));
    await store.mapEpisodes({resource: (1, 2)});
    expect((await store.resources()).single.episode, 2);
    final updated = (await store.resources()).single;
    await store.mapEpisodes({updated: (1, 1)});
    await store.bind(await store.resources(), _work(FilmMediaType.tv, 2));
    expect((await store.resources()).single.season, isNull);
  });

  for (final status in [302, 401, 403, 404, 429, 500]) {
    test('TMDB $status 不泄露令牌且无自动重试', () async {
      final adapter = _ApiAdapter((_) async => {}, status: status);
      final tmdb = TmdbMetadataService(
        credentials: _MemoryToken(),
        dio: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(tmdb.close);
      final expected = switch (status) {
        401 || 403 => 'invalidToken',
        404 => 'metadataNotFound',
        429 => 'rateLimited',
        _ => 'metadataRequestFailed',
      };
      await expectLater(
        tmdb.details(FilmMediaType.movie, 1, 'zh-CN'),
        throwsA(_code(expected)),
      );
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.uri.host, 'api.themoviedb.org');
      expect(adapter.requests.single.followRedirects, isFalse);
      expect(
        adapter.requests.single.uri.toString(),
        isNot(contains('fake-api-token')),
      );
      if ([401, 403, 429].contains(status)) {
        await expectLater(
          tmdb.details(FilmMediaType.movie, 2, 'zh-CN'),
          throwsA(_code(expected)),
        );
        expect(adapter.requests, hasLength(1));
      }
    });
  }

  test('重复并发详情合并且缺失身份字段明确失败', () async {
    final gate = Completer<void>();
    final adapter = _ApiAdapter((_) async {
      await gate.future;
      return _details(FilmMediaType.movie, 1);
    });
    final tmdb = TmdbMetadataService(
      credentials: _MemoryToken(),
      dio: Dio()..httpClientAdapter = adapter,
    );
    addTearDown(tmdb.close);
    final first = tmdb.details(FilmMediaType.movie, 1, 'zh-CN');
    final second = tmdb.details(FilmMediaType.movie, 1, 'zh-CN');
    gate.complete();
    await Future.wait([first, second]);
    expect(adapter.requests, hasLength(2));
    final bad = TmdbMetadataService(
      credentials: _MemoryToken(),
      dio: Dio()..httpClientAdapter = _ApiAdapter((_) async => {'id': 0}),
    );
    addTearDown(bad.close);
    await expectLater(
      bad.details(FilmMediaType.movie, 1, 'zh-CN'),
      throwsA(_code('invalidMetadata')),
    );
  });

  test('图片尺寸来自配置，缓存离线复用，API 凭据不进入图片请求', () async {
    final config = _ApiAdapter((_) async => _imageConfig());
    final tmdb = TmdbMetadataService(
      credentials: _MemoryToken(),
      dio: Dio()..httpClientAdapter = config,
    );
    addTearDown(tmdb.close);
    final images = _ImageAdapter();
    final cache = FilmCatalogImageCache(
      Directory(p.join(temp.path, 'images')),
      tmdb,
      dio: Dio()..httpClientAdapter = images,
      validateImage: (_) async {},
    );
    addTearDown(cache.close);
    final result = await cache.get('/a.jpg');
    expect(await result.exists(), isTrue);
    expect(images.requests.single.uri.path, '/t/p/w500/a.jpg');
    expect(images.requests.single.headers['Authorization'], isNull);
    expect(images.requests.single.followRedirects, isFalse);
    await tmdb.clearToken();
    expect((await cache.get('/a.jpg')).path, result.path);
    expect(images.requests, hasLength(1));
    final offline = FilmCatalogImageCache(
      cache.directory,
      tmdb,
      dio: Dio()..httpClientAdapter = images,
      validateImage: (_) async {},
    );
    addTearDown(offline.close);
    expect((await offline.get('/a.jpg')).path, result.path);
    expect(images.requests, hasLength(1));
    await expectLater(
      cache.get('/../escape.jpg'),
      throwsA(_code('invalidImage')),
    );
    await cache.directory.delete(recursive: true);
    final rebuilt = await cache.get('/b.jpg');
    expect(await rebuilt.exists(), isTrue);
    expect(images.requests, hasLength(2));
    final reopened = FilmCatalogImageCache(
      cache.directory,
      tmdb,
      dio: Dio()..httpClientAdapter = images,
      validateImage: (_) async {},
    );
    addTearDown(reopened.close);
    expect((await reopened.get('/b.jpg')).path, rebuilt.path);
    expect(images.requests, hasLength(2));
  });

  test('图片流式上限、失败清理 partial 与预算仅删除专用缓存', () async {
    final tmdb = TmdbMetadataService(
      credentials: _MemoryToken(),
      dio: Dio()..httpClientAdapter = _ApiAdapter((_) async => _imageConfig()),
    );
    addTearDown(tmdb.close);
    final directory = Directory(p.join(temp.path, 'images'))..createSync();
    final outside = File(p.join(temp.path, 'keep'))
      ..writeAsStringSync('source');
    final unknown = File(p.join(directory.path, 'keep.txt'))
      ..writeAsStringSync('keep');
    final adapter = _ImageAdapter(bytes: [1, 2, 3, 4]);
    final tooLarge = FilmCatalogImageCache(
      directory,
      tmdb,
      maxImageBytes: 2,
      dio: Dio()..httpClientAdapter = adapter,
      validateImage: (_) async {},
    );
    await expectLater(
      tooLarge.get('/large.jpg'),
      throwsA(_code('imageTooLarge')),
    );
    tooLarge.close();
    expect(
      directory.listSync().where((f) => f.path.endsWith('.partial')),
      isEmpty,
    );
    final cache = FilmCatalogImageCache(
      directory,
      tmdb,
      budgetBytes: 4,
      dio: Dio()..httpClientAdapter = adapter,
      validateImage: (_) async {},
    );
    addTearDown(cache.close);
    final first = await cache.get('/one.jpg');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final second = await cache.get('/two.jpg');
    expect(await first.exists(), isFalse);
    expect(await second.exists(), isTrue);
    expect(await outside.readAsString(), 'source');
    expect(await unknown.readAsString(), 'keep');
  });

  test('真实图像解码校验接受 PNG、拒绝损坏字节并保留有效缓存', () async {
    final tmdb = TmdbMetadataService(
      credentials: _MemoryToken(),
      dio: Dio()..httpClientAdapter = _ApiAdapter((_) async => _imageConfig()),
    );
    addTearDown(tmdb.close);
    final adapter = _ImageAdapter(
      bytes: await File('assets/tmdb_logo.png').readAsBytes(),
    );
    final cache = FilmCatalogImageCache(
      Directory(p.join(temp.path, 'decoded_images')),
      tmdb,
      dio: Dio()..httpClientAdapter = adapter,
    );
    addTearDown(cache.close);
    final image = await cache.get('/valid.png');
    expect(await image.exists(), isTrue);
    final bad = FilmCatalogImageCache(
      cache.directory,
      tmdb,
      dio: Dio()..httpClientAdapter = _ImageAdapter(),
    );
    addTearDown(bad.close);
    await expectLater(bad.get('/corrupt.png'), throwsA(_code('invalidImage')));
    expect(await image.exists(), isTrue);
    expect(
      await cache.directory
          .list()
          .where((file) => file.path.endsWith('.partial'))
          .isEmpty,
      isTrue,
    );
  });

  test('旧 JSON 默认目录，新单项范围跨 copyWith 和 JSON 保存且 stableKey 不变', () {
    const old = MediaLibraryItem(
      sourceId: 'dav',
      parentPath: 'Movies',
      name: 'a.mkv',
      kind: MediaLibraryKind.video,
    );
    const single = MediaLibraryItem(
      sourceId: 'dav',
      parentPath: 'Movies',
      name: 'a.mkv',
      kind: MediaLibraryKind.video,
      playbackScope: VideoPlaybackScope.singleItem,
    );
    final json = old.toJson()..remove('playbackScope');
    expect(
      MediaLibraryItem.fromJson(json).playbackScope,
      VideoPlaybackScope.directory,
    );
    expect(
      MediaLibraryItem.fromJson(single.toJson()).playbackScope,
      VideoPlaybackScope.singleItem,
    );
    expect(single.stableKey, old.stableKey);
    final history = PlaybackHistory(
      dirCrumbs: const ['Movies'],
      fileName: 'a.mkv',
      videoIndex: 0,
      updatedAt: DateTime.now(),
      playbackScope: VideoPlaybackScope.singleItem,
    );
    expect(
      PlaybackHistory.fromJson(
        history.copyWith(playerPid: 99).toJson(),
      ).playbackScope,
      VideoPlaybackScope.singleItem,
    );
    expect(
      () => MediaLibraryItem.fromJson({...json, 'playbackScope': 'unknown'}),
      throwsFormatException,
    );
  });

  test('缓存播放标题按季集映射取 TMDB，缺失映射留给旧命名并隔离来源', () async {
    final root = await addRoot(type: FilmMediaType.tv);
    final paths = [
      'Movies/01.mkv',
      'Movies/special.strm',
      'Movies/unmapped.mkv',
    ];
    await inventory(root, paths);
    final resources = await store.resources();
    await store.bind(
      resources,
      const FilmWork(
        type: FilmMediaType.tv,
        tmdbId: 10,
        title: 'TMDB 剧名',
        originalTitle: 'Original',
        overview: '',
        language: 'zh-CN',
        year: 2023,
      ),
    );
    final bound = await store.resources();
    await store.mapEpisodes({bound[0]: (2, 123), bound[1]: (0, 1)});
    await store.saveSeason(bound[0].workId!, 2, 'zh-CN', {
      'episodes': [
        {'episode_number': 123, 'name': '长' * 49},
      ],
    });
    final titles = await store.videoPlaylistTitles('dav', paths);
    expect(titles[paths[0]], 'TMDB 剧名·2023·S02E123·${'长' * 45}...');
    expect(titles[paths[1]], 'TMDB 剧名·2023·S00E01');
    expect(titles.containsKey(paths[2]), isFalse);
    expect(await store.videoPlaylistTitles('other', paths), isEmpty);
    expect(await store.videoPlaylistTitles('dav', []), isEmpty);
  });

  test('电影缓存标题保留名称年份，本地路径忽略大小写，批量读取完整', () async {
    final id = await store.addRoot(
      sourceId: 'local:titles',
      kind: MediaSourceKind.local,
      path: 'Movies',
      type: FilmMediaType.movie,
      name: 'Movies',
    );
    final root = (await store.root(id))!;
    final paths = [for (var i = 0; i < 205; i++) 'Movies/Movie$i.mkv'];
    await inventory(root, paths);
    await store.bind(
      await store.resources(),
      const FilmWork(
        type: FilmMediaType.movie,
        tmdbId: 1,
        title: '电影名',
        originalTitle: 'Original',
        overview: '',
        language: 'zh-CN',
        year: 2020,
      ),
    );
    final requested = paths.map((path) => path.toUpperCase()).toList();
    final titles = await store.videoPlaylistTitles(root.sourceId, requested);
    expect(titles, hasLength(205));
    expect(titles.values.toSet(), {'电影名·2020'});
    expect(titles.keys, requested);
  });

  test('影视目录范围经过两种真实持久化存储和重启仍保留', () async {
    final root = await addRoot();
    await inventory(root, ['Movies/a.mkv']);
    final item = (await store.resources()).single.playbackItem;
    final historyPath = p.join(temp.path, 'playback.json');
    final history = PlaybackHistory(
      dirCrumbs: const ['Movies'],
      fileName: 'a.mkv',
      videoIndex: 0,
      updatedAt: DateTime.now(),
      playbackScope: item.playbackScope,
    );
    await PlaybackHistoryStore.forPath(historyPath).upsert(history);
    final reloaded = (await PlaybackHistoryStore.forPath(
      historyPath,
    ).loadAll()).single;
    expect(reloaded.playbackScope, VideoPlaybackScope.directory);
    final libraryPath = p.join(temp.path, 'library.json');
    final library = MediaLibraryStore.forPath(libraryPath);
    await library.recordPlayback(item, playbackSessionId: 'film');
    expect(
      (await MediaLibraryStore.forPath(
        libraryPath,
      ).playbackHistory('dav', audio: false)).single.item.playbackScope,
      VideoPlaybackScope.directory,
    );
  });

  test('同一图片不同视图回退到同一尺寸时合并下载', () async {
    final tmdb = TmdbMetadataService(
      credentials: _MemoryToken(),
      dio: Dio()..httpClientAdapter = _ApiAdapter((_) async => _imageConfig()),
    );
    addTearDown(tmdb.close);
    final adapter = _ImageAdapter();
    final cache = FilmCatalogImageCache(
      Directory(p.join(temp.path, 'images')),
      tmdb,
      dio: Dio()..httpClientAdapter = adapter,
      validateImage: (_) async {},
    );
    addTearDown(cache.close);
    final images = await Future.wait([
      cache.get('/a.jpg'),
      cache.get('/a.jpg', target: 'w500'),
    ]);
    expect(images.first.path, images.last.path);
    expect(adapter.requests, hasLength(1));
  });

  test('TMDB 超时返回可见错误，元数据缓存保留', () async {
    final work = _work(FilmMediaType.movie, 1);
    await store.refreshWork(work);
    final tmdb = TmdbMetadataService(
      credentials: _MemoryToken(),
      dio: Dio()
        ..httpClientAdapter = _ApiAdapter(
          (options) async => throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionTimeout,
          ),
        ),
    );
    addTearDown(tmdb.close);
    await expectLater(
      FilmCatalogMatcher(
        store,
        tmdb,
      ).refresh((await store.cachedWork(FilmMediaType.movie, 1))!),
      throwsA(_code('metadataTimeout')),
    );
    expect((await store.cachedWork(FilmMediaType.movie, 1))!.title, work.title);
  });

  test('10,000 文件与 1,000 作品的清单提交和首批查询基准', () async {
    final root = await addRoot();
    final dav = _Dav(
      (path) async => path == 'Movies'
          ? [
              for (var i = 0; i < 1000; i++)
                _file('Movies/Film$i', directory: true),
            ]
          : [for (var i = 0; i < 10; i++) _file('$path/Version$i.mkv')],
    );
    final watch = Stopwatch()..start();
    await FilmCatalogScanner(
      store,
      remoteInterval: Duration.zero,
    ).scan(root, WebDavMediaSourceAdapter(dav));
    final scanMs = watch.elapsedMilliseconds;
    final resources = await store.resources(rootId: root.id);
    final grouped = <String, List<FilmResource>>{};
    for (final resource in resources) {
      grouped.putIfAbsent(resource.parentPath, () => []).add(resource);
    }
    var id = 1;
    for (final group in grouped.values) {
      await store.bind(group, _work(FilmMediaType.movie, id++));
    }
    watch.reset();
    final page = await store.works(type: FilmMediaType.movie);
    final queryMs = watch.elapsedMilliseconds;
    expect(resources, hasLength(10000));
    expect(page, hasLength(60));
    expect(dav.readPaths, hasLength(1001));
    // 仅测试清单与 SQLite；不代表真实网盘耗时或滚动内存。
    // ignore: avoid_print
    print(
      'Film catalog benchmark: files=10000 works=1000 directories=1001 scan_ms=$scanMs first_page_ms=$queryMs',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('逐目录先登记资源，名称刮削与元数据独立关联', () async {
    final root = await addRoot();
    final events = <String>[];
    final dav = _Dav((path) async {
      events.add('directory:$path');
      return path == 'Movies'
          ? [
              _file('Movies/Iron.Man.3.2013.PROPER.2160P.BluRay.REMUX.mkv'),
              _file('Movies/Child', directory: true),
            ]
          : [_file('Movies/Child/Iron.Man.3.2013.1080p.mkv')];
    });
    final adapter = _ApiAdapter((options) async {
      events.add('tmdb:${options.uri.path}');
      expect(await store.resources(rootId: root.id), isNotEmpty);
      final data = {
        ..._details(FilmMediaType.movie, 68721),
        'title': '钢铁侠3',
        'original_title': 'Iron Man 3',
        'release_date': '2013-04-24',
      };
      if (options.path.contains('/search/')) {
        expect(options.queryParameters['query'], 'Iron Man 3');
        expect(options.queryParameters['year'], 2013);
        return {
          'results': [data],
        };
      }
      return data;
    });
    final tmdb = TmdbMetadataService(
      credentials: _MemoryToken(),
      dio: Dio()..httpClientAdapter = adapter,
    );
    addTearDown(tmdb.close);
    final metadata = await FilmCatalogMatcher(
      store,
      tmdb,
    ).scanSession(root, cancelled: () => false);
    await FilmCatalogScanner(
      store,
      remoteInterval: Duration.zero,
    ).scan(root, WebDavMediaSourceAdapter(dav), onEntries: metadata.prepare);
    await store.applyMetadata(root.id, metadata.matches);
    expect(
      events.indexOf('tmdb:/3/search/movie'),
      lessThan(events.indexOf('directory:Movies/Child')),
    );
    expect(adapter.requests, hasLength(3));
    final resources = await store.resources(rootId: root.id);
    expect(resources.map((r) => r.bindingOrigin), everyElement('search'));
    expect(resources.map((r) => r.workId).toSet(), hasLength(1));
    expect(
      (await store.works(type: FilmMediaType.movie)).single.originalTitle,
      'Iron Man 3',
    );
  });

  test('同名候选歧义与年份不符保留待整理，不采用搜索排名', () async {
    final root = await addRoot();
    final adapter = _ApiAdapter(
      (_) async => {
        'results': [
          {
            ..._details(FilmMediaType.movie, 1),
            'title': 'Twin',
            'original_title': 'Twin',
            'release_date': '2020-01-01',
          },
          {
            ..._details(FilmMediaType.movie, 2),
            'title': 'Twin',
            'original_title': 'Twin',
            'release_date': '2020-01-01',
          },
        ],
      },
    );
    final tmdb = TmdbMetadataService(
      credentials: _MemoryToken(),
      dio: Dio()..httpClientAdapter = adapter,
    );
    addTearDown(tmdb.close);
    final metadata = await FilmCatalogMatcher(
      store,
      tmdb,
    ).scanSession(root, cancelled: () => false);
    final dav = _Dav(
      (_) async => [
        _file('Movies/Twin.2020.mkv'),
        _file('Movies/Twin.2019.mkv'),
      ],
    );
    await FilmCatalogScanner(
      store,
    ).scan(root, WebDavMediaSourceAdapter(dav), onEntries: metadata.prepare);
    await store.applyMetadata(root.id, metadata.matches);
    expect(
      (await store.resources()).map((r) => r.workId),
      everyElement(isNull),
    );
    expect(adapter.requests, hasLength(2));
  });

  test('电影特别篇保留完整片名与年份，不套用剧集显示解析', () {
    final hint = FilmCatalogMatcher.scanHint(
      '死亡笔记特别篇：幻影之神.2007.mkv',
      'Movies',
      'Movies',
      type: FilmMediaType.movie,
    );
    expect(hint.title, '死亡笔记特别篇：幻影之神');
    expect(hint.year, 2007);
    expect(hint.episode, isNull);
  });

  for (final sample in const [
    (
      'Moon.and.Cabbage.1996.mkv',
      461922,
      '月亮与高丽菜',
      '月とキャベツ',
      1996,
      'Moon and Cabbage',
    ),
    (
      '5.Centimeters.per.Second.2007.mkv',
      38142,
      '秒速五厘米',
      '秒速5センチメートル',
      2007,
      '5 Centimeters per Second',
    ),
    (
      '剧场版 CLANNAD.2007.mkv',
      16516,
      'CLANNAD 剧场版',
      'CLANNAD -クラナド-',
      2007,
      'Clannad',
    ),
    (
      '寒蝉鸣泣时之·扩.2013.mkv',
      300442,
      '寒蝉鸣泣之时·扩',
      'ひぐらしのなく頃に 拡',
      2013,
      'Higurashi Outbreak',
    ),
    (
      '进击的巨人：后篇～自由之翼～.2015.mkv',
      330081,
      '进击的巨人：后篇 ~自由之翼~',
      '劇場版「進撃の巨人」後編',
      2015,
      'Attack on Titan',
    ),
    (
      '刀剑神域进击篇：无星之夜的咏叹调.2021.mkv',
      761898,
      '刀剑神域进击篇：无星之夜',
      'ソードアート・オンライン',
      2021,
      '剧场版 刀剑神域 进击篇 无星之夜的咏叹调',
    ),
    (
      'Cosmic.Princess.Kaguya!.2026.mkv',
      1575337,
      '超时空辉夜姬！',
      '超かぐや姫！',
      2026,
      'Cosmic Princess Kaguya!',
    ),
    (
      '死亡笔记特别篇：幻影之神.2007.mkv',
      51482,
      '死亡笔记特别篇：幻影之神',
      'DEATH NOTE リライト ～幻視する神～',
      2007,
      'Death Note Relight',
    ),
    (
      '死亡笔记特别篇2：L的继承者.2009.mkv',
      68555,
      '死亡笔记特别篇2：L的继承者',
      'デスノート：リライト2 Lを継ぐ者',
      2009,
      'Death Note Relight 2',
    ),
  ]) {
    test('截图影片自动匹配 ${sample.$1}', () async {
      final root = await addRoot();
      final data = {
        ..._details(FilmMediaType.movie, sample.$2),
        'title': sample.$3,
        'original_title': sample.$4,
        'release_date': '${sample.$5}-01-01',
      };
      final adapter = _ApiAdapter((options) async {
        if (options.path.contains('/search/')) {
          return {
            'results': [data],
          };
        }
        if (options.queryParameters['append_to_response'] != null) {
          return {
            ...data,
            'alternative_titles': {
              'titles': [
                {'title': sample.$6},
              ],
            },
            'translations': {'translations': []},
          };
        }
        return data;
      });
      final tmdb = TmdbMetadataService(
        credentials: _MemoryToken(),
        dio: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(tmdb.close);
      final session = await FilmCatalogMatcher(
        store,
        tmdb,
      ).scanSession(root, cancelled: () => false);
      await session.prepare([
        FilmScanEntry(
          path: 'Movies/${sample.$1}',
          parentPath: 'Movies',
          name: sample.$1,
          mediaKind: 'video',
        ),
      ]);
      expect(session.matches.values.single.work.tmdbId, sample.$2);
      expect(session.error, isNull);
    });
  }

  test('同年多个别名候选仍保留待整理，核验失败保留错误', () async {
    final root = await addRoot();
    final candidates = [
      for (final id in [1, 2])
        {
          ..._details(FilmMediaType.movie, id),
          'title': 'Other $id',
          'original_title': '別名 $id',
        },
    ];
    final adapter = _ApiAdapter((options) async {
      if (options.path.contains('/search/')) return {'results': candidates};
      final id = int.parse(options.path.split('/').last);
      return {
        'id': id,
        'alternative_titles': {
          'titles': [
            {'title': 'Alias'},
          ],
        },
        'translations': {'translations': []},
      };
    });
    final tmdb = TmdbMetadataService(
      credentials: _MemoryToken(),
      dio: Dio()..httpClientAdapter = adapter,
    );
    addTearDown(tmdb.close);
    final session = await FilmCatalogMatcher(
      store,
      tmdb,
    ).scanSession(root, cancelled: () => false);
    await session.prepare([
      const FilmScanEntry(
        path: 'Movies/Alias.2020.mkv',
        parentPath: 'Movies',
        name: 'Alias.2020.mkv',
        mediaKind: 'video',
      ),
    ]);
    expect(session.matches, isEmpty);
    expect(session.paused, isFalse);
    expect(adapter.requests, hasLength(3));
    final bad = TmdbMetadataService(
      credentials: _MemoryToken(),
      dio: Dio()..httpClientAdapter = _ApiAdapter((_) async => {'id': 1}),
    );
    addTearDown(bad.close);
    await expectLater(
      bad.matchingTitles(FilmMediaType.movie, 1),
      throwsA(_code('invalidMetadata')),
    );
  });

  for (final sample in const [
    ('Weathering.with.Yuo.2019.mkv', ['Weathering with You'], [2019], true),
    (
      'Cosmic.Princes.Kaguya.2026.mkv',
      ['Cosmic Princess Kaguya'],
      [2026],
      true,
    ),
    ('进击的巨人编年使.2020.mkv', ['进击的巨人编年史'], [2020], true),
    (
      'Alpha.Gamma.2020.mkv',
      ['Alpha Gama', 'Alpha Gammb'],
      [2020, 2020],
      false,
    ),
    ('Iron.Man.2.2013.mkv', ['Iron Man 3'], [2013], false),
    ('Weathering.with.Yuo.2019.mkv', ['Weathering with You'], [2018], false),
    ('Hero.2020.mkv', ['Hera'], [2020], false),
  ]) {
    test('模糊匹配及歧义、年份和续作数字边界 $sample', () async {
      final root = await addRoot();
      final rows = [
        for (var i = 0; i < sample.$2.length; i++)
          {
            ..._details(FilmMediaType.movie, i + 1),
            'title': sample.$2[i],
            'original_title': sample.$2[i],
            'release_date': '${sample.$3[i]}-01-01',
          },
      ];
      final adapter = _ApiAdapter((options) async {
        if (options.path.contains('/search/')) return {'results': rows};
        final id = int.parse(
          options.path.split('/').where((v) => v != 'images').last,
        );
        return {
          ...rows[id - 1],
          'alternative_titles': {'titles': []},
          'translations': {'translations': []},
        };
      });
      final tmdb = TmdbMetadataService(
        credentials: _MemoryToken(),
        dio: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(tmdb.close);
      final session = await FilmCatalogMatcher(
        store,
        tmdb,
      ).scanSession(root, cancelled: () => false);
      await session.prepare([
        FilmScanEntry(
          path: 'Movies/${sample.$1}',
          parentPath: 'Movies',
          name: sample.$1,
          mediaKind: 'video',
        ),
      ]);
      expect(session.matches.length, sample.$4 ? 1 : 0);
      expect(session.paused, isFalse);
    });
  }

  test('背景取全部语言中的最高分辨率横图，原图缓存与缩略图独立', () async {
    final adapter = _ApiAdapter((options) async {
      if (!options.path.endsWith('/images')) {
        return _details(FilmMediaType.movie, 1);
      }
      expect(options.queryParameters, isEmpty);
      return {
        'id': 1,
        'backdrops': [
          {
            'file_path': '/low.jpg',
            'width': 780,
            'height': 439,
            'iso_639_1': null,
          },
          {
            'file_path': '/high.jpg',
            'width': 3840,
            'height': 2160,
            'iso_639_1': 'fr',
          },
          {
            'file_path': '/portrait.jpg',
            'width': 4000,
            'height': 6000,
            'iso_639_1': null,
          },
          {
            'file_path': '/medium.jpg',
            'width': 2048,
            'height': 1152,
            'iso_639_1': null,
          },
        ],
      };
    });
    final tmdb = TmdbMetadataService(
      credentials: _MemoryToken(),
      dio: Dio()..httpClientAdapter = adapter,
    );
    addTearDown(tmdb.close);
    final work = await tmdb.details(FilmMediaType.movie, 1, 'zh-CN');
    expect(work.backdropPath, '/high.jpg');
    expect(work.metadata['backdrop_width'], 3840);
    expect(work.metadata['backdrop_height'], 2160);
    final imageApi = _ImageAdapter();
    final configApi = TmdbMetadataService(
      credentials: _MemoryToken(),
      dio: Dio()..httpClientAdapter = _ApiAdapter((_) async => _imageConfig()),
    );
    addTearDown(configApi.close);
    final cache = FilmCatalogImageCache(
      Directory(p.join(temp.path, 'original')),
      configApi,
      dio: Dio()..httpClientAdapter = imageApi,
      validateImage: (_) async {},
    );
    addTearDown(cache.close);
    final thumb = await cache.get('/high.jpg', target: 'w780');
    final original = await cache.get('/high.jpg', target: 'original');
    expect(original.path, isNot(thumb.path));
    expect(imageApi.requests.last.uri.path, '/t/p/original/high.jpg');
    expect(imageApi.requests.last.headers['Authorization'], isNull);
    expect(
      (await cache.get('/high.jpg', target: 'original')).path,
      original.path,
    );
    expect(imageApi.requests, hasLength(2));
  });

  test('英文译名、别名、剧场版与标点差异自动关联并复用标题核验', () async {
    final root = await addRoot();
    final data = {
      ..._details(FilmMediaType.movie, 568160),
      'title': '天气之子',
      'original_title': '天気の子',
      'release_date': '2019-07-19',
    };
    final adapter = _ApiAdapter((options) async {
      if (options.path.contains('/search/')) {
        return {
          'results': [data],
        };
      }
      if (options.queryParameters['append_to_response'] != null) {
        return {
          ...data,
          'alternative_titles': {'titles': <Object>[]},
          'translations': {
            'translations': [
              {
                'data': {'title': 'Weathering With You'},
              },
            ],
          },
        };
      }
      return data;
    });
    final tmdb = TmdbMetadataService(
      credentials: _MemoryToken(),
      dio: Dio()..httpClientAdapter = adapter,
    );
    addTearDown(tmdb.close);
    final session = await FilmCatalogMatcher(
      store,
      tmdb,
    ).scanSession(root, cancelled: () => false);
    await session.prepare([
      const FilmScanEntry(
        path: 'Movies/a.mkv',
        parentPath: 'Movies',
        name: 'Weathering.with.You.2019.mkv',
        mediaKind: 'video',
      ),
      const FilmScanEntry(
        path: 'Movies/b.mkv',
        parentPath: 'Movies',
        name: 'Weathering.with.You.2019.2160p.mkv',
        mediaKind: 'video',
      ),
    ]);
    expect(session.matches, hasLength(2));
    expect(
      session.matches.values.map((m) => m.work.tmdbId),
      everyElement(568160),
    );
    expect(
      adapter.requests.where(
        (r) =>
            r.queryParameters['append_to_response'] ==
            'alternative_titles,translations',
      ),
      hasLength(1),
    );
  });

  test('特别篇 S00 与普通季共享作品搜索，每季只请求一次且保存集图', () async {
    final root = await addRoot(type: FilmMediaType.tv, path: 'TV');
    final adapter = _ApiAdapter((options) async {
      final work = {
        ..._details(FilmMediaType.tv, 10),
        'name': 'Show',
        'original_name': 'Show',
      };
      if (options.path.contains('/search/')) {
        return {
          'results': [work],
        };
      }
      if (options.path.contains('/season/')) {
        final number = int.parse(options.path.split('/').last);
        final data = _season(number, [1, 2]);
        for (final episode in data['episodes'] as List) {
          episode['still_path'] = '/still.jpg';
        }
        return data;
      }
      return work;
    });
    final tmdb = TmdbMetadataService(
      credentials: _MemoryToken(),
      dio: Dio()..httpClientAdapter = adapter,
    );
    addTearDown(tmdb.close);
    final metadata = await FilmCatalogMatcher(
      store,
      tmdb,
    ).scanSession(root, cancelled: () => false);
    final dav = _Dav(
      (path) async => switch (path) {
        'TV' => [_file('TV/Show', directory: true)],
        'TV/Show' => [
          _file('TV/Show/Season 0', directory: true),
          _file('TV/Show/Season 1', directory: true),
        ],
        'TV/Show/Season 0' => [
          _file('$path/S00E01.1080p.mkv'),
          _file('$path/S00E02.mkv'),
        ],
        _ => [_file('$path/S01E01.mkv')],
      },
    );
    await FilmCatalogScanner(
      store,
      remoteInterval: Duration.zero,
    ).scan(root, WebDavMediaSourceAdapter(dav), onEntries: metadata.prepare);
    await store.applyMetadata(root.id, metadata.matches);
    final resources = await store.resources(rootId: root.id);
    expect(resources.map((r) => (r.season, r.episode)), [
      (0, 1),
      (0, 2),
      (1, 1),
    ]);
    expect(adapter.requests, hasLength(5));
    expect(
      (await store.season(
        resources.first.workId!,
        0,
      ))!['episodes'][0]['still_path'],
      '/still.jpg',
    );
  });

  for (final missingSeason in [false, true]) {
    test('TMDB ${missingSeason ? '没有第零季' : '缺少特典集号'}时按本地季集入库', () async {
      final root = await addRoot(type: FilmMediaType.tv, path: 'TV');
      final adapter = _ApiAdapter(
        (options) async => options.path.contains('/season/')
            ? _season(0, [1])
            : _details(FilmMediaType.tv, 10),
        statusFor: (options) =>
            missingSeason && options.path.contains('/season/') ? 404 : 200,
      );
      final tmdb = TmdbMetadataService(
        credentials: _MemoryToken(),
        dio: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(tmdb.close);
      final matcher = FilmCatalogMatcher(store, tmdb);
      final entries = [
        for (final episode in [1, 41, 75])
          FilmScanEntry(
            path: 'TV/Show [tmdb-10]/Specials/Show.S00E$episode.INFO.mkv',
            parentPath: 'TV/Show [tmdb-10]/Specials',
            name: 'Show.S00E$episode.INFO.mkv',
            mediaKind: 'video',
          ),
      ];
      final session = await matcher.scanSession(root, cancelled: () => false);
      await session.prepare(entries);
      final generation = await store.beginScan(root.id);
      await store.stage(root, generation, entries);
      await store.commitScan(root.id, generation, cancelled: () => false);
      await store.applyMetadata(root.id, session.matches);
      final resources = await store.resources(rootId: root.id);
      expect(resources.map((r) => (r.season, r.episode)), [
        (0, 1),
        (0, 41),
        (0, 75),
      ]);
      expect(resources.map((r) => r.mappingOrigin), everyElement('filename'));
      expect(await store.pendingCount(rootId: root.id), 0);
      expect(session.error, isNull);
      expect(session.paused, isFalse);
      expect(
        adapter.requests.where((r) => r.path.contains('/season/')),
        hasLength(1),
      );
      await matcher.verifyEpisodes(resources.map((r) => r.id).toList());
      await matcher.organize(root.id);
      await matcher.refresh((await store.work(resources.first.workId!))!);
      expect(await store.pendingCount(rootId: root.id), 0);
      final metadata = await store.season(resources.first.workId!, 0);
      if (missingSeason) {
        expect(metadata, isNull);
      } else {
        expect(
          (metadata!['episodes'] as List).map((e) => e['episode_number']),
          [1],
        );
      }
    });
  }

  for (final (folder, filename, years, expected) in [
    ('2005 - 《青空 AIR》/0.《Specials》/番外篇', 'AIR S00E01.mkv', [2005, 2025], 10),
    ('AIR/Specials', 'AIR.2005.S00E01.mkv', [2005, 2025], 10),
    ('AIR/Specials', 'AIR S00E01.mkv', [2005, 2025], null),
    ('2005 - 《青空 AIR》/Specials', 'AIR.2006.S02E01.mkv', [2005], 10),
    ('2005 - 《青空 AIR》/Specials', 'AIR S00E01.mkv', [2005, 2005], null),
  ]) {
    test('同名剧集使用文件或作品目录年份消歧 $folder $filename $years', () async {
      final root = await addRoot(type: FilmMediaType.tv, path: 'TV');
      Map<String, dynamic> details(int index) => {
        ..._details(FilmMediaType.tv, (index + 1) * 10),
        'name': 'AIR',
        'original_name': 'AIR',
        'first_air_date': '${years[index]}-01-01',
      };
      final adapter = _ApiAdapter((options) async {
        if (options.path.endsWith('/search/tv')) {
          return {
            'results': [for (var i = 0; i < years.length; i++) details(i)],
          };
        }
        if (options.path.contains('/season/')) {
          return _season(int.parse(options.path.split('/').last), []);
        }
        return details(
          int.parse(
                    Uri.parse(options.path).pathSegments
                        .where((part) => int.tryParse(part) != null)
                        .last,
                  ) ~/
                  10 -
              1,
        );
      });
      final tmdb = TmdbMetadataService(
        credentials: _MemoryToken(),
        dio: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(tmdb.close);
      final session = await FilmCatalogMatcher(
        store,
        tmdb,
      ).scanSession(root, cancelled: () => false);
      await session.prepare([
        FilmScanEntry(
          path: 'TV/$folder/$filename',
          parentPath: 'TV/$folder',
          name: filename,
          mediaKind: 'video',
        ),
      ]);
      expect(session.error, isNull);
      expect(session.matches.values.firstOrNull?.work.tmdbId, expected);
    });
  }

  test('截图中的前置画质标记和中英双名自动匹配全部季集', () async {
    final root = await addRoot(type: FilmMediaType.tv, path: 'TV');
    final entries = <FilmScanEntry>[];
    for (final (season, episodes) in [
      (0, [1, 2, 3, 4, 5]),
      (1, [1, 10, 11, 12, 13, 14, 15, 16, 17]),
      (2, [1, 10, 11, 12, 13, 14]),
    ]) {
      for (final episode in episodes) {
        final name = 'CLANNAD.4k.S${season}E$episode.mkv';
        final folder = season == 0
            ? 'Specials'
            : season == 2
            ? 'CLANNAD ~AFTER~STORY~'
            : 'CLANNAD';
        final parent = 'TV/2007 - 《CLANNAD》/$season.《$folder》';
        entries.add(
          FilmScanEntry(
            path: '$parent/$name',
            parentPath: parent,
            name: name,
            mediaKind: 'video',
          ),
        );
      }
    }
    for (var episode = 6; episode <= 11; episode++) {
      final name =
          '灵魂摆渡.Soul.Ferry.2014.S01E${episode.toString().padLeft(2, '0')}.WEB-DL.2160p.H265.AAC-PTerWEB.mp4';
      const parent = 'TV/2014 - 《The Ferry Man》/1.《The Ferry Man Season 1》';
      entries.add(
        FilmScanEntry(
          path: '$parent/$name',
          parentPath: parent,
          name: name,
          mediaKind: 'video',
        ),
      );
    }
    Map<String, dynamic> details(int id) => {
      ..._details(FilmMediaType.tv, id),
      'name': id == 24835 ? 'CLANNAD' : '灵魂摆渡',
      'original_name': id == 24835 ? 'CLANNAD' : '灵魂摆渡',
      'first_air_date': id == 24835 ? '2007-10-05' : '2014-02-28',
    };
    final adapter = _ApiAdapter((options) async {
      if (options.path.contains('/search/')) {
        return {
          'results': switch (options.queryParameters['query']) {
            'CLANNAD' => [details(24835)],
            '灵魂摆渡 Soul Ferry' || '灵魂摆渡' || 'Soul Ferry' => [details(75480)],
            _ => <Object>[],
          },
        };
      }
      if (options.path.contains('/season/')) {
        return _season(int.parse(options.path.split('/').last), []);
      }
      final id = int.parse(
        Uri.parse(
          options.path,
        ).pathSegments.where((part) => int.tryParse(part) != null).last,
      );
      return {
        ...details(id),
        'alternative_titles': {'results': <Object>[]},
        'translations': {'translations': <Object>[]},
      };
    });
    final tmdb = TmdbMetadataService(
      credentials: _MemoryToken(),
      dio: Dio()..httpClientAdapter = adapter,
    );
    addTearDown(tmdb.close);
    final session = await FilmCatalogMatcher(
      store,
      tmdb,
    ).scanSession(root, cancelled: () => false);
    await session.prepare(entries);
    expect(session.matches, hasLength(26));
    final generation = await store.beginScan(root.id);
    await store.stage(root, generation, entries);
    await store.commitScan(root.id, generation, cancelled: () => false);
    await store.applyMetadata(root.id, session.matches);
    expect(await store.pendingCount(rootId: root.id), 0);
    for (final resource in await store.resources(rootId: root.id)) {
      final work = (await store.work(resource.workId!))!;
      expect(work.tmdbId, resource.name.startsWith('CLANNAD') ? 24835 : 75480);
      expect((
        resource.season,
        resource.episode,
      ), FilmCatalogMatcher.hint(resource).episode);
    }
    expect(session.error, isNull);
    expect(
      adapter.requests.where((r) => r.path.contains('/season/')),
      hasLength(4),
    );
    expect(
      adapter.requests.where((r) => r.queryParameters['query'] == 'CLANNAD'),
      hasLength(1),
    );
  });

  for (final (title, emptyCombined, conflicting, expected) in [
    ('灵魂摆渡 Soul Ferry', true, false, 1),
    ('灵魂摆渡 Soul Ferry', false, true, 0),
    ('灵魂摆渡 Soul Ferry 2', false, false, 0),
  ]) {
    test('双语关键词分别搜索并保留名称冲突与续作数字 $title $emptyCombined $conflicting', () async {
      final root = await addRoot(type: FilmMediaType.tv, path: 'TV');
      Map<String, dynamic> details(int id) => {
        ..._details(FilmMediaType.tv, id),
        'name': id == 10 ? '灵魂摆渡' : 'Soul Ferry',
        'original_name': id == 10 ? '灵魂摆渡' : 'Soul Ferry',
        'first_air_date': '2014-01-01',
        'alternative_titles': {'results': <Object>[]},
        'translations': {'translations': <Object>[]},
      };
      final adapter = _ApiAdapter((options) async {
        if (options.path.contains('/search/')) {
          final query = options.queryParameters['query'];
          return {
            'results': emptyCombined && query == title
                ? <Object>[]
                : [details(conflicting && query == 'Soul Ferry' ? 20 : 10)],
          };
        }
        if (options.path.contains('/season/')) return _season(1, [1]);
        return details(
          int.parse(
            Uri.parse(
              options.path,
            ).pathSegments.where((part) => int.tryParse(part) != null).last,
          ),
        );
      });
      final tmdb = TmdbMetadataService(
        credentials: _MemoryToken(),
        dio: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(tmdb.close);
      final session = await FilmCatalogMatcher(
        store,
        tmdb,
      ).scanSession(root, cancelled: () => false);
      await session.prepare([
        FilmScanEntry(
          path: 'TV/$title.2014.S01E01.mkv',
          parentPath: 'TV',
          name: '$title.2014.S01E01.mkv',
          mediaKind: 'video',
        ),
      ]);
      expect(session.matches, hasLength(expected));
      expect(session.error, isNull);
      if (expected == 1) expect(session.matches.values.single.work.tmdbId, 10);
    });
  }

  for (final (name, folder, title, episode) in [
    (
      'CLANNAD.1080P.S0E1.mkv',
      '2007 - 《CLANNAD》/0.《Specials》',
      'CLANNAD',
      (0, 1),
    ),
    ('4k.S0E1.mkv', '2007 - 《CLANNAD》/0.《Specials》', 'CLANNAD', (0, 1)),
    ('S0E1.mkv', '2007 - 《CLANNAD》/0.《Specials》', 'CLANNAD', (0, 1)),
    (
      'S2E1.mkv',
      '2007 - 《CLANNAD》/2.《CLANNAD ~AFTER~STORY~》',
      'CLANNAD ~AFTER~STORY~',
      (2, 1),
    ),
  ]) {
    test('季集前画质与带编号作品目录提取 $name $folder', () {
      final hint = FilmCatalogMatcher.scanHint(
        name,
        'TV/$folder',
        'TV',
        type: FilmMediaType.tv,
      );
      expect(hint.title, title);
      expect(hint.year, 2007);
      expect(hint.episode, episode);
    });
  }

  for (final (name, episode, year) in [
    (
      'Squid.Game.S02E01.2021.2160p.NF.WEB-DL.DDP5.1.Atmos.HDR.H.265-LeveTV.mkv',
      (2, 1),
      2021,
    ),
    (
      'Squid.Game.S03E01.2025.2160p.NF.WEB-DL.H265.HDR10.DDP5.1.Atmos.2Audio.mkv',
      (3, 1),
      2025,
    ),
    ('Show.S01E01.2025.mkv', (1, 1), 2025),
    ('86不存在的战区 S00E02 11.5集.mkv', (0, 2), 2021),
    ('86不存在的战区 S00E03 17.5集.mkv', (0, 3), 2021),
    ('86不存在的战区 S00E04 18.5集.mkv', (0, 4), 2021),
    ('86不存在的战区 S00E05 21.5集.mkv', (0, 5), 2021),
    ('Show.S01E01.2025 11.5集.mkv', (1, 1), 2025),
    ('Show.S01E11.5.mkv', null, null),
    ('Show.S01E11.5集.mkv', null, null),
    ('Show.S01E11.5.2025.mkv', null, null),
    ('Show.S01E01.2025.E02.mkv', null, null),
    ('Show.S01E01 11.5集-E02.mkv', null, null),
    ('Show.S01E01-E02.2025.mkv', null, null),
  ]) {
    test('后置年份和描述性小数集号 $name', () {
      final hint = FilmCatalogMatcher.scanHint(
        name,
        'TV/2021 - 《Show》/0.《Specials》',
        'TV',
        type: FilmMediaType.tv,
      );
      expect(hint.episode, episode);
      if (year != null) expect(hint.year, year);
      if (name.startsWith('Squid')) expect(hint.title, 'Squid Game');
      if (name.startsWith('86')) expect(hint.title, '86不存在的战区');
    });
  }

  test('后置年份和描述性小数集号可补全已关联资源并保留人工季集', () async {
    final root = await addRoot(type: FilmMediaType.tv, path: 'TV');
    final names = [
      for (final episode in [1, 2, 3, 7])
        'Squid.Game.S02E${episode.toString().padLeft(2, '0')}.2021.2160p.NF.WEB-DL.DDP5.1.Atmos.HDR.H.265-LeveTV.mkv',
      for (var episode = 1; episode <= 6; episode++)
        'Squid.Game.S03E${episode.toString().padLeft(2, '0')}.2025.2160p.NF.WEB-DL.H265.HDR10.DDP5.1.Atmos.2Audio.mkv',
      for (final (episode, label) in [
        (2, '11.5'),
        (3, '17.5'),
        (4, '18.5'),
        (5, '21.5'),
      ])
        '86不存在的战区 S00E${episode.toString().padLeft(2, '0')} $label集.mkv',
    ];
    await inventory(root, [for (final name in names) 'TV/$name']);
    await store.bind(await store.resources(), _work(FilmMediaType.tv, 10));
    var resources = await store.resources(rootId: root.id);
    await store.mapEpisodes({resources.last: (0, 75)});
    final adapter = _ApiAdapter((options) async {
      if (options.path.contains('/season/')) {
        return _season(int.parse(options.path.split('/').last), []);
      }
      throw StateError('Unexpected request');
    });
    final tmdb = TmdbMetadataService(
      credentials: _MemoryToken(),
      dio: Dio()..httpClientAdapter = adapter,
    );
    addTearDown(tmdb.close);
    final matcher = FilmCatalogMatcher(store, tmdb);
    final session = await matcher.scanSession(root, cancelled: () => false);
    await session.prepare([
      for (final r in resources)
        FilmScanEntry(
          path: r.path,
          parentPath: r.parentPath,
          name: r.name,
          mediaKind: 'video',
        ),
    ]);
    await store.applyMetadata(root.id, session.matches);
    expect(session.error, isNull);
    expect(await store.pendingCount(rootId: root.id), 0);
    resources = await store.resources(rootId: root.id);
    for (var i = 0; i < resources.length; i++) {
      final resource = resources[i];
      expect(
        (resource.season, resource.episode),
        i == resources.length - 1
            ? (0, 75)
            : FilmCatalogMatcher.hint(resource).episode,
      );
    }
    expect(resources.last.mappingOrigin, 'manual');
    await matcher.verifyEpisodes(resources.map((r) => r.id).toList());
    await matcher.organize(root.id);
    expect(await store.pendingCount(rootId: root.id), 0);
    expect((await store.resource(resources.last.id))!.episode, 75);
    expect(
      adapter.requests.where((r) => r.path.contains('/season/')),
      hasLength(3),
    );
  });

  test('没有官方季资料也可离线预览和保存季集；非法编号与混合作品拒绝', () async {
    final root = await addRoot(type: FilmMediaType.tv, path: 'TV');
    await inventory(root, ['TV/Show.S00E41.mkv', 'TV/Show.S00E42.mkv']);
    await store.bind(await store.resources(), _work(FilmMediaType.tv, 10));
    final resources = await store.resources();
    final credentials = _MemoryToken()..token = null;
    final adapter = _ApiAdapter(
      (_) async => throw StateError('Unexpected request'),
    );
    final tmdb = TmdbMetadataService(
      credentials: credentials,
      dio: Dio()..httpClientAdapter = adapter,
    );
    addTearDown(tmdb.close);
    final matcher = FilmCatalogMatcher(store, tmdb);
    final mappings = await matcher.mappingPreview(resources, 0, 41);
    expect(mappings.values, [(0, 41), (0, 42)]);
    await store.mapEpisodes(mappings);
    expect(await store.pendingCount(), 0);
    expect(
      (await store.resources()).map((r) => r.mappingOrigin),
      everyElement('manual'),
    );
    expect(adapter.requests, isEmpty);
    for (final number in [(-1, 1), (0, 0), (0, -1)]) {
      await expectLater(
        matcher.mappingPreview(resources, number.$1, number.$2),
        throwsA(_code('invalidEpisode')),
      );
      await expectLater(
        store.mapEpisodes({(await store.resources()).first: number}),
        throwsA(_code('invalidEpisode')),
      );
    }
    await store.bind([
      (await store.resources()).last,
    ], _work(FilmMediaType.tv, 20));
    await expectLater(
      matcher.mappingPreview(await store.resources(), 0, 1),
      throwsA(_code('invalidEpisode')),
    );
  });

  test('刮削认证失败不阻止递归清单提交，并保留可见错误', () async {
    final root = await addRoot();
    final adapter = _ApiAdapter((_) async => {}, status: 401);
    final tmdb = TmdbMetadataService(
      credentials: _MemoryToken(),
      dio: Dio()..httpClientAdapter = adapter,
    );
    addTearDown(tmdb.close);
    final metadata = await FilmCatalogMatcher(
      store,
      tmdb,
    ).scanSession(root, cancelled: () => false);
    final dav = _Dav(
      (path) async => path == 'Movies'
          ? [
              _file('Movies/A.2020.mkv'),
              _file('Movies/B.2020.mkv'),
              _file('Movies/Child', directory: true),
            ]
          : [_file('$path/C.2020.mkv')],
    );
    await FilmCatalogScanner(
      store,
      remoteInterval: Duration.zero,
    ).scan(root, WebDavMediaSourceAdapter(dav), onEntries: metadata.prepare);
    await store.applyMetadata(root.id, metadata.matches);
    expect(await store.resources(), hasLength(3));
    expect(adapter.requests, hasLength(1));
    expect((await store.root(root.id))!.status, 'completed');
    expect((await store.root(root.id))!.lastError, isNull);
    expect(metadata.error, 'invalidToken');
  });

  test('刮削迟到结果不覆盖人工纠错，扫描取消保留已发现资源', () async {
    final root = await addRoot();
    await inventory(root, ['Movies/A.2020.mkv']);
    final entered = Completer<void>();
    final release = Completer<void>();
    final adapter = _ApiAdapter((options) async {
      final work = {
        ..._details(FilmMediaType.movie, 1),
        'title': 'A',
        'original_title': 'A',
      };
      if (options.path.contains('/search/')) {
        return {
          'results': [work],
        };
      }
      entered.complete();
      await release.future;
      return work;
    });
    final tmdb = TmdbMetadataService(
      credentials: _MemoryToken(),
      dio: Dio()..httpClientAdapter = adapter,
    );
    addTearDown(tmdb.close);
    final metadata = await FilmCatalogMatcher(
      store,
      tmdb,
    ).scanSession(root, cancelled: () => false);
    final scan = FilmCatalogScanner(store).scan(
      root,
      WebDavMediaSourceAdapter(_Dav((_) async => [_file('Movies/A.2020.mkv')])),
      onEntries: metadata.prepare,
    );
    await store.applyMetadata(root.id, metadata.matches);
    await entered.future;
    await store.bind([
      (await store.resources()).single,
    ], _work(FilmMediaType.movie, 2));
    release.complete();
    await scan;
    await store.applyMetadata(root.id, metadata.matches);
    final resource = (await store.resources()).single;
    expect(resource.bindingOrigin, 'manual');
    expect((await store.work(resource.workId!))!.tmdbId, 2);
    expect(await store.cachedWork(FilmMediaType.movie, 1), isNull);

    final next = await FilmCatalogMatcher(
      store,
      tmdb,
    ).scanSession(root, cancelled: () => false);
    final scanner = FilmCatalogScanner(store);
    await expectLater(
      scanner.scan(
        root,
        WebDavMediaSourceAdapter(
          _Dav((_) async => [_file('Movies/B.2020.mkv')]),
        ),
        onEntries: (entries) async {
          await next.prepare(entries);
          scanner.cancel();
        },
      ),
      throwsA(_code('cancelled')),
    );
    expect(await store.resources(), hasLength(2));
    expect((await store.resource(resource.id))!.availability, 'present');
    expect((await store.resource(resource.id))!.workId, resource.workId);
  });

  test('同一来源三个影视根独立筛选，全部类型合并电影与剧集', () async {
    final roots = [
      await addRoot(path: 'A'),
      await addRoot(path: 'B'),
      await addRoot(path: 'C', type: FilmMediaType.tv),
    ];
    for (var i = 0; i < roots.length; i++) {
      await inventory(roots[i], ['${roots[i].path}/file.mkv']);
      if (i != 1) {
        await store.bind(
          await store.resources(rootId: roots[i].id),
          _work(roots[i].type, i + 1),
        );
      }
    }
    expect(await store.works(type: null), hasLength(2));
    expect(await store.works(type: null, rootId: roots[0].id), hasLength(1));
    expect(
      await store.works(type: FilmMediaType.movie, rootId: roots[2].id),
      isEmpty,
    );
    expect(await store.pendingCount(rootId: roots[1].id), 1);
    expect(await store.pendingCount(rootId: roots[0].id), 0);
  });

  test('目录库 v1 升级前备份且保留资源身份与人工季集', () async {
    final root = await addRoot(type: FilmMediaType.tv);
    await inventory(root, ['Movies/Show.S00E01.mkv']);
    await store.bind(await store.resources(), _work(FilmMediaType.tv, 10));
    var resource = (await store.resources()).single;
    await store.saveSeason(resource.workId!, 0, 'zh-CN', _season(0, [1]));
    await store.mapEpisodes({resource: (0, 1)});
    resource = (await store.resources()).single;
    await store.close();
    final path = p.join(temp.path, 'catalog.db');
    final legacy = await databaseFactoryFfi.openDatabase(path);
    for (final table in [
      'collection_members',
      'work_people',
      'server_items',
      'server_sync_pending',
      'film_collections',
    ]) {
      await legacy.execute('DROP TABLE $table');
    }
    await legacy.execute('PRAGMA foreign_keys=OFF');
    await legacy.execute(
      'CREATE TABLE legacy_works AS SELECT id,media_type,tmdb_id,title,original_title,year,overview,poster_path,backdrop_path,metadata_json,metadata_language,metadata_fetched_at FROM works',
    );
    await legacy.execute('DROP TABLE works');
    await legacy.execute('ALTER TABLE legacy_works RENAME TO works');
    await legacy.execute('DROP TABLE work_favorites');
    await legacy.execute('DROP TABLE resource_probes');
    await legacy.execute('DROP TABLE root_covers');
    await legacy.execute('DROP TABLE catalog_preferences');
    await legacy.execute('DROP TABLE film_watch_state');
    await legacy.execute('DROP TABLE film_disc_watch_state');
    await legacy.execute('ALTER TABLE catalog_settings DROP COLUMN probe_mode');
    for (final table in [
      'film_playlist_scopes',
      'film_playlist_items',
      'film_playlists',
    ]) {
      await legacy.execute('DROP TABLE $table');
    }
    await legacy.setVersion(1);
    await legacy.close();
    store = await FilmCatalogStore.open(path);
    final restored = (await store.resources()).single;
    expect(restored.id, resource.id);
    expect(restored.bindingVersion, resource.bindingVersion);
    expect(
      (restored.season, restored.episode, restored.mappingOrigin),
      (0, 1, 'manual'),
    );
    expect(
      temp.listSync().where((f) => f.path.contains('.before-v2-')),
      hasLength(1),
    );
  });

  test('影视新增文案覆盖四语言并保留模板参数', () {
    for (final entry in filmCatalogTranslations.entries) {
      expect(entry.value, hasLength(3));
      for (final language in AppLanguage.values) {
        final text = AppLocalizations(language).text(entry.key);
        expect(text, isNotEmpty);
        expect(
          RegExp(r'\{[^}]+\}').allMatches(text).map((m) => m[0]).toSet(),
          RegExp(r'\{[^}]+\}').allMatches(entry.key).map((m) => m[0]).toSet(),
        );
      }
    }
  });
}

Matcher _code(String code) =>
    isA<FilmCatalogException>().having((e) => e.code, 'code', code);
FilmWork _work(FilmMediaType type, int id) => FilmWork(
  type: type,
  tmdbId: id,
  title: 'Work $id',
  originalTitle: 'Original $id',
  overview: '',
  language: 'zh-CN',
);
Map<String, dynamic> _details(FilmMediaType type, int id) => {
  'id': id,
  'backdrops': <Object>[],
  type == FilmMediaType.movie ? 'title' : 'name': 'Work $id',
  type == FilmMediaType.movie ? 'original_title' : 'original_name':
      'Original $id',
  'overview': '',
  'genres': <Object>[],
  'release_date': '2020-01-01',
  'first_air_date': '2020-01-01',
};
Map<String, dynamic> _season(int season, List<int> episodes) => {
  'season_number': season,
  'episodes': [
    for (final e in episodes)
      {
        'season_number': season,
        'episode_number': e,
        'name': 'Episode $e',
        'overview': '',
      },
  ],
};
Map<String, dynamic> _imageConfig() => {
  'images': {
    'secure_base_url': 'https://image.tmdb.org/t/p/',
    'poster_sizes': ['w185', 'w500'],
    'backdrop_sizes': ['w780', 'w1280', 'original'],
    'still_sizes': ['w185', 'w300'],
  },
};
WebDavFile _file(String path, {bool directory = false}) => WebDavFile(
  name: p.posix.basename(path),
  href: Uri(path: '/dav/$path${directory ? '/' : ''}').toString(),
  isDirectory: directory,
);

class _Dav extends WebDAVService {
  _Dav(this.list)
    : super(
        client: WebDavClient(baseUrl: 'https://nas.example/dav'),
        profileId: 'dav',
      );
  final Future<List<WebDavFile>> Function(String) list;
  final List<String> readPaths = [];
  final List<bool> refreshes = [];
  @override
  Future<List<WebDavFile>> fetchCatalogDirectory(String path) =>
      fetchDirectory(path, forceRefresh: true);
  @override
  Future<List<WebDavFile>> fetchDirectory(
    String path, {
    bool forceRefresh = false,
  }) async {
    readPaths.add(path);
    refreshes.add(forceRefresh);
    return list(path);
  }

  @override
  Future<String?> fetchStrmUrl(WebDavFile file) =>
      throw StateError('Scanner read STRM content');
}

class _MemoryToken extends TmdbCredentialStore {
  String? token = 'fake-api-token';
  @override
  Future<String?> read() async => token;
  @override
  Future<void> write(String value) async {
    token = value;
  }

  @override
  Future<void> delete() async {
    token = null;
  }
}

class _ApiAdapter implements HttpClientAdapter {
  _ApiAdapter(this.respond, {this.status = 200, this.statusFor});
  final Future<Map<String, dynamic>> Function(RequestOptions) respond;
  final int status;
  final int Function(RequestOptions)? statusFor;
  final List<RequestOptions> requests = [];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(await respond(options)),
      statusFor?.call(options) ?? status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        if (status == 429) 'retry-after': ['3600'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _ImageAdapter implements HttpClientAdapter {
  _ImageAdapter({this.bytes = const [1, 2, 3]});
  final List<int> bytes;
  final List<RequestOptions> requests = [];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody(Stream.value(Uint8List.fromList(bytes)), 200);
  }

  @override
  void close({bool force = false}) {}
}
