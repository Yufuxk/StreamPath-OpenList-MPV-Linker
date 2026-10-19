import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'support/legacy_film_catalog.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/domain/services/film_probe_access.dart';
import 'package:streampath/domain/services/local_media_source.dart';
import 'package:streampath/domain/services/media_info_probe.dart';
import 'package:streampath/presentation/controllers/film_media_probe_controller.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory temp;
  late FilmCatalogStore store;
  late FilmCatalogRoot root;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('film_phase3_');
    store = await FilmCatalogStore.open(p.join(temp.path, 'catalog.db'));
    final id = await store.addRoot(
      sourceId: 'local:fixture',
      kind: MediaSourceKind.local,
      path: '',
      type: FilmMediaType.movie,
      name: 'Fixture',
    );
    root = (await store.root(id))!;
    final generation = await store.beginScan(id);
    await store.stage(root, generation, const [
      FilmScanEntry(
        path: 'sample.strm',
        parentPath: '',
        name: 'sample.strm',
        mediaKind: 'strm',
      ),
    ]);
    await store.commitScan(id, generation, cancelled: () => false);
  });
  tearDown(() async {
    await store.close();
    await temp.delete(recursive: true);
  });

  test('来源封面只选择真实已缓存图片，未缓存时保持占位且不联网', () async {
    await store.bind(
      await store.resources(),
      FilmWork(
        type: FilmMediaType.movie,
        tmdbId: 10,
        title: 'Cached',
        originalTitle: 'Cached',
        overview: '',
        language: 'zh-CN',
        posterPath: '/cached.png',
        backdropPath: '/uncached.jpg',
      ),
    );
    final tmdb = TmdbMetadataService(credentials: _FilmNoCredentials());
    final directory = Directory(p.join(temp.path, 'covers'));
    final images = FilmCatalogImageCache(directory, tmdb);
    final catalog = FilmCatalogController(
      store: store,
      tmdb: tmdb,
      images: images,
      sourceFor: (_) => throw StateError('No source access'),
    );
    await catalog.refresh();
    expect(catalog.rootCovers, isEmpty);
    await directory.create(recursive: true);
    final file = File(
      p.join(
        directory.path,
        '${FilmCatalogImageCache.cacheKey('/cached.png', 'w342')}.img',
      ),
    );
    await file.writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aPioAAAAASUVORK5CYII=',
      ),
    );
    await catalog.refresh();
    expect(catalog.rootCovers[root.id]?.title, 'Cached');
    expect(catalog.rootCoverFiles[root.id]?.path, file.path);
    await file.delete();
    await catalog.refresh();
    expect(catalog.rootCoverFiles, isEmpty);
    await catalog.close();
    store = await FilmCatalogStore.open(p.join(temp.path, 'catalog.db'));
  });

  test('删除来源释放封面记录且现存来源封面保持一致', () async {
    final tmdb = TmdbMetadataService(credentials: _FilmNoCredentials());
    final images = FilmCatalogImageCache(
      Directory(p.join(temp.path, 'covers')),
      tmdb,
    );
    final catalog = FilmCatalogController(
      store: store,
      tmdb: tmdb,
      images: images,
      sourceFor: (_) => throw StateError('No source access'),
    );
    final file = File(p.join(temp.path, 'custom.png'));
    await file.writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aPioAAAAASUVORK5CYII=',
      ),
    );
    await store.setCustomRootCover(root.id, file.path);
    for (var i = 0; i < 20; i++) {
      final id = await store.addRoot(
        sourceId: 'local:$i',
        kind: MediaSourceKind.local,
        path: '',
        type: FilmMediaType.movie,
        name: 'Transient $i',
      );
      await store.setCustomRootCover(id, file.path);
      await catalog.refresh();
      expect(catalog.rootCoverFiles[id]?.path, file.path);
      await store.removeRoot(id);
      await catalog.refresh();
      expect(catalog.rootCoverFiles.keys, [root.id]);
      expect(catalog.rootCoverFiles[root.id]?.path, file.path);
    }
    await catalog.close();
    store = await FilmCatalogStore.open(p.join(temp.path, 'catalog.db'));
  });

  test('删除来源释放随机封面且现存来源不重新选择封面', () async {
    final otherId = await store.addRoot(
      sourceId: 'local:other',
      kind: MediaSourceKind.local,
      path: '',
      type: FilmMediaType.movie,
      name: 'Other',
    );
    final other = (await store.root(otherId))!;
    final generation = await store.beginScan(otherId);
    await store.stage(other, generation, const [
      FilmScanEntry(
        path: 'other.mkv',
        parentPath: '',
        name: 'other.mkv',
        mediaKind: 'video',
      ),
    ]);
    await store.commitScan(otherId, generation, cancelled: () => false);
    await store.bind(
      await store.resources(),
      const FilmWork(
        type: FilmMediaType.movie,
        tmdbId: 1,
        title: 'Fixture',
        originalTitle: 'Fixture',
        overview: '',
        language: 'zh-CN',
        posterPath: '/cached.png',
      ),
    );
    final tmdb = TmdbMetadataService(credentials: _FilmNoCredentials());
    final images = FilmCatalogImageCache(
      Directory(p.join(temp.path, 'covers')),
      tmdb,
    );
    await images.directory.create();
    final file = File(
      p.join(
        images.directory.path,
        '${FilmCatalogImageCache.cacheKey('/cached.png', 'w342')}.img',
      ),
    );
    await file.writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aPioAAAAASUVORK5CYII=',
      ),
    );
    final catalog = FilmCatalogController(
      store: store,
      tmdb: tmdb,
      images: images,
      sourceFor: (_) => throw StateError('No source access'),
    );
    await catalog.refresh();
    final original = catalog.rootCovers[root.id];
    expect(original, isNotNull);
    expect(catalog.rootCovers[otherId], isNotNull);
    await store.removeRoot(otherId);
    await catalog.refresh();
    expect(catalog.rootCovers.keys, [root.id]);
    expect(catalog.rootCoverFiles.keys, [root.id]);
    expect(catalog.rootCovers[root.id], same(original));
    expect(await file.exists(), isTrue);
    await catalog.close();
    store = await FilmCatalogStore.open(p.join(temp.path, 'catalog.db'));
  });

  test('收藏按作品去重，来源筛选与探测缓存持久化，来源封面在重启后轮换', () async {
    final work = FilmWork(
      type: FilmMediaType.movie,
      tmdbId: 1,
      title: 'Fixture',
      originalTitle: 'Fixture',
      overview: '',
      language: 'zh-CN',
      posterPath: '/one.jpg',
    );
    await store.bind(await store.resources(), work);
    final resource = (await store.resources()).single;
    await store.setFavorite(resource.workId!, true);
    await store.saveProbe(resource.id, {'origin': 'MPV', 'duration': 1});
    expect(
      await store.works(
        type: null,
        favoritesOnly: true,
        sourceIds: {'local:fixture'},
      ),
      hasLength(1),
    );
    expect(
      await store.works(type: null, favoritesOnly: true, sourceIds: {'other'}),
      isEmpty,
    );
    final gen = await store.beginScan(root.id);
    await store.stage(root, gen, const [
      FilmScanEntry(
        path: 'sample.strm',
        parentPath: '',
        name: 'sample.strm',
        mediaKind: 'strm',
      ),
      FilmScanEntry(
        path: 'two.iso',
        parentPath: '',
        name: 'two.iso',
        mediaKind: 'iso',
      ),
    ]);
    await store.commitScan(root.id, gen, cancelled: () => false);
    await store.bind(
      [(await store.resources()).singleWhere((r) => r.mediaKind == 'iso')],
      FilmWork(
        type: FilmMediaType.movie,
        tmdbId: 2,
        title: 'Second',
        originalTitle: 'Second',
        overview: '',
        language: 'zh-CN',
        posterPath: '/two.jpg',
      ),
    );
    final first = (await store.chooseRootCover(root.id))!;
    await store.close();
    store = await FilmCatalogStore.open(p.join(temp.path, 'catalog.db'));
    expect(await store.isFavorite(resource.workId!), isTrue);
    expect(await store.probe(resource.id), containsPair('duration', 1));
    expect((await store.chooseRootCover(root.id))!.id, isNot(first.id));
    await store.clearFavorites('other');
    expect(await store.isFavorite(resource.workId!), isTrue);
    await store.clearFavorites('local:fixture');
    expect(await store.isFavorite(resource.workId!), isFalse);
  });

  test('v2 迁移保留人工关联与参数默认值，不读取或改动媒体文件', () async {
    final resource = (await store.resources()).single;
    await store.close();
    final db = await databaseFactoryFfi.openDatabase(
      p.join(temp.path, 'catalog.db'),
    );
    await restoreVersion6Fixture(db);
    for (final table in [
      'work_favorites',
      'resource_probes',
      'root_covers',
      'catalog_preferences',
      'film_watch_state',
      'film_disc_watch_state',
    ]) {
      await db.execute('DROP TABLE $table');
    }
    await db.execute('ALTER TABLE catalog_settings DROP COLUMN probe_mode');
    await db.setVersion(2);
    await db.close();
    store = await FilmCatalogStore.open(p.join(temp.path, 'catalog.db'));
    expect((await store.resources()).single.id, resource.id);
    expect(await store.probeMode(), 'playback');
    expect(
      temp.listSync().where((e) => e.path.contains('before-v3-')),
      hasLength(1),
    );
  });

  FilmMediaProbeController controller(
    _Probe probe,
    _Access access, {
    List<FilmPlaybackSnapshot> snapshots = const [],
    bool playing = false,
  }) => FilmMediaProbeController(
    store: store,
    sourceFor: (_) => LocalMediaSource(
      LocalRootConfig(
        rootId: 'fixture',
        displayName: 'Fixture',
        path: temp.path,
      ),
    ),
    snapshots: () => snapshots,
    relativePathFor: (snapshot) => snapshot.resourcePath,
    isPlaying: () async => playing,
    probe: probe,
    access: access,
  );

  test('退出播放会话释放快照记录并保留活动快照去重', () async {
    final snapshots = <FilmPlaybackSnapshot>[];
    final c = controller(_Probe(), _Access(), snapshots: snapshots);
    var updates = 0;
    void changed() => updates++;
    store.addListener(changed);
    addTearDown(() => store.removeListener(changed));
    addTearDown(() async {
      await c.close();
      expect(c.retainedSnapshotCount, 0);
    });
    for (var i = 0; i < 20; i++) {
      final file = File(p.join(temp.path, '$i.media.json'));
      const target = 'https://media.invalid/resolved.mp4';
      await file.writeAsString(
        jsonEncode({
          'path': target,
          'duration': 1,
          'tracks': [
            {'type': 'video', 'codec': 'h264', 'demux-w': 160, 'demux-h': 90},
          ],
        }),
      );
      snapshots
        ..clear()
        ..add((
          sourceId: 'local:fixture',
          target: target,
          snapshotPath: file.path,
          resourcePath: 'sample.strm',
        ));
      await c.tick();
      final afterFirst = updates;
      await c.tick();
      expect(updates, afterFirst);
      expect(c.retainedSnapshotCount, 1);
    }
    snapshots.clear();
    await c.tick();
    expect(c.retainedSnapshotCount, 0);
  });

  test('默认模式不调用解析器，STRM 参数关联原始条目且拒绝旧曲目快照', () async {
    final file = File(p.join(temp.path, 'media.json'));
    final probe = _Probe(), access = _Access();
    final c = controller(
      probe,
      access,
      snapshots: [
        (
          sourceId: 'local:fixture',
          target: 'https://media.invalid/resolved.mp4',
          snapshotPath: file.path,
          resourcePath: 'sample.strm',
        ),
      ],
    );
    addTearDown(c.close);
    await file.writeAsString(
      jsonEncode({
        'path': 'https://media.invalid/previous.mp4',
        'tracks': [
          {'type': 'video', 'codec': 'h264', 'demux-w': 160, 'demux-h': 90},
        ],
      }),
    );
    await c.tick();
    final resource = (await store.resources()).single;
    expect(await store.probe(resource.id), isNull);
    await file.writeAsString(
      jsonEncode({
        'path': 'https://media.invalid/resolved.mp4',
        'duration': 1,
        'tracks': [
          {'type': 'video', 'codec': 'h264', 'demux-w': 160, 'demux-h': 90},
        ],
      }),
    );
    await c.tick();
    expect(await store.probe(resource.id), containsPair('duration', 1));
    expect(probe.calls, 0);
    expect(access.calls, 0);
  });

  test('完整模式仅补充普通视频，ISO、BDMV 和已有 STRM 快照不入队', () async {
    final generation = await store.beginScan(root.id);
    await store.stage(root, generation, const [
      FilmScanEntry(
        path: 'sample.strm',
        parentPath: '',
        name: 'sample.strm',
        mediaKind: 'strm',
      ),
      FilmScanEntry(
        path: 'sample.iso',
        parentPath: '',
        name: 'sample.iso',
        mediaKind: 'iso',
      ),
      FilmScanEntry(
        path: 'disc',
        parentPath: '',
        name: 'disc',
        mediaKind: 'bdmv',
      ),
      FilmScanEntry(
        path: 'sample.mp4',
        parentPath: '',
        name: 'sample.mp4',
        mediaKind: 'video',
      ),
    ]);
    await store.commitScan(root.id, generation, cancelled: () => false);
    final resources = await store.resources();
    final video = resources.singleWhere((r) => r.mediaKind == 'video');
    expect(
      await store.unprobedResources(limit: 10),
      everyElement(isA<FilmResource>().having((r) => r.isDisc, 'disc', false)),
    );
    for (final resource in resources) {
      await store.saveProbe(resource.id, {
        'origin': 'MPV',
        'state': 'playback',
      });
    }
    expect((await store.unprobedResources()).single.id, video.id);
    await store.setProbeMode('full');
    final probe = _Probe(), access = _Access();
    final c = controller(probe, access);
    addTearDown(c.close);
    await c.tick();
    expect(probe.calls, 1);
    expect(access.calls, 1);
    expect(await store.probe(video.id), containsPair('fullProbed', true));
    await c.tick();
    expect(probe.calls, 1);
    expect(await store.unprobedResources(), isEmpty);
  });

  for (final kind in ['video', 'iso', 'bdmv']) {
    test('$kind 快照复用已知大小与实测时长，仅普通视频补充整体平均码率', () async {
      final generation = await store.beginScan(root.id);
      final path = kind == 'bdmv' ? 'disc' : 'sample.$kind';
      await store.stage(root, generation, [
        FilmScanEntry(path: path, parentPath: '', name: path, mediaKind: kind),
      ]);
      await store.commitScan(root.id, generation, cancelled: () => false);
      final resource = (await store.resources()).singleWhere(
        (r) => r.path == path,
      );
      await store.saveProbe(resource.id, {
        'origin': 'MediaInfo',
        'state': 'partial',
        'fileSize': 125000000,
      });
      final file = File(p.join(temp.path, 'snapshot.json'));
      final target = p.join(temp.path, path);
      await file.writeAsString(
        jsonEncode({
          'path': target,
          'duration': 100,
          'tracks': [
            {'type': 'video', 'codec': 'h264', 'demux-bitrate': 8000000},
          ],
        }),
      );
      final probe = _Probe(), access = _Access();
      final c = controller(
        probe,
        access,
        snapshots: [
          (
            sourceId: root.sourceId,
            target: target,
            snapshotPath: file.path,
            resourcePath: path,
          ),
        ],
      );
      addTearDown(c.close);
      await c.tick();
      final info = (await store.probe(resource.id))!;
      expect(info['fileSize'], 125000000);
      expect(info['duration'], 100);
      expect(info['bitrate'], kind == 'video' ? 10000000 : isNull);
      expect((info['video'] as List).single['bitrate'], 8000000);
      expect(probe.calls, 0);
      expect(access.calls, 0);
    });
  }

  test('MPV 已知大小和时长立即填充总码率，缓存 MediaInfo 有效码率优先', () async {
    final resource = (await store.resources()).single;
    final file = File(p.join(temp.path, 'snapshot.json'));
    const target = 'https://media.invalid/resolved.mp4';
    Future<void> write(int duration) => file.writeAsString(
      jsonEncode({
        'path': target,
        'size': 125000000,
        'duration': duration,
        'tracks': [
          {'type': 'video', 'codec': 'h264'},
        ],
      }),
    );
    final c = controller(
      _Probe(),
      _Access(),
      snapshots: [
        (
          sourceId: root.sourceId,
          target: target,
          snapshotPath: file.path,
          resourcePath: resource.path,
        ),
      ],
    );
    addTearDown(c.close);
    await write(100);
    await c.tick();
    expect(await store.probe(resource.id), containsPair('bitrate', 10000000));
    await store.saveProbe(resource.id, {
      'origin': 'MediaInfo',
      'state': 'partial',
      'bitrate': 9000000,
    });
    await write(200);
    await file.setLastModified(DateTime.now().add(const Duration(seconds: 1)));
    await c.tick();
    expect(await store.probe(resource.id), containsPair('bitrate', 9000000));
  });

  test('完整探测复用缓存大小与准确时长，MediaInfo 有效码率优先', () async {
    final generation = await store.beginScan(root.id);
    await store.stage(root, generation, const [
      FilmScanEntry(
        path: 'sample.mp4',
        parentPath: '',
        name: 'sample.mp4',
        mediaKind: 'video',
      ),
    ]);
    await store.commitScan(root.id, generation, cancelled: () => false);
    final video = (await store.resources()).singleWhere(
      (r) => r.mediaKind == 'video',
    );
    await store.saveProbe(video.id, {
      'state': 'playback',
      'fileSize': 125000000,
      'duration': 100,
    });
    await store.setProbeMode('full');
    final probe = _Probe();
    final c = controller(probe, _Access());
    addTearDown(c.close);
    await c.tick();
    expect(await store.probe(video.id), containsPair('bitrate', 10000000));
    await store.clearProbeMetadata();
    probe.values = {'fileSize': 125000000, 'duration': 100, 'bitrate': 9000000};
    await c.tick();
    expect(await store.probe(video.id), containsPair('bitrate', 9000000));
  });

  test('光盘地址准备直接退出，不枚举目录或启动 helper', () async {
    final generation = await store.beginScan(root.id);
    await store.stage(root, generation, const [
      FilmScanEntry(
        path: 'absent.iso',
        parentPath: '',
        name: 'absent.iso',
        mediaKind: 'iso',
      ),
      FilmScanEntry(
        path: 'absent-disc',
        parentPath: '',
        name: 'absent-disc',
        mediaKind: 'bdmv',
      ),
    ]);
    await store.commitScan(root.id, generation, cancelled: () => false);
    final access = FilmProbeAccess();
    final source = LocalMediaSource(
      LocalRootConfig(
        rootId: 'fixture',
        displayName: 'Fixture',
        path: temp.path,
      ),
    );
    for (final resource in (await store.resources()).where((r) => r.isDisc)) {
      await expectLater(
        access.prepare(resource, source),
        throwsA(
          isA<FilmCatalogException>().having(
            (e) => e.code,
            'code',
            'probePlaybackOnly',
          ),
        ),
      );
    }
  });

  for (final state in ['failed', 'partial']) {
    test('播放快照保留完整探测的 $state 状态，重试可重新入队且不会自动重复请求', () async {
      final generation = await store.beginScan(root.id);
      await store.stage(root, generation, const [
        FilmScanEntry(
          path: 'sample.mp4',
          parentPath: '',
          name: 'sample.mp4',
          mediaKind: 'video',
        ),
      ]);
      await store.commitScan(root.id, generation, cancelled: () => false);
      final resource = (await store.resources()).singleWhere(
        (r) => r.mediaKind == 'video',
      );
      final file = File(p.join(temp.path, 'media.json'));
      final probe = _Probe()
        ..resultState = state
        ..failure = state == 'failed' ? 'probeFailed' : null;
      final c = controller(
        probe,
        _Access(),
        snapshots: [
          (
            sourceId: root.sourceId,
            target: p.join(temp.path, 'sample.mp4'),
            resourcePath: 'sample.mp4',
            snapshotPath: file.path,
          ),
        ],
      );
      addTearDown(c.close);
      await store.setProbeMode('full');
      await c.tick();
      expect(
        await store.probe(resource.id),
        containsPair('fullProbeState', state),
      );
      await file.writeAsString(
        jsonEncode({
          'path': p.join(temp.path, 'sample.mp4'),
          'duration': 1,
          'tracks': [
            {'type': 'video', 'codec': 'h264', 'demux-w': 160, 'demux-h': 90},
          ],
        }),
      );
      await c.tick();
      final metadata = await store.probe(resource.id);
      expect(metadata, containsPair('origin', 'MPV'));
      expect(metadata, containsPair('fullProbeState', state));
      expect(probe.calls, 1);
      expect(await store.unprobedResources(), isEmpty);
      await store.clearFailedProbes();
      expect((await store.unprobedResources()).single.id, resource.id);
    });
  }

  test('播放期间完整探测不打开媒体，准备播放先停止正在探测的任务', () async {
    await store.setProbeMode('full');
    final blocked = controller(_Probe(), _Access(), playing: true);
    await blocked.tick();
    expect(blocked.pausedForPlayback, isTrue);
    await blocked.close();
    final probe = _Probe()..hold = true, access = _Access();
    final c = controller(probe, access);
    addTearDown(c.close);
    final task = c.tick();
    await probe.entered.future;
    var opened = false;
    await c.withPlaybackPriority(() async {
      expect(probe.cancelled, isTrue);
      expect(access.cancelled, isTrue);
      opened = true;
    });
    await task;
    expect(opened, isTrue);
    expect(await store.probe((await store.resources()).single.id), isNull);
  });
}

class _Probe extends MediaInfoProbe {
  int calls = 0;
  String resultState = 'complete';
  String? failure;
  Map<String, dynamic> values = {};
  bool hold = false, cancelled = false;
  final entered = Completer<void>();
  final pending = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> probe(
    String target, {
    Map<String, String> headers = const {},
  }) async {
    calls++;
    if (!entered.isCompleted) entered.complete();
    if (hold) return pending.future;
    if (failure != null) {
      throw FilmCatalogException(failure!);
    }
    return {
      'origin': 'MediaInfo',
      'state': resultState,
      'video': [],
      ...values,
    };
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
    if (hold && !pending.isCompleted) {
      pending.completeError(const FilmCatalogException('cancelled'));
    }
  }
}

class _Access extends FilmProbeAccess {
  int calls = 0;
  bool cancelled = false;
  @override
  Future<FilmProbeTarget> prepare(FilmResource resource, dynamic source) async {
    calls++;
    return FilmProbeTarget(resource.path);
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
  }
}

class _FilmNoCredentials extends TmdbCredentialStore {
  @override
  Future<String?> read() async => null;
}
