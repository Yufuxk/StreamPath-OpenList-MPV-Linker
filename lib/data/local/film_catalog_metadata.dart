part of 'film_catalog_store.dart';

Map<String, dynamic> _metadataPatch(
  Map<String, dynamic> previous,
  Map<String, dynamic> changes,
  Set<String> restore,
) {
  final patch = {...previous}..removeWhere((key, _) => restore.contains(key));
  patch.addAll(changes);
  if (patch['image_sources'] case final Map value) {
    final choices = Map<String, dynamic>.from(value);
    for (final image in ['poster_path', 'backdrop_path', 'logo_path']) {
      if (restore.contains(image) || changes[image] == '') {
        choices.remove(image);
      }
    }
    if (choices.isEmpty) {
      patch.remove('image_sources');
    } else {
      patch['image_sources'] = choices;
    }
  }
  return patch;
}

Map<String, dynamic> _canonicalSeason(
  Map<String, dynamic> value, {
  bool episode = false,
}) {
  final result = {
    ...value,
    'title': value['name'] ?? '',
    'release_date': value['air_date'],
    if (value['year'] == null && value['air_date'] is String)
      'year': int.tryParse((value['air_date'] as String).split('-').first),
    if (episode) 'poster_path': value['still_path'],
  };
  result.remove('_manual');
  return result;
}

Map<String, dynamic> _seasonValues(
  Map<String, dynamic> source,
  Map<String, dynamic> patch, {
  bool episode = false,
}) {
  final value = filmApplyMetadata(source, patch);
  value['name'] = value['title'];
  value['air_date'] = value['release_date'];
  if (episode) value['still_path'] = value['poster_path'];
  return value;
}

Map<String, dynamic> _mergeSeasonMetadata(
  Map<String, dynamic> incoming,
  Map<String, dynamic> previous,
) {
  final source = incoming.containsKey('_manual')
      ? filmMetadataSource(incoming)
      : _canonicalSeason(incoming);
  final patch = {
    ...filmMetadataOverrides(incoming),
    ...filmMetadataOverrides(previous),
  };
  source['episodes'] = incoming['episodes'] ?? [];
  final oldEpisodes = {
    for (final e in (previous['episodes'] as List? ?? []).whereType<Map>())
      e['episode_number']: Map<String, dynamic>.from(e),
  };
  final episodes = <Map<String, dynamic>>[];
  for (final e in (source['episodes'] as List? ?? []).whereType<Map>()) {
    final row = Map<String, dynamic>.from(e);
    final old = oldEpisodes.remove(e['episode_number']) ?? {};
    episodes.add(
      _seasonValues(
        row.containsKey('_manual')
            ? filmMetadataSource(row)
            : _canonicalSeason(row, episode: true),
        {...filmMetadataOverrides(row), ...filmMetadataOverrides(old)},
        episode: true,
      ),
    );
  }
  episodes.addAll(
    oldEpisodes.values.where((e) => filmMetadataOverrides(e).isNotEmpty),
  );
  source['episodes'] = episodes;
  return _seasonValues(source, patch);
}

extension FilmCatalogMetadata on FilmCatalogStore {
  Future<void> saveMetadataCandidates(
    FilmMetadataSnapshot snapshot,
    Map<String, List<Map<String, dynamic>>> candidates,
  ) async {
    var target = snapshot.target;
    if (target.level == FilmMetadataLevel.resource) {
      final r = snapshot.resource!;
      if (r.workId == null) return;
      target = r.season != null && r.episode != null
          ? FilmMetadataTarget.episode(r.workId, r.season, r.episode)
          : FilmMetadataTarget.work(r.workId);
    }
    final fields = {
      for (final e in candidates.entries)
        e.key.replaceFirst('_path', '_candidates'): e.value,
    };
    await _db.transaction((txn) async {
      if (target.level == FilmMetadataLevel.work) {
        final rows = await txn.query(
          'works',
          where: 'id=?',
          whereArgs: [target.workId],
        );
        if (rows.isEmpty) return;
        final work = FilmWork.fromRow(rows.single);
        final source = work.metadata.containsKey('_manual')
            ? filmMetadataSource(work.metadata)
            : filmWorkMetadata(work);
        await _writeMetadataWork(
          txn,
          rows.single,
          filmApplyMetadata({
            ...source,
            ...fields,
          }, filmMetadataOverrides(work.metadata)),
        );
      } else {
        final rows = await txn.query(
          'season_metadata',
          where: 'work_id=? AND season_number=?',
          whereArgs: [target.workId, target.season],
        );
        if (rows.isEmpty) return;
        final season = Map<String, dynamic>.from(
          jsonDecode(rows.single['metadata_json'] as String) as Map,
        );
        if (target.level == FilmMetadataLevel.season) {
          season.addAll(fields);
          if (season['_manual'] case final Map m) {
            (m['source'] as Map).addAll(fields);
          }
        } else {
          final episode = (season['episodes'] as List? ?? [])
              .whereType<Map>()
              .where((e) => e['episode_number'] == target.episode)
              .firstOrNull;
          if (episode == null) return;
          episode.addAll(fields);
          if (episode['_manual'] case final Map m) {
            (m['source'] as Map).addAll(fields);
          }
          if (season['_manual'] case final Map m) {
            (m['source'] as Map)['episodes'] = season['episodes'];
          }
        }
        await txn.update(
          'season_metadata',
          {'metadata_json': jsonEncode(season)},
          where: 'work_id=? AND season_number=?',
          whereArgs: [target.workId, target.season],
        );
      }
    });
  }

  Future<Set<String>> metadataArtworkReferences() async {
    final refs = <String>{};
    void visit(Object? value) {
      if (value is Map) {
        for (final child in value.values) {
          visit(child);
        }
      } else if (value is List) {
        for (final child in value) {
          visit(child);
        }
      } else if (value is String && value.startsWith('sp-image:')) {
        refs.add(value);
      }
    }

    for (final table in ['works', 'season_metadata', 'resources']) {
      final field = table == 'resources'
          ? 'metadata_override_json'
          : 'metadata_json';
      for (final row in await _db.query(table, columns: [field])) {
        visit(jsonDecode(row[field] as String));
      }
    }
    return refs;
  }

  Future<FilmMetadataSnapshot> metadataSnapshot(
    FilmMetadataTarget target,
  ) async {
    final resource = target.resourceId == null
        ? null
        : await this.resource(target.resourceId!);
    if (target.resourceId != null && resource == null) {
      throw const FilmCatalogException('staleMatch');
    }
    final workId = target.workId ?? resource?.workId;
    final work = workId == null ? null : await this.work(workId);
    if (target.level != FilmMetadataLevel.resource && work == null) {
      throw const FilmCatalogException('staleMatch');
    }
    Map<String, dynamic> value;
    switch (target.level) {
      case FilmMetadataLevel.work:
        value = {
          ...filmWorkMetadata(work!),
          if (work.metadata['_manual'] != null)
            '_manual': work.metadata['_manual'],
        };
      case FilmMetadataLevel.season:
      case FilmMetadataLevel.episode:
        final season = await this.season(workId!, target.season!);
        if (target.level == FilmMetadataLevel.season) {
          value = {
            ..._canonicalSeason(season ?? {'name': 'S${target.season}'}),
            if (season?['_manual'] != null) '_manual': season!['_manual'],
          };
        } else {
          final e = (season?['episodes'] as List? ?? [])
              .whereType<Map>()
              .where((e) => e['episode_number'] == target.episode)
              .firstOrNull;
          value = {
            ..._canonicalSeason(
              Map<String, dynamic>.from(e ?? {'name': 'E${target.episode}'}),
              episode: true,
            ),
            if (e?['_manual'] != null) '_manual': e!['_manual'],
          };
        }
      case FilmMetadataLevel.resource:
        value = {'title': resource!.name};
        if (work != null) value.addAll(filmWorkMetadata(work));
        if (resource.type == FilmMediaType.tv &&
            resource.season != null &&
            resource.episode != null) {
          final s = await season(workId!, resource.season!);
          final e = (s?['episodes'] as List? ?? [])
              .whereType<Map>()
              .where((e) => e['episode_number'] == resource.episode)
              .firstOrNull;
          if (e != null) {
            value.addAll(
              _canonicalSeason(Map<String, dynamic>.from(e), episode: true),
            );
          }
        }
        if (resource.isExtra || resource.workId == null) {
          value['title'] = resource.name;
        }
        value = filmApplyMetadata(value, resource.metadataOverrides);
    }
    return FilmMetadataSnapshot(
      target: target,
      source: filmMetadataSource(value),
      overrides: filmMetadataOverrides(value),
      values: {...value}..remove('_manual'),
      resource: resource,
      work: work,
    );
  }

  Future<void> saveMetadata(
    FilmMetadataSnapshot snapshot,
    Map<String, dynamic> changes, {
    Set<String> restore = const {},
  }) async {
    if (!filmMetadataFields.containsAll({...changes.keys, ...restore})) {
      throw const FilmCatalogException('invalidMetadata');
    }
    final latest = await metadataSnapshot(snapshot.target);
    final before = snapshot.resource, current = latest.resource;
    if (before != null &&
        (current!.bindingVersion != before.bindingVersion ||
            current.workId != before.workId ||
            current.season != before.season ||
            current.episode != before.episode)) {
      throw const FilmCatalogException('staleMatch');
    }
    final patch = _metadataPatch(latest.overrides, changes, restore);
    final effective = filmApplyMetadata(latest.source, patch);
    validateFilmMetadata(effective);
    await _db.transaction((txn) async {
      final t = snapshot.target;
      if (t.level == FilmMetadataLevel.work) {
        final rows = await txn.query(
          'works',
          where: 'id=?',
          whereArgs: [t.workId],
        );
        if (rows.isEmpty) throw const FilmCatalogException('staleMatch');
        final now = FilmWork.fromRow(rows.single);
        final source = now.metadata.containsKey('_manual')
            ? filmMetadataSource(now.metadata)
            : filmWorkMetadata(now);
        final mergedPatch = _metadataPatch(
          filmMetadataOverrides(now.metadata),
          changes,
          restore,
        );
        final value = filmApplyMetadata(source, mergedPatch);
        validateFilmMetadata(value);
        await _writeMetadataWork(txn, rows.single, value);
      } else if (t.level == FilmMetadataLevel.resource) {
        await _checkResource(txn, before!);
        final currentRow = (await txn.query(
          'resources',
          where: 'id=?',
          whereArgs: [t.resourceId],
        )).single;
        if (currentRow['work_id'] != before.workId ||
            currentRow['season_number'] != before.season ||
            currentRow['episode_number'] != before.episode) {
          throw const FilmCatalogException('staleMatch');
        }
        final resourcePatch = _metadataPatch(
          Map<String, dynamic>.from(
            jsonDecode(currentRow['metadata_override_json'] as String) as Map,
          ),
          changes,
          restore,
        );
        await txn.update(
          'resources',
          {'metadata_override_json': jsonEncode(resourcePatch)},
          where: 'id=?',
          whereArgs: [t.resourceId],
        );
      } else {
        if ((await txn.query(
          'works',
          columns: ['id'],
          where: 'id=?',
          whereArgs: [t.workId],
        )).isEmpty) {
          throw const FilmCatalogException('staleMatch');
        }
        final rows = await txn.query(
          'season_metadata',
          where: 'work_id=? AND season_number=?',
          whereArgs: [t.workId, t.season],
        );
        var season = rows.isEmpty
            ? <String, dynamic>{
                'season_number': t.season,
                'name': 'S${t.season}',
                'episodes': <dynamic>[],
              }
            : Map<String, dynamic>.from(
                jsonDecode(rows.single['metadata_json'] as String) as Map,
              );
        if (t.level == FilmMetadataLevel.season) {
          final source = season.containsKey('_manual')
              ? filmMetadataSource(season)
              : _canonicalSeason(season);
          source['episodes'] = season['episodes'] ?? [];
          final nowPatch = _metadataPatch(
            filmMetadataOverrides(season),
            changes,
            restore,
          );
          season = _seasonValues(source, nowPatch);
        } else {
          final episodes = [...(season['episodes'] as List? ?? [])];
          final index = episodes.indexWhere(
            (e) => (e as Map)['episode_number'] == t.episode,
          );
          final row = index < 0
              ? <String, dynamic>{
                  'episode_number': t.episode,
                  'season_number': t.season,
                  'name': 'E${t.episode}',
                }
              : Map<String, dynamic>.from(episodes[index] as Map);
          final source = row.containsKey('_manual')
              ? filmMetadataSource(row)
              : _canonicalSeason(row, episode: true);
          final nowPatch = _metadataPatch(
            filmMetadataOverrides(row),
            changes,
            restore,
          );
          final edited = _seasonValues(source, nowPatch, episode: true);
          if (index < 0) {
            episodes.add(edited);
          } else {
            episodes[index] = edited;
          }
          season['episodes'] = episodes;
          if (season['_manual'] case final Map manual) {
            (manual['source'] as Map)['episodes'] = episodes;
          }
        }
        await _saveSeason(
          txn,
          t.workId!,
          t.season!,
          latest.work!.language,
          season,
          preserveManual: false,
        );
      }
    });
    notifyListeners();
  }

  Future<void> _writeMetadataWork(
    DatabaseExecutor txn,
    Map<String, Object?> row,
    Map<String, dynamic> value,
  ) async {
    final metadata = {...value}
      ..removeWhere((key, _) => filmMetadataRowFields.contains(key));
    final result = {
      ...row,
      for (final key in filmMetadataRowFields) key: value[key],
      'metadata_json': jsonEncode(metadata),
    };
    await txn.update(
      'works',
      {
        for (final key in filmMetadataRowFields) key: value[key],
        'metadata_json': jsonEncode(metadata),
      },
      where: 'id=?',
      whereArgs: [row['id']],
    );
    await _indexPhase5Work(txn, row['id'] as int, FilmWork.fromRow(result));
  }
}
