import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/data/models/media_entry.dart';
import 'package:streampath/data/models/subtitle_item.dart';
import 'package:streampath/domain/services/webdav_subtitle_localizer.dart';

void main() {
  late Directory root;
  late WebDavSubtitleLocalizer localizer;
  late List<String> artifacts;
  late int loads;

  const subtitle = SubtitleItem(
    name: '01.chs.ass',
    url: 'http://h/dav/show/01.chs.ass',
    language: SubtitleLanguage.chinese,
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('webdav_subtitle_');
    localizer = WebDavSubtitleLocalizer(directory: root);
    artifacts = [];
    loads = 0;
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  Future<List<int>> loader(
    String url, {
    required int maxBytes,
    required Duration timeout,
  }) async {
    loads++;
    return const [0xef, 0xbb, 0xbf, 0x41, 0x53, 0x53, 0x0a];
  }

  test('同源字幕取回会话目录并逐字节保留内容与扩展名', () async {
    final result = await localizer.localize(
      subtitle: subtitle,
      serverUrl: 'http://h/dav',
      sessionToken: 'session-a__e1',
      loader: loader,
      registerArtifact: artifacts.add,
    );

    expect(result, isNotNull);
    expect(result!.name, subtitle.name);
    expect(result.language, subtitle.language);
    expect(p.extension(result.url).toLowerCase(), '.ass');
    expect(p.isWithin(root.path, result.url), isTrue);
    expect(File(result.url).readAsBytesSync(), const [
      0xef,
      0xbb,
      0xbf,
      0x41,
      0x53,
      0x53,
      0x0a,
    ]);
    expect(artifacts, contains(p.dirname(result.url)));
    expect(artifacts, contains(result.url));
    expect(loads, 1);
  });

  test('非同源、本地路径与非字幕扩展不下载', () async {
    for (final item in const [
      SubtitleItem(
        name: 'third.ass',
        url: 'http://other/dav/third.ass',
        language: SubtitleLanguage.other,
      ),
      SubtitleItem(
        name: 'local.ass',
        url: '/cache/local.ass',
        language: SubtitleLanguage.other,
      ),
      SubtitleItem(
        name: 'note.txt',
        url: 'http://h/dav/note.txt',
        language: SubtitleLanguage.other,
      ),
    ]) {
      final result = await localizer.localize(
        subtitle: item,
        serverUrl: 'http://h/dav',
        sessionToken: 'session-a',
        loader: loader,
        registerArtifact: artifacts.add,
      );
      expect(result, isNull);
    }
    expect(loads, 0);
    expect(artifacts, isEmpty);
  });

  test('下载失败时不留下正式文件并返回 null 供调用方回退', () async {
    Future<List<int>> failing(
      String url, {
      required int maxBytes,
      required Duration timeout,
    }) async => throw const NetworkException('unauthorized');

    final result = await localizer.localize(
      subtitle: subtitle,
      serverUrl: 'http://h/dav',
      sessionToken: 'session-failed',
      loader: failing,
      registerArtifact: artifacts.add,
    );

    expect(result, isNull);
    final session = Directory(p.join(root.path, 'session-failed'));
    final files = session.existsSync()
        ? session.listSync().whereType<File>().toList()
        : <File>[];
    expect(files, isEmpty);
  });

  test('下载超时同样不留下正式文件', () async {
    Future<List<int>> timingOut(
      String url, {
      required int maxBytes,
      required Duration timeout,
    }) async => throw TimeoutException('slow');

    expect(
      await localizer.localize(
        subtitle: subtitle,
        serverUrl: 'http://h/dav',
        sessionToken: 'session-timeout',
        loader: timingOut,
        registerArtifact: artifacts.add,
      ),
      isNull,
    );
    final session = Directory(p.join(root.path, 'session-timeout'));
    expect(
      session.existsSync() ? session.listSync().whereType<File>() : const [],
      isEmpty,
    );
  });

  test('超过大小上限或无法创建会话目录时返回 null', () async {
    Future<List<int>> oversized(
      String url, {
      required int maxBytes,
      required Duration timeout,
    }) async => List<int>.filled(maxBytes + 1, 1);

    expect(
      await localizer.localize(
        subtitle: subtitle,
        serverUrl: 'http://h/dav',
        sessionToken: 'session-oversized',
        loader: oversized,
        registerArtifact: artifacts.add,
      ),
      isNull,
    );
    final session = Directory(p.join(root.path, 'session-oversized'));
    expect(
      session.existsSync() ? session.listSync().whereType<File>() : const [],
      isEmpty,
    );

    final blocked = File(p.join(root.path, 'blocked'));
    blocked.writeAsBytesSync([1]);
    final unavailable = WebDavSubtitleLocalizer(
      directory: Directory(blocked.path),
    );
    expect(
      await unavailable.localize(
        subtitle: subtitle,
        serverUrl: 'http://h/dav',
        sessionToken: 'session-blocked',
        loader: loader,
        registerArtifact: artifacts.add,
      ),
      isNull,
    );
  });

  test('服务端文件名不能穿越会话目录', () async {
    final result = await localizer.localize(
      subtitle: const SubtitleItem(
        name: 'evil.ass',
        url: 'http://h/dav/show/%2E%2E/%2E%2E/evil.ass',
        language: SubtitleLanguage.other,
      ),
      serverUrl: 'http://h/dav',
      sessionToken: 'session-traversal',
      loader: loader,
      registerArtifact: artifacts.add,
    );

    expect(result, isNotNull);
    expect(
      p.isWithin(p.join(root.path, 'session-traversal'), result!.url),
      isTrue,
    );
    expect(p.basename(result.url).contains('..'), isFalse);
    expect(p.extension(result.url), '.ass');
  });

  test('同一会话内相同 URL 只下载一次，不同集数互不覆盖', () async {
    final cache = <String, Future<SubtitleItem?>>{};
    final result = await localizer.localizeEntries(
      entries: const [
        MediaEntry(
          url: 'http://h/dav/show/01.mkv',
          progressTarget: 'http://h/dav/show/01.mkv',
          subtitle: SubtitleItem(
            name: '01.ass',
            url: 'http://h/dav/show/01.ass',
            language: SubtitleLanguage.exact,
          ),
        ),
        MediaEntry(
          url: 'http://h/dav/show/02.mkv',
          progressTarget: 'http://h/dav/show/02.mkv',
          subtitle: SubtitleItem(
            name: '02.ass',
            url: 'http://h/dav/show/02.ass',
            language: SubtitleLanguage.exact,
          ),
        ),
      ],
      serverUrl: 'http://h/dav',
      sessionToken: 'session-a',
      loader: loader,
      cache: cache,
      registerArtifact: artifacts.add,
    );

    expect(loads, 2);
    expect(result[0].url, 'http://h/dav/show/01.mkv');
    expect(result[1].url, 'http://h/dav/show/02.mkv');
    expect(
      p.basename(result[0].subtitle!.url),
      isNot(p.basename(result[1].subtitle!.url)),
    );
    expect(p.extension(result[0].subtitle!.url), '.ass');
    expect(p.extension(result[1].subtitle!.url), '.ass');

    final repeated = await localizer.localizeEntries(
      entries: [result[0]],
      serverUrl: 'http://h/dav',
      sessionToken: 'session-a',
      loader: loader,
      cache: cache,
      registerArtifact: artifacts.add,
    );
    expect(loads, 2);
    expect(repeated.single.subtitle?.url, result[0].subtitle?.url);
  });

  test('不同会话使用独立目录，互不覆盖', () async {
    final first = await localizer.localize(
      subtitle: subtitle,
      serverUrl: 'http://h/dav',
      sessionToken: 'session-a',
      loader: loader,
      registerArtifact: artifacts.add,
    );
    final second = await localizer.localize(
      subtitle: subtitle,
      serverUrl: 'http://h/dav',
      sessionToken: 'session-b',
      loader: loader,
      registerArtifact: artifacts.add,
    );

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(p.dirname(first!.url), isNot(p.dirname(second!.url)));
  });

  test('清理只删除不属于活动会话的临时目录', () async {
    final active = Directory(p.join(root.path, 'session-a'))..createSync();
    final activeStage = Directory(p.join(root.path, 'session-a__e2'))
      ..createSync();
    final orphan = Directory(p.join(root.path, 'session-b'))..createSync();
    File(p.join(orphan.path, 'stale.ass')).writeAsBytesSync([1]);
    final outside = await Directory.systemTemp.createTemp('subtitle_keep_');
    File(p.join(outside.path, 'keep.ass')).writeAsBytesSync([1]);
    addTearDown(() => outside.delete(recursive: true));

    await localizer.prune(() async => {'session-a'});

    expect(active.existsSync(), isTrue);
    expect(activeStage.existsSync(), isTrue);
    expect(orphan.existsSync(), isFalse);
    expect(File(p.join(outside.path, 'keep.ass')).existsSync(), isTrue);
  });
}
