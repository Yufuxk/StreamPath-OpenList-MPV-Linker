import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import '../../data/models/film_catalog_item.dart';
import '../../data/models/media_connection.dart';
import '../../data/models/media_source.dart';

class ServerPlaybackInfo {
  const ServerPlaybackInfo({
    required this.itemId,
    required this.mediaSourceId,
    required this.playSessionId,
    required this.url,
    required this.runtimeTicks,
    required this.size,
  });
  final String itemId, mediaSourceId, playSessionId, url;
  final int? runtimeTicks;
  final int? size;
}

/// Jellyfin 与 Emby 各自持有 API 适配器，认证只在内存和凭据管理器保存。
abstract class MediaServerApi {
  MediaServerApi(this.config, {Dio? dio, Map<String, dynamic>? credentials})
    : dio = dio ?? Dio() {
    config.validate();
    this.dio.options
      ..connectTimeout = const Duration(seconds: 15)
      ..receiveTimeout = const Duration(seconds: 30)
      ..followRedirects = false
      ..headers['X-Emby-Authorization'] =
          'MediaBrowser Client="StreamPath", Device="Windows", DeviceId="${sha256.convert(utf8.encode(config.id)).toString().substring(0, 24)}", Version="0.1"';
    token = credentials?['token'] as String?;
    userId = credentials?['userId'] as String?;
    serverId = credentials?['serverId'] as String?;
    if (token != null) this.dio.options.headers['X-Emby-Token'] = token;
  }
  final MediaConnection config;
  final Dio dio;
  String? token, userId, serverId;
  bool authenticationFailed = false;
  bool _closed = false;
  String endpoint(String path) =>
      '${config.url.replaceAll(RegExp(r'/+$'), '')}/$path';
  Future<Response<dynamic>> request(
    String path, {
    String method = 'GET',
    Object? data,
    Map<String, dynamic>? query,
    bool playlistAccess = false,
  }) async {
    if (_closed) throw const FilmCatalogException('cancelled');
    if (authenticationFailed) {
      throw const FilmCatalogException('serverAuthenticationFailed');
    }
    try {
      return await dio.request(
        endpoint(path),
        data: data,
        queryParameters: query,
        options: Options(
          method: method,
          validateStatus: playlistAccess
              ? (status) =>
                    status != null &&
                    (status >= 200 && status < 300 ||
                        status == 403 ||
                        status == 404)
              : null,
        ),
      );
    } on DioException catch (error) {
      if (_closed) throw const FilmCatalogException('cancelled');
      if ([401, 403].contains(error.response?.statusCode)) {
        authenticationFailed = true;
        throw const FilmCatalogException('serverAuthenticationFailed');
      }
      throw const FilmCatalogException('serverConnectionFailed');
    }
  }

  Future<Map<String, dynamic>> authenticate(String password) async {
    authenticationFailed = false;
    final row = Map<String, dynamic>.from(
      (await request(
            'Users/AuthenticateByName',
            method: 'POST',
            data: {'Username': config.username, 'Pw': password},
          )).data
          as Map,
    );
    token = row['AccessToken'] as String;
    userId = (row['User'] as Map)['Id'] as String;
    serverId = row['ServerId'] as String;
    dio.options.headers['X-Emby-Token'] = token;
    return {
      'password': password,
      'token': token,
      'userId': userId,
      'serverId': serverId,
    };
  }

  Future<void> verify() async {
    if (userId == null || token == null) {
      throw const FilmCatalogException('serverAuthenticationFailed');
    }
    await request('Users/$userId');
  }

  Stream<List<Map<String, dynamic>>> items({
    String? parentId,
    String types = 'Movie,Series,Season,Episode,BoxSet',
    bool recursive = true,
  }) async* {
    var offset = 0;
    while (true) {
      final response = await request(
        'Users/$userId/Items',
        playlistAccess: types == 'Playlist',
        query: {
          'IncludeItemTypes': types,
          'Recursive': recursive,
          'StartIndex': offset,
          'Limit': 100,
          'Fields':
              'ProviderIds,Overview,People,MediaSources,Path,OriginalTitle,Genres,Studios,ProductionLocations,DateCreated,ParentId',
          'EnableUserData': true,
          'ParentId': ?parentId,
        },
      );
      if (types == 'Playlist' &&
          (response.statusCode == 403 || response.statusCode == 404)) {
        throw const FilmCatalogException('serverPlaylistUnavailable');
      }
      final row = response.data as Map;
      final page = (row['Items'] as List)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
      if (page.isEmpty) {
        if (types == 'Playlist' && offset < (row['TotalRecordCount'] as int)) {
          throw const FilmCatalogException('serverConnectionFailed');
        }
        return;
      }
      yield page;
      offset += page.length;
      if (offset >= (row['TotalRecordCount'] as int)) return;
    }
  }

  Future<Map<String, dynamic>> item(String id) async =>
      Map<String, dynamic>.from(
        (await request('Users/$userId/Items/$id')).data as Map,
      );
  Stream<List<Map<String, dynamic>>> playlistItems(String id) async* {
    var offset = 0;
    while (true) {
      final response = await request(
        'Playlists/$id/Items',
        playlistAccess: true,
        query: {
          'UserId': userId,
          'StartIndex': offset,
          'Limit': 100,
          'Fields': 'ProviderIds,MediaSources,ParentId',
          'EnableUserData': true,
        },
      );
      if (response.statusCode == 403 || response.statusCode == 404) {
        throw const FilmCatalogException('serverPlaylistUnavailable');
      }
      final row = response.data as Map;
      final page = (row['Items'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      if (page.isEmpty) {
        if (offset < (row['TotalRecordCount'] as int)) {
          throw const FilmCatalogException('serverConnectionFailed');
        }
        return;
      }
      yield page;
      offset += page.length;
      if (offset >= (row['TotalRecordCount'] as int)) return;
    }
  }

  Future<ServerPlaybackInfo> playback(
    String itemId, {
    String? mediaSourceId,
    int startTicks = 0,
  }) async {
    final info =
        (await request(
              'Items/$itemId/PlaybackInfo',
              method: 'POST',
              data: {
                'UserId': userId,
                'StartTimeTicks': startTicks,
                'MediaSourceId': ?mediaSourceId,
                'EnableDirectPlay': true,
                'EnableDirectStream': false,
                'EnableTranscoding': false,
                'DeviceProfile': {
                  'Name': 'StreamPath MPV',
                  'MaxStreamingBitrate': 1000000000,
                  'MaxStaticBitrate': 1000000000,
                  'DirectPlayProfiles': [
                    {
                      'Type': 'Video',
                      'Container':
                          'mkv,mp4,m4v,mov,avi,ts,m2ts,mpg,mpeg,webm,wmv,flv,ogg,ogv',
                    },
                  ],
                  'TranscodingProfiles': <Object>[],
                  'ContainerProfiles': <Object>[],
                  'CodecProfiles': <Object>[],
                  'SubtitleProfiles': [
                    for (final format in [
                      'ass',
                      'ssa',
                      'srt',
                      'subrip',
                      'webvtt',
                      'pgssub',
                      'dvdsub',
                      'mov_text',
                    ])
                      {'Format': format, 'Method': 'Embed'},
                  ],
                },
              },
            )).data
            as Map;
    final sources = (info['MediaSources'] as List).whereType<Map>();
    final source = sources
        .where(
          (row) =>
              row['SupportsDirectPlay'] == true &&
              (mediaSourceId == null || row['Id'] == mediaSourceId),
        )
        .firstOrNull;
    if (source == null || source['RequiresOpening'] == true) {
      throw const FilmCatalogException('serverDirectPlayUnavailable');
    }
    final id = source['Id'] as String;
    final url = Uri.parse(endpoint('Videos/$itemId/stream'))
        .replace(
          queryParameters: {
            'Static': 'true',
            'MediaSourceId': id,
            'PlaySessionId': info['PlaySessionId'] as String,
          },
        )
        .toString();
    return ServerPlaybackInfo(
      itemId: itemId,
      mediaSourceId: id,
      playSessionId: info['PlaySessionId'] as String,
      url: url,
      runtimeTicks: (source['RunTimeTicks'] as num?)?.toInt(),
      size: (source['Size'] as num?)?.toInt(),
    );
  }

  Future<void> report(String event, Map<String, dynamic> state) async {
    await request(
      'Sessions/Playing${event == 'start'
          ? ''
          : event == 'stop'
          ? '/Stopped'
          : '/Progress'}',
      method: 'POST',
      data: state,
    );
  }

  Future<void> played(String id, bool watched);
  Future<void> favorite(String id, bool value) async {
    await request(
      'Users/$userId/FavoriteItems/$id',
      method: value ? 'POST' : 'DELETE',
    );
  }

  Future<Uint8List> image(
    String itemId,
    String type,
    String tag, {
    String? index,
  }) async {
    try {
      final response = await dio.get<ResponseBody>(
        endpoint('Items/$itemId/Images/$type${index == null ? '' : '/$index'}'),
        queryParameters: {'tag': tag},
        options: Options(responseType: ResponseType.stream),
      );
      final body = response.data!;
      final output = BytesBuilder(copy: false);
      if (body.contentLength > 10 * 1024 * 1024) {
        await body.stream.listen((_) {}).cancel();
        throw const FilmCatalogException('imageTooLarge');
      }
      await for (final chunk in body.stream) {
        output.add(chunk);
        if (output.length > 10 * 1024 * 1024) {
          throw const FilmCatalogException('imageTooLarge');
        }
      }
      return output.takeBytes();
    } on DioException catch (error) {
      if ([401, 403].contains(error.response?.statusCode)) {
        authenticationFailed = true;
        throw const FilmCatalogException('serverAuthenticationFailed');
      }
      throw const FilmCatalogException('invalidImage');
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    dio.close(force: true);
  }
}

class JellyfinApi extends MediaServerApi {
  JellyfinApi(super.config, {super.dio, super.credentials});
  @override
  Future<void> played(String id, bool watched) async {
    await request(
      'Users/$userId/PlayedItems/$id',
      method: watched ? 'POST' : 'DELETE',
    );
  }
}

class EmbyApi extends MediaServerApi {
  EmbyApi(super.config, {super.dio, super.credentials});
  @override
  Future<void> played(String id, bool watched) async {
    await request(
      'Users/$userId/PlayedItems/$id',
      method: watched ? 'POST' : 'DELETE',
    );
  }
}

MediaServerApi mediaServerApi(
  MediaConnection config, {
  Dio? dio,
  Map<String, dynamic>? credentials,
}) => switch (config.kind) {
  MediaSourceKind.jellyfin => JellyfinApi(
    config,
    dio: dio,
    credentials: credentials,
  ),
  MediaSourceKind.emby => EmbyApi(config, dio: dio, credentials: credentials),
  _ => throw ArgumentError('Expected media server'),
};
