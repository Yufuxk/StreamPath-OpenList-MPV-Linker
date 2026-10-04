import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/film_shelf.dart';
import 'package:streampath/presentation/widgets/film_work_menu.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  testWidgets('封面菜单采用圆角实底，刷新更新同一作品且右键不触发打开', (tester) async {
    final prepared = await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('film_menu_');
      final store = await FilmCatalogStore.open(
        p.join(temp.path, 'catalog.db'),
      );
      final rootId = await store.addRoot(
        sourceId: 'local:test',
        kind: MediaSourceKind.local,
        path: 'Movies',
        type: FilmMediaType.movie,
        name: 'Movies',
      );
      final root = (await store.root(rootId))!;
      final generation = await store.beginScan(rootId);
      await store.stage(root, generation, const [
        FilmScanEntry(
          path: 'Movies/Movie.mkv',
          parentPath: 'Movies',
          name: 'Movie.mkv',
          mediaKind: 'video',
        ),
      ]);
      await store.commitScan(rootId, generation, cancelled: () => false);
      await store.bind(
        await store.resources(),
        const FilmWork(
          type: FilmMediaType.movie,
          tmdbId: 1,
          title: 'Original',
          originalTitle: 'Original',
          overview: '',
          language: 'zh-CN',
          metadata: {'presentation_version': 3},
        ),
      );
      final requests = <String>[];
      final tmdb = TmdbMetadataService(
        credentials: _Token(),
        dio: Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                requests.add(options.path);
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: options.path.endsWith('/images')
                        ? {'id': 1, 'backdrops': [], 'logos': []}
                        : {
                            'id': 1,
                            'title': 'Updated',
                            'original_title': 'Original',
                            'overview': '',
                            'release_date': '2020-01-01',
                            'genres': [],
                            'credits': {'cast': [], 'crew': []},
                          },
                  ),
                );
              },
            ),
          ),
      );
      final c = FilmCatalogController(
        store: store,
        tmdb: tmdb,
        images: FilmCatalogImageCache(
          Directory(p.join(temp.path, 'images')),
          tmdb,
        ),
        sourceFor: (_) => throw StateError('Unexpected directory request'),
      );
      return (
        temp,
        c,
        (await store.works(type: FilmMediaType.movie)).single,
        requests,
      );
    });
    final (temp, c, work, requests) = prepared!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await c.close();
        await temp.delete(recursive: true);
      });
    });
    var opened = 0;
    final theme = AppTheme.dark();
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: SizedBox(
                width: 174,
                height: 304,
                child: FilmWorkCard(
                  work: work,
                  cache: c.images,
                  onTap: () => opened++,
                  onMenu: (position) => showFilmWorkMenu(
                    context,
                    catalog: c,
                    work: work,
                    position: position,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    Future<void> settle() async {
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.tap(find.byType(FilmWorkCard), buttons: kSecondaryMouseButton);
    await settle();
    expect(opened, 0);
    expect(find.byWidgetPredicate((w) => w is PopupMenuItem), findsNWidgets(5));
    final surface = tester
        .widgetList<Material>(find.byType(Material))
        .singleWhere(
          (m) =>
              m.shape is RoundedRectangleBorder &&
              m.color == AppTheme.dropdownMenuColor(theme),
        );
    expect(
      (surface.shape as RoundedRectangleBorder).borderRadius,
      AppTheme.dropdownBorderRadius,
    );
    expect(surface.color!.a, 1);
    await tester.tap(find.text('刷新元数据'));
    await settle();
    final refreshed = await tester.runAsync(() => c.store.work(work.id));
    expect(refreshed!.id, work.id);
    expect(refreshed.title, 'Updated');
    expect(requests.any((path) => path.endsWith('/movie/1')), isTrue);
    expect(requests.any((path) => path.endsWith('/movie/1/images')), isTrue);
    await tester.tap(find.byType(FilmWorkCard));
    await tester.pump();
    expect(opened, 1);
    expect(tester.takeException(), isNull);
  });
}

class _Token extends TmdbCredentialStore {
  @override
  Future<String?> read() async => 'test-token';
}
