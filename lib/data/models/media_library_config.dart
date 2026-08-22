/// 媒体中心容量配置，写入统一的 stream_path_config.json。
class MediaLibraryConfig {
  const MediaLibraryConfig({
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
  final int maxContinuePerLane;
  final int maxRecentPlaybackPerLane;
  final int maxRecentDirectoriesPerSource;

  MediaLibraryConfig get normalized => MediaLibraryConfig(
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
