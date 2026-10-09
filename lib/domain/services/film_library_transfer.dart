import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../../data/local/film_catalog_store.dart';
import '../../data/local/media_library_store.dart';
import '../../data/local/playback_progress_db.dart';
import '../../data/models/film_catalog_item.dart';
import '../../data/models/film_image_reference.dart';
import '../../data/models/media_library_item.dart';
import '../../data/models/media_source.dart';
import 'film_catalog_image_cache.dart';
import 'external_player_service.dart';
import 'iso_playback_service.dart';

class FilmTransferPreview {
  FilmTransferPreview(this.directory, this.data, this.sources, this.counts);
  final Directory directory;
  final Map<String, dynamic> data;
  final Set<String> sources;
  final Map<String, int> counts;
  Future<void> close() => directory.delete(recursive: true);
}

void _validateItem(Map<String, dynamic> row) {
  final parent = row['parentPath'] as String, name = row['name'] as String;
  validateFilmPath(parent);
  if (name.isEmpty ||
      name.contains('/') ||
      name.contains('\\') ||
      name == '.' ||
      name == '..') {
    throw const FilmCatalogException('invalidImport');
  }
  if (row['discRootPath'] case final String path) validateFilmPath(path);
  if (row['sourceId'] is! String ||
      (row['sourceId'] as String).isEmpty ||
      !MediaSourceKind.values.any(
        (kind) => kind.jsonValue == row['sourceKind'],
      )) {
    throw const FilmCatalogException('invalidImport');
  }
  MediaLibraryItem.fromJson(row);
  if (row['discResumeEdition'] != null &&
      (row['discResumeEdition'] is! int ||
          row['discResumeEdition'] < 0 ||
          row['discResumeEdition'] > 99999)) {
    throw const FilmCatalogException('invalidImport');
  }
}

/// ZIP 只承载逻辑媒体身份、个人数据与图片，不包含连接凭据或运行中会话。
class FilmLibraryTransfer {
  FilmLibraryTransfer({
    required this.store,
    required this.images,
    required this.records,
    required this.progress,
    required this.targetFor,
    required this.dataDirectory,
    this.players = const {},
    this.isoServices = const {},
  });
  final FilmCatalogStore store;
  final FilmCatalogImageCache images;
  final Map<String, MediaLibraryStore> records;
  final Map<String, PlaybackProgressService> progress;
  final String? Function(MediaLibraryItem) targetFor;
  final Directory dataDirectory;
  final Map<String, ExternalPlayerService> players;
  final Map<String, IsoPlaybackService> isoServices;
  Future<File> export({bool collections = false}) async {
    await dataDirectory.create(recursive: true);
    final stamp = DateTime.now().toIso8601String().replaceAll(
      RegExp(r'[^0-9]'),
      '',
    );
    final output = File(
      p.join(dataDirectory.path, 'StreamPath-library-$stamp.zip'),
    );
    final temporary = await dataDirectory.createTemp('streampath_export_');
    try {
      final catalog = await store.portableSnapshot(collections: collections);
      final personal = <String, dynamic>{},
          positions = <String, dynamic>{},
          discs = <String, dynamic>{};
      for (final lane in records.entries) {
        final data = await lane.value.portableSnapshot();
        personal[lane.key] = data;
        final items = <String, MediaLibraryItem>{};
        for (final rows in data.values.whereType<List>()) {
          for (final row in rows.whereType<Map>()) {
            final item = MediaLibraryItem.fromJson(
              Map<String, dynamic>.from(row),
            );
            items[item.stableKey] = item;
          }
        }
        final saved = <Map<String, dynamic>>[];
        final iso = <Map<String, dynamic>>[];
        for (final item in items.values) {
          final service = item.kind == MediaLibraryKind.audio
              ? progress['audio']
              : progress[lane.key];
          final target = targetFor(item);
          if (service == null || target == null) continue;
          if (item.kind == MediaLibraryKind.iso &&
              item.sourceKind != MediaSourceKind.local &&
              isoServices[lane.key] != null) {
            iso.add({
              'item': item.toJson(),
              'state': await isoServices[lane.key]!.portableState(
                profileId: item.sourceId,
                resolvedUrl: target,
                playbackMode: item.playbackMode,
              ),
            });
            continue;
          }
          final state = await service.getResumeProgress(
            target,
            profileId: item.sourceId,
          );
          if (state != null) {
            saved.add({
              'item': item.toJson(),
              'positionMs': state.positionMs,
              'durationMs': state.durationMs,
              'updatedAt': state.updatedAt?.millisecondsSinceEpoch,
            });
          } else {
            final watch = await players[lane.key]?.portableWatchLater(target);
            if ((watch?.startSeconds ?? 0) > 0) {
              saved.add({
                'item': item.toJson(),
                'positionMs': (watch!.startSeconds! * 1000).round(),
                'durationMs': watch.durationSeconds == null
                    ? null
                    : (watch.durationSeconds! * 1000).round(),
              });
            }
          }
        }
        positions[lane.key] = saved;
        discs[lane.key] = iso;
      }
      final refs = <String>{}, localPaths = <String>{};
      for (final row in (catalog['works'] as List).whereType<Map>()) {
        refs.addAll(
          [row['poster_path'], row['backdrop_path']].whereType<String>(),
        );
        final metadata = jsonDecode(row['metadata_json'] as String) as Map;
        for (final person in [
          ...?(metadata['credits']?['cast'] as List?),
          ...?(metadata['credits']?['crew'] as List?),
        ].whereType<Map>()) {
          if (person['profile_path'] case final String path) refs.add(path);
        }
      }
      for (final row in (catalog['season_metadata'] as List).whereType<Map>()) {
        final metadata = jsonDecode(row['metadata_json'] as String) as Map;
        if (metadata['poster_path'] case final String path) refs.add(path);
        for (final episode
            in (metadata['episodes'] as List? ?? []).whereType<Map>()) {
          if (episode['still_path'] case final String path) refs.add(path);
        }
      }
      for (final table in ['root_covers', 'collection_covers']) {
        for (final row in (catalog[table] as List? ?? []).whereType<Map>()) {
          if (row['custom_path'] case final String path when path.isNotEmpty) {
            localPaths.add(path);
          }
        }
      }
      final background = await store.backgroundPath();
      if (background != null && background.isNotEmpty) {
        localPaths.add(background);
      }
      final artwork = <String, String>{};
      for (final path in {...refs, ...localPaths}) {
        final file = localPaths.contains(path)
            ? File(path)
            : await images.cached(path, 'original') ??
                  await images.cached(path, 'w780') ??
                  await images.cached(path, 'w500') ??
                  await images.cached(path, 'w342') ??
                  await images.cached(path, 'w300') ??
                  await images.cached(path, 'w185');
        // 未缓存图片保留稳定引用，导出不依赖来源在线。
        if (file == null) continue;
        if (await file.length() > 10 * 1024 * 1024) {
          throw const FilmCatalogException('imageTooLarge');
        }
        final hash = (await sha256.bind(file.openRead()).first).toString();
        final name = 'assets/$hash.bin';
        final staged = File(p.join(temporary.path, name));
        await staged.parent.create(recursive: true);
        if (!await staged.exists()) await file.copy(staged.path);
        artwork[path] = name;
      }
      final payload = {
        'catalog': catalog,
        'records': personal,
        'progress': positions,
        'artwork': artwork,
        'discs': discs,
      };
      await Isolate.run(() async {
        final data = File(p.join(temporary.path, 'data.json'));
        await data.writeAsString(jsonEncode(payload), flush: true);
        final files = <String, Map<String, Object>>{};
        await for (final file in temporary.list(
          recursive: true,
          followLinks: false,
        )) {
          if (file is! File) continue;
          files[p
              .relative(file.path, from: temporary.path)
              .replaceAll('\\', '/')] = {
            'size': await file.length(),
            'sha256': (await sha256.bind(file.openRead()).first).toString(),
          };
        }
        final manifest = File(p.join(temporary.path, 'manifest.json'));
        await manifest.writeAsString(
          jsonEncode({
            'format': 'StreamPath film library',
            'version': 1,
            'collections': collections,
            'files': files,
          }),
          flush: true,
        );
        final partial = File('${output.path}.partial');
        final encoder = ZipFileEncoder()..create(partial.path);
        try {
          for (final name in [...files.keys, 'manifest.json']) {
            await encoder.addFile(File(p.join(temporary.path, name)), name);
          }
        } finally {
          await encoder.close();
        }
        await partial.rename(output.path);
      });
    } finally {
      await temporary.delete(recursive: true);
    }
    return output;
  }

  static Future<FilmTransferPreview> preflight(File zip) async {
    final temporary = await Directory.systemTemp.createTemp(
      'streampath_import_',
    );
    try {
      final (data, sources) = await Isolate.run(() async {
        final input = InputFileStream(zip.path);
        try {
          final archive = ZipDecoder().decodeStream(input);
          if (archive.length > 100000) {
            throw const FilmCatalogException('invalidImport');
          }
          final names = <String>{};
          var total = 0;
          for (final file in archive) {
            final name = file.name;
            if (!file.isFile ||
                file.isSymbolicLink ||
                !(name == 'manifest.json' ||
                    name == 'data.json' ||
                    RegExp(r'^assets/[a-f0-9]{64}\.bin$').hasMatch(name)) ||
                !names.add(name.toLowerCase())) {
              throw const FilmCatalogException('invalidImport');
            }
            final limit = name.startsWith('assets/')
                ? 10 * 1024 * 1024
                : 128 * 1024 * 1024;
            total += file.size;
            if (file.size < 0 ||
                file.size > limit ||
                total > 1024 * 1024 * 1024) {
              throw const FilmCatalogException('invalidImport');
            }
            final destination = File(p.join(temporary.path, name));
            await destination.parent.create(recursive: true);
            final output = _BoundedZipOutput(destination.path, file.size);
            try {
              file.writeContent(output);
              output.flush();
            } finally {
              await output.close();
            }
            if (await destination.length() != file.size) {
              throw const FilmCatalogException('invalidImport');
            }
          }
          if (!names.contains('manifest.json') ||
              !names.contains('data.json')) {
            throw const FilmCatalogException('invalidImport');
          }
          final manifest =
              jsonDecode(
                    await File(
                      p.join(temporary.path, 'manifest.json'),
                    ).readAsString(),
                  )
                  as Map;
          if (manifest['format'] != 'StreamPath film library' ||
              manifest['version'] != 1) {
            throw const FilmCatalogException('invalidImport');
          }
          final entries = manifest['files'] as Map;
          if (entries.length + 1 != names.length ||
              !entries.containsKey('data.json')) {
            throw const FilmCatalogException('invalidImport');
          }
          for (final entry in entries.entries) {
            if (!names.contains(entry.key) || entry.key == 'manifest.json') {
              throw const FilmCatalogException('invalidImport');
            }
            final file = File(p.join(temporary.path, entry.key as String));
            if (await file.length() != (entry.value as Map)['size'] ||
                (await sha256.bind(file.openRead()).first).toString() !=
                    entry.value['sha256']) {
              throw const FilmCatalogException('invalidImport');
            }
          }
          final data = Map<String, dynamic>.from(
            jsonDecode(
                  await File(
                    p.join(temporary.path, 'data.json'),
                  ).readAsString(),
                )
                as Map,
          );
          final catalog = data['catalog'] as Map;
          final sources = <String>{};
          for (final row in catalog['catalog_roots'] as List) {
            FilmCatalogRoot.fromRow(Map<String, Object?>.from(row));
            validateFilmPath(row['root_path'] as String);
            sources.add(row['source_id'] as String);
          }
          for (final work in catalog['works'] as List) {
            FilmWork.fromRow(Map<String, Object?>.from(work as Map));
          }
          for (final resource in catalog['resources'] as List) {
            validateFilmPath(resource['relative_path'] as String);
            validateFilmPath(resource['parent_path'] as String);
            if (![
              'video',
              'strm',
              'iso',
              'bdmv',
            ].contains(resource['media_kind'])) {
              throw const FilmCatalogException('invalidImport');
            }
          }
          for (final lane in (data['records'] as Map).values) {
            for (final rows in (lane as Map).values) {
              for (final row in rows as List) {
                _validateItem(Map<String, dynamic>.from(row));
                final item = MediaLibraryRecord.fromJson(
                  Map<String, dynamic>.from(row),
                );
                sources.add(item.item.sourceId);
              }
            }
          }
          for (final lane in (data['progress'] as Map).values) {
            for (final row in lane as List) {
              _validateItem(Map<String, dynamic>.from(row['item'] as Map));
              if (row['positionMs'] is! int ||
                  row['positionMs'] < 0 ||
                  row['durationMs'] != null &&
                      (row['durationMs'] is! int || row['durationMs'] <= 0)) {
                throw const FilmCatalogException('invalidImport');
              }
            }
          }
          for (final lane in (data['discs'] as Map? ?? {}).values) {
            for (final row in lane as List) {
              _validateItem(Map<String, dynamic>.from(row['item'] as Map));
              final state = row['state'] as Map,
                  selection = row['state']['selection'] as Map;
              for (final field in ['order', 'selected']) {
                if (!(selection[field] as List).every(
                  (id) => id is String && RegExp(r'^\d{5}$').hasMatch(id),
                )) {
                  throw const FilmCatalogException('invalidImport');
                }
              }
              if (selection['lastMplsId'] != null &&
                  !RegExp(
                    r'^\d{5}$',
                  ).hasMatch(selection['lastMplsId'] as String)) {
                throw const FilmCatalogException('invalidImport');
              }
              for (final entry in (state['titles'] as Map).entries) {
                if (!RegExp(r'^\d{5}$').hasMatch(entry.key as String)) {
                  throw const FilmCatalogException('invalidImport');
                }
                final position = entry.value['position'],
                    duration = entry.value['duration'];
                if (position is! num ||
                    !position.isFinite ||
                    position <= 0 ||
                    duration != null &&
                        (duration is! num ||
                            !duration.isFinite ||
                            duration <= 0)) {
                  throw const FilmCatalogException('invalidImport');
                }
              }
              if (state['menu'] case final Map menu) {
                final edition = menu['edition'],
                    editions = menu['editions'],
                    position = menu['position'],
                    duration = menu['duration'];
                if (edition is! int ||
                    editions is! int ||
                    edition < 0 ||
                    edition >= editions ||
                    position is! num ||
                    !position.isFinite ||
                    position < 0 ||
                    duration is! num ||
                    !duration.isFinite ||
                    duration <= 0 ||
                    menu['completed'] is! bool) {
                  throw const FilmCatalogException('invalidImport');
                }
              }
            }
          }
          for (final entry in (data['artwork'] as Map).entries) {
            if (entry.key is! String ||
                entry.value is! String ||
                !RegExp(
                  r'^assets/[a-f0-9]{64}\.bin$',
                ).hasMatch(entry.value as String) ||
                !await File(p.join(temporary.path, entry.value)).exists()) {
              throw const FilmCatalogException('invalidImport');
            }
          }
          for (final table in [
            'root_covers',
            'collection_covers',
            'film_collections',
          ]) {
            for (final row in catalog[table] as List? ?? []) {
              final path = row['custom_path'];
              if (path != null &&
                  path != '' &&
                  !(data['artwork'] as Map).containsKey(path)) {
                throw const FilmCatalogException('invalidImport');
              }
            }
          }
          for (final row in catalog['catalog_preferences'] as List) {
            if (![
              'background',
              'sections',
              'spoiler_protection',
            ].contains(row['key'])) {
              throw const FilmCatalogException('invalidImport');
            }
            if (row['key'] == 'background' &&
                row['value_json'] != '' &&
                !(data['artwork'] as Map).containsKey(row['value_json'])) {
              throw const FilmCatalogException('invalidImport');
            }
          }
          return (data, sources);
        } finally {
          await input.close();
        }
      });
      final catalog = data['catalog'] as Map;
      for (final asset in (data['artwork'] as Map).values.toSet()) {
        await FilmCatalogImageCache.validatePortableImage(
          File(p.join(temporary.path, asset as String)),
        );
      }
      return FilmTransferPreview(temporary, data, sources, {
        'metadata': (catalog['works'] as List).length,
        'playback':
            (catalog['film_watch_state'] as List).length +
            (catalog['film_disc_watch_state'] as List).length +
            (data['records'] as Map).values.fold<int>(
              0,
              (count, lane) =>
                  count +
                  (lane as Map).entries
                      .where((entry) => entry.key != 'favorites')
                      .fold<int>(
                        0,
                        (sum, entry) => sum + (entry.value as List).length,
                      ),
            ) +
            (data['progress'] as Map).values.fold<int>(
              0,
              (count, lane) => count + (lane as List).length,
            ) +
            (data['discs'] as Map? ?? {}).values.fold<int>(
              0,
              (count, lane) => count + (lane as List).length,
            ),
        'favorites':
            (catalog['work_favorites'] as List).length +
            (data['records'] as Map).values.fold<int>(
              0,
              (count, lane) =>
                  count + ((lane as Map)['favorites'] as List).length,
            ),
        'artwork': (data['artwork'] as Map).length,
        'collections': (catalog['film_collections'] as List? ?? []).length,
      });
    } on FormatException {
      await temporary.delete(recursive: true);
      throw const FilmCatalogException('invalidImport');
    } on TypeError {
      await temporary.delete(recursive: true);
      throw const FilmCatalogException('invalidImport');
    } catch (_) {
      await temporary.delete(recursive: true);
      rethrow;
    }
  }

  Future<Map<String, int>> import(
    FilmTransferPreview preview,
    Set<String> categories,
    Map<String, String> sources, {
    required Future<bool> Function(MediaLibraryItem) matches,
    Map<String, MediaSourceKind> sourceKinds = const {},
    Future<void> Function()? beforeCommit,
  }) async {
    if (categories.isEmpty) return {};
    final directory = Directory(
      p.join(dataDirectory.path, '.film-import-recovery'),
    );
    if (await directory.exists()) {
      throw const FilmCatalogException('importRecoveryRequired');
    }
    await directory.create(recursive: true);
    final backups = <String, String?>{};
    final sqlite = <String, String>{};
    final jsonStores = <String, File?>{};
    final discFiles = <String, String>{};
    final otherFiles = <String, File?>{};
    var prepared = false;
    var cleanup = true;
    try {
      final dbs = {
        store.databasePath: store.backupTo,
        for (final service
            in categories.contains('playback')
                ? progress.values
                : <PlaybackProgressService>[])
          service.databasePath: service.backupTo,
      };
      var index = 0;
      if (categories.contains('playback')) {
        for (final lane in (preview.data['discs'] as Map? ?? {}).entries) {
          final iso = isoServices[lane.key];
          if (iso == null) continue;
          for (final raw in lane.value as List) {
            final identity = Map<String, dynamic>.from(raw['item'] as Map);
            final source = sources[identity['sourceId']];
            if (source == null) continue;
            identity['sourceId'] = source;
            if (sourceKinds[source] case final kind?) {
              identity['sourceKind'] = kind.jsonValue;
            }
            final item = MediaLibraryItem.fromJson(identity);
            if (item.sourceKind == MediaSourceKind.local ||
                !await matches(item)) {
              continue;
            }
            final target = targetFor(item);
            if (target != null) {
              await iso.planPortableState(
                Map<String, dynamic>.from(raw['state'] as Map),
                profileId: source,
                resolvedUrl: target,
                playbackMode: item.playbackMode,
                files: discFiles,
              );
            }
          }
        }
        for (final path in discFiles.keys) {
          if (!p.isWithin(dataDirectory.path, path)) {
            throw StateError(
              'Disc state is outside the portable data directory',
            );
          }
          final file = File(path);
          final backup = await file.exists()
              ? await file.copy(p.join(directory.path, '${index++}.json'))
              : null;
          backups[p.relative(path, from: dataDirectory.path)] = backup == null
              ? null
              : p.basename(backup.path);
          otherFiles[path] = backup;
        }
      }
      for (final entry in dbs.entries) {
        if (!p.isWithin(dataDirectory.path, entry.key)) {
          throw StateError('Database is outside the portable data directory');
        }
        final backup = p.join(directory.path, '${index++}.db');
        await entry.value(backup);
        backups[p.relative(entry.key, from: dataDirectory.path)] = p.basename(
          backup,
        );
        sqlite[entry.key] = backup;
      }
      for (final lane
          in categories.contains('playback') || categories.contains('favorites')
              ? records.entries
              : <MapEntry<String, MediaLibraryStore>>[]) {
        await lane.value.portableSnapshot();
        final path = lane.value.storagePath;
        if (!p.isWithin(dataDirectory.path, path)) {
          throw StateError(
            'Media records are outside the portable data directory',
          );
        }
        final original = File(path);
        final backup = await original.exists()
            ? await original.copy(p.join(directory.path, '${index++}.json'))
            : null;
        backups[p.relative(path, from: dataDirectory.path)] = backup == null
            ? null
            : p.basename(backup.path);
        jsonStores[lane.key] = backup;
      }
      await File(p.join(directory.path, 'journal.json')).writeAsString(
        jsonEncode({'state': 'prepared', 'files': backups}),
        flush: true,
      );
      prepared = true;
      cleanup = false;
      final artwork = Map<String, String>.from(preview.data['artwork'] as Map);
      final assetDirectory = Directory(
        p.join(dataDirectory.path, 'library', 'imported_artwork'),
      );
      if (categories.contains('artwork')) {
        await assetDirectory.create(recursive: true);
        for (final name in artwork.values.toSet()) {
          final file = File(p.join(preview.directory.path, name));
          final target = File(p.join(assetDirectory.path, p.basename(name)));
          if (!await target.exists()) await file.copy(target.path);
        }
      }
      final exportDataPath = p.join(preview.directory.path, 'data.json');
      final assetPath = assetDirectory.path;
      final catalog = await Isolate.run(() {
        final data = jsonDecode(File(exportDataPath).readAsStringSync()) as Map;
        Object? rewrite(Object? value, {bool localFile = false}) {
          if (value is List) {
            for (var index = 0; index < value.length; index++) {
              value[index] = rewrite(value[index]);
            }
            return value;
          }
          if (value is Map) {
            for (final key in value.keys) {
              value[key] = rewrite(
                value[key],
                localFile: key == 'custom_path' || key == 'value_json',
              );
            }
            return value;
          }
          if (value is! String) return value;
          if (artwork[value] case final String asset
              when categories.contains('artwork')) {
            return localFile
                ? p.join(assetPath, p.basename(asset))
                : FilmImageReference(
                    'asset',
                    'app',
                    'imported_artwork/${p.basename(asset)}',
                  ).encode();
          }
          if (value.startsWith('sp-image:')) {
            final ref = FilmImageReference.parse(value)!;
            return FilmImageReference(
              ref.origin,
              sources[ref.sourceId] ?? ref.sourceId,
              ref.path,
              type: ref.type,
              tag: ref.tag,
              index: ref.index,
            ).encode();
          }
          return value;
        }

        final catalog = Map<String, dynamic>.from(
          rewrite(data['catalog']) as Map,
        );
        if (!categories.contains('artwork')) {
          for (final row in catalog['film_collections'] as List? ?? []) {
            row['custom_path'] = null;
          }
        }
        for (final table in ['works', 'season_metadata']) {
          for (final row in catalog[table] as List) {
            row['metadata_json'] = jsonEncode(
              rewrite(jsonDecode(row['metadata_json'] as String)),
            );
          }
        }
        return catalog;
      });
      final personal = <String, Map<String, dynamic>>{};
      var skipped = 0;
      for (final lane in (preview.data['records'] as Map).entries) {
        if (!records.containsKey(lane.key)) continue;
        final result = <String, dynamic>{};
        for (final group in (lane.value as Map).entries) {
          final rows = <Map<String, dynamic>>[];
          for (final raw in group.value as List) {
            final row = Map<String, dynamic>.from(raw as Map);
            final source = sources[row['sourceId']];
            if (source == null) {
              skipped++;
              continue;
            }
            row['sourceId'] = source;
            if (sourceKinds[source] case final kind?) {
              row['sourceKind'] = kind.jsonValue;
            }
            final item = MediaLibraryItem.fromJson(row);
            if (!await matches(item)) {
              skipped++;
              continue;
            }
            rows.add(row);
          }
          result[group.key as String] = rows;
        }
        personal[lane.key as String] = result;
      }
      await beforeCommit?.call();
      final result = await store.importPortable(catalog, categories, sources);
      if (categories.contains('playback') || categories.contains('favorites')) {
        for (final lane in personal.entries) {
          await records[lane.key]!.importPortable(lane.value, categories);
        }
      }
      if (categories.contains('playback')) {
        for (final lane in (preview.data['progress'] as Map).entries) {
          for (final raw in lane.value as List) {
            final row = Map<String, dynamic>.from(raw as Map);
            final identity = Map<String, dynamic>.from(row['item'] as Map);
            final source = sources[identity['sourceId']];
            if (source == null) continue;
            identity['sourceId'] = source;
            if (sourceKinds[source] case final kind?) {
              identity['sourceKind'] = kind.jsonValue;
            }
            final item = MediaLibraryItem.fromJson(identity);
            if (!await matches(item)) continue;
            final target = targetFor(item);
            final service = item.kind == MediaLibraryKind.audio
                ? progress['audio']
                : progress[lane.key];
            if (target == null ||
                service == null ||
                await service.getResumeProgress(target, profileId: source) !=
                    null) {
              continue;
            }
            await service.saveProgress(
              url: target,
              profileId: source,
              positionMs: row['positionMs'] as int,
              durationMs: row['durationMs'] as int?,
            );
          }
        }
      }
      final committed = File(p.join(directory.path, 'journal.json.partial'));
      for (final entry in discFiles.entries) {
        final file = File(entry.key);
        await file.parent.create(recursive: true);
        final staged = File('${file.path}.import-pending');
        await staged.writeAsString(entry.value, flush: true);
        await staged.rename(file.path);
      }
      await committed.writeAsString(
        jsonEncode({'state': 'committed', 'files': backups}),
        flush: true,
      );
      await committed.rename(p.join(directory.path, 'journal.json'));
      cleanup = true;
      result['skipped'] = result['skipped']! + skipped;
      return result;
    } catch (_) {
      if (prepared) {
        await store.restoreBackup(sqlite[store.databasePath]!);
        for (final service in progress.values) {
          if (sqlite[service.databasePath] case final String backup) {
            await service.restoreBackup(backup);
          }
        }
        for (final lane in records.entries) {
          if (jsonStores.containsKey(lane.key)) {
            await lane.value.reloadFromBackup(jsonStores[lane.key]);
          }
        }
        for (final entry in otherFiles.entries) {
          final original = File(entry.key);
          if (entry.value == null) {
            if (await original.exists()) await original.delete();
          } else {
            await entry.value!.copy(original.path);
          }
        }
      }
      cleanup = true;
      rethrow;
    } finally {
      if (cleanup && await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  }

  /// 启动时在打开任何数据库前恢复未完成提交；重复恢复保持幂等。
  static Future<void> recover(Directory dataDirectory) async {
    final directory = Directory(
      p.join(dataDirectory.path, '.film-import-recovery'),
    );
    final journal = File(p.join(directory.path, 'journal.json'));
    if (!await journal.exists()) {
      if (await directory.exists()) await directory.delete(recursive: true);
      return;
    }
    final state = jsonDecode(await journal.readAsString()) as Map;
    if (state['state'] == 'prepared') {
      for (final entry in (state['files'] as Map).entries) {
        final path = entry.key as String;
        if (p.isAbsolute(path) ||
            path.split(RegExp(r'[/\\]')).any((part) => part == '..')) {
          throw const FilmCatalogException('importRecoveryRequired');
        }
        final original = File(p.join(dataDirectory.path, path));
        if (!p.isWithin(dataDirectory.path, original.path)) {
          throw const FilmCatalogException('importRecoveryRequired');
        }
        if (entry.value == null) {
          if (await original.exists()) await original.delete();
          continue;
        }
        final name = entry.value as String;
        if (!RegExp(r'^\d+\.(db|json)$').hasMatch(name)) {
          throw const FilmCatalogException('importRecoveryRequired');
        }
        final backup = File(p.join(directory.path, name));
        final temporary = await backup.copy('${original.path}.import-restore');
        await temporary.rename(original.path);
        if (name.endsWith('.db')) {
          for (final suffix in ['-wal', '-shm']) {
            final file = File('${original.path}$suffix');
            if (await file.exists()) await file.delete();
          }
        }
      }
    } else if (state['state'] != 'committed') {
      throw const FilmCatalogException('importRecoveryRequired');
    }
    await directory.delete(recursive: true);
  }
}

class _BoundedZipOutput extends OutputFileStream {
  _BoundedZipOutput(String path, this.limit)
    : super.withFileHandle(FileHandle(path, mode: FileAccess.write));
  final int limit;
  int _written = 0;
  void _claim(int count) {
    _written += count;
    if (_written > limit) throw const FilmCatalogException('invalidImport');
  }

  @override
  void writeByte(int value) {
    _claim(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _claim(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      writeBytes(stream.readBytes(stream.length.clamp(0, 65536)).toUint8List());
    }
  }
}
