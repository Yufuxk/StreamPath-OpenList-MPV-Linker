import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
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
  int fetches = 0;

  @override
  final MediaSourceDescriptor descriptor = const MediaSourceDescriptor(
    sourceId: 'local:test',
    kind: MediaSourceKind.local,
    displayName: 'test',
  );

  LocalMediaEntry _entry(String relative, String name, {bool dir = false}) =>
      LocalMediaEntry(
        name: name,
        relativePath: relative,
        absolutePath: p.joinAll([root.path, ...relative.split('/')]),
        isDirectory: dir,
      );

  @override
  Future<List<MediaDirectoryEntry>> fetchDirectory(
    String relativePath, {
    bool forceRefresh = false,
  }) async {
    fetches++;
    if (relativePath == 'Fonts') {
      return [_entry('Fonts/sample.ttf', 'sample.ttf')];
    }
    return [
      _entry('video.mkv', 'video.mkv'),
      _entry('video.ass', 'video.ass'),
      _entry('Fonts', 'Fonts', dir: true),
    ];
  }

  @override
  List<MediaDirectoryEntry>? cachedDirectory(String relativePath) => null;

  @override
  Future<MediaOpenTarget> resolve(MediaDirectoryEntry entry) async =>
      LocalMediaOpenTarget((entry as LocalMediaEntry).absolutePath);

  @override
  bool get supportsRemoteSearch => false;
}

void main() {
  test('缓存条目缺字体时补齐字体目录并保留缓存条目', () async {
    final root = await Directory.systemTemp.createTemp('font_preparer_');
    addTearDown(() => root.delete(recursive: true));
    final fonts = await Directory(p.join(root.path, 'Fonts')).create();
    await File(p.join(fonts.path, 'sample.ttf')).writeAsBytes([0, 1, 2, 3]);
    final source = _FakeLocalSource(root);
    final preparer = VideoEntryPreparer(
      source: source,
      config: const PlayerConfig(name: 'mpv', executable: 'mpv'),
      subtitleMatcher: const SubtitleMatcher(),
      fontMatcher: const WebDavFontMatcher(),
      titles: const {},
      cached: (path) async =>
          PreparedVideoItem(entry: MediaEntry(url: '/cache/video.mkv')),
    );
    final prepared = await preparer.prepare(
      const VideoQueueVersion(path: 'video.mkv', name: 'video.mkv'),
    );
    expect(prepared.entry.url, '/cache/video.mkv');
    expect(prepared.entry.subtitle?.name, 'video.ass');
    expect(prepared.localFontDirectory, fonts.path);
    expect(source.fetches, greaterThan(0));
  });

  test('缓存条目已有字幕和字体时不重复查找目录', () async {
    final root = await Directory.systemTemp.createTemp('font_preparer_');
    addTearDown(() => root.delete(recursive: true));
    final source = _FakeLocalSource(root);
    final preparer = VideoEntryPreparer(
      source: source,
      config: const PlayerConfig(name: 'mpv', executable: 'mpv'),
      subtitleMatcher: const SubtitleMatcher(),
      fontMatcher: const WebDavFontMatcher(),
      titles: const {},
      cached: (path) async => const PreparedVideoItem(
        entry: MediaEntry(
          url: '/cache/video.mkv',
          subtitle: SubtitleItem(
            name: 'cached.ass',
            url: '/cache/cached.ass',
            language: SubtitleLanguage.chinese,
            score: 0,
          ),
        ),
        localFontDirectory: '/cached/fonts',
      ),
    );
    final prepared = await preparer.prepare(
      const VideoQueueVersion(path: 'video.mkv', name: 'video.mkv'),
    );
    expect(prepared.localFontDirectory, '/cached/fonts');
    expect(prepared.entry.subtitle?.name, 'cached.ass');
    expect(source.fetches, 0);
  });
}
