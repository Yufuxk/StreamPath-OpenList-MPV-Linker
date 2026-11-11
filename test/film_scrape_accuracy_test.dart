// 刮削准确性回归：文件名解析、季集提示、双语匹配与身份冲突守卫。
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/core/utils/video_filename_parser.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/tmdb_credential_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/domain/services/film_catalog_matcher.dart';
import 'package:streampath/domain/services/film_logo_selector.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';

class _MemoryToken extends TmdbCredentialStore {
  const _MemoryToken();
  @override
  Future<String?> read() async => 'fake-api-token';
}

FilmWork _work(
  FilmMediaType type,
  int id,
  String title,
  String original, {
  int? year,
}) => FilmWork(
  type: type,
  tmdbId: id,
  title: title,
  originalTitle: original,
  overview: '',
  language: 'zh-CN',
  year: year,
  fetchedAt: 42,
  metadata: const {'genres': <String>[]},
);

class _FakeTmdb extends TmdbMetadataService {
  _FakeTmdb(this.works, this.results, {this.titles = const {}})
    : super(credentials: const _MemoryToken(), dio: Dio());

  final Map<int, FilmWork> works;

  /// 检索词 -> 候选作品 ID。
  final Map<String, List<int>> results;
  final Map<int, List<String>> titles;
  final queries = <String>[];

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
    queries.add(query);
    return [for (final id in results[query] ?? const <int>[]) works[id]!];
  }

  @override
  Future<FilmWork> details(
    FilmMediaType type,
    int id,
    String language, {
    Future<String?> Function(List<LogoChoice>)? chooseLogo,
  }) async => works[id]!;

  @override
  Future<List<String>> matchingTitles(FilmMediaType type, int id) async =>
      titles[id] ?? const [];

  @override
  Future<Map<String, dynamic>> season(
    int id,
    int number,
    String language,
  ) async => {'season_number': number, 'episodes': <Map<String, Object?>>[]};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  group('文件名解析', () {
    final movieCases = <(String, String, int?)>[
      ('5.Centimeters.Per.Second.2007.iso', '5 Centimeters Per Second', 2007),
      ('5 Centimeters Per Second 2007.iso', '5 Centimeters Per Second', 2007),
      (
        'Iron.Man.2008.PROPER.2160P.BluRay.REMUX.HEVC.DTS-HD.MA.TrueHD.7.1.Atmos-XXX.strm',
        'Iron Man',
        2008,
      ),
      (
        'Blade.Runner.2049.2017.2160p.UHD.BluRay.x265-TERMiNAL.mkv',
        'Blade Runner 2049',
        2017,
      ),
      ('1917.2019.1080p.BluRay.x264-GROUP.mkv', '1917', 2019),
      (
        'The.Matrix.1999.Directors.Cut.1080p.BluRay.x264-GROUP.mkv',
        'The Matrix',
        1999,
      ),
      ('你的名字.2016.BlueRay.REMUX.1080P.H.264.DTS-HD.MA.5.1.strm', '你的名字', 2016),
      ('死亡笔记特别篇2：L的继承者.2009.strm', '死亡笔记特别篇2：L的继承者', 2009),
    ];
    for (final (name, title, year) in movieCases) {
      test('电影 $name', () {
        final info = const VideoFilenameParser().parse(name, movie: true);
        expect(info?.title, title);
        expect(info?.year, year);
      });
    }

    test('解析失败时仍剥离扩展名、版本标记与尾部年份', () {
      final value = VideoFilenameParser.fallback(
        '[VCB-Studio] CLANNAD [Ma10p_1080p][x265_flac].mkv',
      );
      expect(value.title, 'CLANNAD');
      expect(value.year, isNull);
      final iso = VideoFilenameParser.fallback(
        '5 Centimeters Per Second 2007.iso',
      );
      expect(iso.title, '5 Centimeters Per Second');
      expect(iso.year, 2007);
    });

    test('无法解析的光盘镜像仍得到干净的检索词', () {
      final hint = FilmCatalogMatcher.scanHint(
        'COSMIC_PRINCESS_KAGUYA_DISC_1.iso',
        'Movies/2026 -《超时空辉夜姬》',
        'Movies',
        type: FilmMediaType.movie,
      );
      expect(hint.title, 'COSMIC PRINCESS KAGUYA');
      expect(hint.year, isNull);
      final japanese = FilmCatalogMatcher.scanHint(
        '心が叫びたがってるんだ。SPBD.ISO',
        'Movies/《心灵想要大声呼喊 》- 2015/《SPs》',
        'Movies',
        type: FilmMediaType.movie,
      );
      expect(japanese.title, startsWith('心が叫びたがってるんだ'));
    });
  });

  group('季集提示', () {
    const tvRoot = 'TV';
    FilmMatchHint hint(String parent, String name) =>
        FilmCatalogMatcher.scanHint(
          name,
          parent,
          tvRoot,
          type: FilmMediaType.tv,
        );

    test('进击的巨人 Q版剧场 保留区分后缀', () {
      final value = hint(
        'TV/2013 -《进击的巨人 Q版剧场》/2.《飞翔吧！新生利威尔班》',
        '进击的巨人 Q版剧场.S02E01.BlueRay.1080P.AVC.LPCM.strm',
      );
      expect(value.title, '进击的巨人 Q版剧场');
      expect(value.episode, (2, 1));
    });

    test('季集后置年份与小数为描述时不视为合并集', () {
      final value = hint(
        'TV/2021 -《86不存在的战区》/0.《Specials》',
        '86不存在的战区 S00E02 11.5集.strm',
      );
      expect(value.title, '86不存在的战区');
      expect(value.episode, (0, 2));
    });

    test('1x01、第01话、EP01 与番剧短横线编号都能得到季集', () {
      expect(
        hint('TV/Show/Season 02', 'Show.Name.1x02.720p.HDTV.mkv').episode,
        (1, 2),
      );
      expect(
        hint('TV/Show/Season 02', 'Show.Name.1x02.720p.HDTV.mkv').title,
        'Show Name',
      );
      expect(hint('TV/Show', '某科学的超电磁炮 第03话.mkv').episode, (1, 3));
      expect(hint('TV/Show/Season 03', '某科学的超电磁炮 第03话.mkv').episode, (3, 3));
      expect(hint('TV/Show', '某科学的超电磁炮 EP04.mkv').episode, (1, 4));
      expect(
        hint(
          'TV/Show',
          '[Lilith-Raws] 某科学的超电磁炮 - 05 [Baha][WEB-DL][1080p][AVC AAC].mp4',
        ).episode,
        (1, 5),
      );
    });

    test('明确的合并集仍留给人工映射', () {
      expect(
        hint('TV/Show', 'Show.Name.S01E01E02.1080p.BluRay.mkv').episode,
        isNull,
      );
      expect(
        hint('TV/Show', 'Show.Name.S01E01-E03.1080p.BluRay.mkv').episode,
        isNull,
      );
    });

    test('容器名称可作为兜底依据', () {
      final container = FilmCatalogMatcher.containerHint(
        'QuarkFilmsData_SPECIAL/0.MOVIE SPs/《秒速5厘米》- 2007',
        'QuarkFilmsData_SPECIAL/0.MOVIE SPs',
      );
      expect(container?.title, '秒速5厘米');
      expect(container?.year, 2007);
    });

    test('季、特典与纯数字目录不能代表作品身份', () {
      expect(FilmCatalogMatcher.genericContainerTitle('Season 1'), isTrue);
      expect(FilmCatalogMatcher.genericContainerTitle('0.《Specials》'), isTrue);
      expect(FilmCatalogMatcher.genericContainerTitle('2013'), isTrue);
      expect(
        FilmCatalogMatcher.genericContainerTitle('2013 -《进击的巨人》'),
        isFalse,
      );
      expect(FilmCatalogMatcher.genericContainerTitle('命运石之门'), isFalse);
    });
  });

  group('匹配', () {
    late Directory temp;
    late FilmCatalogStore store;
    late FilmCatalogRoot root;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('film_accuracy_');
      store = await FilmCatalogStore.open(p.join(temp.path, 'catalog.db'));
      final id = await store.addRoot(
        sourceId: 'test',
        kind: MediaSourceKind.webdav,
        path: 'TV',
        type: FilmMediaType.tv,
        name: 'TV',
      );
      root = (await store.root(id))!;
    });
    tearDown(() async {
      await store.close();
      await temp.delete(recursive: true);
    });

    Future<void> stage(List<FilmScanEntry> entries) async {
      final generation = await store.beginScan(root.id);
      await store.stage(root, generation, entries);
      await store.commitScan(root.id, generation, cancelled: () => false);
    }

    Future<FilmScanMatch?> prepare(
      FilmCatalogMatcher matcher,
      FilmScanEntry entry,
    ) async {
      final session = await matcher.scanSession(root, cancelled: () => false);
      await session.prepare([entry]);
      return session.matches[filmPathKey(entry.path, root.sourceKind)];
    }

    FilmScanEntry entry(String parent, String name) => FilmScanEntry(
      path: '$parent/$name',
      parentPath: parent,
      name: name,
      mediaKind: 'strm',
    );

    test('进击的巨人 Q版剧场 绑定 224499 且不拆分覆盖', () async {
      const name = '进击的巨人 Q版剧场.S02E01.BlueRay.1080P.AVC.LPCM.strm';
      const parent = 'TV/2013 -《进击的巨人 Q版剧场》/2.《飞翔吧！新生利威尔班》';
      await stage([entry(parent, name)]);
      final tmdb = _FakeTmdb(
        {
          224499: _work(
            FilmMediaType.tv,
            224499,
            '《进击の巨人》Q版剧场',
            'ちみキャラ劇場',
            year: 2013,
          ),
          1429: _work(FilmMediaType.tv, 1429, '进击的巨人', '進撃の巨人', year: 2013),
        },
        {
          '进击的巨人 Q版剧场': [224499],
          '进击的巨人': [1429],
          'Q版剧场': [224499],
        },
        titles: {
          224499: ['《进击の巨人》Q版剧场', 'Attack on Titan: Chibi Theater'],
          1429: ['进击的巨人', 'Attack on Titan'],
        },
      );
      final matcher = FilmCatalogMatcher(store, tmdb);
      final match = await prepare(matcher, entry(parent, name));
      expect(match?.work.tmdbId, 224499);
      expect(match?.episode, (2, 1));
      // 完整名称已有结论，拆分检索不应发生。
      expect(tmdb.queries, isNot(contains('进击的巨人')));
    });

    test('完整名称无候选时才使用双语拆分', () async {
      const name = '魔女之旅 Wandering Witch.S01E01.1080p.mkv';
      const parent = 'TV/2020 -《魔女之旅》';
      await stage([entry(parent, name)]);
      final tmdb = _FakeTmdb(
        {500: _work(FilmMediaType.tv, 500, '魔女之旅', '魔女の旅々', year: 2020)},
        {
          '魔女之旅 Wandering Witch': <int>[],
          '魔女之旅': [500],
        },
        titles: {
          500: ['魔女之旅', 'Wandering Witch'],
        },
      );
      final matcher = FilmCatalogMatcher(store, tmdb);
      final match = await prepare(matcher, entry(parent, name));
      expect(match?.work.tmdbId, 500);
      expect(tmdb.queries, contains('魔女之旅'));
    });

    test('相同标题不同续作的数字必须一致', () async {
      const name = 'Show.Name.2.S01E01.1080p.mkv';
      const parent = 'TV/Show Name 2';
      await stage([entry(parent, name)]);
      final tmdb = _FakeTmdb(
        {
          1: _work(FilmMediaType.tv, 1, 'Show Name', 'Show Name', year: 2020),
          2: _work(
            FilmMediaType.tv,
            2,
            'Show Name 2',
            'Show Name 2',
            year: 2022,
          ),
        },
        {
          'Show Name 2': [1, 2],
        },
        titles: {
          1: ['Show Name'],
          2: ['Show Name 2'],
        },
      );
      final matcher = FilmCatalogMatcher(store, tmdb);
      final match = await prepare(matcher, entry(parent, name));
      expect(match?.work.tmdbId, 2);
    });

    test('匹配算法版本升级后重算非人工绑定', () async {
      const name = 'Another.2012.S01E01.BluRay.strm';
      const parent = 'TV/2012 -《Another》';
      await stage([entry(parent, name)]);
      final resource = (await store.resources(rootId: root.id)).single;
      final wrong = _work(FilmMediaType.tv, 9, '错误的作品', 'Wrong', year: 2012);
      await store.bind([resource], wrong, origin: 'search');
      final right = _work(FilmMediaType.tv, 77, 'Another', 'アナザー', year: 2012);
      final tmdb = _FakeTmdb(
        {9: wrong, 77: right},
        {
          'Another': [77],
        },
        titles: {
          77: ['Another'],
        },
      );
      final matcher = FilmCatalogMatcher(store, tmdb);
      final first = await prepare(matcher, entry(parent, name));
      expect(first?.work.tmdbId, 77);
      await store.applyMetadata(root.id, {
        filmPathKey('$parent/$name', root.sourceKind): first!,
      });
      expect((await store.resources(rootId: root.id)).single.workId, isNotNull);
      expect(
        (await store.resource(
          (await store.resources(rootId: root.id)).single.id,
        ))!.workId,
        isNot(resource.workId),
      );

      await store.setMatcherVersion(FilmCatalogMatcher.matchingVersion);
      final idle = _FakeTmdb(
        {77: right},
        {
          'Another': [77],
        },
        titles: {
          77: ['Another'],
        },
      );
      final second = await prepare(
        FilmCatalogMatcher(store, idle),
        entry(parent, name),
      );
      expect(second?.work.tmdbId, 77);
      expect(idle.queries, isEmpty);
    });

    test('兄弟容器剧集重叠且名称不是版本标记时退回待整理', () async {
      await stage([
        for (var i = 1; i <= 3; i++)
          entry('TV/进击的巨人', '进击的巨人.S02E0$i.BlueRay.strm'),
        for (var i = 1; i <= 3; i++)
          entry('TV/进击的巨人 Q版剧场', '进击的巨人 Q版剧场.S02E0$i.BlueRay.strm'),
      ]);
      final work = _work(FilmMediaType.tv, 1429, '进击的巨人', '進撃の巨人', year: 2013);
      final all = await store.resources(rootId: root.id);
      await store.bind(all, work, origin: 'search');
      final bound = await store.resources(rootId: root.id);
      await store.mapEpisodes({
        for (final resource in bound)
          resource: (
            2,
            int.parse(RegExp(r'E(\d+)').firstMatch(resource.name)![1]!),
          ),
      }, origin: 'filename');
      final matcher = FilmCatalogMatcher(
        store,
        _FakeTmdb({1429: work}, const {}),
      );
      final cleared = await matcher.resolveConflicts(root.id);
      expect(cleared, 3);
      final after = await store.resources(rootId: root.id);
      expect(
        after.where((r) => r.workId == null).map((r) => r.parentPath).toSet(),
        {'TV/进击的巨人 Q版剧场'},
      );
      expect(after.where((r) => r.workId != null).length, 3);
    });

    test('分辨率目录属于同一作品的多个版本，不得被解绑', () async {
      await stage([
        entry('TV/Show.1080p', 'Show.S01E01.1080p.BluRay.mkv'),
        entry('TV/Show.720p', 'Show.S01E01.720p.BluRay.mkv'),
      ]);
      final work = _work(FilmMediaType.tv, 300, 'Show', 'Show', year: 2020);
      final all = await store.resources(rootId: root.id);
      await store.bind(all, work, origin: 'search');
      final bound = await store.resources(rootId: root.id);
      await store.mapEpisodes({
        for (final resource in bound) resource: (1, 1),
      }, origin: 'filename');
      final matcher = FilmCatalogMatcher(
        store,
        _FakeTmdb({300: work}, const {}),
      );
      expect(await matcher.resolveConflicts(root.id), 0);
      expect(
        (await store.resources(rootId: root.id)).every((r) => r.workId != null),
        isTrue,
      );
    });

    test('特典视频按 S00 顺序编号且排除 CD 和 SCAN 目录', () async {
      await stage([
        entry('TV/Show/Season 01', 'Show.S01E01.mkv'),
        entry('TV/Show/0.《Specials》/《SPs》', 'Clip #1.strm'),
        entry('TV/Show/0.《Specials》/《SPs》', 'Clip #2.strm'),
        entry('TV/Show/0.《Specials》/《PVs》', 'Clip #3.strm'),
        entry('TV/Show/0.《Specials》/《CDs》', 'Drama #1.strm'),
        entry('TV/Show/0.《Specials》/《CDs》', 'Drama #2.strm'),
        entry('TV/Show/0.《Specials》/《SCANs》', 'cover.strm'),
      ]);
      final work = _work(FilmMediaType.tv, 500, 'Show', 'Show', year: 2020);
      final all = await store.resources(rootId: root.id);
      await store.bind(all, work, origin: 'search');
      final matcher = FilmCatalogMatcher(
        store,
        _FakeTmdb({500: work}, const {}),
      );
      expect(await matcher.assignExtras(root.id), 3);
      final after = await store.resources(rootId: root.id);
      Map<String, (int?, int?)> mapping() => {
        for (final resource in after)
          resource.name: (resource.season, resource.episode),
      };
      final first = mapping();
      expect(first['Show.S01E01.mkv'], (null, null));
      expect(first['Drama #1.strm'], isNull);
      expect(first['Drama #2.strm'], isNull);
      expect(first['cover.strm'], isNull);
      expect(first.values.where((v) => v.$1 == 0).map((v) => v.$2).toSet(), {
        1,
        2,
        3,
      });
      // 已编号的特典不再变化。
      expect(await matcher.assignExtras(root.id), 0);
    });

    test('剧集以容器身份优先，避免 CD 曲目被当成独立作品', () async {
      const parent = 'TV/2011 -《命运石之门》/0.《Specials》/《CDs》/[BDMV] Vol.1';
      const name = 'Drama #1.strm';
      await stage([entry(parent, name)]);
      final tmdb = _FakeTmdb(
        {
          42509: _work(
            FilmMediaType.tv,
            42509,
            '命运石之门',
            'STEINS;GATE',
            year: 2011,
          ),
          99133: _work(FilmMediaType.tv, 99133, 'Drama', 'Drama', year: 2019),
        },
        {
          '命运石之门': [42509],
          'Drama': [99133],
        },
        titles: {
          42509: ['命运石之门', 'STEINS;GATE'],
        },
      );
      final matcher = FilmCatalogMatcher(store, tmdb);
      final match = await prepare(matcher, entry(parent, name));
      expect(match, isNull);
      expect(tmdb.queries, isEmpty);
    });
  });
}
