import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/connection_config.dart';
import 'package:streampath/data/models/server_profile.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/presentation/pages/home_page.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/theme/app_theme.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  testWidgets('返回登录页时首帧直接显示已保存配置且标签位置稳定', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: HomePage(
          initialConnection: ConnectionConfig(
            baseUrl: 'https://example.com/dav',
            username: 'saved-user',
          ),
        ),
      ),
    );

    final fields = tester
        .widgetList<TextFormField>(find.byType(TextFormField))
        .toList(growable: false);
    expect(fields, hasLength(4));
    expect(fields.map((field) => field.controller!.text), [
      '默认服务器',
      'https://example.com/dav',
      'saved-user',
      '',
    ]);
    expect(find.byIcon(Icons.route_outlined), findsNothing);
    expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

    final labelFinders = [
      find.text('服务器地址'),
      find.text('用户名'),
      find.text('密码'),
      find.text('档案名称'),
    ];
    final initialLabelPositions = labelFinders
        .map(tester.getTopLeft)
        .toList(growable: false);

    await tester.pump(const Duration(milliseconds: 50));

    for (var index = 0; index < labelFinders.length; index++) {
      expect(
        tester.getTopLeft(labelFinders[index]),
        initialLabelPositions[index],
        reason: '已填入文本的标签不应在登录页出现后继续从输入框内向上移动',
      );
    }
  });

  testWidgets('登录页在宽窄窗口下均保持可用布局', (tester) async {
    Future<void> pumpAt(Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const HomePage(
            initialConnection: ConnectionConfig(
              baseUrl: 'https://example.com/dav',
              username: 'saved-user',
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('直接浏览，顺畅播放'), findsNothing);
      expect(find.text('连接服务器'), findsOneWidget);
      expect(find.byType(TextFormField), findsNWidgets(4));
      expect(tester.takeException(), isNull);
    }

    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpAt(const Size(1200, 800));
    await pumpAt(const Size(520, 720));
  });

  testWidgets('登录页选择服务器档案后同步切换候选连接信息', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync('home_profiles_');
    final configStore = StreamPathConfigStore.forPath(
      '${tempDir.path}${Platform.pathSeparator}stream_path_config.json',
    );
    const first = ServerProfile(
      profileId: 'profile-a',
      name: '主服务器',
      serverUrl: 'https://a.example/dav',
      username: 'alice',
      password: 'secret-a',
    );
    const second = ServerProfile(
      profileId: 'profile-b',
      name: '备用服务器',
      serverUrl: 'https://b.example/dav',
      username: 'bob',
      password: 'secret-b',
    );
    late PlaybackProgressService progress;
    await tester.runAsync(() async {
      await configStore.save(
        StreamPathConfig.defaults()
            .upsertProfile(first)
            .upsertProfile(second, activate: false),
      );
      progress = await PlaybackProgressService.open(
        inMemoryDatabasePath,
        factory: databaseFactoryFfi,
        legacyProfileId: first.profileId,
      );
    });
    final appState = AppState(
      configStore: configStore,
      playbackHistoryStore: PlaybackHistoryStore.forPath(
        '${tempDir.path}${Platform.pathSeparator}playback_history.json',
      ),
      progressService: progress,
    );
    addTearDown(() async {
      appState.dispose();
      await tester.runAsync(() async {
        await progress.close().timeout(const Duration(seconds: 2));
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: appState,
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pump();

    tester
        .widget<DropdownButtonFormField<String>>(
          find.byKey(const Key('server-profile-selector')),
        )
        .onChanged!('profile-b');
    await tester.pump();

    final fields = tester
        .widgetList<TextFormField>(find.byType(TextFormField))
        .map((field) => field.controller!.text)
        .toList(growable: false);
    expect(fields, ['备用服务器', 'https://b.example/dav', 'bob', 'secret-b']);
    expect(configStore.current.profileId, first.profileId);
    expect(tester.takeException(), isNull);
  });
}
