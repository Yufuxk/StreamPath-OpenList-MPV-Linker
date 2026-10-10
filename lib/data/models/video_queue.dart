import 'dart:io';
import 'package:path/path.dart' as p;
import '../../core/errors/app_exception.dart';
import 'media_entry.dart';
import '../../domain/services/webdav_font_matcher.dart';

class VideoQueueVersion {
  const VideoQueueVersion({
    required this.path,
    required this.name,
    this.rootId,
  });
  final String path, name;
  final int? rootId;
}

/// 同一集的资源版本共同占用一个逻辑位置。
class VideoQueueItem {
  const VideoQueueItem({
    required this.versions,
    this.season,
    this.episode,
    this.airDate,
    this.unavailable = false,
  });
  final List<VideoQueueVersion> versions;
  final int? season, episode;
  final DateTime? airDate;
  final bool unavailable;

  /// 同目录版本优先，其次沿用影视根和相同目录分支。
  List<VideoQueueVersion> orderedVersions(VideoQueueVersion? preferred) {
    if (preferred == null) return List.of(versions);
    final parent = p.posix.dirname(preferred.path).split('/');
    int sharedParent(VideoQueueVersion version) {
      final parts = p.posix.dirname(version.path).split('/');
      var count = 0;
      while (count < parent.length &&
          count < parts.length &&
          parent[count] == parts[count]) {
        count++;
      }
      return count;
    }

    final result = List<VideoQueueVersion>.of(versions);
    result.sort((a, b) {
      if (a.path == preferred.path) return b.path == preferred.path ? 0 : -1;
      if (b.path == preferred.path) return 1;
      if (preferred.rootId != null) {
        final sameA = a.rootId == preferred.rootId,
            sameB = b.rootId == preferred.rootId;
        if (sameA != sameB) return sameA ? -1 : 1;
      }
      final shared = sharedParent(b).compareTo(sharedParent(a));
      return shared != 0
          ? shared
          : versions.indexOf(a).compareTo(versions.indexOf(b));
    });
    return result;
  }

  Future<(VideoQueueVersion, PreparedVideoItem)> prepareVersion(
    Future<PreparedVideoItem> Function(VideoQueueVersion) prepare, {
    VideoQueueVersion? preferred,
    Future<bool> Function(VideoQueueVersion)? isAvailable,
    Map<String, PreparedVideoItem>? cached,
    Set<String> excluded = const {},
  }) async {
    if (unavailable) throw AppException.config('播放列表条目不可用，请检查来源或资源');
    Object? failure;
    StackTrace? failureStack;
    for (final version in orderedVersions(preferred)) {
      if (excluded.contains(version.path) ||
          isAvailable != null && !await isAvailable(version)) {
        continue;
      }
      try {
        final prepared = cached?[version.path] ?? await prepare(version);
        return (version, prepared);
      } on NetworkException catch (error, stack) {
        failure = error;
        failureStack = stack;
      } on ConfigException catch (error, stack) {
        failure = error;
        failureStack = stack;
      } on FileSystemException catch (error, stack) {
        failure = error;
        failureStack = stack;
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
    throw AppException.config('播放列表条目不可用，请检查来源或资源');
  }

  Map<String, dynamic> toJson() => {
    'versions': [
      for (final v in versions)
        {
          'path': v.path,
          'name': v.name,
          if (v.rootId != null) 'rootId': v.rootId,
        },
    ],
    'season': season,
    'episode': episode,
    'airDate': airDate?.toIso8601String(),
    if (unavailable) 'unavailable': true,
  };
  factory VideoQueueItem.fromJson(Map<String, dynamic> json) => VideoQueueItem(
    versions: [
      for (final v in json['versions'] as List)
        VideoQueueVersion(
          path: v['path'] as String,
          name: v['name'] as String,
          rootId: v['rootId'] as int?,
        ),
    ],
    season: json['season'] as int?,
    episode: json['episode'] as int?,
    airDate: DateTime.tryParse(json['airDate'] as String? ?? ''),
    unavailable: json['unavailable'] == true,
  );
}

class PreparedVideoItem {
  const PreparedVideoItem({
    required this.entry,
    this.localFontDirectory,
    this.remoteFonts,
  });
  final MediaEntry entry;
  final String? localFontDirectory;
  final WebDavFontDirectory? remoteFonts;
}

/// 只保存逻辑身份；真实媒体与附属资源由当前来源按需准备。
class ImplicitVideoPlan {
  ImplicitVideoPlan({
    required this.items,
    required this.index,
    required this.prepare,
    this.isAvailable,
    required this.activated,
    this.pending,
    this.failed,
  });
  final List<VideoQueueItem> items;
  int index;
  final Future<PreparedVideoItem> Function(VideoQueueVersion) prepare;
  final Future<bool> Function(VideoQueueVersion)? isAvailable;
  final Future<void> Function(int, VideoQueueVersion) activated;
  final Future<void> Function(int)? pending;
  final void Function(String)? failed;
  final Map<int, VideoQueueVersion> selected = {};
  final Map<String, PreparedVideoItem> prepared = {};
}

class VideoProgressUpdate {
  const VideoProgressUpdate({
    required this.sourceId,
    required this.path,
    required this.positionMs,
    required this.recordedAt,
    this.durationMs,
    this.completed = false,
    this.paused = false,
    this.stopped = false,
  });
  final String sourceId, path;
  final int positionMs;
  final int? durationMs;
  final DateTime recordedAt;
  final bool completed;
  final bool paused, stopped;
}
