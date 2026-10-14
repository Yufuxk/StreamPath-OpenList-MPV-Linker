import 'package:streampath/presentation/widgets/transition_content.dart';
import 'package:streampath/presentation/widgets/adaptive_film_backdrop.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/video_queue.dart';
import 'package:streampath/data/models/media_connection.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/pages/film_detail_page.dart';
import 'package:streampath/presentation/pages/film_library_page.dart';
import 'package:streampath/presentation/pages/film_library_shell.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';
import 'package:streampath/presentation/widgets/film_shelf.dart';
import 'package:streampath/presentation/widgets/film_library_background.dart';
import 'package:streampath/presentation/widgets/directory_scroll_view.dart';
import 'package:streampath/presentation/pages/film_related_page.dart';
import 'package:streampath/data/models/film_home_section.dart';
import 'package:streampath/presentation/pages/film_featured_page.dart';
import 'package:streampath/presentation/widgets/film_featured_showcase.dart';
import 'package:streampath/presentation/widgets/film_segmented_control.dart';
import 'package:streampath/presentation/widgets/film_detail_backdrop.dart';
import 'package:streampath/presentation/widgets/film_detail_back_button.dart';
import 'package:streampath/presentation/widgets/film_watch_overlay.dart';
import 'package:streampath/presentation/widgets/film_continue_card.dart';
import 'package:streampath/presentation/widgets/film_play_icon.dart';
import 'package:streampath/presentation/widgets/sp_menu.dart';
import 'package:streampath/data/models/media_library_item.dart';

import 'helpers/shell_test_app_state.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory temp;
  late _ServerTestAppState app;
  late FilmCatalogController catalog;
  late PlaybackProgressService progress;
  late List<FilmWork> works;

  Future<void> prepare(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('film_detail_artwork_');
      final config = StreamPathConfigStore.forPath(
        p.join(temp.path, 'config.json'),
      );
      progress = await PlaybackProgressService.open(
        inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      app = _ServerTestAppState(
        configStore: config,
        playbackHistoryStore: PlaybackHistoryStore.forPath(
          p.join(temp.path, 'history.json'),
        ),
        mediaLibraryStore: MediaLibraryStore.forPath(
          p.join(temp.path, 'records.json'),
        ),
        progressService: progress,
      );
      catalog = await app.getFilmCatalog();
      final rootId = await catalog.store.addRoot(
        sourceId: 'local:fixture',
        kind: MediaSourceKind.local,
        path: '',
        type: FilmMediaType.movie,
        name: 'Fixture',
      );
      final root = (await catalog.store.root(rootId))!;
      final generation = await catalog.store.beginScan(rootId);
      await catalog.store.stage(root, generation, [
        for (var i = 0; i < 3; i++)
          FilmScanEntry(
            path: '$i.mkv',
            parentPath: '',
            name: '$i.mkv',
            mediaKind: 'video',
          ),
      ]);
      await catalog.store.commitScan(
        rootId,
        generation,
        cancelled: () => false,
      );
      final resources = await catalog.store.resources();
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 960, 540),
        Paint()..color = Colors.teal,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(960, 540);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      image.dispose();
      picture.dispose();
      await catalog.images.directory.create(recursive: true);
      for (var i = 0; i < 3; i++) {
        await catalog.store.bind(
          [resources[i]],
          FilmWork(
            type: FilmMediaType.movie,
            tmdbId: i + 1,
            title: 'Film $i',
            originalTitle: 'Film $i',
            overview: '',
            language: 'zh-CN',
            posterPath: '/poster$i.png',
            backdropPath: '/backdrop$i.png',
            metadata: const {'presentation_version': 3},
          ),
        );
        for (final (path, target) in [
          ('/poster$i.png', 'w342'),
          ('/poster$i.png', 'w500'),
          ('/backdrop$i.png', 'original'),
        ]) {
          await File(
            p.join(
              catalog.images.directory.path,
              '${FilmCatalogImageCache.cacheKey(path, target)}.img',
            ),
          ).writeAsBytes(bytes);
          if (target == 'original') {
            await catalog.images.backdropBlurs.get(
              File(
                p.join(
                  catalog.images.directory.path,
                  '${FilmCatalogImageCache.cacheKey(path, target)}.img',
                ),
              ),
            );
          }
        }
      }
      await catalog.refresh();
      works = await catalog.store.works(type: null);
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await tester.runAsync(() async {
        await app.closeTestStores();
        app.dispose();
        await progress.close();
        await temp.delete(recursive: true);
      });
    });
  }

  Widget frame(Widget home) => ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(theme: AppTheme.dark(), home: home),
  );

  Finder backdropImages() => find.descendant(
    of: find.byKey(const Key('film-detail-backdrop')),
    matching: find.byKey(const Key('adaptive-backdrop-sharp')),
  );

  testWidgets('详情提亮后极亮极暗背景仍可阅读真实信息区', (tester) async {
    await prepare(tester);
    final old = works.first;
    const overview =
        'Readable detail overview with a long paragraph. '
        'The scene remains visible while the title and description stay clear. '
        'A second sentence fills the available reading width. '
        'The final sentence checks the right edge of the information column.';
    await tester.runAsync(() async {
      await catalog.store.bind(
        [
          (await catalog.store.resources()).firstWhere(
            (r) => r.workId == old.id,
          ),
        ],
        FilmWork(
          type: old.type,
          tmdbId: old.tmdbId,
          title: old.title,
          originalTitle: 'Original detail title with a long readable name',
          overview: overview,
          language: old.language,
          year: 2020,
          posterPath: old.posterPath,
          backdropPath: old.backdropPath,
          metadata: const {
            'genres': ['Drama', 'Science Fiction'],
            'runtime': 140,
            'presentation_version': 3,
          },
        ),
      );
      await catalog.store.setPreference('spoiler_protection', false);
    });
    final evidence = <Map<String, Object>>[];
    for (final size in [const Size(1920, 1350), const Size(640, 450)]) {
      for (final color in [Colors.white, Colors.black]) {
        await tester.pumpWidget(const SizedBox.shrink());
        PaintingBinding.instance.imageCache.clear();
        final file = (await tester.runAsync(
          () => catalog.images.cached(old.backdropPath!, 'original'),
        ))!;
        await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawRect(Offset.zero & size, Paint()..color = color);
          final picture = recorder.endRecording();
          final image = await picture.toImage(
            size.width.toInt(),
            size.height.toInt(),
          );
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
          picture.dispose();
        });
        var ready = false;
        Object? failure;
        unawaited(
          catalog.images.backdropBlurs
              .get(file)
              .then(
                (_) => ready = true,
                onError: (Object error) {
                  failure = error;
                  ready = true;
                },
              ),
        );
        for (var wait = 0; !ready && wait < 600; wait++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(failure, isNull);
        expect(ready, isTrue);
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          frame(
            RepaintBoundary(
              key: boundaryKey,
              child: FilmDetailPage(
                catalog: catalog,
                workId: old.id,
                onOpenItem: (_) async {},
              ),
            ),
          ),
        );
        await settle(tester);
        final textRows = <(String, Rect, Color, double)>[];
        for (final label in [
          old.title,
          'Original detail title with a long readable name',
          'Drama · Science Fiction',
          overview,
        ]) {
          final finder = find.text(label).first;
          final element = tester.element(finder);
          final text = element.widget as Text;
          final style = DefaultTextStyle.of(element).style.merge(text.style);
          final rect = tester.getRect(finder);
          final painter = TextPainter(
            text: TextSpan(text: label, style: style),
            textDirection: TextDirection.ltr,
            maxLines: text.maxLines,
            ellipsis: text.overflow == TextOverflow.ellipsis ? '…' : null,
          )..layout(maxWidth: rect.width);
          for (final line in painter.computeLineMetrics()) {
            textRows.add((
              label,
              Rect.fromLTWH(
                rect.left + line.left,
                rect.top + line.baseline - line.ascent,
                line.width,
                line.height,
              ),
              style.color!,
              style.fontSize!,
            ));
          }
          painter.dispose();
        }
        final colors = {for (final row in textRows) row.$3};
        expect(colors, hasLength(1));
        expect([Colors.black, Colors.white], contains(colors.single));
        final backgroundKey = tester
            .widget<AdaptiveFilmBackdrop>(find.byType(AdaptiveFilmBackdrop))
            .textColors!
            .backgroundKey;
        final data = (await tester.runAsync(() async {
          final image =
              await (backgroundKey.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          return bytes;
        }))!;
        for (final (label, bounds, foreground, fontSize) in textRows) {
          final rect = bounds.intersect(const Rect.fromLTWH(0, 0, 1280, 900));
          if (rect.isEmpty) continue;
          var minimum = double.infinity;
          for (var y = rect.top + 2; y < rect.bottom - 2; y += 4) {
            for (var x = rect.left + 2; x < rect.right - 2; x += 4) {
              final offset = (y.floor() * 1280 + x.floor()) * 4;
              final background = Color.fromARGB(
                255,
                data.getUint8(offset),
                data.getUint8(offset + 1),
                data.getUint8(offset + 2),
              );
              final a = Color.alphaBlend(
                    foreground,
                    background,
                  ).computeLuminance(),
                  b = background.computeLuminance();
              final contrast = a > b
                  ? (a + .05) / (b + .05)
                  : (b + .05) / (a + .05);
              if (contrast < minimum) minimum = contrast;
            }
          }
          evidence.add({
            'size': size.toString(),
            'color': color.toString(),
            'label': label,
            'contrast': minimum,
          });
          expect(
            minimum,
            greaterThanOrEqualTo(fontSize >= 24 ? 3 : 4.5),
            reason: 'Detail: $size, $color, $label',
          );
        }
      }
    }
    await tester.runAsync(() async {
      final file = File(
        'build/adaptive-background/brightness-followup/detail-contrast.json',
      );
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(evidence));
    });
  });

  testWidgets('portrait progress bottom pixels do not depend on poster color', (
    tester,
  ) async {
    await prepare(tester);
    final pair = works.take(2).toList();
    await tester.runAsync(() async {
      final resources = await catalog.store.resources();
      for (final work in pair) {
        final resource = resources.singleWhere((r) => r.workId == work.id);
        await catalog.store.recordVideoProgress(
          VideoProgressUpdate(
            sourceId: resource.sourceId,
            path: resource.path,
            positionMs: 50,
            durationMs: 100,
            recordedAt: DateTime.now(),
          ),
        );
      }
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.white, BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(342, 513);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await (await catalog.images.cached(
        pair.last.posterPath!,
        'w342',
      ))!.writeAsBytes(bytes.buffer.asUint8List());
      image.dispose();
      picture.dispose();
    });
    final keys = [GlobalKey(), GlobalKey()];
    for (final dpr in [1.0, 1.25, 1.5]) {
      tester.view.devicePixelRatio = dpr;
      for (final width in [174.5, 181.0, 210.5]) {
        await tester.pumpWidget(
          frame(
            Scaffold(
              body: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < pair.length; i++)
                    RepaintBoundary(
                      key: keys[i],
                      child: SizedBox(
                        width: width,
                        height: 350,
                        child: FilmWorkCard(
                          store: catalog.store,
                          work: pair[i],
                          cache: catalog.images,
                          onTap: () {},
                          onMenu: (_) {},
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
        await settle(tester);
        final progressRect = tester.getRect(
          find.byType(LinearProgressIndicator).first,
        );
        final pixels = <ByteData>[];
        var imageWidth = 0;
        for (final key in keys) {
          final image = await tester.runAsync(
            () =>
                (key.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: dpr),
          );
          imageWidth = image!.width;
          pixels.add(
            (await tester.runAsync(
              () async =>
                  (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!,
            ))!,
          );
          image.dispose();
        }
        final lastRow = (progressRect.bottom * dpr).floor();
        for (var x = (30 * dpr).ceil(); x < ((width - 30) * dpr).floor(); x++) {
          for (var channel = 0; channel < 3; channel++) {
            final offset = (lastRow * imageWidth + x) * 4 + channel;
            expect(
              pixels[0].getUint8(offset),
              closeTo(pixels[1].getUint8(offset), 1),
              reason:
                  'poster leaking at dpr=$dpr width=$width x=$x row=$lastRow',
            );
          }
        }
      }
    }
  });

  testWidgets(
    'spoiler mode retains main artwork and uses one overview reveal action',
    (tester) async {
      await prepare(tester);
      await tester.runAsync(() async {
        await catalog.store.bind(
          [(await catalog.store.resources()).first],
          FilmWork(
            type: FilmMediaType.movie,
            tmdbId: works.first.tmdbId,
            title: works.first.title,
            originalTitle: works.first.originalTitle,
            overview: 'Secret overview',
            language: 'zh-CN',
            posterPath: works.first.posterPath,
            backdropPath: works.first.backdropPath,
          ),
        );
        await catalog.store.setPreference('spoiler_protection', true);
      });
      await tester.pumpWidget(
        frame(
          FilmDetailPage(
            catalog: catalog,
            workId: works.first.id,
            onOpenItem: (_) async {},
          ),
        ),
      );
      await settle(tester);
      expect(
        find.ancestor(
          of: find.text('Secret overview'),
          matching: find.byType(ImageFiltered),
        ),
        findsOneWidget,
      );
      expect(find.text('展示剧透'), findsOneWidget);
      expect(find.text('展开简介'), findsNothing);
      for (final key in ['film-detail-poster', 'film-detail-backdrop']) {
        expect(
          find.ancestor(
            of: find.byKey(Key(key)),
            matching: find.byType(ImageFiltered),
          ),
          findsNothing,
        );
      }
      await tester.tap(find.text('展示剧透'));
      await tester.pump();
      expect(
        find.ancestor(
          of: find.text('Secret overview'),
          matching: find.byType(ImageFiltered),
        ),
        findsNothing,
      );
      expect(find.text('展示剧透'), findsNothing);
      expect(find.text('展开简介'), findsOneWidget);
    },
  );

  testWidgets(
    'collection and person pages share library layout and background updates',
    (tester) async {
      await prepare(tester);
      final collectionId = (await tester.runAsync(() async {
        final id = await catalog.store.createCollection('Fixture collection');
        await catalog.store.addCollectionMember(id, works.first.id);
        return id;
      }))!;
      final collections = (await tester.runAsync(
        () => catalog.store.collections(customOnly: true),
      ))!;
      final files = (await tester.runAsync(
        () async => [
          (await catalog.images.cached(works[0].backdropPath!, 'original'))!,
          (await catalog.images.cached(works[1].backdropPath!, 'original'))!,
        ],
      ))!;
      for (final isCollection in [true, false]) {
        await tester.runAsync(() async {
          await catalog.store.setBackgroundPath(files.first.path);
          await catalog.refresh();
        });
        await tester.pumpWidget(
          frame(
            FilmRelatedPage(
              key: ValueKey(isCollection),
              catalog: catalog,
              title: 'Related',
              collection: isCollection
                  ? collections.singleWhere((c) => c.id == collectionId)
                  : null,
              personId: isCollection ? null : 'tmdb:999',
              sidebarInset: 72,
              onOpenItem: (_) async {},
            ),
          ),
        );
        await settle(tester);
        expect(tester.getTopLeft(find.byType(AppBar)).dx, 72);
        final bar = tester.widget<AppBar>(find.byType(AppBar));
        expect(bar.toolbarHeight, 48);
        expect(bar.backgroundColor, Colors.transparent);
        expect(bar.shape, const Border());
        expect((bar.title! as Text).data, 'Related');
        expect((bar.title! as Text).style, isNull);
        expect(find.text('Related'), findsOneWidget);
        expect(find.text('主页'), findsOneWidget);
        expect(find.text('重命名'), findsNothing);
        expect(find.text('修改图片'), findsNothing);
        expect(find.text('删除合集'), findsNothing);
        expect(find.byType(FilmPosterGrid), findsOneWidget);
        expect(
          tester
              .widget<FilmLibraryBackground>(find.byType(FilmLibraryBackground))
              .file!
              .path,
          files.first.path,
        );
        await tester.runAsync(() async {
          await catalog.store.setBackgroundPath(files.last.path);
          await catalog.refresh();
        });
        await settle(tester);
        expect(
          tester
              .widget<FilmLibraryBackground>(find.byType(FilmLibraryBackground))
              .file!
              .path,
          files.last.path,
        );
      }
    },
  );

  testWidgets(
    'collections show all opens the immersive showcase with selected artwork',
    (tester) async {
      await prepare(tester);
      await tester.runAsync(() async {
        final id = await catalog.store.createCollection(
          'All collections fixture',
        );
        await catalog.store.addCollectionMember(id, works.first.id);
        await catalog.store.setBackgroundPath(
          (await catalog.images.cached(
            works[0].backdropPath!,
            'original',
          ))!.path,
        );
        await catalog.refresh();
      });
      await tester.pumpWidget(
        frame(FilmLibraryPage(sidebarInset: 72, onOpenItem: (_) async {})),
      );
      await settle(tester);
      final shelf = find.byWidgetPredicate(
        (w) => w is FilmShelf && w.title == '合集',
      );
      final all = find.descendant(of: shelf, matching: find.text('查看全部'));
      await tester.ensureVisible(all);
      await tester.tap(all);
      await settle(tester);
      expect(find.byType(AppBar), findsNothing);
      expect(find.byType(FilmFeaturedPage), findsOneWidget);
      expect(find.byType(FilmFeaturedShowcase), findsOneWidget);
      expect(find.byType(FilmDetailBackButton), findsOneWidget);
      final selectedBackdrop = tester
          .widget<FilmDetailBackdrop>(find.byType(FilmDetailBackdrop))
          .path;
      expect(selectedBackdrop, works.first.backdropPath);
      expect(
        find.descendant(
          of: find.byType(FilmFeaturedShowcase),
          matching: find.byType(FilmPosterHover),
        ),
        findsOneWidget,
      );
      final newBackground = (await tester.runAsync(
        () => catalog.images.cached(works[1].backdropPath!, 'original'),
      ))!;
      await tester.runAsync(() async {
        await catalog.store.setBackgroundPath(newBackground.path);
        await catalog.refresh();
      });
      await settle(tester);
      expect(find.byType(FilmLibraryBackground), findsNothing);
      expect(
        tester.widget<FilmDetailBackdrop>(find.byType(FilmDetailBackdrop)).path,
        selectedBackdrop,
      );
      await tester.tap(find.text('查看合集'));
      await settle(tester);
      expect(find.byType(FilmPosterGrid), findsNothing);
      expect(find.byType(FilmFeaturedShowcase), findsOneWidget);
      expect(find.byType(FilmSegmentedControl<String>), findsNothing);
      expect(find.byType(FilmLibraryBackground), findsNothing);
      expect(
        tester
            .widget<FilmFeaturedShowcase>(find.byType(FilmFeaturedShowcase))
            .works!
            .single
            .id,
        works.first.id,
      );
      await tester.tap(find.byKey(const ValueKey('featured-open')));
      await settle(tester);
      expect(find.byType(FilmDetailPage), findsOneWidget);
      Navigator.of(tester.element(find.byType(FilmDetailPage))).pop();
      await settle(tester);
      expect(find.byType(FilmFeaturedShowcase), findsOneWidget);
      expect(find.byType(FilmSegmentedControl<String>), findsNothing);
      Navigator.of(tester.element(find.byType(FilmFeaturedShowcase))).pop();
      await settle(tester);
      expect(find.text('查看合集'), findsOneWidget);
      Navigator.of(tester.element(find.byType(FilmFeaturedShowcase))).pop();
      await settle(tester);
      expect(find.byType(FilmLibraryPage), findsOneWidget);
      expect(
        tester
            .widget<FilmLibraryBackground>(find.byType(FilmLibraryBackground))
            .file!
            .path,
        newBackground.path,
      );
    },
  );

  testWidgets(
    'source selection shows the cached server library before refresh and shares background',
    (tester) async {
      await prepare(tester);
      await tester.runAsync(() async {
        final config = MediaConnection(
          id: 'jellyfin:fixture',
          kind: MediaSourceKind.jellyfin,
          name: 'Fixture server',
          url: 'http://localhost:8096',
        );
        app.servers.add(config);
        final root = (await catalog.store.serverRoots(
          config,
        ))[FilmMediaType.movie]!;
        final generation = await catalog.store.beginScan(root.id);
        final item = <String, dynamic>{'Id': 'fixture', 'Name': 'Server movie'};
        final work = await catalog.store.saveServerWork(
          config,
          'fixture-server',
          item,
          FilmMediaType.movie,
        );
        await catalog.store.saveServerResources(
          config,
          root,
          generation,
          item,
          work,
        );
        await catalog.store.commitScan(
          root.id,
          generation,
          cancelled: () => false,
        );
        await catalog.store.setBackgroundPath(
          (await catalog.images.cached(
            works.first.backdropPath!,
            'original',
          ))!.path,
        );
        await catalog.refresh();
      });
      await tester.pumpWidget(frame(FilmLibraryPage(onOpenItem: (_) async {})));
      await settle(tester);
      expect(find.text('主影视库'), findsOneWidget);
      final background = tester.element(find.byType(FilmLibraryBackground));
      final backgroundImage = find.descendant(
        of: find.byType(FilmLibraryBackground),
        matching: find.byKey(const Key('adaptive-backdrop-sharp')),
      );
      final decoded = tester.widget<RawImage>(backgroundImage).image;
      expect(decoded, isNotNull);
      final search = tester.state(find.byType(EditableText));
      final selector = tester.state(
        find.byType(SPDropdownButtonFormField<String>),
      );
      final rootFilter = tester.state(
        find.byType(SPDropdownButtonFormField<int>),
      );
      final sortFilter = tester.state(
        find.byType(SPDropdownButtonFormField<bool>),
      );
      final pending = tester.element(
        find.byKey(const ValueKey('film-pending-button')),
      );
      app.catalogGate = Completer<void>();
      await tester.tap(find.text('主影视库'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fixture server').last);
      await tester.pumpAndSettle();
      expect(tester.element(find.byType(FilmLibraryBackground)), background);
      expect(tester.widget<RawImage>(backgroundImage).image, same(decoded));
      expect(tester.state(find.byType(EditableText)), search);
      expect(
        tester.state(find.byType(SPDropdownButtonFormField<String>)),
        selector,
      );
      expect(
        tester.state(find.byType(SPDropdownButtonFormField<int>)),
        rootFilter,
      );
      expect(
        tester.state(find.byType(SPDropdownButtonFormField<bool>)),
        sortFilter,
      );
      expect(
        tester.element(find.byKey(const ValueKey('film-pending-button'))),
        pending,
      );
      app.catalogGate!.complete();
      app.catalogGate = null;
      await settle(tester);
      expect(app.refreshes, 1);
      expect(app.serverRefresh.isCompleted, false);
      expect(
        find.byWidgetPredicate(
          (w) => w is FilmWorkCard && w.work.title == 'Server movie',
        ),
        findsWidgets,
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is FilmWorkCard && w.work.title.startsWith('Film '),
        ),
        findsNothing,
      );
      expect(
        tester
            .widget<FilmLibraryBackground>(find.byType(FilmLibraryBackground))
            .file!
            .path,
        catalog.backgroundFile!.path,
      );
      expect(tester.element(find.byType(FilmLibraryBackground)), background);
      expect(tester.widget<RawImage>(backgroundImage).image, same(decoded));
      expect(tester.state(find.byType(EditableText)), search);
      expect(
        tester.state(find.byType(SPDropdownButtonFormField<String>)),
        selector,
      );
      expect(
        tester.state(find.byType(SPDropdownButtonFormField<int>)),
        rootFilter,
      );
      expect(
        tester.state(find.byType(SPDropdownButtonFormField<bool>)),
        sortFilter,
      );
      expect(
        tester.element(find.byKey(const ValueKey('film-pending-button'))),
        pending,
      );
      app.serverRefresh.complete();
      await settle(tester);
      await tester.tap(
        find
            .descendant(
              of: find.byType(AppBar),
              matching: find.text('Fixture server'),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('主影视库').last);
      await settle(tester);
      expect(
        find.byWidgetPredicate(
          (w) => w is FilmWorkCard && w.work.title.startsWith('Film '),
        ),
        findsWidgets,
      );
      void expectRetained() {
        expect(tester.element(find.byType(FilmLibraryBackground)), background);
        expect(tester.widget<RawImage>(backgroundImage).image, same(decoded));
        expect(tester.state(find.byType(EditableText)), search);
        expect(
          tester.state(find.byType(SPDropdownButtonFormField<String>)),
          selector,
        );
        expect(
          tester.state(find.byType(SPDropdownButtonFormField<int>)),
          rootFilter,
        );
        expect(
          tester.state(find.byType(SPDropdownButtonFormField<bool>)),
          sortFilter,
        );
        expect(
          tester.element(find.byKey(const ValueKey('film-pending-button'))),
          pending,
        );
      }

      void select(String value) => tester
          .widget<SPDropdownButtonFormField<String>>(
            find.byType(SPDropdownButtonFormField<String>),
          )
          .onChanged!(value);
      for (var i = 0; i < 20; i++) {
        app.catalogGate = Completer<void>();
        select('jellyfin:fixture');
        await tester.pump();
        expectRetained();
        if (i.isEven) {
          select('');
          await tester.pump();
        }
        app.catalogGate!.complete();
        app.catalogGate = null;
        await settle(tester);
        expectRetained();
        expect(
          tester
              .widget<SPDropdownButtonFormField<String>>(
                find.byType(SPDropdownButtonFormField<String>),
              )
              .initialValue,
          i.isEven ? '' : 'jellyfin:fixture',
        );
        expect(
          find.byWidgetPredicate(
            (w) => w is FilmWorkCard && w.work.title.startsWith('Film '),
          ),
          i.isEven ? findsWidgets : findsNothing,
        );
        if (i.isOdd) {
          select('');
          await settle(tester);
        }
        expectRetained();
        expect(tester.takeException(), isNull);
      }
      app.catalogFailure = const FileSystemException('Fixture load failure');
      app.catalogGate = Completer<void>();
      select('jellyfin:fixture');
      await tester.pump();
      app.catalogGate!.complete();
      app.catalogGate = null;
      await settle(tester);
      expectRetained();
      expect(find.text('影视目录库操作失败'), findsOneWidget);
      app.catalogFailure = null;
      select('');
      await settle(tester);
      expectRetained();
      expect(find.text('影视目录库操作失败'), findsNothing);
    },
  );

  testWidgets('collection cover menu renames and deletes the collection', (
    tester,
  ) async {
    await prepare(tester);
    await tester.runAsync(() async {
      final id = await catalog.store.createCollection('Menu collection');
      await catalog.store.addCollectionMember(id, works.first.id);
      await catalog.refresh();
    });
    await tester.pumpWidget(frame(FilmLibraryPage(onOpenItem: (_) async {})));
    await settle(tester);
    Future<void> openMenu(String title) async {
      await tester.ensureVisible(find.text(title));
      await tester.pumpAndSettle();
      await tester.tap(find.text(title), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(find.text('重命名'), findsOneWidget);
      expect(find.text('修改图片'), findsOneWidget);
      expect(find.text('删除合集'), findsOneWidget);
    }

    await openMenu('Menu collection');
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Renamed collection');
    await tester.tap(find.text('保存'));
    await settle(tester);
    expect(find.text('Renamed collection'), findsOneWidget);
    await openMenu('Renamed collection');
    await tester.tap(find.text('删除合集'));
    await settle(tester);
    expect(find.text('Renamed collection'), findsNothing);
  });

  testWidgets('分类栏无查看全部，鼠标拖动可访问全部分类并复用海报墙筛选', (tester) async {
    await prepare(tester);
    final work = works.first;
    await tester.runAsync(() async {
      await catalog.store.refreshWork(
        FilmWork(
          id: work.id,
          type: work.type,
          tmdbId: work.tmdbId,
          title: work.title,
          originalTitle: work.originalTitle,
          overview: work.overview,
          language: work.language,
          year: 2024,
          posterPath: work.posterPath,
          backdropPath: work.backdropPath,
          metadata: {
            'genres': [
              for (var i = 0; i < 18; i++)
                'Genre ${i.toString().padLeft(2, '0')}',
            ],
            'origin_country': ['JP'],
          },
        ),
      );
      await catalog.store.setHomeSections(const [
        FilmHomeSection('genres', enabled: true),
        FilmHomeSection('countries', enabled: true),
        FilmHomeSection('years', enabled: true),
        FilmHomeSection('continue'),
        FilmHomeSection('daily'),
        FilmHomeSection('collections'),
        FilmHomeSection('sources'),
        FilmHomeSection('recent'),
        FilmHomeSection('movies'),
        FilmHomeSection('series'),
      ]);
      final original = File(
        p.join(
          catalog.images.directory.path,
          '${FilmCatalogImageCache.cacheKey(work.backdropPath!, 'original')}.img',
        ),
      );
      await original.copy(
        p.join(
          catalog.images.directory.path,
          '${FilmCatalogImageCache.cacheKey(work.backdropPath!, 'w780')}.img',
        ),
      );
      await catalog.refresh();
    });
    await tester.pumpWidget(
      frame(
        FilmLibraryPage(
          onOpenItem: (_) async {},
          continueShelf: const SizedBox.shrink(),
        ),
      ),
    );
    await settle(tester);
    final shelf = find.byWidgetPredicate(
      (w) => w is FilmShelf && w.title == '类型',
    );
    await tester.ensureVisible(shelf);
    await tester.pumpAndSettle();
    final list = tester.widget<ListView>(
      find.descendant(of: shelf, matching: find.byType(ListView)),
    );
    expect(list.semanticChildCount, 18);
    for (final title in ['类型', '地区', '年份']) {
      final categoryShelf = find.byWidgetPredicate(
        (w) => w is FilmShelf && w.title == title,
      );
      expect(
        find.descendant(of: categoryShelf, matching: find.text('查看全部')),
        findsNothing,
      );
    }
    final cover = tester
        .widget<FilmCategoryCard>(
          find
              .descendant(of: shelf, matching: find.byType(FilmCategoryCard))
              .first,
        )
        .category
        .coverPath;
    final shared = tester.widget<DirectoryScrollView>(
      find.descendant(of: shelf, matching: find.byType(DirectoryScrollView)),
    );
    expect(shared.hideScrollbar, isTrue);
    await tester.drag(
      shelf,
      const Offset(-10000, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(
      shared.controller!.offset,
      shared.controller!.position.maxScrollExtent,
    );
    expect(find.text('Genre 17'), findsOneWidget);
    await tester.tap(find.text('Genre 17'));
    await settle(tester);
    expect(catalog.sectionId, 'genre:Genre 17');
    expect(catalog.works.map((w) => w.id), [work.id]);
    await tester.tap(find.text('主页'));
    await settle(tester);
    await tester.drag(
      shelf,
      const Offset(10000, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilmCategoryCard>(
            find
                .descendant(of: shelf, matching: find.byType(FilmCategoryCard))
                .first,
          )
          .category
          .coverPath,
      cover,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'continue artwork and watch overlay fill the card cover without inset gaps',
    (tester) async {
      await prepare(tester);
      final resource = (await tester.runAsync(
        () => catalog.store.resources(),
      ))!.first;
      for (final poster in [false, true]) {
        await tester.pumpWidget(
          frame(
            Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: poster ? 212 : FilmContinueCard.landscapeWidth,
                  height: poster ? 400 : FilmContinueCard.landscapeHeight,
                  child: FilmContinueCard(
                    catalog: catalog,
                    record: MediaLibraryRecord(
                      item: resource.playbackItem,
                      updatedAt: DateTime.now(),
                    ),
                    onTap: () {},
                    poster: poster,
                  ),
                ),
              ),
            ),
          ),
        );
        await settle(tester);
        final artwork = tester.getRect(find.byType(FilmArtwork));
        final card = tester.getRect(find.byType(FilmContinueCard));
        expect(artwork.left, closeTo(card.left, 1e-9));
        expect(artwork.top, closeTo(card.top, 1e-9));
        expect(artwork.width, closeTo(card.width, 1e-9));
        expect(artwork, tester.getRect(find.byType(FilmWatchOverlay)));
        final info = tester.getRect(
          find
              .descendant(
                of: find.byType(FilmContinueCard),
                matching: find.byType(Padding),
              )
              .last,
        );
        expect(artwork.bottom, closeTo(info.top, 1e-9));
        expect(tester.widget<Card>(find.byType(Card)).clipBehavior, Clip.none);
        final surface = find.byType(FilmPosterHoverSurface);
        expect(
          find.descendant(of: surface, matching: find.byType(ClipRRect)),
          findsWidgets,
        );
      }
    },
  );

  testWidgets(
    'episode artwork and overview share one reveal action below the overview',
    (tester) async {
      await prepare(tester);
      final resource = (await tester.runAsync(() async {
        final rootId = await catalog.store.addRoot(
          sourceId: 'local:tv-fixture',
          kind: MediaSourceKind.local,
          path: 'TV',
          type: FilmMediaType.tv,
          name: 'TV fixture',
        );
        final root = (await catalog.store.root(rootId))!;
        final generation = await catalog.store.beginScan(rootId);
        await catalog.store.stage(root, generation, [
          const FilmScanEntry(
            path: 'TV/E1.mkv',
            parentPath: 'TV',
            name: 'E1.mkv',
            mediaKind: 'video',
          ),
        ]);
        await catalog.store.commitScan(
          rootId,
          generation,
          cancelled: () => false,
        );
        final resource = (await catalog.store.resources(rootId: rootId)).single;
        await catalog.store.bind(
          [resource],
          FilmWork(
            type: FilmMediaType.tv,
            tmdbId: 777,
            title: 'TV fixture',
            originalTitle: 'TV fixture',
            overview: '',
            language: 'en',
            posterPath: works.first.posterPath,
          ),
        );
        final bound = (await catalog.store.resources()).firstWhere(
          (r) => r.id == resource.id,
        );
        await catalog.store.mapEpisodes({bound: (1, 1)});
        await catalog.store.setPreference('spoiler_protection', true);
        final original = (await catalog.images.cached(
          works.first.backdropPath!,
          'original',
        ))!;
        await original.copy(
          p.join(
            catalog.images.directory.path,
            '${FilmCatalogImageCache.cacheKey('/still.png', 'w300')}.img',
          ),
        );
        return (await catalog.store.resources()).firstWhere(
          (r) => r.id == resource.id,
        );
      }))!;
      for (final overview in ['', 'Secret episode overview']) {
        var menuCalls = 0;
        await tester.pumpWidget(
          frame(
            Scaffold(
              body: FilmSpoilerScope(
                key: ValueKey(overview),
                child: SizedBox(
                  width: 300,
                  child: Column(
                    children: [
                      Expanded(
                        child: FilmEpisodeCard(
                          resource: resource,
                          catalog: catalog,
                          state: '可用',
                          onOpenItem: (_) async {},
                          onChanged: () async {},
                          episode: {
                            'name': 'Episode',
                            'still_path': '/still.png',
                            'overview': overview,
                          },
                        ),
                      ),
                      SizedBox(
                        height: FilmContinueCard.landscapeHeight,
                        child: FilmContinueCard(
                          catalog: catalog,
                          record: MediaLibraryRecord(
                            item: resource.playbackItem,
                            updatedAt: DateTime.now(),
                          ),
                          onTap: () {},
                          onMenu: (_) => menuCalls++,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await settle(tester);
        expect(find.text('展示封面'), findsOneWidget);
        expect(find.text('展示剧透'), findsNothing);
        expect(find.byType(ImageFiltered), findsNWidgets(3));
        for (final element in find.byType(ImageFiltered).evaluate()) {
          final filter = find.byWidget(element.widget);
          final clip = find
              .ancestor(of: filter, matching: find.byType(ClipRect))
              .first;
          expect(tester.getRect(clip), tester.getRect(filter));
        }
        final continuationMenu = find.descendant(
          of: find.byType(FilmContinueCard),
          matching: find.byTooltip('更多操作'),
        );
        expect(
          find.ancestor(
            of: find.byType(FilmPlayIcon),
            matching: find.byType(ImageFiltered),
          ),
          findsNothing,
        );
        expect(
          find.ancestor(
            of: continuationMenu,
            matching: find.byType(ImageFiltered),
          ),
          findsNothing,
        );
        await tester.tap(continuationMenu);
        await tester.pump();
        expect(menuCalls, 1);
        await tester.tap(find.text('展示封面'));
        await tester.pump();
        expect(find.byType(ImageFiltered), findsNothing);
        expect(find.text('展示封面'), findsNothing);
      }
    },
  );

  testWidgets('首页背景淘汰后返回保留首帧，候选加载失败保留已显示图', (tester) async {
    await prepare(tester);
    final file = (await tester.runAsync(
      () => catalog.images.cached(works.first.backdropPath!, 'original'),
    ))!;
    late BuildContext homeContext;
    await tester.pumpWidget(
      frame(
        Builder(
          builder: (context) {
            homeContext = context;
            return FilmLibraryBackground(cache: catalog.images, file: file);
          },
        ),
      ),
    );
    await settle(tester);
    final original = tester
        .widget<RawImage>(find.byKey(const Key('adaptive-backdrop-sharp')))
        .image;
    expect(original, isNotNull);
    for (var i = 0; i < 20; i++) {
      Navigator.of(homeContext).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Child')),
        ),
      );
      await tester.pumpAndSettle();
      PaintingBinding.instance.imageCache.clear();
      Navigator.of(homeContext).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(
        tester
            .widget<RawImage>(find.byKey(const Key('adaptive-backdrop-sharp')))
            .image,
        isNotNull,
      );
      await settle(tester);
    }
    await tester.pumpWidget(
      frame(
        Builder(
          builder: (_) => FilmLibraryBackground(
            cache: catalog.images,
            file: File(p.join(temp.path, 'missing-background.png')),
          ),
        ),
      ),
    );
    expect(
      tester
          .widget<RawImage>(find.byKey(const Key('adaptive-backdrop-sharp')))
          .image,
      same(original),
    );
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('影片详情复用目录滚动条，滚轮在条边和正文只滚动一次', (tester) async {
    await prepare(tester);
    tester.view.physicalSize = const Size(1280, 640);
    await tester.pumpWidget(
      frame(
        FilmDetailPage(
          catalog: catalog,
          workId: works.first.id,
          initialWork: works.first,
          onOpenItem: (_) async {},
        ),
      ),
    );
    await settle(tester);
    final list = find.byKey(const Key('film-detail-scroll'));
    final shared = find.ancestor(
      of: list,
      matching: find.byType(DirectoryScrollView),
    );
    expect(shared, findsOneWidget);
    final controller = tester.widget<ListView>(list).controller!;
    final rect = tester.getRect(shared);
    for (final x in [rect.right - 2, rect.left + 400]) {
      final before = controller.offset;
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      final location = Offset(x, rect.top + 80);
      await tester.sendEventToBinding(pointer.hover(location));
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: location,
          scrollDelta: const Offset(0, 30),
        ),
      );
      await tester.pump();
      expect(controller.offset, before + 30);
    }
    expect(tester.takeException(), isNull);
  });

  for (final dpr in [1.0, 2.0]) {
    testWidgets('已解码背景在首帧复用同一缓存键 DPR=$dpr', (tester) async {
      await prepare(tester);
      tester.view.devicePixelRatio = dpr;
      final file = (await tester.runAsync(
        () => catalog.images.cached(works.first.backdropPath!, 'original'),
      ))!;
      final provider = filmArtworkProvider(
        file,
        target: 'original',
        backdrop: true,
        devicePixelRatio: dpr,
      );
      await decode(tester, provider);
      final before = PaintingBinding.instance.imageCache.currentSizeBytes;
      await tester.pumpWidget(
        frame(
          AdaptiveFilmBackdrop(
            cache: catalog.images,
            path: works.first.backdropPath,
          ),
        ),
      );
      final images = tester
          .widgetList<RawImage>(
            find.byKey(const Key('adaptive-backdrop-sharp')),
          )
          .toList();
      expect(images, hasLength(1));
      expect(images.every((image) => image.image != null), isTrue);
      expect(images.single.image!.width, 960);
      expect(images.single.scale, dpr);
      expect(PaintingBinding.instance.imageCache.currentSizeBytes, before);
    });
  }

  testWidgets('自定义主页背景在切页和返回中保持原帧，轻壳没有顶栏或占位块', (tester) async {
    await prepare(tester);
    await tester.runAsync(() async {
      final background = await catalog.images.cached(
        works.first.backdropPath!,
        'original',
      );
      await catalog.store.setBackgroundPath(background!.path);
      await catalog.refresh();
    });
    const frameKey = Key('library-transition-frame');
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          theme: AppTheme.dark().copyWith(platform: TargetPlatform.windows),
          builder: (_, child) => RepaintBoundary(key: frameKey, child: child!),
          home: const FilmLibraryShell(sidebarInset: 64),
        ),
      ),
    );
    await settle(tester);
    final background = find.byType(FilmLibraryBackground);
    expect(background, findsOneWidget);
    final element = tester.element(background);
    final sharp = find.descendant(
      of: background,
      matching: find.byKey(const Key('adaptive-backdrop-sharp')),
    );
    final decoded = tester.widget<RawImage>(sharp).image;
    expect(decoded, isNotNull);
    Future<List<int>> pixel() async => (await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(frameKey),
      );
      final image = await boundary.toImage();
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List();
      final offset = (450 * image.width + 5) * 4;
      final result = data.sublist(offset, offset + 4);
      image.dispose();
      return result;
    }))!;
    final baseline = await pixel();
    PaintingBinding.instance.imageCache.clear();
    Future<void> checkFrames(int count) async {
      for (var frame = 0; frame < count; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.element(background), same(element));
        expect(tester.widget<RawImage>(sharp).image, same(decoded));
        final current = await pixel();
        for (var channel = 0; channel < 4; channel++) {
          expect(current[channel], closeTo(baseline[channel], 2));
        }
      }
    }

    await tester.tap(find.byType(FilmWorkCard).first);
    await tester.pump();
    await checkFrames(12);
    final shell = tester.widget<Scaffold>(
      find.descendant(
        of: find.byType(StreamPathPageShell),
        matching: find.byType(Scaffold),
      ),
    );
    expect(shell.appBar, isNull);
    expect(shell.body, isNull);
    expect(shell.backgroundColor, Colors.transparent);
    expect(find.byType(FilmDetailPage), findsNothing);
    await settle(tester);
    Navigator.of(tester.element(find.byType(FilmDetailPage))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 64));
    await checkFrames(8);
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击立即导航，轻壳后加载原图且首张背景静态显示', (tester) async {
    await prepare(tester);
    await tester.pumpWidget(frame(FilmLibraryPage(onOpenItem: (_) async {})));
    await settle(tester);
    final card = find.byType(FilmWorkCard).first;
    final work = tester.widget<FilmWorkCard>(card).work;
    final background = File(
      p.join(
        catalog.images.directory.path,
        '${FilmCatalogImageCache.cacheKey(work.backdropPath!, 'original')}.img',
      ),
    );
    expect(
      PaintingBinding.instance.imageCache
          .statusForKey(
            filmArtworkProvider(background, target: 'original', backdrop: true),
          )
          .untracked,
      isTrue,
    );
    // 使用生产 Windows 路由契约，正文在结束帧后挂载。
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          theme: AppTheme.dark().copyWith(platform: TargetPlatform.windows),
          home: FilmLibraryPage(onOpenItem: (_) async {}),
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.byType(FilmWorkCard).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(StreamPathPageShell), findsOneWidget);
    expect(find.byType(FilmDetailPage), findsNothing);
    expect(backdropImages(), findsNothing);
    await settle(tester);
    final images = tester.widgetList<RawImage>(backdropImages()).toList();
    expect(images, hasLength(1));
    expect(images.single.image!.width, 960);
    final transitions = tester
        .widgetList<AnimatedBuilder>(
          find.descendant(
            of: find.byKey(const Key('film-detail-backdrop')),
            matching: find.byType(AnimatedBuilder),
          ),
        )
        .map((w) => w.animation)
        .whereType<AnimationController>();
    expect(transitions.every((animation) => animation.value == 1), isTrue);
    final actual = tester.widgetList<Image>(
      find.descendant(
        of: find.byKey(const Key('film-detail-backdrop')),
        matching: find.byType(Image),
      ),
    );
    expect(actual.every((image) => image.image is FileImage), isTrue);
    expect(find.byKey(const Key('film-detail-scroll')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final focus in [false, true]) {
    testWidgets('${focus ? '键盘焦点' : '鼠标悬停'}不预解码下一页背景，切页完成后才加载', (tester) async {
      await prepare(tester);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: app,
          child: MaterialApp(
            theme: AppTheme.dark().copyWith(platform: TargetPlatform.windows),
            home: FilmLibraryPage(onOpenItem: (_) async {}),
          ),
        ),
      );
      await settle(tester);
      final card = find.byType(FilmWorkCard).first;
      final work = tester.widget<FilmWorkCard>(card).work;
      if (focus) {
        Focus.of(
          tester.element(
            find.descendant(of: card, matching: find.byType(FilmArtwork)).first,
          ),
        ).requestFocus();
        await tester.pump();
      } else {
        final mouse = await tester.createGesture(
          kind: ui.PointerDeviceKind.mouse,
        );
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(tester.getCenter(card));
        addTearDown(mouse.removePointer);
      }
      await settle(tester);
      final file = File(
        p.join(
          catalog.images.directory.path,
          '${FilmCatalogImageCache.cacheKey(work.backdropPath!, 'original')}.img',
        ),
      );
      final provider = filmArtworkProvider(
        file,
        target: 'original',
        backdrop: true,
      );
      expect(
        PaintingBinding.instance.imageCache.statusForKey(provider).untracked,
        isTrue,
      );
      await tester.tap(card);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(StreamPathPageShell), findsOneWidget);
      expect(find.byType(FilmDetailPage), findsNothing);
      expect(
        PaintingBinding.instance.imageCache.statusForKey(provider).untracked,
        isTrue,
      );
      await settle(tester);
      final route = ModalRoute.of(tester.element(find.byType(FilmDetailPage)))!;
      expect(route, isA<MaterialPageRoute<void>>());
      expect(route.transitionDuration, const Duration(milliseconds: 220));
      expect(
        PaintingBinding.instance.imageCache.statusForKey(provider).keepAlive,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('20次进入退出不重复解码背景，缓存有界且没有残留监听器', (tester) async {
    await prepare(tester);
    late BuildContext context;
    await tester.pumpWidget(
      frame(
        Builder(
          builder: (value) {
            context = value;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.runAsync(
      () => catalog.images.cached(works.first.backdropPath!, 'original'),
    );
    await settle(tester);
    final cache = PaintingBinding.instance.imageCache;
    final file = catalog.images.knownFile(
      works.first.backdropPath,
      'original',
    )!;
    final provider = filmArtworkProvider(
      file,
      target: 'original',
      backdrop: true,
    );
    final original = await decode(tester, provider);
    final initialBytes = cache.currentSizeBytes;
    int? settledBytes;
    for (var i = 0; i < 20; i++) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => FilmDetailPage(
            catalog: catalog,
            workId: works.first.id,
            initialWork: works.first,
            onOpenItem: (_) async {},
          ),
        ),
      );
      await tester.pump();
      expect(
        tester
            .widgetList<RawImage>(backdropImages())
            .every((image) => image.image?.isCloneOf(original) ?? false),
        isTrue,
      );
      await settle(tester);
      settledBytes ??= cache.currentSizeBytes;
      expect(cache.currentSizeBytes, settledBytes);
      Navigator.of(context).pop();
      await settle(tester);
    }
    expect(cache.currentSizeBytes, lessThanOrEqualTo(settledBytes!));
    expect(cache.maximumSizeBytes, 100 * 1024 * 1024);
    expect(cache.liveImageCount, 0);
    expect(cache.pendingImageCount, 0);
    expect(find.byType(FilmDetailPage), findsNothing);
    expect(tester.takeException(), isNull);
    stdout.writeln(
      'IMAGE_CACHE_20_CYCLES initial_bytes=$initialBytes final_bytes=${cache.currentSizeBytes} live=${cache.liveImageCount} pending=${cache.pendingImageCount}',
    );
  });

  testWidgets('改变图片路径不保留上一部背景，清理缓存同步废弃文件位置', (tester) async {
    await prepare(tester);
    for (final work in works.take(2)) {
      final file = (await tester.runAsync(
        () => catalog.images.cached(work.backdropPath!, 'original'),
      ))!;
      await decode(
        tester,
        filmArtworkProvider(file, target: 'original', backdrop: true),
      );
    }
    Widget artwork(FilmWork work) => frame(
      AdaptiveFilmBackdrop(cache: catalog.images, path: work.backdropPath),
    );
    await tester.pumpWidget(artwork(works.first));
    await tester.pumpWidget(artwork(works[1]));
    final file = catalog.images.knownFile(works[1].backdropPath, 'original')!;
    await settle(tester);
    expect(
      tester
          .widget<AdaptiveFilmBackdrop>(find.byType(AdaptiveFilmBackdrop))
          .path,
      works[1].backdropPath,
    );
    expect(
      tester
          .widget<RawImage>(find.byKey(const Key('adaptive-backdrop-sharp')))
          .image!
          .width,
      960,
    );
    expect(
      file.path,
      catalog.images.knownFile(works[1].backdropPath, 'original')!.path,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => catalog.images.clear());
    expect(catalog.images.knownFile(works[1].backdropPath, 'original'), isNull);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<ui.Image> decode(
  WidgetTester tester,
  ImageProvider<Object> provider,
) async {
  final result = await tester.runAsync(() async {
    final stream = provider.resolve(ImageConfiguration.empty);
    ui.Image? image;
    final listener = ImageStreamListener(
      (info, _) => image = info.image.clone(),
    );
    stream.addListener(listener);
    while (image == null) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    stream.removeListener(listener);
    return image!;
  });
  addTearDown(result!.dispose);
  return result;
}

class _ServerTestAppState extends ShellTestAppState {
  _ServerTestAppState({
    required super.configStore,
    required super.playbackHistoryStore,
    required super.mediaLibraryStore,
    required super.progressService,
  });
  final servers = <MediaConnection>[];
  final serverRefresh = Completer<void>();
  Completer<void>? catalogGate;
  Object? catalogFailure;
  int refreshes = 0;
  @override
  List<MediaConnection> get mediaConnections => servers;
  @override
  Future<FilmCatalogController> getFilmCatalog() async {
    await catalogGate?.future;
    if (catalogFailure case final failure?) throw failure;
    return super.getFilmCatalog();
  }

  @override
  Future<void> refreshMediaServer(String id, {bool metadata = true}) async {
    refreshes++;
    await serverRefresh.future;
  }
}
