import '../../core/constants.dart';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../../core/errors/app_exception.dart';
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
  }) {
    if (directories != null) _directories.addAll(directories);
  }
  final MediaDirectorySource source;
  final PlayerConfig config;
  final SubtitleMatcher subtitleMatcher;
  final WebDavFontMatcher fontMatcher;
  final Map<String, String> titles;
  final _directories = <String, List<MediaDirectoryEntry>>{};
  final _fonts = <String, PreparedVideoItem>{};
  String? sharedLocalFonts;
  WebDavFontDirectory? sharedRemoteFonts;
  bool get local => source.descriptor.kind == MediaSourceKind.local;

  Future<void> prepareSharedFonts(
    String rootPath, {
    List<MediaDirectoryEntry>? siblings,
  }) async {
    if (!config.sharePlaylistFonts) return;
    final files = siblings ?? await source.fetchDirectory(rootPath);
    final video = files
        .where((e) => e.isVideo || !local && e.isPlayable)
        .firstOrNull;
    if (video == null) return;
    final fonts = await fontsFor(video, files);
    sharedLocalFonts = fonts.localFontDirectory;
    sharedRemoteFonts = fonts.remoteFonts;
  }

  Future<PreparedVideoItem> prepare(VideoQueueVersion version) async {
    final parent = p.posix
        .dirname(version.path)
        .replaceFirst(RegExp(r'^\.$'), '');
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
    if (video == null) throw AppException.config('未找到上次播放的视频，请检查文件或特典设置');
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
    final subtitle = await subtitleFor(video, siblings);
    final fonts = _fonts[parent] ??= await fontsFor(video, siblings);
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
      localFontDirectory: fonts.localFontDirectory ?? sharedLocalFonts,
      remoteFonts: fonts.remoteFonts ?? sharedRemoteFonts,
    );
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
