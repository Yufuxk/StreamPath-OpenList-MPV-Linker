import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/film_extra.dart';
import 'package:streampath/data/models/film_watch_state.dart';
import 'package:streampath/data/models/film_playlist.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/data/models/video_queue.dart';
import 'package:streampath/domain/services/film_extra_classifier.dart';
import 'package:streampath/domain/services/film_version_resolver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  final classifier = FilmExtraClassifier(const FilmExtraRules());
  for (final (name, kind) in [
    ('NCOP.mkv', 'ncop'),
    ('NCOP01.mkv', 'ncop'),
    ('NCOP_01.mkv', 'ncop'),
    ('NCOP 01.mkv', 'ncop'),
    ('NCOP-01.mkv', 'ncop'),
    ('NCED_02.m2ts', 'nced'),
    ('PV01.mp4', 'pv'),
    ('PV_02.mkv', 'pv'),
    ('CM-03.mkv', 'cm'),
    ('MENU.mkv', 'menu'),
    ('INFO_01.mkv', 'info'),
    ('SP01.mkv', 'sp'),
    ('OVA_01.mkv', 'ova'),
    ('Creditless OP.mkv', 'ncop'),
    ('Creditless ED.mkv', 'nced'),
    ('无字幕OP.mkv', 'ncop'),
    ('無字幕ED.mkv', 'nced'),
    ('ノンクレジットOP.mkv', 'ncop'),
    ('ＮＣＯＰ＿０１.mkv', 'ncop'),
    ('Show.S0E052.NCED.strm', 'nced'),
    ('NCOP+NCED.mkv', 'mixed'),
    ('下集预告.mkv', 'next'),
  ]) {
    test(
      '分类词元 $name',
      () => expect(
        classifier
            .classify(
              name: name,
              path: 'Library/Work/$name',
              rootPath: 'Library',
            )
            .kind,
        kind,
      ),
    );
  }
  test('目录继承、文件优先、混合目录与公共边界', () {
    for (final (path, kind) in [
      ('Movies/Work/Extras/PV/01.mkv', 'pv'),
      ('Movies/Work/Specials/NCOP/01.mkv', 'ncop'),
      ('Movies/Work/Specials/NCOP/NCED03.mkv', 'nced'),
      ('Movies/Work/Specials/NCOP&ED/01.mkv', 'mixed'),
      ('Movies/Work/Specials/01.mkv', 'other'),
    ]) {
      expect(
        classifier
            .classify(
              name: p.posix.basename(path),
              path: path,
              rootPath: 'Movies',
            )
            .kind,
        kind,
      );
    }
    expect(
      classifier
          .classify(
            name: '01.mkv',
            path: 'Specials/Work/01.mkv',
            rootPath: 'Specials',
          )
          .kind,
      isNull,
    );
    expect(
      classifier
          .classify(
            name: '01.mkv',
            path: 'Movies/SPIDER-MAN/01.mkv',
            rootPath: 'Movies',
          )
          .kind,
      isNull,
    );
    expect(
      classifier
          .classify(
            name: '01.mkv',
            path: 'Other/Work/PV/01.mkv',
            rootPath: 'Movies',
          )
          .kind,
      isNull,
    );
  });
  test('短词边界与光盘结构保护', () {
    for (final name in [
      'SPY×FAMILY.mkv',
      'SPIDER-MAN.mkv',
      'InformationAge.mkv',
      'CMYK.mkv',
      'APVCodec.mkv',
      'ordinary.mkv',
    ]) {
      expect(
        classifier
            .classify(
              name: name,
              path: 'Library/Work/$name',
              rootPath: 'Library',
            )
            .isExtra,
        isFalse,
        reason: name,
      );
    }
    for (final kind in ['iso', 'bdmv']) {
      expect(
        classifier
            .classify(
              name: 'MENU',
              path: 'Library/Work/MENU',
              rootPath: 'Library',
              mediaKind: kind,
            )
            .isExtra,
        isFalse,
      );
    }
  });
  test('全部真实库路径独立预期与排除清单', () {
    final corpus =
        jsonDecode(
              File('test/fixtures/film_extra_library.json').readAsStringSync(),
            )
            as Map;
    final directories = (corpus['directories'] as List).cast<String>();
    var extras = 0, excluded = 0, regular = 0;
    final mismatches = <String>[];
    for (final row in corpus['files'] as List) {
      final folder = directories[row[0] as int], name = row[1] as String;
      final expected = row[2] as String?;
      if (expected == '@excluded') {
        expect(
          FilmExtraClassifier.excludedPath(folder),
          isTrue,
          reason: folder,
        );
        excluded++;
        continue;
      }
      final result = classifier.classify(
        name: name,
        path: '$folder/$name',
        rootPath: folder.split('/').first,
        mediaKind: 'strm',
      );
      if (result.kind != expected) {
        mismatches.add('$folder/$name: expected $expected, got ${result.kind}');
      }
      if (expected == null) {
        regular++;
      } else {
        extras++;
      }
    }
    expect(mismatches, isEmpty);
    expect((extras, excluded, regular), (1091, 993, 1374));
  });
  test('别名字面匹配、重复与通用词保护', () {
    final custom = FilmExtraType('custom:test', 'Custom', ['My+Clip']);
    final rules = FilmExtraRules(types: [...FilmExtraRules.defaults, custom]);
    FilmExtraClassifier.validateRules(rules.types);
    expect(
      FilmExtraClassifier(rules)
          .classify(
            name: 'My+Clip01.mkv',
            path: 'Work/My+Clip01.mkv',
            rootPath: '',
          )
          .kind,
      custom.id,
    );
    expect(
      () => FilmExtraClassifier.validateRules([
        ...rules.types,
        const FilmExtraType('custom:bad', 'Bad', ['ncop']),
      ]),
      throwsFormatException,
    );
    expect(
      () => FilmExtraClassifier.validateRules([
        ...rules.types,
        const FilmExtraType('custom:bad', 'Bad', ['Specials']),
      ]),
      throwsFormatException,
    );
  });

  group('分类存储与隔离', () {
    late Directory temp;
    late FilmCatalogStore store;
    late FilmCatalogRoot root;
    Future<void> inventory(List<String> paths) async {
      final generation = await store.beginScan(root.id);
      await store.stage(root, generation, [
        for (final path in paths)
          FilmScanEntry(
            path: path,
            parentPath: p.posix.dirname(path),
            name: p.posix.basename(path),
            mediaKind: 'video',
          ),
      ]);
      await store.commitScan(root.id, generation, cancelled: () => false);
    }

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('film_extras_');
      store = await FilmCatalogStore.open(p.join(temp.path, 'catalog.db'));
      final id = await store.addRoot(
        sourceId: 'dav',
        kind: MediaSourceKind.webdav,
        path: 'Movies',
        type: FilmMediaType.movie,
        name: 'Fixture',
      );
      root = (await store.root(id))!;
    });
    tearDown(() async {
      await store.close();
      await temp.delete(recursive: true);
    });
    test('扫描、人工非特典、规则更新、恢复自动与重启', () async {
      final paths = [
        'Movies/Work/Extras/PV01.mkv',
        'Movies/Work/Extras/Foo01.mkv',
      ];
      await inventory(paths);
      var resources = await store.resources();
      final first = resources.firstWhere((r) => r.name == 'PV01.mkv');
      await store.setExtraType(first, null);
      await inventory(paths);
      expect((await store.resource(first.id))!.extraOrigin, 'manual');
      expect((await store.resource(first.id))!.isExtra, isFalse);
      final types = [
        ...store.extraRules.types,
        const FilmExtraType('custom:foo', 'Foo', ['Foo'], custom: true),
      ];
      await store.saveExtraRules(types);
      await store.waitForExtraBackfill();
      expect(
        (await store.resources())
            .firstWhere((r) => r.name == 'Foo01.mkv')
            .extraKind,
        'custom:foo',
      );
      expect((await store.resource(first.id))!.extraStatus, 'non_extra');
      await store.setExtraType(
        (await store.resource(first.id))!,
        null,
        automatic: true,
      );
      expect((await store.resource(first.id))!.extraKind, 'pv');
      final path = store.path;
      await store.close();
      store = await FilmCatalogStore.open(path);
      expect((await store.resource(first.id))!.extraKind, 'pv');
      expect(store.extraRules.type('custom:foo').label, 'Foo');
    });
    test('电影特典观看与手工重置不会覆盖正片', () async {
      await inventory([
        'Movies/Work/Work.mkv',
        'Movies/Work/Extras/PV01.mkv',
        'Movies/Work/unknown.mkv',
      ]);
      await store.bind(
        await store.resources(),
        const FilmWork(
          type: FilmMediaType.movie,
          tmdbId: 1,
          title: 'Work',
          originalTitle: 'Work',
          overview: '',
          language: 'zh-CN',
        ),
      );
      final resources = await store.resources();
      final main = resources.firstWhere((r) => r.name == 'Work.mkv');
      await store.setExtraType(main, null);
      final updatedMain = (await store.resource(main.id))!;
      final extra = resources.firstWhere((r) => r.isExtra);
      final unknown = resources.firstWhere((r) => r.name == 'unknown.mkv');
      final now = DateTime.now();
      await store.recordVideoProgress(
        VideoProgressUpdate(
          sourceId: 'dav',
          path: main.path,
          positionMs: 10000,
          durationMs: 100000,
          recordedAt: now,
        ),
      );
      for (final r in [extra, unknown]) {
        await store.recordVideoProgress(
          VideoProgressUpdate(
            sourceId: 'dav',
            path: r.path,
            positionMs: 60000,
            durationMs: 60000,
            completed: true,
            recordedAt: now,
          ),
        );
        expect(
          (await store.resourceWatchState(r))!.status,
          FilmWatchStatus.watched,
        );
      }
      expect((await store.resourceWatchState(updatedMain))!.fraction, .1);
      expect(
        (await store.workWatchStates([
          updatedMain.workId!,
        ]))[updatedMain.workId]!.fraction,
        .1,
      );
      await store.markWatched(
        [extra],
        false,
        observedAt: now.add(const Duration(seconds: 1)),
      );
      await store.recordVideoProgress(
        VideoProgressUpdate(
          sourceId: 'dav',
          path: extra.path,
          positionMs: 60000,
          durationMs: 60000,
          completed: true,
          recordedAt: now,
        ),
      );
      expect(
        (await store.resourceWatchState(extra))!.status,
        FilmWatchStatus.unwatched,
      );
      expect((await store.resourceWatchState(updatedMain))!.fraction, .1);
    });
    test('旧库回填和排除项保留原记录', () async {
      await inventory([
        'Movies/Work/Extras/NCED01.mkv',
        'Movies/Work/《CDs》/01.mkv',
      ]);
      await store.waitForExtraBackfill();
      final path = store.path;
      await store.close();
      final db = await databaseFactoryFfi.openDatabase(path);
      for (final field in [
        'metadata_override_json',
        'extra_kind',
        'extra_origin',
        'extra_status',
        'extra_rule_version',
        'extra_evidence_json',
      ]) {
        await db.execute('ALTER TABLE resources DROP COLUMN $field');
      }
      await db.execute('DROP TABLE film_resource_watch_state');
      await db.setVersion(10);
      await db.close();
      store = await FilmCatalogStore.open(path);
      final rows = await store.resources();
      expect(rows, hasLength(1));
      expect(rows.single.extraKind, 'nced');
      await store.waitForExtraBackfill();
      final verify = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      expect(await verify.getVersion(), 12);
      expect((await verify.query('resources')), hasLength(2));
      await verify.close();
    });
    test('电影跟随列表和缓存仅选择正片，显式特典保持独立条目', () async {
      await inventory([
        'Movies/Work/Work.mkv',
        'Movies/Work/Extras/PV01.mkv',
        'Movies/Work/unknown.mkv',
      ]);
      await store.bind(
        await store.resources(),
        const FilmWork(
          type: FilmMediaType.movie,
          tmdbId: 1,
          title: 'Work',
          originalTitle: 'Work',
          overview: '',
          language: 'zh-CN',
        ),
      );
      final rows = await store.resources(), workId = rows.first.workId!;
      final main = rows.singleWhere((r) => r.isMovieMain),
          extra = rows.singleWhere((r) => r.isExtra);
      final scope = FilmPlaylistScope.work(workId);
      final id = await store.createPlaylist(
        'Movie',
        root.sourceId,
        root.sourceKind,
        root.displayName,
        scope,
      );
      var snapshot = await store.playlistSnapshot(id);
      expect(snapshot.entries, hasLength(1));
      expect(snapshot.entries.single.queueItem.versions.map((v) => v.path), [
        main.path,
      ]);
      expect(
        (await store.cacheResourceGroups(
          root.sourceId,
          scope,
        )).expand((g) => g).map((r) => r.path),
        [main.path],
      );
      await store.addPlaylistScope(
        id,
        root.sourceId,
        FilmPlaylistScope.resource(extra),
      );
      snapshot = await store.playlistSnapshot(id);
      expect(snapshot.entries, hasLength(2));
      expect(snapshot.entries.last.queueItem.versions.map((v) => v.path), [
        extra.path,
      ]);
      await store.setExtraType(extra, 'ncop');
      expect(
        (await store.playlistSnapshot(id)).entries.last.id,
        snapshot.entries.last.id,
      );
    });
    test('本地作品升级为 TMDB 身份时保留特典资源观看状态', () async {
      await inventory(['Movies/Work/PV01.mkv']);
      await store.bind(
        await store.resources(),
        const FilmWork(
          type: FilmMediaType.movie,
          identityKey: 'file:fixture',
          metadataOrigin: 'file',
          title: 'Work',
          originalTitle: 'Work',
          overview: '',
          language: 'zh-CN',
        ),
      );
      var r = (await store.resources()).single;
      await store.markWatched([r], true);
      await store.bind(
        [r],
        const FilmWork(
          type: FilmMediaType.movie,
          tmdbId: 77,
          title: 'Work',
          originalTitle: 'Work',
          overview: '',
          language: 'zh-CN',
        ),
      );
      r = (await store.resource(r.id))!;
      expect(
        (await store.resourceWatchState(r))!.status,
        FilmWatchStatus.watched,
      );
      expect(r.extraKind, 'pv');
      expect((await store.work(r.workId!))!.tmdbId, 77);
    });
    test('自动确认的正片在重新关联不同作品后回到待确认', () async {
      await inventory(['Movies/Work/Work.mkv']);
      await store.bind(
        await store.resources(),
        const FilmWork(
          type: FilmMediaType.movie,
          tmdbId: 1,
          title: 'Work',
          originalTitle: 'Work',
          overview: '',
          language: 'zh-CN',
        ),
      );
      var r = (await store.resources()).single;
      expect(r.isMovieMain, isTrue);
      await store.bind(
        [r],
        const FilmWork(
          type: FilmMediaType.movie,
          tmdbId: 2,
          title: 'Other',
          originalTitle: 'Other',
          overview: '',
          language: 'zh-CN',
        ),
      );
      r = (await store.resource(r.id))!;
      expect(r.isMovieMain, isFalse);
      expect(r.extraStatus, 'unknown');
    });
    test('自定义目录版本身份不随人工分类或规则重算变化', () async {
      final id = await store.addRoot(
        sourceId: 'tv',
        kind: MediaSourceKind.webdav,
        path: 'TV',
        type: FilmMediaType.tv,
        name: 'TV',
      );
      final tv = (await store.root(id))!;
      await store.saveExtraRules([
        ...store.extraRules.types,
        const FilmExtraType('custom:clip', 'Clip', [
          'CUSTOMCLIP',
        ], custom: true),
      ]);
      final gen = await store.beginScan(id);
      await store.stage(tv, gen, [
        const FilmScanEntry(
          path: 'TV/Work/Edition/CUSTOMCLIP/01.mkv',
          parentPath: 'TV/Work/Edition/CUSTOMCLIP',
          name: '01.mkv',
          mediaKind: 'video',
        ),
      ]);
      await store.bind(
        await store.resources(rootId: id),
        const FilmWork(
          type: FilmMediaType.tv,
          tmdbId: 2,
          title: 'Work',
          originalTitle: 'Work',
          overview: '',
          language: 'zh-CN',
        ),
      );
      var r = (await store.resources(rootId: id)).single;
      await store.mapEpisodes({r: (0, 7)});
      r = (await store.resource(r.id))!;
      final version = automaticFilmVersion(r);
      expect(version.name, 'TV · Edition');
      await store.setExtraType(r, 'pv');
      r = (await store.resource(r.id))!;
      expect(automaticFilmVersion(r), version);
      expect((r.season, r.episode, r.mappingOrigin), (0, 7, 'manual'));
      await store.setExtraType(r, null, automatic: true);
      expect(automaticFilmVersion((await store.resource(r.id))!), version);
    });
    test('便携导入与备份恢复保留自定义人工分类和资源观看状态', () async {
      await inventory(['Movies/Work/PV01.mkv']);
      await store.bind(
        await store.resources(),
        const FilmWork(
          type: FilmMediaType.movie,
          tmdbId: 1,
          title: 'Work',
          originalTitle: 'Work',
          overview: '',
          language: 'zh-CN',
        ),
      );
      await store.saveExtraRules([
        ...store.extraRules.types.map(
          (t) =>
              t.id == 'ncop' ? FilmExtraType(t.id, 'Renamed OP', t.aliases) : t,
        ),
        const FilmExtraType('custom:clip', 'Clip', [
          'CUSTOMCLIP',
        ], custom: true),
      ]);
      var r = (await store.resources()).single;
      await store.setExtraType(r, 'custom:clip');
      r = (await store.resource(r.id))!;
      await store.markWatched([r], true);
      final snapshot = await store.portableSnapshot();
      final backup = '${temp.path}/extra-backup.db';
      await store.waitForExtraBackfill();
      await store.backupTo(backup);
      final original = await File(backup).readAsBytes();
      await store.setExtraType(r, null);
      await store.restoreBackup(backup);
      expect(await File(backup).readAsBytes(), original);
      expect((await store.resource(r.id))!.extraKind, 'custom:clip');
      expect(
        (await store.resourceWatchState((await store.resource(r.id))!))!.status,
        FilmWatchStatus.watched,
      );
      final other = await FilmCatalogStore.open('${temp.path}/import.db');
      try {
        final id = await other.addRoot(
          sourceId: 'dav2',
          kind: MediaSourceKind.webdav,
          path: 'Movies',
          type: FilmMediaType.movie,
          name: 'Other',
        );
        final target = (await other.root(id))!, gen = await other.beginScan(id);
        await other.stage(target, gen, [
          const FilmScanEntry(
            path: 'Movies/Work/PV01.mkv',
            parentPath: 'Movies/Work',
            name: 'PV01.mkv',
            mediaKind: 'video',
          ),
        ]);
        await other.importPortable(
          snapshot,
          {'metadata', 'playback'},
          {'dav': 'dav2'},
        );
        final imported = (await other.resources()).single;
        expect(imported.extraKind, 'custom:clip');
        expect(imported.extraOrigin, 'manual');
        expect(other.extraRules.type('custom:clip').label, 'Clip');
        expect(other.extraRules.type('ncop').label, 'Renamed OP');
        expect(
          (await other.resourceWatchState(imported))!.status,
          FilmWatchStatus.watched,
        );
      } finally {
        await other.close();
      }
    });
  });
}
