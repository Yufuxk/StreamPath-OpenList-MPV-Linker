import 'package:streampath/data/models/video_playlist_mode.dart';
import 'package:streampath/data/models/video_queue.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/data/local/directory_cache.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_entry.dart';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/playback_history.dart';
import 'package:streampath/data/models/video_playback_scope.dart';
import 'package:streampath/data/models/special_playlist_mode.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/domain/services/external_player_service.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/domain/services/webdav_font_localizer.dart';
import 'package:streampath/domain/services/webdav_font_matcher.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/pages/browser_page.dart';
import 'package:streampath/presentation/state/app_state.dart';

import 'helpers/pump_until.dart';

const _video = '葬送的芙莉莲.2023.S01E29.BluRay.REMUX.1080p.mkv';
const _firstVideo = '葬送的芙莉莲.2023.S01E01.BluRay.REMUX.1080p.mkv';
const _nextVideo = '葬送的芙莉莲.2023.S02E01.BluRay.REMUX.1080p.mkv';
const _nextLastVideo = '葬送的芙莉莲.2023.S02E123.BluRay.REMUX.1080p.mkv';
const _specialVideo = '葬送的芙莉莲.2023.S00E01.BluRay.REMUX.1080p.mkv';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    HttpOverrides.global = null;
  });
  for (final local in [true, false]) {
    for (final targetParent in ['Season 01', 'Season 02']) {
      testWidgets('隐式跨季关闭后独立选集 ${local ? 'local' : 'WebDAV'} $targetParent', (
        tester,
      ) async {
        final fixture = await tester.runAsync(() async {
          final temp = await Directory.systemTemp.createTemp(
            'sp_implicit_reopen_',
          );
          final media = await Directory(p.join(temp.path, 'Media')).create();
          for (final (parent, names) in [
            ('Season 01', [_video, _firstVideo]),
            ('Season 02', [_nextVideo, _nextLastVideo]),
          ]) {
            await Directory(p.join(media.path, parent)).create();
            for (final name in names) {
              await File(p.join(media.path, parent, name)).writeAsBytes([0]);
            }
          }
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server.listen((request) async {
            expect(request.method, 'PROPFIND');
            final relative = Uri.decodeComponent(
              request.uri.path,
            ).replaceFirst('/dav', '').replaceAll(RegExp(r'^/|/$'), '');
            final folder = Directory(p.join(media.path, relative));
            final rows = <String>[
              _response(
                '/dav${relative.isEmpty ? '' : '/$relative'}/',
                p.basename(folder.path),
                true,
              ),
            ];
            await for (final child in folder.list()) {
              final name = p.basename(child.path);
              rows.add(
                _response(
                  '/dav/${relative.isEmpty ? '' : '$relative/'}$name',
                  name,
                  child is Directory,
                ),
              );
            }
            request.response.statusCode = HttpStatus.multiStatus;
            request.response.write(
              '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">${rows.join()}</d:multistatus>',
            );
            await request.response.close();
          });
          final config = StreamPathConfigStore.forPath(
            p.join(temp.path, 'config.json'),
          );
          final root = LocalRootConfig(
            rootId: 'reopen',
            displayName: 'Media',
            path: media.path,
          );
          await config.save(
            StreamPathConfig(
              playerExecutable: 'mpv.exe',
              localRoots: [root],
              videoPlaylistMode: VideoPlaylistMode.implicit,
              autoSeasonTransitionEnabled: true,
            ),
          );
          final cache = DirectoryCache(boxName: 'implicit_reopen');
          final progress = await PlaybackProgressService.open(
            inMemoryDatabasePath,
            factory: databaseFactoryFfi,
          );
          final player = _NamingPlayer(configStore: config);
          final app = _NamingAppState(
            playerService: player,
            configStore: config,
            progressService: progress,
            directoryCache: cache,
            playbackHistoryStore: PlaybackHistoryStore.forPath(
              p.join(temp.path, 'history.json'),
            ),
          );
          if (!local) {
            await app.connect(
              baseUrl: 'http://${server.address.address}:${server.port}/dav',
              username: 'viewer',
              password: 'secret',
            );
          }
          await app.initializeFilmPlayback();
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump(const Duration(seconds: 4));
            await app.closeCatalog();
            app.dispose();
            for (var i = 0; i < 4; i++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 30)),
              );
              await tester.pump();
            }
            await tester.pump(const Duration(seconds: 4));
            await progress.close();
            await server.close(force: true);
            await tester.runAsync(() => temp.delete(recursive: true));
          });
          return (app, player, root);
        });
        final (app, player, root) = fixture!;
        final key = GlobalKey<BrowserPageState>();
        MediaLibraryItem item(String parent, String name) => MediaLibraryItem(
          sourceId: local ? root.sourceId : app.mediaSourceId!,
          sourceKind: local ? MediaSourceKind.local : MediaSourceKind.webdav,
          parentPath: parent,
          name: name,
          kind: MediaLibraryKind.video,
        );
        await tester.pumpWidget(
          ChangeNotifierProvider<AppState>.value(
            value: app,
            child: MaterialApp(
              home: Scaffold(
                body: BrowserPage(
                  key: key,
                  playbackOnly: true,
                  localRoot: local ? root : null,
                  initialDirectoryPath: 'Season 01',
                ),
              ),
            ),
          ),
        );
        Future<void> open(MediaLibraryItem target) async {
          var done = false;
          Future<void>? operation;
          await tester.runAsync(() async {
            operation = key.currentState!
                .playLibraryItem(target)
                .then((_) => done = true);
          });
          await pumpUntil(
            tester,
            () => done,
            reason:
                'Playback preparation must finish before checking the queue',
          );
          await tester.runAsync(() => operation!);
        }

        await open(item('Season 01', _video));
        final originalId = player.sessionIds.single;
        final plan = player.plan!;
        final nextIndex = plan.items.indexWhere(
          (i) => i.versions.first.name == _nextVideo,
        );
        expect(nextIndex, greaterThan(0));
        await tester.runAsync(
          () => plan.activated(nextIndex, plan.items[nextIndex].versions.first),
        );
        await tester.pump();
        final crossed = (await tester.runAsync(
          app.filmPlaybackHistoryStore.loadAll,
        ))!.single;
        expect(crossed.dirCrumbs, ['Season 02']);
        expect(crossed.videoQueueRootPath, 'Season 01');

        player.running = true;
        await open(item('Season 01', _video));
        expect(player.selections.single, (originalId, 1, 'Season 01/$_video'));
        await open(item('Season 02', _nextVideo));
        expect(player.resumed, [originalId]);
        expect(player.sessionIds, [originalId]);
        player.running = false;

        final targetName = targetParent == 'Season 01'
            ? _video
            : _nextLastVideo;
        await open(item(targetParent, targetName));
        expect(player.sessionIds, hasLength(2));
        expect(player.sessionIds.last, isNot(originalId));
        expect(player.entries!.single.catalogPath, '$targetParent/$targetName');
        expect(find.text('未找到上次播放的视频，请检查文件或特典设置'), findsNothing);
        final histories = (await tester.runAsync(
          app.filmPlaybackHistoryStore.loadAll,
        ))!;
        expect(histories, hasLength(2));
        final retained = histories.singleWhere(
          (h) => h.sessionId == originalId,
        );
        expect(retained.fileName, crossed.fileName);
        expect(retained.videoIndex, crossed.videoIndex);
        expect(retained.playlistRelativePaths, crossed.playlistRelativePaths);
        expect(retained.videoQueueRootPath, crossed.videoQueueRootPath);

        await open(item('Season 02', _nextVideo));
        expect(player.sessionIds.last, originalId);
        expect(player.entries!.single.catalogPath, 'Season 02/$_nextVideo');
        expect(
          await tester.runAsync(app.filmPlaybackHistoryStore.loadAll),
          hasLength(2),
        );
        ScaffoldMessenger.of(key.currentContext!).clearSnackBars();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 4));
        expect(tester.takeException(), isNull);
      });
    }
  }
  for (final local in [true, false]) {
    for (final scenario in [
      (
        language: AppLanguage.simplifiedChinese,
        enabled: true,
        next: false,
        single: false,
        resume: false,
        missing: false,
      ),
      (
        language: AppLanguage.traditionalChinese,
        enabled: true,
        next: false,
        single: false,
        resume: false,
        missing: false,
      ),
      (
        language: AppLanguage.simplifiedChinese,
        enabled: true,
        next: true,
        single: false,
        resume: false,
        missing: false,
      ),
      (
        language: AppLanguage.traditionalChinese,
        enabled: true,
        next: true,
        single: false,
        resume: false,
        missing: false,
      ),
      (
        language: AppLanguage.japanese,
        enabled: true,
        next: true,
        single: false,
        resume: false,
        missing: false,
      ),
      (
        language: AppLanguage.english,
        enabled: true,
        next: true,
        single: false,
        resume: false,
        missing: false,
      ),
      (
        language: AppLanguage.english,
        enabled: false,
        next: true,
        single: false,
        resume: false,
        missing: false,
      ),
      (
        language: AppLanguage.simplifiedChinese,
        enabled: true,
        next: false,
        single: true,
        resume: false,
        missing: false,
      ),
      (
        language: AppLanguage.english,
        enabled: true,
        next: true,
        single: true,
        resume: false,
        missing: false,
      ),
      (
        language: AppLanguage.english,
        enabled: true,
        next: true,
        single: true,
        resume: true,
        missing: false,
      ),
      (
        language: AppLanguage.english,
        enabled: true,
        next: true,
        single: true,
        resume: true,
        missing: true,
      ),
    ]) {
      testWidgets('简洁命名 ${local ? 'local' : 'WebDAV'} $scenario', (
        tester,
      ) async {
        final targetFile = !local && scenario.single
            ? _video.replaceFirst('.mkv', '.strm')
            : _video;
        final fixture = await tester.runAsync(() async {
          final temp = await Directory.systemTemp.createTemp(
            'sp_naming_browser_',
          );
          final media = Directory(p.join(temp.path, 'Media'));
          await Directory(
            p.join(media.path, 'Season 01'),
          ).create(recursive: true);
          await Directory(p.join(media.path, 'Season 02')).create();
          await File(p.join(media.path, 'Season 01', _video)).writeAsBytes([0]);
          await File(
            p.join(media.path, 'Season 01', _firstVideo),
          ).writeAsBytes([0]);
          await Directory(p.join(media.path, 'Season 01', 'Fonts')).create();
          await File(
            p.join(media.path, 'Season 01', 'Fonts', 'sample.ttf'),
          ).writeAsBytes([0]);
          await File(
            p.join(
              media.path,
              'Season 01',
              _video.replaceFirst('.mkv', '.flac'),
            ),
          ).writeAsBytes([0]);
          if (!local && scenario.single) {
            await File(
              p.join(media.path, 'Season 01', targetFile),
            ).writeAsString('pointer');
          }
          await File(
            p.join(
              media.path,
              'Season 01',
              _video.replaceFirst('.mkv', '.ass'),
            ),
          ).writeAsString('');
          await File(
            p.join(media.path, 'Season 02', _nextVideo),
          ).writeAsBytes([0]);
          await File(
            p.join(media.path, 'Season 02', _nextLastVideo),
          ).writeAsBytes([0]);
          if (!scenario.next) {
            await Directory(p.join(media.path, 'Season 01', 'OVA')).create();
            await File(
              p.join(media.path, 'Season 01', 'OVA', _specialVideo),
            ).writeAsBytes([0]);
          }
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server.listen((request) async {
            if (request.method != 'PROPFIND') {
              request.response.write(
                Uri(
                  scheme: 'http',
                  host: server.address.address,
                  port: server.port,
                  path: '/dav/Season 01/$_video',
                ).toString(),
              );
              await request.response.close();
              return;
            }
            final relative = Uri.decodeComponent(
              request.uri.path,
            ).replaceFirst('/dav', '').replaceAll(RegExp(r'^/|/$'), '');
            final folder = Directory(p.join(media.path, relative));
            final rows = <String>[
              _response(
                '/dav${relative.isEmpty ? '' : '/$relative'}/',
                p.basename(folder.path),
                true,
              ),
            ];
            await for (final child in folder.list()) {
              final name = p.basename(child.path);
              final path = '/dav${relative.isEmpty ? '' : '/$relative'}/$name';
              rows.add(_response(path, name, child is Directory));
            }
            request.response
              ..statusCode = HttpStatus.multiStatus
              ..headers.contentType = ContentType(
                'application',
                'xml',
                charset: 'utf-8',
              )
              ..write(
                '<d:multistatus xmlns:d="DAV:">${rows.join()}</d:multistatus>',
              );
            await request.response.close();
          });
          // 命名回归只验证网络条目映射，不启用 Hive 目录落盘。
          final cache = DirectoryCache(boxName: 'naming');
          final config = StreamPathConfigStore.forPath(
            p.join(temp.path, 'config.json'),
          );
          final root = LocalRootConfig(
            rootId: 'naming',
            displayName: 'Media',
            path: media.path,
          );
          await config.save(
            StreamPathConfig(
              videoPlaylistMode: VideoPlaylistMode.legacy,
              localRoots: [root],
              language: scenario.language,
              videoPlaylistSimpleNaming: scenario.enabled,
              autoSeasonTransitionEnabled: scenario.next,
              specialPlaylistMode: SpecialPlaylistMode.all,
            ),
          );
          final progress = await PlaybackProgressService.open(
            inMemoryDatabasePath,
            factory: databaseFactoryFfi,
          );
          final player = _NamingPlayer(configStore: config);
          final appState = _NamingAppState(
            playerService: player,
            configStore: config,
            progressService: progress,
            directoryCache: cache,
            playbackHistoryStore: PlaybackHistoryStore.forPath(
              p.join(temp.path, 'history.json'),
            ),
          );
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump(const Duration(seconds: 4));
            await appState.closeCatalog();
            appState.dispose();
            for (var i = 0; i < 4; i++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 30)),
              );
              await tester.pump();
            }
            await progress.close();
            await server.close(force: true);
            await tester.runAsync(() => temp.delete(recursive: true));
          });
          if (!local) {
            await appState.connect(
              baseUrl: 'http://${server.address.address}:${server.port}/dav',
              username: 'viewer',
              password: 'secret',
            );
          }
          if (scenario.single) {
            await appState.initializeFilmPlayback();
            final catalog = await appState.getFilmCatalog();
            final sourceId = local ? root.sourceId : appState.mediaSourceId!;
            final id = await catalog.store.addRoot(
              sourceId: sourceId,
              kind: local ? MediaSourceKind.local : MediaSourceKind.webdav,
              path: '',
              type: FilmMediaType.tv,
              name: 'TV',
            );
            final catalogRoot = (await catalog.store.root(id))!;
            final generation = await catalog.store.beginScan(id);
            final paths = {
              'Season 01/$_firstVideo',
              'Season 01/$_video',
              if (!local) 'Season 01/$targetFile',
              'Season 02/$_nextVideo',
              'Season 02/$_nextLastVideo',
              if (!scenario.next) 'Season 01/OVA/$_specialVideo',
            };
            await catalog.store.stage(catalogRoot, generation, [
              for (final path in paths)
                FilmScanEntry(
                  path: path,
                  parentPath: p.posix.dirname(path),
                  name: p.posix.basename(path),
                  mediaKind: path.endsWith('.strm') ? 'strm' : 'video',
                ),
            ]);
            await catalog.store.commitScan(
              id,
              generation,
              cancelled: () => false,
            );
            await catalog.store.bind(
              await catalog.store.resources(),
              const FilmWork(
                type: FilmMediaType.tv,
                tmdbId: 1,
                title: 'TMDB 芙莉莲',
                originalTitle: 'Frieren',
                overview: '',
                language: 'zh-CN',
                year: 2023,
              ),
            );
            await catalog.store.mapEpisodes({
              for (final resource in await catalog.store.resources())
                if (resource.name != _firstVideo)
                  resource: resource.name == _specialVideo
                      ? (0, 1)
                      : resource.parentPath == 'Season 02'
                      ? (2, resource.name == _nextVideo ? 1 : 123)
                      : (1, resource.name == _firstVideo ? 1 : 29),
            });
            await catalog.store.saveSeason(
              (await catalog.store.resources()).first.workId!,
              1,
              'zh-CN',
              {
                'episodes': [
                  {'episode_number': 29, 'name': '第一季集名'},
                ],
              },
            );
            await catalog.store.saveSeason(
              (await catalog.store.resources()).first.workId!,
              2,
              'zh-CN',
              {
                'episodes': [
                  {'episode_number': 1, 'name': '下一季集名'},
                ],
              },
            );
          }
          return (appState, player, root);
        });
        final (appState, player, root) = fixture!;
        final hostKey = GlobalKey<BrowserPageState>();
        await tester.pumpWidget(
          ChangeNotifierProvider<AppState>.value(
            value: appState,
            child: MaterialApp(
              locale: scenario.language.locale,
              supportedLocales: AppLanguage.values.map(
                (language) => language.locale,
              ),
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              home: Scaffold(
                body: BrowserPage(
                  key: hostKey,
                  playbackOnly: scenario.single,
                  localRoot: local ? root : null,
                  initialDirectoryPath: 'Season 01',
                  initialLibraryItem: scenario.single && !scenario.resume
                      ? MediaLibraryItem(
                          sourceId: local
                              ? root.sourceId
                              : appState.mediaSourceId!,
                          sourceKind: local
                              ? MediaSourceKind.local
                              : MediaSourceKind.webdav,
                          parentPath: 'Season 01',
                          name: targetFile,
                          kind: targetFile.endsWith('.strm')
                              ? MediaLibraryKind.strm
                              : MediaLibraryKind.video,
                          playbackScope: VideoPlaybackScope.singleItem,
                        )
                      : null,
                  initialVideoResumeHistory: scenario.resume
                      ? PlaybackHistory(
                          dirCrumbs: const ['Season 01'],
                          fileName: scenario.missing
                              ? 'missing.mkv'
                              : targetFile,
                          videoIndex: 0,
                          updatedAt: DateTime.now(),
                          playlistFileNames: [
                            scenario.missing ? 'missing.mkv' : targetFile,
                          ],
                          playlistRelativePaths: [
                            'Season 01/${scenario.missing ? 'missing.mkv' : targetFile}',
                          ],
                          sourceId: local
                              ? root.sourceId
                              : appState.mediaSourceId,
                          playbackScope: VideoPlaybackScope.singleItem,
                        )
                      : null,
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 30 && find.text(_video).evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        if (!scenario.single) expect(find.text(_video), findsOneWidget);
        if (!scenario.single) await tester.tap(find.text(_video));
        for (var i = 0; i < 80 && player.entries == null; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        if (scenario.missing) {
          expect(player.entries, isNull);
          expect(tester.takeException(), isNull);
          await tester.pump(const Duration(seconds: 4));
          return;
        }
        expect(player.entries, isNotNull);
        if (scenario.single) {
          expect(find.byType(AppBar), findsNothing);
          final expectedCount = (local ? 2 : 3) + (scenario.next ? 0 : 1);
          expect(player.entries, hasLength(expectedCount));
          final selected = player.entries!.firstWhere(
            (entry) => entry.catalogPath == 'Season 01/$targetFile',
          );
          expect(
            selected.url,
            endsWith(local ? _video : Uri.encodeComponent(_video)),
          );
          expect(selected.subtitle!.name, _video.replaceFirst('.mkv', '.ass'));
          expect(
            selected.title,
            scenario.enabled ? 'TMDB 芙莉莲·2023·S01E29·第一季集名' : targetFile,
          );
          expect(
            player.entries!.first.title,
            scenario.enabled
                ? '葬送的芙莉莲·2023·${scenario.language == AppLanguage.english ? 'Season 1·Episode 01' : '第一季·第01集'}'
                : _firstVideo,
          );
          if (scenario.next) {
            expect(player.nextSeason!.entries, hasLength(2));
            expect(
              player.nextSeason!.entries.first.title,
              scenario.enabled ? 'TMDB 芙莉莲·2023·S02E01·下一季集名' : _nextVideo,
            );
          } else {
            expect(player.nextSeason, isNull);
            expect(player.entries!.last.title, 'TMDB 芙莉莲·2023·S00E01');
          }
          if (local) {
            expect(player.localFonts![1], endsWith('Fonts'));
          } else {
            expect(selected.externalAudioTracks, hasLength(1));
            expect(player.remoteFonts![1]!.files.single.name, 'sample.ttf');
          }
          final histories = await tester.runAsync(
            appState.filmPlaybackHistoryStore.loadAll,
          );
          expect(histories!.single.playbackScope, VideoPlaybackScope.directory);
          expect(histories.single.playlistFileNames, hasLength(expectedCount));
          Future<void>? selection;
          var selectedAgain = false;
          await tester.runAsync(() async {
            selection = hostKey.currentState!
                .playLibraryItem(
                  MediaLibraryItem(
                    sourceId: local ? root.sourceId : appState.mediaSourceId!,
                    sourceKind: local
                        ? MediaSourceKind.local
                        : MediaSourceKind.webdav,
                    parentPath: 'Season 01',
                    name: _firstVideo,
                    kind: MediaLibraryKind.video,
                  ),
                )
                .then((_) => selectedAgain = true);
          });
          for (var i = 0; i < 80 && !selectedAgain; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)),
            );
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(selectedAgain, isTrue);
          await tester.runAsync(() => selection!);
          final selectedHistories = await tester.runAsync(
            appState.filmPlaybackHistoryStore.loadAll,
          );
          expect(selectedHistories, hasLength(1));
          expect(
            selectedHistories!.single.sessionId,
            histories.single.sessionId,
          );
          expect(selectedHistories.single.fileName, _firstVideo);
          expect(selectedHistories.single.videoIndex, 0);
          expect(tester.takeException(), isNull);
          await tester.pump(const Duration(seconds: 4));
          return;
        }
        const labels = [
          '第一季·第29集',
          '第一季·第29集',
          'シーズン1·第29話',
          'Season 1·Episode 29',
        ];
        expect(
          player.entries![1].title,
          scenario.enabled
              ? '葬送的芙莉莲·2023·${labels[scenario.language.index]}'
              : _video,
        );
        const firstLabels = [
          '第一季·第01集',
          '第一季·第01集',
          'シーズン1·第01話',
          'Season 1·Episode 01',
        ];
        expect(
          player.entries!.first.title,
          scenario.enabled
              ? '葬送的芙莉莲·2023·${firstLabels[scenario.language.index]}'
              : _firstVideo,
        );
        expect(
          player.entries![1].url,
          endsWith(local ? _video : Uri.encodeComponent(_video)),
        );
        expect(
          player.entries![1].subtitle!.name,
          _video.replaceFirst('.mkv', '.ass'),
        );
        if (scenario.next) {
          const nextLabels = [
            '第二季·第001集',
            '第二季·第001集',
            'シーズン2·第001話',
            'Season 2·Episode 001',
          ];
          expect(player.nextSeason!.entries, hasLength(2));
          expect(
            player.nextSeason!.entries.first.title,
            scenario.enabled
                ? '葬送的芙莉莲·2023·${nextLabels[scenario.language.index]}'
                : _nextVideo,
          );
          expect(
            player.nextSeason!.entries.last.url,
            endsWith(
              local ? _nextLastVideo : Uri.encodeComponent(_nextLastVideo),
            ),
          );
        } else {
          expect(player.entries, hasLength(3));
          expect(
            player.entries!.last.title,
            scenario.language == AppLanguage.simplifiedChinese
                ? '葬送的芙莉莲·2023·特别篇·第1集'
                : '葬送的芙莉莲·2023·特別篇·第1集',
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 4));
      });
    }
  }
}

String _response(String path, String name, bool directory) =>
    '<d:response><d:href>${Uri(path: path).toString()}${directory && !path.endsWith('/') ? '/' : ''}</d:href><d:propstat><d:prop><d:displayname>$name</d:displayname><d:resourcetype>${directory ? '<d:collection/>' : ''}</d:resourcetype><d:getcontentlength>1</d:getcontentlength></d:prop></d:propstat></d:response>';

class _NamingAppState extends AppState {
  _NamingAppState({
    required super.playerService,
    required super.configStore,
    required super.progressService,
    required super.directoryCache,
    required super.playbackHistoryStore,
  });
  FilmCatalogController? catalog;
  @override
  Future<FilmCatalogController> getFilmCatalog() async {
    if (catalog != null) return catalog!;
    final tmdb = TmdbMetadataService(credentials: _NoCredentials());
    return catalog = FilmCatalogController(
      store: await FilmCatalogStore.open(
        p.join(p.dirname(configStore.configFilePath), 'catalog.db'),
      ),
      tmdb: tmdb,
      images: FilmCatalogImageCache(
        Directory(p.join(p.dirname(configStore.configFilePath), 'images')),
        tmdb,
      ),
      sourceFor: (_) => throw const FilmCatalogException('sourceUnavailable'),
    );
  }

  @override
  Future<FilmCatalogStore> getFilmCatalogStore() async =>
      (await getFilmCatalog()).store;

  Future<void> closeCatalog() async => catalog?.close();
}

class _NoCredentials extends TmdbCredentialStore {
  @override
  Future<String?> read() async => null;
}

class _NamingPlayer extends ExternalPlayerService {
  _NamingPlayer({required super.configStore});
  @override
  ExternalPlayerService forFilmLibrary(
    PlaybackProgressService progress,
    Directory watchLater,
  ) => this;
  List<MediaEntry>? entries;
  SeasonPlaybackEntries? nextSeason;
  List<String?>? localFonts;
  List<WebDavFontDirectory?>? remoteFonts;
  ImplicitVideoPlan? plan;
  final sessionIds = <String>[];
  bool running = false;
  final selections = <(String, int, String?)>[];
  final resumed = <String>[];

  @override
  Future<bool> isPlayerRunning([String? sessionId]) async => running;

  @override
  Future<bool> selectPlaylistEntry(
    String sessionId,
    int index, {
    String? versionPath,
  }) async {
    selections.add((sessionId, index, versionPath));
    return true;
  }

  @override
  Future<void> sendResume([String? sessionId]) async {
    resumed.add(sessionId!);
  }

  Future<PlayerLaunchResult> _record(
    List<MediaEntry> entries,
    SeasonPlaybackEntries? next,
  ) async {
    this.entries = entries;
    nextSeason = next;
    throw AppException.process('Test player stopped');
  }

  @override
  Future<PlayerLaunchResult> launchLocal({
    ImplicitVideoPlan? implicitPlan,
    required List<MediaEntry> entries,
    required String sourceId,
    String? sessionId,
    int playlistStart = 0,
    int? resumeSeconds,
    List<String?>? localFontDirectories,
    SeasonPlaybackEntries? nextSeason,
  }) {
    localFonts = localFontDirectories;
    plan = implicitPlan;
    sessionIds.add(sessionId!);
    return _record(entries, nextSeason);
  }

  @override
  Future<PlayerLaunchResult> launch({
    ImplicitVideoPlan? implicitPlan,
    required List<MediaEntry> entries,
    String? sessionId,
    int playlistStart = 0,
    int? resumeSeconds,
    String? username,
    String? password,
    String? webDavSourceUrl,
    String? webDavSourceId,
    bool automaticRecovery = false,
    WebDavFontDirectory? webDavFonts,
    List<WebDavFontDirectory?>? webDavFontsByEntry,
    List<String?>? localFontDirectories,
    WebDavFontBytesLoader? webDavFontLoader,
    WebDavFontFileLoader? webDavFontFileLoader,
    void Function(WebDavFontLocalizationProgress progress)? onFontProgress,
    void Function(String stage)? onPreparationStage,
    SeasonPlaybackEntries? nextSeason,
  }) {
    remoteFonts = webDavFontsByEntry;
    plan = implicitPlan;
    sessionIds.add(sessionId!);
    return _record(entries, nextSeason);
  }

  @override
  Future<void> captureOpenListProcessIdentity() async {}
}
