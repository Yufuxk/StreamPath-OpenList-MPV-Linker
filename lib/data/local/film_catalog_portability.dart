part of 'film_catalog_store.dart';

const _portableTables = [
  'catalog_roots',
  'works',
  'resources',
  'series_bindings',
  'season_metadata',
  'work_favorites',
  'film_watch_state',
  'film_disc_watch_state',
  'root_covers',
  'catalog_preferences',
  'film_collections',
  'collection_members',
];

extension FilmCatalogPortability on FilmCatalogStore {
  Future<Map<int, Map<String, Object?>>> _matchPortableResources(
    DatabaseExecutor txn,
    Map<String, dynamic> data,
    Map<String, String> sources,
  ) async {
    final incomingRoots = {
      for (final row in data['catalog_roots'] as List) row['id']: row,
    };
    final current = <String, List<Map<String, Object?>>>{};
    final ids = sources.values.toSet();
    if (ids.isEmpty) return {};
    for (var offset = 0; ; offset += 500) {
      final rows = await txn.rawQuery(
        '''SELECT r.*,c.source_id FROM resources r JOIN catalog_roots c ON c.id=r.root_id
        WHERE c.source_id IN (${List.filled(ids.length, '?').join(',')}) ORDER BY r.id LIMIT 500 OFFSET ?''',
        [...ids, offset],
      );
      for (final row in rows) {
        current
            .putIfAbsent(
              '${row['source_id']}\u0000${row['relative_path']}\u0000${row['media_kind']}',
              () => [],
            )
            .add(row);
      }
      if (rows.length < 500) break;
    }
    final result = <int, Map<String, Object?>>{};
    var processed = 0;
    for (final row in data['resources'] as List) {
      if (++processed % 500 == 0) await Future<void>.delayed(Duration.zero);
      final source = sources[incomingRoots[row['root_id']]?['source_id']];
      if (source == null) continue;
      final path = validateFilmPath(row['relative_path'] as String);
      final candidates =
          current['$source\u0000$path\u0000${row['media_kind']}'];
      if (candidates?.length == 1) {
        result[row['id'] as int] = candidates!.single;
      }
    }
    return result;
  }

  Future<Map<String, int>> previewPortable(
    Map<String, dynamic> data,
    Map<String, String> sources,
  ) async {
    final matched = await _matchPortableResources(_db, data, sources);
    return {
      'matched': matched.length,
      'skipped': (data['resources'] as List).length - matched.length,
    };
  }

  String get databasePath => _db.path;
  Future<void> backupTo(String path) =>
      _db.execute("VACUUM INTO '${path.replaceAll("'", "''")}'");
  Future<void> restoreBackup(String path) async {
    await _db.execute(
      "ATTACH DATABASE '${path.replaceAll("'", "''")}' AS recovery",
    );
    try {
      await _db.transaction((txn) async {
        final tables = [
          ..._portableTables,
          'resource_probes',
          'work_people',
          'server_items',
          'server_sync_pending',
          'film_playlists',
          'film_playlist_items',
          'film_playlist_scopes',
        ];
        for (final table in tables.reversed) {
          await txn.delete(table);
        }
        for (final table in tables) {
          await txn.execute('INSERT INTO $table SELECT * FROM recovery.$table');
        }
      });
    } finally {
      await _db.execute('DETACH DATABASE recovery');
    }
    spoilerProtection = await preference('spoiler_protection') == true;
    _changed();
  }

  Future<Map<String, dynamic>> portableSnapshot({bool collections = false}) =>
      _db.transaction((txn) async {
        final result = <String, dynamic>{};
        for (final table in _portableTables) {
          if (!collections && table == 'collection_members') continue;
          final rows = await txn.query(table);
          if (table == 'film_collections') {
            result['collection_covers'] = [
              for (final row in rows)
                {'id': row['id'], 'custom_path': row['custom_path']},
            ];
            if (!collections) continue;
            result[table] = rows
                .where((row) => (row['id'] as String).startsWith('custom:'))
                .toList();
          } else if (table == 'collection_members') {
            result[table] = rows
                .where(
                  (row) =>
                      (row['collection_id'] as String).startsWith('custom:'),
                )
                .toList();
          } else if (table == 'catalog_preferences') {
            result[table] = rows
                .where(
                  (row) => [
                    'background',
                    'sections',
                    'spoiler_protection',
                  ].contains(row['key']),
                )
                .toList();
          } else {
            result[table] = rows;
          }
        }
        return result;
      });

  /// 来源和资源明确匹配后合并缺失字段，已有人工选择和个人数据优先。
  Future<Map<String, int>> importPortable(
    Map<String, dynamic> data,
    Set<String> categories,
    Map<String, String> sources,
  ) async {
    final result = <String, int>{'matched': 0, 'skipped': 0, 'collections': 0};
    Iterable<Map<String, Object?>> rows(String table) =>
        (data[table] as List? ?? []).map(
          (row) => Map<String, Object?>.from(row as Map),
        );
    await _db.transaction((txn) async {
      final roots = {for (final row in rows('catalog_roots')) row['id']: row};
      final rootIds = <Object?, int>{};
      final currentRoots = await txn.query('catalog_roots');
      for (final row in roots.values) {
        final matches = currentRoots
            .where(
              (current) =>
                  current['source_id'] == sources[row['source_id']] &&
                  current['root_path'] == row['root_path'] &&
                  current['media_type'] == row['media_type'],
            )
            .toList();
        if (matches.length == 1) {
          rootIds[row['id']] = matches.single['id'] as int;
        }
      }
      final resourceIds = <int, int>{}, workIds = <int, int>{};
      final boundWorks = <int, Set<int>>{};
      final resources = await _matchPortableResources(txn, data, sources);
      final matchedIncomingWorks = <int>{};
      final collectionWorks = <int>{};
      var processed = 0;
      for (final row in rows('resources')) {
        if (++processed % 500 == 0) await Future<void>.delayed(Duration.zero);
        final source = sources[roots[row['root_id']]?['source_id']];
        if (source == null) {
          result['skipped'] = result['skipped']! + 1;
          continue;
        }
        final current = resources[row['id']];
        if (current == null) {
          result['skipped'] = result['skipped']! + 1;
          continue;
        }
        resourceIds[row['id'] as int] = current['id'] as int;
        if (row['work_id'] case final int work) {
          matchedIncomingWorks.add(work);
          if (current['work_id'] case final int id) {
            boundWorks.putIfAbsent(work, () => {}).add(id);
          }
        }
        result['matched'] = result['matched']! + 1;
      }
      for (final row in rows('works')) {
        final work = FilmWork.fromRow(row);
        final bound = boundWorks[work.id] ?? {};
        final candidates = await txn.query(
          'works',
          where:
              'media_type=? AND (identity_key=? OR ((title=? COLLATE NOCASE OR original_title=? COLLATE NOCASE) AND year IS ?))',
          whereArgs: [
            work.type.name,
            work.identity,
            work.title,
            work.originalTitle,
            work.year,
          ],
        );
        final valid = candidates
            .where(
              (candidate) =>
                  work.tmdbId == 0 ||
                  candidate['tmdb_id'] == null ||
                  candidate['tmdb_id'] == work.tmdbId,
            )
            .toList();
        final selected = bound.length == 1
            ? bound.single
            : valid.length == 1
            ? valid.single['id'] as int
            : null;
        if (selected != null) {
          final current = (await txn.query(
            'works',
            where: 'id=?',
            whereArgs: [selected],
          )).single;
          if (work.tmdbId > 0 &&
              current['tmdb_id'] != null &&
              current['tmdb_id'] != work.tmdbId) {
            continue;
          }
          workIds[work.id] = selected;
          if (current['media_type'] == row['media_type'] &&
              current['year'] == row['year'] &&
              (current['title'].toString().toLowerCase() ==
                      work.title.toLowerCase() ||
                  current['original_title'].toString().toLowerCase() ==
                      work.originalTitle.toLowerCase())) {
            collectionWorks.add(work.id);
          }
          if (categories.contains('metadata')) {
            final metadata =
                jsonDecode(current['metadata_json'] as String) as Map;
            final incoming = jsonDecode(row['metadata_json'] as String) as Map;
            workIds[work.id] = await _saveWork(
              txn,
              FilmWork.fromRow({
                ...current,
                'tmdb_id': current['tmdb_id'] ?? row['tmdb_id'],
                for (final field in [
                  'original_title',
                  'overview',
                  'poster_path',
                  'backdrop_path',
                  'year',
                ])
                  if (current[field] == null || current[field] == '')
                    field: row[field],
                'metadata_json': jsonEncode({...incoming, ...metadata}),
              }),
            );
          }
          continue;
        }
        if (bound.isNotEmpty ||
            valid.length > 1 ||
            !categories.contains('metadata') ||
            !matchedIncomingWorks.contains(work.id)) {
          continue;
        }
        workIds[work.id] = await _saveWork(
          txn,
          FilmWork.fromRow({...row, 'id': 0}),
        );
        collectionWorks.add(work.id);
      }
      if (categories.contains('metadata')) {
        for (final row in rows('resources')) {
          final current = resources[row['id']];
          final work = workIds[row['work_id']];
          if (current == null || work == null) continue;
          final values = <String, Object?>{};
          if (current['work_id'] == null) {
            values.addAll({
              'work_id': work,
              'binding_origin': row['binding_origin'],
              'binding_version': (current['binding_version'] as int) + 1,
            });
          }
          if (current['season_number'] == null &&
              row['season_number'] != null &&
              (current['work_id'] == null || current['work_id'] == work)) {
            values.addAll({
              'season_number': row['season_number'],
              'episode_number': row['episode_number'],
              'episode_mapping_origin': row['episode_mapping_origin'],
            });
          }
          if (values.isNotEmpty) {
            await txn.update(
              'resources',
              values,
              where: 'id=?',
              whereArgs: [current['id']],
            );
          }
        }
        for (final row in rows('season_metadata')) {
          if (workIds[row['work_id']] case final int work) {
            await txn.insert('season_metadata', {
              ...row,
              'work_id': work,
            }, conflictAlgorithm: ConflictAlgorithm.ignore);
          }
        }
        for (final row in rows('series_bindings')) {
          final root = rootIds[row['root_id']], work = workIds[row['work_id']];
          if (root == null || work == null) continue;
          validateFilmPath(row['directory_path'] as String);
          await txn.insert('series_bindings', {
            ...row,
            'root_id': root,
            'work_id': work,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
      for (final table in [
        'work_favorites',
        'film_watch_state',
        'film_disc_watch_state',
      ]) {
        if (!categories.contains(
          table == 'work_favorites' ? 'favorites' : 'playback',
        )) {
          continue;
        }
        for (final row in rows(table)) {
          final work = workIds[row['work_id']];
          if (work == null) continue;
          final source = row['source_id'] == null
              ? null
              : sources[row['source_id']];
          if (row['source_id'] != null && source == null) continue;
          final resource = resourceIds[row['resource_id']];
          if (table == 'film_disc_watch_state' && resource == null) continue;
          await txn.insert(table, {
            ...row,
            'work_id': work,
            'source_id': ?source,
            'resource_id': ?resource,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
      if (categories.contains('collections')) {
        for (final row in rows('film_collections')) {
          final id = row['id'] as String;
          if (!id.startsWith('custom:')) {
            throw const FilmCatalogException('invalidImport');
          }
          final exists = (await txn.query(
            'film_collections',
            where: 'id=?',
            whereArgs: [id],
          )).isNotEmpty;
          await txn.insert('film_collections', {
            ...row,
            'cover_work_id': workIds[row['cover_work_id']],
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
          if (!exists) result['collections'] = result['collections']! + 1;
        }
        for (final row in rows('collection_members')) {
          if (workIds[row['work_id']] case final int work
              when collectionWorks.contains(row['work_id'])) {
            await txn.insert('collection_members', {
              ...row,
              'work_id': work,
            }, conflictAlgorithm: ConflictAlgorithm.ignore);
          } else {
            result['skipped'] = result['skipped']! + 1;
          }
        }
      }
      if (categories.contains('artwork')) {
        for (final row in rows('root_covers')) {
          if (rootIds[row['root_id']] case final int root) {
            await txn.insert('root_covers', {
              ...row,
              'root_id': root,
              'work_id': workIds[row['work_id']],
            }, conflictAlgorithm: ConflictAlgorithm.ignore);
          }
        }
        for (final row in rows('collection_covers')) {
          await txn.update(
            'film_collections',
            {'custom_path': row['custom_path']},
            where: 'id=? AND custom_path IS NULL',
            whereArgs: [row['id']],
          );
        }
        for (final row in rows('catalog_preferences')) {
          await txn.insert(
            'catalog_preferences',
            row,
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
      }
    });
    _changed();
    return result;
  }
}
