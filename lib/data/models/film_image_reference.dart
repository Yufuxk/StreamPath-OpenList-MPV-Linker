import 'dart:convert';
import 'film_catalog_item.dart';

/// 图片只保存稳定引用，认证和临时 URL 由当前来源解析。
class FilmImageReference {
  const FilmImageReference(
    this.origin,
    this.sourceId,
    this.path, {
    this.type,
    this.tag,
    this.index,
  });
  final String origin, sourceId, path;
  final String? type, tag, index;
  String encode() =>
      'sp-image:${base64Url.encode(utf8.encode(jsonEncode({'origin': origin, 'source': sourceId, 'path': path, 'type': type, 'tag': tag, 'index': index})))}';
  static FilmImageReference? parse(String value) {
    if (!value.startsWith('sp-image:')) return null;
    try {
      final row =
          jsonDecode(utf8.decode(base64Url.decode(value.substring(9)))) as Map;
      final ref = FilmImageReference(
        row['origin'] as String,
        row['source'] as String,
        row['path'] as String,
        type: row['type'] as String?,
        tag: row['tag'] as String?,
        index: row['index'] as String?,
      );
      if (!['file', 'server', 'asset'].contains(ref.origin) ||
          ref.sourceId.isEmpty) {
        throw const FormatException('Invalid image reference');
      }
      validateFilmPath(ref.path);
      if (ref.origin == 'server' &&
          (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(ref.path) ||
              !['Primary', 'Backdrop', 'Thumb'].contains(ref.type) ||
              ref.tag == null ||
              ref.index != null && !RegExp(r'^\d+$').hasMatch(ref.index!))) {
        throw const FormatException('Invalid server image');
      }
      return ref;
    } on FormatException {
      throw const FilmCatalogException('invalidImage');
    } on TypeError {
      throw const FilmCatalogException('invalidImage');
    }
  }
}
