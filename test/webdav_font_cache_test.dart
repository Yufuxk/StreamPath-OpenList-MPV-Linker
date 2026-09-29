import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
    expect(downloads, 2);
    expect(otherSource?.directory.path, isNot(first?.directory.path));

    await cache.prune(
      () async => {WebDavFontCache.sessionKey('profile-a', 'second')},
    );
    expect(await first!.directory.exists(), isTrue);
    expect(await otherSource!.directory.exists(), isFalse);
    final orphan = Directory(
      '${base.path}${Platform.pathSeparator}streampath-fonts-orphan',
    );
    await orphan.create();
    await cache.prune(() async => <String>{});
    expect(await first.directory.exists(), isFalse);
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
