class FilmCollection {
  const FilmCollection({
    required this.id,
    required this.name,
    this.tmdbId,
    this.posterPath,
    this.customPath,
    this.coverWorkId,
    this.count = 0,
  });
  final String id, name;
  final int? tmdbId, coverWorkId;
  final String? posterPath, customPath;
  final int count;
  bool get automatic => tmdbId != null;
  bool get readOnly => automatic || id.startsWith('server:');
  factory FilmCollection.fromRow(Map<String, Object?> row) => FilmCollection(
    id: row['id'] as String,
    name: row['name'] as String,
    tmdbId: row['tmdb_id'] as int?,
    posterPath: row['poster_path'] as String?,
    customPath: row['custom_path'] as String?,
    coverWorkId: row['cover_work_id'] as int?,
    count: row['member_count'] as int? ?? 0,
  );
}
