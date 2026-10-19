part of 'film_catalog_store.dart';

const _versionSchema = '''CREATE TABLE film_resource_versions (
 resource_id INTEGER PRIMARY KEY REFERENCES resources(id) ON DELETE CASCADE,
 family_key TEXT NOT NULL, family_name TEXT NOT NULL, origin TEXT NOT NULL)''';

extension FilmCatalogVersions on FilmCatalogStore {
  String _versionPreference(String identity, String? sourceScope) =>
      'film_versions:${jsonEncode([identity, sourceScope])}';

  Future<FilmVersionSelection?> versionSelection(
    String identity, {
    String? sourceScope,
  }) async {
    final value = await preference(_versionPreference(identity, sourceScope));
    return value == null
        ? null
        : FilmVersionSelection.fromJson((value as Map).cast<String, dynamic>());
  }

  Future<void> saveVersionSelection(
    String identity,
    FilmVersionSelection value, {
    String? sourceScope,
  }) async {
    await _db.insert('catalog_preferences', {
      'key': _versionPreference(identity, sourceScope),
      'value_json': jsonEncode(value.toJson()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    _notifyChange(watch: false);
  }

  Future<void> assignVersion(List<FilmResource> resources, String name) async {
    final label = name.trim();
    if (label.isEmpty) throw const FilmCatalogException('invalidMetadata');
    final identities = <(String, int?, int?, int?)>{};
    for (final r in resources) {
      if (!identities.add((r.sourceId, r.workId, r.season, r.episode))) {
        throw const FilmCatalogException('versionConflict');
      }
    }
    await _db.transaction((txn) async {
      for (final r in resources) {
        final work = await txn.query(
          'works',
          where: 'id=?',
          whereArgs: [r.workId],
        );
        final key = filmVersionKey(
          r.sourceId,
          '',
          'manual:${FilmWork.fromRow(work.single).identity}',
          label,
        );
        final conflicts = await txn.rawQuery(
          '''SELECT r.id FROM film_resource_versions v
          JOIN resources r ON r.id=v.resource_id WHERE v.family_key=? AND r.work_id=?
          AND r.season_number=? AND r.episode_number=? AND r.availability='present' AND r.id<>?''',
          [key, r.workId, r.season, r.episode, r.id],
        );
        if (conflicts.isNotEmpty) {
          throw const FilmCatalogException('versionConflict');
        }
        await txn.insert('film_resource_versions', {
          'resource_id': r.id,
          'family_key': key,
          'family_name': '${r.rootName} · $label',
          'origin': 'manual',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    _changed();
  }

  Future<void> saveServerVersion(
    int resourceId, {
    String? path,
    String? name,
  }) async {
    final existing = await _db.query(
      'film_resource_versions',
      where: 'resource_id=?',
      whereArgs: [resourceId],
    );
    if (existing.firstOrNull?['origin'] == 'manual') return;
    final r = (await resource(resourceId))!;
    // 远端 URL 可能带凭据，只把普通文件路径用于资源包识别。
    final filePath = path != null && !path.contains('://') ? path : null;
    final descriptor = automaticFilmVersion(
      r,
      sourcePath: filePath,
      sourceName: name,
    );
    await _db.insert('film_resource_versions', {
      'resource_id': resourceId,
      'family_key': descriptor.key,
      'family_name': descriptor.name,
      'origin': 'server',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
