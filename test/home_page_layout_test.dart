import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/connection_config.dart';
import 'package:streampath/data/models/server_profile.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/presentation/pages/home_page.dart';
import 'package:streampath/presentation/pages/settings_page.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/theme/glass_tokens.dart';
import 'package:streampath/presentation/widgets/glass_surface.dart';
import 'package:streampath/presentation/widgets/window_title_bar.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    HttpOverrides.global = null;
  });

  setUp(SettingsPageMemory.reset);

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

  testWidgets('默认窗口尺寸下登录卡片完整居中且保留下边距', (tester) async {
    const windowSize = Size(1280, 720);
    tester.view.physicalSize = windowSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final tempDir = Directory.systemTemp.createTempSync('home_default_window_');
    final configStore = StreamPathConfigStore.forPath(
      '${tempDir.path}${Platform.pathSeparator}stream_path_config.json',
    );
    const profile = ServerProfile(
      profileId: 'profile-default',
      name: '默认服务器',
      serverUrl: 'https://example.com/dav',
      username: 'saved-user',
      password: 'secret',
    );
    late PlaybackProgressService progress;
    await tester.runAsync(() async {
      await configStore.save(
        StreamPathConfig.defaults().upsertProfile(profile),
      );
      progress = await PlaybackProgressService.open(
        inMemoryDatabasePath,
        factory: databaseFactoryFfi,
        legacyProfileId: profile.profileId,
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
        child: MaterialApp(
          theme: AppTheme.dark(),
          builder: (context, navigator) => Column(
            children: [
              const SizedBox(height: WindowTitleBar.height),
              Expanded(child: navigator ?? const SizedBox.shrink()),
            ],
          ),
          home: const HomePage(),
        ),
      ),
    );
    await tester.pump();

    final cardRect = tester.getRect(find.byType(GlassSurface));
    final bodyTop =
        WindowTitleBar.height + AppTheme.dark().appBarTheme.toolbarHeight!;
    final expectedCenterY = (bodyTop + windowSize.height) / 2;
    expect(cardRect.center.dy, closeTo(expectedCenterY, 0.5));
    expect(cardRect.bottom, lessThanOrEqualTo(windowSize.height - 4));
    final verticalScrollable = find.byWidgetPredicate(
      (widget) =>
          widget is Scrollable && widget.axisDirection == AxisDirection.down,
    );
    expect(verticalScrollable, findsOneWidget);
    expect(
      tester
          .state<ScrollableState>(verticalScrollable)
          .position
          .maxScrollExtent,
      0,
    );
  });

  testWidgets('磨砂登录卡片使用无阴影的扁平内容层', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(glass: true),
        home: const HomePage(
          initialConnection: ConnectionConfig(
            baseUrl: 'https://example.com/dav',
            username: 'saved-user',
          ),
        ),
      ),
    );

    final surface = tester.widget<GlassSurface>(find.byType(GlassSurface));
    expect(surface.level, GlassSurfaceLevel.content);
    expect(surface.showShadow, isFalse);
    expect(surface.border, isNotNull);
  });

  testWidgets('登录页选择服务器档案后同步候选信息与设置页当前档案', (tester) async {
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
    expect(SettingsPageMemory.selectedProfileId, second.profileId);
    expect(configStore.current.profileId, first.profileId);

    await tester.tap(find.text('新建档案'));
    await tester.pump();
    expect(SettingsPageMemory.selectedProfileId, isNull);
    expect(configStore.current.profileId, first.profileId);
    expect(tester.takeException(), isNull);
  });

  testWidgets('设置页档案认证成功后登录页同步活动档案', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'home_profile_activation_',
    );
    late HttpServer server;
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.multiStatus
          ..headers.set(HttpHeaders.connectionHeader, 'close')
          ..headers.contentType = ContentType(
            'application',
            'xml',
            charset: 'utf-8',
          )
          ..write('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"/>');
        await request.response.close();
      });
    });
    final configStore = StreamPathConfigStore.forPath(
      '${tempDir.path}${Platform.pathSeparator}stream_path_config.json',
    );
    const first = ServerProfile(
      profileId: 'profile-a',
      name: '默认档案',
      serverUrl: 'https://a.example/dav',
      username: 'alice',
    );
    final second = ServerProfile(
      profileId: 'profile-b',
      name: '其他档案',
      serverUrl: 'http://${server.address.address}:${server.port}/dav',
      username: 'bob',
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
      await progress.close();
      await server.close(force: true);
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: appState,
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => appState.connectAndActivateProfile(
        profile: second,
        config: configStore.current,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(configStore.current.profileId, 'profile-b');
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const Key('server-profile-selector')),
          )
          .initialValue,
      'profile-b',
    );
    expect(
      tester
          .widgetList<TextFormField>(find.byType(TextFormField))
          .map((field) => field.controller!.text),
      ['其他档案', second.serverUrl, 'bob', ''],
    );
  });

  testWidgets('设置页档案认证失败后登录页保持原活动档案', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'home_profile_activation_failure_',
    );
    late HttpServer server;
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..headers.set(HttpHeaders.connectionHeader, 'close');
        await request.response.close();
      });
    });
    final configStore = StreamPathConfigStore.forPath(
      '${tempDir.path}${Platform.pathSeparator}stream_path_config.json',
    );
    const first = ServerProfile(
      profileId: 'profile-a',
      name: '默认档案',
      serverUrl: 'https://a.example/dav',
      username: 'alice',
    );
    final second = ServerProfile(
      profileId: 'profile-b',
      name: '其他档案',
      serverUrl: 'http://${server.address.address}:${server.port}/dav',
      username: 'bob',
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
      await progress.close();
      await server.close(force: true);
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: appState,
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      await expectLater(
        appState.connectAndActivateProfile(
          profile: second,
          config: configStore.current,
        ),
        throwsA(isA<NetworkException>()),
      );
    });
    await tester.pump();

    expect(configStore.current.profileId, 'profile-a');
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const Key('server-profile-selector')),
          )
          .initialValue,
      'profile-a',
    );
    expect(
      tester
          .widgetList<TextFormField>(find.byType(TextFormField))
          .map((field) => field.controller!.text),
      ['默认档案', first.serverUrl, 'alice', ''],
    );
  });
}
