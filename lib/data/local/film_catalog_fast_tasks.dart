part of 'film_catalog_store.dart';

const _fastTaskSchema = <String>[
  '''CREATE TABLE fast_tasks (id INTEGER PRIMARY KEY CHECK(id=1),
    status TEXT NOT NULL, scrape_only INTEGER NOT NULL, incremental INTEGER NOT NULL,
    created_at INTEGER NOT NULL, elapsed_ms INTEGER NOT NULL DEFAULT 0,
    directories INTEGER NOT NULL DEFAULT 0, discovered_directories INTEGER NOT NULL DEFAULT 0,
    files INTEGER NOT NULL DEFAULT 0, processed INTEGER NOT NULL DEFAULT 0,
    total INTEGER NOT NULL DEFAULT 0, matched INTEGER NOT NULL DEFAULT 0,
    error TEXT, path TEXT NOT NULL DEFAULT '')''',
  '''CREATE TABLE fast_task_roots (root_id INTEGER PRIMARY KEY REFERENCES catalog_roots(id),
    task_id INTEGER NOT NULL REFERENCES fast_tasks(id) ON DELETE CASCADE,
    ordinal INTEGER NOT NULL, generation INTEGER NOT NULL, scope TEXT,
    scan_complete INTEGER NOT NULL, seeded INTEGER NOT NULL DEFAULT 0,
    after_id INTEGER NOT NULL DEFAULT 0, snapshot TEXT NOT NULL)''',
  '''CREATE TABLE fast_task_jobs (id INTEGER PRIMARY KEY AUTOINCREMENT,
    root_id INTEGER NOT NULL REFERENCES fast_task_roots(root_id) ON DELETE CASCADE,
    kind TEXT NOT NULL, path TEXT NOT NULL, path_key TEXT NOT NULL,
    parent TEXT NOT NULL DEFAULT '', name TEXT NOT NULL DEFAULT '',
    media_kind TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT 'pending',
    UNIQUE(root_id,kind,path_key))''',
  'CREATE INDEX fast_jobs_pending ON fast_task_jobs(kind,state,id)',
];

extension FilmCatalogFastTasks on FilmCatalogStore {
  Future<FilmFastTask?> fastTask() async {
    final rows = await _db.query('fast_tasks');
    return rows.isEmpty ? null : FilmFastTask.fromRow(rows.single);
  }

  Future<List<FilmFastRoot>> fastRoots() async => [
    for (final row in await _db.query('fast_task_roots', orderBy: 'ordinal'))
      FilmFastRoot.fromRow(row),
  ];

  Future<bool> fastOwnsRoot(int rootId) async => (await _db.query(
    'fast_task_roots',
    columns: ['root_id'],
    where: 'root_id=?',
    whereArgs: [rootId],
  )).isNotEmpty;

  Future<bool> fastDirectoryPending(int rootId) async => (await _db.query(
    'fast_task_jobs',
    columns: ['id'],
    limit: 1,
    where: "root_id=? AND kind='directory' AND state<>'done'",
    whereArgs: [rootId],
  )).isNotEmpty;

  Future<Set<String>> fastKnownPaths(int rootId, List<String> paths) async {
    final known = <String>{};
    for (var offset = 0; offset < paths.length; offset += 400) {
      final part = paths.sublist(offset, min(offset + 400, paths.length));
      final rows = await _db.query(
        'resources',
        columns: ['path_key'],
        where:
            "root_id=? AND availability='present' AND path_key IN (${List.filled(part.length, '?').join(',')})",
        whereArgs: [rootId, ...part],
      );
      known.addAll(rows.map((row) => row['path_key'] as String));
    }
    return known;
  }

  Future<void> createFastTask(
    List<FilmCatalogRoot> roots,
    List<Map<String, dynamic>> snapshots, {
    required bool scrapeOnly,
    required bool incremental,
    String? scope,
  }) async {
    await _db.transaction((txn) async {
      if ((await txn.query('fast_tasks')).isNotEmpty) {
        throw const FilmCatalogException('fastTaskPending');
      }
      await txn.insert('fast_tasks', {
        'id': 1,
        'status': 'paused',
        'scrape_only': scrapeOnly ? 1 : 0,
        'incremental': incremental ? 1 : 0,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'discovered_directories': scrapeOnly ? 0 : roots.length,
      });
      for (var i = 0; i < roots.length; i++) {
        final root = roots[i];
        var generation = root.generation;
        if (!scrapeOnly) {
          generation++;
          await txn.delete(
            'scan_entries',
            where: 'root_id=?',
            whereArgs: [root.id],
          );
          await txn.update(
            'catalog_roots',
            {
              'scan_generation': generation,
              'scan_status': 'running',
              'last_error': null,
            },
            where: 'id=?',
            whereArgs: [root.id],
          );
        }
        await txn.insert('fast_task_roots', {
          'root_id': root.id,
          'task_id': 1,
          'ordinal': i,
          'generation': generation,
          'scope': scope,
          'scan_complete': scrapeOnly ? 1 : 0,
          'seeded': scrapeOnly ? 0 : 1,
          'snapshot': jsonEncode(snapshots[i]),
        });
        if (!scrapeOnly) {
          await _fastInsert(txn, root, 'directory', scope ?? root.path);
        }
      }
    });
  }

  Future<bool> _fastInsert(
    DatabaseExecutor txn,
    FilmCatalogRoot root,
    String kind,
    String path, {
    FilmScanEntry? entry,
  }) async {
    await txn.insert('fast_task_jobs', {
      'root_id': root.id,
      'kind': kind,
      'path': path,
      'path_key': filmPathKey(path, root.sourceKind),
      if (entry != null) ...{
        'parent': entry.parentPath,
        'name': entry.name,
        'media_kind': entry.mediaKind,
      },
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    return (await txn.rawQuery('SELECT changes() AS n')).single['n'] == 1;
  }

  Future<List<FilmFastJob>> fastJobs(String kind, {int limit = 32, int? rootId}) async => [
    for (final row in await _db.rawQuery(
      '''SELECT j.* FROM fast_task_jobs j JOIN fast_task_roots r ON r.root_id=j.root_id
      WHERE j.kind=? AND j.state='pending' ${rootId == null ? '' : 'AND j.root_id=?'} ORDER BY r.ordinal,j.id LIMIT ?''',
      [kind, ?rootId, limit],
    ))
      FilmFastJob.fromRow(row),
  ];

  Future<void> claimFastJobs(List<FilmFastJob> jobs) async {
    await _db.transaction((txn) async {
      final batch = txn.batch();
      for (final job in jobs) {
        batch.update(
          'fast_task_jobs',
          {'state': 'running'},
          where: "id=? AND state='pending'",
          whereArgs: [job.id],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> stageFastDirectory(
    FilmCatalogRoot root,
    FilmFastRoot taskRoot,
    FilmFastJob job,
    List<FilmScanEntry> entries,
    List<String> children,
  ) async {
    await _db.transaction((txn) async {
      await _stage(txn, root, taskRoot.generation, entries);
      var added = 0;
      for (final child in children) {
        if (await _fastInsert(txn, root, 'directory', child)) added++;
      }
      var scraped = 0;
      for (final entry in entries) {
        if (await _fastInsert(txn, root, 'scrape', entry.path, entry: entry)) {
          scraped++;
        }
      }
      await txn.update(
        'fast_task_jobs',
        {'state': 'done'},
        where: 'id=?',
        whereArgs: [job.id],
      );
      await txn.rawUpdate(
        '''UPDATE fast_tasks SET directories=directories+1,
        discovered_directories=discovered_directories+?, files=files+?, total=total+?, path=? WHERE id=1''',
        [added, entries.length, scraped, job.path],
      );
    });
    if (entries.isNotEmpty) notifyListeners();
  }

  Future<void> seedFastScraping(
    FilmCatalogRoot root,
    List<(int, FilmScanEntry)> rows,
  ) async {
    await _db.transaction((txn) async {
      var added = 0;
      for (final row in rows) {
        if (await _fastInsert(
          txn,
          root,
          'scrape',
          row.$2.path,
          entry: row.$2,
        )) {
          added++;
        }
      }
      await txn.update(
        'fast_task_roots',
        {
          if (rows.isNotEmpty) 'after_id': rows.last.$1,
          if (rows.isEmpty) 'seeded': 1,
        },
        where: 'root_id=?',
        whereArgs: [root.id],
      );
      await txn.rawUpdate('UPDATE fast_tasks SET total=total+? WHERE id=1', [
        added,
      ]);
    });
  }

  Future<void> completeFastScraping(
    int rootId,
    List<FilmFastJob> jobs,
    Map<String, FilmScanMatch> matches,
  ) async {
    final result = await _db.transaction((txn) async {
      final result = await _applyMetadata(txn, rootId, matches);
      for (final job in jobs) {
        await txn.update(
          'fast_task_jobs',
          {'state': 'done'},
          where: 'id=?',
          whereArgs: [job.id],
        );
      }
      await txn.rawUpdate(
        'UPDATE fast_tasks SET processed=processed+?, matched=matched+? WHERE id=1',
        [jobs.length, matches.length],
      );
      return result;
    });
    if (result.$1) _notifyChange(watch: result.$2);
  }

  Future<void> commitFastScan(
    FilmFastRoot taskRoot,
    bool incremental,
    bool Function() cancelled,
  ) async {
    final current = await root(taskRoot.rootId);
    if (current == null) throw const FilmCatalogException('staleScan');
    // 清单已提交但任务标记尚未写入时，恢复只补记状态。
    if (current.status != 'completed' ||
        current.generation != taskRoot.generation) {
      await commitScan(
        taskRoot.rootId,
        taskRoot.generation,
        cancelled: cancelled,
        incremental: incremental,
        scopePath: taskRoot.scope,
      );
    }
    await _db.update(
      'fast_task_roots',
      {'scan_complete': 1},
      where: 'root_id=?',
      whereArgs: [taskRoot.rootId],
    );
  }

  Future<void> setFastStatus(
    String status, {
    String? error,
    int? elapsedMs,
  }) async {
    await _db.transaction((txn) async {
      await txn.update('fast_tasks', {
        'status': status,
        'error': error,
        'elapsed_ms': ?elapsedMs,
      }, where: 'id=1');
      if (status == 'paused') {
        await txn.update('fast_task_jobs', {
          'state': 'pending',
        }, where: "state='running'");
      }
    });
  }

  Future<void> discardFastTask() async {
    await _db.transaction((txn) async {
      for (final row in await txn.query('fast_task_roots')) {
        if (row['scan_complete'] == 0) {
          await txn.update(
            'catalog_roots',
            {'scan_status': 'cancelled', 'last_error': 'cancelled'},
            where: 'id=? AND scan_generation=?',
            whereArgs: [row['root_id'], row['generation']],
          );
          await txn.delete(
            'scan_entries',
            where: 'root_id=? AND generation=?',
            whereArgs: [row['root_id'], row['generation']],
          );
        }
      }
      await txn.delete('fast_tasks');
    });
    notifyListeners();
  }
}
