enum MediaLibrarySharingMode { independent, localShared, allShared }

/// 媒体中心容量与展示范围，写入统一的 stream_path_config.json。
class MediaLibraryConfig {
  const MediaLibraryConfig({
    this.sharingMode = MediaLibrarySharingMode.independent,
    this.maxFavoritesPerSource = defaultMaxFavoritesPerSource,
    this.maxContinuePerLane = defaultMaxContinuePerLane,
    this.maxRecentPlaybackPerLane = defaultMaxRecentPlaybackPerLane,
    this.maxRecentDirectoriesPerSource = defaultMaxRecentDirectoriesPerSource,
  });

  static const int minItemLimit = 1;

  static const int defaultMaxFavoritesPerSource = 2000;
  static const int defaultMaxContinuePerLane = 500;
  static const int defaultMaxRecentPlaybackPerLane = 500;
  static const int defaultMaxRecentDirectoriesPerSource = 100;

  static const int systemMaxFavoritesPerSource = 2000;
  static const int systemMaxContinuePerLane = 500;
  static const int systemMaxRecentPlaybackPerLane = 2000;
  static const int systemMaxRecentDirectoriesPerSource = 500;

  final int maxFavoritesPerSource;
  final MediaLibrarySharingMode sharingMode;

  bool includesSource(String current, String candidate) =>
      current == candidate ||
      sharingMode == MediaLibrarySharingMode.allShared ||
      (sharingMode == MediaLibrarySharingMode.localShared &&
          current.startsWith('local:') &&
          candidate.startsWith('local:'));
  final int maxContinuePerLane;
  final int maxRecentPlaybackPerLane;
  final int maxRecentDirectoriesPerSource;

  MediaLibraryConfig get normalized => MediaLibraryConfig(
    sharingMode: sharingMode,
    maxFavoritesPerSource: maxFavoritesPerSource.clamp(
      minItemLimit,
      systemMaxFavoritesPerSource,
    ),
    maxContinuePerLane: maxContinuePerLane.clamp(
      minItemLimit,
      systemMaxContinuePerLane,
    ),
    maxRecentPlaybackPerLane: maxRecentPlaybackPerLane.clamp(
      minItemLimit,
      systemMaxRecentPlaybackPerLane,
    ),
    maxRecentDirectoriesPerSource: maxRecentDirectoriesPerSource.clamp(
      minItemLimit,
      systemMaxRecentDirectoriesPerSource,
    ),
  );

  Map<String, dynamic> toJson() {
    final value = normalized;
    return <String, dynamic>{
      'sharingMode': value.sharingMode.name,
      'maxFavoritesPerSource': value.maxFavoritesPerSource,
      'maxContinuePerLane': value.maxContinuePerLane,
      'maxRecentPlaybackPerLane': value.maxRecentPlaybackPerLane,
      'maxRecentDirectoriesPerSource': value.maxRecentDirectoriesPerSource,
    };
  }

  factory MediaLibraryConfig.fromJson(Map<String, dynamic>? json) {
    int readLimit(String key, int fallback, int maximum) {
      final raw = json?[key];
      final value = raw is num
          ? raw.toInt()
          : raw is String
          ? int.tryParse(raw.trim())
          : null;
      return (value ?? fallback).clamp(minItemLimit, maximum);
    }

    return MediaLibraryConfig(
      sharingMode:
          MediaLibrarySharingMode.values
              .where((mode) => mode.name == json?['sharingMode'])
              .firstOrNull ??
          MediaLibrarySharingMode.independent,
      maxFavoritesPerSource: readLimit(
        'maxFavoritesPerSource',
        defaultMaxFavoritesPerSource,
        systemMaxFavoritesPerSource,
      ),
      maxContinuePerLane: readLimit(
        'maxContinuePerLane',
        defaultMaxContinuePerLane,
        systemMaxContinuePerLane,
      ),
      maxRecentPlaybackPerLane: readLimit(
        'maxRecentPlaybackPerLane',
        defaultMaxRecentPlaybackPerLane,
        systemMaxRecentPlaybackPerLane,
      ),
      maxRecentDirectoriesPerSource: readLimit(
        'maxRecentDirectoriesPerSource',
        defaultMaxRecentDirectoriesPerSource,
        systemMaxRecentDirectoriesPerSource,
      ),
    );
  }
}
