import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/playback_history.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/domain/services/external_player_service.dart';
import 'package:streampath/domain/services/player_process_controller.dart';
import 'package:streampath/domain/services/iso_playback_service.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/pages/film_library_shell.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/film_continue_card.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  for (final mode in [
    'video',
    'orphan',
    'refused',
    'disc',
    'iso',
    'iso-refused',
  ]) {
    testWidgets('影视库关闭并删除续播 $mode', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final prepared = await tester.runAsync(() async {
        final temp = await Directory.systemTemp.createTemp('film_remove_');
        final root = LocalRootConfig(
          rootId: 'remove',
          displayName: 'Local',
          path: temp.path,
        );
        final config = StreamPathConfigStore.forPath(
          p.join(temp.path, 'config.json'),
        );
        await config.save(StreamPathConfig(localRoots: [root]));
        final progress = await PlaybackProgressService.open(
          inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        final tmdb = TmdbMetadataService(credentials: _NoToken());
        final catalog = FilmCatalogController(
          store: await FilmCatalogStore.open(p.join(temp.path, 'catalog.db')),
          tmdb: tmdb,
          images: FilmCatalogImageCache(
            Directory(p.join(temp.path, 'images')),
            tmdb,
          ),
          sourceFor: (_) => throw StateError('Unexpected scan'),
        );
        final player = _Player(configStore: config)..refuse = mode == 'refused';
        final isoPlayer = _IsoPlayer(configStore: config)
          ..refuse = mode == 'iso-refused';
        final app = _App(
          catalog,
          configStore: config,
          playbackHistoryStore: PlaybackHistoryStore.forPath(
            p.join(temp.path, 'history.json'),
          ),
          mediaLibraryStore: MediaLibraryStore.forPath(
            p.join(temp.path, 'library.json'),
          ),
          progressService: progress,
          playerService: player,
          isoPlaybackService: isoPlayer,
        );
        for (final name in ['target', 'neighbor']) {
          final disc =
              (mode == 'disc' || mode.startsWith('iso')) && name == 'target';
          final item = MediaLibraryItem(
            sourceId: root.sourceId,
            sourceKind: MediaSourceKind.local,
            parentPath: '',
            name: '$name.${disc ? 'iso' : 'mkv'}',
            kind: disc ? MediaLibraryKind.iso : MediaLibraryKind.video,
            playbackMode: mode == 'disc' && name == 'target'
                ? PlaybackMode.localHdmvMenu
                : PlaybackMode.legacyTitle,
          );
          await File(p.join(temp.path, item.name)).writeAsBytes([1]);
          await app.filmMediaLibraryStore!.recordPlayback(
            item,
            playbackSessionId: name,
          );
          await app.mediaLibraryStore!.recordPlayback(
            item,
            playbackSessionId: 'browser-$name',
          );
          await progress.saveProgress(
            url: p.join(temp.path, item.name),
            positionMs: 5000,
            durationMs: 60000,
            profileId: root.sourceId,
          );
          if ((!disc || mode.startsWith('iso')) &&
              (mode != 'orphan' || name != 'target')) {
            await app.filmPlaybackHistoryStore.upsert(
              PlaybackHistory(
                sessionId: name,
                sourceId: root.sourceId,
                dirCrumbs: const [],
                fileName: item.name,
                videoIndex: 0,
                updatedAt: DateTime.now(),
                playlistFileNames: [item.name],
                kind: disc
                    ? PlaybackHistoryKind.iso
                    : PlaybackHistoryKind.video,
                playerPid: disc ? 123 : null,
                isoSessionDirectoryPath: disc ? 'target-iso' : null,
              ),
            );
          }
        }
        return (temp, app, catalog, progress, player, isoPlayer, root.sourceId);
      });
      final (temp, app, catalog, progress, player, isoPlayer, sourceId) =
          prepared!;
      final refused = mode == 'refused' || mode == 'iso-refused';
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          app.dispose();
          await catalog.close();
          await progress.close();
          await temp.delete(recursive: true);
        });
      });
      Widget frame() => ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const FilmLibraryShell(),
        ),
      );
      Future<void> settle() async {
        for (var i = 0; i < 15; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await tester.pumpWidget(frame());
      await settle();
      Finder target() => find.byWidgetPredicate(
        (w) => w is FilmContinueCard && w.record.playbackSessionId == 'target',
      );
      expect(target(), findsOneWidget);
      await tester.tap(target(), buttons: kSecondaryMouseButton);
      await settle();
      expect(find.text('删除并关闭播放器'), findsOneWidget);
      await tester.tap(find.text('删除并关闭播放器'));
      await settle();
      expect(target(), refused ? findsOneWidget : findsNothing);
      expect(find.byType(FilmContinueCard), findsNWidgets(refused ? 2 : 1));
      final histories = await tester.runAsync(
        () => app.filmPlaybackHistoryStore.loadAll(),
      );
      expect(histories!.any((h) => h.sessionId == 'target'), refused);
      final browser = await tester.runAsync(
        () => app.mediaLibraryStore!.playbackHistory(
          sourceId,
          audio: false,
          iso: mode == 'disc' || mode.startsWith('iso'),
        ),
      );
      expect(
        browser,
        hasLength(mode == 'disc' || mode.startsWith('iso') ? 1 : 2),
      );
      if (mode != 'disc' && !mode.startsWith('iso')) {
        expect(player.terminated, ['target']);
      }
      if (mode.startsWith('iso')) expect(isoPlayer.terminated, ['target-iso']);
      if (refused) {
        expect(
          find.text(
            mode == 'refused'
                ? '无法确认视频播放器身份，已保留会话且未终止进程'
                : '无法确认 ISO 播放器身份，已保留会话且未终止进程',
          ),
          findsOneWidget,
        );
        player.refuse = false;
        isoPlayer.refuse = false;
        await tester.tap(target(), buttons: kSecondaryMouseButton);
        await settle();
        await tester.tap(find.text('删除并关闭播放器'));
        await settle();
        for (var i = 0; i < 5 && target().evaluate().isNotEmpty; i++) {
          await settle();
        }
        expect(target(), findsNothing);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(frame());
      await settle();
      expect(target(), findsNothing);
      expect(find.byType(FilmContinueCard), findsOneWidget);
      final neighbor = find.byType(FilmContinueCard);
      await tester.tap(neighbor, buttons: kSecondaryMouseButton);
      await settle();
      expect(find.text('删除并关闭播放器'), findsOneWidget);
      await tester.tapAt(const Offset(1100, 800));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}

class _NoToken extends TmdbCredentialStore {
  @override
  Future<String?> read() async => null;
}

class _App extends AppState {
  _App(
    this.catalog, {
    required super.configStore,
    required super.playbackHistoryStore,
    required super.mediaLibraryStore,
    required super.progressService,
    required super.playerService,
    required super.isoPlaybackService,
  });
  final FilmCatalogController catalog;
  @override
  Future<FilmCatalogStore> getFilmCatalogStore() async =>
      (await getFilmCatalog()).store;
  @override
  Future<FilmCatalogController> getFilmCatalog() async => catalog;
}

class _Player extends ExternalPlayerService {
  _Player({required super.configStore});
  @override
  ExternalPlayerService forFilmLibrary(
    PlaybackProgressService progress,
    Directory watchLater,
  ) => this;
  bool refuse = false;
  final terminated = <String>[];
  @override
  Future<void> restoreSession({
    required String sessionId,
    String? profileId,
    required int? pid,
    String? executablePath,
    int? creationTime,
    String? ipcPipeName,
    String? launchEpoch,
    String? currentSeasonPlaylistPath,
    int? currentStageLength,
  }) async {}
  @override
  Future<PlayerTerminationOutcome> terminateSession(String sessionId) async {
    terminated.add(sessionId);
    return refuse
        ? PlayerTerminationOutcome.refused
        : PlayerTerminationOutcome.terminated;
  }
}

class _IsoPlayer extends IsoPlaybackService {
  _IsoPlayer({required super.configStore});
  @override
  Future<IsoPlaybackService> forFilmLibrary(
    StreamPathConfigStore config,
    Set<String> keys,
  ) async => this;
  bool refuse = false;
  final terminated = <String>[];
  @override
  Future<IsoPlaybackSessionSnapshot> sessionSnapshot(
    String? sessionDirectoryPath,
  ) async =>
      const IsoPlaybackSessionSnapshot(liveness: PlayerProcessLiveness.alive);
  @override
  Future<PlayerTerminationOutcome> terminateSession(
    String? sessionDirectoryPath,
  ) async {
    terminated.add(sessionDirectoryPath!);
    return refuse
        ? PlayerTerminationOutcome.refused
        : PlayerTerminationOutcome.terminated;
  }
}
