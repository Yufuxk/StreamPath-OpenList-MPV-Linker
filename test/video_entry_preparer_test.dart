import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/data/models/external_audio_track.dart';
import 'package:streampath/data/models/media_directory_entry.dart';
import 'package:streampath/data/models/media_entry.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/player_config.dart';
import 'package:streampath/data/models/subtitle_item.dart';
import 'package:streampath/data/models/video_queue.dart';
import 'package:streampath/domain/repositories/media_directory_source.dart';
import 'package:streampath/domain/services/subtitle_matcher.dart';
import 'package:streampath/domain/services/video_entry_preparer.dart';
import 'package:streampath/domain/services/webdav_font_matcher.dart';

class _FakeLocalSource implements MediaDirectorySource {
  _FakeLocalSource(this.root);
  final Directory root;
  final Map<String, List<MediaDirectoryEntry>> directories = {};
  final Map<String, Object> failures = {};
  final List<String> fetches = [];
  Object? failure;

  @override
  final MediaSourceDescriptor descriptor = const MediaSourceDescriptor(
    sourceId: 'local:test',
    kind: MediaSourceKind.local,
    displayName: 'test',
  );

  LocalMediaEntry entry(String relative, {bool directory = false}) =>
      LocalMediaEntry(
        name: p.posix.basename(relative),
        relativePath: relative,
        absolutePath: p.joinAll([root.path, ...relative.split('/')]),
        isDirectory: directory,
      );

  @override
  Future<List<MediaDirectoryEntry>> fetchDirectory(
    String relativePath, {
    bool forceRefresh = false,
  }) async {
    fetches.add(relativePath);
    final scoped = failures[relativePath];
    if (scoped != null) throw scoped;
    final error = failure;
    if (error != null) throw error;
    return directories[relativePath] ?? const [];
  }

  @override
  List<MediaDirectoryEntry>? cachedDirectory(String relativePath) => null;

  @override
  Future<MediaOpenTarget> resolve(MediaDirectoryEntry item) async =>
      LocalMediaOpenTarget((item as LocalMediaEntry).absolutePath);

  @override
  bool get supportsRemoteSearch => false;
}

const _config = PlayerConfig(name: 'mpv', executable: 'mpv');

void main() {
  late Directory root;
  late _FakeLocalSource source;

  const cachedSubtitle = SubtitleItem(
    name: 'cached.ass',
    url: '/cache/subtitles/cached.ass',
    language: SubtitleLanguage.chinese,
  );
  const cachedAudio = ExternalAudioTrack(
    name: 'cached.flac',
    url: '/cache/audio/cached.flac',
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('video_preparer_');
    source = _FakeLocalSource(root);
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  Future<void> writeFile(String relative, [List<int> bytes = const [1]]) async {
    final file = File(p.joinAll([root.path, ...relative.split('/')]));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  }

  void addSeasonDirectory(
    String parent, {
    bool withSubtitle = true,
    bool withFonts = true,
  }) {
    source.directories[parent] = [
      source.entry('$parent/video.mkv'),
      if (withSubtitle) source.entry('$parent/video.ass'),
      if (withFonts) source.entry('$parent/Fonts', directory: true),
    ];
    if (withFonts) {
      source.directories['$parent/Fonts'] = [
        source.entry('$parent/Fonts/sample.ttf'),
      ];
    }
  }

  VideoEntryPreparer preparer({
    PlayerConfig config = _config,
    Future<PreparedVideoItem?> Function(String path)? cached,
  }) => VideoEntryPreparer(
    source: source,
    config: config,
    subtitleMatcher: const SubtitleMatcher(),
    fontMatcher: const WebDavFontMatcher(),
    titles: const {},
    cached: cached,
  );

  test('完整缓存命中直接复用，不读取目录并保留全部资源', () async {
    final hit = PreparedVideoItem(
      entry: MediaEntry(
        url: '/cache/video.mkv',
        progressTarget: 'https://nas.invalid/show/video.mkv',
        catalogPath: 'show/video.mkv',
        title: 'Cached title',
        subtitle: cachedSubtitle,
        externalAudioTracks: const [cachedAudio],
      ),
      localFontDirectory: '/cache/fonts',
    );
    final prepared = await preparer(cached: (_) async => hit).prepare(
      const VideoQueueVersion(path: 'show/video.mkv', name: 'video.mkv'),
    );

    expect(source.fetches, isEmpty);
    expect(prepared, same(hit));
    expect(prepared.entry.url, '/cache/video.mkv');
    expect(prepared.entry.progressTarget, 'https://nas.invalid/show/video.mkv');
    expect(prepared.entry.catalogPath, 'show/video.mkv');
    expect(prepared.entry.title, 'Cached title');
    expect(prepared.entry.subtitle, same(cachedSubtitle));
    expect(prepared.entry.externalAudioTracks, [cachedAudio]);
    expect(prepared.localFontDirectory, '/cache/fonts');
  });

  test('缓存缺字幕时补齐字幕并保留缓存视频、进度、音轨与字体', () async {
    await writeFile('show/video.mkv');
    await writeFile('show/video.ass');
    await writeFile('show/Fonts/sample.ttf');
    addSeasonDirectory('show');
    final hit = PreparedVideoItem(
      entry: MediaEntry(
        url: '/cache/video.mkv',
        progressTarget: 'https://nas.invalid/show/video.mkv',
        catalogPath: 'show/video.mkv',
        title: 'Cached title',
        externalAudioTracks: const [cachedAudio],
      ),
      localFontDirectory: '/cache/fonts',
    );

    final prepared = await preparer(cached: (_) async => hit).prepare(
      const VideoQueueVersion(path: 'show/video.mkv', name: 'video.mkv'),
    );

    expect(prepared.entry.url, '/cache/video.mkv');
    expect(prepared.entry.progressTarget, 'https://nas.invalid/show/video.mkv');
    expect(prepared.entry.catalogPath, 'show/video.mkv');
    expect(prepared.entry.title, 'Cached title');
    expect(prepared.entry.externalAudioTracks, [cachedAudio]);
    expect(prepared.entry.subtitle?.name, 'video.ass');
    expect(
      prepared.entry.subtitle?.url,
      p.join(root.path, 'show', 'video.ass'),
    );
    expect(prepared.localFontDirectory, '/cache/fonts');
    expect(source.fetches, ['show']);
  });

  test('缓存缺字体时补齐字体并保留缓存字幕与视频', () async {
    await writeFile('show/video.mkv');
    await writeFile('show/Fonts/sample.ttf');
    addSeasonDirectory('show', withSubtitle: false);
    final hit = PreparedVideoItem(
      entry: MediaEntry(
        url: '/cache/video.mkv',
        progressTarget: 'https://nas.invalid/show/video.mkv',
        subtitle: cachedSubtitle,
      ),
    );

    final prepared = await preparer(cached: (_) async => hit).prepare(
      const VideoQueueVersion(path: 'show/video.mkv', name: 'video.mkv'),
    );

    expect(prepared.entry.url, '/cache/video.mkv');
    expect(prepared.entry.progressTarget, 'https://nas.invalid/show/video.mkv');
    expect(prepared.entry.subtitle, same(cachedSubtitle));
    expect(prepared.localFontDirectory, p.join(root.path, 'show', 'Fonts'));
    expect(source.fetches, ['show', 'show/Fonts']);
  });

  test('补齐字幕时不覆盖已缓存字体，补齐字体时不覆盖已缓存字幕', () async {
    await writeFile('show/video.mkv');
    await writeFile('show/video.ass');
    await writeFile('show/Fonts/sample.ttf');
    addSeasonDirectory('show');

    final subtitleOnly =
        await preparer(
          cached: (_) async => PreparedVideoItem(
            entry: const MediaEntry(url: '/cache/video.mkv'),
            localFontDirectory: '/cache/fonts',
          ),
        ).prepare(
          const VideoQueueVersion(path: 'show/video.mkv', name: 'video.mkv'),
        );
    expect(subtitleOnly.entry.subtitle?.name, 'video.ass');
    expect(subtitleOnly.localFontDirectory, '/cache/fonts');

    final fontsOnly =
        await preparer(
          cached: (_) async => const PreparedVideoItem(
            entry: MediaEntry(
              url: '/cache/video.mkv',
              subtitle: cachedSubtitle,
            ),
          ),
        ).prepare(
          const VideoQueueVersion(path: 'show/video.mkv', name: 'video.mkv'),
        );
    expect(fontsOnly.entry.subtitle, same(cachedSubtitle));
    expect(fontsOnly.localFontDirectory, p.join(root.path, 'show', 'Fonts'));
  });

  test('缓存资源补查失败时仍返回有效缓存媒体', () async {
    final hit = PreparedVideoItem(
      entry: MediaEntry(
        url: '/cache/video.mkv',
        progressTarget: 'https://nas.invalid/show/video.mkv',
        subtitle: cachedSubtitle,
      ),
    );
    source.failure = const NetworkException('offline');

    final prepared = await preparer(cached: (_) async => hit).prepare(
      const VideoQueueVersion(path: 'show/video.mkv', name: 'video.mkv'),
    );

    expect(prepared, same(hit));
    expect(prepared.entry.url, '/cache/video.mkv');
    expect(prepared.entry.subtitle, same(cachedSubtitle));
  });

  test('自动注入关闭时不补查目录并原样复用缓存条目', () async {
    final hit = const PreparedVideoItem(
      entry: MediaEntry(url: '/cache/video.mkv'),
    );
    final prepared =
        await preparer(
          config: const PlayerConfig(
            name: 'mpv',
            executable: 'mpv',
            subtitleInjectionEnabled: false,
          ),
          cached: (_) async => hit,
        ).prepare(
          const VideoQueueVersion(path: 'show/video.mkv', name: 'video.mkv'),
        );

    expect(prepared, same(hit));
    expect(source.fetches, isEmpty);
  });

  test('同一父目录的负结果在一次准备中只查询一次', () async {
    await writeFile('show/E01.mkv');
    await writeFile('show/E02.mkv');
    addSeasonDirectory('show', withSubtitle: false, withFonts: false);
    final subject = preparer(
      cached: (_) async =>
          const PreparedVideoItem(entry: MediaEntry(url: '/cache/video.mkv')),
    );

    await subject.prepare(
      const VideoQueueVersion(path: 'show/E01.mkv', name: 'E01.mkv'),
    );
    await subject.prepare(
      const VideoQueueVersion(path: 'show/E02.mkv', name: 'E02.mkv'),
    );

    expect(source.fetches, ['show']);
  });

  test('共享字体在完整缓存命中时跳过目录读取，缺字体时从列表根补查', () async {
    await writeFile('show/video.mkv');
    await writeFile('show/Fonts/sample.ttf');
    addSeasonDirectory('show', withSubtitle: false);

    final complete = preparer(
      config: const PlayerConfig(
        name: 'mpv',
        executable: 'mpv',
        sharePlaylistFonts: true,
      ),
      cached: (_) async => const PreparedVideoItem(
        entry: MediaEntry(url: '/cache/video.mkv'),
        localFontDirectory: '/cache/fonts',
      ),
    );
    await complete.prepareSharedFonts('show', startPath: 'show/video.mkv');
    expect(source.fetches, isEmpty);

    final missing = preparer(
      config: const PlayerConfig(
        name: 'mpv',
        executable: 'mpv',
        sharePlaylistFonts: true,
      ),
      cached: (_) async =>
          const PreparedVideoItem(entry: MediaEntry(url: '/cache/video.mkv')),
    );
    await missing.prepareSharedFonts('show', startPath: 'show/video.mkv');
    final prepared = await missing.prepare(
      const VideoQueueVersion(path: 'show/video.mkv', name: 'video.mkv'),
    );
    expect(prepared.localFontDirectory, p.join(root.path, 'show', 'Fonts'));
  });

  test('字体目录读取失败不影响视频与字幕准备', () async {
    await writeFile('show/video.mkv');
    await writeFile('show/video.ass');
    addSeasonDirectory('show');
    source.failures['show/Fonts'] = const FileSystemException('unreadable');

    final prepared = await preparer().prepare(
      const VideoQueueVersion(path: 'show/video.mkv', name: 'video.mkv'),
    );

    expect(prepared.entry.url, p.join(root.path, 'show', 'video.mkv'));
    expect(prepared.entry.subtitle?.name, 'video.ass');
    expect(prepared.localFontDirectory, isNull);
  });

  test('只有字幕没有字体目录时仍正常准备字幕', () async {
    await writeFile('show/video.mkv');
    await writeFile('show/video.ass');
    addSeasonDirectory('show', withFonts: false);

    final prepared = await preparer().prepare(
      const VideoQueueVersion(path: 'show/video.mkv', name: 'video.mkv'),
    );

    expect(prepared.entry.subtitle?.name, 'video.ass');
    expect(prepared.localFontDirectory, isNull);
    expect(source.fetches, ['show']);
  });

  test('不同集数的字体目录互不串用', () async {
    for (final season in ['a', 'b']) {
      await writeFile('$season/video.mkv');
      await writeFile('$season/Fonts/sample.ttf');
      addSeasonDirectory(season, withSubtitle: false);
    }
    final subject = preparer();

    final first = await subject.prepare(
      const VideoQueueVersion(path: 'a/video.mkv', name: 'video.mkv'),
    );
    final second = await subject.prepare(
      const VideoQueueVersion(path: 'b/video.mkv', name: 'video.mkv'),
    );

    expect(first.localFontDirectory, p.join(root.path, 'a', 'Fonts'));
    expect(second.localFontDirectory, p.join(root.path, 'b', 'Fonts'));
  });
}
