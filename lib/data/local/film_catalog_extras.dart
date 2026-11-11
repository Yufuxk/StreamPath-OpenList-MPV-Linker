part of 'film_catalog_store.dart';

const _extraWatchSchema = '''CREATE TABLE film_resource_watch_state (
  resource_id INTEGER NOT NULL REFERENCES resources(id) ON DELETE CASCADE,
  work_id INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
  watched INTEGER NOT NULL DEFAULT 0, position_ms INTEGER NOT NULL DEFAULT 0,
  duration_ms INTEGER, observed_at INTEGER NOT NULL DEFAULT 0,
  manual_at INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(resource_id,work_id))''';

Future<void> _upgradeExtras(DatabaseExecutor db) async {
  for (final field in [
    'extra_kind TEXT',
    "extra_origin TEXT NOT NULL DEFAULT 'unset' CHECK(extra_origin IN ('unset','filename','folder','manual'))",
    "extra_status TEXT NOT NULL DEFAULT 'unknown' CHECK(extra_status IN ('unknown','extra','non_extra'))",
    'extra_rule_version INTEGER NOT NULL DEFAULT 0',
    "extra_evidence_json TEXT NOT NULL DEFAULT '{}'",
  ]) {
    await db.execute('ALTER TABLE resources ADD COLUMN $field');
  }
  await db.execute(_extraWatchSchema);
}

extension FilmCatalogExtras on FilmCatalogStore {
  Future<bool> _confirmMovieMain(
    DatabaseExecutor txn,
    Map<String, Object?> row,
    FilmWork work,
  ) async {
    if (work.type != FilmMediaType.movie ||
        row['extra_origin'] == 'manual' ||
        row['extra_status'] == 'extra') {
      return false;
    }
    final name = row['name'] as String;
    final title =
        const VideoFilenameParser().parse(name, movie: true)?.title ??
        VideoFilenameParser.fallback(name).title;
    String key(String value) => FilmExtraClassifier.normalize(
      value,
    ).replaceAll(RegExp(r'[\s._\-:：!！《》「」『』]+'), '');
    if ([
      work.title,
      work.originalTitle,
    ].any((t) => key(t).isNotEmpty && key(t) == key(title))) {
      await txn.update(
        'resources',
        {'extra_status': 'non_extra'},
        where: "id=? AND extra_origin<>'manual'",
        whereArgs: [row['id']],
      );
      return true;
    }
    return false;
  }

  Future<void> _loadExtraRules() async {
    final value = await preference('extra_rules');
    extraRules = value == null
        ? const FilmExtraRules()
        : FilmExtraRules.fromJson((value as Map).cast<String, dynamic>());
    FilmExtraClassifier.validateRules(extraRules.types);
  }

  Future<void> saveExtraRules(List<FilmExtraType> types) async {
    FilmExtraClassifier.validateRules(types);
    final next = FilmExtraRules(
      revision: extraRules.revision + 1,
      types: types,
    );
    await _db.insert('catalog_preferences', {
      'key': 'extra_rules',
      'value_json': jsonEncode(next.toJson()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    extraRules = next;
    extraError = null;
    notifyListeners();
    startExtraBackfill();
  }

  Map<String, Object?> _extraValues(
    FilmExtraClassification result,
    int version,
  ) => {
    'extra_kind': result.kind,
    'extra_origin': result.origin,
    'extra_status': result.status,
    'extra_rule_version': version,
    'extra_evidence_json': jsonEncode(result.evidence),
  };

  /// 按当前读取批次补齐旧分类，不等待全库任务。
  Future<List<Map<String, Object?>>> _classifyExtraRows(
    List<Map<String, Object?>> rows, {
    DatabaseExecutor? executor,
  }) async {
    if (rows.every(
      (r) =>
          r['extra_origin'] == 'manual' ||
          r['extra_rule_version'] == extraRules.classificationVersion,
    )) {
      return rows;
    }
    Future<List<Map<String, Object?>>> classify(DatabaseExecutor txn) async {
      final classifier = FilmExtraClassifier(extraRules);
      final result = <Map<String, Object?>>[];
      final works = <int, FilmWork>{};
      for (final row in rows) {
        final latest = (await txn.query(
          'resources',
          where: 'id=?',
          whereArgs: [row['id']],
        )).firstOrNull;
        if (latest == null) continue;
        if (latest['extra_origin'] == 'manual' ||
            latest['extra_rule_version'] == extraRules.classificationVersion) {
          result.add({...row, ...latest});
          continue;
        }
        final server =
            row['source_kind'] == 'jellyfin' || row['source_kind'] == 'emby';
        final oldEvidence =
            jsonDecode(latest['extra_evidence_json'] as String) as Map;
        final sourceName = oldEvidence['source_name'] as String?;
        final classified = server
            ? sourceName == null
                  ? const FilmExtraClassification()
                  : classifier.classify(
                      name: sourceName,
                      path: sourceName,
                      rootPath: '',
                    )
            : classifier.classify(
                name: latest['name'] as String,
                path: latest['relative_path'] as String,
                rootPath: row['root_path'] as String,
                mediaKind: latest['media_kind'] as String,
              );
        final values = _extraValues(
          classified,
          extraRules.classificationVersion,
        );
        if (oldEvidence['directory'] != null) {
          values['extra_evidence_json'] = jsonEncode({
            ...classified.evidence,
            'directory': oldEvidence['directory'],
          });
        }
        if (sourceName != null) {
          values['extra_evidence_json'] = jsonEncode({
            ...classified.evidence,
            'source_name': sourceName,
          });
        }
        if (FilmExtraClassifier.excludedPath(latest['parent_path'] as String)) {
          values['availability'] = 'missing';
        }
        await txn.update(
          'resources',
          values,
          where: "id=? AND extra_origin<>'manual'",
          whereArgs: [row['id']],
        );
        final workId = latest['work_id'] as int?;
        if (workId != null && row['media_type'] == 'movie') {
          if (!works.containsKey(workId)) {
            works[workId] = FilmWork.fromRow(
              (await txn.query(
                'works',
                where: 'id=?',
                whereArgs: [workId],
              )).single,
            );
          }
          if (await _confirmMovieMain(txn, {
            ...latest,
            ...values,
          }, works[workId]!)) {
            values['extra_status'] = 'non_extra';
          }
        }
        result.add({...row, ...latest, ...values});
      }
      return result;
    }

    return executor == null || executor is Database
        ? _db.transaction(classify)
        : classify(executor);
  }

  void startExtraBackfill() {
    if (_closing || _extraTask != null) return;
    final requestedVersion = extraRules.classificationVersion;
    _extraTask = _backfillExtras()
        .onError<DatabaseException>((error, stack) {
          extraError = 'catalogStorageFailed';
          if (!_closing) notifyListeners();
        })
        .whenComplete(() {
          _extraTask = null;
          if (!_closing &&
              extraRules.classificationVersion != requestedVersion) {
            startExtraBackfill();
          }
        });
  }

  Future<void> _backfillExtras() async {
    while (!_closing) {
      final rows = await _db.rawQuery(
        "${FilmCatalogStore._resourceSelect} WHERE r.extra_origin<>'manual' AND r.extra_rule_version<>? ORDER BY r.id LIMIT 200",
        [extraRules.classificationVersion],
      );
      if (rows.isEmpty) return;
      await _classifyExtraRows(rows);
      if (!_closing) notifyListeners();
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> waitForExtraBackfill() async {
    while (_extraTask != null) {
      await _extraTask;
    }
  }

  Future<void> setExtraType(
    FilmResource resource,
    String? kind, {
    bool automatic = false,
  }) async {
    if (kind != null) extraRules.type(kind);
    await _db.transaction((txn) async {
      await _checkResource(txn, resource);
      await txn.update(
        'resources',
        automatic
            ? {
                'extra_kind': null,
                'extra_origin': 'unset',
                'extra_status': 'unknown',
                'extra_rule_version': 0,
                'extra_evidence_json': resource.extraEvidence,
              }
            : {
                'extra_kind': kind,
                'extra_origin': 'manual',
                'extra_status': kind == null ? 'non_extra' : 'extra',
                'extra_rule_version': extraRules.classificationVersion,
                'extra_evidence_json': resource.extraEvidence,
              },
        where: 'id=?',
        whereArgs: [resource.id],
      );
    });
    if (automatic) await this.resource(resource.id);
    notifyListeners();
  }

  Future<void> _recordExtraProgress(
    FilmResource resource,
    VideoProgressUpdate update,
  ) async {
    final watched =
        update.completed ||
        update.durationMs != null &&
            update.durationMs! > 0 &&
            update.positionMs / update.durationMs! >= .99;
    await _db.rawInsert(
      '''INSERT INTO film_resource_watch_state(resource_id,work_id,watched,position_ms,duration_ms,observed_at)
      VALUES(?,?,?,?,?,?) ON CONFLICT(resource_id,work_id) DO UPDATE SET
      watched=MAX(watched,excluded.watched),position_ms=excluded.position_ms,duration_ms=excluded.duration_ms,observed_at=excluded.observed_at
      WHERE excluded.observed_at>film_resource_watch_state.manual_at AND excluded.observed_at>=film_resource_watch_state.observed_at''',
      [
        resource.id,
        resource.workId,
        watched ? 1 : 0,
        update.positionMs,
        update.durationMs,
        update.recordedAt.millisecondsSinceEpoch,
      ],
    );
    _notifyWatchResources([resource]);
  }
}
