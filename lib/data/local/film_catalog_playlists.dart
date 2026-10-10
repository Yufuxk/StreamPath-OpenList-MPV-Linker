part of 'film_catalog_store.dart';

const _playlistSchema = [
  '''CREATE TABLE film_playlists (id TEXT PRIMARY KEY, name TEXT NOT NULL,
    source_id TEXT NOT NULL, source_kind TEXT NOT NULL, source_name TEXT NOT NULL,
    kind TEXT NOT NULL CHECK(kind IN ('custom','server')), server_identity TEXT,
    remote_id TEXT, created_at INTEGER NOT NULL, error TEXT)''',
  '''CREATE TABLE film_playlist_items (id TEXT PRIMARY KEY,
    playlist_id TEXT NOT NULL REFERENCES film_playlists(id) ON DELETE CASCADE,
    target_key TEXT NOT NULL, work_id INTEGER, season_number INTEGER, episode_number INTEGER,
    pinned_path TEXT, server_item_id TEXT, position INTEGER NOT NULL,
    excluded INTEGER NOT NULL DEFAULT 0, versions_json TEXT NOT NULL, display_json TEXT NOT NULL)''',
  '''CREATE TABLE film_playlist_scopes (playlist_id TEXT NOT NULL REFERENCES film_playlists(id) ON DELETE CASCADE,
    work_id INTEGER NOT NULL, season_number INTEGER NOT NULL, position INTEGER NOT NULL,
    PRIMARY KEY(playlist_id,work_id,season_number))''',
  'CREATE INDEX playlist_items_order ON film_playlist_items(playlist_id,position)',
];

String _playlistId() =>
    '${DateTime.now().microsecondsSinceEpoch}:${Random.secure().nextInt(1 << 32)}';
String _playlistTarget(FilmResource r) =>
    r.workId != null &&
        (r.type == FilmMediaType.movie || r.season != null && r.episode != null)
    ? 'work:${r.workId}:${r.season ?? -1}:${r.episode ?? -1}'
    : 'path:${r.pathKey}';

extension FilmCatalogPlaylists on FilmCatalogStore {
  Future<List<FilmPlaylist>> playlists({
    String? sourceId,
    bool editableOnly = false,
  }) async => (await _db.rawQuery(
    '''SELECT p.*,
      (SELECT COUNT(*) FROM film_playlist_items i WHERE i.playlist_id=p.id AND i.excluded=0) AS member_count,
      json_extract(cover.display_json,'\$.artwork') AS artwork,
      json_extract(cover.display_json,'\$.artworkTarget') AS artwork_target,
      json_extract(cover.display_json,'\$.episodeArtwork') AS artwork_sensitive,
      json_extract(cover.versions_json,'\$[0].path') AS artwork_path,
      cover.work_id AS artwork_work_id
      FROM film_playlists p LEFT JOIN film_playlist_items cover ON cover.id=(
        SELECT i.id FROM film_playlist_items i WHERE i.playlist_id=p.id AND i.excluded=0
        AND json_extract(i.display_json,'\$.artwork') IS NOT NULL
        AND json_extract(i.display_json,'\$.artwork')<>'' ORDER BY i.position LIMIT 1)
      WHERE 1=1 ${sourceId == null ? '' : 'AND p.source_id=?'}
      ${editableOnly ? "AND p.kind='custom'" : ''} ORDER BY p.created_at DESC,p.id''',
    [?sourceId],
  )).map(FilmPlaylist.fromRow).toList();

  Future<FilmPlaylist> playlist(String id) async {
    final rows = await _db.query(
      'film_playlists',
      where: 'id=?',
      whereArgs: [id],
    );
    if (rows.isEmpty) throw const FilmCatalogException('playlistMissing');
    return FilmPlaylist.fromRow(rows.single);
  }

  Future<void> _editablePlaylist(DatabaseExecutor db, String id) async {
    final rows = await db.query(
      'film_playlists',
      where: 'id=?',
      whereArgs: [id],
    );
    if (rows.isEmpty) throw const FilmCatalogException('playlistMissing');
    if (rows.single['kind'] != 'custom') {
      throw const FilmCatalogException('sourceReadOnly');
    }
  }

  Future<String?> _playlistServerIdentity(
    DatabaseExecutor db,
    String source,
  ) async {
    final row = await db.query(
      'catalog_preferences',
      where: 'key=?',
      whereArgs: ['server_identity:$source'],
    );
    return row.isEmpty
        ? null
        : jsonDecode(row.single['value_json'] as String) as String;
  }

  Future<List<FilmResource>> _playlistResources(
    DatabaseExecutor db,
    String source, {
    int? workId,
  }) async => (await db.rawQuery(
    '''${FilmCatalogStore._resourceSelect} WHERE c.source_id=? AND ${FilmCatalogStore._rootEnabledSql}
      ${workId == null ? '' : 'AND r.work_id=?'}
      AND r.availability='present' AND r.media_kind IN ('video','strm')
      ORDER BY r.relative_path,r.id''',
    [source, ?workId],
  )).map(FilmResource.fromRow).toList();

  Future<List<List<FilmResource>>> _playlistGroups(
    DatabaseExecutor db,
    String source,
    FilmPlaylistScope scope,
  ) async {
    if (scope.resource case final resource?) {
      final rows = await _playlistResources(
        db,
        source,
        workId: resource.workId,
      );
      final current = rows
          .where((r) => r.pathKey == resource.pathKey)
          .firstOrNull;
      return current == null
          ? []
          : [
              [current],
            ];
    }
    final resources = await _playlistResources(
      db,
      source,
      workId: scope.workId,
    );
    final filtered = resources
        .where((r) => scope.season == null || r.season == scope.season)
        .toList();
    if (filtered.isEmpty) return [];
    if (filtered.first.type == FilmMediaType.movie) return [filtered];
    final seasons = <int, Map<String, dynamic>>{};
    for (final row in await db.query(
      'season_metadata',
      where: 'work_id=?',
      whereArgs: [scope.workId],
    )) {
      seasons[row['season_number'] as int] =
          jsonDecode(row['metadata_json'] as String) as Map<String, dynamic>;
    }
    final byPath = {for (final r in filtered) r.path: r};
    return [
      for (final item in buildFilmVideoOrder(filtered, seasons))
        [for (final v in item.versions) byPath[v.path]!],
    ];
  }

  Future<Map<String, dynamic>> _playlistDisplay(
    DatabaseExecutor db,
    FilmResource r,
  ) async {
    final rows = r.workId == null
        ? <Map<String, Object?>>[]
        : await db.query('works', where: 'id=?', whereArgs: [r.workId]);
    if (rows.isEmpty) return {'title': r.name};
    final work = FilmWork.fromRow(rows.single);
    Map? episode;
    if (r.season != null) {
      final seasons = await db.query(
        'season_metadata',
        where: 'work_id=? AND season_number=?',
        whereArgs: [r.workId, r.season],
      );
      if (seasons.isNotEmpty) {
        episode =
            ((jsonDecode(seasons.single['metadata_json'] as String)
                            as Map)['episodes']
                        as List? ??
                    [])
                .whereType<Map>()
                .where((e) => e['episode_number'] == r.episode)
                .firstOrNull;
      }
    }
    return {
      'title': work.title,
      'episodeTitle': episode?['name'],
      'year': work.year,
      'artwork': episode?['still_path'] ?? work.backdropPath ?? work.posterPath,
      'artworkTarget': episode?['still_path'] != null
          ? 'w300'
          : work.backdropPath != null
          ? 'w780'
          : 'w342',
      'episodeArtwork': episode?['still_path'] != null,
    };
  }

  Future<int> playlistScopeCount(
    String source,
    FilmPlaylistScope scope,
  ) async => scope.playlist == null
      ? (await _playlistGroups(_db, source, scope)).length
      : (await _playlistSelection(_db, source, scope)).length;

  Future<List<Map<String, Object?>>> _playlistSelection(
    DatabaseExecutor db,
    String source,
    FilmPlaylistScope scope,
  ) async {
    final lists = await db.query(
      'film_playlists',
      where: 'id=?',
      whereArgs: [scope.playlist!.id],
    );
    if (lists.isEmpty) throw const FilmCatalogException('playlistMissing');
    if (lists.single['source_id'] != source) {
      throw const FilmCatalogException('sourceUnavailable');
    }
    return db.query(
      'film_playlist_items',
      where:
          'playlist_id=? AND excluded=0${scope.entryId == null ? '' : ' AND id=?'}',
      whereArgs: [scope.playlist!.id, ?scope.entryId],
      orderBy: 'position,id',
    );
  }

  Future<String> createPlaylist(
    String name,
    String source,
    MediaSourceKind kind,
    String sourceName,
    FilmPlaylistScope scope,
  ) async {
    if (name.trim().isEmpty) {
      throw const FilmCatalogException('invalidPlaylistName');
    }
    if (scope.playlist case final list?) {
      if (list.sourceId != source) {
        throw const FilmCatalogException('sourceUnavailable');
      }
      return copyPlaylist(list.id, name, entryId: scope.entryId);
    }
    final id = 'custom:${_playlistId()}';
    await _db.transaction((txn) async {
      if ((await _playlistGroups(txn, source, scope)).isEmpty) {
        throw const FilmCatalogException('playlistEmpty');
      }
      await txn.insert('film_playlists', {
        'id': id,
        'name': name.trim(),
        'source_id': source,
        'source_kind': kind.name,
        'source_name': sourceName,
        'kind': 'custom',
        'server_identity': await _playlistServerIdentity(txn, source),
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
      await _addPlaylistScope(txn, id, source, scope);
    });
    _changed();
    return id;
  }

  Future<void> addPlaylistScope(
    String id,
    String source,
    FilmPlaylistScope scope,
  ) async {
    await _db.transaction((txn) async {
      await _editablePlaylist(txn, id);
      final row = (await txn.query(
        'film_playlists',
        where: 'id=?',
        whereArgs: [id],
      )).single;
      if (row['source_id'] != source ||
          row['server_identity'] !=
              await _playlistServerIdentity(txn, source)) {
        throw const FilmCatalogException('sourceUnavailable');
      }
      await _addPlaylistScope(txn, id, source, scope);
    });
    _changed();
  }

  Future<void> _addPlaylistScope(
    DatabaseExecutor db,
    String id,
    String source,
    FilmPlaylistScope scope,
  ) async {
    if (scope.playlist case final list?) {
      final rows = await _playlistSelection(db, source, scope);
      if (list.serverIdentity != await _playlistServerIdentity(db, source)) {
        throw const FilmCatalogException('sourceUnavailable');
      }
      for (final row in rows) {
        final logical =
            row['work_id'] != null &&
            (row['season_number'] != null && row['episode_number'] != null ||
                (await db.query(
                      'works',
                      columns: ['media_type'],
                      where: 'id=?',
                      whereArgs: [row['work_id']],
                    )).firstOrNull?['media_type'] ==
                    'movie');
        final existing = await db.rawQuery(
          '''SELECT * FROM film_playlist_items WHERE playlist_id=? AND
          (target_key=? ${logical
              ? 'OR (work_id=? AND COALESCE(season_number,-1)=? AND COALESCE(episode_number,-1)=?)'
              : row['server_item_id'] != null
              ? 'OR server_item_id=?'
              : 'OR pinned_path=?'})
          ORDER BY excluded,position,id''',
          [
            id,
            row['target_key'],
            if (logical) ...[
              row['work_id'],
              row['season_number'] ?? -1,
              row['episode_number'] ?? -1,
            ] else
              row['server_item_id'] ?? row['pinned_path'],
          ],
        );
        if (existing.any((e) => e['excluded'] == 0)) continue;
        final position = (await db.rawQuery(
          'SELECT COALESCE(MAX(position),-1)+1 AS value FROM film_playlist_items WHERE playlist_id=?',
          [id],
        )).single['value'];
        final values = {
          ...row,
          'id': existing.firstOrNull?['id'] ?? _playlistId(),
          'playlist_id': id,
          'position': position,
          'excluded': 0,
        };
        if (existing.isEmpty) {
          await db.insert('film_playlist_items', values);
        } else {
          await db.update(
            'film_playlist_items',
            values,
            where: 'id=?',
            whereArgs: [existing.first['id']],
          );
        }
      }
      return;
    }
    if (scope.follows) {
      final scopes = await db.query(
        'film_playlist_scopes',
        where: 'playlist_id=?',
        whereArgs: [id],
      );
      await db.insert('film_playlist_scopes', {
        'playlist_id': id,
        'work_id': scope.workId,
        'season_number': scope.season ?? -1,
        'position': scopes.length,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    for (final group in await _playlistGroups(db, source, scope)) {
      await _appendPlaylistGroup(
        db,
        id,
        group,
        pinned: !scope.follows,
        restoreExcluded: !scope.follows,
      );
    }
  }

  Future<bool> _appendPlaylistGroup(
    DatabaseExecutor db,
    String id,
    List<FilmResource> group, {
    bool pinned = false,
    bool restoreExcluded = false,
  }) async {
    final r = group.first;
    final key = _playlistTarget(r);
    final logical = key.startsWith('work:');
    final existing = await db.rawQuery(
      '''SELECT * FROM film_playlist_items WHERE playlist_id=? AND
      (target_key=? ${logical ? 'OR (work_id=? AND COALESCE(season_number,-1)=? AND COALESCE(episode_number,-1)=?)' : ''})
      ORDER BY excluded,position,id''',
      [
        id,
        key,
        if (logical) ...[r.workId!, r.season ?? -1, r.episode ?? -1],
      ],
    );
    if (existing.isNotEmpty &&
        !(restoreExcluded && existing.every((e) => e['excluded'] == 1))) {
      return false;
    }
    final position = (await db.rawQuery(
      'SELECT COALESCE(MAX(position),-1)+1 AS value FROM film_playlist_items WHERE playlist_id=?',
      [id],
    )).single['value'];
    final values = {
      'work_id': r.workId,
      'season_number': r.season,
      'episode_number': r.episode,
      'pinned_path': pinned ? r.path : null,
      'position': position,
      'excluded': 0,
      'versions_json': jsonEncode([
        for (final r in group) {'path': r.path, 'name': r.name},
      ]),
      'display_json': jsonEncode(await _playlistDisplay(db, r)),
    };
    if (existing.isNotEmpty) {
      await db.update(
        'film_playlist_items',
        values,
        where: 'id=?',
        whereArgs: [existing.first['id']],
      );
    } else {
      await db.insert('film_playlist_items', {
        'id': _playlistId(),
        'playlist_id': id,
        'target_key': key,
        ...values,
      });
    }
    return true;
  }

  /// 只补齐新增成员，用户排除及已有顺序具有优先权。
  Future<void> reconcilePlaylists({String? sourceId}) async {
    var changed = false;
    await _db.transaction((txn) async {
      final lists = await txn.query(
        'film_playlists',
        where: "kind='custom'${sourceId == null ? '' : ' AND source_id=?'}",
        whereArgs: [?sourceId],
      );
      for (final list in lists) {
        final source = list['source_id'] as String;
        if (list['server_identity'] !=
            await _playlistServerIdentity(txn, source)) {
          continue;
        }
        // 固定资源后来取得季集身份时仍保留版本和位置。
        final pinned = await txn.query(
          'film_playlist_items',
          where: 'playlist_id=? AND pinned_path IS NOT NULL',
          whereArgs: [list['id']],
        );
        if (pinned.isNotEmpty) {
          final resources = {
            for (final r in await _playlistResources(txn, source)) r.path: r,
          };
          for (final item in pinned) {
            final r = resources[item['pinned_path']];
            if (r != null && item['target_key'] != _playlistTarget(r)) {
              await txn.update(
                'film_playlist_items',
                {
                  'target_key': _playlistTarget(r),
                  'work_id': r.workId,
                  'season_number': r.season,
                  'episode_number': r.episode,
                },
                where: 'id=?',
                whereArgs: [item['id']],
              );
              changed = true;
            }
          }
          changed =
              await _deduplicatePlaylist(txn, list['id'] as String) || changed;
        }
        for (final scope in await txn.query(
          'film_playlist_scopes',
          where: 'playlist_id=?',
          whereArgs: [list['id']],
          orderBy: 'position',
        )) {
          for (final group in await _playlistGroups(
            txn,
            source,
            FilmPlaylistScope.work(
              scope['work_id'] as int,
              season: scope['season_number'] == -1
                  ? null
                  : scope['season_number'] as int,
            ),
          )) {
            changed =
                await _appendPlaylistGroup(txn, list['id'] as String, group) ||
                changed;
          }
        }
      }
    });
    if (changed) _changed();
  }

  Future<FilmPlaylistSnapshot> playlistSnapshot(String id) async {
    final list = await playlist(id);
    if (!list.readOnly) await reconcilePlaylists(sourceId: list.sourceId);
    return _db.transaction((txn) async {
      final rows = await txn.query(
        'film_playlist_items',
        where: 'playlist_id=? AND excluded=0',
        whereArgs: [id],
        orderBy: 'position,id',
      );
      final entries = rows.map(FilmPlaylistEntry.fromRow).toList();
      final header = (await txn.query(
        'film_playlists',
        where: 'id=?',
        whereArgs: [id],
      )).single;
      final identityMatches =
          header['error'] == null &&
          list.serverIdentity ==
              await _playlistServerIdentity(txn, list.sourceId);
      final byWork = <int?, List<FilmResource>>{};
      for (var i = 0; i < entries.length; i++) {
        final entry = entries[i];
        if (!identityMatches) continue;
        final resources = byWork[entry.workId] ??= await _playlistResources(
          txn,
          list.sourceId,
          workId: entry.workId,
        );
        var group = resources
            .where(
              (r) => entry.pinnedPath != null
                  ? r.path == entry.pinnedPath
                  : entry.workId != null &&
                        r.workId == entry.workId &&
                        r.season == entry.season &&
                        r.episode == entry.episode,
            )
            .toList();
        if (entry.serverItemId != null) {
          final mappings = await txn.query(
            'server_items',
            where: 'source_id=? AND item_id=?',
            whereArgs: [list.sourceId, entry.serverItemId],
          );
          final ids = mappings.map((r) => r['resource_id']).toSet();
          group = resources.where((r) => ids.contains(r.id)).toList();
        }
        if (group.isNotEmpty) {
          entry.available = true;
          entry.resource = group.first;
          entry.workId = group.first.workId;
          entry.season = group.first.season;
          entry.episode = group.first.episode;
          entry.currentVersions = [
            for (final r in group)
              VideoQueueVersion(path: r.path, name: r.name, rootId: r.rootId),
          ];
          entry.display.addAll(await _playlistDisplay(txn, group.first));
          final versions = jsonEncode([
            for (final v in entry.currentVersions!)
              {'path': v.path, 'name': v.name},
          ]);
          final display = jsonEncode(entry.display);
          final saved = rows[i];
          if (saved['versions_json'] != versions ||
              saved['display_json'] != display ||
              saved['work_id'] != entry.workId ||
              saved['season_number'] != entry.season ||
              saved['episode_number'] != entry.episode) {
            await txn.update(
              'film_playlist_items',
              {
                'versions_json': versions,
                'display_json': display,
                'work_id': entry.workId,
                'season_number': entry.season,
                'episode_number': entry.episode,
              },
              where: 'id=?',
              whereArgs: [entry.id],
            );
          }
        }
      }
      return FilmPlaylistSnapshot(list, entries);
    });
  }

  Future<void> reorderPlaylist(String id, List<String> entryIds) async {
    if (entryIds.toSet().length != entryIds.length) {
      throw StateError('Duplicate playlist entry IDs');
    }
    await _db.transaction((txn) async {
      await _editablePlaylist(txn, id);
      final rows = await txn.query(
        'film_playlist_items',
        where: 'playlist_id=? AND excluded=0',
        whereArgs: [id],
        orderBy: 'position,id',
      );
      final current = rows.map((r) => r['id'] as String).toSet();
      final ordered = [
        ...entryIds.where(current.contains),
        ...rows
            .map((r) => r['id'] as String)
            .where((key) => !entryIds.contains(key)),
      ];
      for (var i = 0; i < ordered.length; i++) {
        await txn.update(
          'film_playlist_items',
          {'position': i},
          where: 'id=? AND playlist_id=?',
          whereArgs: [ordered[i], id],
        );
      }
    });
    _changed();
  }

  Future<void> removePlaylistEntry(String id, String entryId) async {
    await _db.transaction((txn) async {
      await _editablePlaylist(txn, id);
      await txn.update(
        'film_playlist_items',
        {'excluded': 1},
        where: 'playlist_id=? AND id=?',
        whereArgs: [id, entryId],
      );
    });
    _changed();
  }

  Future<void> renamePlaylist(String id, String name) async {
    if (name.trim().isEmpty) {
      throw const FilmCatalogException('invalidPlaylistName');
    }
    await _db.transaction((txn) async {
      await _editablePlaylist(txn, id);
      await txn.update(
        'film_playlists',
        {'name': name.trim()},
        where: 'id=?',
        whereArgs: [id],
      );
    });
    _changed();
  }

  Future<void> deletePlaylist(String id) async {
    await _db.transaction((txn) async {
      await _editablePlaylist(txn, id);
      await txn.delete('film_playlists', where: 'id=?', whereArgs: [id]);
    });
    _changed();
  }

  Future<String> copyPlaylist(String id, String name, {String? entryId}) async {
    if (name.trim().isEmpty) {
      throw const FilmCatalogException('invalidPlaylistName');
    }
    final copy = 'custom:${_playlistId()}';
    await _db.transaction((txn) async {
      final lists = await txn.query(
        'film_playlists',
        where: 'id=?',
        whereArgs: [id],
      );
      if (lists.isEmpty) throw const FilmCatalogException('playlistMissing');
      final list = lists.single;
      final rows = await txn.query(
        'film_playlist_items',
        where:
            'playlist_id=? AND excluded=0${entryId == null ? '' : ' AND id=?'}',
        whereArgs: [id, ?entryId],
        orderBy: 'position,id',
      );
      if (entryId != null && rows.isEmpty) {
        throw const FilmCatalogException('playlistEmpty');
      }
      await txn.insert('film_playlists', {
        ...list,
        'id': copy,
        'kind': 'custom',
        'name': name.trim(),
        'remote_id': null,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'error': null,
      });
      for (final row in rows) {
        await txn.insert('film_playlist_items', {
          ...row,
          'id': _playlistId(),
          'playlist_id': copy,
        });
      }
    });
    _changed();
    return copy;
  }

  Future<void> saveServerPlaylist(
    MediaConnection config,
    String identity,
    Map<String, dynamic> list,
    List<Map<String, dynamic>> items,
  ) async {
    final remoteId = _serverId(list['Id']);
    final id = 'server:$identity:${config.id}:$remoteId';
    await _db.transaction((txn) async {
      final existing = await txn.query(
        'film_playlists',
        where: 'id=?',
        whereArgs: [id],
      );
      await txn.insert('film_playlists', {
        'id': id,
        'name': list['Name'],
        'source_id': config.id,
        'source_kind': config.kind.name,
        'source_name': config.name,
        'kind': 'server',
        'server_identity': identity,
        'remote_id': remoteId,
        'created_at':
            existing.firstOrNull?['created_at'] ??
            DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      final occurrences = <String, int>{};
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        final itemId = _serverId(item['Id']);
        final occurrence = occurrences.update(
          itemId,
          (v) => v + 1,
          ifAbsent: () => 0,
        );
        final resources = (await txn.rawQuery(
          '''${FilmCatalogStore._resourceSelect} JOIN server_items s ON s.resource_id=r.id
          WHERE s.source_id=? AND s.item_id=? ORDER BY r.relative_path''',
          [config.id, itemId],
        )).map(FilmResource.fromRow).toList();
        final r = resources.firstOrNull;
        await txn.insert('film_playlist_items', {
          'id': '$id:$itemId:$occurrence',
          'playlist_id': id,
          'target_key': 'server:$itemId:$occurrence',
          'server_item_id': itemId,
          'work_id': r?.workId,
          'season_number':
              r?.season ??
              (item['Type'] == 'Episode'
                  ? (item['ParentIndexNumber'] as num?)?.toInt()
                  : null),
          'episode_number':
              r?.episode ??
              (item['Type'] == 'Episode'
                  ? (item['IndexNumber'] as num?)?.toInt()
                  : null),
          'position': i,
          'versions_json': jsonEncode(
            resources.isEmpty
                ? [
                    {'path': 'missing/$itemId', 'name': item['Name'] ?? itemId},
                  ]
                : [
                    for (final r in resources) {'path': r.path, 'name': r.name},
                  ],
          ),
          'display_json': jsonEncode(
            r == null
                ? {
                    'title': item['SeriesName'] ?? item['Name'] ?? itemId,
                    'episodeTitle': item['Type'] == 'Episode'
                        ? item['Name']
                        : null,
                    'year': (item['ProductionYear'] as num?)?.toInt(),
                    'artwork': _serverImage(config.id, item, 'Primary'),
                    'episodeArtwork': item['Type'] == 'Episode',
                  }
                : await _playlistDisplay(txn, r),
          ),
        });
      }
    });
    _changed();
  }

  Future<void> finishServerPlaylists(
    String source,
    Set<String> remoteIds,
  ) async {
    final identity = await _playlistServerIdentity(_db, source);
    for (final row in await _db.query(
      'film_playlists',
      where: "source_id=? AND kind='server'",
      whereArgs: [source],
    )) {
      if (row['server_identity'] != identity ||
          !remoteIds.contains(row['remote_id'])) {
        await _db.delete(
          'film_playlists',
          where: 'id=?',
          whereArgs: [row['id']],
        );
      }
    }
    _changed();
  }

  Future<void> markServerPlaylistUnavailable(
    String source,
    String remoteId,
  ) async {
    await _db.update(
      'film_playlists',
      {'error': 'serverPlaylistUnavailable'},
      where: "source_id=? AND remote_id=? AND kind='server'",
      whereArgs: [source, remoteId],
    );
    _changed();
  }
}

Future<bool> _deduplicatePlaylist(DatabaseExecutor db, String id) async {
  final seen = <String>{};
  var changed = false;
  for (final row in await db.query(
    'film_playlist_items',
    where: 'playlist_id=?',
    whereArgs: [id],
    orderBy: 'excluded,position,id',
  )) {
    if (!seen.add(row['target_key'] as String)) {
      await db.delete(
        'film_playlist_items',
        where: 'id=?',
        whereArgs: [row['id']],
      );
      changed = true;
    }
  }
  return changed;
}

Future<void> _mergePlaylistWork(
  DatabaseExecutor db,
  int oldId,
  int newId,
) async {
  for (final scope in await db.query(
    'film_playlist_scopes',
    where: 'work_id=?',
    whereArgs: [oldId],
  )) {
    await db.insert('film_playlist_scopes', {
      ...scope,
      'work_id': newId,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }
  await db.delete(
    'film_playlist_scopes',
    where: 'work_id=?',
    whereArgs: [oldId],
  );
  final lists = <String>{};
  for (final row in await db.query(
    'film_playlist_items',
    where: 'work_id=?',
    whereArgs: [oldId],
  )) {
    lists.add(row['playlist_id'] as String);
    final key = row['target_key'] as String;
    await db.update(
      'film_playlist_items',
      {
        'work_id': newId,
        'target_key': key.startsWith('work:$oldId:')
            ? key.replaceFirst('work:$oldId:', 'work:$newId:')
            : key,
      },
      where: 'id=?',
      whereArgs: [row['id']],
    );
  }
  for (final id in lists) {
    await _deduplicatePlaylist(db, id);
  }
}
