import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/pages/film_library_page.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/theme/window_appearance_status.dart';
import 'package:streampath/presentation/widgets/startup_overlay.dart';

import 'helpers/shell_test_app_state.dart';

void main() {
  testWidgets('整窗遮罩保留页面状态，首帧就绪后淡出销毁并恢复交互', (tester) async {
    final ready = ValueNotifier(false);
    addTearDown(ready.dispose);
    var clicks = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StartupOverlay(
          ready: ready,
          child: Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => clicks++,
                child: const Text('Ready content'),
              ),
            ),
          ),
        ),
      ),
    );
    final overlay = find.byKey(const Key('startup-overlay'));
    expect(tester.getRect(overlay), const Rect.fromLTWH(0, 0, 800, 600));
    expect(find.text('Ready content'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.tap(find.text('Ready content'), warnIfMissed: false);
    expect(clicks, 0);
    ready.value = true;
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));
    expect(overlay, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 180));
    await tester.pump();
    expect(overlay, findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.tap(find.text('Ready content'));
    expect(clicks, 1);
  });

  test('加载提示覆盖四种语言', () {
    for (final language in AppLanguage.values) {
      final text = AppLocalizations(language).text('正在加载影视库…');
      expect(text, isNotEmpty);
      if (language != AppLanguage.simplifiedChinese) {
        expect(text, isNot('正在加载影视库…'));
      }
    }
  });

  testWidgets('遮罩随纯色、Acrylic、Mica 和明暗主题变化，加载期不透出页面', (tester) async {
    final ready = ValueNotifier(false);
    addTearDown(ready.dispose);
    for (final backdrop in [
      WindowBackdropType.none,
      WindowBackdropType.systemAcrylic,
      WindowBackdropType.mica,
    ]) {
      for (final dark in [false, true]) {
        final theme = dark
            ? AppTheme.dark(
                glass: backdrop != WindowBackdropType.none,
                windowBackdrop: backdrop,
              )
            : AppTheme.light(
                glass: backdrop != WindowBackdropType.none,
                windowBackdrop: backdrop,
              );
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: StartupOverlay(
              ready: ready,
              child: const ColoredBox(color: Colors.red),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        final surface = tester.widget<Material>(
          find.byKey(const Key('startup-surface')),
        );
        expect(surface.color, theme.scaffoldBackgroundColor);
        expect(
          surface.color!.a,
          backdrop == WindowBackdropType.none ? 1 : lessThan(1),
        );
        expect(
          tester
              .widget<Opacity>(find.byKey(const Key('startup-content')))
              .opacity,
          0,
        );
      }
    }
  });

  testWidgets('目录加载失败也释放遮罩并显示可见错误', (tester) async {
    final fixture = await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('startup_error_');
      final progress = await PlaybackProgressService.open(
        p.join(temp.path, 'progress.db'),
      );
      final app = _FailedCatalogAppState(
        configStore: StreamPathConfigStore.forPath(
          p.join(temp.path, 'config.json'),
        ),
        playbackHistoryStore: PlaybackHistoryStore.forPath(
          p.join(temp.path, 'history.json'),
        ),
        progressService: progress,
      );
      return (temp, progress, app);
    });
    final (temp, progress, app) = fixture!;
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          home: StartupOverlay(
            ready: app.startupReady,
            child: FilmLibraryPage(onOpenItem: (_) async {}),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(app.startupReady.value, true);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.byKey(const Key('startup-overlay')), findsNothing);
    expect(find.text('影视目录库操作失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      app.dispose();
      await progress.close();
      await temp.delete(recursive: true);
    });
  });
}

class _FailedCatalogAppState extends ShellTestAppState {
  _FailedCatalogAppState({
    required super.configStore,
    required super.playbackHistoryStore,
    required super.progressService,
  });

  @override
  Future<FilmCatalogController> getFilmCatalog() =>
      Future.error(const FilmCatalogException('catalogStorageFailed'));
}
