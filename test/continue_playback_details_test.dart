import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/core/constants.dart';
import 'package:streampath/data/local/directory_cache.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/data/models/audio_playback_history.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/data/models/playback_history.dart';
import 'package:streampath/data/models/server_profile.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/widgets/continue_playback_subtitle.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('四语言按集或曲目显示数量，零秒和单项隐藏对应字段', () {
    const path = '中文目录 / Original Title';
    for (final language in AppLanguage.values) {
      final l10n = AppLocalizations(language);
      final expectedVideo = switch (language) {
        AppLanguage.english => 'Episode 2/12',
        AppLanguage.japanese => '第 2/12 話',
        _ => '第 2/12 集',
      };
      final expectedAudio = switch (language) {
        AppLanguage.english => 'Track 2/12',
        AppLanguage.japanese => '第 2/12 曲',
        _ => '第 2/12 首',
      };
      expect(
        l10n.playbackDetails(
          path,
          positionMs: 0,
          episodeNumber: 1,
          episodeCount: 1,
        ),
        path,
      );
      expect(l10n.playbackDetails(path, positionMs: 999), path);
      expect(
        l10n.playbackDetails(
          path,
          positionMs: 0,
          episodeNumber: 2,
          episodeCount: 12,
        ),
        '$path  ·  $expectedVideo',
      );
      expect(
        l10n.playbackDetails(
          path,
          positionMs: 123000,
          episodeNumber: 2,
          episodeCount: 12,
        ),
        contains('$expectedVideo  ·  '),
      );
      expect(
        l10n.playbackDetails(
          path,
          positionMs: 123000,
          episodeNumber: 2,
          episodeCount: 12,
          audio: true,
        ),
        contains('$expectedAudio  ·  '),
      );
      expect(
        l10n.playbackDetails(
          path,
          positionMs: 3661000,
          episodeNumber: 1,
          episodeCount: 1,
        ),
        endsWith('1:01:01'),
      );
      expect(
        l10n.playbackDetails('', positionMs: 1000),
        isNot(startsWith('  ·  ')),
      );
    }
  });

  for (final local in [false, true]) {
    testWidgets('${local ? '本地' : 'WebDAV'}全部已支持音视频后缀读取独立进度并响应切项及零秒', (
      tester,
    ) async {
      final temp = Directory.systemTemp.createTempSync('continue_details_');
      final config = StreamPathConfigStore.forPath('${temp.path}/config.json');
      late PlaybackProgressService video;
      late PlaybackProgressService audio;
      await tester.runAsync(() async {
        await config.save(
          StreamPathConfig(
            profiles: const [
              ServerProfile(
                profileId: 'server',
                name: 'Server',
                serverUrl: 'https://example.test/dav',
              ),
            ],
            localRoots: [
              LocalRootConfig(
                rootId: 'root',
                displayName: 'Root',
                path: temp.path,
              ),
            ],
          ),
        );
        video = await PlaybackProgressService.open(
            '${temp.path}/video.db',
          factory: databaseFactoryFfi,
        );
        audio = await PlaybackProgressService.open(
            '${temp.path}/audio.db',
          factory: databaseFactoryFfi,
        );
      });
      final cache = _DetailsDirectoryCache();
      final app = AppState(
        configStore: config,
        playbackHistoryStore: PlaybackHistoryStore.forPath(
          '${temp.path}/history.json',
        ),
        progressService: video,
        audioProgressService: audio,
        directoryCache: cache,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await tester.runAsync(() async {
          await video.close();
          await audio.close();
          await temp.delete(recursive: true);
        });
      });
      final sourceId = local ? 'local:root' : 'server';
      final extensions = <(String, bool)>[
        for (final extension in AppConstants.videoExtensions)
          (extension, false),
        for (final extension in AppConstants.audioExtensions) (extension, true),
      ];
      for (final (extension, isAudio) in extensions) {
        final name = '媒体$extension';
        cache.files = [
          WebDavFile(
            name: name,
            href: '/dav/media/${Uri.encodeComponent(name)}',
            isDirectory: false,
          ),
        ];
        final url = local
            ? '${temp.path}${Platform.pathSeparator}media${Platform.pathSeparator}$name'
            : 'https://example.test/dav/media/${Uri.encodeComponent(name)}';
        await tester.runAsync(() async {
          await video.saveProgress(
            url: url,
            positionMs: 26000,
            profileId: sourceId,
          );
          await audio.saveProgress(
            url: url,
            positionMs: 123000,
            profileId: sourceId,
          );
          await video.saveProgress(
            url: url,
            positionMs: 90000,
            profileId: 'other-source',
          );
        });
        final subtitle = isAudio
            ? ContinuePlaybackSubtitle.audio(
                label: 'media',
                history: AudioPlaybackHistory(
                  sessionId: 'audio',
                  sourceId: sourceId,
                  dirCrumbs: const ['media'],
                  fileName: name,
                  trackIndex: 1,
                  playlistFileNames: ['first$extension', name],
                  updatedAt: DateTime.now(),
                ),
              )
            : ContinuePlaybackSubtitle.video(
                label: 'media',
                history: PlaybackHistory(
                  sessionId: 'video',
                  sourceId: sourceId,
                  dirCrumbs: const ['media'],
                  fileName: name,
                  videoIndex: 1,
                  playlistFileNames: ['first$extension', name],
                  updatedAt: DateTime.now(),
                ),
              );
        await tester.pumpWidget(
          ChangeNotifierProvider<AppState>.value(
            value: app,
            child: MaterialApp(home: Scaffold(body: subtitle)),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        expect(
          find.text(
            isAudio
                ? 'media  ·  第 2/2 首  ·  已播放 02:03'
                : 'media  ·  第 2/2 集  ·  已播放 00:26',
          ),
          findsOneWidget,
          reason:
              '$extension: ${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).toList()}',
        );
        await tester.runAsync(
          () => (isAudio ? audio : video).saveProgress(
            url: url,
            positionMs: 0,
            profileId: sourceId,
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        expect(
          find.text(isAudio ? 'media  ·  第 2/2 首' : 'media  ·  第 2/2 集'),
          findsOneWidget,
          reason: extension,
        );
      }
    });
  }

  testWidgets('STRM 底栏使用无地址快照，更新后即时显示并隐藏零秒', (tester) async {
    final temp = Directory.systemTemp.createTempSync('strm_details_');
    final library = MediaLibraryStore.forPath('${temp.path}/library.json');
    final config = StreamPathConfigStore.forPath('${temp.path}/config.json');
    late PlaybackProgressService progress;
    await tester.runAsync(() async {
      await library.recordPlayback(
        const MediaLibraryItem(
          sourceId: 'server',
          parentPath: 'media',
          name: 'second.strm',
          kind: MediaLibraryKind.strm,
        ),
        playbackSessionId: 'strm',
        playlistIndex: 1,
        playlistCount: 3,
      );
      progress = await PlaybackProgressService.open(
        inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
    });
    final app = AppState(
      configStore: config,
      playbackHistoryStore: PlaybackHistoryStore.forPath(
        '${temp.path}/history.json',
      ),
      progressService: progress,
      mediaLibraryStore: library,
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await tester.runAsync(() async {
        await progress.close();
        await temp.delete(recursive: true);
      });
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          home: Scaffold(
            body: ContinuePlaybackSubtitle.video(
              label: 'media',
              history: PlaybackHistory(
                sessionId: 'strm',
                sourceId: 'server',
                dirCrumbs: const ['media'],
                fileName: 'second.strm',
                videoIndex: 1,
                playlistFileNames: const [
                  'first.strm',
                  'second.strm',
                  'third.strm',
                ],
                updatedAt: DateTime.now(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(find.text('media  ·  第 2/3 集'), findsOneWidget);
    await tester.runAsync(
      () => library.updateStrmProgress(
        sourceId: 'server',
        playbackSessionId: 'strm',
        fileName: 'second.strm',
        playlistIndex: 1,
        positionMs: 123000,
      ),
    );
    await tester.pump();
    expect(find.text('media  ·  第 2/3 集  ·  已播放 02:03'), findsOneWidget);
    await tester.runAsync(
      () => library.updateStrmProgress(
        sourceId: 'server',
        playbackSessionId: 'strm',
        fileName: 'second.strm',
        playlistIndex: 1,
        positionMs: 0,
      ),
    );
    await tester.pump();
    expect(find.text('media  ·  第 2/3 集'), findsOneWidget);
  });
}

class _DetailsDirectoryCache extends DirectoryCache {
  List<WebDavFile> files = [];

  @override
  List<VisitedDirectorySnapshot> visitedDirectories(String sourceId) => [
    VisitedDirectorySnapshot(
      path: 'media',
      entries: files,
      lastAccessedAt: DateTime.now(),
    ),
  ];
}
