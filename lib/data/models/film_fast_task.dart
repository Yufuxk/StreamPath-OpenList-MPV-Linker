import 'dart:convert';

enum FilmTaskExecutionMode { standard, fullSpeed }

class FilmFastTask {
  const FilmFastTask({
    required this.id,
    required this.status,
    required this.scrapeOnly,
    required this.incremental,
    required this.createdAt,
    required this.elapsedMs,
    required this.directories,
    required this.discoveredDirectories,
    required this.files,
    required this.processed,
    required this.total,
    required this.matched,
    this.error,
    this.path = '',
  });
  factory FilmFastTask.fromRow(Map<String, Object?> row) => FilmFastTask(
    id: row['id'] as int,
    status: row['status'] as String,
    scrapeOnly: row['scrape_only'] == 1,
    incremental: row['incremental'] == 1,
    createdAt: row['created_at'] as int,
    elapsedMs: row['elapsed_ms'] as int,
    directories: row['directories'] as int,
    discoveredDirectories: row['discovered_directories'] as int,
    files: row['files'] as int,
    processed: row['processed'] as int,
    total: row['total'] as int,
    matched: row['matched'] as int,
    error: row['error'] as String?,
    path: row['path'] as String,
  );
  final int id, createdAt, elapsedMs;
  final int directories,
      discoveredDirectories,
      files,
      processed,
      total,
      matched;
  final String status, path;
  final String? error;
  final bool scrapeOnly, incremental;
  bool get active => status == 'running' || status == 'stopping';
}

class FilmFastRoot {
  FilmFastRoot.fromRow(Map<String, Object?> row)
    : rootId = row['root_id'] as int,
      ordinal = row['ordinal'] as int,
      generation = row['generation'] as int,
      scanComplete = row['scan_complete'] == 1,
      seeded = row['seeded'] == 1,
      afterId = row['after_id'] as int,
      scope = row['scope'] as String?,
      snapshot = jsonDecode(row['snapshot'] as String) as Map<String, dynamic>;
  final int rootId, ordinal, generation, afterId;
  final bool scanComplete, seeded;
  final String? scope;
  final Map<String, dynamic> snapshot;
}

class FilmFastJob {
  FilmFastJob.fromRow(Map<String, Object?> row)
    : id = row['id'] as int,
      rootId = row['root_id'] as int,
      kind = row['kind'] as String,
      path = row['path'] as String,
      parent = row['parent'] as String,
      name = row['name'] as String,
      mediaKind = row['media_kind'] as String;
  final int id, rootId;
  final String kind, path, parent, name, mediaKind;
}
