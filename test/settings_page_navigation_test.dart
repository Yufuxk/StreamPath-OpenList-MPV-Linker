import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/appearance_config.dart';
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/data/models/media_library_config.dart';
import 'package:streampath/data/models/openlist_recovery_config.dart';
import 'package:streampath/data/models/server_profile.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/domain/services/cache_cleanup_service.dart';
import 'package:streampath/domain/services/openlist_index_service.dart';
import 'package:streampath/domain/services/openlist_recovery_service.dart';
import 'package:streampath/features/cache_control/models/cache_intelligence_config.dart';
import 'package:streampath/features/cache_control/models/cache_policy_config.dart';
import 'package:streampath/features/cache_control/store/cache_intelligence_config_store.dart';
import 'package:streampath/features/cache_control/store/cache_policy_config_store.dart';
import 'package:streampath/features/cache_expiration/models/cache_expiration_config.dart';
import 'package:streampath/features/cache_expiration/store/cache_expiration_config_store.dart';
import 'package:streampath/presentation/pages/settings_page.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/theme/appearance_controller.dart';
import 'package:streampath/presentation/theme/glass_tokens.dart';
import 'package:streampath/presentation/widgets/directory_wheel_scroll_region.dart';
import 'package:streampath/presentation/widgets/glass_surface.dart';

void main() {
  late Directory tempDir;
  late AppState appState;
  late StreamPathConfigStore configStore;
  late AppearanceController appearanceController;
  late _RecordingWindowAppearanceDriver appearanceDriver;
  late _RecordingCacheCleaner cacheCleaner;
  late _RecordingCacheCleaner learningDataCleaner;
  late CachePolicyConfigStore cachePolicyStore;
  late CacheIntelligenceConfigStore intelligenceStore;
  late CacheExpirationConfigStore expirationStore;

  setUpAll(() => HttpOverrides.global = null);

  setUp(() async {
    SettingsPageMemory.reset();
    tempDir = Directory.systemTemp.createTempSync('settings_page_navigation_');
    configStore = StreamPathConfigStore.forPath(
      '${tempDir.path}${Platform.pathSeparator}stream_path_config.json',
    );
    await configStore.save(StreamPathConfig.defaults());
    appearanceDriver = _RecordingWindowAppearanceDriver();
    appearanceController = AppearanceController(
      initialConfig: configStore.current.appearance,
      driver: appearanceDriver,
    );
    cacheCleaner = _RecordingCacheCleaner();
    learningDataCleaner = _RecordingCacheCleaner();
    cachePolicyStore = CachePolicyConfigStore.forPath(
      '${tempDir.path}${Platform.pathSeparator}cache_policy.json',
    );
    intelligenceStore = CacheIntelligenceConfigStore.forPath(
      '${tempDir.path}${Platform.pathSeparator}cache_intelligence.json',
    );
    expirationStore = CacheExpirationConfigStore.forPath(
      '${tempDir.path}${Platform.pathSeparator}cache_expiration.json',
    );
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
      cachePolicyConfigStore: cachePolicyStore,
      cacheIntelligenceConfigStore: intelligenceStore,
      cacheExpirationConfigStore: expirationStore,
      cacheCleaner: cacheCleaner,
      learningDataCleaner: learningDataCleaner,
    );
  });

  tearDown(() async {
    appearanceController.dispose();
    appState.dispose();
    for (var attempt = 0; attempt < 10 && tempDir.existsSync(); attempt++) {
      try {
        await tempDir.delete(recursive: true);
      } on FileSystemException {
        if (attempt == 9) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  });

  Widget buildSettings({
    ValueChanged<SettingsSection>? onSectionBuilt,
    AppLanguage language = AppLanguage.simplifiedChinese,
    ThemeData? theme,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: appState),
        ChangeNotifierProvider<AppearanceController>.value(
          value: appearanceController,
        ),
      ],
      child: MaterialApp(
        theme: theme,
        locale: language.locale,
        supportedLocales: AppLanguage.values
            .map((candidate) => candidate.locale)
            .toList(),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: SettingsPage(onSectionBuilt: onSectionBuilt),
      ),
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
    expect(
      find.byKey(const Key('settings-section-mediaLibrary')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('settings-section-cache')), findsOneWidget);
    expect(
      find.byKey(const Key('settings-section-appearance')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('settings-section-diagnostics')),
      findsOneWidget,
    );
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

  testWidgets('菜单进度默认独立，可保存共享并切回独立', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildSettings());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-section-playback')));
    await tester.pumpAndSettle();
    expect(configStore.current.menuProgressSharingEnabled, isFalse);
    for (final sharing in [true, false]) {
      final field = find.byKey(const Key('menu-progress-sharing'));
      await tester.ensureVisible(field);
      await tester.tap(field);
      await tester.pumpAndSettle();
      await tester.tap(find.text(sharing ? '共享（供标题模式续播）' : '独立（不记录进度）').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-settings-button')));
      for (var i = 0; i < 30 && configStore.current.menuProgressSharingEnabled != sharing; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 30));
        if (tester.widget<FilledButton>(find.byKey(const Key('save-settings-button'))).onPressed != null) break;
      }
      final saved = await tester.runAsync(configStore.load);
      expect(saved!.menuProgressSharingEnabled, sharing);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('媒体中心共享模式可选择并保存', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildSettings());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-section-mediaLibrary')));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<MediaLibrarySharingMode>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('本地与网络存储共享').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-settings-button')));
    for (var i = 0; i < 30 && configStore.current.mediaLibrary.sharingMode != MediaLibrarySharingMode.allShared; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(configStore.current.mediaLibrary.sharingMode, MediaLibrarySharingMode.allShared);
    final saved = await tester.runAsync(configStore.load);
    expect(saved!.mediaLibrary.sharingMode, MediaLibrarySharingMode.allShared);
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存另一个服务器档案后认证成功并切换活动档案', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
    addTearDown(() => server.close(force: true));
    const first = ServerProfile(
      profileId: 'profile-a',
      name: '主服务器',
      serverUrl: 'https://a.example/dav',
      username: 'alice',
    );
    final second = ServerProfile(
      profileId: 'profile-b',
      name: '备用服务器',
      serverUrl: 'http://${server.address.address}:${server.port}/dav',
      username: 'bob',
    );
    await tester.runAsync(
      () => configStore.save(
        StreamPathConfig.defaults()
            .upsertProfile(first)
            .upsertProfile(second, activate: false),
      ),
    );

    await tester.pumpWidget(buildSettings());
    await tester.pumpAndSettle();
    tester
        .widget<DropdownButtonFormField<String>>(
          find.byKey(const Key('settings-profile-selector')),
        )
        .onChanged!('profile-b');
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('profile-name-field')),
      '备用服务器已保存',
    );
    final saveButton = tester.widget<FilledButton>(
      find.byKey(const Key('save-settings-button')),
    );
    await tester.runAsync(() async {
      saveButton.onPressed!();
      const expectedFiles = [
        'stream_path_config.json',
        'cache_policy.json',
        'cache_intelligence.json',
        'cache_expiration.json',
      ];
      for (var i = 0; i < 200; i++) {
        final savedProfile = configStore.current.profiles
            .where((profile) => profile.profileId == 'profile-b')
            .first;
        final saveFinished =
            savedProfile.name == '备用服务器已保存' &&
            expectedFiles.every(
              (name) => File(
                '${tempDir.path}${Platform.pathSeparator}$name',
              ).existsSync(),
            ) &&
            tempDir.listSync().whereType<File>().every(
              (file) => !file.path.endsWith('.tmp'),
            );
        if (saveFinished) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump(const Duration(milliseconds: 500));

    expect(configStore.current.profileId, 'profile-b');
    expect(appState.mediaSourceId, 'profile-b');
    expect(find.text('全部配置已保存'), findsOneWidget);
    tester.testTextInput.hide();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();
    await tester.pumpWidget(buildSettings());
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      if (find
          .byKey(const Key('settings-profile-selector'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }

    final selector = tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const Key('settings-profile-selector')),
    );
    expect(selector.initialValue, 'profile-b');
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('profile-name-field')))
          .controller!
          .text,
      '备用服务器已保存',
    );
    expect(configStore.current.profileId, 'profile-b');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();
  });

  testWidgets('切换服务器档案认证失败时恢复原活动档案且不保存候选修改', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late HttpServer server;
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.set(HttpHeaders.connectionHeader, 'close');
        if (request.uri.path == '/dav/a') {
          request.response
            ..statusCode = HttpStatus.multiStatus
            ..headers.contentType = ContentType(
              'application',
              'xml',
              charset: 'utf-8',
            )
            ..write('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"/>');
        } else {
          request.response.statusCode = HttpStatus.unauthorized;
        }
        await request.response.close();
      });
    });
    addTearDown(() => server.close(force: true));
    final first = ServerProfile(
      profileId: 'profile-a',
      name: '默认档案',
      serverUrl: 'http://${server.address.address}:${server.port}/dav/a',
      username: 'alice',
    );
    final second = ServerProfile(
      profileId: 'profile-b',
      name: '其他档案',
      serverUrl: 'http://${server.address.address}:${server.port}/dav/b',
      username: 'bob',
    );
    await tester.runAsync(() async {
      await configStore.save(
        StreamPathConfig.defaults()
            .upsertProfile(first)
            .upsertProfile(second, activate: false),
      );
      await appState.connect(
        baseUrl: first.serverUrl,
        username: first.username,
        password: first.password,
        profileId: first.profileId,
      );
    });
    final previousService = appState.webDavService;

    await tester.pumpWidget(buildSettings());
    await tester.pumpAndSettle();
    tester
        .widget<DropdownButtonFormField<String>>(
          find.byKey(const Key('settings-profile-selector')),
        )
        .onChanged!('profile-b');
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('profile-name-field')),
      '认证失败时不能保存',
    );
    tester
        .widget<FilledButton>(find.byKey(const Key('save-settings-button')))
        .onPressed!();
    for (var i = 0; i < 50; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      if (find.textContaining('重新连接失败').evaluate().isNotEmpty) break;
    }

    expect(configStore.current.profileId, 'profile-a');
    expect(
      configStore.current.profiles
          .where((profile) => profile.profileId == 'profile-b')
          .single
          .name,
      '其他档案',
    );
    expect(appState.mediaSourceId, 'profile-a');
    expect(identical(appState.webDavService, previousService), isTrue);
    expect(appState.username, 'alice');
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const Key('settings-profile-selector')),
          )
          .initialValue,
      'profile-a',
    );
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('profile-name-field')))
          .controller!
          .text,
      '默认档案',
    );
    expect(find.textContaining('重新连接失败'), findsOneWidget);
  });

  testWidgets('磨砂设置分组使用无阴影的扁平内容层', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildSettings(theme: AppTheme.dark(glass: true)));
    await tester.pumpAndSettle();

    final flatCards = tester
        .widgetList<GlassSurface>(find.byType(GlassSurface))
        .where((surface) => surface.level == GlassSurfaceLevel.content)
        .toList(growable: false);
    expect(flatCards, isNotEmpty);
    for (final card in flatCards) {
      expect(card.showShadow, isFalse);
      expect(card.border, isNotNull);
    }
  });

  testWidgets('已确认缺少增强端点时禁用恢复与索引更新并显示能力摘要', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const profile = ServerProfile(
      profileId: 'alist-360',
      name: 'AList 3.6.0',
      serverUrl: 'https://alist.test/dav',
      username: 'viewer',
      password: 'secret',
      openListRecovery: OpenListRecoveryConfig(
        enabled: true,
        baseUrl: 'https://alist.test',
        token: 'admin-token',
      ),
    );
    await tester.runAsync(
      () => configStore
          .save(StreamPathConfig.defaults().upsertProfile(profile))
          .timeout(const Duration(seconds: 5)),
    );
    final progressService = appState.progressService;
    appState.dispose();
    appState = AppState(
      configStore: configStore,
      playbackHistoryStore: PlaybackHistoryStore.forPath(
        '${tempDir.path}${Platform.pathSeparator}playback_history_capability.json',
      ),
      progressService: progressService,
      openListIndexService: OpenListIndexService(
        requestSender: (uri, {required method, headers, body, timeout}) async {
          if (uri.path == '/api/public/settings') {
            return const OpenListHttpResponse(
              statusCode: 200,
              data: {
                'code': 200,
                'data': {'version': 'v3.6.0'},
              },
            );
          }
          if (uri.path == '/api/admin/index/progress') {
            return const OpenListHttpResponse(
              statusCode: 200,
              data: {
                'code': 200,
                'data': {'is_done': true},
              },
            );
          }
          return const OpenListHttpResponse(statusCode: 404);
        },
      ),
      cachePolicyConfigStore: cachePolicyStore,
      cacheIntelligenceConfigStore: intelligenceStore,
      cacheExpirationConfigStore: expirationStore,
      cacheCleaner: cacheCleaner,
      learningDataCleaner: learningDataCleaner,
    );

    await tester.pumpWidget(buildSettings());
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final recovery = tester.widget<SwitchListTile>(
      find.byKey(const Key('openlist-recovery-switch')),
    );
    final indexUpdate = tester.widget<SwitchListTile>(
      find.byKey(const Key('openlist-index-auto-update-switch')),
    );
    expect(recovery.onChanged, isNull);
    expect(indexUpdate.onChanged, isNull);
    expect(
      find.descendant(
        of: find.byKey(const Key('openlist-capability-summary')),
        matching: find.textContaining('存储恢复 不可用'),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(buildSettings(language: AppLanguage.english));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('openlist-capability-summary')),
        matching: find.textContaining(
          'Backend v3.6.0 capabilities: Basic WebDAV available',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'The current backend does not provide the storage recovery endpoint, '
        'so automatic recovery is disabled',
      ),
      findsOneWidget,
    );
  });

  testWidgets('索引轮询只重建服务器分类并保留全部表单', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const profile = ServerProfile(
      profileId: 'openlist-polling',
      name: 'OpenList polling',
      serverUrl: 'https://openlist.test/dav',
      username: 'viewer',
      password: 'secret',
      openListRecovery: OpenListRecoveryConfig(
        baseUrl: 'https://openlist.test',
        token: 'admin-token',
      ),
    );
    await tester.runAsync(
      () =>
          configStore.save(StreamPathConfig.defaults().upsertProfile(profile)),
    );
    final progressService = appState.progressService;
    appState.dispose();
    var progressRequests = 0;
    appState = AppState(
      configStore: configStore,
      playbackHistoryStore: PlaybackHistoryStore.forPath(
        '${tempDir.path}${Platform.pathSeparator}playback_history_polling.json',
      ),
      progressService: progressService,
      openListIndexService: OpenListIndexService(
        requestSender: (uri, {required method, headers, body, timeout}) async {
          if (uri.path == '/api/public/settings') {
            return const OpenListHttpResponse(
              statusCode: 200,
              data: {
                'code': 200,
                'data': {'version': 'v4.1.4'},
              },
            );
          }
          if (uri.path == '/api/admin/index/progress') {
            progressRequests++;
            return OpenListHttpResponse(
              statusCode: 200,
              data: {
                'code': 200,
                'data': {
                  'is_done': progressRequests >= 2,
                  'obj_count': progressRequests,
                },
              },
            );
          }
          return const OpenListHttpResponse(statusCode: 404);
        },
      ),
      cachePolicyConfigStore: cachePolicyStore,
      cacheIntelligenceConfigStore: intelligenceStore,
      cacheExpirationConfigStore: expirationStore,
      cacheCleaner: cacheCleaner,
      learningDataCleaner: learningDataCleaner,
    );
    final builds = <SettingsSection, int>{};
    await tester.pumpWidget(
      buildSettings(
        onSectionBuilt: (section) =>
            builds.update(section, (count) => count + 1, ifAbsent: () => 1),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (progressRequests >= 1 &&
          find
              .byKey(const Key('openlist-index-progress-status'))
              .evaluate()
              .isNotEmpty) {
        break;
      }
    }
    expect(progressRequests, 1);
    expect(
      find.byType(Form, skipOffstage: false),
      findsNWidgets(SettingsSection.values.length),
    );
    builds.clear();

    await tester.pump(const Duration(seconds: 2));
    for (var i = 0; i < 10 && progressRequests < 2; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(progressRequests, 2);
    expect(builds[SettingsSection.server] ?? 0, greaterThan(0));
    for (final section in SettingsSection.values) {
      if (section == SettingsSection.server) continue;
      expect(builds[section] ?? 0, 0, reason: '索引轮询不应重建 ${section.name} 分类');
    }
  });

  testWidgets('背景密度滑块只重建界面分类', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final builds = <SettingsSection, int>{};
    await tester.pumpWidget(
      buildSettings(
        onSectionBuilt: (section) =>
            builds.update(section, (count) => count + 1, ifAbsent: () => 1),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byType(Form, skipOffstage: false),
      findsNWidgets(SettingsSection.values.length),
    );
    await tester.tap(find.byKey(const Key('settings-section-appearance')));
    await tester.pumpAndSettle();
    tester
        .widget<SegmentedButton<InterfaceStyle>>(
          find.byKey(const Key('interface-style-selector')),
        )
        .onSelectionChanged!({InterfaceStyle.glass});
    await tester.pump();
    builds.clear();

    for (final value in const [0.61, 0.62, 0.63]) {
      tester
          .widget<Slider>(find.byKey(const Key('glass-opacity-slider')))
          .onChanged!(value);
      await tester.pump();
    }

    expect(builds[SettingsSection.appearance], 3);
    for (final section in SettingsSection.values) {
      if (section == SettingsSection.appearance) continue;
      expect(builds[section] ?? 0, 0, reason: '滑块采样不应重建 ${section.name} 分类');
    }
  });

  testWidgets('外观能力刷新只重建界面分类并保留全部表单', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final builds = <SettingsSection, int>{};
    await tester.pumpWidget(
      buildSettings(
        onSectionBuilt: (section) =>
            builds.update(section, (count) => count + 1, ifAbsent: () => 1),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byType(Form, skipOffstage: false),
      findsNWidgets(SettingsSection.values.length),
    );
    await tester.tap(find.byKey(const Key('settings-section-appearance')));
    await tester.pumpAndSettle();
    builds.clear();
    final previousQueries = appearanceDriver.queryCount;
    final refreshButton = find.byKey(
      const Key('refresh-window-capabilities-button'),
    );

    await tester.ensureVisible(refreshButton);
    await tester.pump();
    await tester.tap(refreshButton);
    for (var attempt = 0; attempt < 10; attempt++) {
      await tester.pump(const Duration(milliseconds: 10));
      if (!appearanceController.checkingCapabilities) break;
    }

    expect(appearanceDriver.queryCount, previousQueries + 1);
    expect(builds[SettingsSection.appearance] ?? 0, greaterThan(0));
    for (final section in SettingsSection.values) {
      if (section == SettingsSection.appearance) continue;
      expect(builds[section] ?? 0, 0, reason: '能力刷新不应重建 ${section.name} 分类');
    }
    expect(
      find.byType(Form, skipOffstage: false),
      findsNWidgets(SettingsSection.values.length),
    );
  });

  testWidgets('诊断页提供检查、脱敏导出和非破坏性数据库维护入口', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildSettings());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-section-diagnostics')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('run-diagnostics-button')), findsOneWidget);
    expect(find.byKey(const Key('export-diagnostics-button')), findsOneWidget);
    expect(find.byKey(const Key('repair-databases-button')), findsOneWidget);
    expect(find.textContaining('脱敏边界'), findsOneWidget);
    expect(SettingsPageMemory.selectedSection, SettingsSection.diagnostics);
    expect(tester.takeException(), isNull);
  });

  testWidgets('设置分页在表单区域接收滚轮且不会重复滚动', (tester) async {
    tester.view.physicalSize = const Size(1200, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildSettings());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-section-cache')));
    await tester.pumpAndSettle();

    final page = find.byKey(
      const PageStorageKey<String>('settings-page-cache'),
    );
    final scrollbarFinder = find.byKey(
      const ValueKey<String>('settings-scrollbar-cache'),
    );
    final regionFinder = find.ancestor(
      of: scrollbarFinder,
      matching: find.byType(DirectoryWheelScrollRegion),
    );
    final region = tester.widget<DirectoryWheelScrollRegion>(regionFinder);
    final scrollView = tester.widget<SingleChildScrollView>(page);
    final scrollbar = tester.widget<Scrollbar>(scrollbarFinder);

    expect(identical(region.controller, scrollView.controller), isTrue);
    expect(identical(region.controller, scrollbar.controller), isTrue);
    expect(region.controller.offset, 0);

    final location = tester.getCenter(
      find.byKey(const Key('cache-enabled-switch')),
    );
    final pointer = TestPointer(1, ui.PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(location));
    await tester.sendEventToBinding(
      PointerScrollEvent(position: location, scrollDelta: const Offset(0, 120)),
    );
    await tester.pump();

    expect(region.controller.offset, 120);
    expect(tester.takeException(), isNull);
  });

  testWidgets('界面页保存磨砂样式与背景不透明度', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildSettings());
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('settings-section-appearance')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-section-appearance')));
    await tester.pumpAndSettle();

    expect(find.text('Windows 材质'), findsOneWidget);
    expect(
      find.byKey(const Key('windows-appearance-capabilities-section')),
      findsOneWidget,
    );
    expect(find.text('Windows 10.0（内部版本 26100）'), findsOneWidget);
    expect(
      tester
          .widget<Slider>(find.byKey(const Key('glass-opacity-slider')))
          .onChanged,
      isNull,
    );

    tester
        .widget<SegmentedButton<InterfaceStyle>>(
          find.byKey(const Key('interface-style-selector')),
        )
        .onSelectionChanged!({InterfaceStyle.glass});
    await tester.pump();
    expect(
      tester
          .widget<SegmentedButton<InterfaceStyle>>(
            find.byKey(const Key('interface-style-selector')),
          )
          .selected,
      {InterfaceStyle.glass},
    );
    tester
        .widget<SegmentedButton<WindowMaterialPreference>>(
          find.byKey(const Key('window-material-selector')),
        )
        .onSelectionChanged!({WindowMaterialPreference.mica});
    await tester.pump();
    final slider = tester.widget<Slider>(
      find.byKey(const Key('glass-opacity-slider')),
    );
    slider.onChanged!(0.70);
    await tester.pump();
    final saveButton = tester.widget<FilledButton>(
      find.byKey(const Key('save-settings-button')),
    );
    await tester.runAsync(() async {
      saveButton.onPressed!();
      final expectedFiles = [
        'stream_path_config.json',
        'cache_policy.json',
        'cache_intelligence.json',
        'cache_expiration.json',
      ];
      for (var i = 0; i < 200; i++) {
        final saveFinished =
            configStore.current.appearance.style == InterfaceStyle.glass &&
            expectedFiles.every(
              (name) => File(
                '${tempDir.path}${Platform.pathSeparator}$name',
              ).existsSync(),
            ) &&
            tempDir.listSync().whereType<File>().every(
              (file) => !file.path.endsWith('.tmp'),
            );
        if (saveFinished) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      SettingsPageMemory.selectedSection,
      SettingsSection.appearance,
      reason: '保存前所有设置页默认值都应通过校验',
    );
    expect(appearanceDriver.applied, hasLength(1), reason: '选择磨砂样式后应先应用窗口效果');
    final saved = configStore.current.appearance;
    expect(saved.style, InterfaceStyle.glass);
    expect(saved.material, WindowMaterialPreference.mica);
    expect(saved.glassOpacity, closeTo(0.70, 0.001));
    expect(appearanceController.glassActive, isTrue);
    expect(find.text('全部配置已保存'), findsOneWidget);
    final snackBarBottom = tester.getBottomRight(find.byType(SnackBar)).dy;
    final saveButtonTop = tester
        .getTopLeft(find.byKey(const Key('save-settings-button')))
        .dy;
    expect(
      snackBarBottom,
      lessThanOrEqualTo(saveButtonTop),
      reason: '保存提示应悬浮在设置下边栏上方，不能覆盖保存按钮',
    );
    expect(
      find.byKey(const Key('save-settings-button')).hitTestable(),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('save-settings-button')))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄窗口下材质选择器保持可用且不溢出', (tester) async {
    tester.view.physicalSize = const Size(520, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildSettings());
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('settings-section-appearance')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-section-appearance')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('window-material-selector')),
    );
    await tester.pump();

    expect(find.byKey(const Key('window-material-selector')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('隐藏后缀开关关闭后保留英文逗号格式内容', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildSettings());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-section-general')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('hidden-extensions-field')),
      '.ass, .mkv',
    );
    final field = tester.widget<TextFormField>(
      find.byKey(const Key('hidden-extensions-field')),
    );
    expect(field.controller?.text, '.ass, .mkv');

    await tester.tap(find.byKey(const Key('hidden-extensions-enabled-switch')));
    await tester.pump();
    expect(field.controller?.text, '.ass, .mkv');
  });

  testWidgets('基础设置保存语言后同步持久化并更新全局状态', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildSettings());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-section-general')));
    await tester.pumpAndSettle();

    final languageField = find.byKey(const Key('app-language-field'));
    expect(languageField, findsOneWidget);
    await tester.ensureVisible(languageField);
    final dropdown = tester.widget<DropdownButton<AppLanguage>>(
      find.descendant(
        of: languageField,
        matching: find.byType(DropdownButton<AppLanguage>),
      ),
    );
    dropdown.onChanged!(AppLanguage.english);
    await tester.pump();

    final saveButton = tester.widget<FilledButton>(
      find.byKey(const Key('save-settings-button')),
    );
    await tester.runAsync(() async {
      saveButton.onPressed!();
      for (var i = 0; i < 200; i++) {
        if (configStore.current.language == AppLanguage.english) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump(const Duration(milliseconds: 300));

    expect(configStore.current.language, AppLanguage.english);
    expect(appState.language, AppLanguage.english);
    final persisted = await tester.runAsync(
      () async =>
          jsonDecode(
                await File(
                  '${tempDir.path}${Platform.pathSeparator}stream_path_config.json',
                ).readAsString(),
              )
              as Map<String, dynamic>,
    );
    expect(persisted!['language'], 'en');
    expect(tester.takeException(), isNull);
  });

  testWidgets('全部设置重置需要确认且不会清理缓存', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const customAppearance = AppearanceConfig(
      style: InterfaceStyle.glass,
      material: WindowMaterialPreference.mica,
      glassOpacity: 0.70,
    );
    await tester.runAsync(() async {
      await configStore.save(
        const StreamPathConfig(
          serverUrl: 'https://example.com/dav',
          username: 'user',
          password: 'secret',
          playerExecutable: 'custom-player.exe',
          hiddenExtensionsEnabled: false,
          appearance: customAppearance,
        ),
      );
    });

    await tester.pumpWidget(buildSettings());
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('settings-section-general')), findsOneWidget);

    await tester.runAsync(() async {
      expect(
        await cachePolicyStore.save(
          const CachePolicyConfig(
            enabled: false,
            mode: CachePolicyMode.performance,
            memoryBudgetRatio: 0.40,
          ),
        ),
        isTrue,
      );
      expect(
        await intelligenceStore.save(
          const CacheIntelligenceConfig(enabled: false, minSamples: 12),
        ),
        isTrue,
      );
      expect(
        await expirationStore.save(
          const CacheExpirationConfig(
            directoryFreshnessMinutes: 77,
            playbackRetentionDays: 99,
          ),
        ),
        isTrue,
      );
    });
    await tester.tap(find.byKey(const Key('settings-section-general')));
    await tester.pump(const Duration(milliseconds: 500));

    final resetButton = find.byKey(const Key('reset-settings-button'));
    await tester.ensureVisible(resetButton);
    await tester.tap(resetButton);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('重置全部设置？'), findsOneWidget);

    await tester.tap(find.byKey(const Key('cancel-reset-settings-button')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(configStore.current.serverUrl, 'https://example.com/dav');
    expect(cachePolicyStore.current.enabled, isFalse);
    expect(cacheCleaner.clearCalls, 0);
    expect(learningDataCleaner.clearCalls, 0);

    await tester.tap(resetButton);
    await tester.pump(const Duration(milliseconds: 500));
    final confirmButton = tester.widget<FilledButton>(
      find.byKey(const Key('confirm-reset-settings-button')),
    );
    await tester.runAsync(() async {
      confirmButton.onPressed!();
      for (var i = 0; i < 200; i++) {
        final resetFinished =
            configStore.current.serverUrl.isEmpty &&
            cachePolicyStore.current.enabled &&
            intelligenceStore.current.enabled &&
            expirationStore.current.directoryFreshnessMinutes ==
                CacheExpirationConfig.defaultDirectoryFreshnessMinutes;
        if (resetFinished) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump(const Duration(milliseconds: 500));

    expect(configStore.current.toJson(), StreamPathConfig.defaults().toJson());
    expect(
      cachePolicyStore.current.toJson(),
      CachePolicyConfig.defaults().toJson(),
    );
    expect(
      intelligenceStore.current.toJson(),
      CacheIntelligenceConfig.defaults().toJson(),
    );
    expect(
      expirationStore.current.toJson(),
      CacheExpirationConfig.defaults().toJson(),
    );
    expect(
      appearanceController.config.toJson(),
      AppearanceConfig.defaults().toJson(),
    );
    expect(cacheCleaner.clearCalls, 0);
    expect(learningDataCleaner.clearCalls, 0);
    expect(find.text('全部设置已恢复默认值'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-section-server')));
    await tester.pump(const Duration(milliseconds: 500));
    final serverField = tester.widget<TextFormField>(
      find.byKey(const Key('server-url-field')),
    );
    expect(serverField.controller?.text, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('缓存清理必须确认，取消不执行、确认后执行', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildSettings());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-section-cache')));
    await tester.pumpAndSettle();

    final clearButton = find.byKey(const Key('clear-cache-button'));
    await tester.ensureVisible(clearButton);
    await tester.tap(clearButton);
    await tester.pumpAndSettle();
    expect(find.text('清理缓存？'), findsOneWidget);

    await tester.tap(find.byKey(const Key('cancel-clear-cache-button')));
    await tester.pumpAndSettle();
    expect(cacheCleaner.clearCalls, 0);

    await tester.tap(clearButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-clear-cache-button')));
    await tester.pump();
    await tester.runAsync(() async {
      for (var i = 0; i < 50 && cacheCleaner.clearCalls == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump(const Duration(milliseconds: 500));

    expect(cacheCleaner.clearCalls, 1);
    expect(learningDataCleaner.clearCalls, 0);
    expect(find.text('缓存已清理'), findsOneWidget);

    final learningButton = find.byKey(const Key('clear-learning-data-button'));
    await tester.ensureVisible(learningButton);
    await tester.tap(learningButton);
    await tester.pumpAndSettle();
    expect(find.text('清理学习数据？'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('cancel-clear-learning-data-button')),
    );
    await tester.pumpAndSettle();
    expect(learningDataCleaner.clearCalls, 0);

    await tester.tap(learningButton);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('confirm-clear-learning-data-button')),
    );
    await tester.pump();
    await tester.runAsync(() async {
      for (var i = 0; i < 50 && learningDataCleaner.clearCalls == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump(const Duration(milliseconds: 500));

    expect(cacheCleaner.clearCalls, 1);
    expect(learningDataCleaner.clearCalls, 1);
    expect(find.text('学习数据已清理'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('缓存过期时间在缓存页显示且可编辑', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildSettings());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-section-cache')));
    await tester.pumpAndSettle();

    final playbackField = find.byKey(
      const Key('playback-retention-days-field'),
    );
    await tester.ensureVisible(playbackField);
    expect(playbackField, findsOneWidget);
    expect(
      find.byKey(const Key('directory-freshness-minutes-field')),
      findsOneWidget,
    );
    expect(find.text('缓存学习数据不自动过期，只能通过下方独立按钮主动清理。'), findsOneWidget);

    await tester.enterText(playbackField, '45');
    expect(tester.widget<TextFormField>(playbackField).controller?.text, '45');
    expect(tester.takeException(), isNull);
  });
}

class _RecordingCacheCleaner implements CacheCleaner {
  int clearCalls = 0;

  @override
  Future<CacheCleanupResult> clear() async {
    clearCalls++;
    return const CacheCleanupResult(
      cacheDirectory: 'test-cache',
      deletedEntries: 0,
      clearedStores: 0,
    );
  }
}

class _RecordingWindowAppearanceDriver implements WindowAppearanceDriver {
  final List<AppearanceConfig> applied = [];
  int queryCount = 0;

  static const capabilities = WindowAppearanceCapabilities(
    isDetected: true,
    platformSupported: true,
    versionMajor: 10,
    versionMinor: 0,
    buildNumber: 26100,
    compositionEnabled: true,
    transparencyEnabled: true,
    highContrast: false,
    remoteSession: false,
    supportsLegacyAcrylic: true,
    supportsMica: true,
    supportsSystemBackdrop: true,
    systemBackdropType: WindowBackdropType.systemAcrylic,
  );

  @override
  Future<WindowAppearanceCapabilities> queryCapabilities() async {
    queryCount++;
    return capabilities;
  }

  @override
  Future<WindowAppearanceResult> apply(
    AppearanceConfig config,
    Brightness brightness,
  ) async {
    applied.add(config);
    return config.isGlass
        ? WindowAppearanceResult(
            requestedStyle: InterfaceStyle.glass,
            requestedMaterial: config.material,
            actualBackdrop: config.material == WindowMaterialPreference.acrylic
                ? WindowBackdropType.systemAcrylic
                : WindowBackdropType.mica,
            capabilities: capabilities,
          )
        : WindowAppearanceResult.classic(capabilities);
  }
}
