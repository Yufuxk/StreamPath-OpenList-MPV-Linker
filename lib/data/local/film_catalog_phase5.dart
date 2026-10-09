part of 'film_catalog_store.dart';

const _phase5Schema = <String>[
  '''CREATE TABLE film_collections (id TEXT PRIMARY KEY, name TEXT NOT NULL,
    tmdb_id INTEGER UNIQUE, poster_path TEXT, custom_path TEXT,
    cover_work_id INTEGER REFERENCES works(id) ON DELETE SET NULL)''',
  '''CREATE TABLE collection_members (collection_id TEXT NOT NULL REFERENCES film_collections(id) ON DELETE CASCADE,
    work_id INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
    PRIMARY KEY(collection_id,work_id))''',
  '''CREATE TABLE work_people (work_id INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
    person_id TEXT NOT NULL, name TEXT NOT NULL, PRIMARY KEY(work_id,person_id))''',
  'CREATE INDEX work_people_person ON work_people(person_id,work_id)',
  '''CREATE TABLE server_items (source_id TEXT NOT NULL, item_id TEXT NOT NULL,
    resource_id INTEGER REFERENCES resources(id) ON DELETE CASCADE,
    media_source_id TEXT NOT NULL, user_data_json TEXT NOT NULL DEFAULT '{}',
    PRIMARY KEY(source_id,item_id,media_source_id))''',
  '''CREATE TABLE server_sync_pending (source_id TEXT NOT NULL, item_id TEXT NOT NULL,
    state_json TEXT NOT NULL, PRIMARY KEY(source_id,item_id))''',
];

Future<void> _upgradePhase5(Database db) async {
  for (final name in ['works', 'catalog_roots', 'resources']) {
    final schema = FilmCatalogStore._schema.firstWhere(
      (s) => s.startsWith('CREATE TABLE $name '),
    );
    await db.execute(
      schema.replaceFirst(
        'CREATE TABLE $name ',
        'CREATE TABLE ${name}_phase5 ',
      ),
    );
    if (name == 'works') {
      await db.execute(
        '''INSERT INTO works_phase5
        (id,media_type,tmdb_id,identity_key,metadata_origin,title,original_title,year,overview,poster_path,backdrop_path,
         metadata_json,metadata_language,metadata_fetched_at)
        SELECT id,media_type,tmdb_id,'tmdb:'||media_type||':'||tmdb_id,'network',title,original_title,year,overview,
          poster_path,backdrop_path,metadata_json,metadata_language,metadata_fetched_at FROM works''',
      );
    } else {
      await db.execute('INSERT INTO ${name}_phase5 SELECT * FROM $name');
    }
    await db.execute('DROP TABLE $name');
    await db.execute('ALTER TABLE ${name}_phase5 RENAME TO $name');
  }
  await db.execute('CREATE INDEX works_title ON works(title)');
  for (final schema in FilmCatalogStore._schema.where(
    (s) => s.startsWith('CREATE INDEX resources_'),
  )) {
    await db.execute(schema);
  }
  for (final statement in _phase5Schema) {
    await db.execute(statement);
  }
  final rows = await db.query('works');
  for (final row in rows) {
    final work = FilmWork.fromRow(row);
    await _indexPhase5Work(db, work.id, work);
  }
}

Future<void> _indexPhase5Work(
  DatabaseExecutor db,
  int id,
  FilmWork work,
) async {
  await db.delete('work_people', where: 'work_id=?', whereArgs: [id]);
  final credits = work.metadata['credits'] as Map?;
  final people = <String>{};
  for (final person in [
    ...?(credits?['cast'] as List?),
    ...?(credits?['crew'] as List?),
  ].whereType<Map>()) {
    final rawId = person['id'];
    if (rawId == null || person['name'] is! String) continue;
    final key = person['identity'] as String? ?? 'tmdb:$rawId';
    if (!people.add(key)) continue;
    await db.insert('work_people', {
      'work_id': id,
      'person_id': key,
      'name': person['name'],
    });
  }
  await db.rawDelete(
    'DELETE FROM collection_members WHERE work_id=? AND collection_id IN (SELECT id FROM film_collections WHERE tmdb_id IS NOT NULL)',
    [id],
  );
  final collection = work.metadata['belongs_to_collection'];
  if (work.type != FilmMediaType.movie ||
      collection is! Map ||
      collection['id'] is! int) {
    return;
  }
  final key = 'tmdb:${collection['id']}';
  await db.rawInsert(
    '''INSERT INTO film_collections(id,name,tmdb_id,poster_path)
    VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,poster_path=excluded.poster_path''',
    [
      key,
      collection['name'] as String? ?? work.title,
      collection['id'],
      collection['poster_path'],
    ],
  );
  await db.insert('collection_members', {
    'collection_id': key,
    'work_id': id,
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
}

Future<void> _mergeWork(DatabaseExecutor db, int oldId, int newId) async {
  await _mergePlaylistWork(db, oldId, newId);
  // 作品取得统一身份时保留资源 ID，并合并个人数据和季集关联。
  for (final table in [
    'work_favorites',
    'season_metadata',
    'film_disc_watch_state',
    'collection_members',
    'work_people',
  ]) {
    for (final row in await db.query(
      table,
      where: 'work_id=?',
      whereArgs: [oldId],
    )) {
      await db.insert(table, {
        ...row,
        'work_id': newId,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }
  for (final row in await db.query(
    'film_watch_state',
    where: 'work_id=?',
    whereArgs: [oldId],
  )) {
    await db.rawInsert(
      '''INSERT INTO film_watch_state
      (source_id,work_id,season_number,episode_number,watched,position_ms,duration_ms,observed_at,manual_at)
      VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(source_id,work_id,season_number,episode_number)
      DO UPDATE SET watched=excluded.watched,position_ms=excluded.position_ms,
        duration_ms=excluded.duration_ms,observed_at=excluded.observed_at,
        manual_at=MAX(film_watch_state.manual_at,excluded.manual_at)
      WHERE MAX(excluded.manual_at,excluded.observed_at)>MAX(film_watch_state.manual_at,film_watch_state.observed_at)''',
      [
        row['source_id'],
        newId,
        row['season_number'],
        row['episode_number'],
        row['watched'],
        row['position_ms'],
        row['duration_ms'],
        row['observed_at'],
        row['manual_at'],
      ],
    );
  }
  for (final table in ['resources', 'series_bindings', 'root_covers']) {
    await db.update(
      table,
      {'work_id': newId},
      where: 'work_id=?',
      whereArgs: [oldId],
    );
  }
  await db.update(
    'film_collections',
    {'cover_work_id': newId},
    where: 'cover_work_id=?',
    whereArgs: [oldId],
  );
  final daily = await db.query(
    'catalog_preferences',
    where: 'key=?',
    whereArgs: ['daily_selection'],
  );
  if (daily.isNotEmpty) {
    final value = jsonDecode(daily.single['value_json'] as String) as Map;
    final ids = (value['ids'] as List).cast<int>();
    if (ids.contains(oldId)) {
      value['ids'] = ids.map((id) => id == oldId ? newId : id).toSet().toList();
      await db.update(
        'catalog_preferences',
        {'value_json': jsonEncode(value)},
        where: 'key=?',
        whereArgs: ['daily_selection'],
      );
    }
  }
  await db.delete('works', where: 'id=?', whereArgs: [oldId]);
}

extension FilmCatalogPhase5 on FilmCatalogStore {
  Future<Object?> preference(String key) async {
    final rows = await _db.query(
      'catalog_preferences',
      where: 'key=?',
      whereArgs: [key],
    );
    return rows.isEmpty
        ? null
        : jsonDecode(rows.single['value_json'] as String);
  }

  Future<void> setPreference(String key, Object? value) async {
    await _db.insert('catalog_preferences', {
      'key': key,
      'value_json': jsonEncode(value),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    if (key == 'spoiler_protection') spoilerProtection = value == true;
    _changed();
  }

  Future<List<int>> dailySelection({DateTime? now}) => _db.transaction((
    txn,
  ) async {
    final date = (now ?? DateTime.now()).toIso8601String().substring(0, 10);
    final rows = await txn.query(
      'catalog_preferences',
      where: 'key=?',
      whereArgs: ['daily_selection'],
    );
    if (rows.isNotEmpty) {
      final value = jsonDecode(rows.single['value_json'] as String) as Map;
      if (value['date'] == date) return (value['ids'] as List).cast<int>();
    }
    final selected = await txn.rawQuery(
      '''SELECT DISTINCT r.work_id FROM resources r JOIN catalog_roots c ON c.id=r.root_id
      WHERE r.work_id IS NOT NULL AND r.availability='present' AND ${FilmCatalogStore._rootEnabledSql}
      ORDER BY RANDOM() LIMIT 10''',
    );
    final ids = selected.map((r) => r['work_id'] as int).toList();
    await txn.insert('catalog_preferences', {
      'key': 'daily_selection',
      'value_json': jsonEncode({'date': date, 'ids': ids}),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return ids;
  });
  Future<List<FilmCollection>> collections({
    bool customOnly = false,
    String? sourceId,
  }) async {
    final rows = await _db.rawQuery(
      '''SELECT c.*,COUNT(DISTINCT CASE WHEN r.id IS NOT NULL THEN m.work_id END) AS member_count
      FROM film_collections c LEFT JOIN collection_members m ON m.collection_id=c.id
      LEFT JOIN resources r ON r.work_id=m.work_id AND r.availability='present'
        AND r.root_id IN (SELECT c.id FROM catalog_roots c WHERE ${FilmCatalogStore._rootEnabledSql}
          ${sourceId == null ? '' : 'AND c.source_id=?'})
        AND (c.id NOT LIKE 'server:%' OR EXISTS (SELECT 1 FROM catalog_roots owner
          WHERE owner.id=r.root_id AND substr(c.id,1,length(owner.source_id)+8)='server:' || owner.source_id || ':'))
      ${customOnly ? "WHERE c.tmdb_id IS NULL AND c.id LIKE 'custom:%'" : ''}
      GROUP BY c.id HAVING (c.tmdb_id IS NULL OR COUNT(DISTINCT CASE WHEN r.id IS NOT NULL THEN m.work_id END)>=2)
        ${sourceId == null ? '' : 'AND COUNT(r.id)>0'}
        AND (c.id NOT LIKE 'server:%' OR COUNT(r.id)>0)
        AND (COUNT(r.id)>0 OR NOT EXISTS (SELECT 1 FROM collection_members m0 WHERE m0.collection_id=c.id))
      ORDER BY c.name COLLATE NOCASE,c.id''',
      [?sourceId],
    );
    final identities = <String, String>{
      for (final row in await _db.query(
        'catalog_preferences',
        where: "key LIKE 'server_identity:%'",
      ))
        (row['key'] as String).substring('server_identity:'.length):
            jsonDecode(row['value_json'] as String) as String,
    };
    final seen = <String>{};
    return rows.map(FilmCollection.fromRow).where((collection) {
      if (!collection.id.startsWith('server:')) return true;
      final separator = collection.id.lastIndexOf(':');
      final owner = collection.id.substring('server:'.length, separator);
      if (sourceId != null && owner != sourceId) return false;
      final server = identities[owner];
      final key = server == null
          ? collection.id
          : '$server:${collection.id.substring(separator + 1)}';
      return seen.add(key);
    }).toList();
  }

  Future<String> createCollection(String name, {String? id}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const FilmCatalogException('invalidCollectionName');
    }
    final key =
        id ??
        'custom:${DateTime.now().microsecondsSinceEpoch}:${Random.secure().nextInt(1 << 32)}';
    await _db.insert('film_collections', {
      'id': key,
      'name': trimmed,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    _changed();
    return key;
  }

  Future<void> addCollectionMember(String id, int workId) async {
    await _db.insert('collection_members', {
      'collection_id': id,
      'work_id': workId,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    _changed();
  }

  Future<void> removeCollectionMember(String id, int workId) async {
    await _db.delete(
      'collection_members',
      where: 'collection_id=? AND work_id=?',
      whereArgs: [id, workId],
    );
    _changed();
  }

  Future<void> updateCollection(
    String id, {
    String? name,
    String? customPath,
  }) async {
    if (name != null && name.trim().isEmpty) {
      throw const FilmCatalogException('invalidCollectionName');
    }
    await _db.update(
      'film_collections',
      {if (name != null) 'name': name.trim(), 'custom_path': ?customPath},
      where: 'id=?',
      whereArgs: [id],
    );
    _changed();
  }

  Future<void> setCollectionCover(String id, String? path) async {
    await _db.update(
      'film_collections',
      {'custom_path': path},
      where: 'id=?',
      whereArgs: [id],
    );
    _changed();
  }

  Future<void> removeCollection(String id) async {
    await _db.delete(
      'film_collections',
      where: 'id=? AND tmdb_id IS NULL',
      whereArgs: [id],
    );
    _changed();
  }

  Future<String?> collectionArtwork(FilmCollection collection) async {
    if (collection.customPath != null) return collection.customPath;
    if (collection.posterPath != null) return collection.posterPath;
    final rows = await _db.rawQuery(
      '''SELECT w.id,w.poster_path FROM works w JOIN collection_members m ON m.work_id=w.id
      WHERE m.collection_id=? AND w.poster_path IS NOT NULL AND EXISTS
      (SELECT 1 FROM resources r JOIN catalog_roots c ON c.id=r.root_id
        WHERE r.work_id=w.id AND r.availability='present' AND ${FilmCatalogStore._rootEnabledSql})
      ORDER BY CASE WHEN w.id=? THEN 0 ELSE 1 END,RANDOM() LIMIT 1''',
      [collection.id, collection.coverWorkId],
    );
    if (rows.isEmpty) return null;
    await _db.update(
      'film_collections',
      {'cover_work_id': rows.single['id']},
      where: 'id=?',
      whereArgs: [collection.id],
    );
    return rows.single['poster_path'] as String;
  }
}
