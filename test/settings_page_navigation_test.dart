import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/features/cache_control/store/cache_intelligence_config_store.dart';
import 'package:streampath/features/cache_control/store/cache_policy_config_store.dart';
import 'package:streampath/presentation/pages/settings_page.dart';
import 'package:streampath/presentation/state/app_state.dart';

void main() {
  late Directory tempDir;
  late AppState appState;

  setUp(() async {
    SettingsPageMemory.reset();
    tempDir = Directory.systemTemp.createTempSync('settings_page_navigation_');
    final configStore = StreamPathConfigStore.forPath(
      '${tempDir.path}${Platform.pathSeparator}stream_path_config.json',
    );
    await configStore.save(StreamPathConfig.defaults());
    final progressService = await PlaybackProgressService.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    appState = AppState(
      configStore: configStore,
      playbackHistoryStore: PlaybackHistoryStore.forPath(
        '${tempDir.path}${Platform.pathSeparator}playback_history.json',
      ),
      progressService: progressService,
      cachePolicyConfigStore: CachePolicyConfigStore.forPath(
        '${tempDir.path}${Platform.pathSeparator}cache_policy.json',
      ),
      cacheIntelligenceConfigStore: CacheIntelligenceConfigStore.forPath(
        '${tempDir.path}${Platform.pathSeparator}cache_intelligence.json',
      ),
    );
  });

  tearDown(() {
    appState.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Widget buildSettings() {
    return ChangeNotifierProvider<AppState>.value(
      value: appState,
      child: const MaterialApp(home: SettingsPage()),
    );
  }

  testWidgets('顶部分类切换后在进程内记住上次页面', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildSettings());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings-section-server')), findsOneWidget);
    expect(find.byKey(const Key('settings-section-playback')), findsOneWidget);
    expect(find.byKey(const Key('settings-section-cache')), findsOneWidget);
    expect(find.byKey(const Key('settings-section-general')), findsOneWidget);
    expect(find.byKey(const Key('server-url-field')), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-section-cache')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('cache-enabled-switch')), findsOneWidget);
    expect(SettingsPageMemory.selectedSection, SettingsSection.cache);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();
    await tester.pumpWidget(buildSettings());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('cache-enabled-switch')), findsOneWidget);
    expect(find.byKey(const Key('server-url-field')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
