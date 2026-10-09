import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/domain/services/film_scan_scheduler.dart';
import 'package:streampath/presentation/widgets/film_watch_overlay.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  test('scheduler postpones busy scans, runs one missed cycle and waits on shutdown', () async {
    final dir = await Directory.systemTemp.createTemp('film_schedule_');
    final store = await FilmCatalogStore.open('${dir.path}/catalog.db');
    var busy = true, calls = 0;
    final finishing = Completer<void>();
    final scheduler = FilmScanScheduler(store: store, isBusy: () async => busy, scan: (_) async { calls++; await finishing.future; });
    final date = DateTime(2026, 10, 7);
    try {
      await store.setPreference('scan_interval_hours', 1);
      await scheduler.tick(now: date);
      await scheduler.tick(now: date.add(const Duration(hours: 5)));
      expect(calls, 0);
      await scheduler.tick(now: date.add(const Duration(days: 10)));
      expect(calls, 0);
      busy = false;
      final scan = scheduler.tick(now: date.add(const Duration(days: 10)));
      while (calls == 0) { await Future<void>.delayed(Duration.zero); }
      await scheduler.tick(now: date.add(const Duration(days: 10)));
      expect(calls, 1);
      var closed = false;
      final close = scheduler.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, false);
      finishing.complete();
      await scan; await close;
      await scheduler.tick(now: date.add(const Duration(days: 20)));
      expect(calls, 1);
    } finally { await scheduler.close(); await store.close(); await dir.delete(recursive: true); }
  });
  testWidgets('spoiler reveal shares episode versions, keeps other episodes hidden and remasks unwatched content', (tester) async {
    late Directory dir;
    late FilmCatalogStore store;
    late List<FilmResource> resources;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('film_spoiler_');
      store = await FilmCatalogStore.open('${dir.path}/catalog.db');
      final id = await store.addRoot(sourceId: 'test', kind: MediaSourceKind.local, path: '', type: FilmMediaType.tv, name: 'TV');
      final root = (await store.root(id))!;
      final generation = await store.beginScan(id);
      await store.stage(root, generation, [for (final name in ['E1.mkv', 'E1-v2.mkv', 'E2.mkv']) FilmScanEntry(path: name, parentPath: '', name: name, mediaKind: 'video')]);
      await store.commitScan(id, generation, cancelled: () => false);
      await store.bind(await store.resources(), const FilmWork(type: FilmMediaType.tv, tmdbId: 10, title: 'TV', originalTitle: 'TV', overview: '', language: 'en'));
      resources = await store.resources();
      await store.mapEpisodes({for (final r in resources) r: (1, r.name.startsWith('E1') ? 1 : 2)});
      resources = await store.resources();
      await store.setPreference('spoiler_protection', true);
    });
    Future<void> settle() async { await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20))); await tester.pump(); }
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: FilmSpoilerScope(child: Column(children: [for (final r in resources) SizedBox(height: 60, child: FilmWatchOverlay(store: store, resource: r, spoilerSensitive: true, child: Text(r.name)))])))));
    await settle();
    expect(find.byType(ImageFiltered), findsNWidgets(3));
    await tester.tap(find.text('展示剧透').first);
    await tester.pump();
    expect(find.byType(ImageFiltered), findsOneWidget);
    await tester.runAsync(() => store.markWatched([resources.first], true));
    await settle();
    await tester.runAsync(() => store.markWatched([resources.first], false));
    await settle();
    expect(find.byType(ImageFiltered), findsNWidgets(3));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async { await store.close(); await dir.delete(recursive: true); });
  });
}
