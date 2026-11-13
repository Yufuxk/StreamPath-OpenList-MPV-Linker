import 'dart:convert';

import 'film_catalog_item.dart';

enum FilmMetadataLevel { work, season, episode, resource }

class FilmMetadataTarget {
  const FilmMetadataTarget.work(this.workId)
    : level = FilmMetadataLevel.work,
      season = null,
      episode = null,
      resourceId = null;
  const FilmMetadataTarget.season(this.workId, this.season)
    : level = FilmMetadataLevel.season,
      episode = null,
      resourceId = null;
  const FilmMetadataTarget.episode(this.workId, this.season, this.episode)
    : level = FilmMetadataLevel.episode,
      resourceId = null;
  const FilmMetadataTarget.resource(this.resourceId)
    : level = FilmMetadataLevel.resource,
      workId = null,
      season = null,
      episode = null;
  final FilmMetadataLevel level;
  final int? workId, season, episode, resourceId;
}

class FilmMetadataSnapshot {
  const FilmMetadataSnapshot({
    required this.target,
    required this.source,
    required this.overrides,
    required this.values,
    this.resource,
    this.work,
  });
  final FilmMetadataTarget target;
  final Map<String, dynamic> source, overrides, values;
  final FilmResource? resource;
  final FilmWork? work;
}

const filmMetadataRowFields = {
  'title',
  'original_title',
  'overview',
  'year',
  'poster_path',
  'backdrop_path',
};
const filmMetadataFields = {
  ...filmMetadataRowFields,
  'sort_title',
  'tagline',
  'release_date',
  'original_language',
  'genres',
  'origin_country',
  'certification',
  'certification_country',
  'vote_average',
  'tags',
  'production_companies',
  'credits',
  'runtime',
  'logo_path',
  'image_sources',
};

Map<String, dynamic> filmWorkMetadata(FilmWork work) => {
  ...work.metadata,
  'title': work.title,
  'original_title': work.originalTitle,
  'overview': work.overview,
  'year': work.year,
  'poster_path': work.posterPath,
  'backdrop_path': work.backdropPath,
}..remove('_manual');

Map<String, dynamic> filmMetadataSource(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(
      (value['_manual'] as Map?)?['source'] as Map? ?? value,
    )..remove('_manual');
Map<String, dynamic> filmMetadataOverrides(Map value) =>
    Map<String, dynamic>.from(
      (value['_manual'] as Map?)?['patch'] as Map? ?? {},
    );

/// 来源快照与人工补丁分离，空值同样代表明确覆盖。
Map<String, dynamic> filmApplyMetadata(
  Map<String, dynamic> source,
  Map<String, dynamic> patch,
) => {
  ...source,
  ...patch,
  if (patch.isNotEmpty) '_manual': {'source': source, 'patch': patch},
};

void validateFilmMetadata(Map<String, dynamic> values) {
  if ((values['title'] as String? ?? '').trim().isEmpty) {
    throw const FilmCatalogException('metadataTitleRequired');
  }
  final year = values['year'];
  final score = values['vote_average'];
  final runtime = values['runtime'];
  final credits = values['credits'] as Map?;
  for (final person in [
    ...?(credits?['cast'] as List?),
    ...?(credits?['crew'] as List?),
  ].whereType<Map>()) {
    if ((person['name'] as String? ?? '').trim().isEmpty) {
      throw const FilmCatalogException('metadataPersonNameRequired');
    }
  }
  if (year != null && (year is! int || year < 1 || year > 9999) ||
      score != null &&
          (score is! num || !score.isFinite || score < 0 || score > 10) ||
      runtime != null && (runtime is! int || runtime < 0)) {
    throw const FilmCatalogException('metadataInvalidNumber');
  }
  final date = values['release_date'] as String?;
  if (date != null && date.isNotEmpty) {
    final parsed = DateTime.tryParse(date);
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ||
        parsed == null ||
        parsed.toIso8601String().substring(0, 10) != date ||
        year != null && parsed.year != year) {
      throw const FilmCatalogException('metadataInvalidDate');
    }
  }
}

bool filmMetadataEqual(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);
