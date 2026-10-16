import 'dart:io';
import 'package:path/path.dart' as p;
import '../../data/models/film_catalog_item.dart';
import '../../data/models/media_directory_entry.dart';
import '../../data/models/player_config.dart';
import '../../domain/services/webdav_media_source_adapter.dart';
import '../../domain/services/special_video_playlist_collector.dart';
import '../../domain/services/video_entry_preparer.dart';
import '../../domain/services/subtitle_matcher.dart';
import '../../domain/services/webdav_font_matcher.dart';
import '../../domain/services/external_audio_matcher.dart';
import '../../domain/services/iso_subtitle_service.dart';
import '../../domain/services/webdav_bdmv_service.dart';
import '../../domain/services/iso_subtitle_matcher.dart';
import 'video_cache_models.dart';
import 'video_cache_service.dart';

class VideoCachePlanner {
  VideoCachePlanner(
    this.cache,
    this.source,
    this.config,
    this.subtitleMatcher,
    this.fontMatcher, {
    this.identity,
  });
  final VideoCacheService cache;
  final WebDavMediaSourceAdapter source;
  final PlayerConfig config;
  final SubtitleMatcher subtitleMatcher;
  final WebDavFontMatcher fontMatcher;
  final String? identity;
  final _directories = <String, List<MediaDirectoryEntry>>{};
  final _probes = <String, Future<Map<String, dynamic>>>{};

  String pathFor(MediaDirectoryEntry entry, String parent) =>
      SpecialVideoPlaylistCollector.directChildPath(source, parent, entry) ??
      (throw const VideoCacheException('缓存文件路径无效'));

  Future<List<MediaDirectoryEntry>> directory(String path) async =>
      _directories[path] ??= await source.fetchDirectory(path);

  Future<VideoCachePlan> plan(FilmResource resource, String target) async {
    if (this.identity != null) {
      final existing = cache.bundles.values
          .where(
            (b) =>
                b['source'] == resource.sourceId &&
                b['path'] == resource.path &&
                b['identity'] == this.identity,
          )
          .firstOrNull;
      if (existing != null) {
        if (cache.complete(existing) &&
            await cache.lookup(
                  resource.sourceId,
                  resource.path,
                  identity: this.identity,
                ) ==
                null) {
          throw const VideoCacheException('缓存成品已失效，请删除后重新缓存');
        }
        return VideoCachePlan(
          bundle: existing,
          files: (existing['files'] as List)
              .map((id) => cache.files[id]!)
              .toList(),
        );
      }
    }
    if (!p.isAbsolute(target) || !await Directory(target).exists()) {
      throw const VideoCacheException('缓存目录不存在');
    }
    final root = await Directory(target).resolveSymbolicLinks();
    final directoryPaths = <String>{resource.parentPath};
    final siblings = await directory(resource.parentPath);
    final mainEntry = siblings
        .where((entry) => !entry.isSelfEntry)
        .where((entry) => pathFor(entry, resource.parentPath) == resource.path)
        .firstOrNull;
    if (mainEntry == null) throw const VideoCacheException('缓存来源文件不存在');
    final mainProbe = resource.mediaKind == 'bdmv'
        ? null
        : await probe(resource.path, strm: mainEntry.isStrm);
    final identity =
        mainProbe?['identity'] as String? ??
        (await cache.resolveTransfer(
              resource.sourceId,
              resource.path,
              false,
            ))['identity']
            as String;
    final tree = p.join(
      root,
      'StreamPathCache',
      videoCacheId('${resource.sourceId}\n$identity'),
    );
    final rows = <String, VideoCacheFile>{};
    final attachments = <String>{};
    Future<String> add(
      String path, {
      bool strm = false,
      Map<String, dynamic>? metadata,
      bool attachment = false,
    }) async {
      videoCachePath(path);
      final info = metadata ?? await probe(path, strm: strm);
      var extension = '.mkv';
      if (strm) {
        final transfer = await cache.resolveTransfer(
          resource.sourceId,
          path,
          true,
        );
        final name = Uri.tryParse(
          transfer['url'] as String? ?? '',
        )?.pathSegments.lastOrNull;
        if (name != null && p.extension(name).isNotEmpty) {
          extension = p.extension(name);
        }
      }
      final relative = strm ? '$path.video$extension' : path;
      final destination = p.joinAll([tree, ...relative.split('/')]);
      final id = videoCacheId('$identity\n$destination');
      if (attachment) attachments.add(id);
      rows[id] = VideoCacheFile({
        'id': id,
        'source': resource.sourceId,
        'path': path,
        'strm': strm,
        'identity': identity,
        'destination': destination,
        'root': root,
        ...info,
      });
      return id;
    }

    String? main, subtitle;
    final fonts = <String>[], audio = <String>[];
    String? discPath;
    String subtitleLanguage = 'exact';
    if (resource.mediaKind == 'bdmv') {
      final disc = await WebDavBdmvService.discover(
        source.service,
        resource.path,
      );
      for (final item in disc.files.where((f) => f['directory'] != true)) {
        final path = disc.rootPath.isEmpty
            ? item['path'] as String
            : '${disc.rootPath}/${item['path']}';
        final id = await add(path);
        main ??= id;
      }
      discPath = p
          .relative(p.joinAll([tree, ...disc.rootPath.split('/')]), from: root)
          .replaceAll('\\', '/');
      if (main == null) throw const VideoCacheException('缓存来源文件不存在');
    } else {
      main = await add(
        resource.path,
        strm: mainEntry.isStrm,
        metadata: mainProbe,
      );
    }
    if (resource.isDisc) {
      final iso = resource.mediaKind == 'bdmv'
          ? await WebDavBdmvService.discover(source.service, resource.path)
          : mainEntry;
      final context = await IsoSubtitleContext.create(source, iso);
      final stem = p.posix
          .basenameWithoutExtension(resource.path)
          .toLowerCase();
      final count = siblings.where((e) => e.isIso).length;
      for (final candidate in context.candidates.where(
        (c) =>
            IsoSubtitleMatcher.describe(
                  c.path,
                  stem,
                  resource.mediaKind == 'bdmv' ? 1 : count,
                ) !=
                null ||
            context.bindings.values.contains(c.path),
      )) {
        await add(candidate.path, attachment: true);
      }
      for (final font in context.fonts) {
        fonts.add(await add(font.path, attachment: true));
      }
    } else {
      final matched = config.subtitleInjectionEnabled
          ? subtitleMatcher.findBestFor(mainEntry, siblings)
          : null;
      if (matched != null) {
        final file = siblings
            .where((e) => e.entryKey == matched.url)
            .firstOrNull;
        if (file != null) {
          subtitle = await add(
            pathFor(file, resource.parentPath),
            attachment: true,
          );
          subtitleLanguage = matched.language.name;
        }
      }
      if (config.externalAudioInjectionEnabled) {
        for (final track in const ExternalAudioMatcher().matchFor(
          mainEntry,
          siblings,
          baseUrl: source.service.baseUrl,
        )) {
          final file = siblings
              .where((e) => source.service.resolveUrl(e.entryKey) == track.url)
              .firstOrNull;
          if (file != null) {
            audio.add(
              await add(pathFor(file, resource.parentPath), attachment: true),
            );
          }
        }
      }
      final preparer = VideoEntryPreparer(
        source: source,
        config: config,
        subtitleMatcher: subtitleMatcher,
        fontMatcher: fontMatcher,
        titles: const {},
      );
      final matchedFonts = await preparer.fontsFor(mainEntry, siblings);
      if (matchedFonts.remoteFonts case final remote?) {
        directoryPaths.add(remote.requestPath);
        await directory(remote.requestPath);
        for (final font in remote.files) {
          final file = _directories[remote.requestPath]!
              .where((e) => e.name == font.name)
              .firstOrNull;
          if (file != null) {
            fonts.add(
              await add(pathFor(file, remote.requestPath), attachment: true),
            );
          }
        }
      }
    }
    // 为离线播放保存目录展示快照，不保存会话 URL。
    if (resource.isDisc) {
      final parents = rows.values.map((f) => p.posix.dirname(f.path)).toSet();
      for (final parent in parents) {
        directoryPaths.add(parent == '.' ? '' : parent);
        await directory(parent == '.' ? '' : parent);
      }
      if (resource.mediaKind == 'bdmv') {
        directoryPaths.add(resource.path);
        await directory(resource.path);
      }
    }
    final directories = <String, Object>{};
    for (final path in directoryPaths) {
      directories[path] = [
        for (final e in _directories[path]!.where((e) => !e.isSelfEntry))
          {
            'name': e.name,
            'path': pathFor(e, path),
            'directory': e.isDirectory,
            'size': e.size,
            'modified': e.modified?.millisecondsSinceEpoch,
          },
      ];
    }
    final progress =
        mainProbe?['progress'] as String? ??
        source.service.persistentUrl(mainEntry.entryKey);
    final bundle = <String, dynamic>{
      'id': videoCacheId('${resource.sourceId}\n$identity\n${resource.path}'),
      'source': resource.sourceId,
      'sourceKind': resource.sourceKind.name,
      'identity': identity,
      'name': resource.name,
      'path': resource.path,
      'kind': resource.mediaKind,
      'root': root,
      'tree': tree,
      'main': main,
      'progress': progress,
      'files': rows.keys.toList(),
      'subtitle': subtitle,
      'subtitleLanguage': subtitleLanguage,
      'fonts': fonts,
      'audio': audio,
      'attachments': attachments.toList(),
      'directories': directories,
      'discPath': discPath,
    };
    return VideoCachePlan(bundle: bundle, files: rows.values.toList());
  }

  Future<Map<String, dynamic>> probe(String path, {bool strm = false}) =>
      _probes.putIfAbsent(
        '$path:$strm',
        () => cache.probe(source.descriptor.sourceId, path, strm: strm),
      );
}
