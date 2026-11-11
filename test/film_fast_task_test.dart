import 'support/legacy_film_catalog.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ffi' hide Size;
import 'dart:math' as math;
import 'dart:ui' show ImageByteFormat;
import 'package:flutter/services.dart';
import 'package:streampath/domain/services/film_file_metadata.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:streampath/data/models/app_language.dart';
import 'package:streampath/presentation/localization/app_localizations.dart';
import 'package:streampath/presentation/theme/app_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as win32;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/film_fast_task.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/domain/services/local_media_source.dart';
import 'package:streampath/data/remote/webdav_client.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/film_catalog_scanner.dart';
import 'package:streampath/domain/services/film_fast_task_runner.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';
import 'package:streampath/domain/services/webdav_media_source_adapter.dart';
import 'package:streampath/domain/services/webdav_service.dart';
import 'package:streampath/presentation/controllers/film_catalog_controller.dart';
import 'package:streampath/presentation/widgets/film_fast_task_ui.dart';

void main() {
  setUpAll(() {
    HttpOverrides.global = null;
  });
  test('checkpoint stores endpoint identity without URL credentials', () async {
    final f = await _Fixture.create();
    addTearDown(f.close);
    Future<Map<String, dynamic>> snapshot(String token) =>
        FilmFastTaskRunner.snapshot(
          f.c.store,
          f.c.matcher,
          f.root,
          WebDavMediaSourceAdapter(
            WebDAVService(
              client: WebDavClient(
                baseUrl: 'https://user:secret@example.test/dav?token=$token',
                username: 'user',
                password: 'separate-secret',
              ),
              profileId: f.root.sourceId,
            ),
          ),
        );
    final first = jsonEncode(await snapshot('signed-token'));
    expect(first, isNot(contains('secret')));
    expect(first, isNot(contains('signed-token')));
    expect(first, isNot(contains('https://')));
    expect(first, isNot(jsonEncode(await snapshot('changed-token'))));
  });
  for (final status in [401, 429]) {
    test('source HTTP $status pauses with an actionable reason', () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      f.failureStatus = status;
      await f.c.scan(f.root, executionMode: FilmTaskExecutionMode.fullSpeed);
      final task = (await f.c.store.fastTask())!;
      expect(task.status, 'paused');
      expect(
        task.error,
        status == 401
            ? 'fastSourceAuthenticationFailed'
            : 'fastSourceRateLimited',
      );
      expect(f.calls, ['Movies']);
    });
  }
  test(
    'local full speed preserves scoped and incremental inventory semantics',
    () async {
      final temp = await Directory.systemTemp.createTemp('fast_local_');
      final media = Directory(p.join(temp.path, 'media'));
      for (final path in [
        'Outside.2020.mkv',
        'Keep/Old.2020.mkv',
        'Skip/Hidden.mkv',
        'pointer.strm',
      ]) {
        await File(
          p.joinAll([media.path, ...path.split('/')]),
        ).create(recursive: true);
      }
      await Directory(
        p.join(media.path, 'Disc', 'BDMV'),
      ).create(recursive: true);
      final config = LocalRootConfig(
        rootId: 'fixture',
        displayName: 'Local',
        path: media.path,
      );
      final source = LocalMediaSource(config);
      final store = await FilmCatalogStore.open(
        p.join(temp.path, 'catalog.db'),
      );
      final id = await store.addRoot(
        sourceId: config.sourceId,
        kind: MediaSourceKind.local,
        path: '',
        type: FilmMediaType.movie,
        name: 'Local',
      );
      await store.setPreference('directory_exclusions', {
        'names': ['Skip'],
        'exact': true,
      });
      final root = (await store.root(id))!;
      final metadata = _Metadata();
      final c = FilmCatalogController(
        store: store,
        tmdb: metadata,
        images: FilmCatalogImageCache(
          Directory(p.join(temp.path, 'images')),
          metadata,
        ),
        sourceFor: (_) => source,
      );
      try {
        await c.scan(root, executionMode: FilmTaskExecutionMode.fullSpeed);
        final outsideId = (await store.resources())
            .firstWhere((r) => r.path.startsWith('Outside'))
            .id;
        expect(
          (await store.resources()).map((r) => r.path),
          unorderedEquals(['Outside.2020.mkv', 'Keep/Old.2020.mkv', 'Disc']),
        );
        await File(p.join(media.path, 'Keep', 'Old.2020.mkv')).delete();
        await File(p.join(media.path, 'Keep', 'New.2020.mkv')).create();
        await c.scan(
          root,
          scope: FilmScanScope(root.id, 'Keep'),
          executionMode: FilmTaskExecutionMode.fullSpeed,
        );
        expect(
          (await store.resources()).firstWhere((r) => r.id == outsideId).path,
          'Outside.2020.mkv',
        );
        await File(p.join(media.path, 'Keep', 'Newer.2020.mkv')).create();
        await c.scan(
          root,
          incremental: true,
          executionMode: FilmTaskExecutionMode.fullSpeed,
        );
        expect(
          (await store.resources()).map((r) => r.path),
          unorderedEquals([
            'Outside.2020.mkv',
            'Keep/New.2020.mkv',
            'Keep/Newer.2020.mkv',
            'Disc',
          ]),
        );
        expect(await store.fastTask(), isNull);
      } finally {
        await c.close();
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'network fallback NFO updates are prepared and committed in input order',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      f.tree['Movies'] = ['A.2020.mkv', 'B.2020.mkv'];
      _OrderedFiles? files;
      f.metadataFactory = (root) => files = _OrderedFiles(f.source, root);
      await f.c.scan(f.root, executionMode: FilmTaskExecutionMode.fullSpeed);
      expect(await f.c.store.fastTask(), isNull);
      expect(files!.completed, ['A.2020.mkv', 'B.2020.mkv']);
      expect(
        (await f.c.store.works(type: FilmMediaType.movie)).single.title,
        'B.2020.mkv',
      );
    },
  );

  test('v9 upgrade backs up and preserves inventory preferences', () async {
    final f = await _Fixture.create();
    addTearDown(f.close);
    await f.c.store.setPreference('migration_fixture', true);
    await f.closeController();
    final legacy = await databaseFactoryFfi.openDatabase(
      p.join(f.temp.path, 'catalog.db'),
    );
    for (final table in ['fast_task_jobs', 'fast_task_roots', 'fast_tasks']) {
      await legacy.execute('DROP TABLE $table');
    }
    await restoreVersion10Fixture(legacy);
    await legacy.setVersion(9);
    await legacy.close();
    await f.open();
    expect(await f.c.store.preference('migration_fixture'), isTrue);
    expect(await f.c.store.fastTask(), isNull);
    expect(
      f.temp.listSync().where((file) => file.path.contains('.before-v10-')),
      hasLength(1),
    );
  });
  test(
    'parallel scan preserves inventory, exclusions, disc boundaries and manual bindings',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      f.tree['Movies'] = [
        'A/',
        'B/',
        'Disc/',
        'DVD/',
        'old.mkv',
        'pointer.strm',
        'film.iso',
      ];
      f.tree['Movies/A'] = ['TitleA.2020.mkv'];
      f.tree['Movies/B'] = ['TitleB.2020.mkv'];
      f.tree['Movies/Disc'] = ['BDMV/'];
      f.tree['Movies/DVD'] = ['VIDEO_TS/'];
      final scanner = FilmCatalogScanner(
        f.c.store,
        remoteInterval: Duration.zero,
      );
      await scanner.scan(f.root, f.source);
      final old = await f.c.store.resources();
      final oldIds = {for (final row in old) row.path: row.id};
      await f.c.store.bind(
        old.where((row) => row.path.endsWith('old.mkv')).toList(),
        const FilmWork(
          type: FilmMediaType.movie,
          tmdbId: 10,
          title: 'Manual',
          originalTitle: 'Manual',
          overview: '',
          language: 'zh-CN',
          metadata: {'belongs_to_collection': null},
        ),
      );
      await f.c.scan(f.root, executionMode: FilmTaskExecutionMode.fullSpeed);
      expect(await f.c.store.fastTask(), isNull);
      final current = await f.c.store.resources();
      expect({for (final row in current) row.path: row.id}, oldIds);
      expect(
        current.firstWhere((row) => row.path.endsWith('old.mkv')).bindingOrigin,
        'manual',
      );
      expect(current.map((row) => row.path), contains('Movies/Disc'));
      expect(
        current
            .map((row) => row.path)
            .any((path) => path.contains('VIDEO_TS') || path.contains('BDMV')),
        isFalse,
      );
      expect(f.peak, greaterThan(1));
    },
  );

  test(
    'close and reopen resumes pending directories without reading committed directories again',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      f.tree['Movies'] = ['A/', 'B/', 'root.mkv'];
      f.tree['Movies/A'] = ['TitleA.2020.mkv'];
      f.tree['Movies/B'] = ['TitleB.2020.mkv'];
      f.holdChildren = Completer<void>();
      final run = f.c.scan(
        f.root,
        executionMode: FilmTaskExecutionMode.fullSpeed,
      );
      await _until(() => f.calls.contains('Movies/A'));
      await f.c.pauseFastTask();
      await run;
      expect((await f.c.store.fastTask())!.status, 'paused');
      expect((await f.c.store.fastTask())!.error, isNull);
      final rootReads = f.calls.where((path) => path == 'Movies').length;
      await f.reopen();
      f.holdChildren!.complete();
      f.holdChildren = null;
      await f.c.resumeFastTask();
      expect(await f.c.store.fastTask(), isNull);
      expect(f.calls.where((path) => path == 'Movies').length, rootReads);
      expect((await f.c.store.resources()).length, 3);
      expect((await f.c.store.root(f.root.id))!.status, 'completed');
    },
  );

  test(
    'metadata error pauses, keeps original availability and blocks ordinary scans of owned roots',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final generation = await f.c.store.beginScan(f.root.id);
      await f.c.store.stage(f.root, generation, [
        const FilmScanEntry(
          path: 'Movies/old.mkv',
          parentPath: 'Movies',
          name: 'old.mkv',
          mediaKind: 'video',
        ),
      ]);
      await f.c.store.commitScan(f.root.id, generation, cancelled: () => false);
      f.tree['Movies'] = ['A/', 'Title.2020.mkv'];
      f.holdChildren = Completer<void>();
      f.metadata.failure = 'rateLimited';
      await f.c.scan(f.root, executionMode: FilmTaskExecutionMode.fullSpeed);
      final task = (await f.c.store.fastTask())!;
      expect(task.status, 'paused');
      expect(task.error, 'rateLimited');
      expect(
        (await f.c.store.resources())
            .firstWhere((row) => row.path.endsWith('old.mkv'))
            .availability,
        'present',
      );
      await f.c.scan(f.root);
      expect(f.c.error, 'fastTaskPending');
      await f.c.scrape(f.root);
      expect(f.c.error, 'fastTaskPending');
      f.holdChildren!.complete();
      f.holdChildren = null;
      f.metadata.failure = null;
      await f.c.resumeFastTask();
      expect(await f.c.store.fastTask(), isNull);
      expect(
        (await f.c.store.resources()).where(
          (row) => row.path.endsWith('old.mkv'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'scan completion with unfinished scraping resumes only unfinished entries',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      f.tree['Movies'] = List.generate(16, (i) => 'Title$i.2020.mkv');
      f.metadata.holdAfter = 8;
      f.metadata.hold = Completer<void>();
      final run = f.c.scan(
        f.root,
        executionMode: FilmTaskExecutionMode.fullSpeed,
      );
      await _until(() => f.metadata.calls.length > 8);
      final pausing = f.c.pauseFastTask();
      f.metadata.hold!.complete();
      await pausing;
      await run;
      expect((await f.c.store.fastTask())!.processed, 8);
      expect((await f.c.store.fastRoots()).single.scanComplete, isTrue);
      await f.reopen();
      f.metadata.hold = null;
      await f.c.resumeFastTask();
      expect(await f.c.store.fastTask(), isNull);
      expect(f.calls.where((path) => path == 'Movies').length, 1);
      expect(
        f.metadata.calls
            .take(8)
            .toSet()
            .intersection(f.metadata.calls.skip(16).toSet()),
        isEmpty,
      );
    },
  );

  test(
    'changed language rejects checkpoint and discarding retains discovered resources',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      f.tree['Movies'] = ['A/', 'Title.2020.mkv'];
      f.holdChildren = Completer<void>();
      final run = f.c.scan(
        f.root,
        executionMode: FilmTaskExecutionMode.fullSpeed,
      );
      await _until(() => f.calls.contains('Movies/A'));
      await f.c.pauseFastTask();
      await run;
      await f.c.store.setLanguage('en-US');
      await f.c.resumeFastTask();
      expect((await f.c.store.fastTask())!.error, 'fastCheckpointChanged');
      await f.c.discardFastTask();
      expect(
        (await f.c.store.resources()).single.path,
        'Movies/Title.2020.mkv',
      );
      expect(await f.c.store.fastTask(), isNull);
      f.holdChildren!.complete();
    },
  );

  test(
    'source controller scraping blocks starting a global full-speed task',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      f.tree['Movies'] = ['Title.2020.mkv'];
      f.metadata.hold = Completer<void>();
      final sourceCatalog = f.c.forSource('dav');
      try {
        await sourceCatalog.scan(f.root);
        await _until(() => f.metadata.calls.isNotEmpty);
        expect(f.c.standardTasksActive, isTrue);
        await expectLater(
          f.c.scan(f.root, executionMode: FilmTaskExecutionMode.fullSpeed),
          throwsA(
            isA<FilmCatalogException>().having(
              (e) => e.code,
              'code',
              'scanBusy',
            ),
          ),
        );
      } finally {
        f.metadata.hold!.complete();
        await sourceCatalog.waitForScraping();
        await sourceCatalog.close();
      }
    },
  );

  test(
    'closing during source preparation prevents late task creation',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      f.preparation = Completer<void>();
      final task = f.c.scan(
        f.root,
        executionMode: FilmTaskExecutionMode.fullSpeed,
      );
      final expected = expectLater(
        task,
        throwsA(
          isA<FilmCatalogException>().having(
            (e) => e.code,
            'code',
            'cancelled',
          ),
        ),
      );
      await _until(() => f.c.fullSpeedActive);
      var stopped = false;
      final pause = f.c.pauseFastTask().then((_) => stopped = true);
      await Future<void>.delayed(Duration.zero);
      expect(stopped, isFalse);
      f.preparation!.complete();
      await pause;
      await expected;
      expect(await f.c.store.fastTask(), isNull);
      expect(f.calls, isEmpty);
    },
  );

  test(
    'catalog reads and NFO discovery share the per-server request limit',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      f.withFiles = true;
      f.tree['Movies'] = [
        ...List.generate(8, (i) => 'D$i/'),
        ...List.generate(8, (i) => 'TitleRoot$i.2020.mkv'),
      ];
      for (var i = 0; i < 8; i++) {
        f.tree['Movies/D$i'] = ['Title$i.2020.mkv'];
      }
      await f.c.scan(f.root, executionMode: FilmTaskExecutionMode.fullSpeed);
      expect(await f.c.store.fastTask(), isNull);
      expect(f.peak, inInclusiveRange(2, 8));
      expect(await f.c.store.resources(), hasLength(16));
    },
  );

  test(
    'closing cancels a stalled NFO GET and retains the scrape checkpoint',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      f.withFiles = true;
      f.holdFile = Completer<void>();
      f.tree['Movies'] = ['A.2020.mkv', 'A.2020.nfo'];
      final task = f.c.scan(
        f.root,
        executionMode: FilmTaskExecutionMode.fullSpeed,
      );
      await f.fileEntered.future.timeout(const Duration(seconds: 3));
      await f.c.pauseFastTask().timeout(const Duration(seconds: 2));
      await task;
      expect((await f.c.store.fastTask())!.error, isNull);
      expect((await f.c.store.fastTask())!.processed, 0);
      f.holdFile!.complete();
    },
  );

  test(
    'directory transaction rolls back registration and acknowledgement together',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      await f.c.store.createFastTask(
        [f.root],
        [{}],
        scrapeOnly: false,
        incremental: false,
      );
      final job = (await f.c.store.fastJobs('directory')).single;
      final taskRoot = (await f.c.store.fastRoots()).single;
      const entry = FilmScanEntry(
        path: 'Movies/Title.mkv',
        parentPath: 'Movies',
        name: 'Title.mkv',
        mediaKind: 'video',
      );
      await expectLater(
        f.c.store.stageFastDirectory(f.root, taskRoot, job, [entry, entry], []),
        throwsA(isA<DatabaseException>()),
      );
      expect(await f.c.store.resources(), isEmpty);
      expect((await f.c.store.fastJobs('directory')).single.id, job.id);
      expect((await f.c.store.fastTask())!.directories, 0);
      await f.c.store.claimFastJobs([job]);
      await f.reopen();
      expect((await f.c.store.fastJobs('directory')).single.id, job.id);
    },
  );

  test(
    'independent incremental TV scrape never enumerates source directories',
    () async {
      final f = await _Fixture.create(type: FilmMediaType.tv);
      addTearDown(f.close);
      final generation = await f.c.store.beginScan(f.root.id);
      await f.c.store.stage(f.root, generation, [
        const FilmScanEntry(
          path: 'Movies/Title.S01E01.mkv',
          parentPath: 'Movies',
          name: 'Title.S01E01.mkv',
          mediaKind: 'video',
        ),
      ]);
      await f.c.store.commitScan(f.root.id, generation, cancelled: () => false);
      await f.c.scrape(
        f.root,
        incremental: true,
        executionMode: FilmTaskExecutionMode.fullSpeed,
      );
      expect(await f.c.store.fastTask(), isNull);
      expect(f.calls, isEmpty);
      expect(f.metadata.calls, isNotEmpty);
    },
  );

  testWidgets(
    'progress layout covers four languages, dark glass, light, narrow and enlarged text',
    (tester) async {
      final f = (await tester.runAsync(_Fixture.create))!;
      addTearDown(() => tester.runAsync(f.close));
      tester.view.physicalSize = const Size(760, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        final bytes = await File(r'C:\Windows\Fonts\msyh.ttc').readAsBytes();
        final fonts = FontLoader('Microsoft YaHei')
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await fonts.load();
      });
      final boundaryKey = GlobalKey();
      for (final language in AppLanguage.values) {
        for (final glass in [false, true]) {
          f.c.fastTaskState.value = const FilmFastTask(
            id: 1,
            status: 'running',
            scrapeOnly: false,
            incremental: false,
            createdAt: 0,
            elapsedMs: 12500,
            directories: 129,
            discoveredDirectories: 300,
            files: 4200,
            processed: 1280,
            total: 4200,
            matched: 1200,
            path: 'Movies/Example/Season 01/Episode 01',
          );
          await tester.pumpWidget(
            MaterialApp(
              locale: language.locale,
              supportedLocales: AppLanguage.values.map(
                (language) => language.locale,
              ),
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              theme: glass
                  ? AppTheme.dark(glass: true, fontFamily: 'Microsoft YaHei')
                  : AppTheme.light(fontFamily: 'Microsoft YaHei'),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(1.8)),
                child: child!,
              ),
              home: RepaintBoundary(
                key: boundaryKey,
                child: Scaffold(
                  body: FilmFastTaskProgress(catalog: Future.value(f.c)),
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull);
          expect(find.textContaining('129'), findsOneWidget);
          await tester.runAsync(() async {
            final boundary =
                boundaryKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = boundary.toImageSync();
            final data = await image.toByteData(format: ImageByteFormat.png);
            image.dispose();
            final file = File(
              'build/full-speed-validation/progress-${language.name}-${glass ? 'glass' : 'light'}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(data!.buffer.asUint8List());
          });
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('risk dialog cancel does not start work', (tester) async {
    final f = (await tester.runAsync(_Fixture.create))!;
    addTearDown(() => tester.runAsync(f.close));
    var started = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => runFilmFastTask(context, f.c, () async {
                started = true;
              }),
              child: const Text('Start'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(find.text(fastTaskWarning), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(started, isFalse);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _until(bool Function() done) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!done() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue);
}

class _Metadata extends TmdbMetadataService {
  final calls = <String>[];
  bool benchmark = false;
  String? failure;
  Completer<void>? hold;
  int holdAfter = 0;
  @override
  Future<bool> hasToken() async => true;
  @override
  Future<List<FilmWork>> search(
    FilmMediaType type,
    String query,
    String language, {
    int? year,
    int page = 1,
  }) async {
    calls.add(query);
    if (hold != null && calls.length > holdAfter) await hold!.future;
    if (failure != null) throw FilmCatalogException(failure!);
    await Future<void>.delayed(Duration(milliseconds: benchmark ? 300 : 2));
    if (!benchmark) return [];
    final id = int.parse(RegExp(r'\d+').firstMatch(query)!.group(0)!) + 1;
    return [_work(type, id, language)];
  }

  FilmWork _work(FilmMediaType type, int id, String language) => FilmWork(
    type: type,
    tmdbId: id,
    title: 'Bench${id - 1}',
    originalTitle: 'Bench${id - 1}',
    year: 2020,
    overview: '',
    language: language,
    metadata: const {'belongs_to_collection': null},
  );

  @override
  Future<FilmWork> details(
    FilmMediaType type,
    int id,
    String language, {
    LogoChooser? chooseLogo,
  }) async {
    if (!benchmark) {
      return super.details(type, id, language, chooseLogo: chooseLogo);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return _work(type, id, language);
  }
}

class _OrderedFiles extends FilmFileMetadata {
  _OrderedFiles(super.source, super.root)
    : super(localMode: false, canWrite: false);
  final completed = <String>[];
  @override
  Future<FilmLocalMetadata?> load(FilmScanEntry entry, String language) async {
    await Future<void>.delayed(
      Duration(milliseconds: entry.name.startsWith('A') ? 50 : 1),
    );
    completed.add(entry.name);
    return FilmLocalMetadata(
      FilmWork(
        type: FilmMediaType.movie,
        tmdbId: 2,
        title: entry.name,
        originalTitle: entry.name,
        overview: '',
        language: language,
        metadataOrigin: 'nfo',
        fetchedAt: DateTime.now().millisecondsSinceEpoch,
      ),
      null,
      null,
    );
  }
}

class _Fixture {
  _Fixture(this.temp, this.server);
  final Directory temp;
  final HttpServer server;
  final tree = <String, List<String>>{'Movies': []};
  final calls = <String>[];
  final metadata = _Metadata();
  int active = 0, peak = 0;
  int? failureStatus;
  Completer<void>? holdChildren;
  Completer<void>? preparation;
  Completer<void>? holdFile;
  final fileEntered = Completer<void>();
  bool withFiles = false;
  FilmFileMetadata? Function(FilmCatalogRoot)? metadataFactory;
  late FilmCatalogController c;
  bool controllerClosed = false;
  late FilmCatalogRoot root;
  late WebDavMediaSourceAdapter source;
  static Future<_Fixture> create({
    FilmMediaType type = FilmMediaType.movie,
  }) async {
    final f = _Fixture(
      await Directory.systemTemp.createTemp('fast_task_'),
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    f.server.listen(f.handle);
    await f.open(type: type);
    return f;
  }

  Future<void> open({FilmMediaType type = FilmMediaType.movie}) async {
    controllerClosed = false;
    final store = await FilmCatalogStore.open(p.join(temp.path, 'catalog.db'));
    final existing = await store.roots();
    final id = existing.isEmpty
        ? await store.addRoot(
            sourceId: 'dav',
            kind: MediaSourceKind.webdav,
            path: 'Movies',
            type: type,
            name: 'Movies',
          )
        : existing.single.id;
    root = (await store.root(id))!;
    source = WebDavMediaSourceAdapter(
      WebDAVService(
        client: WebDavClient(baseUrl: 'http://127.0.0.1:${server.port}/dav/'),
        profileId: 'dav',
      ),
    );
    c = FilmCatalogController(
      store: store,
      tmdb: metadata,
      images: FilmCatalogImageCache(
        Directory(p.join(temp.path, 'images')),
        metadata,
      ),
      sourceFor: (_) => source,
      prepareFastSources: (_) async {
        await preparation?.future;
      },
      filesFor: (root) async => metadataFactory != null
          ? metadataFactory!(root)
          : withFiles
          ? FilmFileMetadata(source, root, localMode: false, canWrite: false)
          : null,
      ownsResources: false,
    );
    await c.reloadFastTask();
  }

  Future<void> closeController() async {
    if (controllerClosed) return;
    controllerClosed = true;
    final store = c.store;
    await c.close();
    await store.close();
  }

  Future<void> reopen() async {
    await closeController();
    await open();
  }

  Future<void> handle(HttpRequest request) async {
    final path = Uri.decodeComponent(
      request.uri.path,
    ).replaceFirst('/dav/', '').replaceFirst(RegExp(r'/$'), '');
    calls.add(path);
    active++;
    peak = math.max(peak, active);
    try {
      if (failureStatus != null) {
        request.response.statusCode = failureStatus!;
        await request.response.close();
        return;
      }
      if (request.method == 'GET') {
        if (!fileEntered.isCompleted) fileEntered.complete();
        await holdFile?.future;
        request.response.write('<movie/>');
        await request.response.close();
        return;
      }
      if (path != 'Movies' && holdChildren != null) await holdChildren!.future;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      request.response.statusCode = 207;
      request.response.headers.contentType = ContentType(
        'application',
        'xml',
        charset: 'utf-8',
      );
      request.response.write(
        '<d:multistatus xmlns:d="DAV:">${(tree[path] ?? []).map((name) => '<d:response><d:href>/dav/$path/$name</d:href><d:propstat><d:prop><d:displayname>${name.replaceAll('/', '')}</d:displayname><d:resourcetype>${name.endsWith('/') ? '<d:collection/>' : ''}</d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>').join()}</d:multistatus>',
      );
      await request.response.close();
    } finally {
      active--;
    }
  }

  Future<void> close() async {
    if (holdChildren != null && !holdChildren!.isCompleted) {
      holdChildren!.complete();
    }
    if (metadata.hold != null && !metadata.hold!.isCompleted) {
      metadata.hold!.complete();
    }
    if (holdFile != null && !holdFile!.isCompleted) holdFile!.complete();
    await closeController();
    metadata.close();
    await server.close(force: true);
    await temp.delete(recursive: true);
  }
}

int _cpuMicros() {
  final creation = calloc<win32.FILETIME>();
  final exit = calloc<win32.FILETIME>();
  final kernel = calloc<win32.FILETIME>();
  final user = calloc<win32.FILETIME>();
  try {
    if (win32.GetProcessTimes(
          win32.GetCurrentProcess(),
          creation,
          exit,
          kernel,
          user,
        ) ==
        0) {
      throw StateError('Cannot read benchmark process CPU time');
    }
    int ticks(win32.FILETIME value) =>
        (value.dwHighDateTime << 32) | value.dwLowDateTime;
    return (ticks(kernel.ref) + ticks(user.ref)) ~/ 10;
  } finally {
    calloc.free(creation);
    calloc.free(exit);
    calloc.free(kernel);
    calloc.free(user);
  }
}

Future<void> runFastTaskBenchmark() async {
  HttpOverrides.global = null;
  final results = <Map<String, Object>>[];
  for (var trial = 0; trial < 3; trial++) {
    for (final mode in FilmTaskExecutionMode.values) {
      final f = await _Fixture.create();
      f.metadata.benchmark = true;
      f.tree['Movies'] = List.generate(8, (i) => 'D$i/');
      for (var i = 0; i < 8; i++) {
        f.tree['Movies/D$i'] = [
          'Bench${i * 2}.2020.mkv',
          'Bench${i * 2 + 1}.2020.mkv',
        ];
      }
      try {
        for (final cache in ['cold', 'warm']) {
          f.calls.clear();
          f.metadata.calls.clear();
          f.peak = 0;
          var peakRss = ProcessInfo.currentRss;
          final sampling = Timer.periodic(const Duration(milliseconds: 20), (
            _,
          ) {
            peakRss = math.max(peakRss, ProcessInfo.currentRss);
          });
          final cpu = _cpuMicros();
          final clock = Stopwatch()..start();
          try {
            await f.c.scan(f.root, executionMode: mode);
            await f.c.waitForScraping();
          } finally {
            sampling.cancel();
          }
          clock.stop();
          expect(await f.c.store.fastTask(), isNull);
          final resources = await f.c.store.resources();
          expect(resources, hasLength(16));
          expect(
            resources.every(
              (r) => r.workId != null && r.availability == 'present',
            ),
            isTrue,
          );
          results.add({
            'trial': trial,
            'mode': mode.name,
            'cache': cache,
            'elapsedMs': clock.elapsedMilliseconds,
            'cpuMicros': _cpuMicros() - cpu,
            'peakRssBytes': peakRss,
            'directories': f.calls.length,
            'directoryConcurrency': f.peak,
            'searchRequests': f.metadata.calls.length,
            'resources': resources.length,
          });
        }
        final close = Stopwatch()..start();
        await f.closeController();
        close.stop();
        results.last['closeMs'] = close.elapsedMilliseconds;
      } finally {
        await f.close();
      }
    }
  }
  for (var trial = 0; trial < 3; trial++) {
    for (final cache in ['cold', 'warm']) {
      final normal = results.singleWhere(
        (r) =>
            r['trial'] == trial &&
            r['cache'] == cache &&
            r['mode'] == 'standard',
      );
      final fast = results.singleWhere(
        (r) =>
            r['trial'] == trial &&
            r['cache'] == cache &&
            r['mode'] == 'fullSpeed',
      );
      expect(
        (normal['elapsedMs'] as int) / (fast['elapsedMs'] as int),
        greaterThanOrEqualTo(2),
      );
    }
  }
  final output = File('build/full-speed-validation/benchmark.json');
  await output.parent.create(recursive: true);
  await output.writeAsString(
    const JsonEncoder.withIndent('  ').convert(results),
  );
}
