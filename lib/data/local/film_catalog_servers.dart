part of 'film_catalog_store.dart';

String _serverId(Object? value) {
  if (value is! String || !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(value)) {
    throw const FilmCatalogException('invalidMetadata');
  }
  return value;
}

String? _serverImage(String source, Map item, String type, {String? index}) {
  final tags = item['ImageTags'] as Map?;
  final tag = type == 'Backdrop'
      ? (item['BackdropImageTags'] as List?)?.firstOrNull
      : tags?[type];
  if (tag is! String) return null;
  return FilmImageReference(
    'server',
    source,
    _serverId(item['Id']),
    type: type,
    tag: tag,
    index: index,
  ).encode();
}

FilmWork _serverWork(
  MediaConnection config,
  String serverId,
  Map item,
  FilmMediaType type,
  String language,
) {
  final provider = item['ProviderIds'] as Map?;
  final tmdb = int.tryParse('${provider?['Tmdb'] ?? ''}') ?? 0;
  final title = item['Name'] as String;
  final people = (item['People'] as List? ?? [])
      .whereType<Map>()
      .map(
        (person) => <String, dynamic>{
          if (person['Id'] != null) 'id': person['Id'],
          if (person['Id'] != null)
            'identity': 'server:$serverId:${person['Id']}',
          'name': person['Name'],
          'character': person['Role'],
          'job': person['Type'],
          if (person['Id'] != null && person['PrimaryImageTag'] != null)
            'profile_path': FilmImageReference(
              'server',
              config.id,
              _serverId(person['Id']),
              type: 'Primary',
              tag: person['PrimaryImageTag'] as String,
            ).encode(),
        },
      )
      .toList();
  final runtime = ((item['RunTimeTicks'] as num? ?? 0) / 600000000).round();
  return FilmWork(
    type: type,
    tmdbId: tmdb > 0 ? tmdb : 0,
    identityKey: 'server:$serverId:${_serverId(item['Id'])}',
    metadataOrigin: 'server',
    title: title,
    originalTitle: item['OriginalTitle'] as String? ?? title,
    year: (item['ProductionYear'] as num?)?.toInt(),
    overview: item['Overview'] as String? ?? '',
    language: language,
    posterPath: _serverImage(config.id, item, 'Primary'),
    backdropPath: _serverImage(config.id, item, 'Backdrop', index: '0'),
    metadata: {
      'genres': [
        for (final genre in item['Genres'] as List? ?? []) {'name': genre},
      ],
      'production_countries': [
        for (final country in item['ProductionLocations'] as List? ?? [])
          {'name': country},
      ],
      if (runtime > 0) 'runtime': runtime,
      'credits': {
        'cast': people.where((p) => p['job'] == 'Actor').toList(),
        'crew': people.where((p) => p['job'] != 'Actor').toList(),
      },
      'server_item_id': item['Id'],
    },
  );
}

extension FilmCatalogServerData on FilmCatalogStore {
  Future<void> rememberServerIdentity(String source, String server) async {
    if (await preference('server_identity:$source') != server) {
      await setPreference('server_identity:$source', server);
    }
  }

  Future<void> reconcileServerSources(Set<String> sources) async {
    final owners = <String>{
      for (final row in await _db.query(
        'film_playlists',
        columns: ['source_id'],
        where: "kind='server'",
        distinct: true,
      ))
        row['source_id'] as String,
      for (final root in await roots())
        if (root.sourceKind.isMediaServer) root.sourceId,
      for (final row in await _db.query(
        'film_collections',
        columns: ['id'],
        where: "id LIKE 'server:%'",
      ))
        (row['id'] as String).substring(
          'server:'.length,
          (row['id'] as String).lastIndexOf(':'),
        ),
    };
    for (final source in owners.difference(sources)) {
      await removeServerData(source);
    }
  }

  Future<void> removeServerData(String source) async {
    await _db.transaction((txn) async {
      await txn.delete(
        'film_playlists',
        where: "source_id=? AND kind='server'",
        whereArgs: [source],
      );
      final prefix = 'server:$source:';
      for (final row in await txn.query('film_collections', columns: ['id'])) {
        if ((row['id'] as String).startsWith(prefix)) {
          await txn.delete(
            'film_collections',
            where: 'id=?',
            whereArgs: [row['id']],
          );
        }
      }
      await txn.delete(
        'catalog_roots',
        where: 'source_id=?',
        whereArgs: [source],
      );
      await txn.delete(
        'server_items',
        where: 'source_id=?',
        whereArgs: [source],
      );
      await txn.delete(
        'server_sync_pending',
        where: 'source_id=?',
        whereArgs: [source],
      );
      await txn.delete(
        'catalog_preferences',
        where: 'key=?',
        whereArgs: ['server_identity:$source'],
      );
    });
    _changed();
  }

  Future<void> saveServerSeason(
    MediaConnection config,
    Map<String, dynamic> item,
    int work,
  ) async {
    final season = (item['IndexNumber'] as num?)?.toInt();
    if (season == null || season < 0) return;
    final previous = await this.season(work, season) ?? {};
    await saveSeason(work, season, await language(), {
      ...previous,
      'season_number': season,
      'name': item['Name'],
      'overview': item['Overview'] ?? '',
      'poster_path': _serverImage(config.id, item, 'Primary'),
      'episodes': previous['episodes'] ?? [],
    });
  }

  Future<void> finishServerCollections(
    String source,
    Set<String> itemIds,
  ) async {
    final prefix = 'server:$source:';
    await _db.transaction((txn) async {
      final collections = await txn.query('film_collections', columns: ['id']);
      for (final row in collections) {
        final id = row['id'] as String;
        if (id.startsWith(prefix) &&
            !itemIds.contains(id.substring(prefix.length))) {
          await txn.delete('film_collections', where: 'id=?', whereArgs: [id]);
        }
      }
    });
    _changed();
  }

  Future<List<Map<String, Object?>>> serverDirectory(
    String source,
    String path,
  ) async {
    validateFilmPath(path);
    final prefix = path.isEmpty ? '' : '$path/';
    final escaped = prefix
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
    final rows = await _db.rawQuery(
      '''SELECT DISTINCT r.relative_path FROM resources r JOIN catalog_roots c ON c.id=r.root_id
      WHERE c.source_id=? AND r.availability='present' AND r.relative_path LIKE ? ESCAPE '\\' ''',
      [source, '$escaped%'],
    );
    final names = <String, bool>{};
    for (final row in rows) {
      final tail = (row['relative_path'] as String).substring(prefix.length);
      final separator = tail.indexOf('/');
      names[separator < 0 ? tail : tail.substring(0, separator)] =
          separator >= 0;
    }
    return [
      for (final row in names.entries)
        {'name': row.key, 'directory': row.value},
    ];
  }

  Future<bool> applyServerUserData(
    String source,
    String item,
    Map<String, dynamic> userData,
  ) async {
    final applied = await _db.transaction((txn) async {
      if ((await txn.query(
        'server_sync_pending',
        where: 'source_id=? AND item_id=?',
        whereArgs: [source, item],
      )).isNotEmpty) {
        return false;
      }
      final rows = await txn.rawQuery(
        '''SELECT r.work_id,r.season_number,r.episode_number,c.media_type FROM resources r
        JOIN catalog_roots c ON c.id=r.root_id JOIN server_items s ON s.resource_id=r.id WHERE s.source_id=? AND s.item_id=?''',
        [source, item],
      );
      final keys = <(int, int, int)>{};
      final position =
          ((userData['PlaybackPositionTicks'] as num? ?? 0) / 10000).round();
      final watched = userData['Played'] == true;
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final row in rows) {
        if (row['work_id'] == null ||
            row['media_type'] == 'tv' && row['episode_number'] == null) {
          continue;
        }
        final key = (
          row['work_id'] as int,
          row['season_number'] as int? ?? -1,
          row['episode_number'] as int? ?? -1,
        );
        if (!keys.add(key)) continue;
        await txn.rawInsert(
          '''INSERT INTO film_watch_state(source_id,work_id,season_number,episode_number,watched,position_ms,observed_at)
          VALUES(?,?,?,?,?,?,?) ON CONFLICT(source_id,work_id,season_number,episode_number) DO UPDATE SET
          watched=excluded.watched,position_ms=excluded.position_ms,observed_at=excluded.observed_at''',
          [
            source,
            key.$1,
            key.$2,
            key.$3,
            watched ? 1 : 0,
            watched ? 0 : position,
            now,
          ],
        );
      }
      await txn.update(
        'server_items',
        {'user_data_json': jsonEncode(userData)},
        where: 'source_id=? AND item_id=?',
        whereArgs: [source, item],
      );
      return true;
    });
    if (applied) _changed();
    return applied;
  }

  Future<Map<FilmMediaType, FilmCatalogRoot>> serverRoots(
    MediaConnection config,
  ) async {
    final result = <FilmMediaType, FilmCatalogRoot>{};
    for (final type in FilmMediaType.values) {
      final existing = (await roots())
          .where((r) => r.sourceId == config.id && r.type == type)
          .firstOrNull;
      final id =
          existing?.id ??
          await addRoot(
            sourceId: config.id,
            kind: config.kind,
            path: type == FilmMediaType.movie ? 'movies' : 'series',
            type: type,
            name: config.name,
          );
      result[type] = (await root(id))!;
    }
    return result;
  }

  Future<int> saveServerWork(
    MediaConnection config,
    String serverId,
    Map<String, dynamic> item,
    FilmMediaType type,
  ) async {
    final work = _serverWork(config, serverId, item, type, await language());
    final id = await _db.transaction((txn) => _saveWork(txn, work));
    _changed();
    return id;
  }

  Future<void> saveServerResources(
    MediaConnection config,
    FilmCatalogRoot root,
    int generation,
    Map<String, dynamic> item,
    int workId,
  ) async {
    final itemId = _serverId(item['Id']);
    final versions = (item['MediaSources'] as List? ?? [])
        .whereType<Map>()
        .toList();
    if (versions.isEmpty) {
      versions.add({'Id': itemId, 'Container': item['Container'] ?? 'mkv'});
    }
    final season = root.type == FilmMediaType.tv
        ? (item['ParentIndexNumber'] as num?)?.toInt()
        : null;
    final episode = root.type == FilmMediaType.tv
        ? (item['IndexNumber'] as num?)?.toInt()
        : null;
    final entries = <FilmScanEntry>[];
    final versionIds = <String>[];
    for (final version in versions) {
      final id = _serverId(version['Id']);
      final extension = version['Container'] as String? ?? 'mkv';
      if (!RegExp(r'^[A-Za-z0-9]+$').hasMatch(extension)) {
        throw const FilmCatalogException('invalidMetadata');
      }
      final name = '$id.$extension';
      final directory = '${root.path}/$itemId/$id';
      versionIds.add(id);
      entries.add(
        FilmScanEntry(
          path: '$directory/$name',
          parentPath: directory,
          name: name,
          mediaKind: 'video',
        ),
      );
    }
    await stage(root, generation, entries);
    final metadataLanguage = await language();
    await _db.transaction((txn) async {
      for (var i = 0; i < entries.length; i++) {
        final entry = entries[i];
        final rows = await txn.query(
          'resources',
          where: 'root_id=? AND path_key=?',
          whereArgs: [root.id, entry.path],
        );
        final resource = rows.single;
        if (resource['binding_origin'] != 'manual') {
          await txn.update(
            'resources',
            {
              'work_id': workId,
              'binding_origin': 'server',
              'season_number': season != null && episode != null && episode > 0
                  ? season
                  : null,
              'episode_number': season != null && episode != null && episode > 0
                  ? episode
                  : null,
              'episode_mapping_origin':
                  season != null && episode != null && episode > 0
                  ? 'server'
                  : 'unset',
            },
            where: 'id=?',
            whereArgs: [resource['id']],
          );
        }
        await txn.rawInsert(
          '''INSERT INTO server_items(source_id,item_id,resource_id,media_source_id,user_data_json)
          VALUES(?,?,?,?,?) ON CONFLICT(source_id,item_id,media_source_id) DO UPDATE SET
          resource_id=excluded.resource_id,user_data_json=excluded.user_data_json''',
          [
            config.id,
            itemId,
            resource['id'],
            versionIds[i],
            jsonEncode(item['UserData'] ?? {}),
          ],
        );
      }
      if (root.type == FilmMediaType.tv &&
          season != null &&
          episode != null &&
          episode > 0) {
        final rows = await txn.query(
          'season_metadata',
          where: 'work_id=? AND season_number=?',
          whereArgs: [workId, season],
        );
        final data = rows.isEmpty
            ? <String, dynamic>{'season_number': season, 'episodes': <Object>[]}
            : Map<String, dynamic>.from(
                jsonDecode(rows.first['metadata_json'] as String) as Map,
              );
        final episodes = (data['episodes'] as List)
            .whereType<Map>()
            .where((row) => row['episode_number'] != episode)
            .toList();
        episodes.add({
          'id': itemId,
          'name': item['Name'],
          'overview': item['Overview'] ?? '',
          'season_number': season,
          'episode_number': episode,
          'runtime': ((item['RunTimeTicks'] as num? ?? 0) / 600000000).round(),
          'still_path':
              _serverImage(config.id, item, 'Primary') ??
              _serverImage(config.id, item, 'Thumb'),
        });
        data['episodes'] = episodes;
        await txn.insert('season_metadata', {
          'work_id': workId,
          'season_number': season,
          'metadata_language': metadataLanguage,
          'metadata_json': jsonEncode(data),
          'metadata_fetched_at': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    _changed();
  }

  Future<List<Map<String, Object?>>> serverResources(
    String source, {
    String? itemId,
  }) => _db.rawQuery(
    '''SELECT s.*, r.relative_path,
    r.name, r.parent_path, r.work_id, r.season_number, r.episode_number FROM server_items s JOIN resources r ON r.id=s.resource_id
    WHERE s.source_id=? ${itemId == null ? '' : 'AND s.item_id=?'} AND r.availability='present' ORDER BY r.relative_path''',
    [source, ?itemId],
  );
  Future<Map<String, Object?>?> serverResource(
    String source,
    String path,
  ) async => (await _db.rawQuery(
    '''SELECT s.*
    FROM server_items s JOIN resources r ON r.id=s.resource_id WHERE s.source_id=? AND r.relative_path=?''',
    [source, path],
  )).firstOrNull;
  Future<void> saveServerCollection(
    MediaConnection config,
    Map<String, dynamic> item,
    List<int> members,
  ) async {
    final id = 'server:${config.id}:${_serverId(item['Id'])}';
    await _db.transaction((txn) async {
      await txn.rawInsert(
        '''INSERT INTO film_collections(id,name,poster_path) VALUES(?,?,?) ON CONFLICT(id)
        DO UPDATE SET name=excluded.name,poster_path=excluded.poster_path''',
        [id, item['Name'], _serverImage(config.id, item, 'Primary')],
      );
      await txn.delete(
        'collection_members',
        where: 'collection_id=?',
        whereArgs: [id],
      );
      for (final work in members.toSet()) {
        await txn.insert('collection_members', {
          'collection_id': id,
          'work_id': work,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
    _changed();
  }

  Future<void> queueServerState(
    String source,
    String item,
    Map<String, dynamic> state,
  ) async {
    await _db.transaction((txn) async {
      final previous = await txn.query(
        'server_sync_pending',
        where: 'source_id=? AND item_id=?',
        whereArgs: [source, item],
      );
      final merged = <String, dynamic>{
        if (previous.isNotEmpty)
          ...Map<String, dynamic>.from(
            jsonDecode(previous.single['state_json'] as String) as Map,
          ),
        ...state,
      };
      await txn.insert('server_sync_pending', {
        'source_id': source,
        'item_id': item,
        'state_json': jsonEncode(merged),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<List<Map<String, dynamic>>> pendingServerStates(String source) async =>
      (await _db.query(
            'server_sync_pending',
            where: 'source_id=?',
            whereArgs: [source],
          ))
          .map(
            (row) => <String, dynamic>{
              'itemId': row['item_id'],
              'state': jsonDecode(row['state_json'] as String),
            },
          )
          .toList();
  Future<void> acknowledgeServerState(
    String source,
    String item,
    Map<String, dynamic> state,
  ) async {
    await _db.delete(
      'server_sync_pending',
      where: 'source_id=? AND item_id=? AND state_json=?',
      whereArgs: [source, item, jsonEncode(state)],
    );
  }
}
