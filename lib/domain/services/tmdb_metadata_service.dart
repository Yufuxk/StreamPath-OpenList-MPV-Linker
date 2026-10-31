import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import '../../data/local/tmdb_credential_store.dart';
import '../../data/models/film_catalog_item.dart';
import 'film_logo_selector.dart';
import 'tmdb_http_client.dart';

/// 从候选 Logo 中挑出最终下载的版本。
typedef LogoChooser = Future<String?> Function(List<LogoChoice> candidates);

/// 固定 TMDB API 域名、串行请求与连接故障时的备用入口。
class TmdbMetadataService {
  TmdbMetadataService({TmdbCredentialStore? credentials, Dio? dio})
    : credentials = credentials ?? const TmdbCredentialStore(),
      _dio = dio ?? createTmdbDio();
  final TmdbCredentialStore credentials;
  final Dio _dio;
  String _apiHost = 'api.themoviedb.org';
  String? _token;
  bool _loadedToken = false;
  bool _authenticationFailed = false;
  DateTime? _retryAt;
  Future<void> _tail = Future.value();
  Future<Map<String, dynamic>>? _configuration;
  final Map<String, Future<FilmWork>> _workRequests = {};
  final Map<String, Future<Map<String, dynamic>>> _seasonRequests = {};
  final CancelToken _cancel = CancelToken();

  Future<bool> hasToken() async {
    if (!_loadedToken) {
      _token = await credentials.read();
      _loadedToken = true;
    }
    return _token?.isNotEmpty == true;
  }

  Future<void> saveToken(String token) async {
    await credentials.write(token);
    _token = token.trim();
    _loadedToken = true;
    _authenticationFailed = false;
  }

  Future<void> clearToken() async {
    await credentials.delete();
    _token = null;
    _loadedToken = true;
    _authenticationFailed = false;
  }

  Future<void> verify() async {
    _authenticationFailed = false;
    await configuration(refresh: true);
  }

  void close() {
    _cancel.cancel();
    _dio.close(force: true);
  }

  Future<Map<String, dynamic>> _request(
    String endpoint,
    Map<String, dynamic> query,
  ) {
    final task = _tail.then((_) => _get(endpoint, query));
    _tail = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  Future<Map<String, dynamic>> _get(
    String endpoint,
    Map<String, dynamic> query, {
    String? fallbackHost,
  }) async {
    if (_cancel.isCancelled) throw const FilmCatalogException('cancelled');
    if (_retryAt != null && DateTime.now().isBefore(_retryAt!)) {
      throw const FilmCatalogException('rateLimited');
    }
    if (!await hasToken()) throw const FilmCatalogException('noToken');
    if (_authenticationFailed) throw const FilmCatalogException('invalidToken');
    final host = fallbackHost ?? _apiHost;
    try {
      final response = await _dio.get<Object>(
        'https://$host/3/$endpoint',
        queryParameters: query,
        cancelToken: _cancel,
        options: Options(
          followRedirects: false,
          maxRedirects: 0,
          headers: {'Authorization': 'Bearer $_token'},
          validateStatus: (status) =>
              status != null && status >= 200 && status < 600,
        ),
      );
      switch (response.statusCode) {
        case 200:
          break;
        case 401 || 403:
          _authenticationFailed = true;
          throw const FilmCatalogException('invalidToken');
        case 404:
          throw const FilmCatalogException('metadataNotFound');
        case 429:
          final header = response.headers.value('retry-after');
          if (header != null) {
            final seconds = int.tryParse(header);
            if (seconds != null) {
              _retryAt = DateTime.now().add(
                Duration(seconds: seconds < 0 ? 0 : seconds),
              );
            } else {
              try {
                _retryAt = HttpDate.parse(header);
              } on FormatException {
                _retryAt = null;
              }
            }
          }
          throw const FilmCatalogException('rateLimited');
        default:
          throw const FilmCatalogException('metadataRequestFailed');
      }
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        throw const FilmCatalogException('invalidMetadata');
      }
      _apiHost = host;
      return data;
    } on DioException catch (error) {
      if (_cancel.isCancelled) throw const FilmCatalogException('cancelled');
      if (error.error case final FilmCatalogException cause) throw cause;
      if (error.error is HandshakeException) {
        throw const FilmCatalogException('metadataTlsFailed');
      }
      if (fallbackHost == null &&
          switch (error.type) {
            DioExceptionType.connectionError ||
            DioExceptionType.connectionTimeout ||
            DioExceptionType.sendTimeout ||
            DioExceptionType.receiveTimeout => true,
            _ => false,
          }) {
        return _get(
          endpoint,
          query,
          fallbackHost: host == 'api.themoviedb.org'
              ? 'api.tmdb.org'
              : 'api.themoviedb.org',
        );
      }
      throw FilmCatalogException(switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => 'metadataTimeout',
        DioExceptionType.connectionError => 'metadataConnectionFailed',
        DioExceptionType.badCertificate => 'metadataTlsFailed',
        _ => 'metadataRequestFailed',
      });
    }
  }

  Future<Map<String, dynamic>> configuration({bool refresh = false}) async {
    if (refresh) _configuration = null;
    try {
      return await (_configuration ??= _request('configuration', {}));
    } on FilmCatalogException {
      _configuration = null;
      rethrow;
    }
  }

  Future<List<FilmWork>> search(
    FilmMediaType type,
    String query,
    String language, {
    int? year,
    int page = 1,
  }) async {
    final data = await _request('search/${type.name}', {
      'query': query,
      'language': language,
      'page': page,
      if (type == FilmMediaType.movie && year != null) 'year': year,
    });
    final rows = data['results'];
    if (rows is! List) throw const FilmCatalogException('invalidMetadata');
    return rows.map((r) {
      if (r is! Map<String, dynamic>) {
        throw const FilmCatalogException('invalidMetadata');
      }
      return _parseWork(type, r, language, detail: false);
    }).toList();
  }

  Future<FilmWork> details(
    FilmMediaType type,
    int id,
    String language, {
    Future<String?> Function(List<LogoChoice> candidates)? chooseLogo,
  }) async {
    if (id <= 0) throw const FilmCatalogException('invalidMetadata');
    final key = '${type.name}:$id:$language';
    try {
      return await (_workRequests[key] ??= () async {
        final data = await _request('${type.name}/$id', {
          'language': language,
          'append_to_response': type == FilmMediaType.movie
              ? 'credits,release_dates'
              : 'credits,content_ratings',
        });
        final images = await _request('${type.name}/$id/images', {});
        final backdrops = images['backdrops'];
        if (images['id'] != id || backdrops is! List) {
          throw const FilmCatalogException('invalidMetadata');
        }
        Map? best;
        final logos = (images['logos'] as List? ?? [])
            .whereType<Map>()
            .where(
              (logo) =>
                  logo['file_path'] is String &&
                  (logo['file_path'] as String).toLowerCase().endsWith('.png'),
            )
            .toList();
        final originalLanguage = data['original_language'] as String?;
        // 语言偏好：原产地 > 中文 > 英文 > 其他；同一层内按票数与分辨率排序。
        int languagePriority(Map logo) {
          final code = (logo['iso_639_1'] as String?)?.toLowerCase();
          if (code == null || code.isEmpty) return 3;
          if (code == originalLanguage) return 0;
          if (code.startsWith('zh')) return 1;
          if (code == 'en') return 2;
          return 3;
        }

        logos.sort((a, b) {
          final priority = languagePriority(a).compareTo(languagePriority(b));
          if (priority != 0) return priority;
          final votes = ((b['vote_average'] as num?) ?? 0).compareTo(
            (a['vote_average'] as num?) ?? 0,
          );
          return votes != 0
              ? votes
              : ((b['width'] as num?) ?? 0).compareTo(
                  (a['width'] as num?) ?? 0,
                );
        });
        final choices = [
          for (final logo in logos)
            LogoChoice(
              logo['file_path'] as String,
              (logo['width'] as int?) ?? 0,
              languagePriority(logo),
            ),
        ];
        final chosen = chooseLogo == null || choices.length < 2
            ? null
            : await chooseLogo(choices);
        for (final image in backdrops) {
          if (image is! Map ||
              image['width'] is! int ||
              image['height'] is! int ||
              image['file_path'] is! String ||
              image['width'] <= 0 ||
              image['height'] <= 0) {
            throw const FilmCatalogException('invalidMetadata');
          }
          if (image['width'] <= image['height']) continue;
          if (best == null ||
              image['width'] * image['height'] >
                  best['width'] * best['height']) {
            best = image;
          }
        }
        final work = _parseWork(type, {
          ...data,
          if (best != null) 'backdrop_path': best['file_path'],
          'backdrop_width': best?['width'],
          'backdrop_height': best?['height'],
          'backdrop_selection': 'highestResolution',
          'logo_path':
              chosen != null && choices.any((choice) => choice.path == chosen)
              ? chosen
              : choices.firstOrNull?.path,
          'logo_candidates': [
            for (final logo in logos)
              {
                'path': logo['file_path'],
                'width': logo['width'],
                'height': logo['height'],
                'language': logo['iso_639_1'],
              },
          ],
          'presentation_version': 5,
        }, language);
        if (work.tmdbId != id) {
          throw const FilmCatalogException('invalidMetadata');
        }
        return work;
      }());
    } finally {
      _workRequests.remove(key);
    }
  }

  Future<List<String>> matchingTitles(FilmMediaType type, int id) async {
    final data = await _request('${type.name}/$id', {
      'append_to_response': 'alternative_titles,translations',
    });
    final alternatives = data['alternative_titles'];
    final translations = data['translations'];
    final rows = alternatives is Map
        ? alternatives[type == FilmMediaType.movie ? 'titles' : 'results']
        : null;
    final localized = translations is Map ? translations['translations'] : null;
    if (data['id'] != id || rows is! List || localized is! List) {
      throw const FilmCatalogException('invalidMetadata');
    }
    final titles = <String>{};
    for (final row in rows) {
      if (row is! Map || row['title'] is! String) {
        throw const FilmCatalogException('invalidMetadata');
      }
      titles.add(row['title'] as String);
    }
    for (final row in localized) {
      final value = row is Map ? row['data'] : null;
      final title = value is Map
          ? value[type == FilmMediaType.movie ? 'title' : 'name']
          : null;
      if (title is! String) {
        throw const FilmCatalogException('invalidMetadata');
      }
      if (title.isNotEmpty) titles.add(title);
    }
    return titles.toList();
  }

  Future<Map<String, dynamic>> season(
    int id,
    int number,
    String language,
  ) async {
    if (id <= 0 || number < 0) {
      throw const FilmCatalogException('invalidMetadata');
    }
    final key = '$id:$number:$language';
    try {
      return await (_seasonRequests[key] ??= () async {
        final data = await _request('tv/$id/season/$number', {
          'language': language,
        });
        final rows = data['episodes'];
        if (data['season_number'] != number || rows is! List) {
          throw const FilmCatalogException('invalidMetadata');
        }
        if (data['poster_path'] != null && data['poster_path'] is! String) {
          throw const FilmCatalogException('invalidMetadata');
        }
        final episodes = <Map<String, dynamic>>[];
        for (final row in rows) {
          if (row is! Map ||
              row['episode_number'] is! int ||
              row['episode_number'] <= 0 ||
              row['season_number'] != number ||
              row['name'] is! String) {
            throw const FilmCatalogException('invalidMetadata');
          }
          episodes.add({
            'episode_number': row['episode_number'],
            'name': row['name'],
            'overview': row['overview'] is String ? row['overview'] : '',
            'air_date': row['air_date'],
            'runtime': row['runtime'],
            'still_path': row['still_path'],
          });
        }
        return {
          'season_number': number,
          'name': data['name'] is String ? data['name'] : '',
          'poster_path': data['poster_path'],
          'overview': data['overview'] is String ? data['overview'] : '',
          'air_date': data['air_date'],
          'episodes': episodes,
        };
      }());
    } finally {
      _seasonRequests.remove(key);
    }
  }

  FilmWork _parseWork(
    FilmMediaType type,
    Map<String, dynamic> data,
    String language, {
    bool detail = true,
  }) {
    final title = data[type == FilmMediaType.movie ? 'title' : 'name'];
    final original =
        data[type == FilmMediaType.movie ? 'original_title' : 'original_name'];
    final id = data['id'];
    if (id is! int ||
        id <= 0 ||
        title is! String ||
        title.isEmpty ||
        original is! String ||
        original.isEmpty) {
      throw const FilmCatalogException('invalidMetadata');
    }
    final date =
        data[type == FilmMediaType.movie ? 'release_date' : 'first_air_date'];
    final genres = data['genres'];
    if (detail && genres is! List) {
      throw const FilmCatalogException('invalidMetadata');
    }
    if ((data['poster_path'] != null && data['poster_path'] is! String) ||
        (data['backdrop_path'] != null && data['backdrop_path'] is! String)) {
      throw const FilmCatalogException('invalidMetadata');
    }
    return FilmWork(
      type: type,
      tmdbId: id,
      title: title,
      originalTitle: original,
      overview: data['overview'] is String ? data['overview'] : '',
      language: language,
      year: date is String && date.length >= 4
          ? int.tryParse(date.substring(0, 4))
          : null,
      posterPath: data['poster_path'] as String?,
      backdropPath: data['backdrop_path'] as String?,
      fetchedAt: DateTime.now().toUtc().millisecondsSinceEpoch,
      metadata: {
        'genres': genres is List
            ? [
                for (final g in genres)
                  if (g is Map && g['name'] is String) g['name'],
              ]
            : <String>[],
        'vote_average': data['vote_average'],
        'origin_country': (data['origin_country'] as List? ?? [])
            .whereType<String>()
            .toList(),
        'vote_count': data['vote_count'],
        'release_date': date is String ? date : '',
        'runtime': type == FilmMediaType.movie ? data['runtime'] : null,
        if (detail) ...{
          ..._certification(type, data),
          'certification_version': 1,
          'belongs_to_collection': data['belongs_to_collection'],
          'logo_path': data['logo_path'],
          'logo_candidates': data['logo_candidates'],
          'credits': data['credits'],
          'presentation_version': data['presentation_version'],
          'backdrop_width': data['backdrop_width'],
          'backdrop_height': data['backdrop_height'],
          'backdrop_selection': data['backdrop_selection'],
        },
      },
    );
  }

  Map<String, dynamic> _certification(
    FilmMediaType type,
    Map<String, dynamic> data,
  ) {
    final ratings = <String, String>{};
    final results =
        data[type == FilmMediaType.movie ? 'release_dates' : 'content_ratings'];
    if (results is Map && results['results'] is List) {
      for (final row in (results['results'] as List).whereType<Map>()) {
        final country = row['iso_3166_1'];
        if (country is! String) continue;
        final values = type == FilmMediaType.movie
            ? (row['release_dates'] as List? ?? []).whereType<Map>().map(
                (release) => release['certification'],
              )
            : [row['rating']];
        for (final value in values.whereType<String>()) {
          if (value.trim().isNotEmpty) {
            ratings.putIfAbsent(country, () => value.trim());
            break;
          }
        }
      }
    }
    // 优先美区，其次原产地，最后按地区码稳定选择。
    final countries = <String>{
      'US',
      ...(data['origin_country'] as List? ?? []).whereType<String>(),
      ...ratings.keys.toList()..sort(),
    };
    for (final country in countries) {
      if (ratings[country] case final String rating) {
        return {'certification': rating, 'certification_country': country};
      }
    }
    return {'certification': 'NR'};
  }
}
