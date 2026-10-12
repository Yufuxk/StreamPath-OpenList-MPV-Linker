import 'dart:convert';
import 'package:streampath/presentation/widgets/adaptive_film_backdrop.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/playback_history_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/local/stream_path_config_store.dart';
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/film_home_section.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/stream_path_config.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/pages/film_featured_page.dart';
import 'package:streampath/presentation/pages/film_library_page.dart';
import 'package:streampath/presentation/pages/film_related_page.dart';
import 'package:streampath/presentation/state/app_state.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/directory_scroll_view.dart';
import 'package:streampath/presentation/widgets/film_detail_backdrop.dart';
import 'package:streampath/presentation/widgets/film_adaptive_foreground.dart';
import 'package:streampath/presentation/widgets/film_artwork.dart';
import 'package:streampath/presentation/widgets/film_detail_buttons.dart';
import 'package:streampath/presentation/widgets/film_segmented_control.dart';
import 'package:streampath/presentation/widgets/film_shelf.dart';
import 'package:streampath/presentation/widgets/film_featured_showcase.dart';
import 'package:streampath/presentation/widgets/film_detail_back_button.dart';
import 'package:streampath/presentation/widgets/film_watch_overlay.dart';

import 'helpers/shell_test_app_state.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory temp;
  late ShellTestAppState app;
  late FilmCatalogController catalog;
  late PlaybackProgressService progress;
  final opened = <int>[], played = <int>[];
  final menus = <String>[];
  late File imageFile;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> prepare(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    opened.clear();
    played.clear();
    menus.clear();
    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('film_featured_test_');
      final config = StreamPathConfigStore.forPath('${temp.path}/config.json');
      await config.save(
        StreamPathConfig(
          localRoots: [
            LocalRootConfig(
              rootId: 'fixture',
              displayName: 'Fixture',
              path: temp.path,
            ),
          ],
        ),
      );
      progress = await PlaybackProgressService.open(
        inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      app = ShellTestAppState(
        configStore: config,
        playbackHistoryStore: PlaybackHistoryStore.forPath(
          '${temp.path}/history.json',
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
        for (var i = 0; i < 12; i++)
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
        const Rect.fromLTWH(0, 0, 120, 180),
        Paint()..color = Colors.teal,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(120, 180);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      image.dispose();
      picture.dispose();
      imageFile = await File('${temp.path}/image.png').writeAsBytes(bytes);
      await catalog.images.directory.create(recursive: true);
      for (var i = 0; i < resources.length; i++) {
        await catalog.store.bind(
          [resources[i]],
          FilmWork(
            type: FilmMediaType.movie,
            tmdbId: i + 1,
            title: 'Fixture film $i',
            originalTitle: 'Fixture film $i',
            overview: 'Overview $i',
            language: 'zh-CN',
            year: 2020 + i,
            posterPath: '/poster$i.png',
            backdropPath: '/backdrop$i.png',
            metadata: const {
              'runtime': 120,
              'vote_average': 8.2,
              'genres': [
                {'name': 'Drama'},
              ],
            },
          ),
        );
        for (final (path, target) in [
          ('/poster$i.png', 'w342'),
          ('/backdrop$i.png', 'original'),
        ]) {
          await File(
            '${catalog.images.directory.path}/${FilmCatalogImageCache.cacheKey(path, target)}.img',
          ).writeAsBytes(bytes);
        }
      }
      final works = await catalog.store.works(type: null);
      for (var i = 0; i < 2; i++) {
        final id = await catalog.store.createCollection('Collection $i');
        await catalog.store.addCollectionMember(id, works[i].id);
      }
      await catalog.refresh();
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

  Widget frame(
    Widget child, {
    AppLanguage language = AppLanguage.simplifiedChinese,
    bool dark = true,
    bool glass = false,
    double scale = 1,
  }) => ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      theme: dark ? AppTheme.dark(glass: glass) : AppTheme.light(glass: glass),
      locale: language.locale,
      supportedLocales: AppLanguage.values.map((v) => v.locale),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: child,
    ),
  );
  Widget showcase({String section = 'daily', List<FilmWork>? works}) =>
      Scaffold(
        body: FilmFeaturedShowcase(
          catalog: catalog,
          initialSection: section,
          works: works,
          onOpenWork: (w) => opened.add(w.id),
          onPlayWork: (w) => played.add(w.id),
          onOpenCollection: (c) => menus.add('open:${c.id}'),
          onWorkMenu: (w, _) => menus.add('work:${w.id}'),
          onCollectionMenu: (c, _) => menus.add(c.id),
        ),
      );
  Finder poster(Object id) =>
      find.byKey(ValueKey<Object>(('featured-poster', id)));

  testWidgets('浅色橱窗缺图时使用主题文字，已有背景清空后恢复主题文字', (tester) async {
    await prepare(tester);
    final works = catalog.sectionWorks['daily']!;
    final original = works.first;
    final missing = FilmWork(
      id: original.id,
      type: original.type,
      title: original.title,
      originalTitle: original.originalTitle,
      overview: original.overview,
      language: original.language,
      posterPath: original.posterPath,
    );
    final ready = works[1];
    await tester.pumpWidget(
      frame(showcase(works: [missing, ready]), dark: false),
    );
    await settle(tester);
    Color titleColor(int id) => tester
        .widget<Text>(find.byKey(ValueKey<Object>(('featured-title', id))))
        .style!
        .color!;
    final themeColor = AppTheme.light().colorScheme.onSurface;
    expect(titleColor(missing.id), themeColor);
    await tester.tap(poster(ready.id));
    await tester.pump();
    for (var i = 0; i < 12 && titleColor(ready.id) != Colors.white; i++) {
      await settle(tester);
    }
    expect(titleColor(ready.id), Colors.white);
    await tester.tap(poster(missing.id));
    await settle(tester);
    expect(titleColor(missing.id), themeColor);
    expect(tester.takeException(), isNull);
  });

  testWidgets('六类背景验证橱窗固定白字、无取色链路与对称阴影', (tester) async {
    await prepare(tester);
    await tester.runAsync(
      () => catalog.store.setPreference('spoiler_protection', false),
    );
    await settle(tester);
    final work = catalog.sectionWorks['daily']!.first;
    final evidence = Directory(
      'build/film-featured/remove-auto-color/readability',
    );
    await tester.runAsync(() => evidence.create(recursive: true));
    final rows = <Map<String, Object>>[];
    for (final viewport in [const Size(1280, 720), const Size(480, 720)]) {
      tester.view.physicalSize = viewport;
      for (final extended in [false, true]) {
        final sourceSize = viewport * (extended ? .7 : 1.5);
        for (final pattern in [
          'white',
          'black',
          'yellow',
          'colors',
          'checker',
          'texture',
        ]) {
          await tester.pumpWidget(const SizedBox.shrink());
          PaintingBinding.instance.imageCache.clear();
          final file = File(
            '${catalog.images.directory.path}/${FilmCatalogImageCache.cacheKey(work.backdropPath!, 'original')}.img',
          );
          await tester.runAsync(() async {
            final recorder = ui.PictureRecorder();
            final canvas = Canvas(recorder);
            final bounds = Offset.zero & sourceSize;
            canvas.drawRect(
              bounds,
              Paint()
                ..color = switch (pattern) {
                  'black' => Colors.black,
                  'yellow' => Colors.yellow,
                  _ => Colors.white,
                },
            );
            if (pattern == 'colors' ||
                pattern == 'checker' ||
                pattern == 'texture') {
              final step = pattern == 'texture' ? 9.0 : 48.0;
              for (var y = 0.0; y < sourceSize.height; y += step) {
                for (var x = 0.0; x < sourceSize.width; x += step) {
                  final index = (x / step).floor() + (y / step).floor();
                  final colors = pattern == 'colors'
                      ? [Colors.yellow, Colors.cyan, Colors.pink, Colors.lime]
                      : [Colors.white, Colors.black];
                  canvas.drawRect(
                    Rect.fromLTWH(x, y, step, step),
                    Paint()..color = colors[index % colors.length],
                  );
                }
              }
            }
            final picture = recorder.endRecording();
            final image = await picture.toImage(
              sourceSize.width.toInt(),
              sourceSize.height.toInt(),
            );
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            if (viewport.width == 1280 && !extended) {
              await file.copy('${evidence.path}/background-$pattern.png');
            }
            image.dispose();
            picture.dispose();
          });
          if (extended) {
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
          }
          for (final dark in [true, false]) {
            final boundary = GlobalKey();
            await tester.pumpWidget(
              frame(
                RepaintBoundary(key: boundary, child: showcase()),
                dark: dark,
              ),
            );
            for (var wait = 0; wait < 24; wait++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pump(const Duration(milliseconds: 50));
            }
            expect(
              find.byKey(const Key('adaptive-backdrop-sharp')),
              findsOneWidget,
            );
            final textRows = <(String, Rect, Color, double, Color?)>[];
            final informationRects = <Rect>[];
            final informationColors = <Color>{};
            final inkRecorder = ui.PictureRecorder();
            final inkCanvas = Canvas(inkRecorder);
            for (final finder in [
              find.byKey(ValueKey<Object>(('featured-title', work.id))),
              find.text(work.overview),
              find.text('播放'),
              find.text('查看详情'),
              find.text('每日精选'),
              find.text('合集'),
              find.byWidgetPredicate(
                (w) => w is Text && (w.data?.contains('官方时长') ?? false),
              ),
            ]) {
              final element = tester.element(finder);
              final text = element.widget as Text;
              final style = DefaultTextStyle.of(
                element,
              ).style.merge(text.style);
              Color? backing;
              final filled = find.ancestor(
                of: finder,
                matching: find.byType(FilledButton),
              );
              final outlined = find.ancestor(
                of: finder,
                matching: find.byType(OutlinedButton),
              );
              final segmented = find.ancestor(
                of: finder,
                matching: find.byType(FilmSegmentedControl<String>),
              );
              if (filled.evaluate().isNotEmpty) {
                backing = tester
                    .widget<FilledButton>(filled)
                    .style!
                    .backgroundColor!
                    .resolve({});
              } else if (outlined.evaluate().isNotEmpty) {
                backing = tester
                    .widget<OutlinedButton>(outlined)
                    .style!
                    .backgroundColor!
                    .resolve({});
              } else if (segmented.evaluate().isNotEmpty) {
                backing = text.data == '每日精选'
                    ? Colors.white
                    : Colors.black.withValues(alpha: .6);
              }
              if (outlined.evaluate().isNotEmpty) {
                final surface = tester
                    .widget<ColoredBox>(
                      find
                          .ancestor(
                            of: finder,
                            matching: find.byType(ColoredBox),
                          )
                          .first,
                    )
                    .color;
                backing = Color.alphaBlend(backing!, surface);
              }
              final rect = tester.getRect(finder);
              if (backing == null) {
                informationRects.add(rect);
                informationColors.add(style.color!);
                expect(style.shadows, isNull);
              }
              final painter = TextPainter(
                text: TextSpan(text: text.data!, style: style),
                textDirection: TextDirection.ltr,
                textAlign: text.textAlign ?? TextAlign.start,
                maxLines: text.maxLines,
                ellipsis: text.overflow == TextOverflow.ellipsis ? '…' : null,
              )..layout(maxWidth: rect.width);
              for (final line in painter.computeLineMetrics()) {
                textRows.add((
                  text.data!,
                  Rect.fromLTWH(
                    rect.left + line.left,
                    rect.top + line.baseline - line.ascent,
                    line.width,
                    line.height,
                  ),
                  style.color!,
                  style.fontSize!,
                  backing,
                ));
              }
              painter.text = TextSpan(
                text: text.data!,
                style: style.copyWith(color: Colors.white, shadows: const []),
              );
              painter.layout(maxWidth: rect.width);
              painter.paint(inkCanvas, rect.topLeft);
              painter.dispose();
            }
            final inkPicture = inkRecorder.endRecording();
            final inkPixels = (await tester.runAsync(() async {
              final inkImage = await inkPicture.toImage(
                viewport.width.toInt(),
                viewport.height.toInt(),
              );
              final inkBytes = await inkImage.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              );
              inkImage.dispose();
              inkPicture.dispose();
              return inkBytes!;
            }))!;
            final name =
                '${viewport.width.toInt()}-${extended ? 'extended' : 'cover'}-$pattern-${dark ? 'dark' : 'light'}';
            if (!extended) {
              await tester.runAsync(() async {
                final image =
                    await (boundary.currentContext!.findRenderObject()
                            as RenderRepaintBoundary)
                        .toImage();
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                await File(
                  '${evidence.path}/$name.png',
                ).writeAsBytes(bytes!.buffer.asUint8List());
                image.dispose();
              });
            }
            final backdrop = tester.widget<AdaptiveFilmBackdrop>(
              find.byType(AdaptiveFilmBackdrop),
            );
            expect(backdrop.textColors, isNull);
            expect(find.byType(FilmAdaptiveForeground), findsNothing);
            expect(find.byType(FilmBackdropSamplingBoundary), findsNothing);
            expect(informationColors, {Colors.white});
            final posterTitle = tester.widget<Text>(
              find.descendant(
                of: poster(work.id),
                matching: find.text(work.title),
              ),
            );
            expect(posterTitle.style!.color, Colors.white);
            final backgroundBoundary = GlobalKey();
            await tester.pumpWidget(
              frame(
                RepaintBoundary(key: backgroundBoundary, child: backdrop),
                dark: dark,
              ),
            );
            await settle(tester);
            final pixels = (await tester.runAsync(() async {
              final image =
                  await (backgroundBoundary.currentContext!.findRenderObject()
                          as RenderRepaintBoundary)
                      .toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              );
              image.dispose();
              return bytes!;
            }))!;
            if (!extended && pattern == 'white') {
              int brightness(double x, double y) => pixels.getUint8(
                ((viewport.height * y).floor() * viewport.width.toInt() +
                        (viewport.width * x).floor()) *
                    4,
              );
              for (final y in [.04, .3, .46, .7, .95]) {
                for (final x in [.04, .12, .25, .4]) {
                  expect(
                    (brightness(x, y) - brightness(1 - x, y)).abs(),
                    lessThanOrEqualTo(2),
                    reason: '$name symmetry at $x,$y',
                  );
                }
              }
              expect(brightness(.04, .3), lessThan(brightness(.2, .3)));
              expect(brightness(.5, .02), lessThan(brightness(.5, .18)));
              expect(brightness(.5, .46), inInclusiveRange(160, 170));
              expect(brightness(.5, .46), lessThan(brightness(.24, .46)));
              expect(brightness(.5, .99), lessThan(10));
            }
            final informationColor = informationColors.single;
            var readingLuminance = 0.0;
            var readingSamples = 0;
            var whiteReadable = 0;
            for (final bounds in informationRects) {
              final rect = bounds.intersect(Offset.zero & viewport);
              for (var y = rect.top + 2; y < rect.bottom - 2; y += 4) {
                for (var x = rect.left + 2; x < rect.right - 2; x += 4) {
                  final offset =
                      (y.floor() * viewport.width.toInt() + x.floor()) * 4;
                  final luminance = Color.fromARGB(
                    255,
                    pixels.getUint8(offset),
                    pixels.getUint8(offset + 1),
                    pixels.getUint8(offset + 2),
                  ).computeLuminance();
                  readingLuminance += luminance;
                  if (1.05 / (luminance + .05) >= 4.5) whiteReadable++;
                  readingSamples++;
                }
              }
            }
            expect(readingSamples, greaterThan(0));
            final average = readingLuminance / readingSamples;
            final averageContrast = 1.05 / (average + .05);
            rows.add({
              'scene': name,
              'label': 'information-region-average',
              'contrast': averageContrast,
              'readableCoverage': whiteReadable / readingSamples,
              'foreground': informationColor.toARGB32(),
            });
            for (final (label, rect, foreground, fontSize, backing)
                in textRows) {
              var minimum = double.infinity;
              var samples = 0;
              for (var y = rect.top + 2; y < rect.bottom - 2; y += 4) {
                for (var x = rect.left + 2; x < rect.right - 2; x += 4) {
                  final index =
                      (y.floor() * viewport.width.toInt() + x.floor()) * 4;
                  if (inkPixels.getUint8(index + 3) < 240) continue;
                  samples++;
                  var background = Color.fromARGB(
                    255,
                    pixels.getUint8(index),
                    pixels.getUint8(index + 1),
                    pixels.getUint8(index + 2),
                  );
                  if (backing != null) {
                    background = Color.alphaBlend(backing, background);
                  }
                  final visible = Color.alphaBlend(foreground, background);
                  final a = visible.computeLuminance(),
                      b = background.computeLuminance();
                  final ratio = a > b
                      ? (a + .05) / (b + .05)
                      : (b + .05) / (a + .05);
                  if (ratio < minimum) minimum = ratio;
                }
              }
              rows.add({
                'scene': name,
                'label': label,
                'contrast': minimum,
                'fontSize': fontSize,
                'foreground': foreground.toARGB32(),
              });
              expect(samples, greaterThan(0), reason: '$name $label');
              if (backing != null) {
                expect(
                  minimum,
                  greaterThanOrEqualTo(4.5),
                  reason: '$name $label',
                );
              }
              await tester.runAsync(
                () => File(
                  '${evidence.path}/contrast.json',
                ).writeAsString(jsonEncode(rows)),
              );
            }
          }
        }
      }
    }
    await tester.runAsync(
      () => File(
        '${evidence.path}/contrast.json',
      ).writeAsString(jsonEncode(rows)),
    );
  });

  testWidgets(
    'member showcase aligns its information and covers to the daily window baseline',
    (tester) async {
      await prepare(tester);
      final daily = catalog.sectionWorks['daily']!;
      for (final (size, scale) in [
        (const Size(1280, 720), 1.0),
        (const Size(1920, 1080), 1.0),
        (const Size(480, 720), 2.0),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(frame(showcase(), scale: scale));
        await settle(tester);
        final information = tester.getRect(
          find.byKey(const Key('featured-information')),
        );
        final rail = tester.getRect(
          find.byKey(const Key('featured-poster-rail')),
        );
        final cover = tester.getRect(poster(daily.first.id));
        final button = tester.getRect(
          find.byKey(const ValueKey('featured-play')),
        );
        await tester.pumpWidget(
          frame(showcase(works: daily.take(2).toList()), scale: scale),
        );
        await settle(tester);
        expect(find.byType(FilmSegmentedControl<String>), findsNothing);
        expect(
          tester.getRect(find.byKey(const Key('featured-poster-rail'))),
          rail,
        );
        expect(
          tester.getRect(find.byKey(const Key('featured-information'))),
          information,
        );
        final memberCover = tester.getRect(poster(daily.first.id));
        expect(memberCover.top, closeTo(cover.top, .01));
        expect(memberCover.bottom, closeTo(cover.bottom, .01));
        expect(memberCover.width, closeTo(cover.width, .01));
        expect(
          tester.getRect(find.byKey(const ValueKey('featured-play'))),
          button,
        );
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('watched synopsis never builds a transient spoiler layout', (
    tester,
  ) async {
    await prepare(tester);
    catalog.store.spoilerProtection = true;
    final works = catalog.sectionWorks['daily']!;
    await tester.runAsync(() async {
      for (final work in works.take(2)) {
        await catalog.store.markWatched(
          await catalog.store.resources(workId: work.id),
          true,
        );
      }
    });
    await tester.pumpWidget(frame(showcase()));
    await settle(tester);
    await tester.tap(poster(works[1].id));
    await tester.pump();
    final overview = find.ancestor(
      of: find.text(works[1].overview),
      matching: find.byType(FilmWatchOverlay),
    );
    expect(
      find.descendant(of: overview, matching: find.byType(ImageFiltered)),
      findsNothing,
    );
    expect(find.text('展示剧透'), findsNothing);
    final titleRect = tester.getRect(
      find.byKey(ValueKey<Object>(('featured-title', works[1].id))),
    );
    await settle(tester);
    expect(
      tester.getRect(
        find.byKey(ValueKey<Object>(('featured-title', works[1].id))),
      ),
      titleRect,
    );
    await tester.runAsync(
      () async => catalog.store.markWatched(
        await catalog.store.resources(workId: works[1].id),
        false,
      ),
    );
    await settle(tester);
    expect(
      find.descendant(of: overview, matching: find.byType(ImageFiltered)),
      findsOneWidget,
    );
    expect(find.text('展示剧透'), findsOneWidget);
    await tester.tap(find.text('展示剧透'));
    await settle(tester);
    expect(
      find.descendant(of: overview, matching: find.byType(ImageFiltered)),
      findsNothing,
    );
  });

  testWidgets(
    'showcase displays the original clearlogo and falls back to its title',
    (tester) async {
      await prepare(tester);
      final work = catalog.sectionWorks['daily']!.first;
      work.metadata['logo_path'] = '/fixture-logo.png';
      await tester.runAsync(() async {
        await File(
          '${catalog.images.directory.path}/${FilmCatalogImageCache.cacheKey('/fixture-logo.png', 'original')}.img',
        ).writeAsBytes(await imageFile.readAsBytes());
      });
      await tester.pumpWidget(frame(showcase()));
      await settle(tester);
      final logo = find.byKey(const Key('featured-logo'));
      for (var i = 0; i < 100; i++) {
        if (find
            .descendant(
              of: logo,
              matching: find.byWidgetPredicate(
                (widget) => widget is CustomPaint && widget.painter != null,
              ),
            )
            .evaluate()
            .isNotEmpty) {
          break;
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      final artwork = tester.widget<FilmArtwork>(logo);
      expect(artwork.transparent, isTrue);
      expect(artwork.target, 'original');
      expect(artwork.logoGlyphSize, isNotNull);
      expect(
        find.descendant(
          of: logo,
          matching: find.byWidgetPredicate(
            (widget) => widget is CustomPaint && widget.painter != null,
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey<Object>(('featured-title', work.id))),
        findsNothing,
      );
      await tester.tap(poster(catalog.sectionWorks['daily']![1].id));
      await settle(tester);
      expect(logo, findsNothing);
      expect(
        find.byKey(
          ValueKey<Object>((
            'featured-title',
            catalog.sectionWorks['daily']![1].id,
          )),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(FilmSegmentedControl<String>),
          matching: find.text('合集'),
        ),
      );
      await settle(tester);
      expect(logo, findsNothing);
      expect(
        find.byKey(
          ValueKey<Object>(('featured-title', catalog.collections.first.id)),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'showcase keeps the visible background while switching tabs and collection covers',
    (tester) async {
      await prepare(tester);
      await tester.pumpWidget(frame(showcase()));
      await settle(tester);
      final artwork = find.byKey(const Key('featured-backdrop-artwork'));
      final originalElement = tester.element(artwork);
      final originalPath = tester.widget<AdaptiveFilmBackdrop>(artwork).path;
      await tester.tap(
        find.descendant(
          of: find.byType(FilmSegmentedControl<String>),
          matching: find.text('合集'),
        ),
      );
      await tester.pump();
      expect(artwork, findsOneWidget);
      expect(tester.element(artwork), same(originalElement));
      expect(tester.widget<AdaptiveFilmBackdrop>(artwork).path, originalPath);
      await settle(tester);
      final collectionPath = tester.widget<AdaptiveFilmBackdrop>(artwork).path;
      await tester.tap(poster(catalog.collections[1].id));
      await tester.pump();
      expect(tester.element(artwork), same(originalElement));
      expect(tester.widget<AdaptiveFilmBackdrop>(artwork).path, collectionPath);
      await settle(tester);
      expect(
        tester.widget<AdaptiveFilmBackdrop>(artwork).path,
        isNot(collectionPath),
      );
      await tester.tap(
        find.descendant(
          of: find.byType(FilmSegmentedControl<String>),
          matching: find.text('每日精选'),
        ),
      );
      await tester.pump();
      expect(tester.element(artwork), same(originalElement));
      expect(tester.widget<AdaptiveFilmBackdrop>(artwork).path, originalPath);
      await settle(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'poster single click updates the title in the next frame without waiting for a double click',
    (tester) async {
      await prepare(tester);
      await tester.pumpWidget(frame(showcase()));
      await settle(tester);
      final work = catalog.sectionWorks['daily']![1];
      await tester.tap(poster(work.id));
      await tester.pump();
      expect(
        find.byKey(ValueKey<Object>(('featured-title', work.id))),
        findsOneWidget,
      );
      expect(opened, isEmpty);
      await settle(tester);
    },
  );

  testWidgets(
    'selection, independent tabs, keyboard and hidden synchronized scrollbars',
    (tester) async {
      await prepare(tester);
      await tester.pumpWidget(frame(showcase()));
      await settle(tester);
      final works = catalog.sectionWorks['daily']!;
      await tester.tap(poster(works[1].id));
      await settle(tester);
      expect(
        find.byKey(ValueKey<Object>(('featured-title', works[1].id))),
        findsOneWidget,
      );
      expect(opened, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await settle(tester);
      expect(
        find.byKey(ValueKey<Object>(('featured-title', works.last.id))),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle(tester);
      expect(
        find.byKey(ValueKey<Object>(('featured-title', works[1].id))),
        findsOneWidget,
      );
      final tab = find.descendant(
        of: find.byType(FilmSegmentedControl<String>),
        matching: find.text('合集'),
      );
      await tester.tap(tab);
      await settle(tester);
      await tester.tap(poster(catalog.collections[1].id));
      await settle(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(FilmSegmentedControl<String>),
          matching: find.text('每日精选'),
        ),
      );
      await settle(tester);
      expect(
        find.byKey(ValueKey<Object>(('featured-title', works[1].id))),
        findsOneWidget,
      );
      for (final view in tester.widgetList<DirectoryScrollView>(
        find.byType(DirectoryScrollView),
      )) {
        expect(view.hideScrollbar, isTrue);
        final bar = tester.widget<Scrollbar>(
          find
              .descendant(
                of: find.byWidget(view),
                matching: find.byType(Scrollbar),
              )
              .first,
        );
        expect(bar.controller, same(view.controller));
        expect(bar.interactive, isFalse);
        final theme = tester
            .widget<ScrollbarTheme>(
              find
                  .descendant(
                    of: find.byWidget(view),
                    matching: find.byType(ScrollbarTheme),
                  )
                  .first,
            )
            .data;
        expect(
          theme.thickness!.resolve({WidgetState.hovered, WidgetState.dragged}),
          0,
        );
        expect(
          theme.thumbColor!.resolve({WidgetState.hovered}),
          Colors.transparent,
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cached TMDB and NFO genres keep their existing metadata shapes',
    (tester) async {
      await prepare(tester);
      final works = catalog.sectionWorks['daily']!.take(2).toList();
      works[0].metadata['genres'] = ['Drama'];
      works[1].metadata['genres'] = [
        {'name': 'Adventure'},
      ];
      catalog.sectionWorks['daily'] = works;
      await tester.pumpWidget(frame(showcase()));
      await settle(tester);
      expect(find.textContaining('Drama'), findsOneWidget);
      await tester.tap(poster(works[1].id));
      await settle(tester);
      expect(find.textContaining('Adventure'), findsOneWidget);
    },
  );

  testWidgets(
    'horizontal wheel leaves selection unchanged and vertical wheel reaches page',
    (tester) async {
      await prepare(tester);
      tester.view.physicalSize = const Size(650, 500);
      await tester.pumpWidget(frame(showcase()));
      await settle(tester);
      final views = tester
          .widgetList<DirectoryScrollView>(find.byType(DirectoryScrollView))
          .toList();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
      await settle(tester);
      final rail = find.byType(ListView);
      final selected = find.byKey(
        ValueKey<Object>((
          'featured-title',
          catalog.sectionWorks['daily']!.first.id,
        )),
      );
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(rail),
          scrollDelta: const Offset(160, 0),
        ),
      );
      await settle(tester);
      expect(views.last.controller!.offset, greaterThan(0));
      expect(selected, findsOneWidget);
      final before = views.first.controller!.offset;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(rail),
          scrollDelta: const Offset(0, -60),
        ),
      );
      await settle(tester);
      expect(views.first.controller!.offset, lessThan(before));
      expect(selected, findsOneWidget);
    },
  );

  testWidgets(
    'double click, primary actions and right click keep their callbacks',
    (tester) async {
      await prepare(tester);
      await tester.pumpWidget(frame(showcase()));
      await settle(tester);
      final works = catalog.sectionWorks['daily']!;
      await tester.tap(poster(works[1].id));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(poster(works[1].id));
      await settle(tester);
      expect(opened, [works[1].id]);
      await tester.tap(find.byKey(const ValueKey('featured-open')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('featured-play')));
      await settle(tester);
      expect(played, [works[1].id]);
      await tester.tap(poster(works[1].id), buttons: kSecondaryMouseButton);
      await settle(tester);
      expect(menus, contains('work:${works[1].id}'));
    },
  );

  testWidgets(
    'enabled sections, empty states, disabled play and spoiler protection',
    (tester) async {
      await prepare(tester);
      catalog.homeSections = const [
        FilmHomeSection('collections', enabled: true),
      ];
      await tester.pumpWidget(frame(showcase()));
      await settle(tester);
      expect(find.byType(FilmSegmentedControl<String>), findsNothing);
      expect(find.text('查看合集'), findsOneWidget);
      catalog.collections = [];
      catalog.notifyListeners();
      await settle(tester);
      expect(find.text('暂无合集'), findsOneWidget);
      catalog.homeSections = const [FilmHomeSection('daily', enabled: true)];
      catalog.sectionWorks['daily'] = const [
        FilmWork(
          id: 999,
          type: FilmMediaType.movie,
          title: 'Unavailable',
          originalTitle: '',
          overview: 'Spoiler fixture',
          language: 'zh-CN',
        ),
      ];
      catalog.store.spoilerProtection = true;
      catalog.notifyListeners();
      await settle(tester);
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('featured-play')),
      );
      expect(button.onPressed, isNull);
      expect(find.text('展示剧透'), findsOneWidget);
      await tester.tap(find.text('展示剧透'));
      await settle(tester);
      expect(find.text('展示剧透'), findsNothing);
      catalog.sectionWorks['daily'] = [];
      catalog.notifyListeners();
      await settle(tester);
      expect(find.text('暂无每日精选'), findsOneWidget);
      catalog.homeSections = [];
      catalog.notifyListeners();
      await settle(tester);
      expect(find.byType(DirectoryScrollView), findsNothing);
      expect(find.byType(FilmDetailBackButton), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow windows, themes, four languages, text scaling and DPR do not overflow',
    (tester) async {
      await prepare(tester);
      tester.view.physicalSize = const Size(1280, 720);
      await tester.pumpWidget(
        frame(
          FilmFeaturedPage(
            catalog: catalog,
            initialSection: 'daily',
            onOpenItem: (_) async {},
            onOpenWork: (_) {},
          ),
        ),
      );
      await settle(tester);
      final pageScroll = tester
          .widget<DirectoryScrollView>(find.byType(DirectoryScrollView).first)
          .controller!;
      expect(pageScroll.position.maxScrollExtent, 0);
      for (final language in AppLanguage.values) {
        for (final dark in [true, false]) {
          for (final dpr in [1.0, 1.5, 2.0, 3.0]) {
            tester.view.devicePixelRatio = dpr;
            tester.view.physicalSize = Size(480 * dpr, 720 * dpr);
            await tester.pumpWidget(
              frame(
                showcase(),
                language: language,
                dark: dark,
                glass: dpr > 1,
                scale: 2,
              ),
            );
            await settle(tester);
            expect(
              tester.takeException(),
              isNull,
              reason: '${language.name}, dark=$dark, DPR=$dpr',
            );
          }
        }
      }
    },
  );

  testWidgets(
    'daily show all creates a child route and preserves home sections and selection',
    (tester) async {
      final chrome = ValueNotifier<double?>(null);
      addTearDown(chrome.dispose);
      await prepare(tester);
      await tester.pumpWidget(
        ListenableProvider<ValueNotifier<double?>>.value(
          value: chrome,
          child: frame(
            FilmLibraryPage(onOpenItem: (_) async {}, sidebarInset: 64),
          ),
        ),
      );
      await settle(tester);
      final before = catalog.homeSections
          .map((s) => (s.id, s.enabled))
          .toList();
      final daily = find.byWidgetPredicate(
        (w) => w is FilmShelf && w.title == '每日精选',
      );
      final all = find.descendant(of: daily, matching: find.text('查看全部'));
      await tester.ensureVisible(all);
      await tester.tap(all);
      await settle(tester);
      expect(find.byType(FilmFeaturedPage), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);
      expect(find.text('StreamPath'), findsNothing);
      expect(find.byType(FilmDetailBackButton), findsOneWidget);
      expect(chrome.value, 0);
      expect(
        tester.getRect(find.byKey(const Key('featured-fullscreen-backdrop'))),
        tester.getRect(find.byType(FilmFeaturedShowcase)),
      );
      expect(catalog.sectionId, isNull);
      expect(
        catalog.homeSections.map((s) => (s.id, s.enabled)).toList(),
        before,
      );
      final work = catalog.sectionWorks['daily']![1];
      await tester.tap(poster(work.id));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('featured-open')));
      await settle(tester);
      expect(find.byType(FilmFeaturedShowcase), findsNothing);
      Navigator.of(tester.element(find.byType(Scaffold).last)).pop();
      await settle(tester);
      expect(chrome.value, 0);
      expect(
        find.byKey(ValueKey<Object>(('featured-title', work.id))),
        findsOneWidget,
      );
      final back = find.byKey(const Key('film-detail-back'));
      final fade = find.descendant(
        of: find.byType(FilmDetailBackButton),
        matching: find.byType(AnimatedOpacity),
      );
      expect(tester.widget<AnimatedOpacity>(fade).opacity, 0);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(300, 300));
      await mouse.moveTo(tester.getCenter(back));
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedOpacity>(fade).opacity, 1);
      await tester.tap(back);
      await settle(tester);
      expect(find.byType(FilmLibraryPage), findsOneWidget);
      expect(chrome.value, isNull);
      await mouse.removePointer();
    },
  );

  testWidgets(
    'collection opens a member showcase with playback, details, refresh and immersive return',
    (tester) async {
      final chrome = ValueNotifier<double?>(0);
      addTearDown(chrome.dispose);
      await prepare(tester);
      final members = (await tester.runAsync(
        () => catalog.store.works(type: null),
      ))!.take(3).toList();
      final collection = catalog.collections.first;
      await tester.runAsync(() async {
        for (final work in members) {
          await catalog.store.addCollectionMember(collection.id, work.id);
        }
        await catalog.refresh();
      });
      final items = <MediaLibraryItem>[];
      await tester.pumpWidget(
        ListenableProvider<ValueNotifier<double?>>.value(
          value: chrome,
          child: frame(
            FilmFeaturedPage(
              catalog: catalog,
              initialSection: 'daily',
              onOpenItem: (item) async => items.add(item),
              onOpenWork: (work) => opened.add(work.id),
            ),
          ),
        ),
      );
      await settle(tester);
      final work = catalog.sectionWorks['daily']!.first;
      await tester.tap(find.byKey(const ValueKey('featured-play')));
      await settle(tester);
      expect(items.single.sourceId, 'local:fixture');
      final resource = (await tester.runAsync(
        () => catalog.store.resources(workId: work.id),
      ))!.first;
      expect(items.single.name, resource.name);
      await tester.tap(
        find.descendant(
          of: find.byType(FilmSegmentedControl<String>),
          matching: find.text('合集'),
        ),
      );
      await settle(tester);
      await tester.tap(find.text('查看合集'));
      await settle(tester);
      expect(find.byType(FilmRelatedPage), findsNothing);
      expect(find.byType(FilmFeaturedShowcase), findsOneWidget);
      expect(find.byType(FilmSegmentedControl<String>), findsNothing);
      expect(chrome.value, 0);
      final child = tester.widget<FilmFeaturedShowcase>(
        find.byType(FilmFeaturedShowcase),
      );
      expect(child.works!.map((w) => w.id), members.map((w) => w.id));
      final background = find.byKey(const Key('featured-backdrop-artwork'));
      final backgroundElement = tester.element(background);
      await tester.tap(poster(members[1].id));
      await tester.pump();
      expect(tester.element(background), same(backgroundElement));
      expect(
        tester.widget<AdaptiveFilmBackdrop>(background).path,
        members[1].backdropPath,
      );
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('featured-play')));
      await settle(tester);
      final childResource = (await tester.runAsync(
        () => catalog.store.resources(workId: members[1].id),
      ))!.first;
      expect(items.last.name, childResource.name);
      await tester.tap(find.byKey(const ValueKey('featured-open')));
      await settle(tester);
      expect(opened, [members[1].id]);
      catalog.homeSections = [];
      catalog.notifyListeners();
      await tester.runAsync(
        () =>
            catalog.store.removeCollectionMember(collection.id, members[1].id),
      );
      await settle(tester);
      expect(
        tester
            .widget<FilmFeaturedShowcase>(find.byType(FilmFeaturedShowcase))
            .works!
            .map((w) => w.id),
        [members[0].id, members[2].id],
      );
      expect(
        find.byKey(ValueKey<Object>(('featured-title', members[0].id))),
        findsOneWidget,
      );
      catalog.homeSections = const [
        FilmHomeSection('daily', enabled: true),
        FilmHomeSection('collections', enabled: true),
      ];
      catalog.notifyListeners();
      final back = find.byKey(const Key('film-detail-back'));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(300, 300));
      await mouse.moveTo(tester.getCenter(back));
      await tester.pumpAndSettle();
      await tester.tap(back);
      await settle(tester);
      expect(find.byType(FilmFeaturedShowcase), findsOneWidget);
      expect(find.text('查看合集'), findsOneWidget);
      expect(find.byType(FilmSegmentedControl<String>), findsOneWidget);
      expect(chrome.value, 0);
      await mouse.removePointer();
    },
  );

  testWidgets(
    'posters match home size, stay at the bottom and collections are compact',
    (tester) async {
      await prepare(tester);
      for (final size in [const Size(1280, 720), const Size(1920, 1080)]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(frame(showcase(section: 'collections')));
        await settle(tester);
        final rail = tester.getRect(
          find.byKey(const Key('featured-poster-rail')),
        );
        expect(rail.bottom, closeTo(size.height - 16, 1));
        expect(rail.width, closeTo(size.width - 48, 1));
        expect(
          tester.getSize(poster(catalog.collections.first.id)).width,
          FilmShelf.defaultItemWidth,
        );
        final info = tester.getRect(
          find.byKey(const Key('featured-information')),
        );
        expect(info.center.dx, closeTo(size.width / 2, 1));
        final first = tester.getRect(poster(catalog.collections.first.id));
        final last = tester.getRect(poster(catalog.collections.last.id));
        expect((first.left + last.right) / 2, closeTo(size.width / 2, 1));
        expect(info.height, lessThan(220));
        final background = tester.widget<FilmDetailBackdrop>(
          find.byType(FilmDetailBackdrop),
        );
        expect(
          background.path,
          (await tester.runAsync(
            () => catalog.store.works(
              type: null,
              collectionId: catalog.collections.first.id,
            ),
          ))!.single.backdropPath,
        );
        expect(find.byType(FilmDetailActionButton), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.tap(
        find.descendant(
          of: find.byType(FilmSegmentedControl<String>),
          matching: find.text('每日精选'),
        ),
      );
      await settle(tester);
      expect(find.byType(FilmDetailPlayButton), findsOneWidget);
      final dailyLayout = FilmShelf.adaptiveLayout(
        1920 - 48 - 8,
        catalog.sectionWorks['daily']!.length,
      );
      expect(
        tester.getSize(poster(catalog.sectionWorks['daily']!.first.id)).width,
        dailyLayout.width,
      );
      expect(
        tester
            .getRect(
              poster(
                catalog.sectionWorks['daily']![dailyLayout.visible - 1].id,
              ),
            )
            .right,
        lessThanOrEqualTo(1920 - 24),
      );
      final play = tester.widget<FilledButton>(
        find.byKey(const ValueKey('featured-play')),
      );
      expect(play.style!.backgroundColor!.resolve({}), Colors.white);
      expect(play.style!.minimumSize!.resolve({}), const Size(0, 44));
      final open = tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('featured-open')),
      );
      expect(open.style!.minimumSize!.resolve({}), const Size(0, 44));
      final title = tester.getRect(
        find.byKey(
          ValueKey<Object>((
            'featured-title',
            catalog.sectionWorks['daily']!.first.id,
          )),
        ),
      );
      final buttons = tester.getRect(
        find.byKey(const ValueKey('featured-play')),
      );
      expect(buttons.top - title.bottom, inInclusiveRange(12, 16));
      expect(
        tester.getRect(find.textContaining('Drama')).top,
        greaterThan(buttons.bottom),
      );
      final info = tester.getRect(
        find.byKey(const Key('featured-information')),
      );
      final rail = tester.getRect(
        find.byKey(const Key('featured-poster-rail')),
      );
      expect(rail.top - info.bottom, closeTo(24, 1));
      expect(find.text('选择一部影片'), findsNothing);
      expect(find.text('选择一个合集'), findsNothing);
      expect(find.textContaining(RegExp(r'\d{2} / \d{2}')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('featured-information')),
          matching: find.text('每日精选'),
        ),
        findsNothing,
      );
    },
  );

  Future<FilmWork> addUnreadyMember(WidgetTester tester) async =>
      (await tester.runAsync(() async {
        final resource = (await catalog.store.resources()).last;
        await catalog.store.bind(
          [resource],
          const FilmWork(
            type: FilmMediaType.movie,
            identityKey: 'local:unready-background',
            metadataOrigin: 'local',
            title: 'Unready background',
            originalTitle: 'Unready background',
            overview: 'Keep this overview',
            language: 'zh-CN',
          ),
        );
        final work = (await catalog.store.works(
          type: null,
        )).firstWhere((w) => w.title == 'Unready background');
        await catalog.store.addCollectionMember(
          catalog.collections.first.id,
          work.id,
        );
        await catalog.refresh();
        return work;
      }))!;

  testWidgets(
    'collection backgrounds stay fixed across switching, reopening and source recreation until a new session',
    (tester) async {
      await prepare(tester);
      final members = (await tester.runAsync(
        () => catalog.store.works(
          type: null,
          collectionId: catalog.collections.first.id,
        ),
      ))!;
      await addUnreadyMember(tester);
      await tester.pumpWidget(frame(showcase(section: 'collections')));
      await settle(tester);
      final background = tester.widget<FilmDetailBackdrop>(
        find.byType(FilmDetailBackdrop),
      );
      expect(background.path, members.single.backdropPath);
      expect(background.workId, members.single.id);
      expect(
        background.path,
        isNot(catalog.collectionCovers[catalog.collections.first.id]),
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('featured-information')),
          matching: find.text('合集'),
        ),
        findsNothing,
      );
      catalog.notifyListeners();
      await settle(tester);
      expect(
        tester.widget<FilmDetailBackdrop>(find.byType(FilmDetailBackdrop)).path,
        background.path,
      );
      final id = catalog.collections.first.id;
      final replacement = catalog.sectionWorks['daily']!.firstWhere(
        (w) => w.id != members.single.id,
      );
      await tester.runAsync(() async {
        await catalog.store.removeCollectionMember(id, members.single.id);
        await catalog.store.addCollectionMember(id, replacement.id);
        await catalog.refresh();
      });
      await tester.tap(poster(catalog.collections[1].id));
      await settle(tester);
      await tester.tap(poster(id));
      await settle(tester);
      expect(
        tester.widget<FilmDetailBackdrop>(find.byType(FilmDetailBackdrop)).path,
        background.path,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
      await tester.pumpWidget(frame(showcase(section: 'collections')));
      await settle(tester);
      expect(
        tester.widget<FilmDetailBackdrop>(find.byType(FilmDetailBackdrop)).path,
        background.path,
      );
      await tester.runAsync(() async {
        final fresh = FilmCatalogController(
          store: catalog.store,
          tmdb: catalog.tmdb,
          images: catalog.images,
          sourceFor: catalog.sourceFor,
          ownsResources: false,
        );
        try {
          expect((await fresh.collectionBackdrop(id))!.workId, replacement.id);
        } finally {
          await fresh.close();
        }
        final source = catalog.forSource('local:fixture');
        try {
          expect((await source.collectionBackdrop(id))!.workId, replacement.id);
        } finally {
          await source.close();
        }
        await catalog.store.removeCollectionMember(id, replacement.id);
        await catalog.store.addCollectionMember(id, members.single.id);
        final reopened = catalog.forSource('local:fixture');
        try {
          expect(
            (await reopened.collectionBackdrop(id))!.workId,
            replacement.id,
          );
        } finally {
          await reopened.close();
        }
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'collection fetches only artwork and rejects results after switching to daily',
    (tester) async {
      await prepare(tester);
      final original = catalog;
      final members = (await tester.runAsync(
        () => catalog.store.works(
          type: null,
          collectionId: catalog.collections.first.id,
        ),
      ))!;
      final member = await addUnreadyMember(tester);
      final id = catalog.collections.first.id;
      await tester.runAsync(
        () => catalog.store.removeCollectionMember(id, members.single.id),
      );
      final tmdb = _BackgroundTmdb();
      catalog = FilmCatalogController(
        store: original.store,
        tmdb: tmdb,
        images: original.images,
        sourceFor: original.sourceFor,
        ownsResources: false,
      );
      await tester.runAsync(() => catalog.refresh());
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await settle(tester);
        await catalog.close();
        tmdb.close();
      });
      await tester.pumpWidget(frame(showcase(section: 'collections')));
      await settle(tester);
      expect(tmdb.searches, ['Unready background']);
      expect(tmdb.requests, [800]);
      expect(
        tester.widget<FilmDetailBackdrop>(find.byType(FilmDetailBackdrop)).path,
        isNull,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(FilmSegmentedControl<String>),
          matching: find.text('每日精选'),
        ),
      );
      await settle(tester);
      final daily = tester
          .widget<FilmDetailBackdrop>(find.byType(FilmDetailBackdrop))
          .path;
      await tester.tap(
        find.descendant(
          of: find.byType(FilmSegmentedControl<String>),
          matching: find.text('合集'),
        ),
      );
      await settle(tester);
      expect(tmdb.searches, ['Unready background']);
      expect(tmdb.requests, [800]);
      await tester.tap(
        find.descendant(
          of: find.byType(FilmSegmentedControl<String>),
          matching: find.text('每日精选'),
        ),
      );
      await settle(tester);
      tmdb.pending.complete(
        const FilmWork(
          type: FilmMediaType.movie,
          tmdbId: 800,
          title: 'Remote title',
          originalTitle: '',
          overview: 'Remote overview',
          language: 'en',
          backdropPath: '/backdrop0.png',
          posterPath: '/poster0.png',
        ),
      );
      await settle(tester);
      expect(
        tester.widget<FilmDetailBackdrop>(find.byType(FilmDetailBackdrop)).path,
        daily,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(FilmSegmentedControl<String>),
          matching: find.text('合集'),
        ),
      );
      await settle(tester);
      expect(
        tester.widget<FilmDetailBackdrop>(find.byType(FilmDetailBackdrop)).path,
        '/backdrop0.png',
      );
      expect(tmdb.searches, ['Unready background']);
      expect(tmdb.requests, [800]);
      final saved = (await tester.runAsync(
        () => catalog.store.work(member.id),
      ))!;
      expect(saved.tmdbId, 0);
      expect(saved.title, member.title);
      expect(saved.overview, member.overview);
      expect(saved.backdropPath, isNull);
      expect(saved.metadataOrigin, 'local');
      expect(saved.metadata, member.metadata);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'film segmented controls use a white floating indicator in both themes',
    (tester) async {
      await prepare(tester);
      for (final dark in [true, false]) {
        await tester.pumpWidget(frame(showcase(), dark: dark));
        await settle(tester);
        final segment = tester.widget<FilmSegmentedControl<String>>(
          find.byType(FilmSegmentedControl<String>),
        );
        expect(segment.selected, 'daily');
        final dailyFinder = find.descendant(
          of: find.byType(FilmSegmentedControl<String>),
          matching: find.byKey(const ValueKey('daily')),
        );
        final collectionsFinder = find.descendant(
          of: find.byType(FilmSegmentedControl<String>),
          matching: find.byKey(const ValueKey('collections')),
        );
        final daily = tester.widget<TextButton>(dailyFinder);
        final collections = tester.widget<TextButton>(collectionsFinder);
        expect(daily.style!.foregroundColor!.resolve({}), Colors.black);
        expect(
          collections.style!.foregroundColor!.resolve({}),
          Colors.white.withValues(alpha: .7),
        );
        final indicatorFinder = find.descendant(
          of: find.byType(FilmSegmentedControl<String>),
          matching: find.byType(AnimatedAlign),
        );
        final indicator = tester.widget<AnimatedAlign>(indicatorFinder);
        expect(indicator.duration, const Duration(milliseconds: 300));
        expect(indicator.curve, Curves.easeOutCubic);
        expect(indicator.alignment, const AlignmentDirectional(-1, 0));
        await tester.tap(collectionsFinder);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        expect(
          tester.widget<AnimatedAlign>(indicatorFinder).alignment,
          const AlignmentDirectional(1, 0),
        );
        final movingAlignment =
            tester
                    .widget<Align>(
                      find.descendant(
                        of: indicatorFinder,
                        matching: find.byType(Align),
                      ),
                    )
                    .alignment
                as AlignmentDirectional;
        expect(movingAlignment.start, greaterThan(-1));
        expect(movingAlignment.start, lessThan(1));
        await settle(tester);
        await tester.tap(dailyFinder);
        await settle(tester);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'shared detail artwork keeps decoded backgrounds during loading and rejects stale files',
    (tester) async {
      await prepare(tester);
      final cache = _GatedImages(catalog.images);
      Widget backdrop(String path) => frame(
        SizedBox(
          width: 300,
          height: 200,
          child: AdaptiveFilmBackdrop(cache: cache, path: path),
        ),
      );
      await tester.pumpWidget(backdrop('/a'));
      await tester.pumpWidget(backdrop('/b'));
      await tester.pumpWidget(backdrop('/c'));
      expect(cache.calls, ['/a', '/b', '/c']);
      cache.pending['/a']!.complete(imageFile);
      await settle(tester);
      expect(find.byType(Image), findsNothing);
      cache.pending['/c']!.complete(imageFile);
      await settle(tester);
      final sharp = find.byKey(const Key('adaptive-backdrop-sharp'));
      expect(sharp, findsOneWidget);
      cache.pending['/b']!.complete(imageFile);
      await settle(tester);
      final previous = tester.widget<RawImage>(sharp).image!;
      final element = tester.element(sharp);
      await tester.pumpWidget(backdrop('/d'));
      expect(tester.element(sharp), same(element));
      expect(tester.widget<RawImage>(sharp).image, same(previous));
      final other = await tester.runAsync(
        () => imageFile.copy('${temp.path}/other.png'),
      );
      cache.pending['/d']!.complete(other!);
      await tester.pump();
      expect(tester.widget<RawImage>(sharp).image, same(previous));
      await settle(tester);
      await tester.pumpAndSettle();
      expect(sharp, findsOneWidget);
      expect(tester.widget<RawImage>(sharp).image, isNot(same(previous)));
      expect(tester.takeException(), isNull);
    },
  );
}

class _GatedImages extends FilmCatalogImageCache {
  _GatedImages(FilmCatalogImageCache cache)
    : super(cache.directory, cache.tmdb);
  final calls = <String>[];
  final pending = <String, Completer<File>>{};
  @override
  Future<File> get(String path, {String target = 'w342'}) {
    calls.add(path);
    return (pending[path] = Completer<File>()).future;
  }
}

class _BackgroundTmdb extends TmdbMetadataService {
  _BackgroundTmdb() : super(credentials: _NoBackgroundCredentials());
  final searches = <String>[];
  final requests = <int>[];
  final pending = Completer<FilmWork>();
  @override
  Future<List<FilmWork>> search(
    FilmMediaType type,
    String query,
    String language, {
    int? year,
    int page = 1,
  }) async {
    searches.add(query);
    return [
      FilmWork(
        type: type,
        tmdbId: 800,
        title: query,
        originalTitle: query,
        overview: '',
        language: language,
      ),
    ];
  }

  @override
  Future<FilmWork> details(FilmMediaType type, int id, String language) {
    requests.add(id);
    return pending.future;
  }
}

class _NoBackgroundCredentials extends TmdbCredentialStore {
  @override
  Future<String?> read() async => null;
}
