import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 旧版本迁移夹具使用 v6 的作品约束，且不包含第五阶段表。
Future<void> restoreVersion6Fixture(Database db) async {
  await db.execute('PRAGMA foreign_keys=OFF');
  for (final table in [
    'film_playlist_scopes',
    'film_playlist_items',
    'film_playlists',
    'collection_members',
    'work_people',
    'server_items',
    'server_sync_pending',
    'film_collections',
  ]) {
    await db.execute('DROP TABLE $table');
  }
  await db.execute(
    '''CREATE TABLE works_v6 (id INTEGER PRIMARY KEY AUTOINCREMENT,
    media_type TEXT NOT NULL CHECK(media_type IN ('movie','tv')), tmdb_id INTEGER NOT NULL CHECK(tmdb_id > 0),
    title TEXT NOT NULL, original_title TEXT NOT NULL, year INTEGER, overview TEXT NOT NULL,
    poster_path TEXT, backdrop_path TEXT, metadata_json TEXT NOT NULL,
    metadata_language TEXT NOT NULL, metadata_fetched_at INTEGER NOT NULL, UNIQUE(media_type,tmdb_id))''',
  );
  const fields =
      'id,media_type,tmdb_id,title,original_title,year,overview,poster_path,backdrop_path,metadata_json,metadata_language,metadata_fetched_at';
  await db.execute('INSERT INTO works_v6 ($fields) SELECT $fields FROM works');
  await db.execute('DROP TABLE works');
  await db.execute('ALTER TABLE works_v6 RENAME TO works');
  await db.execute('CREATE INDEX works_title ON works(title)');
  await db.execute('PRAGMA foreign_keys=ON');
}
