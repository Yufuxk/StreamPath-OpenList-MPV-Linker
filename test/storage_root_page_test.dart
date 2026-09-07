import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/presentation/pages/storage_root_page.dart';
import 'package:streampath/presentation/state/app_state.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  testWidgets('最外层只显示网络存储和本地存储两个入口', (tester) async {
    final temporaryDirectory = Directory.systemTemp.createTempSync(
      'streampath_storage_root_',
    );
    final mediaDirectory = Directory(p.join(temporaryDirectory.path, 'Media'))
      ..createSync();
    final configStore = StreamPathConfigStore.forPath(
      p.join(temporaryDirectory.path, 'config.json'),
    );
    late PlaybackProgressService progress;
    await tester.runAsync(() async {
      await configStore.save(
        StreamPathConfig(
          localRoots: [
            LocalRootConfig(
              rootId: 'root-test',
              displayName: '本地影视',
              path: mediaDirectory.path,
            ),
          ],
        ),
      );
      progress = await PlaybackProgressService.open(
        inMemoryDatabasePath,
        factory: databaseFactoryFfi,
        legacyProfileId: 'legacy',
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
        child: const MaterialApp(home: StorageRootPage()),
      ),
    );

    expect(find.byKey(const Key('network-storage-folder')), findsOneWidget);
    expect(find.byKey(const Key('local-storage-folder')), findsOneWidget);
    expect(find.text('网络存储'), findsOneWidget);
    expect(find.text('本地存储'), findsOneWidget);
    expect(find.text('已挂载 1 个本地文件夹'), findsOneWidget);

    await tester.tap(find.byKey(const Key('local-storage-folder')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('本地影视'), findsOneWidget);
    expect(find.byKey(const Key('add-local-root-button')), findsOneWidget);
  });
}
