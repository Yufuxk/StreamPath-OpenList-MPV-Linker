import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/film_metadata_edit.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/film_metadata_artwork.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/localization/metadata_editor_translations.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:streampath/presentation/widgets/film_metadata_editor.dart';
import 'package:streampath/presentation/widgets/sp_menu.dart';

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 80));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    sqfliteFfiInit();
    final font = File('C:/Windows/Fonts/segoeui.ttf');
    if (await font.exists()) {
      await (FontLoader(
        'Segoe UI',
      )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
    }
  });

  test('编辑器文案覆盖四语言并保留参数', () {
    for (final language in AppLanguage.values) {
      final l10n = AppLocalizations(language);
      for (final row in metadataEditorTranslations.entries) {
        expect(
          l10n.text(row.key),
          language == AppLanguage.simplifiedChinese
              ? row.key
              : row.value[language.index - 1],
        );
      }
    }
  });

  for (final language in AppLanguage.values) {
    for (final dark in [false, true]) {
      testWidgets('编辑弹窗 ${language.name} dark=$dark 保存取消及窄窗', (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final dir = await tester.runAsync(
          () => Directory.systemTemp.createTemp('metadata-ui-'),
        );
        final store = (await tester.runAsync(
          () => FilmCatalogStore.open(p.join(dir!.path, 'catalog.db')),
        ))!;
        await tester.runAsync(
          () => store.refreshWork(
            const FilmWork(
              type: FilmMediaType.movie,
              tmdbId: 77,
              metadataOrigin: 'nfo',
              title: 'Original title',
              originalTitle: 'Original',
              overview: 'Overview',
              language: 'zh-CN',
              year: 2020,
              metadata: {
                'poster_candidates': [
                  {
                    'file_path': '/fixture-poster.png',
                    'iso_639_1': 'ja',
                    'width': 32,
                    'height': 32,
                  },
                ],
              },
            ),
          ),
        );
        final work = (await tester.runAsync(
          () => store.cachedWork(FilmMediaType.movie, 77),
        ))!;
        final tmdb = TmdbMetadataService();
        final images = FilmCatalogImageCache(
          Directory(p.join(dir!.path, 'cache')),
          tmdb,
        );
        await tester.runAsync(() async {
          await images.directory.create(recursive: true);
          await File(
            p.join(
              images.directory.path,
              '${FilmCatalogImageCache.cacheKey('/fixture-poster.png', 'w300')}.img',
            ),
          ).writeAsBytes(
            img.encodePng(img.Image(width: 32, height: 32, numChannels: 4)),
          );
        });
        final catalog = FilmCatalogController(
          store: store,
          tmdb: tmdb,
          images: images,
          sourceFor: (_) => throw UnimplementedError(),
          ownsResources: false,
        );
        final l10n = AppLocalizations(language);
        final previewKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            locale: language.locale,
            supportedLocales: AppLanguage.values.map((e) => e.locale),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            theme: dark ? AppTheme.dark() : AppTheme.light(),
            builder: (context, child) => RepaintBoundary(
              key: previewKey,
              child: MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!,
              ),
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showFilmMetadataEditor(
                    context,
                    catalog,
                    FilmMetadataTarget.work(work.id),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await settle(tester);
        expect(find.byKey(const ValueKey('metadata:title')), findsOneWidget);
        await tester.enterText(
          find.byKey(const ValueKey('metadata:title')),
          'Edited title',
        );
        await tester.pump();
        await tester.tap(find.text(l10n.text('保存')).last);
        await settle(tester);
        expect(
          (await tester.runAsync(() => store.work(work.id)))!.title,
          'Edited title',
        );
        await tester.tap(find.text('Open'));
        await settle(tester);
        await tester.enterText(
          find.byKey(const ValueKey('metadata:title')),
          'Discard title',
        );
        await tester.tap(find.text(l10n.text('取消')).last);
        await tester.pumpAndSettle();
        expect(find.text(l10n.text('保存修改？')), findsOneWidget);
        await tester.tap(find.text(l10n.text('放弃')));
        await settle(tester);
        expect(
          (await tester.runAsync(() => store.work(work.id)))!.title,
          'Edited title',
        );
        await tester.tap(find.text('Open'));
        await settle(tester);
        await tester.tap(find.text(l10n.text('图片')));
        await settle(tester);
        expect(find.text(l10n.text('本地图片')), findsOneWidget);
        expect(
          tester
              .widget<SPDropdownButtonFormField<String>>(
                find.byType(SPDropdownButtonFormField<String>),
              )
              .items!
              .map((e) => e.value),
          contains('ja'),
        );
        expect(tester.takeException(), isNull);
        await tester.binding.setSurfaceSize(const Size(620, 820));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (language == AppLanguage.english) {
          final boundary =
              previewKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            image.dispose();
            final file = File(
              'build/metadata-editor-${dark ? 'dark' : 'light'}.png',
            );
            await file.writeAsBytes(data!.buffer.asUint8List());
          });
        }
        await tester.tap(find.text(l10n.text('取消')).last);
        await settle(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(catalog.close);
        images.close();
        tmdb.close();
        await tester.runAsync(() async {
          await store.close();
          await dir.delete(recursive: true);
        });
      });
    }
  }

  test('人工图片复制去重、取消草稿及清缓存后仍可读取', () async {
    final temp = await Directory.systemTemp.createTemp('metadata-images-');
    final managed = Directory(p.join(temp.path, 'library', 'imported_artwork'));
    final tmdb = TmdbMetadataService();
    final cache = FilmCatalogImageCache(
      Directory(p.join(temp.path, 'cache', 'film_artwork')),
      tmdb,
      managedArtworkDirectory: managed,
    );
    final importer = FilmMetadataArtwork(managed, cache);
    try {
      final source = File(p.join(temp.path, 'source.png'));
      await source.writeAsBytes(
        img.encodePng(img.Image(width: 32, height: 32, numChannels: 4)),
      );
      final ref = await importer.fromFile(source);
      expect(await importer.fromFile(source), ref);
      expect(await managed.list().length, 1);
      await source.delete();
      await importer.cleanup({ref});
      expect(await (await cache.get(ref)).length(), greaterThan(0));
      await cache.clear();
      expect(await (await cache.get(ref)).length(), greaterThan(0));
      importer.track([ref]);
      await importer.cleanup({});
      expect(await managed.list().length, 0);
      final invalid = File(p.join(temp.path, 'bad.png'));
      await invalid.writeAsString('invalid');
      await expectLater(
        importer.fromFile(invalid),
        throwsA(isA<FilmCatalogException>()),
      );
    } finally {
      importer.cancel();
      cache.close();
      tmdb.close();
      await temp.delete(recursive: true);
    }
  });

  test('图片网址下载、流式上限、取消后重试与格式错误', () async {
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previousOverrides);
    final temp = await Directory.systemTemp.createTemp('metadata-url-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final png = img.encodePng(img.Image(width: 32, height: 32, numChannels: 4));
    final hanging = Completer<void>();
    final tmdb = TmdbMetadataService();
    final cache = FilmCatalogImageCache(
      Directory(p.join(temp.path, 'cache')),
      tmdb,
      maxImageBytes: 1024,
    );
    final importer = FilmMetadataArtwork(
      Directory(p.join(temp.path, 'assets')),
      cache,
    );
    server.listen((request) async {
      expect(request.headers.value('authorization'), isNull);
      if (request.uri.path == '/hang') {
        request.response.add([1]);
        await request.response.flush();
        if (!hanging.isCompleted) hanging.complete();
        return;
      }
      request.response.add(
        request.uri.path == '/large'
            ? List.filled(2048, 0)
            : request.uri.path == '/bad'
            ? [1, 2, 3]
            : png,
      );
      await request.response.close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    try {
      final first = await importer.fromUrl('$base/image');
      expect(await importer.fromUrl('$base/image'), first);
      await expectLater(
        importer.fromUrl('$base/large'),
        throwsA(isA<FilmCatalogException>()),
      );
      await expectLater(
        importer.fromUrl('$base/bad'),
        throwsA(isA<FilmCatalogException>()),
      );
      final pending = importer.fromUrl('$base/hang');
      final rejected = expectLater(
        pending,
        throwsA(isA<FilmCatalogException>()),
      );
      await hanging.future;
      importer.cancelDownloads();
      await rejected;
      expect(await importer.fromUrl('$base/image'), first);
      await expectLater(
        importer.fromUrl('file:///C:/image.png'),
        throwsA(isA<FilmCatalogException>()),
      );
    } finally {
      importer.cancel();
      await server.close(force: true);
      cache.close();
      tmdb.close();
      await temp.delete(recursive: true);
    }
  });
}
