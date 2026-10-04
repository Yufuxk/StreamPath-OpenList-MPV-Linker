import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/widgets/film_section_settings.dart';

class _GatedCatalog extends FilmCatalogController {
  _GatedCatalog(FilmCatalogStore store, TmdbMetadataService tmdb)
    : super(
        store: store,
        tmdb: tmdb,
        images: FilmCatalogImageCache(Directory.systemTemp, tmdb),
        sourceFor: (_) => throw StateError('Unexpected directory request'),
      );
  final refreshGate = Completer<void>();
  Completer<void>? saveGate;
  bool failSave = false;
  @override
  Future<void> refresh({bool more = false}) => refreshGate.future;
  @override
  Future<bool> run(Future<void> Function() action, {bool clearError = true}) =>
      super.run(() async {
        await saveGate?.future;
        if (failSave) throw const FilmCatalogException('catalogStorageFailed');
        await action();
      }, clearError: clearError);
}

void main() {
  setUpAll(sqfliteFfiInit);
  testWidgets('首页栏目立即反馈，保存后不等待整库刷新，失败回退', (tester) async {
    final store = (await tester.runAsync(
      () => FilmCatalogStore.open(inMemoryDatabasePath),
    ))!;
    final catalog = _GatedCatalog(store, TmdbMetadataService());
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      catalog.refreshGate.complete();
      await tester.runAsync(catalog.close);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AnimatedBuilder(
              animation: catalog,
              builder: (_, _) => FilmSectionSettings(catalog: catalog),
            ),
          ),
        ),
      ),
    );
    catalog.saveGate = Completer<void>();
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    expect(tester.widget<Checkbox>(find.byType(Checkbox).first).value, false);
    expect(catalog.homeSections.first.enabled, true);
    catalog.saveGate!.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pump();
    expect(catalog.homeSections.first.enabled, false);
    expect(
      tester
          .widget<IgnorePointer>(
            find
                .descendant(
                  of: find.byType(FilmSectionSettings),
                  matching: find.byType(IgnorePointer),
                )
                .first,
          )
          .ignoring,
      false,
    );
    expect((await tester.runAsync(store.homeSections))!.first.enabled, false);

    catalog.saveGate = Completer<void>();
    catalog.failSave = true;
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    expect(tester.widget<Checkbox>(find.byType(Checkbox).first).value, true);
    catalog.saveGate!.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(tester.widget<Checkbox>(find.byType(Checkbox).first).value, false);
    expect(catalog.error, 'catalogStorageFailed');
    expect(find.byType(SnackBar), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
  });
}
