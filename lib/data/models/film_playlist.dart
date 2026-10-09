import 'dart:convert';
import 'film_catalog_item.dart';
import 'media_source.dart';
import 'video_queue.dart';

class FilmPlaylist {
  FilmPlaylist.fromRow(Map<String, Object?> row)
    : id = row['id'] as String,
      name = row['name'] as String,
      sourceId = row['source_id'] as String,
      sourceName = row['source_name'] as String,
      sourceKind = MediaSourceKind.values.byName(row['source_kind'] as String),
      serverIdentity = row['server_identity'] as String?,
      readOnly = row['kind'] == 'server',
      error = row['error'] as String?,
      artwork = row['artwork'] as String?,
      artworkTarget = row['artwork_target'] as String? ?? 'w342',
      artworkSensitive = row['artwork_sensitive'] == 1,
      artworkPath = row['artwork_path'] as String?,
      artworkWorkId = row['artwork_work_id'] as int?,
      count = row['member_count'] as int? ?? 0;
  final String id, name, sourceId, sourceName;
  final MediaSourceKind sourceKind;
  final String? serverIdentity;
  final bool readOnly;
  final String? error;
  final String? artwork;
  final String artworkTarget;
  final bool artworkSensitive;
  final String? artworkPath;
  final int? artworkWorkId;
  final int count;
}

/// 作品范围跟随新集；资源与已有列表只加入当前所选内容。
class FilmPlaylistScope {
  const FilmPlaylistScope.work(int this.workId, {this.season})
    : resource = null,
      playlist = null,
      entryId = null;
  const FilmPlaylistScope.resource(FilmResource this.resource)
    : workId = null,
      season = null,
      playlist = null,
      entryId = null;
  const FilmPlaylistScope.playlist(FilmPlaylist this.playlist, {this.entryId})
    : workId = null,
      season = null,
      resource = null;
  final int? workId, season;
  final FilmResource? resource;
  final FilmPlaylist? playlist;
  final String? entryId;
  bool get follows => workId != null;
}

class FilmPlaylistEntry {
  FilmPlaylistEntry.fromRow(Map<String, Object?> row)
    : id = row['id'] as String,
      workId = row['work_id'] as int?,
      season = row['season_number'] as int?,
      episode = row['episode_number'] as int?,
      pinnedPath = row['pinned_path'] as String?,
      serverItemId = row['server_item_id'] as String?,
      versions = (jsonDecode(row['versions_json'] as String) as List)
          .map(
            (v) => VideoQueueVersion(
              path: v['path'] as String,
              name: v['name'] as String,
            ),
          )
          .toList(),
      display = Map<String, dynamic>.from(
        jsonDecode(row['display_json'] as String) as Map,
      );
  final String id;
  int? workId, season, episode;
  final String? pinnedPath, serverItemId;
  final List<VideoQueueVersion> versions;
  final Map<String, dynamic> display;
  bool available = false;
  FilmResource? resource;
  List<VideoQueueVersion>? currentVersions;
  String get title => display['title'] as String? ?? versions.first.name;
  int? get year => display['year'] as int?;
  String? get artwork => display['artwork'] as String?;
  VideoQueueItem get queueItem => VideoQueueItem(
    versions: currentVersions ?? versions,
    season: season,
    episode: episode,
    unavailable: !available,
  );
}

class FilmPlaylistSnapshot {
  const FilmPlaylistSnapshot(this.playlist, this.entries);
  final FilmPlaylist playlist;
  final List<FilmPlaylistEntry> entries;
  List<VideoQueueItem> get queueItems =>
      entries.map((e) => e.queueItem).toList();
}
