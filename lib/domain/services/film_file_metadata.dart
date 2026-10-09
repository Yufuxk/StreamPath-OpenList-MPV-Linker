import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';
import 'package:xml/xml.dart';
import '../../data/models/film_catalog_item.dart';
import '../../data/models/film_image_reference.dart';
import '../../data/models/media_directory_entry.dart';
import '../../data/models/media_source.dart';
import '../repositories/media_directory_source.dart';
import 'local_media_source.dart';
import 'native_storage_source.dart';
import 'webdav_media_source_adapter.dart';

class FilmLocalMetadata {
  const FilmLocalMetadata(this.work, this.episode, this.season);
  final FilmWork work;
  final (int, int)? episode;
  final Map<String, dynamic>? season;
}

/// 小型伴随文件与媒体扫描分离；文件写入只允许创建缺少的文件。
class FilmFileMetadata {
  FilmFileMetadata(
    this.source,
    this.root, {
    required this.localMode,
    required this.canWrite,
  });
  final MediaDirectorySource source;
  final FilmCatalogRoot root;
  final bool localMode, canWrite;
  final _directories = <String, List<MediaDirectoryEntry>>{};
  Future<List<MediaDirectoryEntry>> _list(String path) async {
    if (_directories[path] case final rows?) return rows;
    final rows = await source.fetchDirectory(path, forceRefresh: true);
    _directories[path] = rows;
    if (_directories.length > 128) _directories.remove(_directories.keys.first);
    return rows;
  }

  Future<String?> _find(String directory, List<String> names) async {
    final rows = await _list(directory);
    for (final name in names) {
      final found = rows
          .where(
            (row) =>
                !row.isDirectory &&
                row.name.toLowerCase() == name.toLowerCase(),
          )
          .firstOrNull;
      if (found != null) {
        return directory.isEmpty ? found.name : '$directory/${found.name}';
      }
    }
    return null;
  }

  Future<Uint8List> read(String path, int limit) async {
    validateFilmPath(path);
    if (source is NativeStorageSource) {
      return (source as NativeStorageSource).readFile(path, maxBytes: limit);
    }
    if (source is LocalMediaSource) {
      final file = File(
        await (source as LocalMediaSource).resolveRelativePath(path),
      );
      if (await file.length() > limit) {
        throw const FilmCatalogException('imageTooLarge');
      }
      return file.readAsBytes();
    }
    final service = (source as WebDavMediaSourceAdapter).service;
    return Uint8List.fromList(
      await service.fetchFileBytes(
        service.resolveUrl(path),
        maxBytes: limit,
        timeout: const Duration(seconds: 30),
      ),
    );
  }

  Future<XmlElement> _xml(String path) async {
    final bytes = await read(path, 2 * 1024 * 1024);
    try {
      final text = bytes.length >= 2 && bytes[0] == 255 && bytes[1] == 254
          ? String.fromCharCodes([
              for (var i = 2; i + 1 < bytes.length; i += 2)
                bytes[i] | bytes[i + 1] << 8,
            ])
          : bytes.length >= 2 && bytes[0] == 254 && bytes[1] == 255
          ? String.fromCharCodes([
              for (var i = 2; i + 1 < bytes.length; i += 2)
                bytes[i] << 8 | bytes[i + 1],
            ])
          : utf8.decode(bytes).replaceFirst('\uFEFF', '');
      if (text.contains('<!DOCTYPE') || text.contains('<!ENTITY')) {
        throw const FormatException('Unsupported NFO entity');
      }
      return XmlDocument.parse(text).rootElement;
    } on FormatException {
      throw const FilmCatalogException('invalidNfo');
    }
  }

  static String _text(XmlElement node, String name) =>
      node.getElement(name)?.innerText.trim() ?? '';
  Future<String?> _art(String directory, List<String> names) async {
    final path = await _find(directory, names);
    return path == null
        ? null
        : FilmImageReference('file', root.sourceId, path).encode();
  }

  Future<FilmLocalMetadata?> load(FilmScanEntry entry, String language) async {
    if (root.sourceKind.isMediaServer) return null;
    final basename = p.posix.basenameWithoutExtension(entry.name);
    var directory = entry.parentPath;
    final itemNfo = await _find(directory, [
      '$basename.nfo',
      if (root.type == FilmMediaType.movie) 'movie.nfo',
    ]);
    XmlElement? episodeNode;
    String? workNfo = itemNfo;
    if (root.type == FilmMediaType.tv) {
      if (itemNfo != null) episodeNode = await _xml(itemNfo);
      workNfo = null;
      while (filmPathWithin(directory, root.path)) {
        workNfo = await _find(directory, ['tvshow.nfo']);
        if (workNfo != null || directory == root.path || directory.isEmpty) {
          break;
        }
        directory = p.posix.dirname(directory);
        if (directory == '.') directory = '';
      }
    }
    if (workNfo == null) return null;
    final node = await _xml(workNfo);
    if (node.name.local !=
        (root.type == FilmMediaType.movie ? 'movie' : 'tvshow')) {
      throw const FilmCatalogException('invalidNfo');
    }
    final title = _text(node, 'title');
    if (title.isEmpty) throw const FilmCatalogException('invalidNfo');
    final provider = <String, String>{};
    for (final id in node.findElements('uniqueid')) {
      final type = id.getAttribute('type');
      if (type != null && id.innerText.trim().isNotEmpty) {
        provider[type.toLowerCase()] = id.innerText.trim();
      }
    }
    if (_text(node, 'tmdbid').isNotEmpty) {
      provider['tmdb'] = _text(node, 'tmdbid');
    }
    final people = <Map<String, dynamic>>[];
    for (final actor in node.findElements('actor')) {
      final name = _text(actor, 'name');
      final id = actor
          .findElements('uniqueid')
          .where((id) => id.getAttribute('type') == 'tmdb')
          .firstOrNull
          ?.innerText;
      people.add({
        'name': name,
        'character': _text(actor, 'role'),
        if (int.tryParse(id ?? '') case final int id when id > 0) 'id': id,
      });
    }
    final season = int.tryParse(
      episodeNode == null ? '' : _text(episodeNode, 'season'),
    );
    final episode = int.tryParse(
      episodeNode == null ? '' : _text(episodeNode, 'episode'),
    );
    final mapping =
        season != null && season >= 0 && episode != null && episode > 0
        ? (season, episode)
        : null;
    final data = mapping == null
        ? null
        : <String, dynamic>{
            'season_number': season,
            'episodes': [
              {
                'season_number': season,
                'episode_number': episode,
                'name': _text(episodeNode!, 'title'),
                'overview': _text(episodeNode, 'plot'),
                'runtime': int.tryParse(_text(episodeNode, 'runtime')),
                'still_path': await _art(entry.parentPath, [
                  '$basename-thumb.jpg',
                  '$basename.jpg',
                  '$basename.png',
                ]),
              },
            ],
          };
    if (data != null) {
      final seasonNfo = await _find(entry.parentPath, ['season.nfo']);
      if (seasonNfo != null) {
        final seasonNode = await _xml(seasonNfo);
        if (seasonNode.name.local != 'season') {
          throw const FilmCatalogException('invalidNfo');
        }
        data['name'] = _text(seasonNode, 'title');
        data['overview'] = _text(seasonNode, 'plot');
      }
      data['poster_path'] =
          await _art(entry.parentPath, ['poster.jpg', 'poster.png']) ??
          await _art(directory, [
            'season${mapping!.$1.toString().padLeft(2, '0')}-poster.jpg',
            'season${mapping.$1.toString().padLeft(2, '0')}-poster.png',
          ]);
    }
    final work = FilmWork(
      type: root.type,
      tmdbId: int.tryParse(provider['tmdb'] ?? '') ?? 0,
      identityKey:
          'local:${root.sourceId}:$directory:${root.type == FilmMediaType.tv
              ? 'tvshow'
              : p.posix.basename(workNfo).toLowerCase() == 'movie.nfo'
              ? 'movie'
              : basename}',
      metadataOrigin: 'local',
      title: title,
      originalTitle: _text(node, 'originaltitle').isEmpty
          ? title
          : _text(node, 'originaltitle'),
      overview: _text(node, 'plot'),
      year: int.tryParse(_text(node, 'year')),
      language: language,
      posterPath: await _art(directory, [
        '$basename-poster.jpg',
        '$basename-poster.png',
        'poster.jpg',
        'poster.png',
        'folder.jpg',
      ]),
      backdropPath: await _art(directory, [
        '$basename-fanart.jpg',
        'fanart.jpg',
        'fanart.png',
        'backdrop.jpg',
      ]),
      metadata: {
        'provider_ids': provider,
        'runtime': int.tryParse(_text(node, 'runtime')),
        'genres': [
          for (final genre in node.findElements('genre'))
            {'name': genre.innerText},
        ],
        'credits': {
          'cast': people,
          'crew': [
            for (final director in node.findElements('director'))
              {'name': director.innerText, 'job': 'Director'},
          ],
        },
      },
    );
    return FilmLocalMetadata(work, mapping, data);
  }

  Future<void> create(String path, Uint8List bytes) async {
    if (!canWrite || root.sourceKind.isMediaServer) {
      throw const FilmCatalogException('sourceReadOnly');
    }
    if (source is NativeStorageSource) {
      return (source as NativeStorageSource).createMissingFile(path, bytes);
    }
    if (source is LocalMediaSource) {
      final parent = p.posix.dirname(path);
      final directory = await (source as LocalMediaSource).resolveRelativePath(
        parent == '.' ? '' : parent,
        expectDirectory: true,
      );
      final target = p.join(directory, p.posix.basename(path));
      await Isolate.run(() async {
        if (File(target).existsSync()) return;
        final staging = await Directory(
          directory,
        ).createTemp('.streampath-nfo-');
        final stagedFile = File(p.join(staging.path, 'metadata.tmp'));
        final arena = Arena();
        try {
          await stagedFile.writeAsBytes(bytes, flush: true);
          // MoveFile 不替换目标，写入完成后才发布伴随文件。
          if (MoveFile(
                    stagedFile.path.toNativeUtf16(allocator: arena),
                    target.toNativeUtf16(allocator: arena),
                  ) ==
                  0 &&
              !File(target).existsSync()) {
            throw const FilmCatalogException('metadataWriteFailed');
          }
        } finally {
          arena.releaseAll();
          if (await stagedFile.exists()) await stagedFile.delete();
          await staging.delete();
        }
      });
      return;
    }
    await (source as WebDavMediaSourceAdapter).service.createMissingFile(
      path,
      bytes,
    );
  }

  Future<void> writeWork(
    FilmWork work,
    FilmResource resource, {
    Uint8List? poster,
    Uint8List? backdrop,
    String? seriesDirectory,
    Map<String, dynamic>? seasonMetadata,
  }) async {
    if (!canWrite || root.sourceKind.isMediaServer) return;
    final builder = XmlBuilder()
      ..processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element(
      root.type == FilmMediaType.movie ? 'movie' : 'tvshow',
      nest: () {
        for (final field in {
          'title': work.title,
          'originaltitle': work.originalTitle,
          'plot': work.overview,
          'year': work.year,
          'runtime': work.metadata['runtime'],
        }.entries) {
          if (field.value != null) {
            builder.element(field.key, nest: '${field.value}');
          }
        }
        if (work.tmdbId > 0) {
          builder.element(
            'uniqueid',
            attributes: {'type': 'tmdb', 'default': 'true'},
            nest: '${work.tmdbId}',
          );
        }
      },
    );
    var directory = seriesDirectory ?? resource.parentPath;
    if (root.type == FilmMediaType.tv && seriesDirectory == null) {
      var current = resource.parentPath;
      while (filmPathWithin(current, root.path)) {
        if (await _find(current, ['tvshow.nfo']) != null) {
          directory = current;
          break;
        }
        if (current == root.path || current.isEmpty) break;
        current = p.posix.dirname(current);
        if (current == '.') current = '';
      }
    }
    final basename = root.type == FilmMediaType.movie
        ? p.posix.basenameWithoutExtension(resource.name)
        : 'tvshow';
    final prefix = directory.isEmpty ? '' : '$directory/';
    await create(
      '$prefix$basename.nfo',
      Uint8List.fromList(
        utf8.encode(builder.buildDocument().toXmlString(pretty: true)),
      ),
    );
    if (poster != null) await create('${prefix}poster.jpg', poster);
    if (backdrop != null) await create('${prefix}fanart.jpg', backdrop);
    if (root.type == FilmMediaType.tv &&
        resource.season != null &&
        resource.episode != null &&
        seasonMetadata != null) {
      final episode = (seasonMetadata['episodes'] as List? ?? [])
          .whereType<Map>()
          .where((row) => row['episode_number'] == resource.episode)
          .firstOrNull;
      if (episode != null) {
        final builder = XmlBuilder()
          ..processing('xml', 'version="1.0" encoding="UTF-8"');
        builder.element(
          'episodedetails',
          nest: () {
            for (final field in {
              'title': episode['name'],
              'plot': episode['overview'],
              'season': resource.season,
              'episode': resource.episode,
              'runtime': episode['runtime'],
            }.entries) {
              if (field.value != null) {
                builder.element(field.key, nest: '${field.value}');
              }
            }
          },
        );
        final path = p.posix.join(
          resource.parentPath,
          '${p.posix.basenameWithoutExtension(resource.name)}.nfo',
        );
        await create(
          path,
          Uint8List.fromList(
            utf8.encode(builder.buildDocument().toXmlString(pretty: true)),
          ),
        );
      }
    }
  }
}
