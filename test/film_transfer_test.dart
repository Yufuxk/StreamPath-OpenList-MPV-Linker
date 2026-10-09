import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:streampath/data/local/film_catalog_store.dart';
import 'package:streampath/data/local/media_library_store.dart';
import 'package:streampath/data/local/playback_progress_db.dart';
import 'package:streampath/data/models/film_catalog_item.dart';
import 'package:streampath/data/models/media_source.dart';
import 'package:streampath/domain/services/film_catalog_image_cache.dart';
import 'package:streampath/domain/services/film_library_transfer.dart';
import 'package:streampath/domain/services/tmdb_metadata_service.dart';

class _OfflineImages extends FilmCatalogImageCache {
  _OfflineImages(super.directory, super.tmdb);
  int downloads = 0;
  @override
  Future<File> get(String path, {String target = 'w342'}) async {
    downloads++;
    throw const FileSystemException('Image source is offline');
  }
}

class _Library {
  _Library(
    this.directory,
    this.store,
    this.records,
    this.progress,
    this.tmdb,
    this.images,
    this.resource,
  );
  final Directory directory;
  final FilmCatalogStore store;
  final MediaLibraryStore records;
  final PlaybackProgressService progress;
  final TmdbMetadataService tmdb;
  final FilmCatalogImageCache images;
  final FilmResource resource;
  FilmLibraryTransfer get transfer => FilmLibraryTransfer(
    store: store,
    images: images,
    records: {'normal': records},
    progress: {'normal': progress},
    targetFor: (item) =>
        PlaybackProgressService.logicalTarget(item.sourceId, item.targetPath),
    dataDirectory: directory,
  );
  Future<void> close() async {
    images.close();
    tmdb.close();
    await records.portableSnapshot();
    await progress.close();
    await store.close();
    await directory.delete(recursive: true);
  }

  static Future<_Library> create(String source) async {
    final dir = await Directory.systemTemp.createTemp('film_transfer_');
    await Directory('${dir.path}/library').create();
    await Directory('${dir.path}/cache').create();
    final store = await FilmCatalogStore.open(
      '${dir.path}/library/film_catalog.db',
    );
    final records = MediaLibraryStore.forPath(
      '${dir.path}/library/media_library.json',
    );
    await records.load();
    final progress = await PlaybackProgressService.open(
      '${dir.path}/cache/streampath.db',
    );
    final tmdb = TmdbMetadataService();
    final images = FilmCatalogImageCache(Directory('${dir.path}/images'), tmdb);
    final id = await store.addRoot(
      sourceId: source,
      kind: MediaSourceKind.local,
      path: 'Movies',
      type: FilmMediaType.movie,
      name: 'Movies',
    );
    final root = (await store.root(id))!;
    final generation = await store.beginScan(id);
    await store.stage(root, generation, [
      FilmScanEntry(
        path: 'Movies/Test.mkv',
        parentPath: 'Movies',
        name: 'Test.mkv',
        mediaKind: 'video',
      ),
    ]);
    await store.commitScan(id, generation, cancelled: () => false);
    return _Library(
      dir,
      store,
      records,
      progress,
      tmdb,
      images,
      (await store.resources()).single,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  test(
    'offline export includes cached sizes and custom artwork without downloading missing images',
    () async {
      final library = await _Library.create('offline');
      final images = _OfflineImages(library.images.directory, library.tmdb);
      FilmTransferPreview? preview;
      try {
        await library.store.bind(
          [library.resource],
          const FilmWork(
            type: FilmMediaType.movie,
            tmdbId: 321,
            title: 'Offline',
            originalTitle: 'Offline',
            overview: '',
            language: 'en',
            posterPath: '/uncached.jpg',
            backdropPath: '/cached.jpg',
            metadata: {
              'credits': {
                'cast': [
                  {'profile_path': '/actor.jpg'},
                ],
              },
            },
          ),
        );
        await images.directory.create(recursive: true);
        final recorder = ui.PictureRecorder();
        ui.Canvas(
          recorder,
        ).drawColor(const ui.Color(0xFF224466), ui.BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(2, 2);
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.png,
        ))!.buffer.asUint8List();
        image.dispose();
        picture.dispose();
        for (final (path, size) in [
          ('/cached.jpg', 'w500'),
          ('/actor.jpg', 'w185'),
        ]) {
          await File(
            '${images.directory.path}/${FilmCatalogImageCache.cacheKey(path, size)}.img',
          ).writeAsBytes(bytes);
        }
        final background = File('${library.directory.path}/background.png');
        await background.writeAsBytes(bytes);
        await library.store.setBackgroundPath(background.path);
        final transfer = FilmLibraryTransfer(
          store: library.store,
          images: images,
          records: {'normal': library.records},
          progress: {'normal': library.progress},
          targetFor: (_) => null,
          dataDirectory: library.directory,
        );
        final output = await transfer.export();
        preview = await FilmLibraryTransfer.preflight(output);
        expect(images.downloads, 0);
        final artwork = preview.data['artwork'] as Map;
        expect(
          artwork.keys,
          containsAll(['/cached.jpg', '/actor.jpg', background.path]),
        );
        expect(artwork.containsKey('/uncached.jpg'), false);
        expect((preview.data['catalog'] as Map)['works'], hasLength(1));
      } finally {
        await preview?.close();
        images.close();
        await library.close();
      }
    },
  );
  test(
    'fixed export creates separate ZIP backups in the data directory without system temp',
    () async {
      final library = await _Library.create('fixed-export');
      FilmTransferPreview? preview;
      try {
        final unavailable = File('${library.directory.path}/unavailable-temp');
        await unavailable.writeAsString('not a directory');
        final first = await IOOverrides.runZoned(
          () => library.transfer.export(),
          getSystemTempDirectory: () => Directory(unavailable.path),
        );
        final original = await first.readAsBytes();
        final second = await library.transfer.export();
        expect(first.parent.path, library.directory.path);
        expect(second.parent.path, library.directory.path);
        expect(second.path, isNot(first.path));
        expect(await first.readAsBytes(), original);
        expect(first.uri.pathSegments.last, startsWith('StreamPath-library-'));
        expect(
          await library.directory
              .list()
              .where(
                (entry) =>
                    entry.path.contains('streampath_export_') ||
                    entry.path.endsWith('.partial'),
              )
              .toList(),
          isEmpty,
        );
        expect(
          await Directory(
            '${library.directory.path}/cache/film_transfer',
          ).exists(),
          false,
        );
        preview = await FilmLibraryTransfer.preflight(first);
        expect(preview.sources, contains('fixed-export'));
      } finally {
        await preview?.close();
        await library.close();
      }
    },
  );
  test(
    'ZIP mapping, optional collections, repeat import and rollback preserve local progress and personal data',
    () async {
      final source = await _Library.create('old');
      final target = await _Library.create('new');
      FilmTransferPreview? preview;
      try {
        final work = FilmWork(
          type: FilmMediaType.movie,
          tmdbId: 123,
          title: 'Test',
          originalTitle: 'Test',
          year: 2020,
          overview: '',
          language: 'zh-CN',
        );
        await source.store.bind([source.resource], work);
        final saved = (await source.store.works(type: null)).single;
        await source.store.setFavorite(saved.id, true);
        await source.store.markWatched([
          (await source.store.resources()).single,
        ], true);
        final collection = await source.store.createCollection(
          'Export collection',
        );
        await source.store.addCollectionMember(collection, saved.id);
        await source.records.recordPlayback(
          source.resource.playbackItem,
          playbackSessionId: 'SECRET_PROCESS_SESSION',
        );
        await source.progress.saveProgress(
          url: PlaybackProgressService.logicalTarget(
            'old',
            source.resource.path,
          ),
          profileId: 'old',
          positionMs: 25000,
          durationMs: 120000,
        );
        final package = await source.transfer.export(collections: true);
        preview = await FilmLibraryTransfer.preflight(package);
        expect(
          jsonEncode(preview.data),
          isNot(contains('SECRET_PROCESS_SESSION')),
        );
        expect(preview.counts['collections'], 1);
        expect(preview.counts['playback'], 3);
        expect(preview.counts['favorites'], 1);
        final categories = {'metadata', 'favorites', 'playback', 'artwork'};
        await target.transfer.import(preview, categories, {
          'old': 'new',
        }, matches: (_) async => true);
        expect(await target.store.collections(customOnly: true), isEmpty);
        final imported = (await target.store.works(type: null)).single;
        expect(imported.tmdbId, 123);
        expect(await target.store.isFavorite(imported.id), isTrue);
        expect((await target.store.resources()).single.id, target.resource.id);
        expect(
          (await target.records.playbackHistory(
            'new',
            audio: false,
          )).single.playbackSessionId,
          isNull,
        );
        await target.progress.saveProgress(
          url: PlaybackProgressService.logicalTarget(
            'new',
            target.resource.path,
          ),
          profileId: 'new',
          positionMs: 90000,
          durationMs: 120000,
        );
        categories.add('collections');
        final first = await target.transfer.import(preview, categories, {
          'old': 'new',
        }, matches: (_) async => true);
        final second = await target.transfer.import(preview, categories, {
          'old': 'new',
        }, matches: (_) async => true);
        expect(first['collections'], 1);
        expect(second['collections'], 0);
        expect(await target.store.collections(customOnly: true), hasLength(1));
        expect(
          await target.store.works(type: null, collectionId: collection),
          hasLength(1),
        );
        expect(
          await target.records.playbackHistory('new', audio: false),
          hasLength(1),
        );
        final url = PlaybackProgressService.logicalTarget(
          'new',
          target.resource.path,
        );
        expect(
          (await target.progress.getProgress(
            url,
            profileId: 'new',
          ))!.positionMs,
          90000,
        );
        final before = jsonEncode(
          await target.store.portableSnapshot(collections: true),
        );
        await expectLater(
          target.transfer.import(
            preview,
            categories,
            {'old': 'new'},
            matches: (_) async => true,
            beforeCommit: () async {
              await target.store.setFavorite(imported.id, false);
              await target.records.clearAllPlaybackHistory('new');
              await target.progress.clearAll();
              throw const FileSystemException('Injected commit interruption');
            },
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(
          jsonEncode(await target.store.portableSnapshot(collections: true)),
          before,
        );
        expect(
          await target.records.playbackHistory('new', audio: false),
          hasLength(1),
        );
        expect(
          (await target.progress.getProgress(
            url,
            profileId: 'new',
          ))!.positionMs,
          90000,
        );
      } finally {
        await preview?.close();
        await source.close();
        await target.close();
      }
    },
  );
  test(
    'preflight rejects unsafe paths, symlinks and checksum corruption',
    () async {
      final library = await _Library.create('source');
      try {
        final file = await library.transfer.export();
        final original = await file.readAsBytes();
        for (final attack in [
          'traversal',
          'link',
          'checksum',
          'missing manifest',
        ]) {
          final archive = ZipDecoder().decodeBytes(original);
          if (attack == 'traversal') {
            archive.addFile(ArchiveFile('..\\escape', 1, [1]));
          }
          if (attack == 'link') {
            archive.addFile(
              ArchiveFile('assets/${'a' * 64}.bin', 1, [1])
                ..symbolicLink = '../escape',
            );
          }
          if (attack == 'checksum') {
            archive.removeFile(archive.findFile('data.json')!);
            archive.addFile(ArchiveFile.string('data.json', '{}'));
          }
          if (attack == 'missing manifest') {
            archive.removeFile(archive.findFile('manifest.json')!);
          }
          final bad = File('${library.directory.path}/$attack.zip');
          await bad.writeAsBytes(ZipEncoder().encode(archive));
          await expectLater(
            FilmLibraryTransfer.preflight(bad),
            throwsA(isA<FilmCatalogException>()),
          );
        }
        expect(await library.store.works(type: null), isEmpty);
      } finally {
        await library.close();
      }
    },
  );
  test(
    'startup recovers an interrupted commit before databases are opened and is idempotent',
    () async {
      final directory = await Directory.systemTemp.createTemp('film_recovery_');
      try {
        final original = File('${directory.path}/library/records.json');
        await original.parent.create();
        await original.writeAsString('old');
        final recovery = Directory('${directory.path}/.film-import-recovery');
        await recovery.create();
        await original.copy('${recovery.path}/0.json');
        await File('${recovery.path}/journal.json').writeAsString(
          jsonEncode({
            'state': 'prepared',
            'files': {
              'library/records.json': '0.json',
              'library/new.json': null,
            },
          }),
        );
        await original.writeAsString('new');
        await File(
          '${directory.path}/library/new.json',
        ).writeAsString('partial');
        await FilmLibraryTransfer.recover(directory);
        await FilmLibraryTransfer.recover(directory);
        expect(await original.readAsString(), 'old');
        expect(
          await File('${directory.path}/library/new.json').exists(),
          false,
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
