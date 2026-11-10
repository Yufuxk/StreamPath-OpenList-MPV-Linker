import '../../core/constants.dart';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../../core/errors/app_exception.dart';
import '../../data/models/film_catalog_item.dart';
import '../../data/models/media_directory_entry.dart';
import '../../data/models/media_entry.dart';
import '../../data/models/media_source.dart';
import '../../data/models/player_config.dart';
import '../../data/models/subtitle_item.dart';
import '../../data/models/video_queue.dart';
import '../../data/models/web_dav_file.dart';
import '../repositories/media_directory_source.dart';
import 'external_audio_matcher.dart';
import 'special_video_playlist_collector.dart';
import 'subtitle_matcher.dart';
import 'webdav_font_localizer.dart';
import 'webdav_font_matcher.dart';
import 'webdav_media_source_adapter.dart';

/// 逐集准备捕获来源和设置，不依赖页面或活动档案。
class VideoEntryPreparer {
  VideoEntryPreparer({
    required this.source,
    required this.config,
    required this.subtitleMatcher,
    required this.fontMatcher,
    required this.titles,
    Map<String, List<MediaDirectoryEntry>>? directories,
    this.cached,
  }) {
    if (directories != null) _directories.addAll(directories);
  }
  final MediaDirectorySource source;
  final PlayerConfig config;
  final SubtitleMatcher subtitleMatcher;
  final WebDavFontMatcher fontMatcher;
  final Map<String, String> titles;
  final Future<PreparedVideoItem?> Function(String path)? cached;
  final _directories = <String, List<MediaDirectoryEntry>>{};
  final _fonts = <String, PreparedVideoItem>{};
  String? sharedLocalFonts;
  WebDavFontDirectory? sharedRemoteFonts;
  bool get local => source.descriptor.kind == MediaSourceKind.local;

  Future<void> prepareSharedFonts(
    String rootPath, {
    List<MediaDirectoryEntry>? siblings,
    String? startPath,
  }) async {
    if (!config.sharePlaylistFonts) return;
    if (startPath != null) {
      final hit = await cached?.call(startPath);
      if (hit != null &&
          (hit.localFontDirectory != null || hit.remoteFonts != null)) {
        return;
      }
    }
    final List<MediaDirectoryEntry> files;
    try {
      files =
          siblings ??
          (_directories[rootPath] ??= await source.fetchDirectory(rootPath));
    } on AppException {
      // 共享字体是可选资源，目录不可用时不影响当前播放。
      return;
    } on FilmCatalogException {
      return;
    } on FileSystemException {
      return;
    }
    _directories[rootPath] ??= files;
    final video = files
        .where((e) => e.isVideo || !local && e.isPlayable)
        .firstOrNull;
    if (video == null) return;
    final fonts = await _fontsAt(rootPath, video, files);
    sharedLocalFonts = fonts.localFontDirectory;
    sharedRemoteFonts = fonts.remoteFonts;
  }

  /// 字体属于可选资源，目录读取或文件校验失败只跳过本次注入。
  Future<PreparedVideoItem> _fontsAt(
    String parent,
    MediaDirectoryEntry video,
    List<MediaDirectoryEntry> siblings,
  ) async {
    if (_fonts[parent] case final cached?) return cached;
    try {
      return _fonts[parent] = await fontsFor(video, siblings);
    } on AppException {
      return _fonts[parent] = const PreparedVideoItem(
        entry: MediaEntry(url: ''),
      );
    } on FilmCatalogException {
      return _fonts[parent] = const PreparedVideoItem(
        entry: MediaEntry(url: ''),
      );
    } on FileSystemException {
      return _fonts[parent] = const PreparedVideoItem(
        entry: MediaEntry(url: ''),
      );
    }
  }

  Future<PreparedVideoItem> prepare(VideoQueueVersion version) async {
    final hit = await cached?.call(version.path);
    // 缓存条目可能缺少字幕或字体；复用缓存路径，只补查缺失的附属资源。
    final enrichSubtitle =
        config.subtitleInjectionEnabled && hit?.entry.subtitle == null;
    final enrichFonts =
        config.subtitleInjectionEnabled &&
        hit != null &&
        hit.localFontDirectory == null &&
        hit.remoteFonts == null;
    if (hit != null && !enrichSubtitle && !enrichFonts) return hit;
    final parent = p.posix
        .dirname(version.path)
        .replaceFirst(RegExp(r'^\.$'), '');
    try {
      final siblings = _directories[parent] ??= await source.fetchDirectory(
        parent,
      );
      final video = siblings
          .where(
            (e) =>
                e.name == version.name &&
                SpecialVideoPlaylistCollector.directChildPath(
                      source,
                      parent,
                      e,
                    ) ==
                    version.path,
          )
          .firstOrNull;
      if (video == null) {
        if (hit != null) return hit;
        throw AppException.config('未找到上次播放的视频，请检查文件或特典设置');
      }
      final subtitle =
          hit?.entry.subtitle ?? await subtitleFor(video, siblings);
      final fonts = hit == null || enrichFonts
          ? await _fontsAt(parent, video, siblings)
          : null;
      if (hit != null) {
        // 缓存有效资源优先；新查找只补空缺，不能覆盖缓存路径。
        return PreparedVideoItem(
          entry: MediaEntry(
            url: hit.entry.url,
            progressTarget: hit.entry.progressTarget,
            catalogPath: hit.entry.catalogPath ?? version.path,
            title: hit.entry.title,
            subtitle: subtitle,
            externalAudioTracks: hit.entry.externalAudioTracks,
          ),
          localFontDirectory:
              hit.localFontDirectory ??
              fonts?.localFontDirectory ??
              sharedLocalFonts,
          remoteFonts:
              hit.remoteFonts ?? fonts?.remoteFonts ?? sharedRemoteFonts,
        );
      }
      final String url;
      if (video is WebDavFile && video.isStrm) {
        final resolved = await (source as WebDavMediaSourceAdapter).service
            .fetchStrmUrl(video);
        if (resolved == null) throw AppException.config('strm 内容无效或读取失败');
        url = resolved;
      } else {
        url = switch (await source.resolve(video)) {
          WebDavMediaOpenTarget(:final url) => url,
          LocalMediaOpenTarget(:final path) => path,
        };
      }
      return PreparedVideoItem(
        entry: MediaEntry(
          url: url,
          catalogPath: version.path,
          title: titles[version.path] ?? version.name,
          subtitle: subtitle,
          externalAudioTracks: local
              ? const []
              : const ExternalAudioMatcher().matchFor(
                  video,
                  siblings,
                  baseUrl: (source as WebDavMediaSourceAdapter).service.baseUrl,
                ),
        ),
        localFontDirectory: fonts?.localFontDirectory ?? sharedLocalFonts,
        remoteFonts: fonts?.remoteFonts ?? sharedRemoteFonts,
      );
    } on AppException {
      if (hit != null) return hit;
      rethrow;
    } on FilmCatalogException {
      if (hit != null) return hit;
      rethrow;
    } on FileSystemException {
      if (hit != null) return hit;
      rethrow;
    }
  }

  Future<SubtitleItem?> subtitleFor(
    MediaDirectoryEntry video,
    List<MediaDirectoryEntry> siblings,
  ) async {
    if (!config.subtitleInjectionEnabled) return null;
    final match = subtitleMatcher.findBestFor(video, siblings);
    if (match == null || !local) return match;
    final file = siblings.where((e) => e.entryKey == match.url).firstOrNull;
    if (file == null) return null;
    final target = await source.resolve(file);
    return target is LocalMediaOpenTarget
        ? SubtitleItem(
            name: match.name,
            url: target.path,
            language: match.language,
            score: match.score,
          )
        : null;
  }

  Future<PreparedVideoItem> fontsFor(
    MediaDirectoryEntry video,
    List<MediaDirectoryEntry> siblings,
  ) async {
    if (!config.subtitleInjectionEnabled) {
      return const PreparedVideoItem(entry: MediaEntry(url: ''));
    }
    if (!local) {
      final service = (source as WebDavMediaSourceAdapter).service;
      final match = fontMatcher.findBestFor(
        video,
        siblings,
        baseUrl: service.baseUrl,
      );
      if (match == null) {
        return const PreparedVideoItem(entry: MediaEntry(url: ''));
      }
      try {
        final files = await service.fetchDirectory(match.requestPath);
        final fonts = fontMatcher.withDirectFontFiles(
          match,
          files,
          baseUrl: service.baseUrl,
        );
        return PreparedVideoItem(
          entry: const MediaEntry(url: ''),
          remoteFonts: fonts.files.isEmpty ? null : fonts,
        );
      } on AppException {
        return const PreparedVideoItem(entry: MediaEntry(url: ''));
      }
    }
    final candidates =
        siblings
            .where(
              (e) =>
                  e.isDirectory &&
                  !e.isSelfEntry &&
                  WebDavFontMatcher.directoryScore(e.name) != null,
            )
            .toList()
          ..sort(
            (a, b) => WebDavFontMatcher.directoryScore(
              b.name,
            )!.compareTo(WebDavFontMatcher.directoryScore(a.name)!),
          );
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    for (final folder in candidates) {
      if (DateTime.now().isAfter(deadline)) break;
      final target = await source.resolve(folder);
      if (target is! LocalMediaOpenTarget) continue;
      var count = 0, bytes = 0;
      var oversized = false;
      final files = await source.fetchDirectory(folder.relativePath);
      for (final file in files.where(
        (e) =>
            !e.isDirectory && AppConstants.fontExtensions.contains(e.extension),
      )) {
        final resolved = await source.resolve(file);
        if (resolved is LocalMediaOpenTarget) {
          count++;
          final size = await File(resolved.path).length();
          oversized |= size > WebDavFontLocalizer.maxFontBytes;
          bytes += size;
          if (count > WebDavFontLocalizer.maxFontFiles ||
              bytes > WebDavFontLocalizer.maxSessionBytes ||
              DateTime.now().isAfter(deadline)) {
            break;
          }
        }
      }
      if (!oversized &&
          DateTime.now().isBefore(deadline) &&
          count > 0 &&
          count <= WebDavFontLocalizer.maxFontFiles &&
          bytes <= WebDavFontLocalizer.maxSessionBytes) {
        return PreparedVideoItem(
          entry: const MediaEntry(url: ''),
          localFontDirectory: target.path,
        );
      }
    }
    return const PreparedVideoItem(entry: MediaEntry(url: ''));
  }
}
