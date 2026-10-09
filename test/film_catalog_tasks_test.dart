import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/data/remote/webdav_client.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/domain/services/webdav_media_source_adapter.dart';
import 'package:streampath/domain/services/webdav_service.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/widgets/film_catalog_tasks.dart';

void main() {
  test('任务结束释放刮削临时对象并保留结果与完成计数', () async {
    final fixture = await _Fixture.create(
      (_) async => [_file('Movies/A.2020.mkv')],
    );
    addTearDown(fixture.close);
    final c = fixture.controller;
    await c.scan(fixture.root);
    await c.waitForScraping();
    expect(c.scrapeProcessed, 1);
    expect(c.scrapedCount, 1);
    expect(c.scrapeCompletion, 1);
    expect((await c.store.resources()).single.workId, isNotNull);
    expect(c.retainedScrapeSessionCount, 0);
    expect(c.retainedScrapeEntryCount, 0);
  });

  test('空扫描和无凭据扫描也释放临时 session', () async {
    for (final credentials in [_Token(), _FailedToken()]) {
      final fixture = await _Fixture.create(
        (_) async => [],
        credentials: credentials,
      );
      try {
        await fixture.controller.scan(fixture.root);
        expect(fixture.controller.scraping, isFalse);
        expect(fixture.controller.retainedScrapeSessionCount, 0);
        expect(fixture.controller.retainedScrapeEntryCount, 0);
      } finally {
        await fixture.close();
      }
    }
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test('扫描完成不等待 TMDB，独立队列继续处理全部文件', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final fixture = await _Fixture.create(
      (_) async => [_file('Movies/A.2020.mkv'), _file('Movies/B.2020.mkv')],
      api: (options) async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
        return _response(options);
      },
    );
    addTearDown(fixture.close);
    final c = fixture.controller;
    final scan = c.scan(fixture.root);
    await entered.future;
    await scan.timeout(const Duration(seconds: 5));
    expect(c.busy, isFalse);
    expect(c.progress, isNull);
    expect(c.scraping, isTrue);
    expect(c.scrapeTotal, 2);
    expect(c.scrapeProcessed, 0);
    expect(c.retainedScrapeSessionCount, 1);
    expect(c.retainedScrapeEntryCount, 2);
    expect((await c.store.root(fixture.root.id))!.status, 'completed');
    expect(await c.store.pendingCount(), 2);
    release.complete();
    await c.waitForScraping().timeout(const Duration(seconds: 10));
    expect(c.scraping, isFalse);
    expect(c.scrapeProcessed, 2);
    expect(c.scrapedCount, 2);
    expect(await c.store.pendingCount(), 0);
    expect(c.retainedScrapeSessionCount, 0);
    expect(c.retainedScrapeEntryCount, 0);
  });

  test('扫描未结束时逐项发布资源与刮削作品', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final fixture = await _Fixture.create((path) async {
      if (path == 'Movies') {
        return [
          _file('Movies/A.2020.mkv'),
          _file('Movies/Child', directory: true),
        ];
      }
      entered.complete();
      await release.future;
      return [];
    });
    addTearDown(fixture.close);
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final c = fixture.controller;
    final scan = c.scan(fixture.root);
    await entered.future;
    await _until(() => c.scrapeProcessed == 1);
    expect((await c.store.resources()).single.workId, isNotNull);
    await _until(() => c.recentWorks.any((work) => work.tmdbId == 1));
    expect(c.busy, isTrue);
    expect((await c.store.root(fixture.root.id))!.status, 'running');
    expect(await c.store.cachedWork(FilmMediaType.movie, 1), isNotNull);
    expect(c.retainedScrapeSessionCount, 1);
    expect(c.retainedScrapeEntryCount, 1);
    release.complete();
    await scan;
    await c.waitForScraping();
    expect(c.scraping, isFalse);
    expect((await c.store.resources()).single.workId, isNotNull);
    expect(await c.store.pendingCount(), 0);
    expect(c.retainedScrapeSessionCount, 0);
    expect(c.retainedScrapeEntryCount, 0);
  });

  for (final cancel in [true, false]) {
    test('扫描取消或失败保留已发现资源与旧记录，刮削继续 cancel=$cancel', () async {
      final nextDirectory = Completer<void>();
      final directoryRelease = Completer<void>();
      final metadataEntered = Completer<void>();
      final metadataRelease = Completer<void>();
      final fixture = await _Fixture.create(
        (path) async {
          if (path == 'Movies') {
            return [
              _file('Movies/A.2020.mkv'),
              _file('Movies/B.2020.mkv'),
              _file('Movies/Child', directory: true),
            ];
          }
          nextDirectory.complete();
          await directoryRelease.future;
          if (!cancel) throw AppException.network('Test directory unavailable');
          return [_file('$path/C.2020.mkv')];
        },
        api: (options) async {
          if (!metadataEntered.isCompleted) metadataEntered.complete();
          await metadataRelease.future;
          return _response(options);
        },
      );
      addTearDown(fixture.close);
      final c = fixture.controller;
      await fixture.inventory(['Movies/A.2020.mkv']);
      final old = (await c.store.resources()).single;
      final scan = c.scan(fixture.root);
      await Future.wait([nextDirectory.future, metadataEntered.future]);
      if (cancel) c.cancel();
      directoryRelease.complete();
      await scan;
      expect(c.error, cancel ? 'cancelled' : 'directoryReadFailed');
      expect(c.scraping, isTrue);
      expect(await c.store.resources(), hasLength(2));
      expect((await c.store.resource(old.id))!.availability, 'present');
      metadataRelease.complete();
      await c.waitForScraping().timeout(const Duration(seconds: 10));
      expect(c.scrapeProcessed, 2);
      expect(c.retainedScrapeSessionCount, 0);
      expect(c.retainedScrapeEntryCount, 0);
      expect(
        (await c.store.resources()).every((r) => r.workId != null),
        isTrue,
      );
      expect(await c.store.cachedWork(FilmMediaType.movie, 2), isNotNull);
      expect(
        (await c.store.root(fixture.root.id))!.status,
        cancel ? 'cancelled' : 'failed',
      );
    });
  }

  test('连续刮削结果持续刷新主页，不等待队列全部结束', () async {
    final fixture = await _Fixture.create(
      (_) async => [
        for (var i = 0; i < 12; i++)
          _file('Movies/${String.fromCharCode(65 + i)}.2020.mkv'),
      ],
      api: (options) async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return _response(options);
      },
    );
    addTearDown(fixture.close);
    final c = fixture.controller;
    await c.scan(fixture.root);
    await _until(() => c.recentWorks.isNotEmpty);
    expect(c.scraping, isTrue);
    expect(c.scrapeProcessed, lessThan(12));
    await c.waitForScraping();
    await _until(() => c.recentWorks.length == 12);
  });

  test('刮削故障保留队列，另一个扫描不恢复暂停，用户继续后完整处理', () async {
    final fixture = await _Fixture.create(
      (path) async => [_file('$path/A.2020.mkv'), _file('$path/B.2020.mkv')],
    );
    addTearDown(fixture.close);
    final c = fixture.controller;
    fixture.api.status = 503;
    await c.scan(fixture.root);
    await _until(() => c.scrapePaused);
    expect(c.scrapeError, 'metadataRequestFailed');
    expect(c.scrapeProcessed, 0);
    expect(c.scrapeTotal, 2);
    expect(c.error, isNull);
    final otherId = await c.store.addRoot(
      sourceId: 'dav',
      kind: MediaSourceKind.webdav,
      path: 'Other',
      type: FilmMediaType.movie,
      name: 'Other',
    );
    await c.scan((await c.store.root(otherId))!);
    expect(c.scrapePaused, isTrue);
    expect(c.scrapeTotal, 4);
    expect(c.retainedScrapeSessionCount, 2);
    expect(c.retainedScrapeEntryCount, 4);
    expect((await c.store.root(otherId))!.status, 'completed');
    fixture.api.status = 200;
    c.toggleScraping();
    await c.waitForScraping().timeout(const Duration(seconds: 10));
    expect(c.scrapeError, isNull);
    expect(c.scrapeProcessed, 4);
    expect(await c.store.pendingCount(), 0);
    expect(c.retainedScrapeSessionCount, 0);
    expect(c.retainedScrapeEntryCount, 0);
  });

  test('单独刮削不读取目录，关闭应用能释放暂停中的任务', () async {
    final fixture = await _Fixture.create(
      (_) async => throw StateError('Scraping read a directory'),
    );
    await fixture.inventory(['Movies/A.2020.mkv']);
    fixture.api.status = 503;
    final c = fixture.controller;
    await c.scrape(fixture.root);
    await _until(() => c.scrapePaused);
    expect(c.busy, isFalse);
    expect(fixture.dav.reads, 0);
    expect(c.retainedScrapeSessionCount, 1);
    await fixture.close().timeout(const Duration(seconds: 5));
    expect(c.retainedScrapeSessionCount, 0);
    expect(c.retainedScrapeEntryCount, 0);
  });

  test('凭据读取失败只影响刮削，扫描仍提交完整清单', () async {
    final fixture = await _Fixture.create(
      (_) async => [_file('Movies/A.2020.mkv')],
      credentials: _FailedToken(),
    );
    addTearDown(fixture.close);
    await fixture.controller.scan(fixture.root);
    expect(fixture.controller.scrapeError, 'credentialStoreFailed');
    expect(fixture.controller.error, isNull);
    expect(
      (await fixture.controller.store.root(fixture.root.id))!.status,
      'completed',
    );
    expect(await fixture.controller.store.resources(), hasLength(1));
    expect(fixture.api.requests, isEmpty);
  });

  test('正在执行刮削时关闭能释放剩余任务引用', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final fixture = await _Fixture.create(
      (_) async => [_file('Movies/A.2020.mkv'), _file('Movies/B.2020.mkv')],
      api: (options) async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
        return _response(options);
      },
    );
    final c = fixture.controller;
    await c.scan(fixture.root);
    await entered.future;
    expect(c.retainedScrapeSessionCount, 1);
    final closing = fixture.close();
    release.complete();
    await closing.timeout(const Duration(seconds: 5));
    expect(c.retainedScrapeSessionCount, 0);
    expect(c.retainedScrapeEntryCount, 0);
  });

  test('增量扫描递归新增文件、恢复缺失位置并保留既有记录，不重复刮削', () async {
    final fixture = await _Fixture.create(
      (path) async => path == 'Movies'
          ? [_file('Movies/B.2020.mkv'), _file('Movies/Child', directory: true)]
          : [_file('$path/C.2020.mkv')],
    );
    addTearDown(fixture.close);
    final c = fixture.controller;
    await fixture.inventory(['Movies/A.2020.mkv', 'Movies/B.2020.mkv']);
    await c.store.bind(
      await c.store.resources(),
      const FilmWork(
        type: FilmMediaType.movie,
        tmdbId: 1,
        title: 'A',
        originalTitle: 'A',
        overview: '',
        language: 'zh-CN',
        metadata: {},
      ),
    );
    final baseline = await c.store.resources();
    await fixture.inventory(['Movies/A.2020.mkv']);
    expect((await c.store.resource(baseline.last.id))!.availability, 'missing');
    await c.scan(fixture.root, incremental: true);
    await c.waitForScraping();
    final resources = await c.store.resources();
    expect(resources, hasLength(3));
    for (final original in baseline) {
      final actual = (await c.store.resource(original.id))!;
      expect(actual.availability, 'present');
      expect(actual.workId, original.workId);
      expect(actual.bindingVersion, original.bindingVersion);
      expect(actual.bindingOrigin, 'manual');
    }
    expect(resources.last.workId, isNotNull);
    expect(c.scrapeTotal, 2);
    expect(
      fixture.api.requests
          .where((r) => r.path.contains('/search/'))
          .map((r) => r.queryParameters['query']),
      ['C'],
    );
    final requestCount = fixture.api.requests.length;
    await c.scan(fixture.root, incremental: true);
    await c.waitForScraping();
    expect(c.scrapeTotal, 0);
    expect(fixture.api.requests, hasLength(requestCount));
    expect(await c.store.resources(), hasLength(3));
    await c.scan(fixture.root);
    await c.waitForScraping();
    expect(
      (await c.store.resource(baseline.first.id))!.availability,
      'missing',
    );
  });

  for (final cancel in [true, false]) {
    test('增量扫描取消或失败保留记录，已入队刮削继续 cancel=$cancel', () async {
      final reached = Completer<void>();
      final releaseDirectory = Completer<void>();
      final enteredMetadata = Completer<void>();
      final releaseMetadata = Completer<void>();
      final fixture = await _Fixture.create(
        (path) async {
          if (path == 'Movies') {
            return [
              _file('Movies/B.2020.mkv'),
              _file('Movies/Child', directory: true),
            ];
          }
          reached.complete();
          await releaseDirectory.future;
          if (!cancel) throw AppException.network('Test directory unavailable');
          return [];
        },
        api: (options) async {
          if (!enteredMetadata.isCompleted) enteredMetadata.complete();
          await releaseMetadata.future;
          return _response(options);
        },
      );
      addTearDown(fixture.close);
      final c = fixture.controller;
      await fixture.inventory(['Movies/A.2020.mkv']);
      final original = (await c.store.resources()).single;
      final scan = c.scan(fixture.root, incremental: true);
      await Future.wait([reached.future, enteredMetadata.future]);
      if (cancel) c.cancel();
      releaseDirectory.complete();
      await scan;
      expect(c.error, cancel ? 'cancelled' : 'directoryReadFailed');
      expect(await c.store.resources(), hasLength(2));
      expect((await c.store.resource(original.id))!.availability, 'present');
      expect(c.scraping, isTrue);
      releaseMetadata.complete();
      await c.waitForScraping();
      expect(c.scrapeProcessed, 1);
      expect((await c.store.resource(original.id))!.workId, isNull);
      expect(
        (await c.store.resources())
            .singleWhere((r) => r.id != original.id)
            .workId,
        isNotNull,
      );
      expect(await c.store.cachedWork(FilmMediaType.movie, 2), isNotNull);
    });
  }

  test('增量刮削只处理本根可用的未匹配剧集，忽略已关联待映射和缺失文件', () async {
    final fixture = await _Fixture.create(
      (_) async => throw StateError('Unexpected directory read'),
      type: FilmMediaType.tv,
      api: (options) async {
        if (options.path.contains('/season/')) {
          return {'season_number': 1, 'episodes': <Object>[]};
        }
        final data = {
          'id': 20,
          'name': 'Unmatched',
          'original_name': 'Unmatched',
          'first_air_date': '2021-01-01',
          'overview': '',
          'genres': <Object>[],
          'backdrops': <Object>[],
        };
        if (options.path.contains('/search/')) {
          expect(options.queryParameters['query'], 'Unmatched');
          return {
            'results': [data],
          };
        }
        return data;
      },
    );
    addTearDown(fixture.close);
    final c = fixture.controller;
    final names = [
      'Unmatched.S01E01',
      'Matched.S01E02',
      'MappedPending.S01E03',
      'Missing.S01E04',
    ];
    await fixture.inventory([for (final name in names) 'Movies/$name.mkv']);
    final old = await c.store.resources(rootId: fixture.root.id);
    final unmatched = old.singleWhere((r) => r.name.startsWith('Unmatched.'));
    final matched = old.singleWhere((r) => r.name.startsWith('Matched.'));
    final unmapped = old.singleWhere(
      (r) => r.name.startsWith('MappedPending.'),
    );
    final missing = old.singleWhere((r) => r.name.startsWith('Missing.'));
    await c.store.bind(
      [matched, unmapped],
      const FilmWork(
        type: FilmMediaType.tv,
        tmdbId: 10,
        title: 'Matched',
        originalTitle: 'Matched',
        overview: '',
        language: 'zh-CN',
        metadata: {},
      ),
    );
    await c.store.mapEpisodes({(await c.store.resource(matched.id))!: (1, 2)});
    await fixture.inventory([
      for (final name in names.take(3)) 'Movies/$name.mkv',
    ]);
    final bound = (await c.store.resource(unmapped.id))!;
    final otherId = await c.store.addRoot(
      sourceId: 'dav',
      kind: MediaSourceKind.webdav,
      path: 'Other',
      type: FilmMediaType.tv,
      name: 'Other',
    );
    final other = (await c.store.root(otherId))!;
    final generation = await c.store.beginScan(otherId);
    await c.store.stage(other, generation, const [
      FilmScanEntry(
        path: 'Other/Other.S01E01.mkv',
        parentPath: 'Other',
        name: 'Other.S01E01.mkv',
        mediaKind: 'video',
      ),
    ]);
    await c.store.commitScan(otherId, generation, cancelled: () => false);
    await c.scrape(fixture.root, incremental: true);
    await c.waitForScraping();
    expect(c.scrapeTotal, 1);
    expect(c.scrapeProcessed, 1);
    expect(c.scrapedCount, 1);
    expect(fixture.dav.reads, 0);
    expect((await c.store.resources(rootId: otherId)).single.workId, isNull);
    final actual = (await c.store.resource(unmatched.id))!;
    expect(actual.workId, isNotNull);
    expect((actual.season, actual.episode), (1, 1));
    final pending = (await c.store.resource(bound.id))!;
    expect(pending.workId, bound.workId);
    expect(pending.bindingVersion, bound.bindingVersion);
    expect(pending.season, isNull);
    expect((await c.store.resource(missing.id))!.workId, isNull);
    expect((await c.store.resource(missing.id))!.availability, 'missing');
    final requestCount = fixture.api.requests.length;
    await c.scrape(fixture.root, incremental: true);
    await c.waitForScraping();
    expect(c.scrapeTotal, 0);
    expect(fixture.api.requests, hasLength(requestCount));
  });

  test('电影根的增量刮削不建立队列', () async {
    final fixture = await _Fixture.create(
      (_) async => throw StateError('Unexpected directory read'),
    );
    addTearDown(fixture.close);
    await fixture.inventory(['Movies/A.2020.mkv']);
    await fixture.controller.scrape(fixture.root, incremental: true);
    expect(fixture.controller.scraping, isFalse);
    expect(fixture.controller.scrapeTotal, 0);
    expect(fixture.api.requests, isEmpty);
  });

  for (final language in AppLanguage.values) {
    testWidgets('扫描已完成时刮削控制仍可见，四语言与大字号 $language', (tester) async {
      tester.view.physicalSize = const Size(640, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final prepared = (await tester.runAsync(() async {
        final entered = Completer<void>();
        final release = Completer<void>();
        final f = await _Fixture.create(
          (_) async => [_file('Movies/A.2020.mkv')],
          api: (options) async {
            if (!entered.isCompleted) entered.complete();
            await release.future;
            return _response(options);
          },
        );
        await f.controller.scan(f.root);
        await entered.future;
        return (f, release);
      }))!;
      final (fixture, release) = prepared;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(fixture.close);
      });
      final c = fixture.controller;
      final l10n = AppLocalizations(language);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          locale: language.locale,
          supportedLocales: AppLanguage.values.map((value) => value.locale),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: AnimatedBuilder(
              animation: c,
              builder: (_, _) => FilmCatalogTasks(catalog: c),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text(l10n.text('取消扫描')), findsNothing);
      expect(find.text(l10n.text('正在刮削…')), findsOneWidget);
      await tester.tap(find.text(l10n.text('暂停刮削')));
      await tester.pump();
      expect(find.text(l10n.text('刮削已暂停')), findsOneWidget);
      await tester.tap(find.text(l10n.text('继续刮削')));
      await tester.pump();
      await tester.runAsync(() async {
        release.complete();
        await c.waitForScraping();
      });
      await tester.pump();
      expect(find.text(l10n.text('刮削完成')), findsNothing);
      expect(find.text(l10n.text('暂停刮削')), findsNothing);
      expect(c.scrapeCompletion, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('任务卡片只显示扫描和刮削自己的两条进度', (tester) async {
    final prepared = (await tester.runAsync(() async {
      final directoryEntered = Completer<void>();
      final releaseDirectory = Completer<void>();
      final metadataEntered = Completer<void>();
      final releaseMetadata = Completer<void>();
      final fixture = await _Fixture.create(
        (path) async {
          if (path == 'Movies') {
            return [
              _file('Movies/A.2020.mkv'),
              _file('Movies/Child', directory: true),
            ];
          }
          directoryEntered.complete();
          await releaseDirectory.future;
          return [];
        },
        api: (options) async {
          if (!metadataEntered.isCompleted) metadataEntered.complete();
          await releaseMetadata.future;
          return _response(options);
        },
      );
      final scan = fixture.controller.scan(fixture.root);
      await Future.wait([
        directoryEntered.future,
        metadataEntered.future,
      ]).timeout(const Duration(seconds: 5));
      return (fixture, releaseDirectory, releaseMetadata, scan);
    }))!;
    final (fixture, releaseDirectory, releaseMetadata, scan) = prepared;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.close);
    });
    final c = fixture.controller;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatedBuilder(
            animation: c,
            builder: (_, _) => FilmCatalogTasks(catalog: c, panel: true),
          ),
        ),
      ),
    );
    expect(find.byType(LinearProgressIndicator), findsNWidgets(2));
    expect(find.text('取消扫描'), findsOneWidget);
    expect(find.text('暂停刮削'), findsOneWidget);
    await tester.runAsync(() async {
      releaseDirectory.complete();
      await scan;
    });
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('取消扫描'), findsNothing);
    await tester.runAsync(() async {
      releaseMetadata.complete();
      await c.waitForScraping();
    });
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('空闲'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue);
}

class _Fixture {
  _Fixture(this.temp, this.controller, this.root, this.api, this.dav);
  final Directory temp;
  final FilmCatalogController controller;
  final FilmCatalogRoot root;
  final _Api api;
  final _Dav dav;

  static Future<_Fixture> create(
    Future<List<WebDavFile>> Function(String) directory, {
    Future<Map<String, dynamic>> Function(RequestOptions)? api,
    TmdbCredentialStore? credentials,
    FilmMediaType type = FilmMediaType.movie,
  }) async {
    final temp = await Directory.systemTemp.createTemp('film_tasks_');
    final store = await FilmCatalogStore.open(p.join(temp.path, 'catalog.db'));
    final id = await store.addRoot(
      sourceId: 'dav',
      kind: MediaSourceKind.webdav,
      path: 'Movies',
      type: type,
      name: 'Movies',
    );
    final adapter = _Api(api ?? (options) async => _response(options));
    final tmdb = TmdbMetadataService(
      credentials: credentials ?? _Token(),
      dio: Dio()..httpClientAdapter = adapter,
    );
    final dav = _Dav(directory);
    final c = FilmCatalogController(
      store: store,
      tmdb: tmdb,
      images: FilmCatalogImageCache(
        Directory(p.join(temp.path, 'images')),
        tmdb,
      ),
      sourceFor: (_) => WebDavMediaSourceAdapter(dav),
    );
    return _Fixture(temp, c, (await store.root(id))!, adapter, dav);
  }

  Future<void> inventory(List<String> files) async {
    final generation = await controller.store.beginScan(root.id);
    await controller.store.stage(root, generation, [
      for (final file in files)
        FilmScanEntry(
          path: file,
          parentPath: p.posix.dirname(file),
          name: p.posix.basename(file),
          mediaKind: 'video',
        ),
    ]);
    await controller.store.commitScan(
      root.id,
      generation,
      cancelled: () => false,
    );
  }

  Future<void> close() async {
    await controller.close();
    await temp.delete(recursive: true);
  }
}

WebDavFile _file(String path, {bool directory = false}) => WebDavFile(
  name: p.posix.basename(path),
  href: '/dav/$path${directory ? '/' : ''}',
  isDirectory: directory,
);

Map<String, dynamic> _response(RequestOptions options) {
  final id = options.path.contains('/search/')
      ? (options.queryParameters['query'] as String).codeUnitAt(0) - 64
      : int.parse(options.path.split('/').where((s) => s != 'images').last);
  final movie = <String, dynamic>{
    'id': id,
    'title': String.fromCharCode(64 + id),
    'original_title': String.fromCharCode(64 + id),
    'release_date': '2020-01-01',
    'overview': '',
    'genres': [],
    'backdrops': [],
  };
  return options.path.contains('/search/')
      ? {
          'results': [movie],
        }
      : movie;
}

class _Token extends TmdbCredentialStore {
  @override
  Future<String?> read() async => 'fake-token';
}

class _FailedToken extends TmdbCredentialStore {
  @override
  Future<String?> read() async =>
      throw const FilmCatalogException('credentialStoreFailed');
}

class _Dav extends WebDAVService {
  _Dav(this.directory)
    : super(
        client: WebDavClient(baseUrl: 'https://film-tasks.invalid/dav'),
        profileId: 'dav',
      );
  final Future<List<WebDavFile>> Function(String) directory;
  int reads = 0;
  @override
  Future<List<WebDavFile>> fetchCatalogDirectory(String path) async {
    reads++;
    return directory(path);
  }
}

class _Api implements HttpClientAdapter {
  _Api(this.response);
  final Future<Map<String, dynamic>> Function(RequestOptions) response;
  int status = 200;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final data = status == 200 ? await response(options) : <String, dynamic>{};
    return ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
