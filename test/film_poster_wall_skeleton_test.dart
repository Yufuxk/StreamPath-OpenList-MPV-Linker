import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/film_collection.dart';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/cinematic_states.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';
import 'package:streampath/presentation/widgets/film_continue_card.dart';
import 'package:streampath/presentation/widgets/film_poster_wall.dart';
import 'package:streampath/presentation/widgets/film_shelf.dart';
import 'package:streampath/presentation/widgets/skeleton_scope.dart';

void main() {
  final tmdb = TmdbMetadataService(credentials: _NoCredentials());
  final images = FilmCatalogImageCache(Directory.systemTemp, tmdb);
  Widget frame(
    Widget wall, {
    double scale = 1,
    bool dark = true,
    bool disableAnimations = false,
  }) => MaterialApp(
    theme: dark ? AppTheme.dark() : AppTheme.light(),
    home: MediaQuery(
      data: MediaQueryData(
        textScaler: TextScaler.linear(scale),
        disableAnimations: disableAnimations,
      ),
      child: Scaffold(body: wall),
    ),
  );

  void expectLabelsMatch(WidgetTester tester, int count) {
    final labels = find.byType(FilmPosterLabel);
    expect(labels, findsNWidgets(count));
    for (var i = 0; i < count; i++) {
      final label = labels.at(i);
      final text = find.descendant(of: label, matching: find.byType(Text));
      final bar = find.descendant(
        of: label,
        matching: find.byType(FractionallySizedBox),
      );
      final line = tester.getRect(text);
      final fill = tester.getRect(
        find.descendant(of: bar, matching: find.byType(DecoratedBox)),
      );
      expect(fill.left, line.left);
      expect(fill.center.dy, closeTo(line.center.dy, .001));
      expect(fill.width, line.width);
      expect(fill.height, closeTo(line.height * .6, .001));
    }
  }

  for (final (size, scale, dark, count) in [
    (const Size(1920, 900), 1.0, true, 1),
    (const Size(1920, 900), 1.0, true, 3),
    (const Size(540, 600), 2.0, false, 3),
  ]) {
    testWidgets('$count 部作品从首帧按实际封面和标注占位 $size / $scale', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final works = [
        for (var i = 0; i < count; i++)
          FilmWork(
            id: i + 1,
            type: FilmMediaType.movie,
            title: 'Poster ${i + 1}',
            originalTitle: 'Poster ${i + 1}',
            overview: '',
            language: 'en',
            year: i.isEven ? 2026 : null,
          ),
      ];
      var opened = 0;
      Widget wall({required bool loading}) => frame(
        FilmPosterGrid(
          works: loading ? const [] : works,
          loading: loading,
          cache: images,
          onOpen: (_) => opened++,
          onMenu: (_, _) {},
        ),
        scale: scale,
        dark: dark,
      );

      await tester.pumpWidget(wall(loading: true));
      final skeleton = find.byType(CinematicSkeleton);
      expect(skeleton, findsNothing);
      await tester.pump(const Duration(milliseconds: 300));
      expect(skeleton, findsNothing);

      await tester.pumpWidget(wall(loading: false));
      final poster = find.byType(FilmArtwork);
      expect(skeleton, findsNWidgets(count));
      final rects = [
        for (var i = 0; i < count; i++) tester.getRect(poster.at(i)),
      ];
      for (var i = 0; i < count; i++) {
        expect(tester.getRect(skeleton.at(i)), rects[i]);
      }
      expectLabelsMatch(tester, count + (count + 1) ~/ 2);
      await tester.tap(poster.first, warnIfMissed: false);
      expect(opened, 0);
      await tester.pump(const Duration(milliseconds: 119));
      expect(skeleton, findsNWidgets(count));
      await tester.pumpAndSettle();
      expect(skeleton, findsNothing);
      for (var i = 0; i < count; i++) {
        expect(tester.getRect(poster.at(i)), rects[i]);
      }
      await tester.tap(poster.first);
      expect(opened, 1);
    });
  }

  testWidgets('空查询在等待与完成后都没有骨架', (tester) async {
    Widget wall({required bool loading}) => frame(
      FilmPosterGrid(
        works: const [],
        loading: loading,
        cache: images,
        onOpen: (_) {},
        onMenu: (_, _) {},
        emptyBuilder: (_) => const Center(child: Text('Empty results')),
      ),
    );

    await tester.pumpWidget(wall(loading: true));
    expect(find.byType(CinematicSkeleton), findsNothing);
    expect(find.text('Empty results'), findsNothing);
    await tester.pumpWidget(wall(loading: false));
    expect(find.byType(CinematicSkeleton), findsNothing);
    expect(find.text('Empty results'), findsOneWidget);
  });

  testWidgets('合集保留单行标注，关闭动画时直接替换', (tester) async {
    await tester.pumpWidget(
      frame(
        FilmPosterWall(
          itemCount: 1,
          itemBuilder: (_, _) => FilmCollectionCard(
            collection: const FilmCollection(id: 'c', name: 'Collection'),
            cache: images,
            path: null,
            onTap: () {},
          ),
        ),
        disableAnimations: true,
      ),
    );
    final skeleton = find.byType(CinematicSkeleton);
    final rect = tester.getRect(find.byType(FilmArtwork));
    expect(tester.getRect(skeleton), rect);
    expectLabelsMatch(tester, 1);
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    expect(skeleton, findsNothing);
    expect(tester.getRect(find.byType(FilmArtwork)), rect);
  });

  testWidgets('播放记录按实际标注行排版，慢图不阻塞海报墙替换', (tester) async {
    final catalog = (await tester.runAsync(() async {
      sqfliteFfiInit();
      return FilmCatalogController(
        store: await FilmCatalogStore.open(
          inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        ),
        tmdb: tmdb,
        images: images,
        sourceFor: (_) => throw StateError('Unexpected media access'),
      );
    }))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(catalog.close);
    });
    final record = MediaLibraryRecord(
      item: const MediaLibraryItem(
        sourceId: 'fixture',
        parentPath: '',
        name: 'Playback title',
        kind: MediaLibraryKind.video,
      ),
      updatedAt: DateTime(2026),
    );
    await tester.pumpWidget(
      frame(
        FilmPosterWall(
          padding: 20,
          itemHeight: 400,
          itemCount: 1,
          itemBuilder: (_, _) => SkeletonLoadBoundary(
            ready: false,
            artwork: true,
            child: FilmContinueCard(
              catalog: catalog,
              record: record,
              poster: true,
              positionMs: 60000,
              onTap: () {},
            ),
          ),
        ),
      ),
    );
    final poster = find.byType(FilmArtwork);
    final rect = tester.getRect(poster);
    expect(tester.getRect(find.byType(CinematicSkeleton)), rect);
    expectLabelsMatch(tester, 2);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CinematicSkeleton), findsNothing);
    expect(tester.getRect(poster), rect);
  });
}

class _NoCredentials extends TmdbCredentialStore {
  @override
  Future<String?> read() async => null;
}
