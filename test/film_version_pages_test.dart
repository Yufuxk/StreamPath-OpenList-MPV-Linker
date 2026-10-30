import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/domain/services/film_version_resolver.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/pages/film_detail_page.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';
import 'package:streampath/presentation/widgets/film_continue_card.dart';
import 'package:streampath/presentation/widgets/skeleton_scope.dart';
import 'package:streampath/presentation/widgets/film_segmented_control.dart';
import 'package:streampath/presentation/widgets/sp_menu.dart';
import 'helpers/shell_test_app_state.dart';
import 'helpers/pump_until.dart';

Future<void> settleVersions(
  WidgetTester tester, {
  VoidCallback? afterFrame,
}) async {
  for (var i = 0; i < 25; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 12)),
    );
    await tester.pump(const Duration(milliseconds: 40));
    afterFrame?.call();
  }
}

void main() {
  testWidgets('双层选择持久联动，缺集隐藏，页面封面状态保留，播放目标严格匹配', (tester) async {
    tester.view.physicalSize = const Size(1280, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late ShellTestAppState app;
    late FilmCatalogController catalog;
    late Directory dir;
    late PlaybackProgressService progress;
    late int workId;
    late FilmVersionIndex versions;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('film_version_page_');
      final config = StreamPathConfigStore.forPath('${dir.path}/config.json');
      await config.save(
        StreamPathConfig(
          localRoots: [
            LocalRootConfig(
              rootId: 'fixture',
              displayName: 'Fixture',
              path: dir.path,
            ),
          ],
        ),
      );
      progress = await PlaybackProgressService.open('${dir.path}/progress.db');
      app = ShellTestAppState(
        configStore: config,
        playbackHistoryStore: PlaybackHistoryStore.forPath(
          '${dir.path}/history.json',
        ),
        mediaLibraryStore: MediaLibraryStore.forPath(
          '${dir.path}/records.json',
        ),
        progressService: progress,
      );
      catalog = await app.getFilmCatalog();
      final id = await catalog.store.addRoot(
        sourceId: 'local:fixture',
        kind: MediaSourceKind.local,
        path: 'TV',
        type: FilmMediaType.tv,
        name: 'Fixture',
      );
      final root = (await catalog.store.root(id))!;
      final generation = await catalog.store.beginScan(id);
      final paths = [
        'TV/A/S01/E1.mkv',
        'TV/A/S01/E2.mkv',
        'TV/A/S02/E1.mkv',
        'TV/B/S01/E1.mkv',
        'TV/B/S01/E3.mkv',
      ];
      await catalog.store.stage(root, generation, [
        for (final path in paths)
          FilmScanEntry(
            path: path,
            parentPath: path.substring(0, path.lastIndexOf('/')),
            name: path.split('/').last,
            mediaKind: 'video',
          ),
      ]);
      await catalog.store.commitScan(id, generation, cancelled: () => false);
      final otherId = await catalog.store.addRoot(
        sourceId: 'local:other',
        kind: MediaSourceKind.local,
        path: 'TV',
        type: FilmMediaType.tv,
        name: 'Other',
      );
      final otherRoot = (await catalog.store.root(otherId))!;
      final otherGeneration = await catalog.store.beginScan(otherId);
      await catalog.store.stage(otherRoot, otherGeneration, [
        const FilmScanEntry(
          path: 'TV/C/S01/E1.mkv',
          parentPath: 'TV/C/S01',
          name: 'E1.mkv',
          mediaKind: 'video',
        ),
      ]);
      await catalog.store.commitScan(
        otherId,
        otherGeneration,
        cancelled: () => false,
      );
      await catalog.store.bind(
        await catalog.store.resources(),
        const FilmWork(
          type: FilmMediaType.tv,
          tmdbId: 13,
          title: '版本选择测试',
          originalTitle: 'Version fixture',
          overview: '',
          language: 'zh-CN',
          metadata: {'presentation_version': 3, 'certification_version': 1},
        ),
      );
      final rows = await catalog.store.resources();
      await catalog.store.mapEpisodes({
        for (final r in rows)
          r: (r.path.contains('/S02/') ? 2 : 1, int.parse(r.name[1])),
      });
      workId = rows.first.workId!;
      versions = FilmVersionIndex(await catalog.store.resources());
      catalog.store.spoilerProtection = true;
      await catalog.store.markWatched(await catalog.store.resources(), true);
    });
    final opened = <MediaLibraryItem>[];
    final initialWork = (await tester.runAsync(
      () => catalog.store.work(workId),
    ))!;
    Widget frame({
      Key? key,
      Locale locale = const Locale('zh', 'CN'),
      ThemeData? theme,
    }) => ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('zh', 'CN'),
          Locale('zh', 'TW'),
          Locale('ja'),
          Locale('en'),
        ],
        theme: theme ?? AppTheme.dark(),
        home: RepaintBoundary(
          key: const Key('film-version-capture'),
          child: FilmDetailPage(
            key: key,
            catalog: catalog,
            workId: workId,
            initialWork: initialWork,
            onOpenItem: (item) async => opened.add(item),
          ),
        ),
      ),
    );
    await tester.pumpWidget(frame());
    await tester.pump();
    expect(
      find.byKey(const Key('film-season-version-selector')),
      findsNothing,
      reason:
          'Skeleton must not reserve a version selector before data arrives',
    );
    expect(
      find.byKey(const Key('film-work-version-selector')),
      findsNothing,
      reason: 'Skeleton must not reserve a work version selector before data',
    );
    await settleVersions(tester);
    expect(
      find.byKey(const Key('film-season-version-selector')),
      findsOneWidget,
      reason: 'Multi-version works show the season version selector',
    );
    expect(
      find.byKey(const Key('film-work-version-selector')),
      findsOneWidget,
      reason: 'Multi-version works show the work version selector',
    );
    final pageState = tester.state(find.byType(FilmDetailPage));
    final list = tester.widget<ListView>(
      find.byKey(const Key('film-detail-scroll')),
    );
    final selector = find.byKey(const Key('film-season-version-selector'));
    await tester.ensureVisible(selector);
    await settleVersions(tester);
    final a = versions.families.singleWhere((f) => f.name.endsWith('A'));
    final b = versions.families.singleWhere((f) => f.name.endsWith('B'));
    final c = versions.families.singleWhere((f) => f.name.endsWith('C'));
    Iterable<FilmEpisodeCard> cards() =>
        tester.widgetList<FilmEpisodeCard>(find.byType(FilmEpisodeCard));
    expect(cards().map((c) => c.resource.episode), [1, 2]);
    final first = find.byKey(ValueKey('film-episode-$workId-1-1'));
    final art = find
        .descendant(of: first, matching: find.byType(FilmArtwork))
        .first;
    final artState = tester.state(art);
    final continueArt = find
        .descendant(
          of: find.byType(FilmContinueCard),
          matching: find.byType(FilmArtwork),
        )
        .first;
    final continueArtState = tester.state(continueArt);
    final continueState = tester.state(find.byType(FilmContinueCard));
    final continueBounds = tester.getRect(find.byType(FilmContinueCard));
    List<String?> continueLabels() => tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(FilmContinueCard),
            matching: find.byType(Text),
          ),
        )
        .map((w) => w.data)
        .toList();
    final initialContinueLabels = continueLabels();
    final offset = list.controller!.offset;
    await tester.tap(
      find.descendant(of: selector, matching: find.byKey(ValueKey(b.key))),
    );
    await settleVersions(
      tester,
      afterFrame: () {
        expect(
          tester.state(continueArt),
          same(continueArtState),
          reason: 'Equivalent continuation content keeps the mounted cover',
        );
        expect(
          tester.state(find.byType(FilmContinueCard)),
          same(continueState),
        );
        expect(tester.getRect(find.byType(FilmContinueCard)), continueBounds);
        expect(continueLabels(), initialContinueLabels);
        expect(
          tester.state(art),
          same(artState),
          reason:
              'Version switching keeps mounted artwork in every intermediate frame',
        );
        expect(
          find.descendant(of: first, matching: find.byType(ImageFiltered)),
          findsNothing,
          reason: 'Loaded watch state never becomes a temporary spoiler mask',
        );
      },
    );
    expect(cards().map((c) => c.resource.episode), [1, 3]);
    expect(tester.state(find.byType(FilmDetailPage)), same(pageState));
    expect(tester.state(art), same(artState));
    expect(list.controller!.offset, closeTo(offset, 1));
    await tester.runAsync(() => catalog.store.markWatched(c.resources, false));
    await settleVersions(tester);
    tester
        .widget<FilmSegmentedControl<String>>(selector)
        .onSelectionChanged(c.key);
    await settleVersions(
      tester,
      afterFrame: () {
        expect(tester.state(art), same(artState));
        expect(
          find.descendant(of: first, matching: find.byType(ImageFiltered)),
          findsNothing,
        );
      },
    );
    tester
        .widget<FilmSegmentedControl<String>>(selector)
        .onSelectionChanged(b.key);
    await settleVersions(tester);
    await tester.runAsync(
      () => catalog.store.markWatched([cards().first.resource], false),
    );
    await settleVersions(tester);
    expect(
      find.descendant(of: first, matching: find.byType(ImageFiltered)),
      findsWidgets,
    );
    await tester.tap(find.descendant(of: first, matching: find.text('展示封面')));
    await settleVersions(tester);
    final revealedArtState = tester.state(art);
    final revealedContinueArtState = tester.state(continueArt);
    final revealedBounds = tester.getRect(first);
    for (var i = 0; i < 20; i++) {
      tester
          .widget<FilmSegmentedControl<String>>(selector)
          .onSelectionChanged(i.isEven ? a.key : b.key);
      await settleVersions(
        tester,
        afterFrame: () {
          expect(tester.state(art), same(revealedArtState));
          expect(tester.state(continueArt), same(revealedContinueArtState));
          expect(tester.getRect(first), revealedBounds);
          expect(
            find.descendant(of: first, matching: find.byType(ImageFiltered)),
            findsNothing,
          );
        },
      );
    }
    final saved = await tester.runAsync(
      () => catalog.store.versionSelection('tmdb:tv:13'),
    );
    expect(saved!.seasons[1], b.key);
    final capture = Platform.environment['STREAMPATH_FILM_VERSION_SCREENSHOT'];
    if (capture != null) {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('film-version-capture')),
      );
      final image = (await tester.runAsync(
        () => boundary.toImage(pixelRatio: tester.view.devicePixelRatio),
      ))!;
      final bytes = await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.png),
      );
      image.dispose();
      await tester.runAsync(
        () => File(capture).writeAsBytes(bytes!.buffer.asUint8List()),
      );
    }
    await tester.runAsync(
      () => cards().first.onOpenItem(cards().first.resource.playbackItem),
    );
    expect(opened.single.targetPath, contains('/B/'));
    expect(opened.single.filmVersionContext!.selection.forSeason(1), b.key);
    final dropdown = tester.widget<SPDropdownButtonFormField<String>>(
      find.byType(SPDropdownButtonFormField<String>),
    );
    dropdown.onChanged!(b.key);
    await settleVersions(tester);
    final global = await tester.runAsync(
      () => catalog.store.versionSelection('tmdb:tv:13'),
    );
    expect(global!.defaultKey, b.key);
    expect(global.seasons, isEmpty);
    final seasons = tester.widget<FilmSegmentedControl<int?>>(
      find.byType(FilmSegmentedControl<int?>),
    );
    seasons.onSelectionChanged(2);
    await settleVersions(tester);
    expect(cards(), isEmpty);
    expect(find.text('第 2 季 (0)'), findsOneWidget);
    expect(find.text('所选版本在本季没有可用剧集'), findsOneWidget);
    final current = tester.widget<FilmSegmentedControl<String>>(selector);
    current.onSelectionChanged(a.key);
    await settleVersions(tester);
    expect(cards().single.resource.path, contains('/A/S02/'));
    tester
        .widget<SPDropdownButtonFormField<String>>(
          find.byType(SPDropdownButtonFormField<String>),
        )
        .onChanged!(b.key);
    await settleVersions(tester);
    expect(cards(), isEmpty);
    expect(
      (await tester.runAsync(
        () => catalog.store.versionSelection('tmdb:tv:13'),
      ))!.seasons,
      isEmpty,
    );
    tester
        .widget<FilmSegmentedControl<String>>(selector)
        .onSelectionChanged(a.key);
    await settleVersions(tester);
    await tester.pumpWidget(const SizedBox());
    await settleVersions(tester);
    await tester.pumpWidget(frame(key: const ValueKey('reopened')));
    await settleVersions(tester);
    expect(cards().map((c) => c.resource.episode), [1, 3]);
    await tester.pumpWidget(const SizedBox());
    var recentReady = false;
    Future<void> prepareRecent() async {
      await catalog.store.setPreference(
        'film_versions:["tmdb:tv:13",null]',
        null,
      );
      final item = b.resources.first.playbackItem;
      await app.mediaLibraryStore!.recordPlayback(
        item,
        playbackSessionId: 'completed-version',
      );
      await app.mediaLibraryStore!.dismissVideoContinueSession(
        item.sourceId,
        'completed-version',
      );
      recentReady = true;
    }

    await tester.runAsync(() async {
      prepareRecent();
    });
    await pumpUntil(
      tester,
      () => recentReady,
      reason: 'Recent completed history fixture is saved',
    );
    await tester.pumpWidget(
      frame(key: const ValueKey('first-choice-from-recent')),
    );
    await settleVersions(tester);
    expect(
      (await tester.runAsync(
        () => catalog.store.versionSelection('tmdb:tv:13'),
      ))!.defaultKey,
      b.key,
    );
    expect(cards().map((c) => c.resource.episode), [1, 3]);
    var playbackReady = false;
    Future<void> preparePlayback() async {
      for (final family in [a, b]) {
        final resource = family.resources.firstWhere(
          (r) => r.season == 1 && r.episode == (family == a ? 2 : 3),
        );
        final item = resource.playbackItem;
        await app.progressService.saveProgress(
          url: app.resolveMediaLibraryTarget(item, allowLogicalPath: true)!,
          profileId: item.sourceId,
          positionMs: family == a ? 10000 : 20000,
          durationMs: 100000,
        );
        await app.mediaLibraryStore!.recordPlayback(
          item,
          playbackSessionId: 'real-${family.key}',
        );
      }
      playbackReady = true;
    }

    await tester.runAsync(() async {
      preparePlayback();
    });
    await pumpUntil(
      tester,
      () => playbackReady,
      reason: 'Independent version playback history is saved',
    );
    await settleVersions(tester);
    FilmContinueCard continueCard() =>
        tester.widget<FilmContinueCard>(find.byType(FilmContinueCard));
    expect(continueCard().record.item.targetPath, contains('/B/S01/E3.mkv'));
    expect(continueCard().positionMs, 20000);
    tester
        .widget<SPDropdownButtonFormField<String>>(
          find.byType(SPDropdownButtonFormField<String>),
        )
        .onChanged!(a.key);
    await settleVersions(tester);
    expect(continueCard().record.item.targetPath, contains('/A/S01/E2.mkv'));
    expect(continueCard().positionMs, 10000);
    opened.clear();
    continueCard().onTap();
    expect(opened.single.targetPath, contains('/A/S01/E2.mkv'));
    tester
        .widget<SPDropdownButtonFormField<String>>(
          find.byType(SPDropdownButtonFormField<String>),
        )
        .onChanged!(b.key);
    await settleVersions(tester);
    expect(continueCard().record.item.targetPath, contains('/B/S01/E3.mkv'));
    expect(continueCard().positionMs, 20000);
    for (final locale in const [
      Locale('zh', 'CN'),
      Locale('zh', 'TW'),
      Locale('ja'),
      Locale('en'),
    ]) {
      for (final light in [false, true]) {
        for (final dpr in [1.0, 1.5]) {
          tester.view.devicePixelRatio = dpr;
          tester.view.physicalSize = Size(640 * dpr, 1000 * dpr);
          await tester.pumpWidget(
            frame(
              key: ValueKey('ui-$locale-$light-$dpr'),
              locale: locale,
              theme: light ? AppTheme.light() : AppTheme.dark(),
            ),
          );
          await settleVersions(tester);
          expect(
            find.byKey(const Key('film-work-version-selector')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('film-season-version-selector')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        }
      }
    }
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await catalog.store.close();
      await progress.close();
      app.dispose();
      await dir.delete(recursive: true);
    });
  });
}
