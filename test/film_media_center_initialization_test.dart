import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/presentation/pages/film_media_center_page.dart';
import 'package:streampath/presentation/pages/global_media_library_page.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/theme/window_appearance_status.dart';

import 'helpers/shell_test_app_state.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  testWidgets('媒体中心初始化各帧保留同一 Acrylic 主题表面', (tester) async {
    final fixture = await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('center_surface_');
      final progress = await PlaybackProgressService.open(
        inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      final app = _DelayedPlaybackApp(
        configStore: StreamPathConfigStore.forPath(
          p.join(temp.path, 'config.json'),
        ),
        playbackHistoryStore: PlaybackHistoryStore.forPath(
          p.join(temp.path, 'history.json'),
        ),
        mediaLibraryStore: MediaLibraryStore.forPath(
          p.join(temp.path, 'media.json'),
        ),
        progressService: progress,
      );
      await app.getFilmCatalog();
      return (temp, progress, app);
    });
    final (temp, progress, app) = fixture!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        if (!app.ready.isCompleted) app.ready.complete();
        app.dispose();
        await app.closeTestStores();
        await progress.close();
        await temp.delete(recursive: true);
      });
    });
    final theme = AppTheme.dark(
      windowBackdrop: WindowBackdropType.systemAcrylic,
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          theme: theme,
          home: FilmMediaCenterPage(
            onOpenItem: (_) {},
            onContinueSelected: (_) {},
            onContinueMenu: (_, _) {},
            onOpenLegacyItem: (_) {},
          ),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      final surfaces = tester.widgetList<Material>(find.byType(Material));
      expect(
        surfaces.any(
          (material) => material.color == theme.scaffoldBackgroundColor,
        ),
        isTrue,
        reason: 'Missing themed surface at initialization frame $i',
      );
    }
    expect(find.byType(GlobalMediaLibraryPage), findsOneWidget);
    app.ready.complete();
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('媒体中心'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _DelayedPlaybackApp extends ShellTestAppState {
  _DelayedPlaybackApp({
    required super.configStore,
    required super.playbackHistoryStore,
    required super.progressService,
    required super.mediaLibraryStore,
  });
  final ready = Completer<void>();
  @override
  Future<void> initializeFilmPlayback() async {
    await ready.future;
    await super.initializeFilmPlayback();
  }
}
