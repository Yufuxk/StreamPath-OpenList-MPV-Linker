import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_library_config.dart';
import 'package:streampath/data/models/playback_history.dart';
import 'package:streampath/data/models/server_profile.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/widgets/mounted_playback_bars.dart';
import 'package:streampath/presentation/widgets/playback_bar.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  testWidgets('外层续播栏只显示对应挂载类型的会话', (tester) async {
    final temporary = Directory.systemTemp.createTempSync('mounted_bars_');
    final configStore = StreamPathConfigStore.forPath(
      '${temporary.path}${Platform.pathSeparator}config.json',
    );
    late PlaybackHistoryStore historyStore;
    late PlaybackProgressService progress;
    await tester.runAsync(() async {
      historyStore = PlaybackHistoryStore.forPath(
        '${temporary.path}${Platform.pathSeparator}history.json',
      );
      await configStore.save(
        StreamPathConfig(
          profiles: const [ServerProfile(profileId: 'server-a', name: '网络 A')],
          mountedProfileIds: const ['server-a'],
          localRoots: [
            LocalRootConfig(
              rootId: 'root-a',
              displayName: '本地 A',
              path: temporary.path,
            ),
          ],
          mediaLibrary: const MediaLibraryConfig(),
        ),
      );
      final records = [
        PlaybackHistory(
          sessionId: 'remote-session',
          sourceId: 'server-a',
          dirCrumbs: const ['电影'],
          fileName: '远端电影.mkv',
          videoIndex: 0,
          updatedAt: DateTime.now(),
        ),
        PlaybackHistory(
          sessionId: 'local-session',
          sourceId: 'local:root-a',
          dirCrumbs: const ['动画'],
          fileName: '本地动画.mkv',
          videoIndex: 0,
          updatedAt: DateTime.now(),
        ),
      ];
      await File(
        '${temporary.path}${Platform.pathSeparator}history.json',
      ).writeAsString(
        jsonEncode({
          'version': 2,
          'sessions': records.map((item) => item.toJson()).toList(),
        }),
      );
      await historyStore.loadAll();
      expect(historyStore.sessions, hasLength(2));
      progress = await PlaybackProgressService.open(
        inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
    });
    final appState = AppState(
      configStore: configStore,
      playbackHistoryStore: historyStore,
      progressService: progress,
    );
    expect(appState.configStore.current.mountedProfileIds, ['server-a']);
    expect(
      appState.configStore.current.mediaLibrary.sharingMode,
      MediaLibrarySharingMode.networkAndLocalShared,
    );
    addTearDown(() async {
      appState.dispose();
      await tester.runAsync(() async {
        await progress.close();
        if (temporary.existsSync()) temporary.deleteSync(recursive: true);
      });
    });

    Future<void> pumpBars(bool network) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: appState,
          child: MaterialApp(
            home: Scaffold(
              bottomNavigationBar: MountedPlaybackBars(
                key: ValueKey(network),
                network: network,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
    }

    await pumpBars(true);
    expect(find.byType(PlaybackBar), findsOneWidget);
    expect(find.byTooltip('跳过本季'), findsOneWidget);
    expect(find.textContaining('远端电影.mkv'), findsOneWidget);
    expect(find.textContaining('本地动画.mkv'), findsNothing);
    await tester.tap(find.byTooltip('跳过本季'));
    await tester.pumpAndSettle();
    expect(find.text('跳过本季？'), findsOneWidget);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    await pumpBars(false);
    expect(find.byTooltip('跳过本季'), findsOneWidget);
    expect(find.textContaining('远端电影.mkv'), findsNothing);
    expect(find.textContaining('本地动画.mkv'), findsOneWidget);
  });
}
