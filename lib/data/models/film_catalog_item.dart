import 'dart:convert';

import 'media_library_item.dart';
import 'media_source.dart';
import 'video_playback_scope.dart';

enum FilmMediaType { movie, tv }

/// 可向界面公开的目录库错误，不携带 URL、凭据或底层响应。
class FilmCatalogException implements Exception {
  const FilmCatalogException(this.code);
  final String code;
  @override
  String toString() => 'FilmCatalogException($code)';
}

class FilmCatalogRoot {
  FilmCatalogRoot.fromRow(Map<String, Object?> row)
    : id = row['id'] as int,
      sourceId = row['source_id'] as String,
      sourceKind = MediaSourceKind.values.byName(row['source_kind'] as String),
      path = row['root_path'] as String,
      type = FilmMediaType.values.byName(row['media_type'] as String),
      displayName = row['display_name'] as String,
      generation = row['scan_generation'] as int,
      status = row['scan_status'] as String,
      lastSuccessAt = row['last_success_at'] as int?,
      lastError = row['last_error'] as String?;

  final int id;
  final String sourceId;
  final MediaSourceKind sourceKind;
  final String path;
  final FilmMediaType type;
  final String displayName;
  final int generation;
  final String status;
  final int? lastSuccessAt;
  final String? lastError;
}

class FilmWork {
  const FilmWork({
    this.id = 0,
    required this.type,
    required this.tmdbId,
    required this.title,
    required this.originalTitle,
    required this.overview,
    required this.language,
    this.year,
    this.posterPath,
    this.backdropPath,
    this.metadata = const {},
    this.fetchedAt = 0,
    this.resourceCount = 0,
    this.missingCount = 0,
  });

  factory FilmWork.fromRow(Map<String, Object?> row) => FilmWork(
    id: row['id'] as int,
    type: FilmMediaType.values.byName(row['media_type'] as String),
    tmdbId: row['tmdb_id'] as int,
    title: row['title'] as String,
    originalTitle: row['original_title'] as String,
    overview: row['overview'] as String,
    language: row['metadata_language'] as String,
    year: row['year'] as int?,
    posterPath: row['poster_path'] as String?,
    backdropPath: row['backdrop_path'] as String?,
    metadata: Map<String, dynamic>.from(
      jsonDecode(row['metadata_json'] as String),
    ),
    fetchedAt: row['metadata_fetched_at'] as int,
    resourceCount: row['resource_count'] as int? ?? 0,
    missingCount: row['missing_count'] as int? ?? 0,
  );

  final int id;
  final FilmMediaType type;
  final int tmdbId;
  final String title;
  final String originalTitle;
  final String overview;
  final String language;
  final int? year;
  final String? posterPath;
  final String? backdropPath;
  final Map<String, dynamic> metadata;
  final int fetchedAt;
  final int resourceCount;
  final int missingCount;

  Map<String, Object?> toRow() => {
    'media_type': type.name,
    'tmdb_id': tmdbId,
    'title': title,
    'original_title': originalTitle,
    'year': year,
    'overview': overview,
    'poster_path': posterPath,
    'backdrop_path': backdropPath,
    'metadata_json': jsonEncode(metadata),
    'metadata_language': language,
    'metadata_fetched_at': fetchedAt,
  };
}

class FilmResource {
  FilmResource.fromRow(Map<String, Object?> row)
    : id = row['id'] as int,
      rootId = row['root_id'] as int,
      sourceId = row['source_id'] as String,
      sourceKind = MediaSourceKind.values.byName(row['source_kind'] as String),
      type = FilmMediaType.values.byName(row['media_type'] as String),
      rootPath = row['root_path'] as String,
      rootName = row['display_name'] as String,
      path = row['relative_path'] as String,
      pathKey = row['path_key'] as String,
      parentPath = row['parent_path'] as String,
      name = row['name'] as String,
      mediaKind = row['media_kind'] as String,
      availability = row['availability'] as String,
      workId = row['work_id'] as int?,
      bindingOrigin = row['binding_origin'] as String,
      bindingVersion = row['binding_version'] as int,
      season = row['season_number'] as int?,
      episode = row['episode_number'] as int?,
      mappingOrigin = row['episode_mapping_origin'] as String;

  final int id, rootId, bindingVersion;
  final String sourceId, rootPath, rootName, path, pathKey, parentPath, name;
  final String mediaKind, availability, bindingOrigin, mappingOrigin;
  final MediaSourceKind sourceKind;
  final FilmMediaType type;
  final int? workId, season, episode;

  bool get isDisc => mediaKind == 'iso' || mediaKind == 'bdmv';
  bool get canMarkWatched =>
      workId != null &&
      (isDisc ||
          (mediaKind == 'video' || mediaKind == 'strm') &&
              (type == FilmMediaType.movie ||
                  season != null && episode != null));

  MediaLibraryItem get playbackItem => MediaLibraryItem(
    sourceId: sourceId,
    sourceKind: sourceKind,
    parentPath: parentPath,
    name: name,
    kind: switch (mediaKind) {
      'strm' => MediaLibraryKind.strm,
      'iso' || 'bdmv' => MediaLibraryKind.iso,
      _ => MediaLibraryKind.video,
    },
    discRootPath: mediaKind == 'bdmv' ? path : null,
    playbackMode: sourceKind == MediaSourceKind.local
        ? mediaKind == 'iso' || mediaKind == 'bdmv'
              ? PlaybackMode.legacyTitle
              : PlaybackMode.localFile
        : PlaybackMode.legacyTitle,
    playbackScope: VideoPlaybackScope.directory,
  );
}

class FilmScanEntry {
  const FilmScanEntry({
    required this.path,
    required this.parentPath,
    required this.name,
    required this.mediaKind,
  });
  final String path, parentPath, name, mediaKind;
}

/// 本次扫描的元数据结果，完整清单提交时核对人工关联版本。
class FilmScanMatch {
  const FilmScanMatch({
    required this.work,
    required this.origin,
    required this.bindingVersion,
    this.episode,
    this.seasonNumber,
    this.seasonMetadata,
  });
  final FilmWork work;
  final String origin;
  final int bindingVersion;
  final (int, int)? episode;
  final int? seasonNumber;
  final Map<String, dynamic>? seasonMetadata;
}

String filmPathKey(String path, MediaSourceKind kind) =>
    kind == MediaSourceKind.local ? path.toLowerCase() : path;

bool filmPathWithin(String child, String parent) =>
    parent.isEmpty || child == parent || child.startsWith('$parent/');

/// 目录库只接受来源根内的逻辑路径。
String validateFilmPath(String value) {
  if (value.startsWith('/') ||
      value.contains('\\') ||
      value.contains('\u0000') ||
      value.contains('://') ||
      (value.isNotEmpty &&
          value.split('/').any((s) => s.isEmpty || s == '.' || s == '..'))) {
    throw const FilmCatalogException('invalidPath');
  }
  return value;
}
