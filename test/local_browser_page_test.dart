import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/data/models/media_library_config.dart';
import 'package:streampath/data/models/server_profile.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/playback_history.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/presentation/pages/local_browser_page.dart';
import 'package:streampath/presentation/state/app_state.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  testWidgets('本地蓝光下边栏不依赖播放时间并可移除', (tester) async {
    final temporaryDirectory = Directory.systemTemp.createTempSync(
      'streampath_local_browser_',
    );
    final mediaDirectory = Directory(p.join(temporaryDirectory.path, 'Media'))
      ..createSync();
    final iso = File(p.join(mediaDirectory.path, 'disc.iso'))
      ..writeAsBytesSync([1, 2, 3]);
    File(p.join(mediaDirectory.path, 'sample.mp4')).writeAsBytesSync([4, 5, 6]);
    final isoStat = iso.statSync();
    final isoFingerprint = sha256
        .convert(
          utf8.encode(
            'disc.iso\n${isoStat.size}\n'
            '${isoStat.modified.millisecondsSinceEpoch}',
          ),
        )
        .toString();
    final root = LocalRootConfig(
      rootId: 'root-test',
      displayName: '本地影视',
      path: mediaDirectory.path,
    );
    final configStore = StreamPathConfigStore.forPath(
      p.join(temporaryDirectory.path, 'config.json'),
    );
    late MediaLibraryStore mediaLibraryStore;
    late PlaybackProgressService progress;
    late PlaybackHistoryStore playbackHistoryStore;
    await tester.runAsync(() async {
      await configStore.save(StreamPathConfig(localRoots: [root]));
      mediaLibraryStore = MediaLibraryStore.forPath(
        p.join(temporaryDirectory.path, 'media-library.json'),
      );
      await mediaLibraryStore.load();
      await mediaLibraryStore.recordPlayback(
        MediaLibraryItem(
          sourceId: root.sourceId,
          sourceKind: MediaSourceKind.local,
          playbackMode: PlaybackMode.localHdmvMenu,
          parentPath: '',
          name: 'disc.iso',
          kind: MediaLibraryKind.iso,
        ),
        playbackSessionId: 'local-disc-session',
        localDiscSession: LocalDiscSessionSnapshot(
          rootId: root.rootId,
          relativePath: 'disc.iso',
          size: 3,
          modified: isoStat.modified,
          fingerprint: isoFingerprint,
          currentEdition: 1,
          editionCount: 4,
        ),
      );
      progress = await PlaybackProgressService.open(
        inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      await progress.saveProgress(
        url: iso.path,
        positionMs: 125000,
        durationMs: 600000,
        profileId: root.sourceId,
      );
      playbackHistoryStore = PlaybackHistoryStore.forPath(
        p.join(temporaryDirectory.path, 'history.json'),
      );
      await playbackHistoryStore.upsert(
        PlaybackHistory(
          sessionId: 'local-video-session',
          dirCrumbs: const [],
          fileName: 'sample.mp4',
          videoIndex: 0,
          updatedAt: DateTime.now(),
          playlistFileNames: const ['sample.mp4'],
          sourceId: root.sourceId,
        ),
      );
    });
    final appState = AppState(
      configStore: configStore,
      playbackHistoryStore: playbackHistoryStore,
      progressService: progress,
      mediaLibraryStore: mediaLibraryStore,
    );
    final libraryProgress = await tester.runAsync(
      () => appState.localDiscPlaybackService.getLibraryProgress(
        profileId: root.sourceId,
        resolvedUrl: iso.path,
      ),
    );
    expect(libraryProgress?.episodeNumber, 2);
    expect(libraryProgress?.episodeCount, 4);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      appState.dispose();
      await tester.runAsync(() async {
        await progress.close();
        if (temporaryDirectory.existsSync()) {
          temporaryDirectory.deleteSync(recursive: true);
        }
      });
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: appState,
        child: MaterialApp(home: LocalBrowserPage(root: root)),
      ),
    );
    await tester.pump();
    for (var attempt = 0; attempt < 8; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }

    expect(find.text('继续播放本地蓝光：disc.iso'), findsOneWidget);
    expect(find.text('根目录 · Title 2/4'), findsOneWidget);
    expect(find.textContaining('已播放'), findsNothing);
    await tester.tap(
      find.descendant(
        of: find.byKey(
          const ValueKey<String>(
            'local-disc-playback-bar-session\u0000local:root-test\u0000iso\u0000local-disc-session',
          ),
        ),
        matching: find.byTooltip('继续播放'),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    final dialog = find.byType(AlertDialog);
    expect(
      find.descendant(of: dialog, matching: find.byType(OutlinedButton)),
      findsNWidgets(3),
    );
    expect(
      find.descendant(of: dialog, matching: find.byType(TextButton)),
      findsOneWidget,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('继续播放：sample.mp4'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey<String>(
          'local-disc-playback-bar-session\u0000local:root-test\u0000iso\u0000local-disc-session',
        ),
      ),
      findsOneWidget,
    );

    await tester.runAsync(
      () => progress.deleteProgress(iso.path, profileId: root.sourceId),
    );
    for (var attempt = 0; attempt < 8; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    expect(find.text('继续播放本地蓝光：disc.iso'), findsOneWidget);
    expect(find.text('根目录 · Title 2/4'), findsOneWidget);

    final discBar = find.byKey(
      const ValueKey<String>(
        'local-disc-playback-bar-session\u0000local:root-test\u0000iso\u0000local-disc-session',
      ),
    );
    await tester.runAsync(
      () => progress.saveProgress(
        url: iso.path,
        positionMs: 125000,
        durationMs: 600000,
        profileId: root.sourceId,
      ),
    );
    await tester.tap(
      find.descendant(of: discBar, matching: find.byTooltip('删除并关闭对应播放器')),
    );
    for (var attempt = 0; attempt < 12; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('继续播放本地蓝光：disc.iso'), findsNothing);
    final retained = await tester.runAsync(
      () => mediaLibraryStore.playbackHistory(
        root.sourceId,
        audio: false,
        iso: true,
      ),
    );
    expect(retained, hasLength(1));
    expect(retained!.single.continueDismissed, isFalse);
    expect(retained.single.playbackBarDismissed, isTrue);
    final reloaded = await tester.runAsync(
      () => MediaLibraryStore.forPath(
        p.join(temporaryDirectory.path, 'media-library.json'),
      ).playbackHistory(root.sourceId, audio: false, iso: true),
    );
    expect(reloaded!.single.playbackBarDismissed, isTrue);
    final keptProgress = await tester.runAsync(
      () => appState.localDiscPlaybackService.getLibraryProgress(
        profileId: root.sourceId,
        resolvedUrl: iso.path,
      ),
    );
    expect(keptProgress?.position, const Duration(seconds: 125));
  });

  for (final mode in MediaLibrarySharingMode.values) {
    testWidgets('本地底栏展示与跨挂载目录跳转 ${mode.name}', (tester) async {
      final temp = Directory.systemTemp.createTempSync('streampath_sharing_');
      final a = Directory(p.join(temp.path, 'a'))..createSync();
      final b = Directory(p.join(temp.path, 'b'))..createSync();
      Directory(p.join(b.path, 'Series')).createSync();
      File(p.join(b.path, 'Series', 'second.mp4')).writeAsBytesSync([1]);
      final rootA = LocalRootConfig(
        rootId: 'a',
        displayName: '挂载 A',
        path: a.path,
      );
      final rootB = LocalRootConfig(
        rootId: 'b',
        displayName: '挂载 B',
        path: b.path,
      );
      final config = StreamPathConfigStore.forPath(
        p.join(temp.path, 'config.json'),
      );
      late PlaybackHistoryStore history;
      late MediaLibraryStore library;
      late PlaybackProgressService progress;
      await tester.runAsync(() async {
        history = PlaybackHistoryStore.forPath(
          p.join(temp.path, 'history.json'),
        );
        library = MediaLibraryStore.forPath(p.join(temp.path, 'library.json'));
        await config.save(
          StreamPathConfig(
            localRoots: [rootA, rootB],
            profiles: const [
              ServerProfile(profileId: 'server-a', name: '网络 A'),
            ],
            mediaLibrary: MediaLibraryConfig(sharingMode: mode),
          ),
        );
        progress = await PlaybackProgressService.open(
          inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        for (final id in [rootA.sourceId, rootB.sourceId, 'server-a']) {
          await history.upsert(
            PlaybackHistory(
              sessionId: id,
              sourceId: id,
              dirCrumbs: const [],
              fileName: '$id.mp4',
              videoIndex: 0,
              updatedAt: DateTime.now(),
            ),
          );
        }
        await library.toggleFavorite(
          MediaLibraryItem(
            sourceId: rootB.sourceId,
            sourceKind: MediaSourceKind.local,
            parentPath: '',
            name: 'Series',
            kind: MediaLibraryKind.directory,
          ),
        );
      });
      final state = AppState(
        configStore: config,
        playbackHistoryStore: history,
        progressService: progress,
        mediaLibraryStore: library,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
        await tester.runAsync(() async {
          await progress.close();
          temp.deleteSync(recursive: true);
        });
      });
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(home: LocalBrowserPage(root: rootA)),
        ),
      );
      Future<void> settle() async {
        for (var i = 0; i < 8; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await settle();
      expect(find.text('继续播放：local:a.mp4'), findsOneWidget);
      expect(
        find.text('继续播放：local:b.mp4'),
        mode == MediaLibrarySharingMode.independent
            ? findsNothing
            : findsOneWidget,
      );
      expect(
        find.text('继续播放：server-a.mp4'),
        mode == MediaLibrarySharingMode.allShared
            ? findsOneWidget
            : findsNothing,
      );
      if (mode != MediaLibrarySharingMode.independent) {
        await tester.tap(find.byTooltip('媒体中心'));
        await settle();
        await tester.tap(find.text('目录').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Series'));
        await settle();
        for (
          var i = 0;
          i < 60 && find.text('second.mp4').evaluate().isEmpty;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(
          find.text('second.mp4'),
          findsOneWidget,
          reason: tester
              .widgetList<Text>(find.byType(Text))
              .map((text) => text.data)
              .join(' | '),
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('本地浏览复用 WebDAV 的可交互面包屑', (tester) async {
    final temporaryDirectory = Directory.systemTemp.createTempSync(
      'streampath_local_scroll_',
    );
    final mediaDirectory = Directory(p.join(temporaryDirectory.path, 'Media'))
      ..createSync();
    final seriesDirectory = Directory(p.join(mediaDirectory.path, 'Series'))
      ..createSync();
    File(p.join(seriesDirectory.path, 'episode-00.mp4')).writeAsBytesSync([0]);
    final root = LocalRootConfig(
      rootId: 'root-scroll',
      displayName: '本地影视',
      path: mediaDirectory.path,
    );
    final configStore = StreamPathConfigStore.forPath(
      p.join(temporaryDirectory.path, 'config.json'),
    );
    late PlaybackProgressService progress;
    await tester.runAsync(() async {
      await configStore.save(StreamPathConfig(localRoots: [root]));
      progress = await PlaybackProgressService.open(
        inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
    });
    final appState = AppState(
      configStore: configStore,
      playbackHistoryStore: PlaybackHistoryStore.forPath(
        p.join(temporaryDirectory.path, 'history.json'),
      ),
      progressService: progress,
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      appState.dispose();
      await tester.runAsync(() async {
        await progress.close();
        if (temporaryDirectory.existsSync()) {
          temporaryDirectory.deleteSync(recursive: true);
        }
      });
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: appState,
        child: MaterialApp(home: LocalBrowserPage(root: root)),
      ),
    );
    for (var attempt = 0; attempt < 8; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }

    expect(find.byKey(const Key('directory-root-breadcrumb')), findsOneWidget);
    await tester.tap(
      find
          .byKey(const ValueKey<String>('wide-file-tile-Series'))
          .hitTestable()
          .first,
    );
    for (var attempt = 0; attempt < 8; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      if (find
          .byKey(const ValueKey<String>('directory-breadcrumb-0'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }
    expect(
      find.byKey(const ValueKey<String>('directory-breadcrumb-0')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('directory-root-breadcrumb')));
    for (var attempt = 0; attempt < 12; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      if (find
              .byKey(const ValueKey<String>('directory-breadcrumb-0'))
              .evaluate()
              .isEmpty &&
          find.text('Series').evaluate().isNotEmpty) {
        break;
      }
    }
    expect(
      find.byKey(const ValueKey<String>('directory-breadcrumb-0')),
      findsNothing,
    );
    expect(find.text('Series'), findsWidgets);
  });

  testWidgets('嵌套BDMV从媒体中心继续播放直接恢复且不导航', (tester) async {
    final temporaryDirectory = Directory.systemTemp.createTempSync(
      'streampath_nested_bdmv_',
    );
    final mediaDirectory = Directory(p.join(temporaryDirectory.path, 'Media'))
      ..createSync();
    final seriesDirectory = Directory(
      p.join(mediaDirectory.path, '[BDMV] Series'),
    )..createSync();
    final discDirectory = Directory(p.join(seriesDirectory.path, 'DISC_01'))
      ..createSync();
    Directory(p.join(discDirectory.path, 'BDMV', 'PLAYLIST')).createSync(
      recursive: true,
    );
    Directory(p.join(discDirectory.path, 'BDMV', 'STREAM')).createSync(
      recursive: true,
    );
    final indexFile = File(p.join(discDirectory.path, 'BDMV', 'index.bdmv'))
      ..writeAsBytesSync([1, 2, 3, 4]);
    final indexStat = indexFile.statSync();
    final fingerprint = sha256
        .convert(
          utf8.encode(
            '[BDMV] Series/DISC_01\n${indexStat.size}\n'
            '${indexStat.modified.millisecondsSinceEpoch}',
          ),
        )
        .toString();
    final root = LocalRootConfig(
      rootId: 'root-nested',
      displayName: '本地影视',
      path: mediaDirectory.path,
    );
    final configStore = StreamPathConfigStore.forPath(
      p.join(temporaryDirectory.path, 'config.json'),
    );
    late MediaLibraryStore mediaLibraryStore;
    late PlaybackProgressService progress;
    await tester.runAsync(() async {
      await configStore.save(StreamPathConfig(localRoots: [root]));
      mediaLibraryStore = MediaLibraryStore.forPath(
        p.join(temporaryDirectory.path, 'library.json'),
      );
      await mediaLibraryStore.load();
      await mediaLibraryStore.recordPlayback(
        MediaLibraryItem(
          sourceId: root.sourceId,
          sourceKind: MediaSourceKind.local,
          playbackMode: PlaybackMode.localHdmvMenu,
          parentPath: '[BDMV] Series',
          name: 'DISC_01',
          kind: MediaLibraryKind.iso,
        ),
        playbackSessionId: 'nested-disc-session',
        localDiscSession: LocalDiscSessionSnapshot(
          rootId: root.rootId,
          relativePath: '[BDMV] Series/DISC_01',
          size: indexStat.size,
          modified: indexStat.modified,
          fingerprint: fingerprint,
          currentEdition: 1,
          editionCount: 4,
        ),
      );
      progress = await PlaybackProgressService.open(
        inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      await progress.saveProgress(
        url: p.join(mediaDirectory.path, '[BDMV] Series', 'DISC_01'),
        positionMs: 125000,
        durationMs: 600000,
        profileId: root.sourceId,
      );
    });
    final appState = AppState(
      configStore: configStore,
      playbackHistoryStore: PlaybackHistoryStore.forPath(
        p.join(temporaryDirectory.path, 'history.json'),
      ),
      progressService: progress,
      mediaLibraryStore: mediaLibraryStore,
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      appState.dispose();
      await tester.runAsync(() async {
        await progress.close();
        if (temporaryDirectory.existsSync()) {
          temporaryDirectory.deleteSync(recursive: true);
        }
      });
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: appState,
        child: MaterialApp(home: LocalBrowserPage(root: root)),
      ),
    );
    Future<void> settle() async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await settle();
    expect(find.textContaining('继续播放本地蓝光：DISC_01'), findsOneWidget);

    await tester.tap(find.byTooltip('媒体中心'));
    await settle();
    await tester.tap(find.text('继续播放').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('ISO').last);
    await settle();
    expect(find.textContaining('第 2/4 集'), findsOneWidget);

    await tester.tap(find.text('DISC_01'));
    // 播放方式选择弹窗依赖媒体中心出栈与本地路径校验，轮询等待其出现。
    for (
      var i = 0;
      i < 24 && find.byType(AlertDialog).evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await settle();
    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(find.textContaining('可继续上次播放的 Title'), findsOneWidget);
    expect(
      find.descendant(of: dialog, matching: find.byType(OutlinedButton)),
      findsNWidgets(3),
    );
    expect(find.text('本地媒体已移动、删除或来源不可用'), findsNothing);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    // 未发生目录导航：仍停留在本地根目录，未进入父目录 [BDMV] Series。
    expect(find.text('[BDMV] Series'), findsOneWidget);
    expect(find.text('DISC_01'), findsNothing);
  });
}
