import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/directory_cache.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/models/appearance_config.dart';
import 'package:streampath/data/models/media_library_config.dart';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/data/models/playback_progress.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/presentation/pages/media_library_page.dart';
import 'package:streampath/presentation/theme/app_theme.dart';

void main() {
  const sourceId = 'source-a';
  late Directory tempDir;
  late MediaLibraryStore store;
  late PlaybackProgressService videoProgress;
  late PlaybackProgressService audioProgress;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('media_library_page_');
    store = MediaLibraryStore.forPath(
      '${tempDir.path}${Platform.pathSeparator}media_library.json',
    );
    await store.load();
    videoProgress = await PlaybackProgressService.open(
      '${tempDir.path}${Platform.pathSeparator}video.db',
      factory: databaseFactoryFfi,
    );
    audioProgress = await PlaybackProgressService.open(
      '${tempDir.path}${Platform.pathSeparator}audio.db',
      factory: databaseFactoryFfi,
    );
    videoProgress.useProfile(sourceId);
    audioProgress.useProfile(sourceId);
  });

  tearDown(() async {
    await videoProgress.close();
    await audioProgress.close();
    await tempDir.delete(recursive: true);
  });

  WebDavFile file(String name, {bool directory = false}) => WebDavFile(
    name: name,
    href: '/dav/media/${Uri.encodeComponent(name)}',
    isDirectory: directory,
  );

  MediaLibraryItem item(String name, MediaLibraryKind kind) => MediaLibraryItem(
    sourceId: sourceId,
    parentPath: '媒体',
    name: name,
    kind: kind,
  );

  Widget buildPage({
    AppearanceConfig appearance = const AppearanceConfig(),
    MediaLibraryConfig config = const MediaLibraryConfig(),
    List<VisitedDirectorySnapshot>? snapshots,
    PlaybackProgressReader? videoProgressReader,
    PlaybackProgressReader? audioProgressReader,
  }) => MaterialApp(
    theme: AppTheme.light(
      glass: appearance.isGlass,
      glassOpacity: appearance.glassOpacity,
    ),
    home: MediaLibraryPage(
      sourceId: sourceId,
      store: store,
      config: config,
      directoryCache: _FakeDirectoryCache(snapshots ?? const []),
      videoProgressService: videoProgressReader ?? videoProgress,
      audioProgressService: audioProgressReader ?? audioProgress,
      resolveUrl: (href) => 'https://example.test$href',
    ),
  );

  Future<void> settleLibraryPage(WidgetTester tester) async {
    for (var index = 0; index < 4; index++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    }
  }

  Future<void> waitForLibraryState(WidgetTester tester, Finder finder) async {
    for (var index = 0; index < 60; index++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
      if (finder.evaluate().isNotEmpty) return;
    }
    expect(finder, findsOneWidget);
  }

  testWidgets('经典、Acrylic 和 Mica 外观在窄宽窗口均不溢出', (tester) async {
    final appearances = [
      const AppearanceConfig(style: InterfaceStyle.classic),
      const AppearanceConfig(
        style: InterfaceStyle.glass,
        material: WindowMaterialPreference.acrylic,
      ),
      const AppearanceConfig(
        style: InterfaceStyle.glass,
        material: WindowMaterialPreference.mica,
      ),
    ];
    final widths = [420.0, 1180.0, 420.0];
    for (var index = 0; index < appearances.length; index++) {
      tester.view.physicalSize = Size(widths[index], 760);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(buildPage(appearance: appearances[index]));
      await settleLibraryPage(tester);

      expect(find.text('媒体中心'), findsOneWidget);
      expect(find.byKey(const Key('favorite-media-lane')), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  });

  testWidgets('顶部标题栏和分类按钮使用紧凑高度', (tester) async {
    await tester.pumpWidget(buildPage());
    await settleLibraryPage(tester);

    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    final tabs = tester.widgetList<Tab>(find.byType(Tab)).toList();
    expect(appBar.toolbarHeight, 48);
    expect(tabs, hasLength(4));
    expect(tabs.map((tab) => tab.height), everyElement(40));
    expect(tester.takeException(), isNull);
  });

  testWidgets('全局搜索支持剪贴板历史输入菜单并按媒体类型分栏', (tester) async {
    final snapshot = VisitedDirectorySnapshot(
      path: '媒体',
      entries: [file('歌曲.flac'), file('歌曲.mkv'), file('歌曲目录', directory: true)],
      lastAccessedAt: DateTime.utc(2026, 8, 19),
    );
    await tester.pumpWidget(buildPage(snapshots: [snapshot]));
    await settleLibraryPage(tester);

    final field = tester.widget<TextField>(
      find.byKey(const Key('media-library-global-search')),
    );
    expect(field.contextMenuBuilder, isNotNull);

    await tester.enterText(
      find.byKey(const Key('media-library-global-search')),
      '歌曲',
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      find.byKey(const Key('media-library-search-results')),
      findsOneWidget,
    );
    expect(find.text('目录'), findsWidgets);
    expect(find.text('视频'), findsOneWidget);
    expect(find.text('音频'), findsOneWidget);
  });

  testWidgets('取消收藏只更新媒体中心资产记录', (tester) async {
    await tester.runAsync(
      () => store.toggleFavorite(item('收藏影片.mkv', MediaLibraryKind.video)),
    );
    await tester.pumpWidget(buildPage());
    await settleLibraryPage(tester);

    expect(find.text('收藏影片.mkv'), findsOneWidget);
    final removeButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.star),
    );
    late List<MediaLibraryRecord> favorites;
    await tester.runAsync(() async {
      removeButton.onPressed!();
      favorites = await store.favorites(sourceId);
    });
    await settleLibraryPage(tester);

    expect(find.text('还没有收藏视频'), findsOneWidget);
    expect(favorites, isEmpty);
  });

  testWidgets('继续播放使用视频临时点和音频正式进度并过滤片尾', (tester) async {
    final video = item('继续影片.mkv', MediaLibraryKind.video);
    final ending = item('片尾影片.mkv', MediaLibraryKind.video);
    final audio = item('继续歌曲.flac', MediaLibraryKind.audio);
    final videoFile = file(video.name);
    final endingFile = file(ending.name);
    final audioFile = file(audio.name);
    String url(WebDavFile value) => 'https://example.test${value.href}';
    await tester.runAsync(() async {
      await store.recordPlayback(video);
      await store.recordPlayback(ending);
      await store.recordPlayback(audio);
      await videoProgress.saveProgress(url: url(videoFile), positionMs: 0);
      await videoProgress.saveTemporaryProgress(
        url: url(videoFile),
        positionMs: 120000,
        durationMs: 3600000,
      );
      await videoProgress.saveProgress(
        url: url(endingFile),
        positionMs: 595000,
        durationMs: 600000,
      );
      await audioProgress.saveProgress(
        url: url(audioFile),
        positionMs: 90000,
        durationMs: 300000,
      );
    });
    final snapshot = VisitedDirectorySnapshot(
      path: '媒体',
      entries: [videoFile, endingFile, audioFile],
      lastAccessedAt: DateTime.utc(2026, 8, 19),
    );

    await tester.pumpWidget(buildPage(snapshots: [snapshot]));
    await settleLibraryPage(tester);
    await tester.tap(find.text('继续播放').first);
    await tester.pumpAndSettle();

    expect(find.text('继续影片.mkv'), findsOneWidget);
    expect(find.text('片尾影片.mkv'), findsNothing);

    await tester.tap(find.text('音频').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('继续歌曲.flac'), findsOneWidget);
  });

  testWidgets('页面保持打开时实时更新历史、播放时间和完成状态', (tester) async {
    final video = item('实时影片.mkv', MediaLibraryKind.video);
    final nextVideo = item('新播放影片.mkv', MediaLibraryKind.video);
    final videoFile = file(video.name);
    final snapshot = VisitedDirectorySnapshot(
      path: '媒体',
      entries: [videoFile, file(nextVideo.name)],
      lastAccessedAt: DateTime.utc(2026, 8, 19),
    );
    final url = 'https://example.test${videoFile.href}';
    await tester.runAsync(() async {
      await store.recordPlayback(video);
      await videoProgress.saveProgress(
        url: url,
        positionMs: 26000,
        durationMs: 600000,
      );
    });
    await tester.pumpWidget(buildPage(snapshots: [snapshot]));
    await settleLibraryPage(tester);
    await tester.tap(find.text('继续播放').first);
    await tester.pumpAndSettle();

    expect(find.textContaining('已播放 00:26'), findsOneWidget);

    await tester.runAsync(
      () => videoProgress.saveProgress(
        url: url,
        positionMs: 120000,
        durationMs: 600000,
      ),
    );
    await waitForLibraryState(tester, find.textContaining('已播放 02:00'));

    await tester.runAsync(
      () => videoProgress.saveProgress(
        url: url,
        positionMs: 595000,
        durationMs: 600000,
      ),
    );
    await waitForLibraryState(tester, find.text('没有可继续播放的视频'));

    await tester.runAsync(() => store.recordPlayback(nextVideo));
    await tester.tap(find.text('最近播放').first);
    await tester.pumpAndSettle();
    await waitForLibraryState(tester, find.text(nextVideo.name));
  });

  testWidgets('单 URL 进度更新只读取视频目标且不扫描音频分栏', (tester) async {
    final video = item('计数影片.mkv', MediaLibraryKind.video);
    final audio = item('计数歌曲.flac', MediaLibraryKind.audio);
    final videoFile = file(video.name);
    final audioFile = file(audio.name);
    final videoUrl = 'https://example.test${videoFile.href}';
    final audioUrl = 'https://example.test${audioFile.href}';
    final videoReader = _CountingProgressReader()
      ..values[videoUrl] = _progress(videoUrl, 26000);
    final audioReader = _CountingProgressReader()..values[audioUrl] = null;
    await tester.runAsync(() async {
      await store.recordPlayback(video, playbackSessionId: 'video-count');
      await store.recordPlayback(audio, playbackSessionId: 'audio-count');
    });

    await tester.pumpWidget(
      buildPage(
        snapshots: [
          VisitedDirectorySnapshot(
            path: '媒体',
            entries: [videoFile, audioFile],
            lastAccessedAt: DateTime.utc(2026, 8, 23),
          ),
        ],
        videoProgressReader: videoReader,
        audioProgressReader: audioReader,
      ),
    );
    await settleLibraryPage(tester);
    await tester.tap(find.text('继续播放').first);
    await tester.pumpAndSettle();
    videoReader.clearReads();
    audioReader.clearReads();

    videoReader.values[videoUrl] = _progress(videoUrl, 120000);
    videoReader.notifyUrl(videoUrl);
    await tester.pump(const Duration(milliseconds: 130));
    await waitForLibraryState(tester, find.textContaining('已播放 02:00'));

    expect(videoReader.resumeReads, [videoUrl]);
    expect(videoReader.progressReads, isEmpty);
    expect(audioReader.resumeReads, isEmpty);
    expect(audioReader.progressReads, isEmpty);
  });

  testWidgets('同一 URL 的多个播放会话在单次通知中只读取一次进度', (tester) async {
    final video = item('重复会话影片.mkv', MediaLibraryKind.video);
    final videoFile = file(video.name);
    final videoUrl = 'https://example.test${videoFile.href}';
    final videoReader = _CountingProgressReader()
      ..values[videoUrl] = _progress(videoUrl, 26000);
    await tester.runAsync(() async {
      await store.recordPlayback(video, playbackSessionId: 'same-url-a');
      await store.recordPlayback(video, playbackSessionId: 'same-url-b');
    });
    await tester.pumpWidget(
      buildPage(
        snapshots: [
          VisitedDirectorySnapshot(
            path: '媒体',
            entries: [videoFile],
            lastAccessedAt: DateTime.utc(2026, 8, 23),
          ),
        ],
        videoProgressReader: videoReader,
        audioProgressReader: _CountingProgressReader(),
      ),
    );
    await settleLibraryPage(tester);
    await tester.tap(find.text('继续播放').first);
    await tester.pumpAndSettle();
    expect(find.text(video.name), findsNWidgets(2));
    videoReader.clearReads();

    videoReader.values[videoUrl] = _progress(videoUrl, 120000);
    videoReader.notifyUrl(videoUrl);
    await tester.pump(const Duration(milliseconds: 130));
    await waitForLibraryState(tester, find.textContaining('已播放 02:00'));

    expect(videoReader.resumeReads, [videoUrl]);
  });

  testWidgets('目标被移除且原分栏已满时才扫描一个补位候选', (tester) async {
    final older = item('补位影片.mkv', MediaLibraryKind.video);
    final target = item('移除影片.mkv', MediaLibraryKind.video);
    final olderFile = file(older.name);
    final targetFile = file(target.name);
    final olderUrl = 'https://example.test${olderFile.href}';
    final targetUrl = 'https://example.test${targetFile.href}';
    final videoReader = _CountingProgressReader()
      ..values[olderUrl] = _progress(olderUrl, 30000)
      ..values[targetUrl] = _progress(targetUrl, 60000);
    final audioReader = _CountingProgressReader();
    await tester.runAsync(() async {
      await store.recordPlayback(older, playbackSessionId: 'older-fill');
      await store.recordPlayback(target, playbackSessionId: 'target-fill');
    });

    await tester.pumpWidget(
      buildPage(
        config: const MediaLibraryConfig(maxContinuePerLane: 1),
        snapshots: [
          VisitedDirectorySnapshot(
            path: '媒体',
            entries: [targetFile, olderFile],
            lastAccessedAt: DateTime.utc(2026, 8, 23),
          ),
        ],
        videoProgressReader: videoReader,
        audioProgressReader: audioReader,
      ),
    );
    await settleLibraryPage(tester);
    await tester.tap(find.text('继续播放').first);
    await tester.pumpAndSettle();
    expect(find.text(target.name), findsOneWidget);
    videoReader.clearReads();
    audioReader.clearReads();

    videoReader.values[targetUrl] = null;
    videoReader.notifyUrl(targetUrl);
    await tester.pump(const Duration(milliseconds: 130));
    await waitForLibraryState(tester, find.text(older.name));

    expect(videoReader.resumeReads, [targetUrl, olderUrl]);
    expect(videoReader.progressReads, isEmpty);
    expect(audioReader.resumeReads, isEmpty);
    expect(audioReader.progressReads, isEmpty);
  });

  testWidgets('视频读取未完成时到达的音频通知不会取消视频更新', (tester) async {
    final video = item('并发影片.mkv', MediaLibraryKind.video);
    final audio = item('并发歌曲.flac', MediaLibraryKind.audio);
    final videoFile = file(video.name);
    final audioFile = file(audio.name);
    final videoUrl = 'https://example.test${videoFile.href}';
    final audioUrl = 'https://example.test${audioFile.href}';
    final videoReader = _CountingProgressReader()
      ..values[videoUrl] = _progress(videoUrl, 26000);
    final audioReader = _CountingProgressReader()
      ..values[audioUrl] = _progress(audioUrl, 30000);
    await tester.runAsync(() async {
      await store.recordPlayback(video, playbackSessionId: 'video-overlap');
      await store.recordPlayback(audio, playbackSessionId: 'audio-overlap');
    });
    await tester.pumpWidget(
      buildPage(
        snapshots: [
          VisitedDirectorySnapshot(
            path: '媒体',
            entries: [videoFile, audioFile],
            lastAccessedAt: DateTime.utc(2026, 8, 23),
          ),
        ],
        videoProgressReader: videoReader,
        audioProgressReader: audioReader,
      ),
    );
    await settleLibraryPage(tester);
    await tester.tap(find.text('继续播放').first);
    await tester.pumpAndSettle();
    videoReader.clearReads();
    audioReader.clearReads();

    final blockedVideoRead = videoReader.blockNextResume(videoUrl);
    videoReader.notifyUrl(videoUrl);
    await tester.pump(const Duration(milliseconds: 130));
    expect(videoReader.resumeReads, [videoUrl]);

    audioReader.values[audioUrl] = _progress(audioUrl, 120000);
    audioReader.notifyUrl(audioUrl);
    await tester.pump(const Duration(milliseconds: 130));
    expect(audioReader.progressReads, isEmpty);

    blockedVideoRead.complete(_progress(videoUrl, 120000));
    await waitForLibraryState(tester, find.textContaining('已播放 02:00'));
    expect(audioReader.progressReads, [audioUrl]);
    await tester.tap(find.text('音频').last);
    await tester.pumpAndSettle();
    expect(find.text(audio.name), findsOneWidget);
    expect(find.textContaining('已播放 02:00'), findsOneWidget);
  });

  testWidgets('播放会话切集时原位更新且不同会话保留独立记录', (tester) async {
    final first = item('会话第一集.mkv', MediaLibraryKind.video);
    final second = item('会话第二集.mkv', MediaLibraryKind.video);
    await tester.runAsync(
      () => store.recordPlayback(first, playbackSessionId: 'playlist-1'),
    );
    await tester.pumpWidget(buildPage());
    await settleLibraryPage(tester);
    await tester.tap(find.text('最近播放').first);
    await tester.pumpAndSettle();
    expect(find.text(first.name), findsOneWidget);

    await tester.runAsync(
      () => store.recordPlayback(second, playbackSessionId: 'playlist-1'),
    );
    await tester.pump(const Duration(milliseconds: 150));
    await settleLibraryPage(tester);
    expect(find.text(first.name), findsNothing);
    expect(find.text(second.name), findsOneWidget);

    await tester.runAsync(
      () => store.recordPlayback(second, playbackSessionId: 'playlist-2'),
    );
    await tester.pump(const Duration(milliseconds: 150));
    await settleLibraryPage(tester);
    expect(find.text(second.name), findsNWidgets(2));
  });

  testWidgets('继续播放遵守配置显示上限并忽略已手动清空的记录', (tester) async {
    final files = <WebDavFile>[];
    await tester.runAsync(() async {
      for (var index = 0; index < 3; index++) {
        final media = item('限额影片$index.mkv', MediaLibraryKind.video);
        final mediaFile = file(media.name);
        files.add(mediaFile);
        await store.recordPlayback(
          media,
          playbackSessionId: 'limit-session-$index',
        );
        await videoProgress.saveProgress(
          url: 'https://example.test${mediaFile.href}',
          positionMs: 30000,
          durationMs: 600000,
        );
      }
    });
    final snapshot = VisitedDirectorySnapshot(
      path: '媒体',
      entries: files,
      lastAccessedAt: DateTime.utc(2026, 8, 19),
    );

    await tester.pumpWidget(
      buildPage(
        snapshots: [snapshot],
        config: const MediaLibraryConfig(maxContinuePerLane: 2),
      ),
    );
    await settleLibraryPage(tester);
    await tester.tap(find.text('继续播放').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('限额影片'), findsNWidgets(2));

    await tester.runAsync(() => store.clearContinuePlayback(sourceId));
    await tester.pump(const Duration(milliseconds: 150));
    await waitForLibraryState(tester, find.text('没有可继续播放的视频'));
  });

  testWidgets('继续播放上限会跳过无进度的新记录并补充更早的有效记录', (tester) async {
    final older = item('较早有效影片.mkv', MediaLibraryKind.video);
    final newer = item('较新无进度影片.mkv', MediaLibraryKind.video);
    final olderFile = file(older.name);
    final newerFile = file(newer.name);
    await tester.runAsync(() async {
      await store.recordPlayback(older, playbackSessionId: 'older-session');
      await videoProgress.saveProgress(
        url: 'https://example.test${olderFile.href}',
        positionMs: 30000,
        durationMs: 600000,
      );
      await store.recordPlayback(newer, playbackSessionId: 'newer-session');
    });
    await tester.pumpWidget(
      buildPage(
        config: const MediaLibraryConfig(maxContinuePerLane: 1),
        snapshots: [
          VisitedDirectorySnapshot(
            path: '媒体',
            entries: [olderFile, newerFile],
            lastAccessedAt: DateTime.utc(2026, 8, 19),
          ),
        ],
      ),
    );
    await settleLibraryPage(tester);
    await tester.tap(find.text('继续播放').first);
    await tester.pumpAndSettle();
    expect(find.text(older.name), findsOneWidget);
    expect(find.text(newer.name), findsNothing);
  });
}

class _FakeDirectoryCache extends DirectoryCache {
  _FakeDirectoryCache(this.snapshots);

  final List<VisitedDirectorySnapshot> snapshots;

  @override
  List<VisitedDirectorySnapshot> visitedDirectories(String sourceId) =>
      snapshots;
}

PlaybackProgress _progress(String url, int positionMs) => PlaybackProgress(
  url: url,
  positionMs: positionMs,
  durationMs: 600000,
  updatedAt: DateTime.utc(2026, 8, 23),
);

class _CountingProgressReader implements PlaybackProgressReader {
  final Map<String, PlaybackProgress?> values = {};
  final List<String> progressReads = [];
  final List<String> resumeReads = [];
  final Map<String, Completer<PlaybackProgress?>> _resumeBlocks = {};
  final Set<void Function(PlaybackProgressChange)> _listeners = {};

  @override
  void addListener(void Function(PlaybackProgressChange) listener) {
    _listeners.add(listener);
  }

  @override
  void removeListener(void Function(PlaybackProgressChange) listener) {
    _listeners.remove(listener);
  }

  @override
  Future<PlaybackProgress?> getProgress(String url, {String? profileId}) async {
    progressReads.add(url);
    return values[url];
  }

  @override
  Future<PlaybackProgress?> getResumeProgress(
    String url, {
    String? profileId,
  }) async {
    resumeReads.add(url);
    final block = _resumeBlocks.remove(url);
    if (block != null) return block.future;
    return values[url];
  }

  Completer<PlaybackProgress?> blockNextResume(String url) {
    final completer = Completer<PlaybackProgress?>();
    _resumeBlocks[url] = completer;
    return completer;
  }

  void notifyUrl(String url) {
    final change = PlaybackProgressChange.url(url, profileId: 'source-a');
    for (final listener in List.of(_listeners)) {
      listener(change);
    }
  }

  void clearReads() {
    progressReads.clear();
    resumeReads.clear();
  }
}
