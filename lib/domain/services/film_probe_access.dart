import 'dart:convert';
import 'dart:io';

import '../../core/utils/url_utils.dart' as urls;
import '../../data/models/film_catalog_item.dart';
import '../repositories/media_directory_source.dart';
import 'local_media_source.dart';
import 'webdav_media_source_adapter.dart';
import 'webdav_service.dart';

class FilmProbeTarget {
  const FilmProbeTarget(
    this.target, {
    this.headers = const {},
    this.metadata = const {},
  });
  final String target;
  final Map<String, String> headers;
  final Map<String, dynamic> metadata;
}

/// 仅准备普通媒体地址；光盘与 STRM 沿用播放时的参数快照。
class FilmProbeAccess {
  bool _cancelled = false;

  Future<void> cancel() async {
    _cancelled = true;
  }

  Future<FilmProbeTarget> prepare(
    FilmResource resource,
    MediaDirectorySource source,
  ) async {
    _cancelled = false;
    if (resource.isDisc) {
      throw const FilmCatalogException('probePlaybackOnly');
    }
    if (source is LocalMediaSource) {
      final target = await source.resolveRelativePath(resource.path);
      if (_cancelled) throw const FilmCatalogException('cancelled');
      return FilmProbeTarget(target);
    }
    if (source is WebDavMediaSourceAdapter) {
      if (resource.mediaKind == 'strm') {
        throw const FilmCatalogException('probePlaybackOnly');
      }
      final service = source.service;
      final target = service.fullUrl(resource.path);
      if (!urls.isSameOrigin(service.baseUrl, target)) {
        throw const FilmCatalogException('invalidPath');
      }
      return FilmProbeTarget(target, headers: _headers(service));
    }
    throw const FilmCatalogException('sourceUnavailable');
  }

  static Map<String, String> _headers(WebDAVService service) {
    final credentials = service.credentialSnapshot;
    return {
      if (credentials.username.isNotEmpty)
        HttpHeaders.authorizationHeader:
            'Basic ${base64Encode(utf8.encode('${credentials.username}:${credentials.password}'))}',
    };
  }
}
