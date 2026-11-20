import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_library_config.dart';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/openlist_index_config.dart';
import 'package:streampath/data/models/openlist_recovery_config.dart';
import 'package:streampath/data/models/server_profile.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/data/models/appearance_config.dart';
import 'package:streampath/domain/services/openlist_index_service.dart';
import 'package:streampath/domain/services/openlist_recovery_service.dart';
import 'package:streampath/presentation/pages/settings_page.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/theme/appearance_controller.dart';

import 'helpers/pump_until.dart';
import 'helpers/shell_test_app_state.dart';

void main() {
  late Directory tempDir;
  late File configFile;
  late StreamPathConfigStore configStore;
  late MediaLibraryStore mediaLibraryStore;
  late PlaybackProgressService progressService;
  late AppState appState;
  late AppearanceController appearanceController;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    SettingsPageMemory.reset();
    tempDir = Directory.systemTemp.createTempSync('settings_media_library_');
    configFile = File(
      '${tempDir.path}${Platform.pathSeparator}stream_path_config.json',
    );
    configStore = StreamPathConfigStore.forPath(configFile.path);
    await configStore.save(
      const StreamPathConfig(
        serverUrl: 'https://example.test/dav',
        username: 'user',
      ),
    );
    mediaLibraryStore = MediaLibraryStore.forPath(
      '${tempDir.path}${Platform.pathSeparator}media_library.json',
    );
    await mediaLibraryStore.load();
    progressService = await PlaybackProgressService.open(
      '${tempDir.path}/progress.db',
      factory: databaseFactoryFfi,
    );
    appState = ShellTestAppState(
      configStore: configStore,
      playbackHistoryStore: PlaybackHistoryStore.forPath(
        '${tempDir.path}${Platform.pathSeparator}playback_history.json',
      ),
      progressService: progressService,
      mediaLibraryStore: mediaLibraryStore,
    );
    appearanceController = AppearanceController(
      initialConfig: configStore.current.appearance,
      driver: _TestWindowAppearanceDriver(),
    );
  });

  tearDown(() async {
    appearanceController.dispose();
    appState.dispose();
    if (appState case final ShellTestAppState app) await app.closeTestStores();
    await progressService.close();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Widget buildSettings({
    AppearanceConfig appearance = const AppearanceConfig(),
  }) => MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: appState),
      ChangeNotifierProvider<AppearanceController>.value(
        value: appearanceController,
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.light(
        glass: appearance.isGlass,
        glassOpacity: appearance.glassOpacity,
      ),
      home: const SettingsPage(),
    ),
  );

  Future<void> settleSettings(WidgetTester tester) async {
    for (var index = 0; index < 5; index++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
  }

  Future<void> openMediaLibrarySettings(WidgetTester tester) async {
    await tester.pumpWidget(buildSettings());
    await settleSettings(tester);
    final tab = find.byKey(const Key('settings-section-mediaLibrary'));
    await tester.ensureVisible(tab);
    await tester.tap(tab);
    await settleSettings(tester);
    await tester.pumpAndSettle();
  }

  MediaLibraryItem item(
    String name, {
    required MediaLibraryKind kind,
    String parentPath = '媒体',
  }) => MediaLibraryItem(
    sourceId: mediaSourceId(
      baseUrl: configStore.current.serverUrl,
      username: configStore.current.username,
    ),
    parentPath: parentPath,
    name: name,
    kind: kind,
  );

  Future<List<int>> seedFilmFavorites(int count) async {
    final catalog = await appState.getFilmCatalogStore();
    final rootId = await catalog.addRoot(
      sourceId: 'local:fixture',
      kind: MediaSourceKind.local,
      path: 'Movies',
      type: FilmMediaType.movie,
      name: 'Movies',
    );
    final root = (await catalog.root(rootId))!;
    final generation = await catalog.beginScan(rootId);
    await catalog.stage(root, generation, [
      for (var index = 0; index < count; index++)
        FilmScanEntry(
          path: 'Movies/Movie$index.mkv',
          parentPath: 'Movies',
          name: 'Movie$index.mkv',
          mediaKind: 'video',
        ),
    ]);
    await catalog.commitScan(rootId, generation, cancelled: () => false);
    final resources = await catalog.resources();
    final ids = <int>[];
    for (final (index, resource) in resources.indexed) {
      await catalog.bind(
        [resource],
        FilmWork(
          type: FilmMediaType.movie,
          tmdbId: index + 1,
          title: 'Movie $index',
          originalTitle: 'Movie $index',
          overview: '',
          language: 'en',
        ),
      );
      final id = (await catalog.resourceAt(
        resource.sourceId,
        resource.path,
      ))!.workId!;
      ids.add(id);
      await catalog.setFavorite(id, true);
    }
    return ids;
  }

  testWidgets('媒体中心容量设置保存到统一配置并立即应用', (tester) async {
    late List<int> favoritesIds;
    final film = appState.filmMediaLibraryStore!;
    const localDirectory = MediaLibraryItem(
      sourceId: 'local:fixture',
      sourceKind: MediaSourceKind.local,
      parentPath: '',
      name: 'Movies',
      kind: MediaLibraryKind.directory,
    );
    await tester.runAsync(() async {
      favoritesIds = await seedFilmFavorites(3);
      for (var index = 0; index < 3; index++) {
        await mediaLibraryStore.toggleFavorite(
          item('收藏$index.mkv', kind: MediaLibraryKind.video),
        );
        await film.recordPlayback(
          item('Movie$index.mkv', kind: MediaLibraryKind.video),
          playbackSessionId: 'film-$index',
        );
      }
      await mediaLibraryStore.recordRecentDirectory(localDirectory);
    });
    await openMediaLibrarySettings(tester);

    expect(
      find.byKey(const Key('media-library-capacity-section')),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const Key('media-library-favorites-limit-field')),
      '2',
    );
    await tester.enterText(
      find.byKey(const Key('media-library-continue-limit-field')),
      '40',
    );
    await tester.enterText(
      find.byKey(const Key('media-library-recent-playback-limit-field')),
      '2',
    );
    await tester.enterText(
      find.byKey(const Key('media-library-recent-directories-limit-field')),
      '60',
    );
    final saveButton = tester.widget<FilledButton>(
      find.byKey(const Key('save-settings-button')),
    );
    await tester.runAsync(() async {
      saveButton.onPressed!();
      for (var index = 0; index < 200; index++) {
        if (configStore.current.mediaLibrary.maxFavoritesPerSource == 2) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(milliseconds: 300));

    final saved = configStore.current.mediaLibrary;
    expect(saved.maxFavoritesPerSource, 2);
    expect(saved.maxContinuePerLane, 40);
    expect(saved.maxRecentPlaybackPerLane, 2);
    expect(saved.maxRecentDirectoriesPerSource, 60);
    late Map<String, dynamic> json;
    late List<MediaLibraryRecord> favorites;
    await tester.runAsync(() async {
      json = Map<String, dynamic>.from(
        jsonDecode(await configFile.readAsString()) as Map,
      );
      favorites = await mediaLibraryStore.favorites(
        item('x', kind: MediaLibraryKind.video).sourceId,
      );
      final catalog = await appState.getFilmCatalogStore();
      expect(await catalog.isFavorite(favoritesIds.first), isFalse);
      expect(await catalog.isFavorite(favoritesIds.last), isTrue);
      await catalog.setFavorite(favoritesIds.first, true);
      expect(await catalog.isFavorite(favoritesIds.first), isTrue);
      expect(await catalog.isFavorite(favoritesIds[1]), isFalse);
    });
    expect(json['mediaLibrary']['maxFavoritesPerSource'], 2);
    expect(json['mediaLibrary']['maxContinuePerLane'], 40);
    expect(favorites, hasLength(2));
    expect(film.config.maxContinuePerLane, 40);
    expect(film.config.maxRecentDirectoriesPerSource, 60);
    expect(
      film
          .playbackHistorySnapshot(
            item('x', kind: MediaLibraryKind.video).sourceId,
            audio: false,
          )
          .map((record) => record.playbackSessionId),
      ['film-2', 'film-1'],
    );
  });

  testWidgets('共享按钮允许网络与本地同时开启，独立模式关闭冲突项', (tester) async {
    await openMediaLibrarySettings(tester);
    expect(find.byKey(const Key('sharing-network')), findsOneWidget);
    expect(find.byKey(const Key('sharing-local')), findsOneWidget);
    expect(
      configStore.current.mediaLibrary.sharingMode,
      MediaLibrarySharingMode.networkAndLocalShared,
    );

    await tester.tap(find.byKey(const Key('sharing-independent')));
    await tester.pump();
    expect(
      tester.widget<OutlinedButton>(find.byKey(const Key('sharing-network'))),
      isA<OutlinedButton>(),
    );
    await tester.tap(find.byKey(const Key('sharing-network')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sharing-local')));
    await tester.pump();
    expect(find.byKey(const Key('sharing-network')), findsOneWidget);
    expect(find.byKey(const Key('sharing-local')), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('sharing-network'))),
      isA<FilledButton>(),
    );
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('sharing-local'))),
      isA<FilledButton>(),
    );
  });

  testWidgets('设置页展示四个分项清理入口', (tester) async {
    final favorite = item('收藏.mkv', kind: MediaLibraryKind.video);
    final directory = item(
      '最近目录',
      kind: MediaLibraryKind.directory,
      parentPath: '',
    );
    final video = item('第一集.mkv', kind: MediaLibraryKind.video);
    final audio = item('第一首.flac', kind: MediaLibraryKind.audio);
    await tester.runAsync(() async {
      await mediaLibraryStore.toggleFavorite(favorite);
      await mediaLibraryStore.recordRecentDirectory(directory);
      await mediaLibraryStore.recordPlayback(
        video,
        playbackSessionId: 'video-session',
      );
      await mediaLibraryStore.recordPlayback(
        audio,
        playbackSessionId: 'audio-session',
      );
    });
    await openMediaLibrarySettings(tester);

    expect(
      find.byKey(const Key('clear-media-library-favorites-button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('clear-media-library-continue-button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('clear-media-library-recent-button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('clear-media-library-directories-button')),
      findsOneWidget,
    );

    final continueButton = find.byKey(
      const Key('clear-media-library-continue-button'),
    );
    await tester.ensureVisible(continueButton);
    await tester.tap(continueButton);
    await tester.pump();
    expect(find.text('清空继续播放列表？'), findsOneWidget);
    expect(find.textContaining('保留最近播放与播放进度'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('cancel-clear-media-library-button')),
    );
    await tester.pump();

    late List<MediaLibraryRecord> videoHistory;
    late List<MediaLibraryRecord> audioHistory;
    await tester.runAsync(() async {
      videoHistory = await mediaLibraryStore.playbackHistory(
        video.sourceId,
        audio: false,
      );
      audioHistory = await mediaLibraryStore.playbackHistory(
        video.sourceId,
        audio: true,
      );
    });
    expect(videoHistory.single.continueDismissed, isFalse);
    expect(audioHistory.single.continueDismissed, isFalse);
  });

  testWidgets('本地影视库可逐项清理，播放进度仍可读取', (tester) async {
    const video = MediaLibraryItem(
      sourceId: 'local:fixture',
      sourceKind: MediaSourceKind.local,
      parentPath: '',
      name: 'Movie.mkv',
      kind: MediaLibraryKind.video,
    );
    const directory = MediaLibraryItem(
      sourceId: 'local:fixture',
      sourceKind: MediaSourceKind.local,
      parentPath: '',
      name: 'Movies',
      kind: MediaLibraryKind.directory,
    );
    final film = appState.filmMediaLibraryStore!;
    late int workId;
    late String url;
    await tester.runAsync(() async {
      await configStore.save(
        StreamPathConfig(
          localRoots: [
            LocalRootConfig(
              rootId: 'fixture',
              displayName: 'Fixture',
              path: tempDir.path,
            ),
          ],
        ),
      );
      workId = (await seedFilmFavorites(1)).single;
      await film.recordPlayback(video, playbackSessionId: 'film');
      await mediaLibraryStore.recordPlayback(
        video,
        playbackSessionId: 'browser',
      );
      await mediaLibraryStore.toggleFavorite(video);
      await mediaLibraryStore.recordRecentDirectory(directory);
      await appState.initializeFilmPlayback();
      url = appState.resolveMediaLibraryTarget(video)!;
      await appState.filmProgressService.saveProgress(
        url: url,
        profileId: video.sourceId,
        positionMs: 30000,
        durationMs: 120000,
      );
    });
    await openMediaLibrarySettings(tester);

    Future<void> cleanup(String target, String message) async {
      final button = find.byKey(Key('clear-media-library-$target-button'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      final confirm = find.byKey(
        const Key('confirm-clear-media-library-button'),
      );
      expect(confirm, findsOneWidget);
      await tester.tap(confirm);
      await pumpUntil(
        tester,
        () => find.text(message).evaluate().isNotEmpty,
        reason: 'Cleanup completed for $target',
      );
      await tester.pumpAndSettle();
    }

    await cleanup('continue', '继续播放列表已清空');
    for (final store in [film, mediaLibraryStore]) {
      expect(
        store
            .playbackHistorySnapshot(video.sourceId, audio: false)
            .single
            .continueDismissed,
        isTrue,
      );
    }
    await cleanup('directories', '最近目录列表已清空');
    await tester.runAsync(() async {
      expect(
        await mediaLibraryStore.recentDirectories(video.sourceId),
        isEmpty,
      );
      expect(await mediaLibraryStore.favorites(video.sourceId), hasLength(1));
      expect(
        await (await appState.getFilmCatalogStore()).isFavorite(workId),
        isTrue,
      );
    });
    await cleanup('favorites', '收藏列表已清空');
    expect(
      film.playbackHistorySnapshot(video.sourceId, audio: false),
      hasLength(1),
    );
    await cleanup('recent', '最近播放列表已清空');
    await tester.runAsync(() async {
      expect(await mediaLibraryStore.favorites(video.sourceId), isEmpty);
      expect(
        await (await appState.getFilmCatalogStore()).isFavorite(workId),
        isFalse,
      );
      for (final store in [film, mediaLibraryStore]) {
        expect(
          store.playbackHistorySnapshot(video.sourceId, audio: false),
          isEmpty,
        );
      }
      final progress = await appState.filmProgressService.getResumeProgress(
        url,
        profileId: video.sourceId,
      );
      expect(progress?.positionMs, 30000);
    });
  });

  testWidgets('容量字段拒绝超过系统硬上限的数值', (tester) async {
    await openMediaLibrarySettings(tester);
    await tester.enterText(
      find.byKey(const Key('media-library-continue-limit-field')),
      '${MediaLibraryConfig.systemMaxContinuePerLane + 1}',
    );
    await tester.tap(find.byKey(const Key('save-settings-button')));
    await tester.pump();

    expect(
      find.text(
        '请输入 1.0～${MediaLibraryConfig.systemMaxContinuePerLane.toDouble()} 条',
      ),
      findsOneWidget,
    );
    expect(
      configStore.current.mediaLibrary.maxContinuePerLane,
      MediaLibraryConfig.defaultMaxContinuePerLane,
    );
  });

  testWidgets('媒体中心设置在经典、Acrylic 和 Mica 外观下无溢出', (tester) async {
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
    for (final appearance in appearances) {
      tester.view.physicalSize = const Size(520, 760);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(buildSettings(appearance: appearance));
      await settleSettings(tester);
      final tab = find.byKey(const Key('settings-section-mediaLibrary'));
      await tester.ensureVisible(tab);
      await tester.tap(tab);
      await settleSettings(tester);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('media-library-capacity-section')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  });

  testWidgets('定时索引更新拒绝低于五分钟的间隔', (tester) async {
    await tester.pumpWidget(buildSettings());
    await settleSettings(tester);
    final toggle = find.byKey(const Key('openlist-index-auto-update-switch'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pump();
    final interval = find.byKey(const Key('openlist-index-update-interval'));
    await tester.ensureVisible(interval);
    await tester.enterText(interval, '4');
    await tester.tap(find.byKey(const Key('save-settings-button')));
    await tester.pump();

    expect(
      find.text(
        '请输入 ${OpenListIndexConfig.minUpdateIntervalMinutes.toDouble()}～'
        '${OpenListIndexConfig.maxUpdateIntervalMinutes.toDouble()} 分钟',
      ),
      findsOneWidget,
    );
    expect(
      configStore.current.activeProfile?.openListIndex.autoUpdateEnabled,
      isFalse,
    );
  });

  testWidgets('索引设置显示实时进度、条目数和上次更新时间', (tester) async {
    await tester.runAsync(
      () => configStore.save(
        StreamPathConfig.defaults().upsertProfile(
          const ServerProfile(
            profileId: 'progress-profile',
            name: '进度测试',
            serverUrl: 'https://openlist.test/dav',
            username: 'user',
            password: 'password',
            openListRecovery: OpenListRecoveryConfig(
              baseUrl: 'https://openlist.test',
              token: 'admin-token',
            ),
          ),
        ),
      ),
    );
    appState.dispose();
    appState = AppState(
      configStore: configStore,
      playbackHistoryStore: PlaybackHistoryStore.forPath(
        '${tempDir.path}${Platform.pathSeparator}progress-history.json',
      ),
      progressService: progressService,
      mediaLibraryStore: mediaLibraryStore,
      openListIndexService: OpenListIndexService(
        requestSender: (uri, {required method, headers, body, timeout}) async {
          expect(uri.path, '/api/admin/index/progress');
          expect(headers?['authorization'], 'admin-token');
          return const OpenListHttpResponse(
            statusCode: 200,
            data: {
              'code': 200,
              'data': {
                'obj_count': 42,
                'is_done': false,
                'last_done_time': '2026-08-22T08:09:10Z',
                'error': '',
              },
            },
          );
        },
      ),
    );

    await tester.pumpWidget(buildSettings());
    await settleSettings(tester);
    final panel = find.byKey(const Key('openlist-index-progress-panel'));

    expect(panel, findsOneWidget);
    expect(find.text('状态：正在更新'), findsOneWidget);
    expect(find.text('已处理条目：42'), findsOneWidget);
    expect(find.textContaining('上次更新时间：2026-08-22'), findsOneWidget);
    final indicator = tester.widget<LinearProgressIndicator>(
      find.byKey(const Key('openlist-index-progress-indicator')),
    );
    expect(indicator.value, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

class _TestWindowAppearanceDriver implements WindowAppearanceDriver {
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
  Future<WindowAppearanceCapabilities> queryCapabilities() async =>
      capabilities;

  @override
  Future<WindowAppearanceResult> apply(
    AppearanceConfig config,
    Brightness brightness,
  ) async => WindowAppearanceResult.classic(capabilities);
}
