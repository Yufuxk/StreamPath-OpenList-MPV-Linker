import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/external_audio_track.dart';
import 'package:streampath/data/models/media_directory_entry.dart';
import 'package:streampath/data/models/media_entry.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/media_connection.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/server_profile.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/data/remote/webdav_client.dart';
import 'package:streampath/domain/services/native_storage_source.dart';
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
import 'package:streampath/domain/repositories/media_directory_source.dart';
import 'package:streampath/presentation/state/app_state.dart';

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

class _FakeRemoteDirectory implements MediaDirectorySource {
  _FakeRemoteDirectory(this.descriptor, this.entries);

  @override
  final MediaSourceDescriptor descriptor;
  List<MediaDirectoryEntry> entries;
  Object? failure;
  final List<String> fetches = [];

  @override
  Future<List<MediaDirectoryEntry>> fetchDirectory(
    String relativePath, {
    bool forceRefresh = false,
  }) async {
    fetches.add(relativePath);
    final error = failure;
    if (error != null) throw error;
    return entries;
  }

  @override
  List<MediaDirectoryEntry>? cachedDirectory(String relativePath) => null;

  @override
  Future<MediaOpenTarget> resolve(MediaDirectoryEntry entry) async =>
      WebDavMediaOpenTarget(entry.entryKey);

  @override
  bool get supportsRemoteSearch => true;
}

class _AudioDirectoryService extends WebDAVService {
  _AudioDirectoryService(String baseUrl, this.entries)
    : super(client: WebDavClient(baseUrl: baseUrl));

  final List<WebDavFile> entries;
  final requests = <String>[];

  @override
  Future<List<WebDavFile>> fetchDirectory(
    String path, {
    bool forceRefresh = false,
  }) async {
    expect(forceRefresh, isTrue);
    requests.add(path);
    return entries;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Source source;
  late String cacheIdentity;
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
    'identity': cacheIdentity,
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
      cacheIdentity,
      'show',
      'video.mkv',
    );
    final file = VideoCacheFile({
      'id': 'file-a',
      'source': 'source-a',
      'path': 'show/video.mkv',
      'root': folder,
      'destination': destination,
      'identity': cacheIdentity,
      'strm': false,
      ...info,
    });
    return VideoCachePlan(
      bundle: {
        'id': 'bundle-a',
        'source': 'source-a',
        'sourceKind': 'webdav',
        'identity': cacheIdentity,
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
    cacheIdentity = 'account-a';
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

  test('影视库缓存宿主读取来源档案凭据且无需先挂载', () async {
    final store = StreamPathConfigStore.forPath(
      p.join(root.path, 'config.json'),
    );
    final profile = ServerProfile(
      profileId: 'source-a',
      name: 'Test WebDAV',
      serverUrl: source.base,
      username: 'source-user',
      password: 'initial-password',
    );
    await store.save(
      const StreamPathConfig()
          .upsertProfile(profile)
          .upsertProfile(
            const ServerProfile(
              profileId: 'active-other',
              name: 'Other WebDAV',
              serverUrl: 'https://other.invalid/dav',
              username: 'other-user',
              password: 'other-password',
            ),
            activate: true,
          ),
    );
    final service = await open();
    final progress = await PlaybackProgressService.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    addTearDown(progress.close);
    final app = AppState(
      configStore: store,
      playbackHistoryStore: PlaybackHistoryStore.forPath(
        p.join(root.path, 'history.json'),
      ),
      progressService: progress,
      videoCacheService: service,
    );
    addTearDown(() async {
      await app.prepareForClose();
      app.dispose();
    });
    cacheIdentity = (await app.videoCacheIdentity(profile.profileId))!;
    final selection = await plan(service);
    await service.enqueue([selection]);
    await service.setPlaybackSuspended(false);
    await _until(() => service.complete(selection.bundle));
    final reads = source.offsets.length;

    final playback =
        await app.videoCacheSource(profile.profileId) as VideoCacheSource;
    expect(playback.service.credentialSnapshot.baseUrl, source.base);
    expect(playback.service.credentialSnapshot.username, 'source-user');
    expect(playback.service.credentialSnapshot.password, 'initial-password');
    final target = (await playback.fetchDirectory('show')).single;
    final opened = await playback.resolve(target) as LocalMediaOpenTarget;
    expect(opened.path, selection.files.single.destination);
    expect(source.offsets.length, reads);
    expect(app.mountedService(profile.profileId), isNull);

    await store.save(
      store.current.upsertProfile(
        profile.copyWith(password: 'changed-password'),
        activate: true,
      ),
    );
    expect(playback.service.credentialSnapshot.password, 'changed-password');
    await store.save(
      store.current.upsertProfile(
        profile.copyWith(username: 'another-user'),
        activate: true,
      ),
    );
    expect(playback.service.credentialSnapshot.username, isEmpty);
  });

  test('缓存播放合并线上音轨并优先使用本地副本', () async {
    final service = await open();
    final video = WebDavFile(
      name: 'video.mkv',
      href: '${source.base}show/video.mkv',
      isDirectory: false,
    );
    final audio = [
      for (final (name, encoded) in [
        ('video.中文.wav', 'video.%E4%B8%AD%E6%96%87.wav'),
        (
          'video.日语 配音.wav',
          'video.%E6%97%A5%E8%AF%AD%20%E9%85%8D%E9%9F%B3.wav',
        ),
      ])
        WebDavFile(
          name: name,
          href: '${source.base}show/$encoded',
          isDirectory: false,
        ),
    ];
    final origin = _AudioDirectoryService(source.base, [video, ...audio]);
    var mounted = true;
    final playback = VideoCacheSource(
      service,
      const MediaSourceDescriptor(
        sourceId: 'source-a',
        kind: MediaSourceKind.webdav,
        displayName: 'Test WebDAV',
      ),
      identity: cacheIdentity,
      baseUrl: source.base,
      persistent: (path) => '${source.base}$path',
      remote: () async => throw StateError('Unexpected mount'),
      mountedWebDav: () => mounted ? origin : null,
    );
    const version = VideoQueueVersion(
      path: 'show/video.mkv',
      name: 'video.mkv',
    );
    const cachedAudio = ExternalAudioTrack(
      name: 'video.中文.wav',
      url: 'cached/video.中文.wav',
    );
    Future<PreparedVideoItem> prepare({
      bool enabled = true,
      List<MediaDirectoryEntry>? siblings,
      List<ExternalAudioTrack> cachedTracks = const [cachedAudio],
    }) => VideoEntryPreparer(
      source: playback,
      config: PlayerConfig(
        name: 'MPV',
        executable: 'mpv',
        subtitleInjectionEnabled: false,
        externalAudioInjectionEnabled: enabled,
      ),
      subtitleMatcher: const SubtitleMatcher(),
      fontMatcher: const WebDavFontMatcher(),
      titles: const {},
      directories: {'show': ?siblings},
      cached: (_) async => PreparedVideoItem(
        entry: MediaEntry(
          url: 'cached/video.mkv',
          progressTarget: video.href,
          externalAudioTracks: cachedTracks,
        ),
      ),
    ).prepare(version);

    final fromListedDirectory = await prepare(
      siblings: [video, ...audio],
      cachedTracks: const [],
    );
    expect(fromListedDirectory.entry.externalAudioTracks, hasLength(2));
    expect(origin.requests, isEmpty);

    final fromMountedSource = await prepare();
    expect(fromMountedSource.entry.url, 'cached/video.mkv');
    expect(fromMountedSource.entry.progressTarget, video.href);
    expect(
      {
        for (final track in fromMountedSource.entry.externalAudioTracks)
          track.name: track.url,
      },
      {cachedAudio.name: cachedAudio.url, audio.last.name: audio.last.href},
    );
    expect(origin.requests, ['show']);

    final disabled = await prepare(enabled: false, cachedTracks: const []);
    expect(disabled.entry.externalAudioTracks, isEmpty);
    mounted = false;
    final offline = await prepare();
    expect(offline.entry.externalAudioTracks, [cachedAudio]);
    final fromSnapshot = await prepare(
      siblings: [
        for (final entry in [video, ...audio])
          StorageMediaEntry(
            name: entry.name,
            href: entry.href,
            isDirectory: false,
            kind: MediaSourceKind.webdav,
            logicalPath: 'show/${entry.name}',
          ),
      ],
    );
    expect(fromSnapshot.entry.externalAudioTracks, [cachedAudio]);
    expect(origin.requests, ['show']);
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
  test('完整成品逐字节一致，附件补查失败仍复用缓存视频及进度', () async {
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
      remote: () async => throw AppException.network('Offline fixture'),
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
  test('离线缓存缺字幕和字体时，字体补查失败仍从快照播放', () async {
    final service = await open();
    final selection = await plan(service);
    await service.enqueue([selection]);
    await service.setPlaybackSuspended(false);
    await _until(() => service.complete(selection.bundle));
    final hit = (await service.lookup(
      'source-a',
      'show/video.mkv',
      identity: 'account-a',
    ))!;
    final requests = source.offsets.length;
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
      remote: () async => throw AppException.network('Offline fixture'),
    );
    final preparer = VideoEntryPreparer(
      source: offline,
      config: const PlayerConfig(
        name: 'mpv',
        executable: 'mpv',
        sharePlaylistFonts: true,
      ),
      subtitleMatcher: const SubtitleMatcher(),
      fontMatcher: const WebDavFontMatcher(),
      titles: const {},
      cached: (path) async => (await service.lookup(
        'source-a',
        path,
        identity: 'account-a',
      ))?.prepared(),
    );

    await preparer.prepareSharedFonts('show', startPath: 'show/video.mkv');
    final prepared = await preparer.prepare(
      const VideoQueueVersion(path: 'show/video.mkv', name: 'video.mkv'),
    );

    expect(prepared.entry.url, hit.path);
    expect(prepared.entry.progressTarget, 'https://nas.invalid/show/video.mkv');
    expect(prepared.entry.subtitle, isNull);
    expect(prepared.localFontDirectory, isNull);
    expect(source.offsets.length, requests);
  });

  test(
    'cached video discovers new fonts through a distinct logical cache origin',
    () async {
      final overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = overrides);
      final cache = await open();
      final selection = await plan(cache);
      await cache.enqueue([selection]);
      await cache.setPlaybackSuspended(false);
      await _until(() => cache.complete(selection.bundle));
      final requests = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final path = request.uri.path;
        requests.add('${request.method} $path');
        if (request.method == 'GET') {
          request.response.add([1, 2]);
        } else {
          final root = path.endsWith('/show');
          request.response.statusCode = HttpStatus.multiStatus;
          request.response.write('''
<d:multistatus xmlns:d="DAV:"><d:response>
<d:href>${root ? '/actual/show/Fonts/' : '/actual/show/Fonts/Example.ttf'}</d:href>
<d:propstat><d:prop><d:getcontentlength>2</d:getcontentlength></d:prop>
<d:status>HTTP/1.1 200 OK</d:status></d:propstat>
</d:response></d:multistatus>
''');
        }
        await request.response.close();
      });
      final cachedSource = VideoCacheSource(
        cache,
        const MediaSourceDescriptor(
          sourceId: 'source-a',
          kind: MediaSourceKind.webdav,
          displayName: 'test',
        ),
        identity: 'account-a',
        baseUrl: 'https://cache.invalid/folder/',
        persistent: (path) => 'https://cache.invalid/folder/$path',
        remote: () async => WebDavMediaSourceAdapter(
          WebDAVService(
            client: WebDavClient(
              baseUrl: 'http://127.0.0.1:${server.port}/actual',
            ),
          ),
        ),
      );
      final preparer = VideoEntryPreparer(
        source: cachedSource,
        config: const PlayerConfig(name: 'mpv', executable: 'mpv'),
        subtitleMatcher: const SubtitleMatcher(),
        fontMatcher: const WebDavFontMatcher(),
        titles: const {},
        cached: (path) async => (await cache.lookup(
          'source-a',
          path,
          identity: 'account-a',
        ))?.prepared(),
      );
      final prepared = await preparer.prepare(
        const VideoQueueVersion(path: 'show/video.mkv', name: 'video.mkv'),
      );
      expect(prepared.entry.url, selection.files.first.destination);
      final font = prepared.remoteFonts?.files.single;
      expect(font?.name, 'Example.ttf');
      final file = File(
        p.join(p.dirname(selection.files.first.destination), 'probe.ttf'),
      );
      expect(
        await cachedSource.service.downloadFile(
          font!.url,
          file,
          maxBytes: 2,
          timeout: const Duration(seconds: 2),
        ),
        2,
      );
      expect(await file.readAsBytes(), [1, 2]);
      expect(requests, [
        'PROPFIND /actual/show',
        'PROPFIND /actual/show/Fonts',
        'GET /actual/show/Fonts/Example.ttf',
      ]);
    },
  );

  test('缓存目录快照支持显式刷新，来源不可用时回退快照', () async {
    final service = await open();
    final selection = await plan(service);
    await service.enqueue([selection]);
    await service.setPlaybackSuspended(false);
    await _until(() => service.complete(selection.bundle));
    final remote = _FakeRemoteDirectory(
      const MediaSourceDescriptor(
        sourceId: 'source-a',
        kind: MediaSourceKind.webdav,
        displayName: 'test',
      ),
      [
        const WebDavFile(
          name: 'video.mkv',
          href: 'https://nas.invalid/show/video.mkv',
          isDirectory: false,
        ),
      ],
    );
    final cachedSource = VideoCacheSource(
      service,
      const MediaSourceDescriptor(
        sourceId: 'source-a',
        kind: MediaSourceKind.webdav,
        displayName: 'test',
      ),
      identity: 'account-a',
      baseUrl: source.base,
      persistent: (path) => 'https://nas.invalid/$path',
      remote: () async => remote,
    );

    final snapshot = await cachedSource.service.fetchDirectory('show');
    expect(snapshot.map((entry) => entry.name), ['video.mkv']);
    expect(remote.fetches, isEmpty);

    remote.entries = const [
      WebDavFile(
        name: 'video.mkv',
        href: 'https://nas.invalid/show/video.mkv',
        isDirectory: false,
      ),
      WebDavFile(
        name: 'video.srt',
        href: 'https://nas.invalid/show/video.srt',
        isDirectory: false,
      ),
    ];
    final refreshed = await cachedSource.service.fetchDirectory(
      'show',
      forceRefresh: true,
    );
    expect(refreshed.map((entry) => entry.name), ['video.mkv', 'video.srt']);
    expect(remote.fetches, ['show']);

    remote.failure = const NetworkException('offline');
    final fallback = await cachedSource.service.fetchDirectory(
      'show',
      forceRefresh: true,
    );
    expect(fallback.map((entry) => entry.name), ['video.mkv']);
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
  test('缓存目录被移除后仍可删除缓存记录', () async {
    final service = await open();
    final selection = await plan(service);
    await service.enqueue([selection]);
    await service.setPlaybackSuspended(false);
    await _until(() => service.complete(selection.bundle));

    final cacheDirectory = Directory(selection.bundle['root'] as String);
    await cacheDirectory.delete(recursive: true);
    await service.delete('bundle-a');

    expect(service.bundles, isEmpty);
    expect(service.files, isEmpty);
    expect(await cacheDirectory.exists(), isFalse);
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
