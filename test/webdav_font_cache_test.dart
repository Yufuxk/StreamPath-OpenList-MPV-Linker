import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/domain/services/webdav_font_cache.dart';
import 'package:streampath/domain/services/webdav_font_localizer.dart';
import 'package:streampath/domain/services/webdav_font_matcher.dart';

void main() {
  late Directory base;

  setUp(() {
    base = Directory.systemTemp.createTempSync('webdav_font_cache_');
  });

  tearDown(() {
    base.deleteSync(recursive: true);
  });

  test('字体过期维护保留位于旧字体会话目录内的视频下载', () async {
    final video = File(
      '${base.path}/streampath-fonts-retired/StreamPathCache/video.mkv',
    );
    await video.parent.create(recursive: true);
    await video.writeAsString('download');
    final unused = await Directory(
      '${base.path}/streampath-fonts-unused',
    ).create();
    final cache = WebDavFontCache(directory: base);
    await cache.prune(() async => {}, preservedPaths: {video.parent.path});
    expect(await video.readAsString(), 'download');
    expect(await unused.exists(), isFalse);
  });

  test('同来源续播视频复用字体，引用清除后删除缓存', () async {
    const source = WebDavFontDirectory(
      name: 'Fonts',
      requestPath: 'Series/Fonts',
      entryKey: 'https://example.test/dav/Series/Fonts/',
      files: [
        WebDavFontFile(
          name: 'A.ttf',
          url: 'https://example.test/dav/Series/Fonts/A.ttf',
          size: 4,
          etag: 'v1',
        ),
      ],
    );
    final cache = WebDavFontCache(directory: base);
    var downloads = 0;
    Future<List<int>> loader(
      String url, {
      required int maxBytes,
      required Duration timeout,
    }) async {
      downloads++;
      return [1, 2, 3, 4];
    }

    Future<WebDavFontLocalizationResult?> load(
      String sessionId, {
      void Function(WebDavFontLocalizationProgress)? onProgress,
    }) => cache.localize(
      source: source,
      sourceId: 'profile-a',
      retentionSessionId: sessionId,
      sessionBase: base,
      sessionId: sessionId,
      loader: loader,
      maxFiles: 256,
      maxBytes: WebDavFontLocalizer.maxSessionBytes,
      timeout: const Duration(seconds: 30),
      enabled: true,
      onProgress: onProgress,
    );

    final first = await load('first');
    expect(first?.persistent, isTrue);
    expect(downloads, 1);
    final reports = <WebDavFontLocalizationProgress>[];
    final second = await load('second', onProgress: reports.add);
    expect(second?.directory.path, first?.directory.path);
    expect(downloads, 1);
    expect(reports.last.fromCache, isTrue);

    await second!.files.single.writeAsBytes([4, 3, 2, 1]);
    final repaired = await load('second');
    expect(await repaired!.files.single.readAsBytes(), [1, 2, 3, 4]);
    expect(downloads, 2);

    final otherSource = await cache.localize(
      source: source,
      sourceId: 'profile-b',
      retentionSessionId: 'third',
      sessionBase: base,
      sessionId: 'third',
      loader: loader,
      maxFiles: 256,
      maxBytes: WebDavFontLocalizer.maxSessionBytes,
      timeout: const Duration(seconds: 30),
      enabled: true,
    );
    expect(downloads, 3);
    expect(otherSource?.directory.path, isNot(first?.directory.path));

    await cache.prune(
      () async => {WebDavFontCache.sessionKey('profile-a', 'second')},
    );
    expect(await repaired.directory.exists(), isTrue);
    expect(await otherSource!.directory.exists(), isFalse);
    final orphan = Directory(
      '${base.path}${Platform.pathSeparator}streampath-fonts-orphan',
    );
    await orphan.create();
    await cache.prune(() async => <String>{});
    expect(await repaired.directory.exists(), isFalse);
    expect(await orphan.exists(), isFalse);
  });

  test('字体版本变化触发重新下载', () async {
    WebDavFontDirectory source(String etag) => WebDavFontDirectory(
      name: 'Fonts',
      requestPath: 'Fonts',
      entryKey: 'https://example.test/dav/Fonts/',
      files: [
        WebDavFontFile(
          name: 'A.ttf',
          url: 'https://example.test/dav/Fonts/A.ttf',
          size: 1,
          etag: etag,
        ),
      ],
    );
    final cache = WebDavFontCache(directory: base);
    var downloads = 0;
    Future<WebDavFontLocalizationResult?> load(String etag) => cache.localize(
      source: source(etag),
      sourceId: 'profile-a',
      retentionSessionId: 'session',
      sessionBase: base,
      sessionId: etag,
      loader: (url, {required maxBytes, required timeout}) async {
        downloads++;
        return [downloads];
      },
      maxFiles: 256,
      maxBytes: WebDavFontLocalizer.maxSessionBytes,
      timeout: const Duration(seconds: 30),
      enabled: true,
    );
    final first = await load('v1');
    final second = await load('v2');
    expect(downloads, 2);
    expect(second?.directory.path, isNot(first?.directory.path));
  });

  test(
    'partial cache retries only failed or damaged files and protects active generations',
    () async {
      final source = WebDavFontDirectory(
        name: 'Fonts',
        requestPath: 'Fonts',
        entryKey: 'folder',
        files: [
          for (var i = 0; i < 5; i++)
            WebDavFontFile(name: '$i.ttf', url: '$i', size: 2, etag: 'v1'),
        ],
      );
      final cache = WebDavFontCache(directory: base);
      final calls = <String>[];
      final progress = <WebDavFontLocalizationProgress>[];
      var offline = true;
      Future<WebDavFontLocalizationResult?> load(String session) =>
          cache.localize(
            source: source,
            sourceId: 'source',
            retentionSessionId: session,
            sessionBase: base,
            sessionId: session,
            enabled: true,
            maxFiles: 256,
            maxBytes: 1024,
            timeout: const Duration(seconds: 2),
            mediaPaths: ['show/E01.mkv'],
            onProgress: progress.add,
            loader: (url, {required timeout, required maxBytes}) async {
              calls.add(url);
              if (url == '3' && offline) {
                throw AppException.network('Fixture offline');
              }
              return [int.parse(url), 42];
            },
          );
      final partial = (await load('partial'))!;
      expect(partial.summary.complete, isFalse);
      expect(partial.summary.succeeded, 4);
      expect(partial.summary.failed, 1);
      expect(partial.summary.issues, {WebDavFontIssue.network: 1});
      expect(calls.where((url) => url == '3'), hasLength(2));
      expect(progress.last.completedFiles, 4);
      expect(progress.last.fromCache, isFalse);
      expect(
        await cache.forCachedMedia(
          sourceId: 'source',
          mediaPath: 'show/E01.mkv',
          retentionSessionId: 'offline',
        ),
        isNull,
      );

      offline = false;
      calls.clear();
      final complete = (await load('complete'))!;
      expect(calls, ['3']);
      expect(complete.summary.cacheHits, 4);
      expect(complete.summary.complete, isTrue);
      await complete.files[1].writeAsBytes([99, 99]);
      calls.clear();
      final repaired = (await load('repaired'))!;
      expect(calls, ['1']);
      expect(repaired.summary.cacheHits, 4);
      final fallback = await cache.forCachedMedia(
        sourceId: 'source',
        mediaPath: 'show/E01.mkv',
        retentionSessionId: 'offline',
      );
      expect(fallback?.directory.path, repaired.directory.path);
      expect(
        await cache.forCachedMedia(
          sourceId: 'other',
          mediaPath: 'show/E01.mkv',
          retentionSessionId: 'offline',
        ),
        isNull,
      );
      await cache.prune(
        () async => {WebDavFontCache.sessionKey('source', 'offline')},
        activePaths: () => {complete.directory.path},
      );
      expect(await complete.directory.exists(), isTrue);
      expect(await partial.directory.exists(), isFalse);
      expect(await repaired.directory.exists(), isTrue);
      await cache.prune(() async => {});
      expect(await complete.directory.exists(), isFalse);
      expect(await repaired.directory.exists(), isFalse);
    },
  );

  test(
    'weak validators allow cache hits then refresh only weak fonts',
    () async {
      var now = DateTime(2026, 11, 20);
      final cache = WebDavFontCache(directory: base, now: () => now);
      final calls = <String>[];
      const source = WebDavFontDirectory(
        name: 'Fonts',
        requestPath: 'Fonts',
        entryKey: 'folder',
        files: [
          WebDavFontFile(name: 'weak.ttf', url: 'weak', size: 1),
          WebDavFontFile(
            name: 'strong.ttf',
            url: 'strong',
            size: 1,
            etag: 'v1',
          ),
        ],
      );
      Future<WebDavFontLocalizationResult?> load() => cache.localize(
        source: source,
        sourceId: 'source',
        retentionSessionId: 'session',
        sessionBase: base,
        sessionId: 'session',
        enabled: true,
        maxFiles: 256,
        maxBytes: 1024,
        timeout: const Duration(seconds: 2),
        loader: (url, {required timeout, required maxBytes}) async {
          calls.add(url);
          return [now.day];
        },
      );
      final first = (await load())!;
      calls.clear();
      now = now.add(const Duration(days: 6));
      expect((await load())?.directory.path, first.directory.path);
      expect(calls, isEmpty);
      now = now.add(const Duration(days: 1));
      final refreshed = (await load())!;
      expect(calls, ['weak']);
      expect(await refreshed.files[0].readAsBytes(), [27]);
      expect(await refreshed.files[1].readAsBytes(), [20]);
    },
  );

  test('并发清理在字体准备完成后读取最新续播引用', () async {
    const source = WebDavFontDirectory(
      name: 'Fonts',
      requestPath: 'Fonts',
      entryKey: 'https://example.test/dav/Fonts/',
      files: [
        WebDavFontFile(
          name: 'A.ttf',
          url: 'https://example.test/dav/Fonts/A.ttf',
          size: 1,
        ),
      ],
    );
    final cache = WebDavFontCache(directory: base);
    final started = Completer<void>();
    final release = Completer<void>();
    final loading = cache.localize(
      source: source,
      sourceId: 'profile-a',
      retentionSessionId: 'session',
      sessionBase: base,
      sessionId: 'session',
      loader: (url, {required maxBytes, required timeout}) async {
        started.complete();
        await release.future;
        return [1];
      },
      maxFiles: 256,
      maxBytes: WebDavFontLocalizer.maxSessionBytes,
      timeout: const Duration(seconds: 30),
      enabled: true,
    );
    await started.future;
    var active = <String>{};
    final pruning = cache.prune(() async => active);
    active = {WebDavFontCache.sessionKey('profile-a', 'session')};
    release.complete();
    final result = await loading;
    await pruning;
    expect(await result!.directory.exists(), isTrue);
  });

  test('关闭缓存时每次使用独立会话字体目录', () async {
    const source = WebDavFontDirectory(
      name: 'Fonts',
      requestPath: 'Fonts',
      entryKey: 'https://example.test/dav/Fonts/',
      files: [
        WebDavFontFile(
          name: 'A.ttf',
          url: 'https://example.test/dav/Fonts/A.ttf',
          size: 1,
        ),
      ],
    );
    final cache = WebDavFontCache(directory: base);
    var downloads = 0;
    Future<WebDavFontLocalizationResult?> load(String sessionId) =>
        cache.localize(
          source: source,
          sourceId: 'profile-a',
          retentionSessionId: sessionId,
          sessionBase: base,
          sessionId: sessionId,
          loader: (url, {required maxBytes, required timeout}) async {
            downloads++;
            return [1];
          },
          maxFiles: 256,
          maxBytes: WebDavFontLocalizer.maxSessionBytes,
          timeout: const Duration(seconds: 30),
          enabled: false,
        );
    final first = await load('first');
    final second = await load('second');
    expect(downloads, 2);
    expect(first?.persistent, isFalse);
    expect(second?.directory.path, isNot(first?.directory.path));
  });
}
