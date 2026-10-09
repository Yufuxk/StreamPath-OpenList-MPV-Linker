import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/local_root_config.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/domain/services/film_file_metadata.dart';
import 'package:streampath/domain/services/local_media_source.dart';
import 'package:streampath/domain/services/film_catalog_matcher.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';

class _NoNetwork extends TmdbMetadataService {
  int calls = 0;
  @override
  Future<bool> hasToken() async {
    calls++;
    throw StateError('Local mode requested TMDB');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  test(
    'shared movie NFO keeps an unnumbered work identity across versions and TV NFO parses season episodes',
    () async {
      final temp = await Directory.systemTemp.createTemp('film_nfo_versions_');
      final store = await FilmCatalogStore.open('${temp.path}/catalog.db');
      try {
        await Directory('${temp.path}/Movie').create();
        await File('${temp.path}/Movie/movie.nfo').writeAsString(
          '<movie><title>Local film</title><uniqueid type="imdb">tt123</uniqueid></movie>',
        );
        final source = LocalMediaSource(
          LocalRootConfig(
            rootId: 'test',
            displayName: 'Fixture',
            path: temp.path,
          ),
          canonicalizer: (path) async => path,
        );
        final movieId = await store.addRoot(
          sourceId: 'local:test',
          kind: MediaSourceKind.local,
          path: 'Movie',
          type: FilmMediaType.movie,
          name: 'Movie',
        );
        final files = FilmFileMetadata(
          source,
          (await store.root(movieId))!,
          localMode: true,
          canWrite: false,
        );
        final first = (await files.load(
          FilmScanEntry(
            path: 'Movie/a.mkv',
            parentPath: 'Movie',
            name: 'a.mkv',
            mediaKind: 'video',
          ),
          'en',
        ))!;
        final second = (await files.load(
          FilmScanEntry(
            path: 'Movie/b.mp4',
            parentPath: 'Movie',
            name: 'b.mp4',
            mediaKind: 'video',
          ),
          'en',
        ))!;
        expect(first.work.tmdbId, 0);
        expect(first.work.identity, second.work.identity);
        expect(first.work.metadata['provider_ids'], {'imdb': 'tt123'});
        await Directory('${temp.path}/TV/Season 01').create(recursive: true);
        await File('${temp.path}/TV/tvshow.nfo').writeAsString(
          '<tvshow><title>Local series</title><uniqueid type="tmdb">5</uniqueid></tvshow>',
        );
        await File('${temp.path}/TV/Season 01/season.nfo').writeAsString(
          '<season><title>Season one</title><plot>Season overview</plot></season>',
        );
        await File('${temp.path}/TV/Season 01/E1.nfo').writeAsString(
          '<episodedetails><title>Episode one</title><season>1</season><episode>1</episode><runtime>24</runtime><plot>Episode overview</plot></episodedetails>',
        );
        final tvId = await store.addRoot(
          sourceId: 'local:test',
          kind: MediaSourceKind.local,
          path: 'TV',
          type: FilmMediaType.tv,
          name: 'TV',
        );
        final series = FilmFileMetadata(
          source,
          (await store.root(tvId))!,
          localMode: true,
          canWrite: false,
        );
        final episode = (await series.load(
          FilmScanEntry(
            path: 'TV/Season 01/E1.mkv',
            parentPath: 'TV/Season 01',
            name: 'E1.mkv',
            mediaKind: 'video',
          ),
          'en',
        ))!;
        expect(episode.work.title, 'Local series');
        expect(episode.episode, (1, 1));
        expect(episode.season!['name'], 'Season one');
        expect(episode.season!['episodes'].single['runtime'], 24);
        expect(
          episode.season!['episodes'].single['overview'],
          'Episode overview',
        );
      } finally {
        await store.close();
        await temp.delete(recursive: true);
      }
    },
  );
  test(
    'local NFO tasks index provider and trusted people without automatic TMDB; exclusive write preserves existing bytes',
    () async {
      final temp = await Directory.systemTemp.createTemp('film_nfo_');
      final store = await FilmCatalogStore.open('${temp.path}/catalog.db');
      final tmdb = _NoNetwork();
      try {
        final movie = File('${temp.path}/Test.mkv');
        await movie.writeAsBytes([0]);
        final nfo = File('${temp.path}/Test.nfo');
        final original =
            '<movie><title>本地电影</title><originaltitle>Local</originaltitle><year>2020</year><plot>Overview</plot><uniqueid type="tmdb">123</uniqueid><actor><name>Actor</name><role>Role</role><uniqueid type="tmdb">456</uniqueid></actor></movie>';
        await nfo.writeAsString(original);
        final id = await store.addRoot(
          sourceId: 'local:test',
          kind: MediaSourceKind.local,
          path: '',
          type: FilmMediaType.movie,
          name: 'Test',
        );
        final root = (await store.root(id))!;
        final source = LocalMediaSource(
          LocalRootConfig(rootId: 'test', displayName: 'Test', path: temp.path),
          canonicalizer: (path) async => path,
        );
        final files = FilmFileMetadata(
          source,
          root,
          localMode: true,
          canWrite: false,
        );
        final entry = FilmScanEntry(
          path: 'Test.mkv',
          parentPath: '',
          name: 'Test.mkv',
          mediaKind: 'video',
        );
        final generation = await store.beginScan(id);
        await store.stage(root, generation, [entry]);
        await store.commitScan(id, generation, cancelled: () => false);
        final matcher = FilmCatalogMatcher(
          store,
          tmdb,
          filesFor: (_) async => files,
        );
        final session = await matcher.scanSession(root, cancelled: () => false);
        await session.prepare([entry]);
        await store.applyMetadata(id, session.matches);
        expect(tmdb.calls, 0);
        final work = (await store.works(type: null)).single;
        expect(work.title, '本地电影');
        expect(work.tmdbId, 123);
        expect(work.metadataOrigin, 'local');
        expect(
          (await store.works(type: null, personId: 'tmdb:456')).single.id,
          work.id,
        );
        expect(await nfo.readAsString(), original);
        await expectLater(
          files.create('new.nfo', Uint8List.fromList([1])),
          throwsA(isA<FilmCatalogException>()),
        );
        final writable = FilmFileMetadata(
          source,
          root,
          localMode: true,
          canWrite: true,
        );
        await writable.create('Test.nfo', Uint8List.fromList([1, 2]));
        expect(await nfo.readAsString(), original);
        await writable.create('new.nfo', Uint8List.fromList([1, 2]));
        expect(await File('${temp.path}/new.nfo').readAsBytes(), [1, 2]);
      } finally {
        tmdb.close();
        await store.close();
        await temp.delete(recursive: true);
      }
    },
  );
}
